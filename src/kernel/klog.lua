--[[ Delin 内核日志 (klog) —— rsyslog/syslogd 的内核侧底座。
     内核与用户态都经此汇聚, 两条通道与 Linux 同构:
       /dev/kmsg  内核 ring buffer(printk 缓冲区)的只读流, 每行 "pri,seq,usec,-;text"。
                  历史消息保留(读者从缓冲区最旧一条开始), 读尽后阻塞等待新消息。
       /dev/log   用户态 syslog 输入(等价的 /dev/log socket)。生产者以 "<PRI>tag: msg"
                   写入; syslogd 独占读取。无读者时缓冲有界, 满了丢最旧(计数)。
     优先级 pri = facility*8 + severity, facility/severity 名表由本模块持有(唯一真源),
     经 syscall 暴露给 /bin/logger、/bin/syslogd、/bin/dmesg。
     ring buffer 是有界的(默认 16KB): 内核早期消息(含 syslogd 启动前的引导日志)在缓冲区
     里等着 syslogd 启动后一次性取走落盘, 满了丢最旧。 ]]

local vfs_api = require("kernel.vfs_api")

local klog = {}

-- ---------------------------------------------------------------
-- syslog facility / severity (RFC 3164 / syslog(3))
-- ---------------------------------------------------------------
local FACILITIES = {
    kern = 0, user = 1, mail = 2, daemon = 3, auth = 4, syslog = 5, lpr = 6, news = 7,
    uucp = 8, cron = 9, authpriv = 10, ftp = 11,
    local0 = 16, local1 = 17, local2 = 18, local3 = 19,
    local4 = 20, local5 = 21, local6 = 22, local7 = 23,
}
local SEVERITIES = {
    emerg = 0, alert = 1, crit = 2, err = 3, warning = 4, notice = 5, info = 6, debug = 7,
}

local FACILITY_NAMES, SEVERITY_NAMES = {}, {}
for n, v in pairs(FACILITIES) do FACILITY_NAMES[v] = n end
for n, v in pairs(SEVERITIES) do SEVERITY_NAMES[v] = n end

klog.FACILITIES = FACILITIES
klog.SEVERITIES = SEVERITIES

--- 优先级拆分。
---@param pri integer
---@return integer facility, integer severity
function klog.split(pri)
    return math.floor(pri / 8), pri % 8
end

--- 优先级合成。
function klog.makePri(facility, severity)
    return facility * 8 + severity
end

function klog.facilityName(n) return FACILITY_NAMES[n] or ("fac" .. n) end
function klog.severityName(n) return SEVERITY_NAMES[n] or ("sev" .. n) end

-- ---------------------------------------------------------------
-- 内核 ring buffer
-- ---------------------------------------------------------------
local RING_BYTES = 16384
local BOOT_ID = os.epoch("utc") -- 本次引导标识(模块加载时刻); 游标跨引导失效靠它判断

local ring = {}          -- seq -> { seq, usec, pri, text }
local firstSeq = 1       -- 缓冲区里最旧一条的 seq
local nextSeq = 1        -- 下一条 seq
local ringBytes = 0
local ringDrops = 0

--- 写一条内核日志(单行; 内嵌换行会被拆成多条)。
---@param pri integer facility*8+severity
---@param text string
function klog.write(pri, text)
    text = tostring(text or "")
    -- usec 为自引导起的微秒数(与 Linux /dev/kmsg 一致), dmesg 因此直接可读。
    local usec = (os.epoch("utc") - BOOT_ID) * 1000
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        ring[nextSeq] = { seq = nextSeq, usec = usec, pri = pri, text = line }
        ringBytes = ringBytes + #line + 1
        nextSeq = nextSeq + 1
    end
    while ringBytes > RING_BYTES and firstSeq < nextSeq do
        local e = ring[firstSeq]
        ringBytes = ringBytes - (#e.text + 1)
        ring[firstSeq] = nil
        firstSeq = firstSeq + 1
        ringDrops = ringDrops + 1
    end
end

--- 内核 facility=kern severity=info 的快捷写。
function klog.kern(text) klog.write(klog.makePri(FACILITIES.kern, SEVERITIES.info), text) end
--- 用户态 facility=user severity=info 的快捷写(进程 print 走这条)。
function klog.user(text) klog.write(klog.makePri(FACILITIES.user, SEVERITIES.info), text) end

--- ring buffer 统计(供 dmesg / 排障; boot 为本次引导标识)。
function klog.stats()
    return { first = firstSeq, next = nextSeq, bytes = ringBytes, drops = ringDrops, boot = BOOT_ID }
end

--- Linux /dev/kmsg 行格式: "pri,seq,usec,-;text"。
local function kmsgLine(e)
    return string.format("%d,%d,%d,-;%s", e.pri, e.seq, e.usec, e.text)
end

--- /dev/kmsg 读句柄(流式, 历史消息从最旧一条开始)。
local function kmsgReader()
    local pos = firstSeq
    local closed = false
    local h = {
        readAvailable = function()
            if closed then return "" end
            local out = {}
            while pos < nextSeq do
                local e = ring[pos]
                pos = pos + 1
                if e then out[#out + 1] = kmsgLine(e) end
            end
            return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
        end,
        readLine = function()
            while not closed do
                if pos < nextSeq then
                    local e = ring[pos]
                    pos = pos + 1
                    if e then return kmsgLine(e) end
                else
                    os.sleep(0.05)
                end
            end
            return nil
        end,
        --- 下一个待读序号(syslogd 持久化它, 重启后从该处续读, 避免重放整段 ring buffer)。
        cursor = function() return pos end,
        --- 定位读取位置(早于缓冲区最旧一条时从最旧开始)。
        --- 同时支持 `h.seek(n)` 与 `h:seek(n)`(与 ext2 句柄一致)。
        seek = function(a, b)
            local seq = (type(a) == "table") and b or a
            seq = tonumber(seq)
            if not seq then return nil, "seek: bad sequence number" end
            pos = math.max(math.floor(seq), firstSeq)
            return true
        end,
        close = function() closed = true; return true end,
        flush = function() return true end,
        getDeviceName = function() return "kmsg" end,
    }
    return h
end

-- ---------------------------------------------------------------
-- /dev/log: 用户态 syslog 输入缓冲
-- ---------------------------------------------------------------
local LOG_BYTES = 8192

local logLines = {}      -- 待取行(先进先出)
local logBytes = 0
local logDrops = 0

local function logPush(line)
    logLines[#logLines + 1] = line
    logBytes = logBytes + #line + 1
    while logBytes > LOG_BYTES and #logLines > 1 do
        local old = table.remove(logLines, 1)
        logBytes = logBytes - (#old + 1)
        logDrops = logDrops + 1
    end
end

--- /dev/log 写句柄: 按行缓冲, 行必须形如 "<PRI>tag: message"。
local function logWriter()
    local buf = ""
    local closed = false
    return {
        write = function(_, s)
            if closed then return nil, "log closed" end
            s = tostring(s or "")
            buf = buf .. s
            while true do
                local nl = buf:find("\n", 1, true)
                if not nl then break end
                local line = buf:sub(1, nl - 1)
                buf = buf:sub(nl + 1)
                if line ~= "" then logPush(line) end
            end
            return #s
        end,
        writeLine = function(self, s) return self:write(tostring(s or "") .. "\n") end,
        flush = function() return true end,
        close = function()
            if not closed and buf ~= "" then logPush(buf); buf = "" end
            closed = true
            return true
        end,
        getDeviceName = function() return "log" end,
    }
end

--- /dev/log 读句柄(syslogd 独占读取)。
local function logReader()
    local closed = false
    return {
        readAvailable = function()
            if closed or #logLines == 0 then return "" end
            local out = table.concat(logLines, "\n") .. "\n"
            logLines, logBytes = {}, 0
            return out
        end,
        readLine = function()
            while not closed do
                if #logLines > 0 then
                    local line = table.remove(logLines, 1)
                    logBytes = logBytes - (#line + 1)
                    return line
                end
                os.sleep(0.05)
            end
            return nil
        end,
        close = function() closed = true; return true end,
        flush = function() return true end,
        getDeviceName = function() return "log" end,
    }
end

--- 丢弃计数(无读者且缓冲写满时)。
function klog.logDrops() return logDrops end

-- ---------------------------------------------------------------
-- 注册 /dev/kmsg 与 /dev/log
-- ---------------------------------------------------------------
--- 注册日志设备(boot 在 mountDev 之后调用一次)。
function klog.register()
    vfs_api.registerDevice("kmsg", {
        writable = false,
        open = function(mode)
            if mode and mode:find("[wa+]") then return nil, "/dev/kmsg: read-only" end
            return kmsgReader()
        end,
    })
    vfs_api.registerDevice("log", {
        writable = true,
        open = function(mode)
            if mode and mode:find("r") then return logReader() end
            return logWriter()
        end,
    })
end

--- 注册 syslog 优先级名表 syscalls(供用户态工具, 避免各工具各抄一份表)。
function klog.registerSyscalls(sc)
    sc["syslog.facility"]      = function(name) return FACILITIES[(name or ""):lower()] end
    sc["syslog.severity"]      = function(name) return SEVERITIES[(name or ""):lower()] end
    sc["syslog.facilityName"]  = function(n) return klog.facilityName(n) end
    sc["syslog.severityName"]  = function(n) return klog.severityName(n) end
    sc["syslog.facilities"]    = function()
        local out = {}
        for n in pairs(FACILITIES) do out[#out + 1] = n end
        table.sort(out)
        return out
    end
    sc["syslog.severities"]    = function()
        local out = {}
        for n in pairs(SEVERITIES) do out[#out + 1] = n end
        table.sort(out)
        return out
    end
    sc["klog.stats"]           = function() return klog.stats() end
    sc["klog.logDrops"]        = function() return klog.logDrops() end
end

return klog
