-- Delin 宿主测试台: 在 HOST 上运行真实的 Delin bin 工具源码(src/bin/*),
-- 提供与内核一致的 fs/io/syscalls/spawn 环境, 以便本地快速调试 sh/工具逻辑。
-- 用法:
--   lua5.1 tools/harness.lua <tool> <args...>   (stdin 作为工具输入, stdout 即 stdout)
--   如: printf 'echo hi\n' | lua5.1 tools/harness.lua /bin/sh
-- ROOT 会先重建并填充 ROOT/bin(=src/bin), /etc, /home, /root 与示例文件。

local ROOT = "/tmp/delinhost"

-- pipe 内核模块用 os.sleep 做协作式阻塞; 在宿主上把它改成 yield 给调度器
-- (宿主 lua5.1 的 os 没有 sleep, 且这里必须能让出当前协程让调度器切走)。
os.sleep = function() coroutine.yield() end
-- 工具的让出是时间片式的(os.epoch("utc") 毫秒); 宿主用 os.clock 顶上。
-- 宿主调度器不推进真实时间, 时间片基本不会到期 —— 逻辑测试不受影响。
os.epoch = os.epoch or function() return math.floor(os.clock() * 1000) end

local function cmd(...) return { ... } end

-- 文件系统门面(基于 HOST 真实文件)。
local F = {}
local function norm(p)
    if p == nil or p == "" then return "/" end
    if p:sub(1, 1) ~= "/" then p = "/" .. p end
    p = p:gsub("/+$", "")
    if p == "" then p = "/" end
    return p
end
local function host(p) local n = norm(p); return ROOT .. n end

function F.list(p)
    local h = host(p)
    local out = {}
    local f = assert(io.popen("ls -A -- " .. h))
    for line in f:lines() do out[#out + 1] = line end
    f:close()
    return out
end
function F.exists(p)
    local h = host(p)
    local f = io.open(h, "r")
    if f then f:close(); return true end
    local st = io.popen("[ -d " .. h .. " ] && echo yes")
    local r = st:read("*a"); st:close()
    return r ~= ""
end
function F.isDir(p)
    local st = io.popen("[ -d " .. host(p) .. " ] && echo yes")
    local r = st:read("*a"); st:close()
    return r ~= ""
end
function F.isFile(p)
    local st = io.popen("[ -f " .. host(p) .. " ] && echo yes")
    local r = st:read("*a"); st:close()
    return r ~= ""
end
function F.canExecute(p)
    local st = io.popen("[ -x " .. host(p) .. " ] && echo yes")
    local r = st:read("*a"); st:close()
    return r ~= ""
end
function F.getSize(p)
    local st = io.popen("stat -c %s -- " .. host(p) .. " 2>/dev/null")
    local r = tonumber(st:read("*a")); st:close()
    return r or 0
end
function F.makeDir(p) os.execute("mkdir -p -- " .. host(p)); return true end
function F.delete(p)
    if F.isDir(p) then os.execute("rm -rf -- " .. host(p)) else os.execute("rm -f -- " .. host(p)) end
    return true
end
function F.copy(a, b)
    os.execute("cp -r -- " .. host(a) .. " " .. host(b)); return true
end
function F.move(a, b)
    os.execute("mv -- " .. host(a) .. " " .. host(b)); return true
end
function F.combine(a, b)
    if b:sub(1, 1) == "/" then return norm(b) end
    return norm(a .. "/" .. b)
end
function F.attributes(p)
    local n = norm(p)
    local sz = F.getSize(p)
    local typebits = F.isDir(p) and 0x4000 or 0x8000
    -- 读宿主真实权限(八进制) -> 低 9 位, 与 ext2 的 mode 语义一致(低 12 位)。
    local func = "stat -c %a -- " .. host(p) .. " 2>/dev/null"
    local h = io.popen(func)
    local perms = tonumber(((h:read("*a") or ""):gsub("%s+$", "")), 8)
    h:close()
    if not perms then perms = F.isDir(p) and tonumber("755", 8) or tonumber("644", 8) end
    -- 读宿主真实 uid/gid, 便于 ls -l / chown 反映变化。
    local hu = io.popen("stat -c %u -- " .. host(p) .. " 2>/dev/null")
    local gu = io.popen("stat -c %g -- " .. host(p) .. " 2>/dev/null")
    local uid = tonumber(((hu:read("*a") or ""):gsub("%s+$", ""))) or 0
    local gid = tonumber(((gu:read("*a") or ""):gsub("%s+$", ""))) or 0
    hu:close(); gu:close()
    return { size = sz, isDir = F.isDir(p), mode = typebits + (perms % tonumber("1000", 8)),
             name = n:match("[^/]+$") or "", uid = uid, gid = gid }
end

function F.chmod(p, mode)
    local h = host(p)
    local ok = os.execute("chmod " .. string.format("%o", (mode or 0) % tonumber("1000", 8)) .. " -- " .. h)
    return ok == true or ok == 0
end

function F.chown(p, uid, gid)
    local h = host(p)
    local spec = ""
    if uid ~= nil then spec = spec .. tostring(uid) end
    if gid ~= nil then spec = spec .. ":" .. tostring(gid) end
    if spec == "" then return true end
    os.execute("chown " .. spec .. " -- " .. h .. " 2>/dev/null")
    return true
end

-- 文件句柄: 同时支持 `.method` 与 `:method`(CC 原生句柄两者皆可)。
local unpack = table.unpack or unpack
local Handle = {}
local function mkHandle(file, name, isTTY)
    local h = { f = file, name = name, isTTY = isTTY or false, kind = "file" }
    local function m(fn)
        return function(...)
            local n = select("#", ...)
            local a = { ... }
            if n > 0 and a[1] == h then return fn(unpack(a, 2, n)) else return fn(unpack(a, 1, n)) end
        end
    end
    h.close     = m(function() file:close() end)
    h.flush     = m(function() file:flush() return true end)
    h.write     = m(function(s) file:write(tostring(s)); file:flush(); return #tostring(s) end)
    h.writeLine = m(function(s) file:write(tostring(s or "") .. "\n"); file:flush(); return #tostring(s or "") + 1 end)
    h.read      = m(function(fmt) return file:read(fmt) end)
    h.readLine = m(function() return file:read("*l") end)
    h.readAll   = m(function() return file:read("*a") end)
    h.getSize   = m(function() return 0 end)
    h.getDeviceName = m(function() return nil end)
    h.setEcho   = m(function() end)
    return h
end
-- 保持 Handle.new 兼容内部签名
Handle.new = function(file, name, isTTY) return mkHandle(file, name, isTTY) end

-- ---------------------------------------------------------------
-- 每个进程的 io 门面(捕获该进程 stdio)
-- ---------------------------------------------------------------
local function makeIo(stdio)
    return {
        stdin  = function() return stdio.input end,
        stdout = function() return stdio.output end,
        stderr = function() return stdio.output end,
        write = function(...)
            if stdio.output and stdio.output.write then
                local parts = {}
                for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
                stdio.output:write(table.concat(parts))
            end
        end,
        read = function(...) if stdio.input and stdio.input.read then return stdio.input:read(...) end end,
        flush = function() if stdio.output and stdio.output.flush then stdio.output:flush() end end,
        open = function(p, m)
            return F.open(p, m)
        end,
        type = function(v) return "file" end,
        close = function(v) end,
        lines = function(f) local h, i = F.open(f, "r"), 0; return function() i = i + 1; return h and h:readLine() end end,
    }
end

-- /dev/null(与内核 devtmpfs 的 null 设备一致): 读立即 EOF, 写丢弃。
local NULL_HANDLE = {
    isTTY = false,
    read = function() return nil end,
    readLine = function() return nil end,
    write = function(_, s) return #tostring(s or "") end,
    flush = function() return true end,
    close = function() return true end,
    getDeviceName = function() return nil end,
}

-- io.open 落在 F.open / fs.open
function F.open(p, mode)
    p = norm(p)
    if p == "/dev/null" then return NULL_HANDLE end
    local m = mode or "r"
    local hostp = host(p)
    if m == "r" then
        local f = io.open(hostp, "rb")
        if not f then return nil, "No such file or directory" end
        return Handle.new(f, p)
    elseif m == "w" then
        local f = assert(io.open(hostp, "wb"))
        return Handle.new(f, p)
    elseif m == "a" then
        local f = assert(io.open(hostp, "ab"))
        return Handle.new(f, p)
    elseif m == "r+" or m == "rw" then
        local f = assert(io.open(hostp, "r+b"))
        return Handle.new(f, p)
    end
    return nil, "unsupported mode"
end

-- ---------------------------------------------------------------
-- syscalls(最小桩)
-- ---------------------------------------------------------------
local procs = {}
local curPid = nil -- 调度器当前 resume 的进程(供 job.group/signal.install 定位调用者)
local users = {}
local groups = {}
local syscalls = {}
local PIPE = nil -- 内核 pipe 模块(lazy require), 提供 pipe.create
local function pipeCreate()
    if not PIPE then
        package.path = "/home/worker/delin/src/?.lua;" .. package.path
        PIPE = require("kernel.pipe")
    end
    return PIPE.create()
end
syscalls["proc.info"] = function(pid) return procs[pid] end
syscalls["proc.wait"] = function(pid)
    -- 阻塞等待子进程退出(通过 os.sleep 让出调度器, 轮询)。
    while true do
        local p = procs[pid]
        if not p then return -1 end
        if p.status == "dead" or p.status == "error" then
            if p.termSig then return -p.termSig end
            return (p.status == "error" and 1) or (p.exitCode or 0)
        end
        os.sleep(0.01)
    end
end
syscalls["pipe.create"] = function() return pipeCreate() end

-- 信号/作业控制桩: 与内核 signal.lua/process.lua 的语义对齐(编号/默认动作/进程组),
-- 使 sh 的 `&`/jobs/fg/bg/wait/kill %job 能在宿主上被真实验证(前台 tty 部分除外)。
local SIG = {
    [1] = "HUP", [2] = "INT", [3] = "QUIT", [9] = "KILL", [10] = "USR1", [12] = "USR2",
    [13] = "PIPE", [14] = "ALRM", [15] = "TERM", [17] = "CHLD", [18] = "CONT",
    [19] = "STOP", [20] = "TSTP", [21] = "TTIN", [22] = "TTOU",
}
local SIGNO = {}
for n, nm in pairs(SIG) do SIGNO[nm] = n end
local SIG_LIST = {}
for n in pairs(SIG) do SIG_LIST[#SIG_LIST + 1] = n end
table.sort(SIG_LIST)
local STOP_SIGS = { [19] = true, [20] = true, [21] = true, [22] = true }

local function deliver(pid, sig)
    local p = procs[pid]
    if not p then return nil, "no such process: " .. tostring(pid) end
    if p.status == "dead" or p.status == "error" then return true end -- 已死: 无效果但不算错
    if sig == 18 then -- SIGCONT
        if p.status == "stopped" then p.status = "running" end
        return true
    end
    local h = p.handlers and p.handlers[sig]
    if h then pcall(h, sig); return true end
    if sig == 9 or STOP_SIGS[sig] == nil then
        p.termSig = sig
        p.status = "dead"
    else
        p.status = "stopped"
    end
    return true
end

syscalls["signal.list"] = function() return SIG_LIST end
syscalls["signal.name"] = function(n) return SIG[n] or "?" end
syscalls["signal.number"] = function(name)
    return SIGNO[(name or ""):upper():gsub("^SIG", "")]
end
syscalls["signal.kill"] = function(pid, sig) return deliver(pid, sig) end
syscalls["signal.killpg"] = function(pgid, sig)
    local n = 0
    for pid, p in pairs(procs) do
        if p.pgrp == pgid then deliver(pid, sig); n = n + 1 end
    end
    if n == 0 then return nil, "no such process group" end
    return n
end
syscalls["signal.install"] = function(sig, fn)
    local p = procs[curPid]
    if not p then return nil, "no current process" end
    p.handlers = p.handlers or {}
    p.handlers[sig] = fn
    return true
end
syscalls["job.group"] = function()
    local p = procs[curPid]
    return p and p.pgrp or 0
end
syscalls["job.setpgid"] = function(pid, pgid)
    local p = procs[pid]
    if not p then return nil, "no such process: " .. tostring(pid) end
    p.pgrp = (not pgid or pgid == 0) and pid or pgid
    return true
end
syscalls["job.setsid"] = function()
    local p = procs[curPid]
    if not p then return nil, "no current process" end
    p.pgrp, p.sid = curPid, curPid
    return curPid
end
syscalls["job.tcsetpgrp"] = function() return true end
syscalls["stdio.set"] = function(i, o) return true end
syscalls["tty.console"] = function() return "tty0" end
syscalls["tty.list"] = function() return { "tty0", "tty1" } end
syscalls["tty.setFocus"] = function() return true end
syscalls["tty.getFocus"] = function() return "tty0" end
syscalls["user.get"] = function(name) return users[name] end
syscalls["user.verify"] = function(name, pw) return users[name] and users[name].hash == pw end
syscalls["user.list"] = function() local o = {}; for n in pairs(users) do o[#o + 1] = n end; return o end
syscalls["user.byUid"] = function(u)
    for _, usr in pairs(users) do if usr.uid == u then return usr end end
    return nil
end
syscalls["user.groupByName"] = function(name) return groups[name] end
syscalls["user.register"] = function() end

-- 挂载/卸载桩: 记录到内存表, 供 `mount`/`umount` 命令在宿主上验证参数与列表。
-- 行为对齐内核 devdisk: 按节点名/UUID 解析设备, 未知设备或 fstype 不符即报错。
local mountTable = {}
local function blkFind(spec)
    local byUuid = spec:sub(1, 5) == "UUID="
    local want = byUuid and spec:sub(6) or spec:gsub("^/dev/", "")
    for _, e in ipairs(syscalls["blkdev.list"]()) do
        if (byUuid and e.uuid == want) or (not byUuid and e.name == want) then return e end
    end
    return nil
end
syscalls["fs.mount"] = function(device, dir, fstype)
    local e = blkFind(device)
    if not e then return nil, device .. ": no such device" end
    local fst = fstype or e.fstype
    if fst ~= e.fstype then return nil, e.node .. " is " .. e.fstype .. ", not " .. fst end
    mountTable[#mountTable + 1] = { device = e.node, dir = dir, fstype = fst, uuid = e.uuid }
    return true, { device = e.node, fstype = fst, uuid = e.uuid }
end
syscalls["fs.umount"] = function(dir)
    for i = #mountTable, 1, -1 do if mountTable[i].dir == dir then table.remove(mountTable, i) end end
    return true
end
syscalls["fs.mounts"] = function()
    local out = {}
    for _, m in ipairs(mountTable) do out[#out + 1] = { root = m.dir, device = m.device, fstype = m.fstype, uuid = m.uuid } end
    return out
end

-- 块设备桩: 两个磁盘(整盘 ccdisk + 各自 manifest 分区 ext2), 与真机 devdisk 的字段一致。
-- mounted 由当前挂载表算出, 使 lsblk 的 MOUNTPOINT 列可验证。
local blkDevices = {
    { name = "sda",  node = "/dev/sda",  type = "disk", fstype = "ccdisk", uuid = "0",   size = 128000,  label = "BOOT" },
    { name = "sda1", node = "/dev/sda1", type = "part", fstype = "ext2",   uuid = "0-1", size = 2097152, role = "root" },
    { name = "sdb",  node = "/dev/sdb",  type = "disk", fstype = "ccdisk", uuid = "1",   size = 128000 },
    { name = "sdb1", node = "/dev/sdb1", type = "part", fstype = "ext2",   uuid = "1-1", size = 2097152, role = "data" },
}
syscalls["blkdev.list"] = function()
    local out = {}
    for _, e in ipairs(blkDevices) do
        local copy = {}
        for k, v in pairs(e) do copy[k] = v end
        copy.mounted = {}
        for _, m in ipairs(mountTable) do
            if m.device == e.node then copy.mounted[#copy.mounted + 1] = m.dir end
        end
        out[#out + 1] = copy
    end
    return out
end

-- ---------------------------------------------------------------
-- spawn: 以协程起一个 Delin 工具源码(独立 env), 由顶层的协作式调度器驱动。
--        os.sleep 会 yield 给调度器, 使阻塞(管道/proc.wait)能并发进展。
-- ---------------------------------------------------------------
local nextPid = 0
local curStdio = nil
local REAL_G = _G
local running = {} -- 调度器进程队列 { pid, co, status }
local function spawn(src, name, ppid, uid, gid, argv, opts)
    nextPid = nextPid + 1
    local pid = nextPid
    local stdio = (opts and opts.stdio) or curStdio
    -- 环境块(与内核 process.spawn 一致): 继承父进程, opts.env 覆盖/追加(值为 nil 删除)。
    local parent = procs[ppid]
    local envvars = {}
    if parent and parent.envvars then for k, v in pairs(parent.envvars) do envvars[k] = v end end
    if opts and opts.env then
        for k, v in pairs(opts.env) do
            if v == nil then envvars[k] = nil else envvars[k] = tostring(v) end
        end
    end
    local env = setmetatable({
        pid = pid, ppid = ppid or 0, uid = uid or 0, gid = gid or 0,
        cwd = (opts and opts.cwd) or "/",
        argv = argv or {}, args = {}, argc = 0, arg0 = "",
        env = envvars, getenv = function(n) return envvars[n] end,
        fs = F, io = makeIo(stdio), syscalls = syscalls,
        print = function(...) end,
        -- os.sleep 让出当前协程(调度器据此切换进程), 模拟内核按事件驱动恢复。
        os = setmetatable({ sleep = function() coroutine.yield() end }, { __index = REAL_G.os or {} }),
    }, { __index = REAL_G })
    if argv then
        env.argv = argv
        env.arg0 = argv[0] or ""
        for i = 1, #argv do env.args[i] = argv[i] end
        env.argc = #argv
    end
    env.spawn = function(s, n, cu, cg, ca, co) return spawn(s, n, pid, cu, cg, ca, co) end
    env._G = env
    -- Lua 5.1: load 收函数, loadstring 收字符串; 5.2: load 亦可收字符串。统一用 compat。
    local loadcompat = _G.load
    local chunk, lerr
    if _VERSION == "Lua 5.1" then
        chunk, lerr = loadstring(src, name or ("proc" .. pid))
        if chunk then setfenv(chunk, env) end
    else
        chunk, lerr = loadcompat(src, name or ("proc" .. pid), "t", env)
    end
    if not chunk then
        procs[pid] = { pid = pid, name = name, status = "error", error = lerr, exitCode = 1 }
        return nil, "load failed: " .. tostring(lerr)
    end
    -- 进程组/会话: 子进程继承父进程的 pgrp/sid(与内核 process.spawn 一致)。
    local pgrp = parent and parent.pgrp or pid
    local sid = parent and parent.sid or 0
    procs[pid] = { pid = pid, name = name, status = "running", exitCode = 0, stdio = stdio,
                   pgrp = pgrp, sid = sid, handlers = {}, envvars = envvars }
    running[#running + 1] = { pid = pid, co = coroutine.create(chunk) }
    return pid
end

-- 进程退出时释放其 stdio 管道端(与内核 process.onExit 一致), 使下游读到 EOF。
-- 只关带 .pipe 标记的句柄, 避免误关宿主 stdout 文件句柄。
local function closeProcPipes(pid)
    local stdio = procs[pid] and procs[pid].stdio
    if not stdio then return end
    if stdio.output and stdio.output.pipe and stdio.output.close then pcall(stdio.output.close) end
    if stdio.input  and stdio.input.pipe  and stdio.input.close  then pcall(stdio.input.close)  end
end

-- 协作式调度器: 轮流 resume 每个未退出进程; 进程 yield(os.sleep)则让位, 下轮再恢复。
-- 被信号杀死/停止的进程(procs[pid].status)不再被 resume —— 对应内核调度器的信号投递。
-- 只剩 stopped 进程时结束调度(宿主无事件循环, 停住的作业被遗弃; 真机由 SIGCONT/fg 恢复)。
local function schedulerRun()
    while true do
        local anyAlive = false
        for _, pr in ipairs(running) do
            local p = procs[pr.pid]
            if p.status == "running" then
                anyAlive = true
                curPid = pr.pid
                local ok, res = coroutine.resume(pr.co)
                curPid = nil
                if not ok then
                    p.status = "error"; p.error = res; p.exitCode = 1
                    io.stderr:write("[harness] " .. (p.name or pr.pid) .. " error: " .. tostring(res) .. "\n")
                    closeProcPipes(pr.pid)
                elseif coroutine.status(pr.co) == "dead" then
                    p.status = "dead"
                    -- 协程返回值即退出码(与内核 process.onExit 一致)。
                    if type(res) == "number" then p.exitCode = res end
                    closeProcPipes(pr.pid)
                end
            end
        end
        if not anyAlive then break end
    end
end

-- ---------------------------------------------------------------
-- 构建 ROOT
-- ---------------------------------------------------------------
local SRCBIN = "/home/worker/delin/src/bin"
local function setupRoot()
    os.execute("rm -rf " .. ROOT .. " && mkdir -p " .. ROOT)
    os.execute("mkdir -p " .. ROOT .. "/bin " .. ROOT .. "/etc " .. ROOT .. "/home/alice " .. ROOT .. "/root " .. ROOT .. "/tmp " .. ROOT .. "/mnt/cc")
    for _, f in ipairs({ "cat","cp","ed","grep","head","kill","login","ls","mkdir","mv","rm","sed","sh","sleep","tail","touch","wc","chmod","chown","mount","umount","blkid","lsblk","lp" }) do
        os.execute("cp -f " .. SRCBIN .. "/" .. f .. " " .. ROOT .. "/bin/" .. f)
        os.execute("chmod 755 " .. ROOT .. "/bin/" .. f)
    end
    -- 用户库
    users = {
        root  = { name = "root",  uid = 0,    gid = 0,    home = "/root",  shell = "/bin/sh" },
        alice = { name = "alice", uid = 1000, gid = 1000, home = "/home/alice", shell = "/bin/sh" },
    }
    groups = {
        root  = { gid = 0,    members = "root" },
        alice = { gid = 1000, members = "alice" },
    }
    local pw = "root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000:alice:/home/alice:/bin/sh\n"
    local gr = "root:x:0:root\nalice:x:1000:alice\n"
    local sh = "root:$1$root$abc\n"
    local function w(path, s) local f = assert(io.open(ROOT .. path, "w")); f:write(s); f:close() end
    w("/etc/passwd", pw); w("/etc/group", gr); w("/etc/shadow", sh)
    w("/etc/hostname", "delin-host\n")
    w("/pub", "public data\n"); w("/secret", "top secret content\n"); w("/readonly", "ro\n")
    w("/home/alice/x.txt", "alice file\n")
    -- /dev 占位
    os.execute("mkdir -p " .. ROOT .. "/dev " .. ROOT .. "/proc " .. ROOT .. "/sys/class/display")
    os.execute("touch " .. ROOT .. "/dev/null " .. ROOT .. "/dev/lp0") -- 占位(打开走设备桩, 使 ls /dev 一致)
    os.execute("mkdir -p " .. ROOT .. "/lib/modules/0.0.2")
end

-- ---------------------------------------------------------------
-- /sys: 用真实内核 sysfs 后端(src/kernel/sysfs.lua)取代宿主目录,
-- 让 `cat /sys/class/display/top/name` 这类命令在宿主上得到与真机一致的行为。
-- 显示设备用一个桩(kernel.display 只被 sysfs 用于 list/get/byName/resize)。
-- ---------------------------------------------------------------
package.path = "/home/worker/delin/src/?.lua;" .. package.path
local sysfsDev = {
    id = "monitor:top", type = "monitor", mode = "term", name = "top",
    getSize = function() return 51, 19 end,
}
package.loaded["kernel.display"] = {
    list = function() return { sysfsDev.id } end,
    get = function(id) return id == sysfsDev.id and sysfsDev or nil end,
    byName = function(n) return n == "top" and sysfsDev or nil end,
    resize = function() return true end,
}
local vfs = require("kernel.vfs")
require("kernel.sysfs").mount()

--- /sys 下的路径走 sysfs 后端, 其余仍走宿主文件。
local function sysfsFor(p)
    p = norm(p)
    if p ~= "/sys" and p:sub(1, 5) ~= "/sys/" then return nil end
    return vfs.resolve(p)
end

local hostList, hostExists, hostIsDir, hostIsFile = F.list, F.exists, F.isDir, F.isFile
local hostAttrs, hostSize, hostReadOnly, hostOpen = F.attributes, F.getSize, F.isReadOnly, F.open
function F.list(p)
    local b, r = sysfsFor(p)
    if b then return b.list(r) end
    return hostList(p)
end
function F.exists(p)
    local b, r = sysfsFor(p)
    if b then return b.exists(r) end
    return hostExists(p)
end
function F.isDir(p)
    local b, r = sysfsFor(p)
    if b then return b.isDir(r) end
    return hostIsDir(p)
end
function F.isFile(p)
    local b, r = sysfsFor(p)
    if b then return b.exists(r) and not b.isDir(r) end
    return hostIsFile(p)
end
function F.attributes(p)
    local b, r = sysfsFor(p)
    if b then
        local a = b.attributes(r)
        if a then a.uid, a.gid, a.mode = 0, 0, a.isDir and tonumber("40555", 8) or tonumber("100444", 8) end
        return a
    end
    return hostAttrs(p)
end
function F.getSize(p)
    local b, r = sysfsFor(p)
    if b then return b.getSize(r) end
    return hostSize(p)
end
function F.isReadOnly(p)
    local b, r = sysfsFor(p)
    if b then return b.isReadOnly(r) end
    return hostReadOnly(p)
end
function F.open(p, mode)
    local b, r = sysfsFor(p)
    if b then return b.open(r, mode or "r") end
    return hostOpen(p, mode)
end

setupRoot()

-- ---------------------------------------------------------------
-- 桩 printer: /dev/lp0 的写入落到 ROOT/printer.out, /sys/class/printer/lp0 提供状态与可写标题。
-- 让 /bin/lp 在宿主上跑完整路径(ccprinter 内核驱动的分页逻辑由 tools/hosttest.lua 单测)。
-- ---------------------------------------------------------------
local printerOut = assert(io.open(ROOT .. "/printer.out", "w"))
local printerTitle = ""
require("kernel.sysfs").registerClass("printer", {
    list = function() return { "lp0" } end,
    attrs = function(e)
        if e ~= "lp0" then return nil end
        return { "name", "type", "size", "paper", "ink", "title" }
    end,
    writable = function(_, a) return a == "title" end,
    get = function(e, a)
        if e ~= "lp0" then return nil end
        if a == "name" then return "top" end
        if a == "type" then return "printer" end
        if a == "size" then return "25x21" end
        if a == "paper" then return "10" end
        if a == "ink" then return "10" end
        if a == "title" then return printerTitle end
        return nil
    end,
    set = function(e, a, v)
        if e ~= "lp0" then return nil, "no such printer: " .. tostring(e) end
        if a ~= "title" then return nil, "read-only attribute: " .. tostring(a) end
        printerTitle = v
        local tf = io.open(ROOT .. "/printer.title", "w")
        tf:write(v)
        tf:close()
        return true
    end,
})
local LP_HANDLE = {
    write = function(_, s) printerOut:write(s); return #tostring(s) end,
    writeLine = function(_, s) printerOut:write(s .. "\n"); return #tostring(s) + 1 end,
    flush = function() return true end,
    close = function() printerOut:close(); return true end,
    read = function() return nil end,
    readLine = function() return nil end,
}
local openBeforeLp = F.open
function F.open(p, mode)
    if norm(p) == "/dev/lp0" then
        if mode and (mode:find("w") or mode:find("a")) then return LP_HANDLE end
        return nil, "write-only device: /dev/lp0"
    end
    return openBeforeLp(p, mode)
end

-- ---------------------------------------------------------------
-- 运行工具: 顶层进程。argv[0] = 工具名(参数1), args = 其余。
-- ---------------------------------------------------------------
local argsIn = {}
for i = 1, #arg do argsIn[i] = arg[i] end
local toolPath = argsIn[1] or "/bin/sh"
local toolArgs = {}
for i = 2, #argsIn do toolArgs[#toolArgs + 1] = argsIn[i] end

-- 读 stdin(作为脚本内容)
local stdinBuf = {}
for line in io.lines() do stdinBuf[#stdinBuf + 1] = line end
local li = 0
-- DELIN_HARNESS_TTY=1: 把 stdin 伪装成终端, 让 sh 走交互式分支(测 PS1/PS2 提示符)。
local ttyMode = os.getenv("DELIN_HARNESS_TTY") == "1"
local inputHandle = { isTTY = ttyMode, readLine = function() li = li + 1; return stdinBuf[li] end }
inputHandle.read = function() end

local outputHandle = Handle.new(io.stdout, "<stdout>")

curStdio = { input = inputHandle, output = outputHandle }

local tsrc = F.open(toolPath, "r")
if not tsrc then
    io.stderr:write("harness: cannot read " .. toolPath .. "\n")
    os.exit(1)
end
local src = tsrc:readAll(); tsrc:close()

local argv0 = { [0] = toolPath }
for i = 1, #toolArgs do argv0[i] = toolArgs[i] end
local topPid = spawn(src, toolPath, nil, nil, nil, argv0, { cwd = "/" })

-- 运行协作式调度器, 驱动顶层进程及其 spawn 出的子进程(管道/作业控制)。
schedulerRun()

-- flush
io.stdout:flush()
-- 顶层进程的退出码 = 工具的退出码(与内核一致), 便于脚本按 $? 断言。
local top = procs[topPid]
os.exit((top and top.exitCode) or 0)
