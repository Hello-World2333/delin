--[[ Delin procfs: 挂在 /proc 的虚拟进程/系统信息文件系统。
     布局(对齐 Linux procfs 的形状):
       /proc/<pid>/{cmdline,comm,cwd,stat,status}
       /proc/self/...       调用者自身 pid 的别名(Linux 是符号链接; Delin 无 symlink, 当目录)
       /proc/{mounts,uptime,version}
     进程集合 = 内核进程表里仍存活的进程(process.list: running|stopped)。
     Delin 无 zombie 语义: 进程退出后 /proc/<pid> 立即消失(Linux 保留到父进程 wait)。
     没有数据源的东西一律不提供(meminfo/cpuinfo/loadavg 等) —— 不造假; ps 因此也没有
     TIME/%CPU/%MEM 列(见 README「已知偏离」)。
     全部只读; 文件内容是打开时的快照, 读尽即 EOF(与 sysfs 属性句柄一致)。
     stat 只提供 Linux 的前 8 个字段(pid..tpgid): Delin 不统计 CPU 时间/内存/页错误。
     tty 字段(第 7 个)是 tty 名(如 tty0)或 0(无控制终端), 不是 Linux 的 dev_t 编码。 ]]

local vfs     = require("kernel.vfs")
local process = require("kernel.process")

local procfs = {}

local bootMs = 0
local osVersion = "0.0.0" -- Delin 版本串(mount 时由 boot 传入)

-- /proc/<pid>/ 下的文件(字母序, 与 ls 输出无关但保持稳定)
local PID_FILES = { "cmdline", "comm", "cwd", "stat", "status" }
-- /proc/ 下的系统信息文件
local SYS_FILES = { "mounts", "uptime", "version" }

local function norm(rel) return (rel or ""):gsub("^/+", "") end

--- 进程名: 取 name 的 basename(与 Linux comm 一致; spawnFile 传的是程序路径)。
---@param p DelinProcess
---@return string
local function commOf(p)
    local n = p.name or ("proc#" .. p.pid)
    return n:match("([^/]+)$") or n
end

--- 进程状态: Linux 状态字母 + 词。
--- Delin 无真正并发: 只有当前正在跑的进程是 R, 其余存活进程都阻塞在事件上(S)。
---@param p DelinProcess
---@return string letter, string word
local function stateOf(p)
    if p.status == "stopped" then return "T", "stopped" end
    if p.pid == process.current().pid then return "R", "running" end
    return "S", "sleeping"
end

--- 控制终端名(去 /dev/ 前缀; 无则 "0") + 前台进程组(无则 -1)。
---@param p DelinProcess
---@return string, integer
local function ttyOf(p)
    local tty = process.ttyFor(p.pid)
    if not tty then return "0", -1 end
    return (tty:gsub("^/dev/", "")), (process.fgPgrpFor(p.pid) or -1)
end

--- /proc/<pid>/stat: Linux 字段 1..8。
local function statText(p)
    local letter = stateOf(p)
    local tty, tpgid = ttyOf(p)
    return string.format("%d (%s) %s %d %d %d %s %d\n",
        p.pid, commOf(p), letter, p.ppid or 0, p.pgrp or 0, p.sid or 0, tty, tpgid)
end

--- /proc/<pid>/status: Linux 的 key:\tvalue 行(Name/State/Tgid/Pid/PPid/Pgrp/Session/Uid/Gid)。
--- Delin 只有一个 uid/gid, 因此 Uid/Gid 行只有一列(Linux 是 real/effective/saved/fs 四列)。
local function statusText(p)
    local letter, word = stateOf(p)
    return table.concat({
        "Name:\t" .. commOf(p),
        "State:\t" .. letter .. " (" .. word .. ")",
        "Tgid:\t" .. p.pid,
        "Pid:\t" .. p.pid,
        "PPid:\t" .. (p.ppid or 0),
        "Pgrp:\t" .. (p.pgrp or 0),
        "Session:\t" .. (p.sid or 0),
        "Uid:\t" .. (p.uid or 0),
        "Gid:\t" .. (p.gid or 0),
    }, "\n") .. "\n"
end

--- /proc/<pid>/cmdline: argv 以 NUL 分隔 + 结尾 NUL(Linux 语义)。
local function cmdlineText(p)
    local argv = p.argv or {}
    if argv[0] == nil and #argv == 0 then return "" end
    local parts = {}
    for i = 0, #argv do parts[#parts + 1] = tostring(argv[i]) end
    return table.concat(parts, "\0") .. "\0"
end

--- /proc/mounts: <device> <mountpoint> <fstype> <options> 0 0 (Linux proc(5) 的格式)。
local function mountsText()
    local out = {}
    for _, m in ipairs(vfs.list()) do
        local dev = (m.meta and m.meta.device) or "none"
        local fst = (m.meta and m.meta.fstype) or "none"
        local opts = m.backend.isReadOnly("") and "ro" or "rw"
        out[#out + 1] = string.format("%s %s %s %s 0 0", dev, m.root, fst, opts)
    end
    return table.concat(out, "\n") .. "\n"
end

--- /proc/uptime: 自引导起的秒数(Linux 还有第二个 idle 字段; Delin 无 idle 统计, 不提供)。
local function uptimeText()
    return string.format("%.2f\n", (os.epoch("utc") - bootMs) / 1000)
end

--- /proc/version: 内核版本串。
local function versionText()
    return "Delin OS " .. osVersion .. " (" .. tostring(os.version()) ..
        ", " .. _VERSION .. ")\n"
end

--- 解析 /proc 下的相对路径。
---@param rel string
---@return string|nil kind "root"|"pid"|"pidfile"|"sysfile"
---@return integer|nil pid
---@return string|nil name
local function parse(rel)
    rel = norm(rel):gsub("/+$", "")
    if rel == "" then return "root" end
    local parts = {}
    for p in rel:gmatch("[^/]+") do parts[#parts + 1] = p end
    local head = parts[1]
    if head == "self" then
        local pid = process.current().pid
        if not pid or pid == 0 then return nil end
        head = tostring(pid)
    end
    if head:match("^%d+$") then
        local pid = tonumber(head)
        if #parts == 1 then return "pid", pid end
        if #parts == 2 then return "pidfile", pid, parts[2] end
        return nil
    end
    if #parts == 1 then
        for _, n in ipairs(SYS_FILES) do
            if n == head then return "sysfile", nil, head end
        end
    end
    return nil
end

--- 存活进程表项(退出进程没有 /proc 节点)。
---@param pid integer
---@return DelinProcess|nil
local function liveProc(pid)
    local p = process.info(pid)
    if not p then return nil end
    if p.status ~= "running" and p.status ~= "stopped" then return nil end
    return p
end

--- /proc/<pid>/cwd 的读权限(Linux 语义: 属主或 root)。
---@param p DelinProcess
---@return boolean
local function mayReadCwd(p)
    local uid = process.current().uid or 0
    return uid == 0 or uid == p.uid
end

--- 取 /proc/<pid>/<name> 的内容。
---@return string|nil content, string|nil err
local function pidFileText(p, name)
    if name == "comm" then return commOf(p) .. "\n" end
    if name == "stat" then return statText(p) end
    if name == "status" then return statusText(p) end
    if name == "cmdline" then return cmdlineText(p) end
    if name == "cwd" then
        if not mayReadCwd(p) then return nil, "permission denied" end
        return (p.cwd or "/") .. "\n"
    end
    return nil, "no such file: " .. tostring(name)
end

local function sysFileText(name)
    if name == "uptime" then return uptimeText() end
    if name == "version" then return versionText() end
    if name == "mounts" then return mountsText() end
    return nil, "no such file: " .. tostring(name)
end

--- 只读内容句柄: 按行/按字节读, 读尽即 EOF(与 sysfs 属性句柄同样的语义)。
local function openContent(content)
    local pos = 1
    return {
        read = function(_, n)
            if pos > #content then return nil end
            if type(n) ~= "number" then
                local rest = content:sub(pos)
                pos = #content + 1
                return rest
            end
            local chunk = content:sub(pos, pos + n - 1)
            pos = pos + #chunk
            return chunk
        end,
        readLine = function()
            if pos > #content then return nil end
            local nl = content:find("\n", pos, true)
            if not nl then
                local rest = content:sub(pos)
                pos = #content + 1
                return rest
            end
            local line = content:sub(pos, nl - 1)
            pos = nl + 1
            return line
        end,
        readAll = function()
            if pos > #content then return nil end
            local rest = content:sub(pos)
            pos = #content + 1
            return rest
        end,
        write     = function() return nil, "read-only fs" end,
        writeLine = function() return nil, "read-only fs" end,
        close     = function() end,
        flush     = function() return true end,
    }
end

local backend = {
    kind = "virtual",
    list = function(rel)
        local kind, pid = parse(rel)
        if kind == "root" then
            local out = {}
            for _, p in ipairs(process.list()) do out[#out + 1] = tostring(p.pid) end
            out[#out + 1] = "self"
            for _, n in ipairs(SYS_FILES) do out[#out + 1] = n end
            return out
        end
        if kind == "pid" then
            if not liveProc(pid) then return nil end
            local out = {}
            for i, n in ipairs(PID_FILES) do out[i] = n end
            return out
        end
        return nil
    end,
    exists = function(rel)
        local kind, pid, name = parse(rel)
        if kind == "root" or kind == "sysfile" then return true end
        if kind == "pid" then return liveProc(pid) ~= nil end
        if kind == "pidfile" then
            if not liveProc(pid) then return false end
            for _, n in ipairs(PID_FILES) do if n == name then return true end end
            return false
        end
        return false
    end,
    -- 目录判定必须与 exists 一致(否则 cd /proc/<不存在的 pid> 会成功)。
    isDir = function(rel)
        local kind, pid = parse(rel)
        if kind == "root" then return true end
        if kind == "pid" then return liveProc(pid) ~= nil end
        return false
    end,
    attributes = function(rel)
        local kind, pid, name = parse(rel)
        if kind == "root" then return { size = 0, isDir = true, isReadOnly = true, name = "proc" } end
        if kind == "pid" then
            if not liveProc(pid) then return nil end
            return { size = 0, isDir = true, isReadOnly = true, name = tostring(pid) }
        end
        if kind == "pidfile" then
            if not backend.exists(rel) then return nil end
            -- procfs 文件的 st_size 是 0(Linux 同样如此), 内容随读生成。
            return { size = 0, isDir = false, isReadOnly = true, name = name }
        end
        if kind == "sysfile" then
            return { size = 0, isDir = false, isReadOnly = true, name = name }
        end
        return nil
    end,
    getSize = function() return 0 end,
    getDrive = function() return "proc" end,
    getFreeSpace = function() return 0 end,
    getCapacity = function() return 0 end,
    isReadOnly = function() return true end,
    open = function(rel, mode)
        local kind, pid, name = parse(rel)
        if kind == "root" or kind == "pid" then return nil, "is a directory" end
        if not kind then return nil, "no such path: /proc/" .. norm(rel) end
        if mode and mode:find("w") then return nil, "read-only fs: /proc/" .. norm(rel) end
        local content, err
        if kind == "pidfile" then
            local p = liveProc(pid)
            if not p then return nil, "no such process: " .. tostring(pid) end
            content, err = pidFileText(p, name)
        else
            content, err = sysFileText(name)
        end
        if content == nil then return nil, err end
        return openContent(content)
    end,
    makeDir = function() error("read-only fs", 2) end,
    move    = function() error("read-only fs", 2) end,
    copy    = function() error("read-only fs", 2) end,
    delete  = function() error("read-only fs", 2) end,
}

--- 挂载 procfs 到 /proc。
---@param bootMsArg integer|nil 引导时刻(os.epoch("utc") 毫秒), /proc/uptime 的零点
---@param versionArg string|nil Delin 版本号(/proc/version 用)
function procfs.mount(bootMsArg, versionArg)
    bootMs = bootMsArg or os.epoch("utc")
    osVersion = versionArg or osVersion
    vfs.mount("/proc", backend, { device = "proc", fstype = "proc" })
    return true
end

return procfs
