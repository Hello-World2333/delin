--[[ Delin 引导装载器 DLUB (独立于内核的文件, 类似 GRUB).
     自包含: 读 /dlub.cfg 锁定根来源 -> 打开根文件系统 -> 读内核镜像 -> 设 _G.__boot_info
     -> 运行内核。三种根来源(互斥, 由 /dlub.cfg 显式指定, fail-fast 不扫描不回退):

       1. rootfs <镜像路径>  根 = 电脑自带存储上的一个 ext2 镜像文件(如 /parts/root.img)。
       2. bootdisk <外设名>  根 = 磁盘上 /parts/manifest 的 root 行指向的 ext2 分区。
       3. ccdisk <外设名>    根 = 该磁盘的 CC 原生文件系统本身(即"把 CCFS 装在磁盘上")。

     多磁盘时 peripheral.getNames() 顺序不可靠(数据盘可能先被枚举到), 所以根来源只能显式
     指定: 配置缺失/语法错误/该外设不是磁盘驱动/盘上没东西 一律报错。

     内核镜像位置: rootfs/bootdisk 模式读根里的 __boot_info.bootPath(默认 /boot/delin.lua);
     ccdisk 模式读该盘的 /boot/delin.lua。 ]]

local blockdev = require("kernel.blockdev")
local ext2     = require("kernel.ext2")
local manifest = require("kernel.manifest")
local dlubcfg  = require("kernel.dlubcfg")

local dlub = {}

--- 校验外设是一个有数据的磁盘驱动器, 返回其 CC 挂载路径。
local function diskMount(name, cfgKey)
    if peripheral.getType(name) ~= "drive" then
        error("/dlub.cfg: " .. cfgKey .. " " .. name .. " is not a disk drive", 0)
    end
    if not disk.hasData(name) then
        error("/dlub.cfg: " .. cfgKey .. " " .. name .. " has no disk data", 0)
    end
    return disk.getMountPath(name)
end

--- 读内核镜像并启动(接管, 不返回)。
--- 内核路径是各模式的既定契约, 读不到就报错 —— 不回退到别的路径。
local function loadKernel(w, kernelPath, bootInfo)
    local kernelSrc
    if bootInfo.rootFstype == "ext2" then
        local inode = ext2.lookup(bootInfo._rfs, kernelPath)
        kernelSrc = inode and ext2.readFile(bootInfo._rfs, inode)
        if not kernelSrc then error("no kernel at " .. kernelPath .. " in " .. bootInfo.rootPath, 0) end
    else
        local f = fs.open(bootInfo.rootPath .. kernelPath, "r")
        if not f then error("no kernel at " .. bootInfo.rootPath .. kernelPath, 0) end
        kernelSrc = f.readAll()
        f.close()
    end

    w("root=" .. bootInfo.rootPath .. " fs=" .. bootInfo.rootFstype
        .. " kernel=" .. kernelPath .. " (" .. #kernelSrc .. " bytes)")
    bootInfo.bootPath = kernelPath
    bootInfo._rfs = nil
    _G.__boot_info = bootInfo

    local chunk, lerr = load(kernelSrc, kernelPath, "t", _G)
    if not chunk then error("kernel load: " .. tostring(lerr), 0) end
    return chunk
end

function dlub.master()
    -- DLUB 自己的日志(追加; 内核会接管 /delin.log)
    local log = fs.open("/delin.log", "w")
    local function w(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        local line = "[DLUB] " .. table.concat(parts, "\t")
        if log then log.writeLine(line); log.flush() end
        print(line)
    end

    local ok, err = pcall(function()
        -- 读**电脑自身 FS** 上的 /dlub.cfg: 显式指定根来源。
        local cf = fs.open("/dlub.cfg", "r")
        if not cf then error("no /dlub.cfg (write one of: rootfs <img> | bootdisk <drive> | ccdisk <drive>)", 0) end
        local cfgText = cf.readAll(); cf.close()
        local cfg, cerr = dlubcfg.parse(cfgText)
        if not cfg then error("/dlub.cfg: " .. cerr, 0) end

        local bootInfo, chunk

        -- 模式 1: 根 = 电脑自带存储上的 ext2 镜像
        if cfg.rootfs then
            local rootfs = cfg.rootfs
            if rootfs:sub(1, 1) ~= "/" then rootfs = "/" .. rootfs end
            if not fs.exists(rootfs) then
                error("/dlub.cfg: rootfs " .. rootfs .. " not found", 0)
            end
            w("config /dlub.cfg rootfs=" .. rootfs)
            local bd, berr = blockdev.file(rootfs)
            if not bd then error("blockdev: " .. tostring(berr), 0) end
            local rfs, ferr = ext2.mount(bd)
            if not rfs then error("fs ext2: " .. tostring(ferr), 0) end
            bootInfo = { blockDevice = bd, rootFstype = "ext2", rootPath = rootfs, _rfs = rfs }
            chunk = loadKernel(w, "/boot/delin.lua", bootInfo)

        -- 模式 2: 根 = 磁盘上 manifest 的 root 分区(ext2)
        elseif cfg.bootdisk then
            local name = cfg.bootdisk
            local diskMp = diskMount(name, "bootdisk")
            if not fs.exists(diskMp .. "/parts/manifest") then
                error("/dlub.cfg: bootdisk " .. name .. " has no " .. diskMp .. "/parts/manifest", 0)
            end
            w("config /dlub.cfg bootdisk=" .. name .. " -> " .. diskMp)
            local mf = fs.open(diskMp .. "/parts/manifest", "r")
            if not mf then error("cannot open manifest", 0) end
            local m = manifest.parse(mf.readAll()); mf.close()
            local root = manifest.findRoot(m)
            if not root then error("no root partition in " .. name .. ":/parts/manifest", 0) end

            local bd, berr = blockdev.file(diskMp .. root.path)
            if not bd then error("blockdev: " .. tostring(berr), 0) end
            local rfs, ferr = ext2.mount(bd)
            if not rfs then error("fs " .. (root.fstype or "?") .. ": " .. tostring(ferr), 0) end
            bootInfo = { blockDevice = bd, rootFstype = "ext2", rootPath = diskMp .. root.path, _rfs = rfs }
            chunk = loadKernel(w, m.boot or "/boot/delin.lua", bootInfo)

        -- 模式 3: 根 = 磁盘的 CC 原生文件系统本身(CCFS 装在磁盘上)
        else
            local name = cfg.ccdisk
            local diskMp = diskMount(name, "ccdisk")
            w("config /dlub.cfg ccdisk=" .. name .. " -> " .. diskMp)
            bootInfo = { rootFstype = "ccdisk", rootPath = diskMp }
            chunk = loadKernel(w, "/boot/delin.lua", bootInfo)
        end

        if log then log.close(); log = nil end
        chunk() -- 运行内核(接管, 不返回)
    end)
    if not ok then
        w("ERROR: " .. tostring(err))
        if log then log.close(); log = nil end
        error("DLUB failed: " .. tostring(err), 0)
    end
end

return dlub
