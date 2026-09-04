--[[ Delin Virtual Filesystem (VFS).
     全抽象: 内核把真实文件系统(电脑 hdd + 各磁盘驱动)和虚拟文件系统(/dev, /proc)
     挂到同一个命名空间, 作为每个进程看到的 fs/io。真实磁盘挂载路径不可控, 所以由
     内核决定挂到哪。进程的 fs/io 走这个 VFS。 ]]

local vfs = {}

-- 挂载表: array of { root, backend } (root 是 VFS 绝对路径, 如 "/", "/dev", "/mnt/disk/left")
local mounts = {}

--- 挂载一个文件系统。
---@param root string  VFS 相对根, 例如 "/" / "/dev" / "/mnt/disk/left"
---@param backend table  后端(real 或 virtual), 实现 list/exists/isDir/attributes/getSize/open/getDrive/getFreeSpace/getCapacity/makeDir/move/copy/delete/isReadOnly
function vfs.mount(root, backend)
    -- 规范化: 保证以 "/" 开头、去掉末尾斜杠(除非就是根)
    if root == "" then root = "/" end
    if root ~= "/" then root = root:gsub("/+$", "") end
    mounts[#mounts + 1] = { root = root, backend = backend }
end

function vfs.unmount(root)
    if root == "" then root = "/" end
    if root ~= "/" then root = root:gsub("/+$", "") end
    for i = #mounts, 1, -1 do
        if mounts[i].root == root then table.remove(mounts, i) end
    end
end

local function isPrefix(root, p)
    if root == "/" then return true end
    return p == root or (p:sub(1, #root) == root and (p:sub(#root + 1):sub(1, 1) == "/"))
end

--- 解析路径到最长的挂载根。
---@param path string  VFS 绝对路径
---@return table|nil backend, string rel, string|nil err
function vfs.resolve(path)
    -- 归一化: 绝对化、去掉末尾斜杠
    if path == "" then path = "/" end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    if path ~= "/" then path = path:gsub("/+$", "") end

    local best = nil
    for _, m in ipairs(mounts) do
        if isPrefix(m.root, path) and (not best or #m.root > #best.root) then
            best = m
        end
    end
    if not best then
        return nil, nil, "path not under any mount: " .. path
    end
    local rel
    if best.root == "/" then
        rel = (path ~= "/") and (path:gsub("^/", "/")) or ""
        -- 对于根挂载, rel 保留绝对形式
        rel = path  -- 根挂载时 rel 就是原路径(以"/"开头)
    else
        if path == best.root then
            rel = ""
        else
            rel = path:sub(#best.root + 1) -- 保留开头 "/"
        end
    end
    return best.backend, rel, nil
end

-- ---------------------------------------------------------------
-- real 后端: 包装 CC 的全局 fs, 偏移一个真实基路径。
--   basePath=""  → hdd(真实路径即 "/...")
--   basePath="disk" → 磁盘驱动挂载到 "disk"(真实路径 "disk/...")
-- ---------------------------------------------------------------
---@param basePath string
---@return table
function vfs.real(basePath)
    basePath = basePath or ""
    if basePath ~= "" and basePath ~= "/" and basePath:sub(-1) == "/" then
        basePath = basePath:sub(1, -2)
    end
    local function toReal(rel)
        if rel == "" then return basePath end
        if basePath == "" then return rel end
        return basePath .. rel -- "disk" .. "/boot/..." = "disk/boot/..."
    end
    return {
        kind = "real",
        toReal = toReal,
        list     = function(rel) return fs.list(toReal(rel)) end,
        exists   = function(rel) return fs.exists(toReal(rel)) end,
        isDir    = function(rel) return fs.isDir(toReal(rel)) end,
        isFile   = function(rel) return fs.exists(toReal(rel)) and not fs.isDir(toReal(rel)) end,
        attributes = function(rel) return fs.attributes(toReal(rel)) end,
        getSize  = function(rel) return fs.getSize(toReal(rel)) end,
        getDrive = function(rel) return fs.getDrive(toReal(rel)) end,
        getFreeSpace = function(rel) return fs.getFreeSpace(toReal(rel)) end,
        getCapacity  = function(rel) return fs.getCapacity(toReal(rel)) end,
        makeDir  = function(rel) return fs.makeDir(toReal(rel)) end,
        move     = function(a, b) return fs.move(toReal(a), toReal(b)) end,
        copy     = function(a, b) return fs.copy(toReal(a), toReal(b)) end,
        delete   = function(rel) return fs.delete(toReal(rel)) end,
        isReadOnly = function(rel) return fs.isReadOnly(toReal(rel)) end,
        open     = function(rel, mode) return fs.open(toReal(rel), mode) end,
    }
end

-- ---------------------------------------------------------------
-- 虚拟文件系统后端: 由注册的处理器提供 list/exists/open 等。
-- ---------------------------------------------------------------
--- 注册一个虚拟文件系统 mount 处理器(如 /proc)。handler 是 fs 风格的后端(见上)。
function vfs.virtual(handler)
    handler.kind = "virtual"
    return handler
end

return vfs
