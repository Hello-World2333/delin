--[[ Delin 内核模块系统.
     .ko = 带 --@name/--@version/--@deps 注释头的 Lua 文件; 头用静态解析(不执行),
     函数体 `return { init=fn }`, init(kapi) 里调注册 API。
     目录: /lib/modules/<version>/ (含纯文本 manifest), 依赖拓扑排序装载。
     生命周期: load/init/active/error + unload/reload 带依赖引用计数。
     信任: 内核态, 不沙箱。 ]]

local vfs_api = require("kernel.vfs_api")
local vfs     = require("kernel.vfs")
local display = require("kernel.display")

local modules = {}

modules.version = "0.0.2"
modules.log = print   -- boot 可替换为 kprint
modules.fs = fs       -- 读模块文件的 fs 门面(默认 CC 真实 fs; EXT2 根引导时 boot 换成 vfs_api.fs)

---@class DelinModule
---@field name string
---@field meta table
---@field mod table      -- 模块返回的表 { init=, exit= }
---@field deps string[]
---@field ref number     -- 依赖方引用计数
---@field state string   -- pending|loading|active|error|unloaded

local reg = {}     -- name -> DelinModule
local syscalls = {} -- name -> fn   (注册 syscall)

-- ---------------------------------------------------------------
-- 静态元数据解析(不执行模块)
-- ---------------------------------------------------------------
local function trim(v) return (v:match("^%s*(.-)%s*$")) end

---@param src string
---@return table meta { name, version, deps, author, description }
local function parseMeta(src)
    local meta = { name = nil, version = nil, deps = {}, author = nil, description = nil }
    for line in src:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed == "" then
            -- 头部空行, 跳过
        elseif trimmed:sub(1, 1) ~= "-" then
            break -- 首个非注释行即代码区,停止解析头部
        else
            local key, val = line:match("^%s*%-%-@([%w_]+)%s+(.-)%s*$")
            if key then
                if key == "name" then meta.name = val
                elseif key == "version" then meta.version = val
                elseif key == "author" then meta.author = val
                elseif key == "description" then meta.description = val
                elseif key == "deps" then
                    for d in val:gmatch("[^,%s]+") do meta.deps[#meta.deps + 1] = d end
                end
            end
        end
    end
    if not meta.name then meta.name = "unnamed" end
    return meta
end

local function readAll(path)
    local f = modules.fs.open(path, "r")
    if not f then return nil end
    local c = f.readAll()
    f.close()
    return c
end

-- ---------------------------------------------------------------
-- 注册 API (kapi): 统一注册表
-- ---------------------------------------------------------------
local function makeKapi(name)
    return {
        name = name,
        version = modules.version,
        log = modules.log,
        registerSyscall = function(sn, fn) syscalls[sn] = fn end,
        registerDevice  = function(dn, handler) vfs_api.registerDevice(dn, handler) end,
        registerFS      = function(mnt, backend) vfs.mount(mnt, backend) end,
        registerDisplay = function(dev) return display.register(dev) end,
        unregisterDisplay = function(id) display.unregister(id) end,
        displayList     = function() return display.list() end,
    }
end

-- ---------------------------------------------------------------
-- 装载
-- ---------------------------------------------------------------
local loadDir = nil  -- 真实 fs 目录, 由 boot 初始化

---@param dir string 模块目录(modules.fs 是真 fs 时为真实路径, 如 "disk/lib/modules/0.0.2"; 为 vfs 时为 VFS 路径, 如 "/lib/modules/0.0.2")
function modules.init(dir)
    loadDir = dir
end

--- 单个模块装载(递归先装依赖)。
---@param name string
---@param device any|null  传给 init(kapi, device) 的设备(绑定用)
---@return boolean, string|nil
local function loadModule(name, device)
    if reg[name] and reg[name].state == "active" then return true end
    if not loadDir then return nil, "module manager not initialized" end

    local src = readAll(loadDir .. "/" .. name .. ".ko")
    if not src then return nil, "module file not found: " .. name end
    local meta = parseMeta(src)

    -- 依赖先装
    for _, dep in ipairs(meta.deps) do
        local ok, err = loadModule(dep)
        if not ok then return nil, "dep '" .. dep .. "' failed: " .. tostring(err) end
    end

    -- 独立内核态环境(带 require, 可引入内核模块)
    local env = setmetatable({ require = require }, { __index = _G })
    local chunk, loadErr = load(src, name, "t", env)
    if not chunk then return nil, "load failed: " .. tostring(loadErr) end
    local okRun, mod = pcall(chunk)
    if not okRun then return nil, "module body error: " .. tostring(mod) end
    if type(mod) ~= "table" then return nil, "module must return a table: " .. name end

    local rec = { name = name, meta = meta, mod = mod, deps = meta.deps, ref = 0, state = "loading" }

    if mod.init then
        local okI, errI = pcall(mod.init, makeKapi(name), device)
        if not okI then
            rec.state = "error"; reg[name] = rec
            return nil, "init error: " .. tostring(errI)
        end
    end

    rec.state = "active"; reg[name] = rec
    for _, dep in ipairs(meta.deps) do
        if reg[dep] then reg[dep].ref = reg[dep].ref + 1 end
    end
    modules.log(string.format("[module] loaded '%s' v%s (deps:%s)", name, meta.version or "?", table.concat(meta.deps, ",")))
    return true
end

--- 加载一个模块(公开)。
---@param name string
---@return boolean, string|nil
function modules.load(name)
    return loadModule(name)
end

-- 别名表: 设备/外设类型 -> 模块名 (modprobe 风格)
local aliasTable = {}

--- 读取 /lib/modules/<version>/modules.alias。
function modules.loadAliases()
    if not loadDir then return nil, "module manager not initialized" end
    local src = readAll(loadDir .. "/modules.alias")
    if not src then return nil, "no modules.alias at " .. loadDir end
    aliasTable = {}
    for line in src:gmatch("[^\r\n]+") do
        line = line:gsub("%s*#.*$", ""):gsub("^%s*", ""):gsub("%s*$", "")
        if line ~= "" then
            local alias, mod = line:match("^(%S+)%s+(%S+)$")
            if alias and mod then aliasTable[alias] = mod end
        end
    end
    return true
end

--- modprobe 风格: 按别名加载模块, 并把 device 传给 init(kapi, device)。
---@param alias string  设备/外设类型(如 "tm_gpu")
---@param device any    要绑定的外设(如 "right")
---@return boolean, string|nil
function modules.use(alias, device)
    local modName = aliasTable[alias]
    if not modName then return nil, "no module for alias '" .. tostring(alias) .. "' (see modules.alias)" end
    return loadModule(modName, device)
end

--- 按 manifest 装载所有模块(顺序 = manifest, 依赖拓扑排序)。fail-fast。
---@return boolean, string|nil
function modules.loadAll()
    if not loadDir then return nil, "module manager not initialized" end
    local manifest = readAll(loadDir .. "/manifest")
    if not manifest then return nil, "no manifest at " .. loadDir .. "/manifest" end
    local names = {}
    for name in manifest:gmatch("[^\r\n]+") do
        name = trim(name)
        if name ~= "" then names[#names + 1] = name end
    end
    for _, name in ipairs(names) do
        local ok, err = loadModule(name)
        if not ok then return nil, err end
    end
    return true
end

--- 卸载一个模块(引用计数)。
---@param name string
---@return boolean, string|nil
function modules.unload(name)
    local rec = reg[name]
    if not rec then return nil, "not loaded: " .. name end
    if rec.ref > 0 then return nil, "module in use (refcount=" .. rec.ref .. "): " .. name end
    if rec.mod and rec.mod.exit then
        local okE, errE = pcall(rec.mod.exit)
        if not okE then modules.log("module exit error " .. name .. ": " .. tostring(errE)) end
    end
    for _, dep in ipairs(rec.deps) do
        if reg[dep] then reg[dep].ref = math.max(0, reg[dep].ref - 1) end
    end
    rec.state = "unloaded"; reg[name] = nil
    modules.log("[module] unloaded '" .. name .. "'")
    return true
end

--- 重载 (unload + load)。
function modules.reload(name)
    local okU, errU = modules.unload(name)
    if not okU then return nil, errU end
    return loadModule(name)
end

-- ---------------------------------------------------------------
-- syscall 暴露给进程
-- ---------------------------------------------------------------
--- syscall 表(进程 env 的 syscalls)
function modules.syscalls()
    return syscalls
end

--- 注入进程环境: env.syscalls
---@param env table
function modules.applyToEnv(env)
    env.syscalls = syscalls
end

-- ---------------------------------------------------------------
-- 注册模块管理自身的 syscall(运行时 load/unload, 类 modprobe)
-- ---------------------------------------------------------------
syscalls["modules.load"]   = function(name) return modules.load(name) end
syscalls["modules.unload"] = function(name) return modules.unload(name) end
syscalls["modules.reload"] = function(name) return modules.reload(name) end
syscalls["modules.list"]   = function()
    local out = {}
    for name, rec in pairs(reg) do out[#out + 1] = name .. ":" .. rec.state end
    return out
end

return modules
