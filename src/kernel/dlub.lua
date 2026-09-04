--[[ Delin 引导装载器 DLUB (独立于内核的文件, 类似 GRUB).
     自包含: 找引导盘 -> 读 /parts/manifest -> 开 root 分区为块设备 -> 挂 ext2
     -> 读内核镜像 -> 设 _G.__boot_info -> 运行内核。 ]]

local blockdev = require("kernel.blockdev")
local ext2     = require("kernel.ext2")
local manifest = require("kernel.manifest")

local dlub = {}

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
        -- 找带 /parts/manifest 的引导盘
        local diskMp = nil
        for _, name in ipairs(peripheral.getNames()) do
            if disk.hasData(name) then
                local mp = disk.getMountPath(name)
                if mp and fs.exists(mp .. "/parts/manifest") then diskMp = mp; break end
            end
        end
        if not diskMp then error("no disk with /parts/manifest", 0) end

        local mf = fs.open(diskMp .. "/parts/manifest", "r")
        if not mf then error("cannot open manifest", 0) end
        local content = mf.readAll(); mf.close()
        local m = manifest.parse(content)
        local root = manifest.findRoot(m)
        if not root then error("no root partition in manifest", 0) end

        local bd, err = blockdev.file(diskMp .. root.path)
        if not bd then error("blockdev: " .. tostring(err), 0) end
        local rfs, ferr = ext2.mount(bd)
        if not rfs then error("fs " .. (root.fstype or "?") .. ": " .. tostring(ferr), 0) end

        local bootPath = m.boot or "/boot/delin.lua"
        local inode = ext2.lookup(rfs, bootPath)
        local kernelSrc = inode and ext2.readFile(rfs, inode)
        if not kernelSrc then error("no kernel at " .. bootPath, 0) end

        w("root=" .. root.path .. " fs=" .. root.fstype .. " kernel=" .. bootPath .. " (" .. #kernelSrc .. " bytes)")
        _G.__boot_info = { blockDevice = bd, rootFstype = root.fstype, rootPath = root.path, bootPath = bootPath }

        local chunk, lerr = load(kernelSrc, bootPath, "t", _G)
        if not chunk then error("kernel load: " .. tostring(lerr), 0) end
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
