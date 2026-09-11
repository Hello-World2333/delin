--[[ Delin process model.
     - 进程表 + 进程树 (pid/ppid/status/children)
     - 每个进程一个隔离 _ENV (load(src, name, "t", env))
     - env 是白名单环境(kernel/procenv.lua): CC 原生 fs/模块/事件/电源渠道一律不给
     - spawn 只收源码字符串(不收闭包/路径); 读文件由程序自己做
     - 内核自供 print (CC 自带 print 不走 io.stdout)
     - 父死子并入 init (pid 1)
     - 信号机制: 进程信号状态 + 会话(session)/进程组(pgrp) + kill/killpg/自定 handler。
       调度器在 resume 前经 scheduler.setSignalCheck 调用 applySignals 投递信号。 ]]

local signal    = require("kernel.signal")
local scheduler = require("kernel.scheduler")
local tty       = require("kernel.tty")
local vfs_api   = require("kernel.vfs_api")
local modules   = require("kernel.modules")
local procenv   = require("kernel.procenv")

local process = {}

process.next_pid = 0
process.log = nil        -- boot 注入: fun(...)  受控 print
local registry = {}      -- pid -> proc
local children = {}      -- pid -> set of child pids
local coPid = {}         -- coroutine -> pid (process.current() 的 O(1) 反查)

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
---@param opts table|nil  选项 { cwd=, env={NAME=value} } (可缺省, 缺省继承父进程 cwd 或 "/")
---@return table
local function buildEnv(pid, ppid, uid, gid, argv, opts)
    -- argv 约定: [0]=程序名/[1..]=位置参数。args = 只含位置参数(不含 [0]).
    argv = argv or {}
    opts = opts or {}
    local args = {}
    for i = 1, #argv do args[i] = argv[i] end
    -- 继承父进程 cwd(或默认 "/")。调用方(sh)用 opts.cwd 传自己的当前目录。
    local parentCwd = registry[ppid] and registry[ppid].cwd or "/"
    -- 环境块: 子进程继承父进程导出的变量, opts.env 覆盖/追加(值为 nil 即删除)。
    local envvars = {}
    local parentEnvProc = registry[ppid]
    if parentEnvProc and parentEnvProc.envvars then
        for k, v in pairs(parentEnvProc.envvars) do envvars[k] = v end
    end
    if opts.env then
        for k, v in pairs(opts.env) do
            if v == nil then envvars[k] = nil else envvars[k] = tostring(v) end
        end
    end
    ---@type table
    local env = {
        pid   = pid,
        ppid  = ppid,
        uid   = uid or 0,
        gid   = gid or 0,
        cwd   = opts.cwd or parentCwd or "/",
        argv  = argv,
        args  = args,
        argc  = #args,
        arg0  = argv[0] or args[1] or "",
        -- 环境变量表(name -> string) + 查询函数: 进程读环境变量的接口(export 的落点)。
        env    = envvars,
        getenv = function(name) return envvars[name] end,
        print = kprint,
        spawn = function(src, name, childUid, childGid, childArgv, childOpts)
            return process.spawn(src, name, pid, childUid, childGid, childArgv, childOpts)
        end,
    }
    -- 白名单: 只把 procenv 列出的 CC/Lua 全局给进程(没有 __index=_G 兜底), 于是
    -- loadfile/dofile/os.run/require/settings/shell/disk/peripheral/os.pullEvent 等
    -- 绕过 Delin 接口的渠道在内核层一次关干净(见 kernel/procenv.lua 的说明)。
    procenv.apply(env)
    vfs_api.installForEnv(env) -- 替换 fs/io 为 VFS
    modules.applyToEnv(env)    -- 注入 syscalls 表
    env._G = env -- 子进程的 _G 是自己的环境(隔离)
    return env
end

local function newSigState()
    return {
        pending  = {},   -- sigNo -> true
        handlers = {},   -- sigNo -> fun|nil
        -- ignored: sigNo -> true, 被**显式忽略**的信号。与 Linux 一样, 这个状态跨 exec/spawn
        -- 继承给子进程(handler 不继承, 但"忽略"继承)—— nohup(1) 就是靠这条让 COMMAND 免疫
        -- SIGHUP 的。见 process.spawn 的 opts.sigIgnore 与 process.applySignals。
        ignored  = {},
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
    -- opts.ppid: 显式指定父进程(init 的服务引擎用它把服务挂到 PID 1 名下,
    -- 而不是发起 systemctl 的调用者名下)。
    if opts and opts.ppid then ppid = opts.ppid end
    ppid = ppid or 0
    if type(src) ~= "string" then
        return nil, nil, "spawn expects a source string, got " .. type(src)
    end

    -- 继承父进程 uid/gid
    local parent = registry[ppid]
    uid = uid or (parent and parent.uid) or 0
    gid = gid or (parent and parent.gid) or 0
    argv = argv or {} -- proc.argv 与 env.argv 共用同一张表(/proc/<pid>/cmdline 的数据源)

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
    coPid[co] = pid
    ---@type DelinProcess
    local proc = {
        pid = pid, ppid = ppid, name = name or ("proc#" .. pid),
        co = co, status = "running", exitCode = nil, termSig = nil,
        uid = uid, gid = gid,
        cwd = env.cwd,
        argv = argv,      -- [0]=程序名, [1..]=位置参数(/proc/<pid>/cmdline)
        envvars = env.env, -- 环境块(子进程 spawn 时继承)
        stdio = env.__stdio,
        pgrp = pgrp, sid = sid,
        -- 文件创建掩码(POSIX umask): 从父进程继承, 缺省 022。
        -- 由**内核在创建文件/目录时应用**(见 kernel/ext2.lua 的 applyUmask), 而不是让每个工具
        -- 自己去收窄权限 —— 那样只要有一个工具忘了就漏, 而且很容易把 umask 叠加两次。
        umask = (parentProc and parentProc.umask) or tonumber("022", 8),
        sig = newSigState(),
    }
    -- 被忽略的信号跨 spawn 继承(和 Linux 的 exec 一样): nohup 就靠这条让子命令免疫 SIGHUP。
    -- 调用方经 opts.sigIgnore = { [1] = true, ... } 传入(proc.exec 会原样透传 opts)。
    do
        local ign = opts and opts.sigIgnore
        local parentSig = parentProc and parentProc.sig
        if parentSig and parentSig.ignored then
            for s in pairs(parentSig.ignored) do proc.sig.ignored[s] = true end
        end
        if ign then for s in pairs(ign) do proc.sig.ignored[s] = true end end
    end

    -- onExit: 更新 registry 里的规范 proc 表(status/exitCode), 不是调度器的临时 proc 对象。
    -- 否则 process.info(pid) 永远看到 status="running", proc.wait 无法感知子进程退出。
    -- result 是协程的返回值: 数字即退出码(sh -c 'exit 3' -> 3), 其余(工具惯用的 "xx done")记 0。
    proc.onExit = function(_, status, err, result)
        proc.status = status
        proc.exitCode = (status == "dead") and ((type(result) == "number") and result or 0) or nil
        -- 释放进程持有的管道端: 只关带 .pipe 标记的句柄(管道端 close 递减 writer/reader
        -- 计数, 使对端读到 EOF 或在 broken pipe 时中止)。重定向的文件/设备句柄是父进程
        -- 打开后共享给子进程的, 子进程退出只让引用消失, 不该关掉父进程还在用的句柄
        -- (POSIX 语义; 否则父进程的句柄被误关, 且 close 会在内核上下文里跑)。
        if proc.stdio then
            local out, inp = proc.stdio.output, proc.stdio.input
            if out and out.pipe and out.close then pcall(out.close) end
            if inp and inp.pipe and inp.close then pcall(inp.close) end
        end
        if status == "error" then
            proc.error = err
            if process.log then pcall(process.log, "[proc " .. pid .. " " .. tostring(name) .. "] ERROR: " .. tostring(err)) end
        end
        -- 会话首进程退出: 释放其控制终端, 使新的会话(如下一个 login)能重新收养该 tty。
        if proc.sid == pid then
            local sess = sessions[proc.sid]
            if sess then
                if sess.ctty and cttyOwners[sess.ctty] == sess.sid then cttyOwners[sess.ctty] = nil end
                sessions[proc.sid] = nil
            end
        end
        reparentOrphans(pid)
        -- 子进程退出通知(init/PID 1 注册, 用于服务监督)。在调度器上下文中调用,
        -- 回调不得让出; 回调出错只记录, 不影响调度器。
        if process.onExit then
            local ok, herr = pcall(process.onExit, pid, status, proc.exitCode, proc.termSig)
            if not ok and process.log then process.log("[proc exit hook] " .. tostring(herr)) end
        end
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

--- 列出仍存活的进程(running|stopped), 按 pid 升序。
--- Delin 无 zombie 语义: 已退出(dead/error)的进程不进此表, 因此也不出现在 /proc 里
--- (Linux 保留 zombie 直到父进程 wait)。
---@return DelinProcess[]
function process.list()
    local out = {}
    for _, p in pairs(registry) do
        if p.status == "running" or p.status == "stopped" then out[#out + 1] = p end
    end
    table.sort(out, function(a, b) return a.pid < b.pid end)
    return out
end

--- 进程的控制终端名(如 "/dev/tty0"); 无控制终端返回 nil。
---@param pid integer
---@return string|nil
function process.ttyFor(pid)
    local p = registry[pid]
    if not p then return nil end
    local sess = sessions[p.sid]
    if not sess then return nil end
    return sess.ctty
end

--- 进程所在会话的前台进程组(供 /proc/<pid>/stat 的 tpgid 字段); 无则 nil。
---@param pid integer
---@return integer|nil
function process.fgPgrpFor(pid)
    local p = registry[pid]
    if not p then return nil end
    local sess = sessions[p.sid]
    if not sess then return nil end
    return sess.fgPgrp
end

--- 注册子进程退出钩子(init 用): fn(pid, status, exitCode, termSig)。
--- 在调度器上下文里同步调用, 不得让出。
function process.setExitHook(fn)
    process.onExit = fn
end

-- 内核特权凭据覆盖(按协程): syscall 在**自己完成授权**后, 需要以 root 身份落盘系统文件
-- (如 /etc/shadow)时用 process.asRoot 包一段代码 —— 等价于 setuid 程序(euid 0)。
local credOverride = {}

--- 当前进程的 {pid, uid, gid}。通过 coroutine.running() 查进程表。
---@return table
function process.current()
    local co = coroutine.running()
    local pid = co and coPid[co]
    local ov = co and credOverride[co]
    if ov then return { pid = pid or 0, uid = ov.uid, gid = ov.gid, umask = tonumber("022", 8) } end
    if not pid then return { pid = 0, uid = 0, gid = 0, umask = tonumber("022", 8) } end -- 内核/主线程 -> root
    local p = registry[pid]
    if not p then return { pid = 0, uid = 0, gid = 0, umask = tonumber("022", 8) } end
    return { pid = pid, uid = p.uid, gid = p.gid, umask = p.umask or tonumber("022", 8) }
end

--- 以 root 凭据运行 fn(仅限内核在**自行授权之后**写系统文件, 见 kernel/user.lua)。
--- 覆盖按协程记录, fn 返回/抛错都恢复; 调用者负责把错误往上抛(fail-fast)。
---@param fn function
function process.asRoot(fn)
    local co = coroutine.running()
    local prev = co and credOverride[co]
    if co then credOverride[co] = { uid = 0, gid = 0 } end
    local ok, a, b = pcall(fn)
    if co then credOverride[co] = prev end
    if not ok then error(a, 0) end
    return a, b
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
--- 安装信号处置。
---@param sig integer
---@param fn function|string "ignore" => SIG_IGN, "default" => SIG_DFL, 其余按处理函数
function process.setHandler(sig, fn)
    if not signal.catchable(sig) then return nil, "uncatchable signal: " .. signal.name(sig) end
    local cur = process.current()
    local p = registry[cur.pid]
    if not p then return nil, "no current process" end
    if fn == "ignore" then
        -- SIG_IGN: 与 Linux 一样, 这个处置会**跨 spawn 继承给子进程**(nohup 靠它)。
        p.sig.handlers[sig] = nil
        p.sig.ignored[sig] = true
        return true
    end
    if fn == "default" then
        p.sig.handlers[sig] = nil
        p.sig.ignored[sig] = nil
        return true
    end
    p.sig.ignored[sig] = nil
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

--- tty 读保护(POSIX SIGTTIN): 进程读自己的控制终端但不在前台进程组时, 投 SIGTTIN
--- 并返回 true 让 tty 阻塞该读。tty 无归属会话 / 不是该进程会话的控制终端 / 就在前台
--- 一律放行。
---@param ttyName string
---@return boolean
function process.checkTtyRead(ttyName)
    local cur = process.current()
    local p = registry[cur.pid]
    if not p then return false end
    local sid = cttyOwners[ttyName]
    if not sid then return false end
    if p.sid ~= sid then return false end
    local sess = sessions[sid]
    if not sess or not sess.fgPgrp then return false end
    if p.pgrp == sess.fgPgrp then return false end
    p.sig.pending[signal.SIGTTIN] = true
    return true
end

tty.readGuard = process.checkTtyRead

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
            if sig.ignored and sig.ignored[s] then
                -- 被显式忽略(或从父进程继承的忽略): POSIX 规定丢弃, 连停止/终止默认动作都不走。
                pending[s] = nil
            elseif h then
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

-- 文件创建掩码(POSIX umask)。内核在 create 时统一应用(见 kernel/ext2.lua 的 applyUmask),
-- 这两个 syscall 只是给 shell 的 `umask` 内建读写它 —— 与 Linux 一样, umask 是**进程属性**
-- 且被子进程继承(`umask 077; sh -c 'touch x'` 建出来的文件必须是 0600)。
sc["umask.get"] = function() return process.current().umask or tonumber("022", 8) end
sc["umask.set"] = function(mask)
    local cur = process.current()
    local p = registry[cur.pid]
    if not p then return nil, "umask: no such process" end
    if type(mask) ~= "number" or mask < 0 or mask > tonumber("777", 8) then
        return nil, "umask: mask out of range (0..0777)"
    end
    local old = p.umask or tonumber("022", 8)
    p.umask = math.floor(mask)
    return old
end

-- ---------------------------------------------------------------
-- proc.exec: 按 PATH 查找并启动一个程序(execvp 的最小实现)
-- ---------------------------------------------------------------
-- 为什么放内核里: 任何"我要起一个外部命令"的工具(xargs、nohup、sh 的 command 内建)都得做
-- 同一件事 —— 查 PATH、查 x 位、读文件、处理 shebang —— 而 spawn() 只收**源码字符串**,
-- 每个工具自己抄一遍这段逻辑既冗长又容易抄漏 shebang 的 `env` 特判。所以在这里收成一个口子。
-- 注意: 这是"起一个新进程", 不是 POSIX exec 的"替换当前进程映像"(Delin 没有那个语义)。
local function fsapi() return require("kernel.vfs_api").fs end

--- 按 PATH 查找可执行文件。名字里含 "/" 时按路径处理, 不做 PATH 搜索(POSIX 语义)。
---@param name string
---@param pathEnv string|nil
---@return string|nil
local function findInPath(name, pathEnv)
    if name:find("/", 1, true) then return name end
    for dir in tostring(pathEnv or "/bin"):gmatch("[^:]+") do
        local cand = (dir == "/" and "" or dir) .. "/" .. name
        if fsapi().exists(cand) then return cand end
    end
    return nil
end

--- 解析 shebang 行。返回解释器路径与"可选的一个参数"(POSIX 只保证一个参数)。
local function parseShebang(firstLine)
    if firstLine:sub(1, 2) ~= "#!" then return nil, nil end
    local rest = firstLine:sub(3):gsub("^[ \t]+", "")
    local interp = rest:match("^(%S+)")
    if not interp then return nil, nil end
    local arg = rest:match("^%S+[ \t]+(.-)[ \t]*$")
    return interp, arg
end

--- 读一个文件(经 VFS, 走进程的权限检查)。
local function readFile(path)
    local f, err = fsapi().open(path, "r")
    if not f then return nil, err end
    local s = f.readAll() or ""
    f.close()
    return s
end

--- 按 PATH 查找并启动一个程序(不等待)。返回子进程 pid。
---@param cmd string 命令名(含 "/" 则按路径)或绝对路径
---@param argv table|nil 传给子进程的位置参数(argv[0] 由本函数填)
---@param opts table|nil 透传给 process.spawn 的选项(cwd/env/stdio/uid/gid)
---@return integer|nil pid, string|nil err
function process.exec(cmd, argv, opts)
    opts = opts or {}
    local cur = process.current()
    local caller = registry[cur.pid]
    local pathEnv = (caller and caller.envvars and caller.envvars.PATH) or "/bin"

    local path = findInPath(cmd, pathEnv)
    if not path then return nil, cmd .. ": command not found" end
    if not fsapi().canExecute(path) then return nil, path .. ": permission denied" end
    local src, rerr = readFile(path)
    if not src then return nil, path .. ": " .. tostring(rerr) end

    local interp, iarg = parseShebang(src:match("^([^\n]*)") or "")
    local childArgv = { [0] = path }
    if interp then
        -- `#!/usr/bin/env prog [arg]`: JSON 之外最常见的写法, 特判取下一段程序名。
        local prog, arg = interp, iarg
        if interp:match("[^/]+$") == "env" then
            if not arg or arg == "" then return nil, "shebang: env without a program" end
            prog = arg:match("^(%S+)")
            arg = arg:match("^%S+%s+(.*)$")
        end
        local ipath = findInPath(prog, pathEnv)
        if not ipath then return nil, "shebang interpreter not found: " .. prog end
        if not fsapi().canExecute(ipath) then return nil, "shebang interpreter not executable: " .. prog end
        local isrc, ierr = readFile(ipath)
        if not isrc then return nil, "shebang interpreter: " .. tostring(ierr) end
        local n = 0
        childArgv = { [0] = ipath }
        if arg and arg ~= "" then n = 1; childArgv[n] = arg end
        n = n + 1; childArgv[n] = path
        for i = 1, #(argv or {}) do n = n + 1; childArgv[n] = argv[i] end
        local pid, _, cerr = process.spawn(isrc, ipath, cur.pid, opts.uid, opts.gid, childArgv, opts)
        if not pid then return nil, tostring(cerr) end
        return pid
    end

    for i = 1, #(argv or {}) do childArgv[i] = argv[i] end
    local pid, _, cerr = process.spawn(src, path, cur.pid, opts.uid, opts.gid, childArgv, opts)
    if not pid then return nil, tostring(cerr) end
    return pid
end

--- 注册为 syscall。参数与 process.exec 相同。
sc["proc.exec"] = function(cmd, argv, opts) return process.exec(cmd, argv, opts) end

-- 调度器在 resume 前经此投递信号。
scheduler.setSignalCheck(process.applySignals)

return process
