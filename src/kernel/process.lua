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
---@return table
local function buildEnv(pid, ppid)
    ---@type table
    local env = setmetatable({
        pid   = pid,
        ppid  = ppid,
        print = kprint,
        spawn = function(src, name)
            return process.spawn(src, name, pid)
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
---@return integer|nil pid, table|nil proc, string|nil err
function process.spawn(src, name, ppid)
    ppid = ppid or 0
    if type(src) ~= "string" then
        return nil, nil, "spawn expects a source string, got " .. type(src)
    end

    local pid = nextPid()
    local env = buildEnv(pid, ppid)

    local chunk, loadErr = load(src, name or ("proc#" .. pid), "t", env)
    if not chunk then
        return nil, nil, "load failed: " .. tostring(loadErr)
    end

    local co = coroutine.create(chunk)
    ---@type DelinProcess
    local proc = {
        pid = pid, ppid = ppid, name = name or ("proc#" .. pid),
        co = co, status = "running", exitCode = nil,
    }

    proc.onExit = function(self, status, err)
        self.status = status
        self.exitCode = (status == "dead") and 0 or nil
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
