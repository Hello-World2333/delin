--[[ Delin EXT2 文件系统(读写).
     Mount 在一个块设备上; 块大小从 superblock 读; inode 的 mode/uid/gid/类型暴露。
     phase B 修订: 间接块(单/双)、多块组、删除/截断回收块、真实 ".."、硬链接计数、
     isReadOnly=false、时间戳用秒、新块清零、保留块、符号链接、特殊文件类型。
     另含两个"整盘级"入口: mkfs(建空白 fs: 块大小/inode 数/保留块/卷标可调, 单块组)
     与 fsck(五趟检查与修复: inode/块 -> 目录结构 -> 连通性 -> 引用计数 -> 位图与计数)。
     两者都是 /bin/mkfs.ext2、/bin/fsck.ext2 的内核实现, 裁判是宿主 e2fsck。 ]]

local ext2 = {}

-- 权限需要当前进程 uid/gid; 不在内核 bundle 里(如 DLUB 引导器)则视为 root(不强制)。
local process = nil
pcall(function() process = require("kernel.process") end)

-- 命名管道(FIFO)的缓冲区注册表。ext2 只负责"这个 inode 是 FIFO"这件事; 读写与阻塞语义
-- 全在 kernel/fifo.lua(与匿名管道共用一套缓冲与协作式阻塞)。同一 inode 被反复 open 时,
-- 每次都从同一个缓冲区上挂一端, 所以 `cat fifo` 与 `echo x > fifo` 互不干扰。
local fifo = require("kernel.fifo")

-- 权限强制辅助(及早定义, 供 create/backend 使用)
local function cred() if not process then return { uid = 0, gid = 0 } end return process.current() end
--- 按位"a AND NOT mask"(不用位运算符: 宿主 Lua 5.1 没有, 项目统一用算术实现)。
local function andNot(a, mask)
    local r, bit = 0, 1
    for _ = 1, 12 do
        if a % 2 == 1 and mask % 2 == 0 then r = r + bit end
        a = math.floor(a / 2); mask = math.floor(mask / 2); bit = bit * 2
    end
    return r
end

--- 把 POSIX umask 应用到新建节点的权限位。
--- 放在**内核这一层**而不是各工具里: 新建文件的地方有好几处(fs.open "w"、makeDir、mkfifo),
--- 让每个工具自己收窄权限, 漏一个就多出几个"世界可写"的文件; 而且工具往往先收窄一遍、
--- 内核再来一遍 —— 那就是叠了两次, 权限会比用户要的更紧。
---@param mode integer 含类型位的完整 mode
---@return integer
local applyUmask

local function hasPerm(inode, uid, gid, perm) -- perm: 1=x,2=w,4=r
    if uid == 0 then return true end
    local c = (uid == inode.uid) and 6 or ((gid == inode.gid) and 3 or 0)
    local m = math.floor(inode.perms / (2 ^ c)) % 8
    return m % (perm * 2) >= perm
end
-- 低 9 位里是否有任何一个 x 位(u/g/o 其一)。root 执行文件时用得上: POSIX 下 root 绕过的是
-- r/w 检查, **不**绕过 x —— 文件必须至少有一个 x 位才可执行。
local function anyExecBit(perms)
    local p = perms % 512
    return (p % 2) == 1 or (math.floor(p / 8) % 2) == 1 or (math.floor(p / 64) % 2) == 1
end

-- 读小端
local function u16(s, off) local a, b = s:byte(off + 1, off + 2); return a + b * 256 end
local function u32(s, off) local a, b, c, d = s:byte(off + 1, off + 4); return a + b * 256 + c * 65536 + d * 16777216 end
-- 写小端
local function w16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function w32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
local function setU16(s, off, v) return s:sub(1, off) .. w16(v) .. s:sub(off + 3) end
local function setU32(s, off, v) return s:sub(1, off) .. w32(v) .. s:sub(off + 5) end

local function readBlockStr(fs, blockNum) return fs.bd.read(blockNum * fs.blockSize, fs.blockSize) end
local function writeBlockStr(fs, blockNum, data) return fs.bd.write(blockNum * fs.blockSize, data) end

-- inode 类型与文件类型字节
local T_FIFO, T_DIR, T_REG, T_SYM = 0x1000, 0x4000, 0x8000, 0xA000
local FT_REG, FT_DIR, FT_SYM, FT_CHR, FT_BLK, FT_FIFO, FT_SOCK, FT_UNK = 1, 2, 7, 3, 4, 5, 6, 0
local function itype(mode) return math.floor(mode / 0x1000) * 0x1000 end
local function iperms(mode) return mode % 0x1000 end

--- 把 POSIX umask 应用到新建节点的权限位(定义在这里是因为要用 itype/iperms)。
--- 放在**内核这一层**而不是各工具里: 新建文件的入口有好几处(fs.open "w"、makeDir、mkfifo),
--- 让每个工具自己收窄权限, 漏一个就多出几个"世界可写"的文件; 而且工具往往先收窄一遍、
--- 内核再来一遍 —— 那就是叠了两次, 权限会比用户要的更紧。
---@param mode integer 含类型位的完整 mode
---@return integer
applyUmask = function(mode)
    -- 符号链接**不受 umask 影响**: Linux 上链接的权限位恒为 0777(lchmod 都不允许改),
    -- 它只是历史遗留, 内核从不拿它做权限判定。若在这里一并收窄, `ln -s` 建出来的链接
    -- 会变成 0755, 与 Linux 不一致(也被 ls -l 直接看出来)。
    if itype(mode) == T_SYM then return mode end
    local u = cred().umask or tonumber("022", 8)
    return itype(mode) + andNot(iperms(mode), u)
end
local function typeToFileType(t)
    if t == T_DIR then return FT_DIR end
    if t == T_REG then return FT_REG end
    if t == T_SYM then return FT_SYM end
    if t == 0x2000 then return FT_CHR end
    if t == 0x6000 then return FT_BLK end
    if t == 0x1000 then return FT_FIFO end
    if t == 0xC000 then return FT_SOCK end
    return FT_UNK
end

---@class Ext2Fs
---@field bd table
---@field blockSize number
---@field inodesPerGroup number
---@field inodeSize number
---@field firstIno number
---@field inodes number
---@field blocks number
---@field blocksPerGroup number
---@field numGroups number
---@field gdtOffset number
---@field rBlocks number

local function readGroupDesc(fs, group)
    local gdt = fs.bd.read(fs.gdtOffset + group * 32, 32)
    return {
        blockBitmap = u32(gdt, 0),
        inodeBitmap = u32(gdt, 4),
        inodeTable = u32(gdt, 8),
        freeBlocks = u16(gdt, 12),
        freeInodes = u16(gdt, 14),
    }
end

local function inodeDiskOffset(fs, ino)
    local group = math.floor((ino - 1) / fs.inodesPerGroup)
    local index = (ino - 1) % fs.inodesPerGroup
    local gd = readGroupDesc(fs, group)
    return gd.inodeTable * fs.blockSize + index * fs.inodeSize
end

local function readRawInode(fs, ino) return fs.bd.read(inodeDiskOffset(fs, ino), fs.inodeSize) end

function ext2.mount(bd)
    local sb = bd.read(1024, 1024)
    if not sb or #sb < 1024 then return nil, "cannot read superblock" end
    if u16(sb, 56) ~= 0xEF53 then return nil, "not EXT2" end
    local logBlock = u32(sb, 24)
    local blockSize = 1024 * 2 ^ logBlock
    local inodes = u32(sb, 0)
    local fs = {
        bd = bd,
        blockSize = blockSize,
        inodes = inodes,
        blocks = u32(sb, 4),
        rBlocks = u32(sb, 8),
        firstDataBlock = u32(sb, 20),   -- s_first_data_block: blockSize==1024 时为 1(block0=boot), 否则 0
        inodesPerGroup = u32(sb, 40),
        blocksPerGroup = u32(sb, 32),
        inodeSize = u16(sb, 88) or 128,
        firstIno = u32(sb, 84),
        gdtOffset = (blockSize == 1024) and (2 * blockSize) or (1 * blockSize),
    }
    -- 块组数(权威: 由块布局决定; 与 inode 组数在合法 fs 上一致)
    fs.numGroups = math.max(math.ceil((fs.blocks - fs.firstDataBlock) / fs.blocksPerGroup),
                            math.ceil(inodes / fs.inodesPerGroup))
    return fs
end

function ext2.readInode(fs, ino)
    local group = math.floor((ino - 1) / fs.inodesPerGroup)
    local index = (ino - 1) % fs.inodesPerGroup
    local gd = readGroupDesc(fs, group)
    local inodeOffset = gd.inodeTable * fs.blockSize + index * fs.inodeSize
    local raw = fs.bd.read(inodeOffset, fs.inodeSize)
    if not raw then return nil end
    local i = {
        ino = ino, mode = u16(raw, 0), uid = u16(raw, 2),
        sizeLo = u32(raw, 4), gid = u16(raw, 24),
        links = u16(raw, 26), blocks = u32(raw, 28),
        sizeHigh = u32(raw, 108),
    }
    i.size = i.sizeHigh * 4294967296 + i.sizeLo
    i.type = itype(i.mode)
    i.perms = iperms(i.mode)
    i.mtime = u32(raw, 16)
    i.ptrs = {}
    for n = 0, 14 do i.ptrs[n + 1] = u32(raw, 40 + n * 4) end
    return i
end

function ext2.writeInode(fs, inode)
    local raw = string.rep("\0", fs.inodeSize)
    raw = setU16(raw, 0, inode.mode)
    raw = setU16(raw, 2, inode.uid or 0)
    local sizeVal = inode.size or 0
    raw = setU32(raw, 4, sizeVal % 4294967296)
    raw = setU32(raw, 8, inode.atime or 0)
    raw = setU32(raw, 12, inode.ctime or 0)
    raw = setU32(raw, 16, inode.mtime or 0)
    raw = setU16(raw, 24, inode.gid or 0)
    raw = setU16(raw, 26, inode.links or 1)
    raw = setU32(raw, 28, inode.blocks or 0)
    for n = 1, 15 do raw = setU32(raw, 40 + (n - 1) * 4, inode.ptrs[n] or 0) end
    raw = setU32(raw, 108, math.floor(sizeVal / 4294967296))
    return fs.bd.write(inodeDiskOffset(fs, inode.ino), raw)
end

-- ---------------------------------------------------------------
-- 块/inode 分配(多块组), 空闲计数, 保留块
-- ---------------------------------------------------------------
local function sbFreeBlocks(fs) return u32(fs.bd.read(1024, 1024), 12) end
local function updateFreeCounters(fs, group, dBlocks, dInodes, dDirs)
    local sb = fs.bd.read(1024, fs.blockSize)
    sb = setU32(sb, 12, (u32(sb, 12) or 0) + dBlocks)
    sb = setU32(sb, 16, (u32(sb, 16) or 0) + dInodes)
    fs.bd.write(1024, sb)
    local gdt = fs.bd.read(fs.gdtOffset + group * 32, 32)
    gdt = setU16(gdt, 12, (u16(gdt, 12) or 0) + dBlocks)
    gdt = setU16(gdt, 14, (u16(gdt, 14) or 0) + dInodes)
    -- bg_used_dirs_count(偏移 16): 不维护它, fsck 会报 "Directories count wrong for group #N"。
    if dDirs and dDirs ~= 0 then
        gdt = setU16(gdt, 16, (u16(gdt, 16) or 0) + dDirs)
    end
    fs.bd.write(fs.gdtOffset + group * 32, gdt)
end

--- 分配一个数据块(多块组, 保留块, 清零)。返回全局块号。
function ext2.allocBlock(fs)
    if sbFreeBlocks(fs) <= fs.rBlocks then return nil end -- 保留区不分配
    local per = fs.blocksPerGroup
    local base = fs.firstDataBlock
    for group = 0, fs.numGroups - 1 do
        local gd = readGroupDesc(fs, group)
        if gd.freeBlocks > 0 then
            local bitmap = readBlockStr(fs, gd.blockBitmap)
            local start = base + group * per
            local limit = math.min(per, fs.blocks - start) - 1
            for bit = 0, limit do
                local v = bitmap:byte(math.floor(bit / 8) + 1) or 0
                if math.floor(v / 2 ^ (bit % 8)) % 2 == 0 then
                    local pos = math.floor(bit / 8) + 1
                    bitmap = bitmap:sub(1, pos - 1) .. string.char(v + 2 ^ (bit % 8)) .. bitmap:sub(pos + 1)
                    writeBlockStr(fs, gd.blockBitmap, bitmap)
                    updateFreeCounters(fs, group, -1, 0)
                    local blk = start + bit
                    writeBlockStr(fs, blk, string.rep("\0", fs.blockSize)) -- 清零
                    return blk
                end
            end
        end
    end
    return nil
end

--- 释放一个数据块。
function ext2.freeBlock(fs, blk)
    if blk < fs.firstDataBlock then return end -- boot 块等元数据区, 不释放
    local rel = blk - fs.firstDataBlock
    local group = math.floor(rel / fs.blocksPerGroup)
    local bit = rel % fs.blocksPerGroup
    local gd = readGroupDesc(fs, group)
    local bitmap = readBlockStr(fs, gd.blockBitmap)
    local pos = math.floor(bit / 8) + 1
    local v = bitmap:byte(pos) or 0
    if math.floor(v / 2 ^ (bit % 8)) % 2 == 1 then
        v = v - 2 ^ (bit % 8)
        bitmap = bitmap:sub(1, pos - 1) .. string.char(v) .. bitmap:sub(pos + 1)
        writeBlockStr(fs, gd.blockBitmap, bitmap)
        updateFreeCounters(fs, group, 1, 0)
    end
end

--- 分配并初始化一个 inode(多块组)。
function ext2.allocInode(fs, mode, uid, gid)
    local per = fs.inodesPerGroup
    for group = 0, fs.numGroups - 1 do
        local gd = readGroupDesc(fs, group)
        if gd.freeInodes > 0 then
            local bitmap = readBlockStr(fs, gd.inodeBitmap)
            for bit = (fs.firstIno - 1), (per - 1) do
                local v = bitmap:byte(math.floor(bit / 8) + 1) or 0
                if math.floor(v / 2 ^ (bit % 8)) % 2 == 0 then
                    local pos = math.floor(bit / 8) + 1
                    bitmap = bitmap:sub(1, pos - 1) .. string.char(v + 2 ^ (bit % 8)) .. bitmap:sub(pos + 1)
                    writeBlockStr(fs, gd.inodeBitmap, bitmap)
                    local ino = group * per + bit + 1
                    local now = math.floor(os.epoch("utc") / 1000)
                    local inode = { ino = ino, mode = mode, uid = uid or 0, gid = gid or 0, links = 1, size = 0, blocks = 0, atime = now, ctime = now, mtime = now, ptrs = {} }
                    for n = 1, 15 do inode.ptrs[n] = 0 end
                    ext2.writeInode(fs, inode)
                    updateFreeCounters(fs, group, 0, -1, itype(mode) == T_DIR and 1 or 0)
                    return ino
                end
            end
        end
    end
    return nil
end

function ext2.freeInode(fs, ino)
    local group = math.floor((ino - 1) / fs.inodesPerGroup)
    local bit = (ino - 1) % fs.inodesPerGroup
    local gd = readGroupDesc(fs, group)
    local bitmap = readBlockStr(fs, gd.inodeBitmap)
    local pos = math.floor(bit / 8) + 1
    local v = bitmap:byte(pos) or 0
    if math.floor(v / 2 ^ (bit % 8)) % 2 == 1 then
        local inode = ext2.readInode(fs, ino)
        local wasDir = inode and inode.type == T_DIR
        v = v - 2 ^ (bit % 8)
        bitmap = bitmap:sub(1, pos - 1) .. string.char(v) .. bitmap:sub(pos + 1)
        writeBlockStr(fs, gd.inodeBitmap, bitmap)
        updateFreeCounters(fs, group, 0, 1, wasDir and -1 or 0)
        fs.bd.write(inodeDiskOffset(fs, ino), string.rep("\0", fs.inodeSize))
    end
end

-- ---------------------------------------------------------------
-- 逻辑块 -> 物理块 (含间接块)
-- ---------------------------------------------------------------
local function perIndirect(fs) return math.floor(fs.blockSize / 4) end

function ext2.getBlock(fs, inode, idx)
    local per = perIndirect(fs)
    if idx < 12 then return inode.ptrs[idx + 1] end
    idx = idx - 12
    if idx < per then
        if inode.ptrs[13] == 0 then return 0 end
        return u32(readBlockStr(fs, inode.ptrs[13]), idx * 4)
    end
    idx = idx - per
    if idx < per * per then
        if inode.ptrs[14] == 0 then return 0 end
        local ddata = readBlockStr(fs, inode.ptrs[14])
        local ind = u32(ddata, math.floor(idx / per) * 4)
        if ind == 0 then return 0 end
        return u32(readBlockStr(fs, ind), (idx % per) * 4)
    end
    return 0 -- 超出单/双间接(文件过大)
end

local function addUsed(fs, inode) inode.blocks = inode.blocks + math.floor(fs.blockSize / 512) end

--- 确保逻辑块 idx 有物理块; 按需分配(含间接块链)。
function ext2.ensureBlock(fs, inode, idx)
    local per = perIndirect(fs)
    if idx < 12 then
        if inode.ptrs[idx + 1] == 0 then
            inode.ptrs[idx + 1] = ext2.allocBlock(fs)
            if inode.ptrs[idx + 1] then addUsed(fs, inode) end
        end
        return inode.ptrs[idx + 1]
    end
    idx = idx - 12
    if idx < per then
        if inode.ptrs[13] == 0 then
            inode.ptrs[13] = ext2.allocBlock(fs); if not inode.ptrs[13] then return nil end
            addUsed(fs, inode); writeBlockStr(fs, inode.ptrs[13], string.rep("\0", fs.blockSize))
        end
        local data = readBlockStr(fs, inode.ptrs[13])
        local blk = u32(data, idx * 4)
        if blk == 0 then
            blk = ext2.allocBlock(fs); if not blk then return nil end
            data = setU32(data, idx * 4, blk); writeBlockStr(fs, inode.ptrs[13], data); addUsed(fs, inode)
        end
        return blk
    end
    idx = idx - per
    if idx < per * per then
        if inode.ptrs[14] == 0 then
            inode.ptrs[14] = ext2.allocBlock(fs); if not inode.ptrs[14] then return nil end
            addUsed(fs, inode); writeBlockStr(fs, inode.ptrs[14], string.rep("\0", fs.blockSize))
        end
        local ddata = readBlockStr(fs, inode.ptrs[14])
        local dOff = math.floor(idx / per) * 4
        local ind = u32(ddata, dOff)
        if ind == 0 then
            ind = ext2.allocBlock(fs); if not ind then return nil end
            ddata = setU32(ddata, dOff, ind); writeBlockStr(fs, inode.ptrs[14], ddata); addUsed(fs, inode)
            writeBlockStr(fs, ind, string.rep("\0", fs.blockSize))
        end
        local indata = readBlockStr(fs, ind)
        local iOff = (idx % per) * 4
        local blk = u32(indata, iOff)
        if blk == 0 then
            blk = ext2.allocBlock(fs); if not blk then return nil end
            indata = setU32(indata, iOff, blk); writeBlockStr(fs, ind, indata); addUsed(fs, inode)
        end
        return blk
    end
    return nil
end

--- inode 实际占用的数据块数。
--- **不能用 size 直接推**: ext2 的"快速符号链接"把目标(<=60 字节)内联在 inode 的 i_block 区里,
--- 此时 size = 目标长度, 但 i_blocks = 0、一个数据块都没占 —— 而那 15 个"指针"位置上放的是
--- 目标字符串的原始字节。若按 size 遍历指针去释放, 就会把 "targ" 这种字节当块号释放,
--- 直接读坏块组描述符崩掉(创建符号链接后 rm 一下就复现)。
---@param fs Ext2Fs
---@param inode table
---@return integer
local function dataBlockCount(fs, inode)
    if (inode.blocks or 0) == 0 then return 0 end
    return math.ceil((inode.size or 0) / fs.blockSize)
end

--- 释放 inode 引用的所有数据块 + 间接指针块。
function ext2.freeBlocksOfInode(fs, inode)
    local nBlocks = dataBlockCount(fs, inode)
    for idx = 0, nBlocks - 1 do
        local blk = ext2.getBlock(fs, inode, idx)
        if blk and blk ~= 0 then ext2.freeBlock(fs, blk) end
    end
    -- 释放间接指针块(快速符号链接的 ptrs[13]/[14] 也是目标字节, 所以同样要先判 i_blocks)
    if (inode.blocks or 0) == 0 then return end
    local per = perIndirect(fs)
    if inode.ptrs[13] ~= 0 then ext2.freeBlock(fs, inode.ptrs[13]) end
    if inode.ptrs[14] ~= 0 then
        local ddata = readBlockStr(fs, inode.ptrs[14])
        for i = 0, per - 1 do local ind = u32(ddata, i * 4); if ind ~= 0 then ext2.freeBlock(fs, ind) end end
        ext2.freeBlock(fs, inode.ptrs[14])
    end
end

-- ---------------------------------------------------------------
-- 目录
-- ---------------------------------------------------------------
function ext2.readDir(fs, dirIno)
    local entries = {}
    if dirIno.type ~= T_DIR then return nil end
    local nBlocks = math.ceil((dirIno.size or 0) / fs.blockSize)
    for idx = 0, nBlocks - 1 do
        local blockNum = ext2.getBlock(fs, dirIno, idx)
        if not blockNum or blockNum == 0 then break end
        local data = readBlockStr(fs, blockNum)
        local off = 0
        while off < #data do
            local entIno = u32(data, off)
            local recLen = u16(data, off + 4)
            if recLen == 0 then break end
            local nameLen = data:byte(off + 7)
            local fileType = data:byte(off + 8)
            if entIno ~= 0 and nameLen > 0 then
                entries[#entries + 1] = { ino = entIno, name = data:sub(off + 9, off + 8 + nameLen), fileType = fileType }
            end
            off = off + recLen
        end
    end
    return entries
end

local function alignedSize(n) return n + ((4 - (n % 4)) % 4) end

local function findDirEntry(fs, dirIno, name)
    local entries = ext2.readDir(fs, dirIno)
    if not entries then return nil end
    for _, e in ipairs(entries) do if e.name == name then return e end end
    return nil
end

function ext2.lookup(fs, path)
    path = path:gsub("^/+", ""):gsub("/+$", "")
    local cur = ext2.readInode(fs, 2)
    if path == "" then return cur end
    for part in path:gmatch("[^/]+") do
        if part == "." then
            -- self
        elseif part == ".." then
            if cur.type == T_DIR then
                local pe = findDirEntry(fs, cur, "..")
                if pe then cur = ext2.readInode(fs, pe.ino) end
            end
        else
            if cur.type ~= T_DIR then return nil end
            local e = findDirEntry(fs, cur, part)
            if not e then return nil end
            cur = ext2.readInode(fs, e.ino)
        end
    end
    return cur
end

-- ---------------------------------------------------------------
-- 读文件/符号链接
-- ---------------------------------------------------------------
local function readSymlink(fs, inode)
    local len = inode.size
    if len <= 60 then
        local raw = readRawInode(fs, inode.ino)
        return raw:sub(41, 40 + len) -- i_block 内联目标
    end
    local blk = ext2.getBlock(fs, inode, 0)
    if not blk or blk == 0 then return nil end
    return readBlockStr(fs, blk):sub(1, len)
end

function ext2.readFile(fs, inode)
    if inode.type == T_SYM then return readSymlink(fs, inode) end
    if inode.type ~= T_REG then return nil end
    local out = {}
    local remaining = inode.size
    local idx = 0
    while remaining > 0 do
        local blockNum = ext2.getBlock(fs, inode, idx)
        if not blockNum or blockNum == 0 then break end
        local data = readBlockStr(fs, blockNum)
        if not data then break end
        out[#out + 1] = data:sub(1, math.min(#data, remaining))
        remaining = remaining - #data
        idx = idx + 1
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------
-- 写: 目录项增删, 创建, 文件写, 删除
-- ---------------------------------------------------------------
function ext2.addDirEntry(fs, dirIno, name, childIno, fileType)
    local nameLen = #name
    local rec = alignedSize(8 + nameLen)
    local nBlocks = math.ceil((dirIno.size or 0) / fs.blockSize)
    for idx = 0, nBlocks - 1 do
        local blockNum = ext2.getBlock(fs, dirIno, idx)
        if blockNum then
            local data = readBlockStr(fs, blockNum)
            local off = 0
            while off < #data do
                local entRecLen = u16(data, off + 4)
                if entRecLen == 0 then break end
                if u32(data, off) == 0 then
                    -- 已删除条目(ino=0): 整条 rec_len 都是空闲空间, 直接复用它。
                    -- 若按 name_len=0 算出 actual=8、把 rec_len 缩到 8 再往后塞新条目,
                    -- 块中间就会留下 inode=0 的 8 字节空洞, e2fsck 判 "directory corrupted"。
                    if entRecLen >= rec then
                        local entry = w32(childIno) .. w16(entRecLen) .. string.char(nameLen, fileType) .. name .. string.rep("\0", entRecLen - (8 + nameLen))
                        data = data:sub(1, off) .. entry .. data:sub(off + entRecLen + 1)
                        writeBlockStr(fs, blockNum, data)
                        return true
                    end
                else
                    local entNameLen = data:byte(off + 7) -- name_len 在 6(file_type 在 7), Lua 索引从 1 起
                    local actual = alignedSize(8 + entNameLen)
                    local slack = entRecLen - actual
                    if slack >= rec then
                        data = setU16(data, off + 4, actual)
                        local newOff = off + actual
                        -- 新条目必须占满被拆出来的整个 slack 区域(rec_len = slack),
                        -- 否则会在块内留下无 rec_len 的间隙, readDir 视其为坏目录项。
                        local entry = w32(childIno) .. w16(slack) .. string.char(nameLen, fileType) .. name .. string.rep("\0", slack - (8 + nameLen))
                        -- 拆分: 新条目占满整个 slack 区(长度为 slack), 其后才是块内本该跟上的内容。
                        -- 若用 data:sub(newOff+1) 会把旧项的 slack 区再叠加一次, 使 data 长度膨胀
                        -- (1024 -> 2000), 一次写入越界到相邻数据块(如 /lib), 把它清零。
                        data = data:sub(1, newOff) .. entry .. data:sub(newOff + slack + 1)
                        writeBlockStr(fs, blockNum, data)
                        return true
                    end
                end
                off = off + entRecLen
            end
        end
    end
    -- 新块
    local newIdx = nBlocks
    if not ext2.ensureBlock(fs, dirIno, newIdx) then return nil, "no block" end
    local newBlock = ext2.getBlock(fs, dirIno, newIdx)
    if dirIno.size == 0 then dirIno.size = fs.blockSize end
    local oldSize = dirIno.size
    if oldSize <= newIdx * fs.blockSize then dirIno.size = (newIdx + 1) * fs.blockSize end
    ext2.writeInode(fs, dirIno)
    local entry = w32(childIno) .. w16(fs.blockSize) .. string.char(nameLen, fileType) .. name .. string.rep("\0", fs.blockSize - (8 + nameLen))
    writeBlockStr(fs, newBlock, entry)
    return true
end

function ext2.create(fs, dirPath, name, mode, uid, gid)
    local parent = ext2.lookup(fs, dirPath)
    if not parent or parent.type ~= T_DIR then return nil, "parent not a dir" end
    if findDirEntry(fs, parent, name) then return nil, "exists" end
    local c = cred()
    uid = uid or c.uid
    gid = gid or c.gid
    -- umask 在**唯一的创建点**应用(见 applyUmask 的说明)。
    mode = applyUmask(mode)
    local ino = ext2.allocInode(fs, mode, uid, gid)
    if not ino then return nil, "alloc inode failed" end
    local inode = ext2.readInode(fs, ino)
    local now = math.floor(os.epoch("utc") / 1000)
    inode.mtime = now; inode.ctime = now; inode.atime = now
    if itype(mode) == T_DIR then
        local blk = ext2.allocBlock(fs)
        if not blk then return nil, "no block for dir" end
        inode.ptrs[1] = blk
        inode.size = fs.blockSize
        inode.blocks = inode.blocks + math.floor(fs.blockSize / 512)
        inode.links = 2
        local e1 = w32(ino) .. w16(12) .. string.char(1, FT_DIR) .. "." .. string.rep("\0", 3)
        local e2 = w32(parent.ino) .. w16(fs.blockSize - 12) .. string.char(2, FT_DIR) .. ".." .. string.rep("\0", 2)
        writeBlockStr(fs, blk, e1 .. e2)
    end
    ext2.writeInode(fs, inode)
    ext2.addDirEntry(fs, parent, name, ino, typeToFileType(itype(mode)))
    if itype(mode) == T_DIR then
        -- 只有新建子目录才增加父目录的 links(它多了一个 ".." 指向)。
        -- 给普通文件也加会把这个计数越加越大(真机跑一轮 fsck: "ref count is 55, should be 3")。
        local pp = ext2.readInode(fs, parent.ino)
        pp.links = pp.links + 1
        ext2.writeInode(fs, pp)
    end
    return ino
end

function ext2.writeFile(fs, ino, content)
    local inode = ext2.readInode(fs, ino)
    if not inode or (inode.type ~= T_REG and inode.type ~= T_SYM) then return nil, "not a regular file" end
    local blockSize = fs.blockSize
    local oldBlocks = dataBlockCount(fs, inode)
    local nBlocks = math.ceil(#content / blockSize)
    for b = 0, nBlocks - 1 do
        local blk = ext2.ensureBlock(fs, inode, b)
        if not blk then return nil, "no block" end
        local cs = b * blockSize + 1
        local chunk = content:sub(cs, cs + blockSize - 1)
        writeBlockStr(fs, blk, chunk)
    end
    -- 截断: 释放多余块 + 不再需要的间接指针块
    local per = perIndirect(fs)
    for b = nBlocks, oldBlocks - 1 do
        local blk = ext2.getBlock(fs, inode, b)
        if blk and blk ~= 0 then
            ext2.freeBlock(fs, blk)
            if b < 12 then inode.ptrs[b + 1] = 0 end
            inode.blocks = math.max(0, inode.blocks - math.floor(blockSize / 512))
        end
    end
    if nBlocks <= 12 and inode.ptrs[13] ~= 0 then
        ext2.freeBlock(fs, inode.ptrs[13]); inode.ptrs[13] = 0
        inode.blocks = math.max(0, inode.blocks - math.floor(blockSize / 512))
    end
    if nBlocks <= 12 + per and inode.ptrs[14] ~= 0 then
        ext2.freeBlock(fs, inode.ptrs[14]); inode.ptrs[14] = 0
        inode.blocks = math.max(0, inode.blocks - math.floor(blockSize / 512))
    end
    inode.size = #content
    inode.mtime = math.floor(os.epoch("utc") / 1000)
    ext2.writeInode(fs, inode)
    return true
end

--- 在文件末尾追加数据(增量落盘, 不重写已有内容)。
--- 供日志类长驻进程用: 追加句柄 flush 时只写新增部分, 不必重写整个文件。
---@param fs Ext2Fs
---@param ino integer
---@param content string
---@return boolean|nil ok, string|nil err
--- 写符号链接目标。ext2 的"快速符号链接"把 <=60 字节的目标直接内联在 inode 的 i_block
--- 区(15 个 u32), 更长的才分配数据块 —— `readSymlink` 正是按 60 字节这个分界读的, 两边必须一致,
--- 否则短目标会被当成块号读出一堆垃圾(或真正的块内容)。
---@param fs Ext2Fs
---@param ino integer
---@param target string
---@return boolean|nil ok, string|nil err
function ext2.setSymlink(fs, ino, target)
    local inode = ext2.readInode(fs, ino)
    if not inode or inode.type ~= T_SYM then return nil, "not a symlink" end
    if #target > 60 then return ext2.writeFile(fs, ino, target) end
    local s = target .. string.rep("\0", 60 - #target)
    inode.ptrs = {}
    for n = 0, 14 do
        local b1, b2, b3, b4 = s:byte(n * 4 + 1, n * 4 + 4)
        inode.ptrs[n + 1] = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end
    inode.size = #target
    inode.blocks = 0
    inode.mtime = math.floor(os.epoch("utc") / 1000)
    inode.ctime = inode.mtime
    return ext2.writeInode(fs, inode)
end

--- 读符号链接目标(不跟随)。非符号链接返回 nil, err。
---@param fs Ext2Fs
---@param ino integer
---@return string|nil target, string|nil err
function ext2.getSymlink(fs, ino)
    local inode = ext2.readInode(fs, ino)
    if not inode then return nil, "no such file" end
    if inode.type ~= T_SYM then return nil, "not a symlink" end
    local t = readSymlink(fs, inode)
    if not t then return nil, "cannot read symlink" end
    return t
end

--- 硬链接: 给已存在的 inode 再挂一个目录项并递增 links。
--- POSIX/Linux 都不允许给目录做硬链接(会成环), 这里明确拒绝。
---@param fs Ext2Fs
---@param oldPath string 已存在路径
---@param newPath string 新链接路径(必须不存在)
---@return boolean|nil ok, string|nil err
function ext2.link(fs, oldPath, newPath)
    local src = ext2.lookup(fs, oldPath)
    if not src then return nil, "no such file" end
    if src.type == T_DIR then return nil, "hard link to a directory is not allowed" end
    local pdir = newPath:match("^(.*)/[^/]*$") or "/"
    local pname = newPath:match("([^/]*)$") or newPath
    if pname == "" then return nil, "invalid path" end
    local parent = ext2.lookup(fs, pdir)
    if not parent or parent.type ~= T_DIR then return nil, "parent not a dir" end
    if findDirEntry(fs, parent, pname) then return nil, "file exists" end
    local c = cred()
    if not (hasPerm(parent, c.uid, c.gid, 2) and hasPerm(parent, c.uid, c.gid, 1)) then
        return nil, "permission denied (dir)"
    end
    local ok, err = ext2.addDirEntry(fs, parent, pname, src.ino, typeToFileType(src.type))
    if not ok then return nil, err end
    local inode = ext2.readInode(fs, src.ino)
    inode.links = (inode.links or 1) + 1
    inode.ctime = math.floor(os.epoch("utc") / 1000)
    return ext2.writeInode(fs, inode)
end

function ext2.appendFile(fs, ino, content)
    if content == "" then return true end
    local inode = ext2.readInode(fs, ino)
    if not inode or (inode.type ~= T_REG and inode.type ~= T_SYM) then return nil, "not a regular file" end
    local blockSize = fs.blockSize
    local offset = inode.size or 0
    local i = 1
    while i <= #content do
        local idx = math.floor(offset / blockSize)
        local blk = ext2.ensureBlock(fs, inode, idx)
        if not blk then return nil, "no block" end
        local off = offset % blockSize
        local chunk = content:sub(i, i + (blockSize - off) - 1)
        if off == 0 and #chunk == blockSize then
            writeBlockStr(fs, blk, chunk)
        else
            local old = readBlockStr(fs, blk) or ""
            writeBlockStr(fs, blk, old:sub(1, off) .. chunk .. old:sub(off + #chunk + 1))
        end
        offset = offset + #chunk
        i = i + #chunk
    end
    inode.size = offset
    inode.mtime = math.floor(os.epoch("utc") / 1000)
    ext2.writeInode(fs, inode)
    return true
end

function ext2.removeDirEntry(fs, dirIno, name)
    local nBlocks = math.ceil((dirIno.size or 0) / fs.blockSize)
    for idx = 0, nBlocks - 1 do
        local blockNum = ext2.getBlock(fs, dirIno, idx)
        if blockNum then
            local data = readBlockStr(fs, blockNum)
            local off, prevOff, prevRec = 0, nil, 0
            while off < #data do
                local entRecLen = u16(data, off + 4)
                if entRecLen == 0 then break end
                local entNameLen = data:byte(off + 7)
                if entNameLen == #name and data:sub(off + 9, off + 8 + entNameLen) == name then
                    -- ext2 的标准删除: 把被删条目的 rec_len 并入前一条(条目直接从块里消失)。
                    -- 合并更简单, 目录块也不会越用越碎。
                    if not prevOff then
                        -- 条目是本块的**第一条**(目录跨块后, 每个非首块的第一条都会走到这里):
                        -- 没有前一条可以并进去, 于是把它标成**空闲条目**(inode 号置 0), rec_len 与
                        -- name_len 原样保留 —— addDirEntry 扫到 ino==0 的条目会整条复用(条件
                        -- `entRecLen >= rec`), 所以不能缩 rec_len, 更不能清 name_len: 那样会在
                        -- 块里留下 e2fsck 判 "directory corrupted" 的空洞。
                        -- 曾经的 bug: 这里直接 `return nil, "cannot remove first dir entry"`,
                        -- 于是 >1 个块的目录永远删不掉每个块的第一条 —— 真机上 `rm -rf` 一个大目录
                        -- 会报这个错、目录删不干净(regex_test.sh 的自检把它试出来了)。
                        data = setU32(data, off, 0)
                        writeBlockStr(fs, blockNum, data)
                        return true
                    end
                    data = setU16(data, prevOff + 4, prevRec + entRecLen)
                    writeBlockStr(fs, blockNum, data)
                    return true
                end
                prevOff, prevRec = off, entRecLen
                off = off + entRecLen
            end
        end
    end
    return false
end

function ext2.delete(fs, dirPath, name)
    local parent = ext2.lookup(fs, dirPath)
    if not parent or parent.type ~= T_DIR then return nil, "parent not a dir" end
    local entry = findDirEntry(fs, parent, name)
    if not entry then return nil, "no such entry" end
    local child = ext2.readInode(fs, entry.ino)
    -- POSIX rmdir 语义: **非空目录必须拒绝**(ENOTEMPTY), 而不是把目录条目摘掉就算了。
    -- 曾经的 bug: 不检查就直接合并掉条目, 于是子 inode 仍被占用、却没有任何目录项指向它们 ——
    -- 真机跑完 e2fsck 报 "Unconnected directory inode" + "Unattached inode", 数据静默丢失。
    -- 工具侧不能靠"自己先判空"来兜: 直接调 fs.delete 的地方(真机自检脚本就是)一样会弄坏盘。
    if child and child.type == T_DIR then
        for _, e in ipairs(ext2.readDir(fs, child) or {}) do
            if e.name ~= "." and e.name ~= ".." then return nil, "directory not empty" end
        end
    end
    local ok, err = ext2.removeDirEntry(fs, parent, name)
    if not ok then return nil, err end
    if child then
        child.links = math.max(0, child.links - 1)
        -- 目录的 links 含 "." 与 "..": 删空目录后剩 1 即应回收, 否则会漏一个未连接 inode。
        local free = (child.type == T_DIR) and (child.links <= 1) or (child.links <= 0)
        if free then
            -- FIFO 的缓冲区挂在 inode 上: inode 回收时必须一起放掉, 否则缓冲区会一直留着,
            -- 之后在同一位置新建的 FIFO 会"继承"上一个的残留数据与读写端计数。
            if child.type == T_FIFO then fifo.forget(fs, child.ino) end
            ext2.freeBlocksOfInode(fs, child)
            ext2.freeInode(fs, child.ino)
        else
            ext2.writeInode(fs, child)
        end
        if child.type == T_DIR then
            -- 只有子目录才占父目录的 links(与 create 对称)。
            parent.links = math.max(2, parent.links - 1)
            ext2.writeInode(fs, parent)
        end
    end
    return true
end

--- 改权限(保留类型位)。
function ext2.chmod(fs, path, mode)
    local inode = ext2.lookup(fs, path)
    if not inode then return nil, "no such file: " .. tostring(path) end
    inode.mode = inode.type + (mode % 0x1000)
    ext2.writeInode(fs, inode)
    return true
end

--- 改属主(uid/gid)。
function ext2.chown(fs, path, uid, gid)
    local inode = ext2.lookup(fs, path)
    if not inode then return nil, "no such file" end
    if uid then inode.uid = uid end
    if gid then inode.gid = gid end
    ext2.writeInode(fs, inode)
    return true
end

-- ---------------------------------------------------------------
-- VFS 后端(读写)
-- ---------------------------------------------------------------
function ext2.backend(fs)
    local function attr(inode)
        return {
            size = inode.size,
            isDir = inode.type == T_DIR,
            isReadOnly = false,
            mode = inode.mode,
            uid = inode.uid,
            gid = inode.gid,
            ino = inode.ino,
            links = inode.links,
            mtime = inode.mtime,
            kind = inode.type == T_DIR and "dir"
                or (inode.type == T_REG and "file"
                or (inode.type == T_SYM and "symlink"
                or (inode.type == T_FIFO and "fifo" or "device"))),
        }
    end
    return {
        kind = "virtual",
        isReadOnly = function() return false end,
        list = function(rel)
            local inode = ext2.lookup(fs, rel or "/")
            if not inode or inode.type ~= T_DIR then return nil end
            local c = cred()
            if not hasPerm(inode, c.uid, c.gid, 4) then return nil, "permission denied" end
            local out = {}
            for _, e in ipairs(ext2.readDir(fs, inode)) do
                if e.name ~= "." and e.name ~= ".." then out[#out + 1] = e.name end
            end
            return out
        end,
        exists = function(rel) return ext2.lookup(fs, rel) ~= nil end,
        isDir = function(rel) local i = ext2.lookup(fs, rel); return i and i.type == T_DIR or false end,
        isFile = function(rel) local i = ext2.lookup(fs, rel); return i and i.type == T_REG or false end,
        attributes = function(rel) local i = ext2.lookup(fs, rel); return i and attr(i) or nil end,
        -- 符号链接/硬链接。注意 `rel` 已经是**最后一段未被展开**的路径(由 VFS 的
        -- 不跟随解析给出), 后端只负责这一层的创建/读取。
        symlink = function(target, rel)
            local pdir = rel:match("^(.*)/[^/]*$") or "/"
            local pname = rel:match("([^/]*)$") or rel
            if pname == "" then return nil, "invalid path" end
            local c = cred()
            local parent = ext2.lookup(fs, pdir)
            if not parent or parent.type ~= T_DIR then return nil, "parent not a dir" end
            if not (hasPerm(parent, c.uid, c.gid, 2) and hasPerm(parent, c.uid, c.gid, 1)) then
                return nil, "permission denied (dir)"
            end
            local ino, err = ext2.create(fs, pdir, pname, T_SYM + tonumber("777", 8))
            if not ino then return nil, err end
            local ok, werr = ext2.setSymlink(fs, ino, target)
            if not ok then return nil, werr end
            return true
        end,
        readlink = function(rel)
            local i = ext2.lookup(fs, rel)
            if not i then return nil, "no such file" end
            return ext2.getSymlink(fs, i.ino)
        end,
        link = function(oldrel, newrel) return ext2.link(fs, oldrel, newrel) end,
        -- 命名管道(FIFO): 只在 inode 类型上有区别 —— 数据不在文件里, 在 kernel/fifo 的缓冲区里。
        mkfifo = function(rel, mode)
            local pdir = rel:match("^(.*)/[^/]*$") or "/"
            local pname = rel:match("([^/]*)$") or rel
            if pname == "" then return nil, "invalid path" end
            local c = cred()
            local parent = ext2.lookup(fs, pdir)
            if not parent or parent.type ~= T_DIR then return nil, "parent not a dir" end
            if not (hasPerm(parent, c.uid, c.gid, 2) and hasPerm(parent, c.uid, c.gid, 1)) then
                return nil, "permission denied (dir)"
            end
            -- mkfifo(1) 的缺省权限是 0666(再由 umask 收窄)。umask 由 shell 侧算好后传进来,
            -- 这里不做二次收窄, 否则 umask 会被应用两遍。
            local perm = iperms(mode or tonumber("666", 8))
            local ino, err = ext2.create(fs, pdir, pname, T_FIFO + perm)
            if not ino then return nil, err end
            return true
        end,
        getSize = function(rel) local i = ext2.lookup(fs, rel); return i and i.size or 0 end,
        getDrive = function() return "ext2" end,
        getFreeSpace = function() return math.max(0, sbFreeBlocks(fs) - fs.rBlocks) * fs.blockSize end,
        getCapacity = function() return fs.blocks * fs.blockSize end,
        open = function(rel, mode)
            local i = ext2.lookup(fs, rel)
            local c = cred()
            -- 命名管道: 读写都走 kernel/fifo 的缓冲区, **不能**走到下面的文件路径去
            -- (那会把 FIFO 当空文件截断/当空内容读)。权限按 open 的方向查(读要 r, 写要 w);
            -- 打开会阻塞到对端出现, 这是 POSIX 语义(见 kernel/fifo.lua)。
            if i and i.type == T_FIFO then
                local wantW = mode and (mode:find("w") or mode:find("a"))
                local need = wantW and 2 or 4
                if not hasPerm(i, c.uid, c.gid, need) then return nil, "permission denied (fifo)" end
                return fifo.open(fs, i.ino, mode or "r")
            end
            local function checkDirWrite(pdir)
                local parent = ext2.lookup(fs, pdir)
                if parent and not (hasPerm(parent, c.uid, c.gid, 2) and hasPerm(parent, c.uid, c.gid, 1)) then
                    return false
                end
                return true
            end
            if mode and mode:find("w") then
                if not i then
                    local pdir = rel:match("^(.*)/[^/]*$") or "/"
                    local pname = rel:match("([^/]*)$") or rel
                    if not checkDirWrite(pdir) then return nil, "permission denied (dir)" end
                    local ino, err = ext2.create(fs, pdir, pname, 0x81A4)
                    if not ino then return nil, err end
                    i = ext2.readInode(fs, ino)
                end
                if i.type == T_DIR then return nil, "is a directory" end
                if not hasPerm(i, c.uid, c.gid, 2) then return nil, "permission denied (file)" end
                ext2.writeFile(fs, i.ino, "")
                local parts = {}
                -- 句柄方法同时支持 `.method(s)` 与 `:method(s)`(CC 原生句柄两者皆可)。
                -- flush/close 把累积内容整体写回(w 模式语义: 全量重写)。
                local function commit() return ext2.writeFile(fs, i.ino, table.concat(parts)) end
                -- 句柄是"整表缓冲、close 时全量重写"模型, 所以向后 seek 只能用 0 填充缓冲区
                -- (逻辑内容与稀疏文件一致, 只是不省块); 向前 seek 做不到, 明确报错而不是假装成功
                -- —— dd seek= 依赖它, 静默返回 0 会让 dd 悄悄写错位置。
                local function buflen() local n = 0; for k = 1, #parts do n = n + #parts[k] end; return n end
                local function seekTo(whence, off)
                    off = off or 0
                    local cur = buflen()
                    local target
                    if whence == nil or whence == "cur" then target = cur + off
                    elseif whence == "set" then target = off
                    elseif whence == "end" then target = cur + off
                    else return nil, "bad whence" end
                    if target < 0 then return nil, "negative seek" end
                    if target < cur then return nil, "cannot seek backwards on a buffered write handle" end
                    if target > cur then parts[#parts + 1] = string.rep("\0", target - cur) end
                    return target
                end
                return {
                    write = function(self, s) if s == nil then s = self end; parts[#parts + 1] = s; return #s end,
                    writeLine = function(self, s) if s == nil then s = self end; parts[#parts + 1] = s .. "\n"; return #s + 1 end,
                    flush = commit,
                    close = commit,
                    seek = function(p1, p2, p3)
                        if type(p1) == "table" then return seekTo(p2, p3) end
                        return seekTo(p1, p2)
                    end,
                }
            end
            if mode and mode:find("a") then
                -- 追加: 若不存在则创建; 写入只在文件末尾增量落盘(flush/close 提交新增部分)。
                if not i then
                    local pdir = rel:match("^(.*)/[^/]*$") or "/"
                    local pname = rel:match("([^/]*)$") or rel
                    if not checkDirWrite(pdir) then return nil, "permission denied (dir)" end
                    local ino, err = ext2.create(fs, pdir, pname, 0x81A4)
                    if not ino then return nil, err end
                    i = ext2.readInode(fs, ino)
                end
                if i.type == T_DIR then return nil, "is a directory" end
                if not hasPerm(i, c.uid, c.gid, 2) then return nil, "permission denied (file)" end
                local parts = {}
                local function commit()
                    if #parts == 0 then return true end
                    local data = table.concat(parts)
                    parts = {}
                    return ext2.appendFile(fs, i.ino, data)
                end
                -- 追加模式每次 close 都把新内容接到文件末尾, 无法回头改写, 因此只支持
                -- "当前位置" 查询: 其它 whence 一律明确报错(fail-fast, 见 w 模式处的说明)。
                return {
                    write = function(self, s) if s == nil then s = self end; parts[#parts + 1] = s; return #s end,
                    writeLine = function(self, s) if s == nil then s = self end; parts[#parts + 1] = s .. "\n"; return #s + 1 end,
                    flush = commit,
                    close = commit,
                    seek = function(p1, p2, p3)
                        local whence = (type(p1) == "table") and p2 or p1
                        local off = (type(p1) == "table") and p3 or p2
                        if (whence == nil or whence == "cur") and (off == nil or off == 0) then
                            local n = 0; for k = 1, #parts do n = n + #parts[k] end
                            return (i.size or 0) + n
                        end
                        return nil, "append handle only supports seek(0) to query the position"
                    end,
                }
            end
            if not i then return nil, "no such file" end
            if i.type == T_DIR then return nil, "is a directory" end
            if not hasPerm(i, c.uid, c.gid, 4) then return nil, "permission denied (read)" end
            local content = ext2.readFile(fs, i)
            local pos = 0 -- 字节读偏移
            return {
                readAll = function() pos = #content; return content end,
                read = function(a, b)
                    local n
                    if type(a) == "number" then n = a
                    elseif type(a) == "table" and type(b) == "number" then n = b end
                    -- **EOF 必须返回 nil, 不能返回空串**: 与 CC 原生句柄和 Lua 文件语义一致。
                    -- 返回空串会让所有"读到 nil 为止"的循环(tee/dd/cp/od ...)在 EOF 上无限打转 ——
                    -- 症状是命令在真机上挂死(服务被 60s 超时杀掉), 而宿主测试台的句柄是标准的,
                    -- 所以这个 bug 一直只在真机上露头。真机定位: posix-verify.service 卡在 tee。
                    if pos >= #content then return nil end
                    if n == nil then
                        local r = content:sub(pos + 1); pos = #content; return r
                    end
                    local r = content:sub(pos + 1, pos + n)
                    pos = pos + #r
                    return r
                end,
                readLine = function()
                    if pos >= #content then return nil end
                    local nl = content:find("\n", pos + 1, true)
                    if nl then
                        local r = content:sub(pos + 1, nl - 1)
                        pos = nl -- 越过换行
                        return r
                    end
                    local r = content:sub(pos + 1)
                    pos = #content
                    return r
                end,
                write = function() end, writeLine = function() end,
                close = function() end, flush = function() return true end,
                -- 读句柄是"整文件读进内存 + pos"模型, 所以 set/cur/end 三种 whence 都是精确的。
                -- 与 CC 原生句柄一致: 越界 seek 不报错, 之后的 read 返回空串。
                seek = function(p1, p2, p3)
                    local whence, off
                    if type(p1) == "table" then whence, off = p2, p3 else whence, off = p1, p2 end
                    off = off or 0
                    local target
                    if whence == nil or whence == "cur" then target = pos + off
                    elseif whence == "set" then target = off
                    elseif whence == "end" then target = #content + off
                    else return nil, "bad whence" end
                    if target < 0 then return nil, "negative seek" end
                    pos = target
                    return target
                end,
            }
        end,
        makeDir = function(rel)
            local pdir = rel:match("^(.*)/[^/]*$") or "/"
            local pname = rel:match("([^/]*)$") or rel
            local parent = ext2.lookup(fs, pdir)
            local c = cred()
            if parent and not (hasPerm(parent, c.uid, c.gid, 2) and hasPerm(parent, c.uid, c.gid, 1)) then
                error("permission denied", 2)
            end
            local ino, err = ext2.create(fs, pdir, pname, 0x41ED)
            if not ino then error(tostring(err), 2) end
            return true
        end,
        delete = function(rel)
            local pdir = rel:match("^(.*)/[^/]*$") or "/"
            local pname = rel:match("([^/]*)$") or rel
            local parent = ext2.lookup(fs, pdir)
            local c = cred()
            if parent and not (hasPerm(parent, c.uid, c.gid, 2) and hasPerm(parent, c.uid, c.gid, 1)) then
                error("permission denied", 2)
            end
            local ok, err = ext2.delete(fs, pdir, pname)
            if not ok then error(tostring(err), 2) end
            return true
        end,
        chmod = function(rel, mode) return ext2.chmod(fs, rel, mode) end,
        chown = function(rel, uid, gid) return ext2.chown(fs, rel, uid, gid) end,
        -- 执行权限检查: 启动一个程序(普通文件/符号链接)必须对当前进程有 x 位。
        -- 目录/设备等不可执行。符号链接按其 i_block 内联目标判定(本 FS 不用它执行)。
        -- root 也不能一路放行: POSIX 只要求文件至少有一个 x 位(root 绕过的是 r/w, 不绕过 x),
        -- 否则 644 的脚本 `./script` 也能跑起来(历史 bug)。
        canExecute = function(rel)
            local inode = ext2.lookup(fs, rel)
            if not inode then return false end
            if inode.type ~= T_REG and inode.type ~= T_SYM then return false end
            local c = cred()
            if c.uid == 0 then return anyExecBit(inode.perms) end
            return hasPerm(inode, c.uid, c.gid, 1)
        end,
    }
end

-- ---------------------------------------------------------------
-- mkfs: 建一个空白 ext2(mkfs.ext2 命令与安装器现场格式化共用)
-- ---------------------------------------------------------------

--- 在块设备上建一个空白 ext2 文件系统(mkfs.ext2 子集)。
--- 布局(**单块组**, 与宿主 mkfs.ext2 的单块组产物同构):
---   块大小 1024:  block0 引导扇区 | block1 超级块(偏移 1024) | block2 块组描述符
---                  | block3 块位图 | block4 inode 位图 | block5.. inode 表 | 数据块
---   块大小 >1024: block0 超级块(块内偏移 1024) | block1 块组描述符 | block2 块位图
---                  | block3 inode 位图 | block4.. inode 表 | 数据块
--- 只做**单块组**(块数上限 8*块大小: 1024 时 8192 块 = 8MB, 4096 时 32768 块 = 128MB):
--- 少一块组就少一处出错的地方; 超了直接报错, 不静默截断。
--- 根目录与 lost+found 用驱动自己的 create/allocBlock 建(而不是另写一份编码),
--- 这样"mkfs 写出来的东西"与"驱动读得懂的东西"天生一致; 建完再 mount 回来自检。
---@param bd table 块设备
---@param opts table|nil { blocks 必需, blockSize = 1024|2048|4096, inodes, label,
---                         reservedPercent, time(秒), dryRun }
---@return table|nil fs, string|nil err dryRun 时返回描述表(不写盘), 否则返回挂载好的 fs
function ext2.mkfs(bd, opts)
    opts = opts or {}

    -- 块大小: 只收 1024/2048/4096 —— ext2 理论上允许到 64KB, 但 CC 上没有任何意义,
    -- 而且宿主 e2fsck 对非标准组合会直接报错(自检就失去裁判)。
    local blockSize = tonumber(opts.blockSize) or 1024
    if blockSize ~= 1024 and blockSize ~= 2048 and blockSize ~= 4096 then
        return nil, string.format("mkfs: block size must be 1024, 2048 or 4096 (got %s)", tostring(opts.blockSize))
    end
    local logBlockSize = (blockSize == 1024) and 0 or ((blockSize == 2048) and 1 or 2)

    local inodeSize = 128
    local perBlock = math.floor(blockSize / inodeSize) -- 每块 inode 数(8/16/32)
    local blocksPerGroup = 8 * blockSize               -- ext2 标准: 一位图块管 8*blockSize 块
    local firstDataBlock = (blockSize == 1024) and 1 or 0
    local firstIno = 11                                -- 1..10 保留, 11 起给普通文件(与 mkfs.ext2 一致)

    local blocks = tonumber(opts.blocks)
    if not blocks then return nil, "mkfs: blocks is required" end
    blocks = math.floor(blocks)
    if blocks < 64 then return nil, "mkfs: at least 64 blocks (64KB at block size 1024)" end
    if blocks > blocksPerGroup then
        return nil, string.format("mkfs: single block group only (at block size %d at most %d blocks = %dKB)",
            blockSize, blocksPerGroup, blocksPerGroup * blockSize / 1024)
    end

    -- inode 总数: 缺省 256(正好铺满一个 1024/2048/4096 字节的 inode 表块数), -N 给的值
    -- 向上取整到"每块 inode 数"的整数倍, 使 inode 表恰好占整数个块(不留半块, e2fsck 会报)。
    local inodesPerGroup = tonumber(opts.inodes) or 256
    inodesPerGroup = math.floor(inodesPerGroup)
    if inodesPerGroup < 2 * firstIno then
        return nil, string.format("mkfs: at least %d inodes", 2 * firstIno)
    end
    inodesPerGroup = math.ceil(inodesPerGroup / perBlock) * perBlock
    if inodesPerGroup > blockSize * 8 then
        return nil, string.format("mkfs: at most %d inodes (the inode bitmap of a single block group has only %d bits)",
            blockSize * 8, blockSize * 8)
    end

    -- 元数据块布局(见函数头注释)。块组描述符表只有一块(单块组)。
    local gdtBlock = firstDataBlock + 1
    local blockBitmap, inodeBitmap, inodeTable = gdtBlock + 1, gdtBlock + 2, gdtBlock + 3
    local inodeTableBlocks = math.floor(inodesPerGroup * inodeSize / blockSize)
    local dataStart = inodeTable + inodeTableBlocks
    if blocks < dataStart + 2 then
        return nil, string.format("mkfs: at least %d blocks (metadata %d blocks + root dir + lost+found)", dataStart + 2, dataStart)
    end

    local reservedPercent = tonumber(opts.reservedPercent) or 0
    if reservedPercent < 0 or reservedPercent > 99 then
        return nil, "mkfs: reserved block percentage must be within 0..99"
    end

    local size = bd.getSize and bd.getSize() or nil
    if size and size > 0 and size < blocks * blockSize then
        return nil, string.format("mkfs: device has only %d bytes, cannot hold %d blocks (%d bytes)", size, blocks, blocks * blockSize)
    end

    local now = math.floor(opts.time or (os.epoch and (os.epoch("utc") / 1000)) or os.time())
    local label = tostring(opts.label or "delin"):sub(1, 15)

    -- 计数(与下面写进超级块/块组描述符的值是同一份来源, 不各算一遍)
    local usedInodes = firstIno - 1                       -- inode 1..10 保留位
    local freeInodes = inodesPerGroup - usedInodes
    local usedBlocks = dataStart - firstDataBlock + 1     -- 元数据块 + 根目录块
    local freeBlocks = (blocks - firstDataBlock) - usedBlocks
    local rBlocks = math.floor(blocks * reservedPercent / 100)
    if rBlocks >= freeBlocks then
        return nil, string.format("mkfs: reserved blocks (%d) must not fill all free blocks (%d)", rBlocks, freeBlocks)
    end

    local info = {
        blocks = blocks, blockSize = blockSize, inodes = inodesPerGroup,
        freeBlocks = freeBlocks, freeInodes = freeInodes, rBlocks = rBlocks,
        dataStart = dataStart, inodeTable = inodeTable, inodeTableBlocks = inodeTableBlocks,
        blockBitmap = blockBitmap, inodeBitmap = inodeBitmap, label = label,
        reservedPercent = reservedPercent,
    }
    -- -n(dry run): 只做上面那套校验并把参数报给调用者, 一个字节都不写。
    if opts.dryRun then
        info.dryRun = true
        return info
    end

    -- 1) 整盘清零。CC 的 fs 不支持预分配, 写入即扩展文件, 这里顺带把镜像撑到目标大小。
    local CHUNK = 64 * 1024
    local zero = string.rep("\0", math.min(CHUNK, blocks * blockSize))
    local off = 0
    while off < blocks * blockSize do
        local n = math.min(#zero, blocks * blockSize - off)
        local ok, werr = bd.write(off, n == #zero and zero or zero:sub(1, n))
        if not ok then
            return nil, string.format("mkfs: zeroing failed at offset %d: %s", off, tostring(werr))
        end
        off = off + n
    end

    -- 2) 超级块(永远位于字节偏移 1024)
    local sb = string.rep("\0", 1024)
    sb = setU32(sb, 0, inodesPerGroup)          -- s_inodes_count
    sb = setU32(sb, 4, blocks)                  -- s_blocks_count
    sb = setU32(sb, 8, rBlocks)                 -- s_r_blocks_count
    sb = setU32(sb, 12, freeBlocks)             -- s_free_blocks_count
    sb = setU32(sb, 16, freeInodes)             -- s_free_inodes_count
    sb = setU32(sb, 20, firstDataBlock)         -- s_first_data_block
    sb = setU32(sb, 24, logBlockSize)           -- s_log_block_size
    sb = setU32(sb, 28, logBlockSize)           -- s_log_frag_size(碎片大小 = 块大小)
    sb = setU32(sb, 32, blocksPerGroup)         -- s_blocks_per_group
    sb = setU32(sb, 36, blocksPerGroup)         -- s_frags_per_group
    sb = setU32(sb, 40, inodesPerGroup)         -- s_inodes_per_group
    sb = setU32(sb, 44, now)                    -- s_mtime
    sb = setU32(sb, 48, now)                    -- s_wtime
    sb = setU16(sb, 52, 0)                      -- s_mnt_count
    sb = setU16(sb, 54, 0xFFFF)                 -- s_max_mnt_count
    sb = setU16(sb, 56, 0xEF53)                 -- s_magic
    sb = setU16(sb, 58, 1)                      -- s_state: clean
    sb = setU16(sb, 60, 1)                      -- s_errors: continue
    sb = setU16(sb, 62, 0)                      -- s_minor_rev_level
    sb = setU32(sb, 64, now)                    -- s_lastcheck
    sb = setU32(sb, 68, 0)                      -- s_checkinterval
    sb = setU32(sb, 72, 0)                      -- s_creator_os: Linux
    sb = setU32(sb, 76, 1)                      -- s_rev_level: dynamic
    sb = setU16(sb, 80, 0)                      -- s_def_resuid
    sb = setU16(sb, 82, 0)                      -- s_def_resgid
    sb = setU32(sb, 84, firstIno)               -- s_first_ino
    sb = setU16(sb, 88, inodeSize)              -- s_inode_size
    sb = setU16(sb, 90, 0)                      -- s_block_group_nr
    sb = setU32(sb, 92, 0)                      -- s_feature_compat
    -- 目录项的 file_type 字段要有 INCOMPAT_FILETYPE 才合法(驱动一直写它)。
    sb = setU32(sb, 96, 0x2)                    -- s_feature_incompat: FILETYPE
    sb = setU32(sb, 100, 0)                     -- s_feature_ro_compat
    -- s_uuid(104..119): 时间派生的 16 字节, 够区分不同镜像(Delin 不用 ext2 uuid 挂载)
    local seed = now % 2147483647
    local uuid = {}
    for i = 1, 16 do
        seed = (seed * 1103515245 + 12345) % 2147483648
        uuid[i] = string.char(math.floor(seed / 8388608) % 256)
    end
    sb = sb:sub(1, 104) .. table.concat(uuid) .. sb:sub(121)
    sb = sb:sub(1, 120) .. label .. string.rep("\0", 16 - #label) .. sb:sub(137)
    if not bd.write(1024, sb) then return nil, "mkfs: failed to write superblock" end

    -- 3) 块组描述符(单块组)
    --    位图映射(与宿主 mkfs.ext2 的产物逐字节核对过):
    --      块位图: bit k <-> block (k + first_data_block) —— 块大小 1024 时 block0 是引导块, **不进位图**
    --      inode 位图: bit k <-> inode (k+1)
    --    尾部填充位必须置 1, 否则 e2fsck 报 "Padding at end of ... bitmap is not set"。
    local gdt = w32(blockBitmap) .. w32(inodeBitmap) .. w32(inodeTable)
        .. w16(freeBlocks) .. w16(freeInodes) .. w16(1) .. w16(0) .. string.rep("\0", 12)
    if not bd.write(gdtBlock * blockSize, gdt) then return nil, "mkfs: failed to write group descriptor" end

    local function setBit(s, bit)
        local pos = math.floor(bit / 8) + 1
        local v = s:byte(pos) or 0
        return s:sub(1, pos - 1) .. string.char(v + 2 ^ (bit % 8)) .. s:sub(pos + 1)
    end
    local bitsPerBitmap = blockSize * 8
    -- 块位图: 元数据块(firstDataBlock..dataStart-1) + 根目录块(dataStart)都标占用,
    -- 位图容不下的尾部(bit >= blocks - firstDataBlock)必须置 1。
    local bmap = string.rep("\0", blockSize)
    for bit = 0, usedBlocks - 1 do bmap = setBit(bmap, bit) end
    for bit = blocks - firstDataBlock, bitsPerBitmap - 1 do bmap = setBit(bmap, bit) end
    if not bd.write(blockBitmap * blockSize, bmap) then return nil, "mkfs: failed to write block bitmap" end

    -- inode 位图: inode 1..10 保留段标占用(inode 2 是根目录), 其余尾部填充位置 1。
    local imap = string.rep("\0", blockSize)
    for bit = 0, usedInodes - 1 do imap = setBit(imap, bit) end
    for bit = inodesPerGroup, bitsPerBitmap - 1 do imap = setBit(imap, bit) end
    if not bd.write(inodeBitmap * blockSize, imap) then return nil, "mkfs: failed to write inode bitmap" end

    -- 5) 根目录(固定 inode 2)+ 它的目录块
    local fs = {
        bd = bd, blockSize = blockSize, inodes = inodesPerGroup, blocks = blocks,
        rBlocks = rBlocks, firstDataBlock = firstDataBlock, inodesPerGroup = inodesPerGroup,
        blocksPerGroup = blocksPerGroup, inodeSize = inodeSize, firstIno = firstIno,
        gdtOffset = gdtBlock * blockSize, numGroups = 1,
    }
    local rootBlock = dataStart
    local e1 = w32(2) .. w16(12) .. string.char(1, FT_DIR) .. "." .. string.rep("\0", 3)
    local e2 = w32(2) .. w16(blockSize - 12) .. string.char(2, FT_DIR) .. ".." .. string.rep("\0", 2)
    if not writeBlockStr(fs, rootBlock, e1 .. e2) then return nil, "mkfs: failed to write root directory" end
    local rootInode = {
        ino = 2, mode = T_DIR + 493, uid = 0, gid = 0, links = 2, size = blockSize, -- 0755
        blocks = math.floor(blockSize / 512), atime = now, ctime = now, mtime = now,
        ptrs = { rootBlock },
    }
    for n = 2, 15 do rootInode.ptrs[n] = 0 end
    if not ext2.writeInode(fs, rootInode) then return nil, "mkfs: failed to write root inode" end

    -- 6) lost+found: 用驱动自己的 create(取 firstIno 的 inode、分配目录块、写 "."/".."、
    --    在根目录项里登记, 并把根的 links 加到 3)
    local lf, lerr = ext2.create(fs, "/", "lost+found", T_DIR + 448) -- 0700
    if not lf then return nil, "mkfs: failed to create lost+found: " .. tostring(lerr) end

    -- 7) 自检: 按 mount() 的路径重新挂回来, 根与 lost+found 必须都在
    local rfs, rerr = ext2.mount(bd)
    if not rfs then return nil, "mkfs: self-check mount failed: " .. tostring(rerr) end
    local root = ext2.lookup(rfs, "/")
    if not root or root.type ~= T_DIR then return nil, "mkfs: self-check cannot read root directory" end
    local lfi = ext2.lookup(rfs, "/lost+found")
    if not lfi or lfi.type ~= T_DIR then return nil, "mkfs: self-check cannot read /lost+found" end
    if root.links ~= 3 then return nil, "mkfs: root directory should have links 3, got " .. tostring(root.links) end
    rfs.mkfsInfo = info
    return rfs
end

-- ---------------------------------------------------------------
-- fsck: 检查并修复(fsck.ext2 的内核实现)
-- ---------------------------------------------------------------

--- 把一串数字格式化成紧凑区间("1 2 3 8" -> "1--3 8"), 供位图差异那类报告用。
local function formatRanges(nums)
    table.sort(nums)
    local parts, i = {}, 1
    while i <= #nums do
        local j = i
        while j + 1 <= #nums and nums[j + 1] == nums[j] + 1 do j = j + 1 end
        if j == i then
            parts[#parts + 1] = tostring(nums[i])
        elseif j == i + 1 then
            parts[#parts + 1] = tostring(nums[i])
            parts[#parts + 1] = tostring(nums[j])
        else
            parts[#parts + 1] = nums[i] .. "--" .. nums[j]
        end
        i = j + 1
    end
    return table.concat(parts, " ")
end

--- 检查(并可选修复)一个 ext2 文件系统 —— fsck.ext2 的内核实现。
---
--- 与真实 e2fsck 一样分五趟: ①inode/块 ②目录结构 ③连通性(孤儿 inode 重连 /lost+found)
--- ④引用计数 ⑤位图与块组计数。块组数、块大小都是按超级块现算的, 所以宿主 mkfs.ext2
--- 造出来的多块组镜像也走同一条路径(驱动自己只造单块组)。
---
--- **检查与修复是同一套代码**: mode == "check" 时 problem() 只打印不写盘, 一个字节都不落。
---@param bd table 块设备
---@param opts table|nil {
---   mode  = "check"(只看) | "ask"(逐项问) | "fix"(全修),
---   ask   = fun(desc: string): boolean,  mode=="ask" 的询问回调(工具接 stdin),
---   emit  = fun(line: string),         每产出一行就回调(工具直接打印, 不必等跑完),
---   yield = fun(),                     让出调度器(真机上长循环不让出会收不到 ^C),
--- }
---@return table report { code, errors, fixed, unfixed, lines, files, blocks, nonContiguous }
function ext2.fsck(bd, opts)
    opts = opts or {}
    local mode = opts.mode or "check"
    if mode ~= "check" and mode ~= "ask" and mode ~= "fix" then mode = "check" end

    local lines = {}
    local errors, fixed, unfixed = 0, 0, 0
    local function out(s)
        lines[#lines + 1] = s
        if opts.emit then opts.emit(s) end
    end
    -- 运行期错误(超级块读不了/不是 ext2/不认识的特性): 直接以退出码 8 收场。
    -- 这不是"发现问题", 而是"没法检查", 与 e2fsck 的 8 同义。
    local function fatal(msg)
        out(msg)
        errors = errors + 1
        unfixed = unfixed + 1
        return { code = 8, errors = errors, fixed = fixed, unfixed = unfixed, lines = lines }
    end

    -- 让出调度器: 每 50ms CPU 时间一次(与 cat/dd 的分片规则一致)。
    local yield = opts.yield
    local lastYield = os.epoch and (os.epoch("utc") / 1000) or 0
    local function tick()
        if not yield then return end
        local t = os.epoch("utc") / 1000
        if t - lastYield >= 0.05 then lastYield = t; yield() end
    end

    --- 报告一个问题; 返回"是否真的修好了"。apply 为 nil = 没有安全的修法, 只报告。
    local function problem(desc, apply)
        errors = errors + 1
        if mode == "check" or not apply then
            out(desc .. "  <not fixed>")
            unfixed = unfixed + 1
            return false
        end
        if mode == "ask" then
            local yes = opts.ask and opts.ask(desc .. "  Fix<y>? ")
            if not yes then
                out(desc .. "  <not fixed>")
                unfixed = unfixed + 1
                return false
            end
        end
        if apply() == false then
            out(desc .. "  <not fixed>")
            unfixed = unfixed + 1
            return false
        end
        fixed = fixed + 1
        out(desc .. "  FIXED.")
        return true
    end

    -- ---------- 超级块 ----------
    local sb = bd.read(1024, 1024)
    if not sb or #sb < 1024 then return fatal("fsck: cannot read superblock") end
    if u16(sb, 56) ~= 0xEF53 then return fatal("fsck: bad magic number in superblock (not an ext2 filesystem)") end
    local logBlockSize = u32(sb, 24)
    if logBlockSize > 2 then
        return fatal(string.format("fsck: unsupported block size (1024 << %d)", logBlockSize))
    end
    -- 只认识 INCOMPAT_FILETYPE(目录项的 file_type 字段); 其余不认识的特性说明盘上有我们
    -- 读不懂的结构, 继续"修复"只会把它改坏 —— 直接拒绝(与 e2fsck 的 "unsupported feature" 同义)。
    local incompat = u32(sb, 96)
    local unknown = andNot(incompat, 0x2)
    if unknown ~= 0 then
        return fatal(string.format("fsck: unsupported incompat features (0x%x), refusing to check", unknown))
    end

    local fs = ext2.mount(bd)
    if not fs then return fatal("fsck: cannot mount ext2 superblock") end
    local blockSize = fs.blockSize
    local totalBlocks, totalInodes = fs.blocks, fs.inodes
    local inodesPerGroup, inodeSize, firstDataBlock = fs.inodesPerGroup, fs.inodeSize, fs.firstDataBlock
    local blocksPerGroup = fs.blocksPerGroup
    local numGroups = fs.numGroups
    local bitsPerBitmap = blockSize * 8
    local per = perIndirect(fs)

    if blocksPerGroup ~= 8 * blockSize then
        return fatal(string.format("fsck: bad blocks_per_group (%d, expected %d)", blocksPerGroup, 8 * blockSize))
    end
    if inodesPerGroup < 1 or inodesPerGroup > bitsPerBitmap then
        return fatal(string.format("fsck: bad inodes_per_group (%d)", inodesPerGroup))
    end
    if inodeSize < 128 or inodeSize > blockSize or inodeSize % 128 ~= 0 then
        return fatal(string.format("fsck: bad inode size (%d)", inodeSize))
    end
    if firstDataBlock ~= ((blockSize == 1024) and 1 or 0) then
        return fatal(string.format("fsck: bad first_data_block (%d)", firstDataBlock))
    end
    if totalBlocks < numGroups * 1 or totalInodes < 11 then
        return fatal("fsck: superblock counts are impossible")
    end
    if bd.getSize then
        local size = bd.getSize()
        if size and size > 0 and size < totalBlocks * blockSize then
            return fatal(string.format("fsck: device is %d bytes, superblock claims %d blocks (%d bytes)",
                size, totalBlocks, totalBlocks * blockSize))
        end
    end

    local now = math.floor(os.epoch and (os.epoch("utc") / 1000) or os.time())
    local sparseSuper = (u32(sb, 92) % 2) == 1 -- EXT2_FEATURE_COMPAT_SPARSE_SUPER
    local reservedGdt = u16(sb, 206)
    local gdtBlocks = math.ceil(numGroups * 32 / blockSize)

    --- 该块组里是否有超级块副本(组 0 恒有; 稀疏超级块时只有 1 与 3/5/7 的幂)。
    local function hasSuperCopy(g)
        if g == 0 or not sparseSuper then return true end
        for _, base in ipairs({ 3, 5, 7 }) do
            local h = g
            while h % base == 0 do h = h / base end
            if h == 1 then return true end
        end
        return false
    end

    -- 元数据块(boot/superblock/gdt/位图/inode 表): 这些块被文件引用就是"文件用了文件系统的
    -- 元数据", 位图里也永远必须标成占用。
    local metaBlocks = {}
    for g = 0, numGroups - 1 do
        local gd = readGroupDesc(fs, g)
        metaBlocks[gd.blockBitmap] = true
        metaBlocks[gd.inodeBitmap] = true
        local itBlocks = math.ceil(inodesPerGroup * inodeSize / blockSize)
        for i = 0, itBlocks - 1 do metaBlocks[gd.inodeTable + i] = true end
        if hasSuperCopy(g) then
            local base = firstDataBlock + g * blocksPerGroup
            local n = 1 + gdtBlocks + reservedGdt
            for i = 0, n - 1 do metaBlocks[base + i] = true end
        end
    end

    local function getBit(s, bit)
        local v = s:byte(math.floor(bit / 8) + 1) or 0
        return math.floor(v / 2 ^ (bit % 8)) % 2 == 1
    end
    local function setBitAt(s, bit, on)
        local pos = math.floor(bit / 8) + 1
        local v = s:byte(pos) or 0
        local cur = math.floor(v / 2 ^ (bit % 8)) % 2 == 1
        if cur == on then return s end
        if on then v = v + 2 ^ (bit % 8) else v = v - 2 ^ (bit % 8) end
        return s:sub(1, pos - 1) .. string.char(v) .. s:sub(pos + 1)
    end
    local function countFreeInRange(bitmap, from, to)
        local n = 0
        for bit = from, to - 1 do if not getBit(bitmap, bit) then n = n + 1 end end
        return n
    end
    local imapCache = {}
    local function inodeBitmap(g)
        if not imapCache[g] then imapCache[g] = readBlockStr(fs, readGroupDesc(fs, g).inodeBitmap) end
        return imapCache[g]
    end
    --- 改一个 inode 位图位并**立刻**落盘: 中途别的代码(如 lost+found 的 create)也会改位图,
    --- 攒到最后一起写会把那些改动覆盖掉。
    local function setInodeBit(g, bit, on)
        local gd = readGroupDesc(fs, g)
        local bmap = setBitAt(inodeBitmap(g), bit, on)
        writeBlockStr(fs, gd.inodeBitmap, bmap)
        imapCache[g] = bmap
    end

    local reservedIno = fs.firstIno -- 组 0 的 inode 1..firstIno-1 是保留段(mkfs 把它们标成占用)

    -- ---------- Pass 1: inode / 块 ----------
    out("Pass 1: Checking inodes, blocks, and sizes")
    local blockOwner = {} -- 块号 -> 占用它的 inode
    local nonContiguous = 0

    --- 一个 inode 引用的块。每项带 set(newBlk) —— 多重占用时用它把指针改到克隆块上。
    --- 快速符号链接(<= 60 字节)的目标字节内联在 i_block 里, **不是块号**
    --- (与 readSymlink 的 60 字节分界必须一致, 否则会把目标字节当块号)。
    local function inodeBlocks(inode)
        local data, meta = {}, {}
        if inode.type == T_SYM and (inode.size or 0) <= 60 then return data, meta end
        local function slotSetter(slot)
            return function(newBlk)
                local i = ext2.readInode(fs, inode.ino)
                i.ptrs[slot] = newBlk
                ext2.writeInode(fs, i)
            end
        end
        for n = 1, 12 do
            local b = inode.ptrs[n]
            if b ~= 0 then data[#data + 1] = { blk = b, idx = n - 1, set = slotSetter(n) } end
        end
        if inode.ptrs[13] ~= 0 then
            local ind = inode.ptrs[13]
            meta[#meta + 1] = { blk = ind, set = slotSetter(13) }
            local d = readBlockStr(fs, ind)
            if d then
                for i = 0, per - 1 do
                    local b, off = u32(d, i * 4), i * 4
                    if b ~= 0 then
                        data[#data + 1] = { blk = b, idx = 12 + i, set = function(nb)
                            local dd = readBlockStr(fs, ind)
                            if dd then writeBlockStr(fs, ind, setU32(dd, off, nb)) end
                        end }
                    end
                end
            end
        end
        if inode.ptrs[14] ~= 0 then
            local dbl = inode.ptrs[14]
            meta[#meta + 1] = { blk = dbl, set = slotSetter(14) }
            local dblData = readBlockStr(fs, dbl)
            if dblData then
                for i = 0, per - 1 do
                    local ioff, ind = i * 4, u32(dblData, i * 4)
                    if ind ~= 0 then
                        meta[#meta + 1] = { blk = ind, set = function(nb)
                            local d2 = readBlockStr(fs, dbl)
                            if d2 then writeBlockStr(fs, dbl, setU32(d2, ioff, nb)) end
                        end }
                        local indData = readBlockStr(fs, ind)
                        if indData then
                            for j = 0, per - 1 do
                                local joff, b = j * 4, u32(indData, j * 4)
                                if b ~= 0 then
                                    data[#data + 1] = { blk = b, idx = 12 + per + i * per + j, set = function(nb)
                                        local d3 = readBlockStr(fs, ind)
                                        if d3 then writeBlockStr(fs, ind, setU32(d3, joff, nb)) end
                                    end }
                                end
                            end
                        end
                    end
                end
            end
        end
        -- 三间接: 驱动没有写路径(文件大小上限就到双间接), 只如实记下来
        if inode.ptrs[15] ~= 0 then meta[#meta + 1] = { blk = inode.ptrs[15], set = slotSetter(15) } end
        return data, meta
    end

    for ino = 1, totalInodes do
        if ino % 256 == 0 then tick() end
        local g = math.floor((ino - 1) / inodesPerGroup)
        local bit = (ino - 1) % inodesPerGroup
        local inode = ext2.readInode(fs, ino)
        if not inode then return fatal(string.format("fsck: cannot read inode %d", ino)) end
        -- inode 1..10 是保留段(坏块 inode、root、resize inode、journal inode…): e2fsck 同此,
        -- 既不查它们的块/链接计数, 也不把它们当孤儿。resize inode 的 i_block 本来就指着
        -- 预留 GDT 块(那是它的正常形态, 不是"文件占了元数据")。
        if ino < reservedIno then
            -- 跳过
        elseif inode.mode == 0 then
            -- 空 inode 但位图标着占用(保留段除外, mkfs 一直这么标)
            if ino >= reservedIno then
                if getBit(inodeBitmap(g), bit) then
                    problem(string.format("Inode %d is unused but marked in use", ino), function()
                        setInodeBit(g, bit, false)
                    end)
                end
            end
        else
            if not getBit(inodeBitmap(g), bit) then
                problem(string.format("Inode %d is in use, but not marked in use", ino), function()
                    setInodeBit(g, bit, true)
                end)
            end

            local type = itype(inode.mode)
            if type ~= T_DIR and type ~= T_REG and type ~= T_SYM and type ~= T_FIFO
                and type ~= 0x2000 and type ~= 0x6000 and type ~= 0xC000 then
                problem(string.format("Inode %d has invalid mode (0x%x)", ino, inode.mode), function()
                    fs.bd.write(inodeDiskOffset(fs, ino), string.rep("\0", fs.inodeSize))
                    setInodeBit(g, bit, false)
                end)
            else
                local data, meta = inodeBlocks(inode)

                --- 指针合法性 + 多重占用。返回 true 表示这个块最终归本 inode。
                local function checkPtr(e)
                    local b = e.blk
                    if b < firstDataBlock or b >= totalBlocks then
                        problem(string.format("Inode %d has a bad block pointer (%d, fs has %d blocks)",
                            ino, b, totalBlocks), function() e.set(0) end)
                        e.bad = true
                    elseif metaBlocks[b] then
                        problem(string.format("Inode %d block %d is filesystem metadata", ino, b), function()
                            e.set(0)
                        end)
                        e.bad = true
                    elseif blockOwner[b] and blockOwner[b] ~= ino then
                        local other = blockOwner[b]
                        problem(string.format("Block %d is multiply claimed by inode %d and inode %d",
                            b, other, ino), function()
                            -- 克隆: 把内容复制到新块, 本 inode 改指新块(e2fsck 的 "clone" 语义)
                            local nb = ext2.allocBlock(fs)
                            if not nb then return end
                            local content = readBlockStr(fs, b)
                            if content then writeBlockStr(fs, nb, content) end
                            e.set(nb)
                            e.blk = nb
                            blockOwner[nb] = ino
                        end)
                    else
                        blockOwner[b] = ino
                    end
                end
                for _, e in ipairs(meta) do checkPtr(e) end
                for _, e in ipairs(data) do checkPtr(e) end

                -- i_blocks: 数据块 + 间接块, 单位是 512 字节扇区
                local counted = 0
                for _, e in ipairs(data) do if not e.bad then counted = counted + 1 end end
                for _, e in ipairs(meta) do if not e.bad then counted = counted + 1 end end
                local wantBlocks = counted * math.floor(blockSize / 512)
                if (inode.blocks or 0) ~= wantBlocks then
                    problem(string.format("Inode %d, i_blocks is %d, should be %d",
                        ino, inode.blocks or 0, wantBlocks), function()
                        local i = ext2.readInode(fs, ino)
                        i.blocks = wantBlocks
                        ext2.writeInode(fs, i)
                    end)
                end

                if type == T_DIR then
                    local nBlocks = math.ceil((inode.size or 0) / blockSize)
                    if (inode.size or 0) == 0 or inode.size % blockSize ~= 0 or nBlocks > #data then
                        local wantSize = math.max(1, #data) * blockSize
                        problem(string.format("Inode %d is a directory with invalid size %d (should be %d)",
                            ino, inode.size or 0, wantSize), function()
                            local i = ext2.readInode(fs, ino)
                            i.size = wantSize
                            ext2.writeInode(fs, i)
                        end)
                    end
                elseif type == T_REG then
                    -- 非连续文件(块号不按逻辑块序递增)只统计, 给汇总行用
                    local prevIdx, prevBlk
                    for _, e in ipairs(data) do
                        if prevBlk and e.idx == prevIdx + 1 and e.blk ~= prevBlk + 1 then
                            nonContiguous = nonContiguous + 1
                            break
                        end
                        prevIdx, prevBlk = e.idx, e.blk
                    end
                end
            end
        end
    end

    -- ---------- Pass 2: 目录结构 ----------
    out("Pass 2: Checking directory structure")
    local refs = {}         -- ino -> 被目录项引用的次数
    local visitedDirs = {}  -- 已按树走过的目录
    local parentOf = {}     -- 目录 -> 父目录

    --- 把一个目录块按 live 条目重新打包(空条目归到块尾)。
    --- 目录块里 inode=0 的条目只能是**块尾**的空闲空间: 中间的空洞、被删掉的坏条目
    --- 一律靠重打包收干净 —— 这比为每条修补单独算 rec_len 简单得多, 也不会留下
    --- "inode=0 条目夹在活条目之间"那种 e2fsck 判 "directory corrupted" 的形态。
    local function packEntries(entries)
        if #entries == 0 then
            return w32(0) .. w16(blockSize) .. string.char(0, 0) .. string.rep("\0", blockSize - 8)
        end
        local outParts, off = {}, 0
        for i, e in ipairs(entries) do
            local actual = alignedSize(8 + #e.name)
            local rec = (i == #entries) and (blockSize - off) or actual
            outParts[#outParts + 1] = w32(e.ino) .. w16(rec) .. string.char(#e.name, e.type)
                .. e.name .. string.rep("\0", rec - 8 - #e.name)
            off = off + rec
        end
        return table.concat(outParts)
    end

    --- 处理一个目录(校验并修补它的每个目录块), 返回它引用的子目录列表。
    local function checkDir(dirIno, parentIno)
        local inode = ext2.readInode(fs, dirIno)
        if not inode or itype(inode.mode) ~= T_DIR then return {} end
        if (inode.size or 0) == 0 then
            local okFix = problem(string.format("Inode %d (directory) has no data block", dirIno), function()
                local blk = ext2.allocBlock(fs)
                local i = ext2.readInode(fs, dirIno)
                i.ptrs[1] = blk
                i.size = blockSize
                i.blocks = math.floor(blockSize / 512)
                ext2.writeInode(fs, i)
                writeBlockStr(fs, blk, packEntries({}))
            end)
            if not okFix then return {} end
            inode = ext2.readInode(fs, dirIno)
        end

        local nBlocks = math.ceil(inode.size / blockSize)
        local children, names = {}, {}
        for idx = 0, nBlocks - 1 do
            tick()
            local inodeNow = (idx == 0) and inode or ext2.readInode(fs, dirIno)
            local blk = ext2.getBlock(fs, inodeNow, idx)
            if not blk or blk == 0 then
                local okFix = problem(string.format("Inode %d (directory) has a hole at block %d", dirIno, idx), function()
                    local i = ext2.readInode(fs, dirIno)
                    local nb = ext2.ensureBlock(fs, i, idx)
                    if nb then
                        writeBlockStr(fs, nb, packEntries({}))
                        ext2.writeInode(fs, i)
                    end
                end)
                if okFix then
                    blk = ext2.getBlock(fs, ext2.readInode(fs, dirIno), idx)
                end
            end
            if blk and blk ~= 0 then
                local raw = readBlockStr(fs, blk)
                local live, issues, dirty = {}, {}, false
                local off = 0
                while off + 8 <= blockSize do
                    local entIno = u32(raw, off)
                    local recLen = u16(raw, off + 4)
                    if recLen < 8 or recLen % 4 ~= 0 or off + recLen > blockSize then
                        issues[#issues + 1] = string.format("Inode %d block %d has a bad entry length at offset %d", dirIno, idx, off)
                        dirty = true
                        break
                    end
                    local nameLen = raw:byte(off + 7) or 0
                    local ftype = raw:byte(off + 8) or 0
                    if entIno == 0 then
                        if off + recLen < blockSize then
                            issues[#issues + 1] = string.format("Inode %d block %d has free space in the middle", dirIno, idx)
                            dirty = true
                        end
                    else
                        local name = (nameLen > 0 and nameLen <= recLen - 8) and raw:sub(off + 9, off + 8 + nameLen) or nil
                        local why
                        if not name then why = "has an entry with a bad name length"
                        elseif name:find("/", 1, true) or name:find("\0", 1, true) then why = "has an entry with an invalid name"
                        elseif entIno > totalInodes then why = string.format("points to inode %d, which is out of range", entIno)
                        else
                            local ent = ext2.readInode(fs, entIno)
                            if not ent or ent.mode == 0 then
                                why = string.format("points to unused inode %d", entIno)
                            elseif names[name] then
                                why = string.format("has a duplicate entry '%s'", name)
                            end
                        end
                        if why then
                            issues[#issues + 1] = string.format("Inode %d block %d %s ('%s')", dirIno, idx, why, name or "?")
                            dirty = true
                        else
                            local ent = ext2.readInode(fs, entIno)
                            local wantType = typeToFileType(ent.type)
                            if ftype ~= wantType then
                                issues[#issues + 1] = string.format("Inode %d entry '%s' has type %d, should be %d",
                                    dirIno, name, ftype, wantType)
                                dirty = true
                                ftype = wantType
                            end
                            names[name] = true
                            live[#live + 1] = { ino = entIno, name = name, type = ftype }
                        end
                    end
                    off = off + recLen
                end

                -- "." 与 ".." 必须在最前两条、且指向自己与父目录
                if idx == 0 then
                    local dot, dotdot, rest = nil, nil, {}
                    for _, e in ipairs(live) do
                        if e.name == "." then dot = e
                        elseif e.name == ".." then dotdot = e
                        else rest[#rest + 1] = e end
                    end
                    local need = false
                    if not dot then
                        issues[#issues + 1] = string.format("Inode %d is missing '.'", dirIno)
                        need = true
                    elseif dot.ino ~= dirIno then
                        issues[#issues + 1] = string.format("Inode %d has a bad '.' entry (points to %d)", dirIno, dot.ino)
                        need = true
                    end
                    if not dotdot then
                        issues[#issues + 1] = string.format("Inode %d is missing '..'", dirIno)
                        need = true
                    elseif dotdot.ino ~= parentIno then
                        issues[#issues + 1] = string.format("Inode %d has a bad '..' entry (points to %d, should be %d)",
                            dirIno, dotdot.ino, parentIno)
                        need = true
                    end
                    if need then
                        dirty = true
                        live = { { ino = dirIno, name = ".", type = FT_DIR }, { ino = parentIno, name = "..", type = FT_DIR } }
                        for _, e in ipairs(rest) do live[#live + 1] = e end
                    end
                end

                if dirty then
                    problem(table.concat(issues, "; "), function()
                        writeBlockStr(fs, blk, packEntries(live))
                    end)
                end

                for _, e in ipairs(live) do
                    if e.name == "." then
                        refs[dirIno] = (refs[dirIno] or 0) + 1
                    elseif e.name == ".." then
                        refs[parentIno] = (refs[parentIno] or 0) + 1
                    else
                        refs[e.ino] = (refs[e.ino] or 0) + 1
                        local ent = ext2.readInode(fs, e.ino)
                        if ent and itype(ent.mode) == T_DIR then
                            children[#children + 1] = e.ino
                        end
                    end
                end
            end
        end
        return children
    end

    --- 从 rootIno 起走一遍目录树(广度优先, 不递归 —— CC 的 C 栈很浅)。
    local function walkTree(rootIno, rootParent)
        local queue = { { ino = rootIno, parent = rootParent } }
        local head = 1
        while head <= #queue do
            local item = queue[head]; head = head + 1
            local children = checkDir(item.ino, item.parent)
            for _, c in ipairs(children) do
                if visitedDirs[c] then
                    if parentOf[c] ~= item.ino then
                        problem(string.format("Directory inode %d is referenced from two directories (%d and %d)",
                            c, parentOf[c] or -1, item.ino), nil)
                    end
                else
                    visitedDirs[c] = true
                    parentOf[c] = item.ino
                    queue[#queue + 1] = { ino = c, parent = item.ino }
                end
            end
        end
    end

    visitedDirs[2] = true
    walkTree(2, 2)

    -- ---------- Pass 3: 连通性 ----------
    out("Pass 3: Checking directory connectivity")
    local lostFoundIno

    --- /lost+found 的 inode 号; 没有就在允许写盘时建一个(e2fsck 同此)。
    local function lostFound(create)
        if lostFoundIno then return lostFoundIno end
        local e = ext2.lookup(fs, "/lost+found")
        if e and itype(e.mode) == T_DIR then
            lostFoundIno = e.ino
            return lostFoundIno
        end
        if e then
            problem("'/lost+found' is not a directory", nil)
            return nil
        end
        if not create then
            out("  /lost+found does not exist (needed to reconnect orphaned inodes)")
            return nil
        end
        local ino, err = ext2.create(fs, "/", "lost+found", T_DIR + 448)
        if not ino then
            out("  cannot create /lost+found: " .. tostring(err))
            return nil
        end
        lostFoundIno = ino
        out(string.format("  Created /lost+found (inode %d)", ino))
        -- 新目录的 "."/".." 也要计进引用表, 否则 Pass 4 会把它的 links 改坏
        visitedDirs[ino] = true
        parentOf[ino] = 2
        walkTree(ino, 2)
        return lostFoundIno
    end

    -- 孤儿 inode: 在用的 inode 却没有任何目录项指向它 —— 挂到 /lost+found 下(名字用 #<ino>,
    -- 与 e2fsck 一样), 目录型的还要修好它的 "."/".." 并继续往下走。
    for ino = reservedIno, totalInodes do
        tick()
        local inode = ext2.readInode(fs, ino)
        if inode.mode ~= 0 and (refs[ino] or 0) == 0 then
            local type = itype(inode.mode)
            problem(string.format("Inode %d is unconnected (will be reconnected to /lost+found)", ino), function()
                local lf = lostFound(true)
                if not lf then return false end
                local lfInode = ext2.readInode(fs, lf)
                if not ext2.addDirEntry(fs, lfInode, "#" .. ino, ino, typeToFileType(type)) then return false end
                refs[ino] = (refs[ino] or 0) + 1
                if type == T_DIR then
                    visitedDirs[ino] = true
                    parentOf[ino] = lf
                    walkTree(ino, lf)
                end
            end)
        end
    end

    -- ---------- Pass 4: 引用计数 ----------
    out("Pass 4: Checking reference counts")
    for ino = reservedIno, totalInodes do
        tick()
        local inode = ext2.readInode(fs, ino)
        if inode.mode ~= 0 then
            local want = refs[ino] or 0
            if (inode.links or 0) ~= want then
                problem(string.format("Inode %d ref count is %d, should be %d", ino, inode.links or 0, want), function()
                    local i = ext2.readInode(fs, ino)
                    i.links = want
                    ext2.writeInode(fs, i)
                end)
            end
        end
    end

    -- ---------- Pass 5: 位图与块组计数 ----------
    out("Pass 5: Checking group summary information")

    -- 5a) inode 位图: 与"实际在用"对齐(保留段保持标占用)
    for g = 0, numGroups - 1 do
        local gd = readGroupDesc(fs, g)
        local bmap = readBlockStr(fs, gd.inodeBitmap)
        imapCache[g] = bmap
        local adds, dels = {}, {}
        local newBmap = bmap
        for bit = 0, inodesPerGroup - 1 do
            local ino = g * inodesPerGroup + bit + 1
            local inode = ext2.readInode(fs, ino)
            local want = (inode.mode ~= 0) or ino < reservedIno
            local marked = getBit(bmap, bit)
            if want and not marked then
                newBmap = setBitAt(newBmap, bit, true)
                adds[#adds + 1] = ino
            elseif marked and not want then
                newBmap = setBitAt(newBmap, bit, false)
                dels[#dels + 1] = ino
            end
        end
        local padN = 0
        for bit = inodesPerGroup, bitsPerBitmap - 1 do
            if not getBit(newBmap, bit) then
                newBmap = setBitAt(newBmap, bit, true)
                padN = padN + 1
            end
        end
        if #adds > 0 or #dels > 0 or padN > 0 then
            local desc = string.format("Group %d inode bitmap differences:", g)
            if #dels > 0 then desc = desc .. "  -" .. formatRanges(dels) end
            if #adds > 0 then desc = desc .. "  +" .. formatRanges(adds) end
            if padN > 0 then desc = desc .. "  (padding at end not set)" end
            problem(desc, function()
                writeBlockStr(fs, gd.inodeBitmap, newBmap)
                imapCache[g] = newBmap
            end)
        end
    end

    -- 5b) 块位图: 用"最终落盘的 inode 内容"重算一遍占用
    local usedBlocks = {}
    for b in pairs(metaBlocks) do
        if b >= 0 and b < totalBlocks then usedBlocks[b] = true end
    end
    for ino = 1, totalInodes do
        tick()
        local inode = ext2.readInode(fs, ino)
        if inode.mode ~= 0 then
            local data, meta = inodeBlocks(inode)
            for _, e in ipairs(data) do
                if e.blk >= firstDataBlock and e.blk < totalBlocks then usedBlocks[e.blk] = true end
            end
            for _, e in ipairs(meta) do
                if e.blk >= firstDataBlock and e.blk < totalBlocks then usedBlocks[e.blk] = true end
            end
        end
    end

    for g = 0, numGroups - 1 do
        local gd = readGroupDesc(fs, g)
        local bmap = readBlockStr(fs, gd.blockBitmap)
        local start = firstDataBlock + g * blocksPerGroup
        local limit = math.min(blocksPerGroup, totalBlocks - start)
        if limit < 0 then limit = 0 end
        local adds, dels = {}, {}
        local newBmap = bmap
        for bit = 0, limit - 1 do
            local blk = start + bit
            local want = usedBlocks[blk] and true or false
            local marked = getBit(bmap, bit)
            if want and not marked then
                newBmap = setBitAt(newBmap, bit, true)
                adds[#adds + 1] = blk
            elseif marked and not want then
                newBmap = setBitAt(newBmap, bit, false)
                dels[#dels + 1] = blk
            end
        end
        local padN = 0
        for bit = limit, bitsPerBitmap - 1 do
            if not getBit(newBmap, bit) then
                newBmap = setBitAt(newBmap, bit, true)
                padN = padN + 1
            end
        end
        if #adds > 0 or #dels > 0 or padN > 0 then
            local desc = string.format("Group %d block bitmap differences:", g)
            if #dels > 0 then desc = desc .. "  -" .. formatRanges(dels) end
            if #adds > 0 then desc = desc .. "  +" .. formatRanges(adds) end
            if padN > 0 then desc = desc .. "  (padding at end not set)" end
            problem(desc, function()
                writeBlockStr(fs, gd.blockBitmap, newBmap)
            end)
        end
    end

    -- 5c) 空闲计数与目录计数: 用最终位图重算, 与盘上的值逐项比对
    local totalFreeBlocks, totalFreeInodes = 0, 0
    for g = 0, numGroups - 1 do
        local gd = readGroupDesc(fs, g)
        local bmap = readBlockStr(fs, gd.blockBitmap)
        local imap = readBlockStr(fs, gd.inodeBitmap)
        local start = firstDataBlock + g * blocksPerGroup
        local limit = math.min(blocksPerGroup, totalBlocks - start)
        if limit < 0 then limit = 0 end
        local freeB = countFreeInRange(bmap, 0, limit)
        local freeI = countFreeInRange(imap, 0, inodesPerGroup)
        totalFreeBlocks = totalFreeBlocks + freeB
        totalFreeInodes = totalFreeInodes + freeI
        local dirs = 0
        for bit = 0, inodesPerGroup - 1 do
            local ino = g * inodesPerGroup + bit + 1
            local inode = ext2.readInode(fs, ino)
            if inode.mode ~= 0 and itype(inode.mode) == T_DIR then dirs = dirs + 1 end
        end
        local raw = bd.read(fs.gdtOffset + g * 32, 32)
        if u16(raw, 12) ~= freeB then
            problem(string.format("Group %d free blocks count wrong (%d, counted=%d)", g, u16(raw, 12), freeB), function()
                bd.write(fs.gdtOffset + g * 32, setU16(raw, 12, freeB))
            end)
        end
        if u16(raw, 14) ~= freeI then
            problem(string.format("Group %d free inodes count wrong (%d, counted=%d)", g, u16(raw, 14), freeI), function()
                bd.write(fs.gdtOffset + g * 32, setU16(raw, 14, freeI))
            end)
        end
        if u16(raw, 16) ~= dirs then
            problem(string.format("Group %d directories count wrong (%d, counted=%d)", g, u16(raw, 16), dirs), function()
                bd.write(fs.gdtOffset + g * 32, setU16(raw, 16, dirs))
            end)
        end
    end

    local sbNow = bd.read(1024, 1024)
    local sbFreeBlocks, sbFreeInodes = u32(sbNow, 12), u32(sbNow, 16)
    if sbFreeBlocks ~= totalFreeBlocks then
        problem(string.format("Free blocks count wrong in superblock (%d, counted=%d)", sbFreeBlocks, totalFreeBlocks), function()
            bd.write(1024, setU32(sbNow, 12, totalFreeBlocks))
        end)
    end
    if sbFreeInodes ~= totalFreeInodes then
        problem(string.format("Free inodes count wrong in superblock (%d, counted=%d)", sbFreeInodes, totalFreeInodes), function()
            bd.write(1024, setU32(sbNow, 16, totalFreeInodes))
        end)
    end
    if u16(sbNow, 58) ~= 1 then
        problem("Filesystem state is not clean", function()
            bd.write(1024, setU16(sbNow, 58, 1))
        end)
    end

    -- 收尾: 改动过就把超级块标记成干净并刷新时间戳(e2fsck 语义)
    if mode ~= "check" and fixed > 0 then
        local sbEnd = bd.read(1024, 1024)
        sbEnd = setU16(sbEnd, 58, 1)   -- s_state: clean
        sbEnd = setU16(sbEnd, 52, 0)   -- s_mnt_count
        sbEnd = setU32(sbEnd, 48, now) -- s_wtime
        sbEnd = setU32(sbEnd, 64, now) -- s_lastcheck
        bd.write(1024, sbEnd)
    end

    local code = 0
    if errors > 0 then code = (unfixed == 0) and 1 or 4 end
    return {
        code = code, errors = errors, fixed = fixed, unfixed = unfixed, lines = lines,
        files = { used = totalInodes - totalFreeInodes, total = totalInodes },
        blocks = { used = totalBlocks - totalFreeBlocks, total = totalBlocks },
        nonContiguous = nonContiguous,
    }
end

return ext2
