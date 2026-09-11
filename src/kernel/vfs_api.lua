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
        table.sort(out)
        return out
    end,
    exists = function(rel)
        rel = strip(rel)
        if rel == "" then return true end -- /dev 自身是一个目录
        return devices[rel] ~= nil
    end,
    isDir = function(rel) return strip(rel) == "" end,
    attributes = function(rel)
        -- kind 不能漏: 工具靠它区分"文件"与"设备节点"。`dd of=/dev/sda1` 就是例子 ——
        -- 没有 kind 时会按普通文件走, 于是把整个分区镜像读进内存(CC 上直接 OOM)。
        if strip(rel) == "" then
            return { size = 0, isDir = true, isReadOnly = true, kind = "dir", name = "dev", created = 0, modified = 0 }
        end
        if devices[strip(rel)] then
            return { size = 0, isDir = false, isReadOnly = true, kind = "device", name = strip(rel), created = 0, modified = 0 }
        end
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

--- 与 dispatch 相同, 但**不跟随最后一段**的符号链接(供 lstat/readlink/unlink/symlink 用)。
local function dispatchNoFollow(path)
    local backend, rel, err = vfs.resolveNoFollow(path)
    if not backend then error(tostring(err) or "bad path", 2) end
    return backend, rel
end

function fsapi.list(path) local b, r = dispatch(path); return b.list(r) end
function fsapi.exists(path) local b, r = dispatch(path); return b.exists(r) end
function fsapi.isDir(path) local b, r = dispatch(path); return b.isDir(r) end
function fsapi.isReadOnly(path) local b, r = dispatch(path); return b.isReadOnly(r) end
function fsapi.attributes(path) local b, r = dispatch(path); return b.attributes(r) end
--- 不跟随符号链接的 stat(等价 Linux 的 lstat): 对符号链接本身返回 kind="symlink"。
function fsapi.lstat(path) local b, r = dispatchNoFollow(path); return b.attributes(r) end
function fsapi.getSize(path) local b, r = dispatch(path); return b.getSize(r) end
function fsapi.getDrive(path) local b, r = dispatch(path); return b.getDrive(r) end
function fsapi.getFreeSpace(path) local b, r = dispatch(path); return b.getFreeSpace(r) end
function fsapi.getCapacity(path) local b, r = dispatch(path); return b.getCapacity(r) end
-- makeDir/move/delete 的**目标**最后一段不跟随符号链接: 否则 `rm link` 会删掉链接指向的
-- 文件(Linux 的 unlink/rename/mkdir 都不跟随最后一段)。源路径 move 同理(rename 不动链接本身)。
function fsapi.makeDir(path) local b, r = dispatchNoFollow(path); return b.makeDir(r) end
function fsapi.move(a, b)
    local ba, ra = dispatchNoFollow(a)
    local bb, rb = dispatchNoFollow(b)
    return ba.move(ra, rb)
end
function fsapi.copy(a, b) local ba, ra = dispatch(a); local bb, rb = dispatch(b); return ba.copy(ra, rb) end
function fsapi.delete(path) local b, r = dispatchNoFollow(path); return b.delete(r) end
function fsapi.open(path, mode) local b, r = dispatch(path); return b.open(r, mode) end
function fsapi.chmod(path, mode) local b, r = dispatch(path); if b.chmod then return b.chmod(r, mode) end return nil, "chmod not supported" end
function fsapi.chown(path, uid, gid) local b, r = dispatch(path); if b.chown then return b.chown(r, uid, gid) end return nil, "chown not supported" end
--- 不跟随最后一段的 chown(= Linux `lchown`)。`chown -h` / `chgrp -h` / 递归遍历里的链接
--- 必须用它: 用跟随版本会把**链接指向的文件**改掉 —— 递归时常改到树外的文件, 比报错危险得多。
--- ext2 的 lookup 本来就不逐段跟随最后一段, 所以 dispatchNoFollow + b.chown 就是正确的 lchown。
function fsapi.lchown(path, uid, gid)
    local b, r = dispatchNoFollow(path)
    if not b.chown then return nil, "chown not supported" end
    return b.chown(r, uid, gid)
end
function fsapi.canExecute(path) local b, r = dispatch(path); if b.canExecute then return b.canExecute(r) end return true end
-- ---------------- 符号链接 / 硬链接 ----------------
-- 语义对齐 Linux: symlink 的 target 原样保存(不解析), linkpath 的最后一段不跟随符号链接
-- (否则 ln -s 到"已存在的链接"会变成改别人的方向); link 的 oldpath 要跟随(硬链接指向目标
-- 本身而不是链接), newpath 不跟随(必须不存在)。
---@param target string 链接目标(原样保存, 不解析)
---@param linkpath string 新链接路径
function fsapi.symlink(target, linkpath)
    local b, r = dispatchNoFollow(linkpath)
    if not b.symlink then return nil, "symbolic links are not supported on this filesystem" end
    return b.symlink(target, r)
end
--- 读符号链接目标(不跟随)。
function fsapi.readlink(path)
    local b, r = dispatchNoFollow(path)
    if not b.readlink then return nil, "not a symbolic link" end
    return b.readlink(r)
end
--- 硬链接。与 Linux 的 link(2) 一致: **不跟随** oldpath 最后一段的符号链接
--- (给链接本身再挂一个名字), newpath 必须不存在。
function fsapi.link(oldpath, newpath)
    local b, r = dispatchNoFollow(oldpath)
    local b2, r2 = dispatchNoFollow(newpath)
    if b ~= b2 then return nil, "cross-filesystem hard link is not allowed" end
    if not b.link then return nil, "hard links are not supported on this filesystem" end
    return b.link(r, r2)
end
--- 建命名管道(POSIX FIFO)。
---@param path string
---@param mode integer|nil 权限位(八进制数值); **umask 由调用方先算好**, 内核不重复收窄
function fsapi.mkfifo(path, mode)
    local b, r = dispatchNoFollow(path)
    if not b.mkfifo then return nil, "named pipes are not supported on this filesystem" end
    return b.mkfifo(r, mode)
end
--- 该路径是否是命名管道(FIFO)。CC 原生 fs 不支持 FIFO, 一律返回 false。
function fsapi.isFifo(path)
    local b, r = dispatchNoFollow(path)
    local a = b.attributes(r)
    return a ~= nil and a.kind == "fifo"
end
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
-- stdio 按进程隔离(每个进程有自己的 stdin/stdout)。进程 spawn 时由 process.lua
-- 从父进程继承(或从 boot 默认终端)填充 env.__stdio; 该表被本进程 io 闭包捕获。
-- 这样多个 tty 的 login 各自绑定自己的 tty, 互不覆盖。
---@type table|nil boot 默认终端(pid 1/无父进程进程的最初 stdio)
local defaultStdio = nil
local ioapi = {} -- 共享的纯函数面(open/type/close/lines 与 stdio 无关)

function ioapi.open(path, mode) return fsapi.open(path, mode or "r") end
function ioapi.type(obj)
    if type(obj) == "table" and getmetatable(obj) and getmetatable(obj).__ioType then
        return getmetatable(obj).__ioType
    end
    if type(obj) == "userdata" then return "file" end
    return nil
end
function ioapi.close(file) if file and file.close then return file:close() end end
function ioapi.lines(filename, ...)
    if filename then
        local f = fsapi.open(filename, "r")
        if not f then return function() return nil end end
        return f.lines and f.lines() or function() return f.readLine() end
    end
    return function() return nil end
end

--- 按指定 stdio 表构造一个进程专属 io 门面(捕获该表, 读当前进程的 stdin/stdout)。
---@param stdio table { input=, output= }
---@return table io
local function makeIoapi(stdio)
    return {
        open = ioapi.open,
        type = ioapi.type,
        close = ioapi.close,
        lines = ioapi.lines,
        write = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
            if stdio.output then return stdio.output:write(table.concat(parts)) end
            return write(table.concat(parts))
        end,
        read = function(...)
            if stdio.input then return stdio.input:read(...) end
            return read(...)
        end,
        flush = function()
            if stdio.output and stdio.output.flush then return stdio.output:flush() end
        end,
        stdout = function() return stdio.output end,
        stderr = function() return stdio.output end,
        stdin  = function() return stdio.input end,
    }
end

--- 设置 boot 默认终端 stdio(进程未继承父进程时使用)。boot 调用一次。
--- @param input table 终端输入(有 read)
--- @param output table 终端输出(有 write/writeLine/flush)
function vfsapi.setStdio(input, output)
    defaultStdio = { input = input, output = output }
end

--- 取 boot 默认终端 stdio(供 pid 1 初始化)。
---@return table|nil
function vfsapi.getStdio()
    return defaultStdio
end

--- 挂载 /dev 虚拟文件系统。
function vfsapi.mountDev()
    vfs.mount("/dev", devBackend, { device = "devtmpfs", fstype = "devtmpfs" })
end

-- /dev/null: 读立即 EOF, 写丢弃(Linux 语义)。POSIX 规定非交互 sh 的后台命令 stdin
-- 指向 /dev/null, 故本设备是作业控制的组成部分, 随 /dev 一起注册。
local function nullHandle()
    return {
        read = function() return nil end,
        readLine = function() return nil end,
        write = function(_, s) return #tostring(s or "") end,
        flush = function() return true end,
        close = function() return true end,
    }
end
vfsapi.registerDevice("null", {
    writable = true,
    open = function() return nullHandle() end,
})

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
    -- 每个进程独立的 stdio 表(由 process.spawn 填充); io 闭包捕获它。
    local stdio = { input = nil, output = nil }
    env.__stdio = stdio
    env.io = makeIoapi(stdio)
end

return vfsapi
