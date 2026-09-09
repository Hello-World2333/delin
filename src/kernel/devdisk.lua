--[[ Delin 磁盘设备抽象 (/dev/sdX)。
     CC 没有裸块 API, 磁盘驱动器只给两样东西:
       1. 盘上 CC 原生文件系统的真实路径(disk.getMountPath)  -> 整盘设备 /dev/sda (fstype ccdisk)
       2. 盘上 /parts/*.img 文件(可字节读写)                  -> 分区设备 /dev/sda1..N (fstype ext2)
     命名: 磁盘按 disk.getID() 升序编号 a,b,c..(与 peripheral.getNames() 顺序/槽位无关);
           分区号 = 该盘 /parts/manifest 中分区行的序号(1 起, root 行在前);
           另有 /dev/ccdiskN 作为整盘 CC 原生 fs 的别名节点(N 从 0 起)。
     UUID: CC 无文件系统 UUID, 用磁盘 ID 模拟 —— 整盘 "<磁盘ID>", 分区 "<磁盘ID>-<分区号>"。
           无 ID 的介质(电脑盘/海龟盘)不产生 UUID, 因而不能用 UUID= 挂载。
     挂载: fstype 处理器由模块注册(kapi.registerFstype); 本层只做枚举/解析/挂载表, 
           未知 fstype 直接报错(fail-fast, 不回退)。 ]]

local vfs      = require("kernel.vfs")
local vfs_api  = require("kernel.vfs_api")
local manifest = require("kernel.manifest")

local devdisk = {}

-- fstype 注册表: name -> function(source, dir) -> backend, meta | nil, err
local fstypes = {}

--- 注册文件系统类型(模块经 kapi.registerFstype 调用; 重复注册即覆盖, 供模块重载)。
---@param name string
---@param fn fun(source:table, dir:string):table|nil, table|string|nil
function devdisk.registerFstype(name, fn)
    fstypes[name] = fn
end

--- 已注册的 fstype 名(排序)。
function devdisk.fstypes()
    local out = {}
    for n in pairs(fstypes) do out[#out + 1] = n end
    table.sort(out)
    return out
end

-- 节点名 -> 条目(最近一次 refresh 的结果; 别名节点指向同一个条目)
local nodes = {}
-- 已注册到 /dev 的节点名(热插拔时用于注销失效节点)
local registered = {}

--- 磁盘序号 -> 字母(a,b,..,z,aa,..), 即 /dev/sd<字母>。
local function diskLetter(i)
    local s = ""
    while i > 0 do
        local r = (i - 1) % 26
        s = string.char(97 + r) .. s
        i = math.floor((i - 1) / 26)
    end
    return s
end

--- 有数据的磁盘驱动器列表, 按磁盘 ID 升序(无 ID 的介质排最后, 按槽位名)。
local function drives()
    local list = {}
    for _, side in ipairs(peripheral.getNames()) do
        if disk.hasData(side) then
            local mp = disk.getMountPath(side)
            if not mp then error("devdisk: " .. side .. ": disk.hasData but no mount path", 0) end
            list[#list + 1] = {
                side = side,
                mountPath = mp,
                diskId = disk.getID(side),
                label = disk.getLabel(side),
            }
        end
    end
    table.sort(list, function(a, b)
        if a.diskId and b.diskId then
            if a.diskId ~= b.diskId then return a.diskId < b.diskId end
        elseif a.diskId ~= b.diskId then
            return a.diskId ~= nil
        end
        return a.side < b.side
    end)
    return list
end

--- 读盘上 /parts/manifest(不存在则返回 nil, 即该盘无分区)。
local function readPartManifest(mountPath)
    local f = fs.open(mountPath .. "/parts/manifest", "r")
    if not f then return nil end
    local content = f.readAll()
    f.close()
    return manifest.parse(content)
end

--- 扫描所有磁盘, 返回规范设备条目(不含别名节点)。不注册 /dev。
---@return table[]
function devdisk.scan()
    local out = {}
    for i, d in ipairs(drives()) do
        local base = "sd" .. diskLetter(i)
        local uuid = d.diskId and tostring(d.diskId) or nil
        out[#out + 1] = {
            name = base, node = "/dev/" .. base, type = "disk", fstype = "ccdisk",
            uuid = uuid, diskId = d.diskId, index = i, side = d.side, label = d.label,
            mountPath = d.mountPath, size = fs.getCapacity(d.mountPath),
        }
        local m = readPartManifest(d.mountPath)
        if m then
            for n, p in ipairs(m.partitions) do
                local rel = p.path
                if rel:sub(1, 1) ~= "/" then rel = "/" .. rel end
                local img = d.mountPath .. rel
                out[#out + 1] = {
                    name = base .. n, node = "/dev/" .. base .. n, type = "part",
                    fstype = (p.fstype ~= "" and p.fstype) or "ext2",
                    uuid = uuid and (uuid .. "-" .. n) or nil,
                    diskId = d.diskId, index = i, part = n, role = p.role,
                    side = d.side, img = img,
                    size = fs.exists(img) and fs.getSize(img) or nil,
                }
            end
        end
    end
    return out
end

--- 分区节点的原始字节句柄(分区就是盘上的 .img 文件)。
local function openRaw(e, mode)
    local h, err = fs.open(e.img, (mode and mode:find("w")) and "r+" or "r")
    if not h then return nil, err end
    -- CC 原生句柄是点号调用; 这里同时容忍冒号(与 ext2 后端句柄一致)。
    return {
        read = function(a, b) return h.read((type(a) == "table") and b or a) end,
        readLine = function(a) return h.readLine((type(a) == "table") and nil or a) end,
        readAll = function() return h.readAll() end,
        write = function(a, b) return h.write((type(a) == "table") and b or a) end,
        close = function() return h.close() end,
    }
end

local function nodeOpen(name, mode)
    local e = nodes[name]
    if not e then return nil, "/dev/" .. name .. ": no such device" end
    if e.type ~= "part" then
        -- 整盘是 CC 原生文件系统(目录树), 不是字节流设备 —— 只能挂载。
        return nil, "/dev/" .. name .. ": CC native filesystem (ccdisk) — mount it, no byte stream"
    end
    return openRaw(e, mode)
end

--- 重新扫描磁盘并刷新 /dev 节点(盘插入/弹出时由内核事件钩子调用)。
---@return table[] 规范设备条目
function devdisk.refresh()
    local list = devdisk.scan()
    nodes = {}
    for _, e in ipairs(list) do
        nodes[e.name] = e
        if e.type == "disk" then
            nodes["ccdisk" .. (e.index - 1)] = e -- 别名: /dev/ccdiskN -> 整盘条目
        end
    end
    for name in pairs(registered) do
        if not nodes[name] then
            vfs_api.unregisterDevice(name)
            registered[name] = nil
        end
    end
    for name in pairs(nodes) do
        vfs_api.registerDevice(name, {
            writable = true,
            open = function(mode) return nodeOpen(name, mode) end,
        })
        registered[name] = true
    end
    return list
end

--- 列出设备(含挂载点), 供 blkid / lsblk。
---@return table[] { name,node,type,fstype,uuid,size,label,role,mounted }
function devdisk.list()
    local list = devdisk.refresh()
    local mounts = {}
    for _, mt in ipairs(vfs.list()) do
        local dev = mt.meta and mt.meta.device
        if dev then
            mounts[dev] = mounts[dev] or {}
            mounts[dev][#mounts[dev] + 1] = mt.root
        end
    end
    for _, e in ipairs(list) do e.mounted = mounts[e.node] or {} end
    return list
end

--- 解析设备规格: "/dev/sda1" | "sda1" | "ccdisk0" | "UUID=<uuid>"。
---@return table|nil entry, string|nil err
function devdisk.find(spec)
    if type(spec) ~= "string" or spec == "" then return nil, "empty device" end
    if spec:sub(1, 5) == "UUID=" then
        local want = spec:sub(6)
        if want == "" then return nil, "UUID=: empty uuid" end
        for _, e in ipairs(devdisk.list()) do
            if e.uuid == want then return e end
        end
        return nil, spec .. ": no such device"
    end
    devdisk.refresh()
    local name = spec:gsub("^/dev/", "")
    local e = nodes[name]
    if not e then return nil, "/dev/" .. name .. ": no such device" end
    return e
end

--- fstype 处理器的输入: 描述设备的数据源。
local function sourceOf(e)
    if e.type == "part" then return { img = e.img } end
    return { ccpath = e.mountPath }
end

--- 旧式: 真实后端上的块设备镜像路径(如 /parts/root.img)或 CC fs 路径。
local function mountRealPath(path, dir, fst)
    local backend, rel, rerr = vfs.resolve(path)
    if not backend then return nil, path .. ": " .. tostring(rerr) end
    if not backend.toReal then return nil, path .. ": not on a real filesystem" end
    local real = backend.toReal(rel)
    local src = (fst == "ccdisk") and { ccpath = real } or { img = real }
    local handler = fstypes[fst]
    if not handler then return nil, "unknown fstype: " .. fst end
    local ok, b, meta = pcall(handler, src, dir)
    if not ok then return nil, path .. ": " .. tostring(b) end
    if not b then return nil, path .. ": " .. tostring(meta) end
    meta = meta or {}
    meta.device, meta.fstype = path, fst
    vfs.mount(dir, b, meta)
    return true, { device = path, fstype = fst }
end

--- 挂载电脑自带存储上的 ext2 分区。
---@param path string 镜像路径(如 /parts/root.img)
---@param dir string 挂载点
---@param fstype string|nil 文件系统类型(默认 ext2)
---@return boolean|nil ok, table|string 成功时第二值是 { device, fstype }
function devdisk.mountLocal(path, dir, fstype)
    if not vfs_api.fs.exists(path) then
        return nil, path .. ": file not found"
    end
    local fst = fstype or "ext2"
    -- 直接使用文件路径作为设备节点
    local src = { img = path }
    local handler = fstypes[fst]
    if not handler then return nil, "unknown fstype: " .. fst end
    local ok, b, meta = pcall(handler, src, dir)
    if not ok then return nil, path .. ": " .. tostring(b) end
    if not b then return nil, path .. ": " .. tostring(meta) end
    meta = meta or {}
    meta.device, meta.fstype = path, fst
    vfs.mount(dir, b, meta)
    return true, { device = path, fstype = fst }
end

--- 挂载一个文件系统。
---@param device string /dev/sdX | /dev/ccdiskN | UUID=<uuid> | 真实后端路径(兼容旧式)
---@param dir string 挂载点(VFS 目录, 必须已存在)
---@param fstype string|nil 显式类型; nil 时按设备条目自带类型
---@return boolean|nil ok, table|string 成功时第二值是 { device, fstype, uuid }
function devdisk.mount(device, dir, fstype)
    if not vfs_api.fs.isDir(dir) then return nil, dir .. ": mount point does not exist" end

    -- 设备节点规格: UUID=<uuid> | /dev/sdX | 不含 "/" 的裸节点名; 其余按真实路径处理(旧式)。
    local isNodeSpec = device:sub(1, 5) == "UUID=" or device:sub(1, 5) == "/dev/"
        or not device:find("/", 1, true)
    if not isNodeSpec then return mountRealPath(device, dir, fstype or "ext2") end
    local e, err = devdisk.find(device)
    if not e then return nil, err end

    local fst = fstype or e.fstype
    if fst ~= e.fstype then
        return nil, e.node .. " is " .. e.fstype .. ", not " .. fst
    end
    local handler = fstypes[fst]
    if not handler then return nil, "unknown fstype: " .. fst .. " (module not loaded?)" end
    local ok, b, meta = pcall(handler, sourceOf(e), dir)
    if not ok then return nil, e.node .. ": " .. tostring(b) end
    if not b then return nil, e.node .. ": " .. tostring(meta) end
    meta = meta or {}
    meta.device, meta.fstype, meta.uuid = e.node, fst, e.uuid
    vfs.mount(dir, b, meta)
    return true, { device = e.node, fstype = fst, uuid = e.uuid }
end

--- 卸载 dir 上的文件系统(并关闭其块设备)。
---@return boolean|nil ok, string|nil err
function devdisk.umount(dir)
    for _, mt in ipairs(vfs.list()) do
        if mt.root == dir then
            vfs.unmount(dir)
            if mt.meta and mt.meta.cleanup then mt.meta.cleanup() end
            return true
        end
    end
    return nil, dir .. ": not mounted"
end

return devdisk
