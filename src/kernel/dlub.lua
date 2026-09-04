--[[ Delin 引导装载器 DLUB (类似 GRUB).
     读 /parts/manifest -> 打开 root 分区为块设备 -> 挂 ext2 -> 读内核镜像
     -> 设置 __boot_info -> 运行内核。 ]]

local blockdev = require("kernel.blockdev")
local ext2     = require("kernel.ext2")
local manifest = require("kernel.manifest")

local dlub = {}

--- 引导。
---@param diskMountPath string 真实 fs 挂载路径(如 "disk")
---@param log fun(...) 日志
---@return boolean, string|nil
function dlub.boot(diskMountPath, log)
    log = log or function(...) print(...) end
    local mf = fs.open(diskMountPath .. "/parts/manifest", "r")
    if not mf then return nil, "no manifest on " .. diskMountPath end
    local content = mf.readAll(); mf.close()
    local m = manifest.parse(content)
    local root = manifest.findRoot(m)
    if not root then return nil, "no root partition in manifest" end
    local imgPath = diskMountPath .. root.path
    local bd, err = blockdev.file(imgPath)
    if not bd then return nil, "blockdev: " .. tostring(err) end
    local rfs, ferr = ext2.mount(bd)
    if not rfs then return nil, "fs " .. (root.fstype or "?") .. ": " .. tostring(ferr) end
    local bootPath = m.boot or "/boot/delin.lua"
    local inode = ext2.lookup(rfs, bootPath)
    local kernelSrc = inode and ext2.readFile(rfs, inode)
    if not kernelSrc then return nil, "no kernel at " .. bootPath .. " in " .. root.path end
    log("dlub: root=" .. root.path .. " fs=" .. root.fstype .. " kernel=" .. bootPath .. " (" .. #kernelSrc .. " bytes)")
    _G.__boot_info = { blockDevice = bd, rootFstype = root.fstype, rootPath = root.path, bootPath = bootPath }
    local chunk, lerr = load(kernelSrc, bootPath, "t", _G)
    if not chunk then return nil, "kernel load: " .. tostring(lerr) end
    chunk() -- 运行内核
    return true
end

return dlub
