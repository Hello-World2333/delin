--[[ Delin VFS facade: 把 VFS 暴露成进程可用的 fs/io, 并维护 /dev 设备注册表。
     真实挂载走 vfs.real(透传 CC 全局 fs); 虚拟挂载(/dev, /proc) 由注册处理器提供。 ]]

local vfs = require("kernel.vfs")

local vfsapi = {}

-- 设备注册表: name -> handler
local devices = {}

--- 注册一个设备节点(列在 /dev/<name>)。
---@param name string
---@param handler table 提供 open(mode)->handle(handle: read(n)/readLine()/write(s)/close())
---   handler.writable=true 时允许以 "w" 打开(字符设备如 tty/fb); 默认只读。
function vfsapi.registerDevice(name, handler)
    devices[name] = handler
end

--- 注销一个设备节点。
function vfsapi.unregisterDevice(name)
    devices[name] = nil
end

local function strip(rel)
    return rel and rel:gsub("^/+", "") or ""
end

-- ---------------------------------------------------------------
-- /dev 虚拟文件系统后端
-- ---------------------------------------------------------------
local devBackend = vfs.virtual({
    list = function(rel)
        local out = {}
        for n in pairs(devices) do out[#out + 1] = n end
        return out
    end,
    exists = function(rel) return devices[strip(rel)] ~= nil end,
    isDir = function(rel) return strip(rel) == "" end,
    attributes = function(rel)
        if strip(rel) == "" then return { size = 0, isDir = true, isReadOnly = true, name = "dev", created = 0, modified = 0 } end
        if devices[strip(rel)] then return { size = 0, isDir = false, isReadOnly = true, name = strip(rel), created = 0, modified = 0 } end
        return nil
    end,
    getSize = function(rel) return 0 end,
    getDrive = function(rel) return "vfs" end,
    getFreeSpace = function(rel) return 0 end,
    getCapacity = function(rel) return 0 end,
    isReadOnly = function(rel) return true end,
    makeDir = function(rel) error("read-only fs", 2) end,
    move = function() error("read-only fs", 2) end,
    copy = function() error("read-only fs", 2) end,
    delete = function(rel) error("read-only fs", 2) end,
    open = function(rel, mode)
        local name = strip(rel)
        local d = devices[name]
        if not d then return nil, "no such device: " .. name end
        if not d.writable and mode and mode:find("w") then
            error("device is read-only: " .. name, 2)
        end
        if d.open then return d.open(mode) end
        return nil, "device not openable: " .. name
    end,
})

-- ---------------------------------------------------------------
-- fs 门面
-- ---------------------------------------------------------------
local fsapi = {}
fsapi.getName = fs.getName
fsapi.getDir = fs.getDir
fsapi.combine = fs.combine
fsapi.isDriveRoot = fs.isDriveRoot
fsapi.complete = fs.complete

local function dispatch(path)
    local backend, rel, err = vfs.resolve(path)
    if not backend then error(tostring(err) or "bad path", 2) end
    return backend, rel
end

function fsapi.list(path) local b, r = dispatch(path); return b.list(r) end
function fsapi.exists(path) local b, r = dispatch(path); return b.exists(r) end
function fsapi.isDir(path) local b, r = dispatch(path); return b.isDir(r) end
function fsapi.isReadOnly(path) local b, r = dispatch(path); return b.isReadOnly(r) end
function fsapi.attributes(path) local b, r = dispatch(path); return b.attributes(r) end
function fsapi.getSize(path) local b, r = dispatch(path); return b.getSize(r) end
function fsapi.getDrive(path) local b, r = dispatch(path); return b.getDrive(r) end
function fsapi.getFreeSpace(path) local b, r = dispatch(path); return b.getFreeSpace(r) end
function fsapi.getCapacity(path) local b, r = dispatch(path); return b.getCapacity(r) end
function fsapi.makeDir(path) local b, r = dispatch(path); return b.makeDir(r) end
function fsapi.move(a, b) local ba, ra = dispatch(a); local bb, rb = dispatch(b); return ba.move(ra, rb) end
function fsapi.copy(a, b) local ba, ra = dispatch(a); local bb, rb = dispatch(b); return ba.copy(ra, rb) end
function fsapi.delete(path) local b, r = dispatch(path); return b.delete(r) end
function fsapi.open(path, mode) local b, r = dispatch(path); return b.open(r, mode) end
function fsapi.chmod(path, mode) local b, r = dispatch(path); if b.chmod then return b.chmod(r, mode) end return nil, "chmod not supported" end
function fsapi.chown(path, uid, gid) local b, r = dispatch(path); if b.chown then return b.chown(r, uid, gid) end return nil, "chown not supported" end
function fsapi.isFile(path)
    local b, r = dispatch(path)
    if b.isFile then return b.isFile(r) end
    return b.exists(r) and not b.isDir(r)
end
function fsapi.find(path)
    local list = {}
    local function walk(p)
        local b, r = dispatch(p)
        if b.exists(r) and b.isDir(r) then
            for _, n in ipairs(b.list(r)) do
                local child = fsapi.combine(p, n)
                walk(child)
            end
        elseif b.exists(r) then
            list[#list + 1] = p
        end
    end
    walk(path)
    local i = 0
    return function() i = i + 1; return list[i] end
end

-- ---------------------------------------------------------------
-- io 门面
-- ---------------------------------------------------------------
local ioapi = {}
---@type table|nil 默认输入/输出(终端)
local stdio

function ioapi.open(path, mode) return fsapi.open(path, mode or "r") end
function ioapi.type(obj)
    if type(obj) == "table" and getmetatable(obj) and getmetatable(obj).__ioType then
        return getmetatable(obj).__ioType
    end
    if type(obj) == "userdata" then return "file" end
    return nil
end
function ioapi.write(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    if stdio and stdio.output then return stdio.output:write(table.concat(parts)) end
    return write(table.concat(parts))
end
function ioapi.read(...)
    if stdio and stdio.input then return stdio.input:read(...) end
    return read(...)
end
function ioapi.close(file) if file and file.close then return file:close() end end
function ioapi.flush() if stdio and stdio.output and stdio.output.flush then return stdio.output:flush() end end
function ioapi.lines(filename, ...)
    if filename then
        local f = fsapi.open(filename, "r")
        if not f then return function() return nil end end
        return f.lines and f.lines() or function() return f.readLine() end
    end
    return function() return nil end
end
function ioapi.stdout() return stdio and stdio.output end
function ioapi.stderr() return stdio and stdio.output end
function ioapi.stdin() return stdio and stdio.input end

--- @param input table 终端输入(有 read)
--- @param output table 终端输出(有 write/writeLine/flush)
function vfsapi.setStdio(input, output)
    stdio = { input = input, output = output }
end

--- 挂载 /dev 虚拟文件系统。
function vfsapi.mountDev()
    vfs.mount("/dev", devBackend)
end

--- 暴露 fs 门面(供内核/模块/cat 使用)。
vfsapi.fs = fsapi

--- 列出已注册设备名。
---@return string[]
function vfsapi.devices()
    local out = {}
    for n in pairs(devices) do out[#out + 1] = n end
    return out
end

-- ---------------------------------------------------------------
-- 安装到进程环境: 替换 env.fs / env.io
-- ---------------------------------------------------------------
---@param env table 进程环境
function vfsapi.installForEnv(env)
    env.fs = fsapi
    env.io = ioapi
end

return vfsapi
