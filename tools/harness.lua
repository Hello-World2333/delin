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
    local n, sz, mode = norm(p), F.getSize(p), "0644"
    if F.isDir(p) then mode = "040755" end
    return { size = sz, isDir = F.isDir(p), mode = tonumber(mode, 8), name = n:match("[^/]+$") or "", uid = 0, gid = 0 }
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

-- io.open 落在 F.open / fs.open
function F.open(p, mode)
    p = norm(p)
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
local users = {}
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
            return (p.status == "error" and 1) or (p.exitCode or 0)
        end
        os.sleep(0.01)
    end
end
syscalls["pipe.create"] = function() return pipeCreate() end
syscalls["signal.list"] = function() return { 1, 2, 3, 9, 15 } end
syscalls["signal.name"] = function(n) return ({ [1]="HUP", [2]="INT", [3]="QUIT", [9]="KILL", [15]="TERM" })[n] or "?" end
syscalls["signal.number"] = function(name) return ({ ["HUP"]=1, ["INT"]=2, ["QUIT"]=3, ["KILL"]=9, ["TERM"]=15 })[name] end
syscalls["signal.kill"] = function() return true end
syscalls["signal.killpg"] = function() return 1 end
syscalls["signal.install"] = function() return true end
syscalls["job.group"] = function() return 0 end
syscalls["job.setpgid"] = function() return true end
syscalls["job.setsid"] = function() return 0 end
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
syscalls["user.register"] = function() end

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
    local env = setmetatable({
        pid = pid, ppid = ppid or 0, uid = uid or 0, gid = gid or 0,
        cwd = (opts and opts.cwd) or "/",
        argv = argv or {}, args = {}, argc = 0, arg0 = "",
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
    procs[pid] = { pid = pid, name = name, status = "running", exitCode = 0, stdio = stdio }
    running[#running + 1] = { pid = pid, co = coroutine.create(chunk), status = "running" }
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
local function schedulerRun()
    while true do
        local anyAlive = false
        for _, pr in ipairs(running) do
            if pr.status ~= "dead" and pr.status ~= "error" then
                anyAlive = true
                local ok, err = coroutine.resume(pr.co)
                if not ok then
                    pr.status = "error"
                    procs[pr.pid].status = "error"; procs[pr.pid].error = err; procs[pr.pid].exitCode = 1
                    io.stderr:write("[harness] " .. (procs[pr.pid].name or pr.pid) .. " error: " .. tostring(err) .. "\n")
                    closeProcPipes(pr.pid)
                elseif coroutine.status(pr.co) == "dead" then
                    pr.status = "dead"
                    procs[pr.pid].status = "dead"
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
    os.execute("mkdir -p " .. ROOT .. "/bin " .. ROOT .. "/etc " .. ROOT .. "/home/alice " .. ROOT .. "/root " .. ROOT .. "/tmp")
    for _, f in ipairs({ "cat","cp","grep","head","kill","login","ls","mkdir","mv","rm","sed","sh","tail","touch","wc" }) do
        os.execute("cp -f " .. SRCBIN .. "/" .. f .. " " .. ROOT .. "/bin/" .. f)
        os.execute("chmod 755 " .. ROOT .. "/bin/" .. f)
    end
    -- 用户库
    users = {
        root  = { name = "root",  uid = 0,    gid = 0,    home = "/root",  shell = "/bin/sh" },
        alice = { name = "alice", uid = 1000, gid = 1000, home = "/home/alice", shell = "/bin/sh" },
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
    os.execute("mkdir -p " .. ROOT .. "/lib/modules/0.0.2")
end

setupRoot()

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
local inputHandle = { isTTY = false, readLine = function() li = li + 1; return stdinBuf[li] end }
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
spawn(src, toolPath, nil, nil, nil, argv0, { cwd = "/" })

-- 运行协作式调度器, 驱动顶层进程及其 spawn 出的子进程(管道/作业控制)。
schedulerRun()

-- flush
io.stdout:flush()
