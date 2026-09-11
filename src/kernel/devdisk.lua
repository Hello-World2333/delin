--[[ Delin 存储设备抽象 (/dev/sdX): 电脑自带存储 + 磁盘驱动器。
     CC 没有裸块 API, 存储只给两样东西:
       1. CC 原生文件系统的真实路径(disk.getMountPath / 自带存储的 "")  -> 整盘设备 (fstype ccdisk)
       2. 该存储 /parts/*.img 文件(可字节读写)                          -> 分区设备 /dev/sdaN (fstype ext2)
     命名: **电脑自带存储恒为 /dev/sda**(它不是外设, peripheral.getNames() 里没有它),
           磁盘驱动器接在其后按 disk.getID() 升序编号 b,c,..(与 peripheral.getNames() 顺序/槽位
           无关, 重启后同一块盘仍是同一个字母); 无 ID 的介质(放进驱动器的电脑/海龟)排最后。
           分区号 = 该存储 /parts/manifest 中分区行的序号(1 起, root 行在前);
           另有 /dev/ccdiskN 作为整盘 CC 原生 fs 的别名节点(N 从 0 起, 同 sda、sdb)。
     UUID: CC 没有文件系统 UUID, 用 ID 模拟,**两类介质的数字空间是分开的所以各带前缀**:
           磁盘驱动器 "d<磁盘ID>"/"d<磁盘ID>-<分区号>", 电脑自带存储 "c<电脑ID>"/"c<电脑ID>-<分区号>"。
           前缀不是装饰: 磁盘 ID 与电脑 ID 各自递增, 纯数字会撞号(d0 与电脑 0 无法区分)。
           CC 对自带存储(以及放进驱动器的电脑/海龟)**根本不给 ID**(disk.getID 只认软盘),
           无 ID 的介质不产生 UUID, 因而不能用 UUID= 挂载。
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

--- 电脑自带存储的驱动器条目: CC 原生 fs 的根, 挂载路径前缀是 ""(见 vfs.real(""))。
--- 它不是外设(peripheral.getNames() 里没有它), 但和磁盘驱动器一样有 /parts/manifest 分区。
local function rootDrive()
    return {
        side = "root", internal = true, mountPath = "",
        diskId = nil, label = os.getComputerLabel(),
    }
end

--- fs API 的路径: 自带存储的挂载前缀是 "", 对 fs 调用得写成 "/"。
local function fsPath(mountPath)
    return mountPath == "" and "/" or mountPath
end

--- 驱动列表: 电脑自带存储恒在首位(-> sda), 磁盘驱动器按磁盘 ID 升序接在其后
--- (无 ID 的介质排最后, 按槽位名)。
local function drives()
    local list = { rootDrive() }
    local rest = {}
    for _, side in ipairs(peripheral.getNames()) do
        if disk.hasData(side) then
            local mp = disk.getMountPath(side)
            if not mp then error("devdisk: " .. side .. ": disk.hasData but no mount path", 0) end
            rest[#rest + 1] = {
                side = side,
                mountPath = mp,
                diskId = disk.getID(side),
                label = disk.getLabel(side),
            }
        end
    end
    table.sort(rest, function(a, b)
        if a.diskId and b.diskId then
            if a.diskId ~= b.diskId then return a.diskId < b.diskId end
        elseif a.diskId ~= b.diskId then
            return a.diskId ~= nil
        end
        return a.side < b.side
    end)
    for _, d in ipairs(rest) do list[#list + 1] = d end
    return list
end

--- 模拟 UUID 的前缀: 自带存储 "c<电脑ID>", 磁盘 "d<磁盘ID>"; 无 ID 的介质没有 UUID。
local function uuidPrefix(d)
    if d.internal then return "c" .. tostring(os.getComputerID()) end
    if d.diskId then return "d" .. tostring(d.diskId) end
    return nil
end

--- 读存储上 /parts/manifest(不存在则返回 nil, 即该存储无分区)。
local function readPartManifest(mountPath)
    local f = fs.open(mountPath .. "/parts/manifest", "r")
    if not f then return nil end
    local content = f.readAll()
    f.close()
    return manifest.parse(content)
end

--- 扫描所有存储(电脑自带存储 + 各磁盘驱动器), 返回规范设备条目(不含别名节点)。不注册 /dev。
---@return table[]
function devdisk.scan()
    local out = {}
    for i, d in ipairs(drives()) do
        local base = "sd" .. diskLetter(i)
        local uuid = uuidPrefix(d)
        out[#out + 1] = {
            name = base, node = "/dev/" .. base, type = "disk", fstype = "ccdisk",
            uuid = uuid, diskId = d.diskId, internal = d.internal, index = i,
            side = d.side, label = d.label,
            mountPath = d.mountPath, size = fs.getCapacity(fsPath(d.mountPath)),
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
                    diskId = d.diskId, internal = d.internal, index = i, part = n, role = p.role,
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

--- 重新扫描存储(自带存储 + 磁盘驱动器)并刷新 /dev 节点(盘插入/弹出时由内核事件钩子调用)。
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

--- 按存储的 CC 挂载路径找整盘条目("" = 电脑自带存储, "disk2" = 某个驱动器里的盘)。
--- 根引导用它把根挂载对上设备节点(根 = 存储本身时显示为 /dev/sdX, 不是 "rootfs")。
---@return table|nil entry
function devdisk.byMountPath(mountPath)
    for _, e in ipairs(devdisk.list()) do
        if e.type == "disk" and e.mountPath == mountPath then return e end
    end
    return nil
end

--- 解析设备规格: "/dev/sda1" | "sda1" | "ccdisk0" | "UUID=<uuid>"(d<磁盘ID>[-分区号] /
--- c<电脑ID>[-分区号])。
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
