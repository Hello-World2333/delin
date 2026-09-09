--[[ Delin EXT2 文件系统(读写).
     Mount 在一个块设备上; 块大小从 superblock 读; inode 的 mode/uid/gid/类型暴露。
     phase B 修订: 间接块(单/双)、多块组、删除/截断回收块、真实 ".."、硬链接计数、
     isReadOnly=false、时间戳用秒、新块清零、保留块、符号链接、特殊文件类型。 ]]

local ext2 = {}

-- 权限需要当前进程 uid/gid; 不在内核 bundle 里(如 DLUB 引导器)则视为 root(不强制)。
local process = nil
pcall(function() process = require("kernel.process") end)

-- 权限强制辅助(及早定义, 供 create/backend 使用)
local function cred() if not process then return { uid = 0, gid = 0 } end return process.current() end
local function hasPerm(inode, uid, gid, perm) -- perm: 1=x,2=w,4=r
    if uid == 0 then return true end
    local c = (uid == inode.uid) and 6 or ((gid == inode.gid) and 3 or 0)
    local m = math.floor(inode.perms / (2 ^ c)) % 8
    return m % (perm * 2) >= perm
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
local T_DIR, T_REG, T_SYM = 0x4000, 0x8000, 0xA000
local FT_REG, FT_DIR, FT_SYM, FT_CHR, FT_BLK, FT_FIFO, FT_SOCK, FT_UNK = 1, 2, 7, 3, 4, 5, 6, 0
local function itype(mode) return math.floor(mode / 0x1000) * 0x1000 end
local function iperms(mode) return mode % 0x1000 end
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

--- 释放 inode 引用的所有数据块 + 间接指针块。
function ext2.freeBlocksOfInode(fs, inode)
    local nBlocks = math.ceil((inode.size or 0) / fs.blockSize)
    for idx = 0, nBlocks - 1 do
        local blk = ext2.getBlock(fs, inode, idx)
        if blk and blk ~= 0 then ext2.freeBlock(fs, blk) end
    end
    -- 释放间接指针块
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
    local oldBlocks = math.ceil((inode.size or 0) / blockSize)
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
                    -- 也可以只清 inode 留个 ino=0 的条目, 但那样要靠 addDirEntry 记得复用整条
                    -- 空间才不留空洞; 合并更简单, 目录块也不会越用越碎。
                    if not prevOff then return nil, "cannot remove first dir entry" end
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
    local ok, err = ext2.removeDirEntry(fs, parent, name)
    if not ok then return nil, err end
    local child = ext2.readInode(fs, entry.ino)
    if child then
        child.links = math.max(0, child.links - 1)
        -- 目录的 links 含 "." 与 "..": 删空目录后剩 1 即应回收, 否则会漏一个未连接 inode。
        local free = (child.type == T_DIR) and (child.links <= 1) or (child.links <= 0)
        if free then
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
            kind = inode.type == T_DIR and "dir" or (inode.type == T_REG and "file" or (inode.type == T_SYM and "symlink" or "device")),
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
        getSize = function(rel) local i = ext2.lookup(fs, rel); return i and i.size or 0 end,
        getDrive = function() return "ext2" end,
        getFreeSpace = function() return math.max(0, sbFreeBlocks(fs) - fs.rBlocks) * fs.blockSize end,
        getCapacity = function() return fs.blocks * fs.blockSize end,
        open = function(rel, mode)
            local i = ext2.lookup(fs, rel)
            local c = cred()
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
                return {
                    write = function(self, s) if s == nil then s = self end; parts[#parts + 1] = s; return #s end,
                    writeLine = function(self, s) if s == nil then s = self end; parts[#parts + 1] = s .. "\n"; return #s + 1 end,
                    flush = commit,
                    close = commit,
                    seek = function() return 0 end,
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
                return {
                    write = function(self, s) if s == nil then s = self end; parts[#parts + 1] = s; return #s end,
                    writeLine = function(self, s) if s == nil then s = self end; parts[#parts + 1] = s .. "\n"; return #s + 1 end,
                    flush = commit,
                    close = commit,
                    seek = function() return 0 end,
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
                seek = function() return 0 end,
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
        canExecute = function(rel)
            local inode = ext2.lookup(fs, rel)
            if not inode then return false end
            if inode.type ~= T_REG and inode.type ~= T_SYM then return false end
            local c = cred()
            return hasPerm(inode, c.uid, c.gid, 1)
        end,
    }
end

return ext2
