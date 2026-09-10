--[[ Delin Virtual Filesystem (VFS).
     全抽象: 内核把真实文件系统(电脑 hdd + 各磁盘驱动)和虚拟文件系统(/dev, /proc)
     挂到同一个命名空间, 作为每个进程看到的 fs/io。真实磁盘挂载路径不可控, 所以由
     内核决定挂到哪。进程的 fs/io 走这个 VFS。 ]]

local vfs = {}

-- 挂载表: array of { root, backend } (root 是 VFS 绝对路径, 如 "/", "/dev", "/mnt/disk/left")
local mounts = {}

--- 路径规范化: 丢掉空段与 ".", 按 ".." 弹栈 —— **弹到根就停**(POSIX: "/.." 就是 "/")。
---
--- 为什么必须在 VFS 这一层做: CC 原生文件系统(CCFS)对"逃出根的 .."是直接**抛错**的
--- (`/..: Invalid Path`), 不是返回 nil。而 ".." 会从很多地方自然冒出来 —— `ls -la /`
--- 自己拼出 "/.."、`ls /../etc`、脚本里的 `$PWD/..` —— 于是"列出根目录"这种日常操作直接炸。
--- 挂载点上的 ".." 按字典序回到父目录(Linux: "/mnt/disk/.." = "/mnt"), 与"不越出挂载点"
--- 这个直觉不同但与 Linux 一致。
--- 已知偏离: 经**符号链接目录**的 ".." 在 Linux 里按链接目标解析, 这里一律按字典序解析。
---@param path string|nil
---@return string
local function normalize(path)
    if path == nil or path == "" then return "/" end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    local out = {}
    for seg in path:gmatch("[^/]+") do
        if seg == ".." then
            if #out > 0 then out[#out] = nil end
        elseif seg ~= "." then
            out[#out + 1] = seg
        end
    end
    if #out == 0 then return "/" end
    return "/" .. table.concat(out, "/")
end

--- 挂载一个文件系统。
---@param root string  VFS 相对根, 例如 "/" / "/dev" / "/mnt/disk/left"
---@param backend table  后端(real 或 virtual), 实现 list/exists/isDir/attributes/getSize/open/getDrive/getFreeSpace/getCapacity/makeDir/move/copy/delete/isReadOnly
---@param meta table|nil  可选挂载元数据(device/fstype), 供 `mount` 列出
function vfs.mount(root, backend, meta)
    root = normalize(root) -- 保证是绝对路径、无 "."/".."、无末尾斜杠
    mounts[#mounts + 1] = { root = root, backend = backend, meta = meta }
end

function vfs.unmount(root)
    root = normalize(root)
    for i = #mounts, 1, -1 do
        if mounts[i].root == root then table.remove(mounts, i) end
    end
end

local function isPrefix(root, p)
    if root == "/" then return true end
    return p == root or (p:sub(1, #root) == root and (p:sub(#root + 1):sub(1, 1) == "/"))
end

--- 列出所有挂载(含元数据)。供 `mount` 命令无参列出。
---@return table[] { root=, backend=, meta= }
function vfs.list()
    local out = {}
    for _, m in ipairs(mounts) do out[#out + 1] = { root = m.root, backend = m.backend, meta = m.meta } end
    return out
end

--- 解析路径到最长的挂载根。
---@param path string  VFS 路径(绝对; 相对路径按根处理)
---@return table|nil backend, string rel, string|nil err
function vfs.resolve(path)
    -- 归一化: 去掉 "."/".."(见 normalize), 绝对化、去重复与末尾斜杠
    path = normalize(path)

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

--- 把 CC 原生文件句柄包成 Delin 句柄。
--- **为什么必须包**: CC 的句柄方法是 Java 方法, Lua 侧 self 是**隐式**的 —— 只能
--- `h.write(s)`(点号)。用 `h:write(s)` 会把句柄自身当数据传进去, 真机上的表现是
--- 文件里出现 `table: 0x...`(而且不报错, 极难查)。Delin 自己的句柄(ext2 后端、/dev
--- 设备)是普通 Lua 表, 方法吃冒号, 全部 /bin 工具都按冒号写。两条路径必须给上层
--- 同一套语义: 这里包一层, **两种调用风格都接受**(与 klog 里 /dev/kmsg 的 seek 同一做法),
--- 于是内核里既有的点号调用(f.readAll() 等)不受影响。
--- 参数里没有表, 所以"第一个参数是句柄自身"这一个判据是可靠的。
---@param h table CC 原生句柄
---@return table
local function wrapCCHandle(h)
    local w = {}
    local function isSelf(a) return a == w end
    w.read     = function(a, b) if isSelf(a) then return h.read(b) end return h.read(a) end
    w.readAll  = function() return h.readAll() end
    w.readLine = function(a, b) if isSelf(a) then return h.readLine(b) end return h.readLine(a) end
    w.write    = function(a, ...) if isSelf(a) then return h.write(...) end return h.write(a, ...) end
    w.writeLine = function(a, ...) if isSelf(a) then return h.writeLine(...) end return h.writeLine(a, ...) end
    w.seek     = function(a, ...) if isSelf(a) then return h.seek(...) end return h.seek(a, ...) end
    w.flush    = function() return h.flush() end
    w.close    = function() return h.close() end
    w.isReadOnly = function() return h.isReadOnly() end
    w.raw      = h -- 需要 CC 原生调用风格时(点号)的自留口
    return w
end

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
        open     = function(rel, mode)
            local h, err = fs.open(toReal(rel), mode)
            if not h then return nil, err end
            return wrapCCHandle(h)
        end,
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
