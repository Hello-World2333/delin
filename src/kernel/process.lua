--[[ Delin process model.
     - 进程表 + 进程树 (pid/ppid/status/children)
     - 每个进程一个隔离 _ENV (load(src, name, "t", env))
     - spawn 只收源码字符串(不收闭包/路径); 读文件由程序自己做
     - 内核自供 print (CC 自带 print 不走 io.stdout)
     - 父死子并入 init (pid 1)  ]]

local scheduler = require("kernel.scheduler")
local vfs_api  = require("kernel.vfs_api")
local modules  = require("kernel.modules")

local process = {}

process.next_pid = 0
process.log = nil        -- boot 注入: fun(...)  受控 print
local registry = {}      -- pid -> proc
local children = {}      -- pid -> set of child pids

---@class DelinProcess
---@field pid integer
---@field ppid integer
---@field name string
---@field co thread
---@field status string   -- running|dead|error
---@field exitCode any

local function kprint(...)
    if process.log then process.log(...) else print(...) end
end

local function nextPid()
    process.next_pid = process.next_pid + 1
    return process.next_pid
end

--- 构造一个进程的隔离环境。
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
---@param opts table|nil    选项 { cwd= } (可缺省)
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
    local env = buildEnv(pid, ppid, uid, gid, argv, opts)

    -- 继承父进程 stdio(或 boot 默认终端)。每个进程独立 stdio, 子进程在 spawn 时刻
    -- 继承父进程当前的 stdin/stdout, 之后各自变化互不影响。
    local parentProc = registry[ppid]
    local inherit = (parentProc and parentProc.stdio) or vfs_api.getStdio()
    if inherit then
        env.__stdio.input = inherit.input
        env.__stdio.output = inherit.output
    end

    local chunk, loadErr = load(src, name or ("proc#" .. pid), "t", env)
    if not chunk then
        return nil, nil, "load failed: " .. tostring(loadErr)
    end

    local co = coroutine.create(chunk)
    ---@type DelinProcess
    local proc = {
        pid = pid, ppid = ppid, name = name or ("proc#" .. pid),
        co = co, status = "running", exitCode = nil,
        uid = uid, gid = gid,
        cwd = env.cwd,
        stdio = env.__stdio,
    }

    -- onExit: 更新 registry 里的规范 proc 表(status/exitCode), 不是调度器的临时 proc 对象。
    -- 否则 process.info(pid) 永远看到 status="running", proc.wait 无法感知子进程退出。
    proc.onExit = function(_, status, err)
        proc.status = status
        proc.exitCode = (status == "dead") and 0 or nil
        reparentOrphans(pid)
    end

    registry[pid] = proc
    addChild(ppid, pid)

    scheduler.addProcess({
        pid = pid, co = co, name = proc.name,
        started = false, filter = nil, dead = false,
        status = "running", onExit = proc.onExit,
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

--- 打印进程树(调试/验证用)。
---@return string
function process.dumpTree()
    local lines = {}
    local function rec(pid, depth)
        local proc = registry[pid]
        if not proc then return end
        lines[#lines + 1] = string.rep("  ", depth)
            .. string.format("#%d %s (ppid=%d, %s)", pid, proc.name or "?", proc.ppid, proc.status or "?")
        local kids = children[pid]
        if kids then
            for child in pairs(kids) do rec(child, depth + 1) end
        end
    end
    rec(1, 0)
    return table.concat(lines, "\n")
end

return process
