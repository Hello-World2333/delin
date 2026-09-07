--[[ Delin process model.
     - 进程表 + 进程树 (pid/ppid/status/children)
     - 每个进程一个隔离 _ENV (load(src, name, "t", env))
     - spawn 只收源码字符串(不收闭包/路径); 读文件由程序自己做
     - 内核自供 print (CC 自带 print 不走 io.stdout)
     - 父死子并入 init (pid 1)
     - 信号机制: 进程信号状态 + 会话(session)/进程组(pgrp) + kill/killpg/自定 handler。
       调度器在 resume 前经 scheduler.setSignalCheck 调用 applySignals 投递信号。 ]]

local signal    = require("kernel.signal")
local scheduler = require("kernel.scheduler")
local vfs_api   = require("kernel.vfs_api")
local modules   = require("kernel.modules")

local process = {}

process.next_pid = 0
process.log = nil        -- boot 注入: fun(...)  受控 print
local registry = {}      -- pid -> proc
local children = {}      -- pid -> set of child pids

-- 会话/进程组表 (POSIX 作业控制).
--   sessions[sid] = { sid, leader, ctty, fgPgrp }
--   cttyOwners[ttyName] = sid   (一个 tty 至多属于一个会话)
local sessions = {}
local cttyOwners = {}

---@class DelinProcess
---@field pid integer
---@field ppid integer
---@field name string
---@field co thread
---@field status string   -- running|stopped|dead|error
---@field exitCode any
---@field termSig integer|nil  -- 被信号杀死时的信号号
---@field pgrp integer
---@field sid integer
---@field sig table

local function kprint(...)
    if process.log then process.log(...) else print(...) end
end

local function nextPid()
    process.next_pid = process.next_pid + 1
    return process.next_pid
end

--- 构造进程隔离环境。
---@param pid integer
---@param ppid integer
---@param uid integer|nil
---@param gid integer|nil
---@param argv table|nil  参数表 { [0]=程序名, [1..]=位置参数 } (可缺省)
---@param opts table|nil  选项 { cwd= } (可缺省, 缺省继承父进程 cwd 或 "/")
---@return table
local function buildEnv(pid, ppid, uid, gid, argv, opts)
    -- argv 约定: [0]=程序名/[1..]=位置参数。args = 只含位置参数(不含 [0]).
    argv = argv or {}
    opts = opts or {}
    local args = {}
    for i = 1, #argv do args[i] = argv[i] end
    -- 继承父进程 cwd(或默认 "/")。调用方(sh)用 opts.cwd 传自己的当前目录。
    local parentCwd = registry[ppid] and registry[ppid].cwd or "/"
    ---@type table
    local env = setmetatable({
        pid   = pid,
        ppid  = ppid,
        uid   = uid or 0,
        gid   = gid or 0,
        cwd   = opts.cwd or parentCwd or "/",
        argv  = argv,
        args  = args,
        argc  = #args,
        arg0  = argv[0] or args[1] or "",
        print = kprint,
        spawn = function(src, name, childUid, childGid, childArgv, childOpts)
            return process.spawn(src, name, pid, childUid, childGid, childArgv, childOpts)
        end,
    }, { __index = _G })
    vfs_api.installForEnv(env) -- 替换 fs/io 为 VFS
    modules.applyToEnv(env)    -- 注入 syscalls 表
    env._G = env -- 子进程的 _G 是自己的环境(隔离)
    return env
end

local function newSigState()
    return {
        pending  = {},   -- sigNo -> true
        handlers = {},   -- sigNo -> fun|nil
        stopped  = false,
        stopSig  = nil,
        termSig  = nil,
    }
end

local function addChild(ppid, pid)
    if not children[ppid] then children[ppid] = {} end
    children[ppid][pid] = true
end

local function reparentOrphans(pid)
    local kids = children[pid]
    if not kids then return end
    -- 并入 init(pid 1) 名下; 若进程本身是 init,孩子们保持挂其下(无害)。
    if not children[1] then children[1] = {} end
    for child in pairs(kids) do
        local c = registry[child]
        if c then c.ppid = 1 end
        children[1][child] = true
    end
    children[pid] = nil
end

--- 启动一个进程(源码字符串)。
---@param src string        源码字符串(非闭包/路径)
---@param name string|nil   进程名(调试用)
---@param ppid integer|nil  父进程 pid(默认 0)
---@param uid integer|nil   uid(默认继承父/0)
---@param gid integer|nil   gid(默认继承父/0)
---@param argv table|nil    参数表 { [0]=程序名, [1..]=位置参数 } (可缺省)
---@param opts table|nil    选项 { cwd=, stdio={input=,output=} } (可缺省)
---@return integer|nil pid, table|nil proc, string|nil err
function process.spawn(src, name, ppid, uid, gid, argv, opts)
    ppid = ppid or 0
    if type(src) ~= "string" then
        return nil, nil, "spawn expects a source string, got " .. type(src)
    end

    -- 继承父进程 uid/gid
    local parent = registry[ppid]
    uid = uid or (parent and parent.uid) or 0
    gid = gid or (parent and parent.gid) or 0

    local pid = nextPid()
    -- 会话/进程组: 子进程继承父进程的 pgrp/sid(或内核会话 0)。
    -- 内核会话(pid 1)自成一组成员: pgrp = 自身 pid。
    local sid, pgrp
    if parent then
        sid = parent.sid or 0
        pgrp = parent.pgrp or parent.pid
    else
        sid = 0
        pgrp = pid
    end
    local env = buildEnv(pid, ppid, uid, gid, argv, opts)

    -- 继承父进程 stdio(或 boot 默认终端)。每个进程独立 stdio, 子进程在 spawn 时刻
    -- 继承父进程当前的 stdin/stdout, 之后各自变化互不影响。
    -- 子进程 stdio: 默认继承父进程(或 boot 默认终端); 调用方可用 opts.stdio 显式覆盖
    -- (shell 重定向: 把子进程的 stdin/stdout 指向文件)。每个进程 stdio 彼此独立。
    local parentProc = registry[ppid]
    local want = opts and opts.stdio
    if want then
        env.__stdio.input  = want.input
        env.__stdio.output = want.output
    else
        local inherit = (parentProc and parentProc.stdio) or vfs_api.getStdio()
        if inherit then
            env.__stdio.input = inherit.input
            env.__stdio.output = inherit.output
        end
    end

    local chunk, loadErr = load(src, name or ("proc#" .. pid), "t", env)
    if not chunk then
        return nil, nil, "load failed: " .. tostring(loadErr)
    end

    local co = coroutine.create(chunk)
    ---@type DelinProcess
    local proc = {
        pid = pid, ppid = ppid, name = name or ("proc#" .. pid),
        co = co, status = "running", exitCode = nil, termSig = nil,
        uid = uid, gid = gid,
        cwd = env.cwd,
        stdio = env.__stdio,
        pgrp = pgrp, sid = sid,
        sig = newSigState(),
    }

    -- onExit: 更新 registry 里的规范 proc 表(status/exitCode), 不是调度器的临时 proc 对象。
    -- 否则 process.info(pid) 永远看到 status="running", proc.wait 无法感知子进程退出。
    proc.onExit = function(_, status, err)
        proc.status = status
        proc.exitCode = (status == "dead") and 0 or nil
        if status == "error" then
            proc.error = err
            if process.log then pcall(process.log, "[proc " .. pid .. " " .. tostring(name) .. "] ERROR: " .. tostring(err)) end
        end
        reparentOrphans(pid)
    end

    registry[pid] = proc
    addChild(ppid, pid)

    scheduler.addProcess({
        pid = pid, co = co, name = proc.name,
        started = false, filter = nil, dead = false,
        status = "running", onExit = proc.onExit,
        sig = proc.sig, canonical = proc,
    })

    return pid, proc, nil
end

--- 取进程信息。
---@param pid integer
---@return DelinProcess|nil
function process.info(pid)
    return registry[pid]
end

--- 当前进程的 {pid, uid, gid}。通过 coroutine.running() 查进程表。
---@return table
function process.current()
    local co = coroutine.running()
    if not co then return { pid = 0, uid = 0, gid = 0 } end -- 内核/主线程 -> root
    for pid, p in pairs(registry) do
        if p.co == co then return { pid = pid, uid = p.uid, gid = p.gid } end
    end
    return { pid = 0, uid = 0, gid = 0 }
end

--- 当前进程的 pgrp/sid(供 sh 作业控制查询)。
---@return integer|nil pgrp, integer|nil sid
function process.currentGroup()
    local cur = process.current()
    local p = registry[cur.pid]
    if not p then return nil, nil end
    return p.pgrp, p.sid
end

--- 设置当前进程的 stdio(进程侧 stdin/stdout 重定向)。
---@param input table|nil
---@param output table|nil
---@return boolean
function process.setStdio(input, output)
    local cur = process.current()
    local p = registry[cur.pid]
    if not p or not p.stdio then return false end
    p.stdio.input = input
    p.stdio.output = output
    return true
end

-- ---------------------------------------------------------------
-- 信号
-- ---------------------------------------------------------------
--- 发送信号到单个进程(权限: root 或同 uid)。
---@param pid integer
---@param sig integer
---@return boolean, string|nil
function process.kill(pid, sig)
    local p = registry[pid]
    if not p then return nil, "no such process: " .. tostring(pid) end
    local cur = process.current()
    if cur.uid ~= 0 and cur.uid ~= p.uid then return nil, "permission denied" end
    p.sig.pending[sig] = true
    return true
end

--- 发送信号到某个进程组。
---@param pgid integer
---@param sig integer
---@return integer|nil count, string|nil err (count 为收到信号的进程数)
function process.signalGroup(pgid, sig)
    local leader = registry[pgid]
    if not leader then return nil, "no such process group: " .. tostring(pgid) end
    local cur = process.current()
    if cur.uid ~= 0 and cur.uid ~= leader.uid then return nil, "permission denied" end
    local n = 0
    for _, p in pairs(registry) do
        if p.pgrp == pgid then
            p.sig.pending[sig] = true
            n = n + 1
        end
    end
    if n == 0 then return nil, "no such process group" end
    return n
end

--- 安装/清除当前进程的信号处理器(不可捕获的返回错误)。
---@param sig integer
---@param fn function|nil   nil 恢复默认动作
---@return boolean, string|nil
function process.setHandler(sig, fn)
    if not signal.catchable(sig) then return nil, "uncatchable signal: " .. signal.name(sig) end
    local cur = process.current()
    local p = registry[cur.pid]
    if not p then return nil, "no current process" end
    p.sig.handlers[sig] = fn
    return true
end

--- 创建新会话(当前进程成为会话首进程, 其 pgrp = 自身 pid)。
---@return integer|nil sid, string|nil err
function process.setsid()
    local cur = process.current()
    local p = registry[cur.pid]
    if not p then return nil, "no current process" end
    if p.pgrp == p.pid then return nil, "setsid: already a process group leader" end
    local sid = p.pid
    p.sid = sid
    p.pgrp = sid
    sessions[sid] = { sid = sid, leader = p.pid, ctty = nil, fgPgrp = sid }
    return sid
end

--- 设置进程组(仅同会话内; 会话首进程不可移动)。
---@param pid integer
---@param pgid integer  0 => 自成一个新组(pgid = pid)
---@return boolean, string|nil
function process.setpgid(pid, pgid)
    local p = registry[pid]
    if not p then return nil, "no such process: " .. tostring(pid) end
    if p.pid == p.sid then return nil, "setpgid: session leader" end
    local cur = process.current()
    local caller = registry[cur.pid]
    if caller.sid ~= p.sid then return nil, "setpgid: cross-session" end
    if pgid == 0 or pgid == nil then pgid = p.pid end
    p.pgrp = pgid
    return true
end

--- 设置/关联会话的前台进程组。若该 tty 尚无归属会话, 以调用者的会话收养之(login 场景)。
---@param ttyName string
---@param pgid integer  0 => 调用者自身 pgrp
---@return boolean, string|nil
function process.tcsetpgrp(ttyName, pgid)
    local cur = process.current()
    local caller = registry[cur.pid]
    local sid = cttyOwners[ttyName]
    if not sid then
        if not caller then return nil, "tcsetpgrp: no current process" end
        sid = caller.sid
        if not sid or sid == 0 then return nil, "tcsetpgrp: no session" end
        sessions[sid].ctty = ttyName
        cttyOwners[ttyName] = sid
    end
    local sess = sessions[sid]
    if not sess then return nil, "tcsetpgrp: no session" end
    if not pgid or pgid == 0 then pgid = cur.pid end
    -- pgid 必须属于该会话
    local found = false
    for _, p in pairs(registry) do
        if p.pgrp == pgid and p.sid == sid then found = true; break end
    end
    if not found then return nil, "tcsetpgrp: not a process group in session" end
    sess.fgPgrp = pgid
    return true
end

--- 取 tty 当前的前台进程组。
---@param ttyName string
---@return integer|nil
function process.tcgetpgrp(ttyName)
    local sid = cttyOwners[ttyName]
    if not sid then return nil end
    local sess = sessions[sid]
    if not sess then return nil end
    return sess.fgPgrp
end

--- 某 tty 归属的会话 id(供 tty ^C 查找前台组)。
---@param ttyName string
---@return integer|nil
function process.sessionForTty(ttyName)
    return cttyOwners[ttyName]
end

--- 调度器在 resume 前投递信号。返回 "run"|"stop"|"dead"。
---   投递规则(fail-fast, 不防御性回退):
---     SIGCONT  -> 恢复 stopped
---     SIGKILL  -> 一律终止
---     SIGSTOP  -> 一律停止
---     其余带 handler 的 -> 现在运行 handler(进程闭包, 携带自身 _ENV)
---     其余默认 term -> 终止; 默认 stop -> 停止; 默认 ign -> 丢弃
---@param p table 调度器进程对象(含 .sig/.canonical)
---@return string
function process.applySignals(p)
    local sig = p.sig
    if not sig then return "run" end

    local pending = sig.pending
    if sig.stopped and next(pending) == nil then return "stop" end
    if next(pending) == nil then return "run" end

    -- 数字序处理, 保证确定性
    local list = {}
    for s in pairs(pending) do list[#list + 1] = s end
    table.sort(list)

    local dead = false
    for _, s in ipairs(list) do
        if dead then break end
        if s == signal.SIGCONT then
            if sig.stopped then
                sig.stopped = false
                sig.stopSig = nil
                if p.canonical then p.canonical.status = "running" end
            end
            pending[s] = nil
        elseif s == signal.SIGKILL then
            sig.termSig = s
            if p.canonical then p.canonical.termSig = s end
            dead = true
            pending[s] = nil
        elseif s == signal.SIGSTOP then
            if not sig.stopped then
                sig.stopped = true
                sig.stopSig = s
                if p.canonical then p.canonical.status = "stopped" end
            end
            pending[s] = nil
        else
            local h = sig.handlers[s]
            if h then
                pending[s] = nil
                local ok, err = pcall(h, s)
                if not ok then
                    -- handler 出错: 视为进程故障终止(隔离, 不让内核调度器崩)。
                    sig.termSig = s
                    if p.canonical then p.canonical.termSig = s; p.canonical.status = "error"; p.canonical.error = err end
                    dead = true
                end
            else
                local act = signal.defaultAction(s)
                if act == "term" then
                    sig.termSig = s
                    if p.canonical then p.canonical.termSig = s end
                    dead = true
                    pending[s] = nil
                elseif act == "stop" then
                    if not sig.stopped then
                        sig.stopped = true
                        sig.stopSig = s
                        if p.canonical then p.canonical.status = "stopped" end
                    end
                    pending[s] = nil
                elseif act == "cont" then
                    -- SIGCONT 之外不出现 cont 默认; 安全丢弃
                    pending[s] = nil
                else -- ign
                    pending[s] = nil
                end
            end
        end
    end

    if dead then return "dead" end
    if sig.stopped then return "stop" end
    return "run"
end

--- 打印进程树(调试/验证用)。
---@return string
function process.dumpTree()
    local lines = {}
    local function rec(pid, depth)
        local proc = registry[pid]
        if not proc then return end
        lines[#lines + 1] = string.rep("  ", depth)
            .. string.format("#%d %s (ppid=%d, %s, pgrp=%d, sid=%d, sig=%s)", pid,
                proc.name or "?", proc.ppid, proc.status or "?", proc.pgrp or 0,
                proc.sid or 0, proc.termSig and signal.name(proc.termSig) or "-")
        local kids = children[pid]
        if kids then
            for child in pairs(kids) do rec(child, depth + 1) end
        end
    end
    rec(1, 0)
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------
-- 注册 syscalls (供进程/工具使用)
-- ---------------------------------------------------------------
local sc = modules.syscalls()
sc["signal.kill"]   = function(pid, sig) return process.kill(pid, sig) end
sc["signal.killpg"] = function(pgid, sig) return process.signalGroup(pgid, sig) end
sc["signal.install"] = function(sig, fn) return process.setHandler(sig, fn) end
sc["signal.list"]   = function() return signal.listNumbers() end
sc["signal.name"]   = function(sig) return signal.name(sig) end
sc["signal.number"] = function(name) return signal.number(name) end
sc["sig.name"]      = function(sig) return signal.name(sig) end
sc["sig.list"]      = function() return signal.listNumbers() end
sc["sig.number"]    = function(name) return signal.number(name) end

sc["job.setsid"]    = function() return process.setsid() end
sc["job.setpgid"]   = function(pid, pgid) return process.setpgid(pid, pgid) end
sc["job.tcsetpgrp"] = function(ttyName, pgid) return process.tcsetpgrp(ttyName, pgid) end
sc["job.tcgetpgrp"] = function(ttyName) return process.tcgetpgrp(ttyName) end
sc["job.group"]     = function() return process.currentGroup() end
sc["job.sessfor"]   = function(ttyName) return process.sessionForTty(ttyName) end

-- 调度器在 resume 前经此投递信号。
scheduler.setSignalCheck(process.applySignals)

return process
