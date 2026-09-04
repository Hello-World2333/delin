--[[ Delin EXT2 文件系统(只读 for phase A).
     Mount 在一个块设备上; 块大小从 superblock 读; inode 的 mode/uid/gid 暴露在 attributes。
     VFS 后端提供 list/exists/isDir/attributes/getSize/open(读)/getDrive/getFreeSpace/getCapacity/isReadOnly。 ]]

local ext2 = {}

-- 读小端整数 (EXT2 为小端)
local function u16(s, off) local a, b = s:byte(off + 1, off + 2); return a + b * 256 end
local function u32(s, off) local a, b, c, d = s:byte(off + 1, off + 4); return a + b * 256 + c * 65536 + d * 16777216 end

-- inode 类型
local TYPE_MASK = 0xF000
local T_FIFO, T_CHR, T_DIR, T_BLK, T_REG, T_SYM, T_SOCK = 0x1000, 0x2000, 0x4000, 0x6000, 0x8000, 0xA000, 0xC000

---@class Ext2Fs
---@field bd table
---@field blockSize number
---@field inodesPerGroup number
---@field inodeSize number
---@field firstIno number
---@field gdtOffset number

--- 挂载 EXT2 到一个块设备。
---@param bd table 块设备(read(offset,len)->string)
---@return table|nil fs, string|nil err
function ext2.mount(bd)
    local sb = bd.read(1024, 1024)
    if not sb or #sb < 1024 then return nil, "cannot read superblock" end
    local magic = u16(sb, 56)
    if magic ~= 0xEF53 then return nil, "not EXT2 (magic " .. string.format("%x", magic) .. ")" end
    local logBlock = u32(sb, 24)
    local blockSize = 1024 * 2 ^ logBlock
    local fs = {
        bd = bd,
        blockSize = blockSize,
        inodesPerGroup = u32(sb, 40),
        inodeSize = u16(sb, 88) or 128,
        firstIno = u32(sb, 84),
        inodes = u32(sb, 0),
        blocks = u32(sb, 4),
        blocksPerGroup = u32(sb, 32),
        -- 超级块在块1(1024 字节块); GDT 紧随其后
        gdtOffset = (blockSize == 1024) and (2 * blockSize) or (1 * blockSize),
    }
    return fs
end

--- 读一个 inode。
---@param fs Ext2Fs
---@param ino number
---@return table|nil inode
function ext2.readInode(fs, ino)
    local group = math.floor((ino - 1) / fs.inodesPerGroup)
    local index = (ino - 1) % fs.inodesPerGroup
    local gdt = fs.bd.read(fs.gdtOffset + group * 32, 32)
    if not gdt then return nil end
    local inodeTableBlock = u32(gdt, 8) -- bg_inode_table
    local inodeOffset = inodeTableBlock * fs.blockSize + index * fs.inodeSize
    local raw = fs.bd.read(inodeOffset, fs.inodeSize)
    if not raw then return nil end
    local i = {
        ino = ino,
        mode = u16(raw, 0),
        uid = u16(raw, 2),
        sizeLo = u32(raw, 4),
        gid = u16(raw, 24),
        links = u16(raw, 26),
        blocks = u32(raw, 28),
        sizeHigh = u32(raw, 108),
    }
    i.size = i.sizeHigh * 4294967296 + i.sizeLo
    i.type = math.floor(i.mode / 0x1000) * 0x1000 -- mode & 0xF000 (5.2 无 &, 用算术)
    i.perms = i.mode % 0x1000 -- mode & 0xFFF
    i.ptrs = {}
    for n = 0, 14 do i.ptrs[n + 1] = u32(raw, 40 + n * 4) end
    return i
end

local function readBlockData(fs, blockNum)
    return fs.bd.read(blockNum * fs.blockSize, fs.blockSize)
end

--- 从目录 inode 读出条目。
---@return table[]  { ino, name, fileType }
function ext2.readDir(fs, dirIno)
    local entries = {}
    if dirIno.type ~= T_DIR then return nil end
    local size = dirIno.size
    local pos = 0
    while pos < size do
        local blkIdx = math.floor(pos / fs.blockSize) + 1
        local blockNum = dirIno.ptrs[blkIdx]
        if not blockNum or blockNum == 0 then break end
        local data = readBlockData(fs, blockNum)
        local off = 0
        while off < #data do
            local entIno = u32(data, off)
            local recLen = u16(data, off + 4)
            if recLen == 0 then break end
            local nameLen = data:byte(off + 7) -- 0-based byte 6 (1-based index off+7)
            local fileType = data:byte(off + 8) -- 0-based byte 7
            if entIno ~= 0 and nameLen > 0 then
                local name = data:sub(off + 9, off + 8 + nameLen)
                entries[#entries + 1] = { ino = entIno, name = name, fileType = fileType }
            end
            off = off + recLen
        end
        pos = pos + fs.blockSize
    end
    return entries
end

--- 在目录中查找名字。
---@return table|nil entry
local function findDirEntry(fs, dirIno, name)
    local entries = ext2.readDir(fs, dirIno)
    if not entries then return nil end
    for _, e in ipairs(entries) do
        if e.name == name then return e end
    end
    return nil
end

--- 按绝对路径查找 inode。
---@return table|nil inode
function ext2.lookup(fs, path)
    path = path:gsub("^/+", ""):gsub("/+$", "")
    local cur = ext2.readInode(fs, 2) -- 根目录
    if path == "" then return cur end
    for part in path:gmatch("[^/]+") do
        if part == "." then
        elseif part == ".." then
            -- 反父目录(简化: 回到根)
            cur = ext2.readInode(fs, 2)
        else
            if cur.type ~= T_DIR then return nil end
            local e = findDirEntry(fs, cur, part)
            if not e then return nil end
            cur = ext2.readInode(fs, e.ino)
        end
    end
    return cur
end

--- 读文件内容。
---@return string|nil content
function ext2.readFile(fs, ino)
    if ino.type == T_SYM then
        -- 符号链接内容直接存在块指针区域(短) — 简化: 读直接块
    end
    if ino.type ~= T_REG then return nil end
    local out = {}
    local remaining = ino.size
    local blk = 1
    while remaining > 0 do
        local blockNum = ino.ptrs[blk]
        if not blockNum or blockNum == 0 then break end
        local data = readBlockData(fs, blockNum)
        if not data then break end
        out[#out + 1] = data:sub(1, math.min(#data, remaining))
        remaining = remaining - #data
        blk = blk + 1
    end
    return table.concat(out)
end

--- 组装一个 VFS 后端(只读)。
---@param fs Ext2Fs
---@return table backend
function ext2.backend(fs)
    local function attr(inode)
        return {
            size = inode.size,
            isDir = inode.type == T_DIR,
            isReadOnly = true,
            mode = inode.mode,
            uid = inode.uid,
            gid = inode.gid,
            ino = inode.ino,
        }
    end
    return {
        kind = "virtual",
        isReadOnly = function() return true end,
        list = function(rel)
            local inode = ext2.lookup(fs, rel or "/")
            if not inode or inode.type ~= T_DIR then return nil end
            local out = {}
            for _, e in ipairs(ext2.readDir(fs, inode)) do
                if e.name ~= "." and e.name ~= ".." then out[#out + 1] = e.name end
            end
            return out
        end,
        exists = function(rel) return ext2.lookup(fs, rel) ~= nil end,
        isDir = function(rel)
            local i = ext2.lookup(fs, rel); return i and i.type == T_DIR or false
        end,
        attributes = function(rel)
            local i = ext2.lookup(fs, rel); return i and attr(i) or nil
        end,
        getSize = function(rel)
            local i = ext2.lookup(fs, rel); return i and i.size or 0
        end,
        getDrive = function() return "ext2" end,
        getFreeSpace = function() return 0 end,
        getCapacity = function() return fs.blocks * fs.blockSize end,
        open = function(rel, mode)
            local i = ext2.lookup(fs, rel)
            if mode and mode:find("w") then
                -- 写: 不存在则创建, 并截断
                if not i then
                    local pdir = rel:match("^(.*)/[^/]*$") or "/"
                    local pname = rel:match("([^/]*)$") or rel
                    local ino, err = ext2.create(fs, pdir, pname, 0x81A4) -- 常规文件 0644
                    if not ino then return nil, err end
                    i = ext2.readInode(fs, ino)
                end
                ext2.writeFile(fs, i.ino, "")
                local parts = {}
                return {
                    write = function(s) parts[#parts + 1] = s; return #s end,
                    writeLine = function(s) parts[#parts + 1] = s .. "\n"; return #s + 1 end,
                    flush = function() return true end,
                    close = function() ext2.writeFile(fs, i.ino, table.concat(parts)); return true end,
                    seek = function() return 0 end,
                }
            end
            if not i then return nil, "no such file" end
            if i.type == T_DIR then return nil, "is a directory" end
            local content = ext2.readFile(fs, i)
            return {
                readAll = function() return content end,
                read = function(n) return n and content:sub(1, n) or content end,
                readLine = function() return content end,
                write = function() end, writeLine = function() end,
                close = function() end, flush = function() return true end,
                seek = function() return 0 end,
            }
        end,
        makeDir = function(rel)
            local pdir = rel:match("^(.*)/[^/]*$") or "/"
            local pname = rel:match("([^/]*)$") or rel
            local ino, err = ext2.create(fs, pdir, pname, 0x41ED) -- 目录 0755
            if not ino then error(tostring(err), 2) end
            return true
        end,
        delete = function(rel)
            local pdir = rel:match("^(.*)/[^/]*$") or "/"
            local pname = rel:match("([^/]*)$") or rel
            local parent = ext2.lookup(fs, pdir)
            if not parent then error("no parent", 2) end
            local entry = findDirEntry(fs, parent, pname)
            if not entry then error("no such entry", 2) end
            ext2.removeDirEntry(fs, parent, pname)
            ext2.freeInode(fs, entry.ino)
            return true
        end,
    }
end

-- =====================================================================
-- Phase B: 写支持 (block/inode 分配, 目录项, 文件写, 增删)
-- =====================================================================
-- 小端写
local function w16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function w32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
local function setU16(s, off, v) return s:sub(1, off) .. w16(v) .. s:sub(off + 3) end
local function setU32(s, off, v) return s:sub(1, off) .. w32(v) .. s:sub(off + 5) end

local function readBlockStr(fs, blockNum) return fs.bd.read(blockNum * fs.blockSize, fs.blockSize) end
local function writeBlockStr(fs, blockNum, data) return fs.bd.write(blockNum * fs.blockSize, data) end

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

--- 把一个 inode 表写回磁盘。
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
    for i = 1, 15 do raw = setU32(raw, 40 + (i - 1) * 4, inode.ptrs[i] or 0) end
    raw = setU32(raw, 108, math.floor(sizeVal / 4294967296))
    return fs.bd.write(inodeDiskOffset(fs, inode.ino), raw)
end

local function updateFreeCounters(fs, dBlocks, dInodes)
    local sb = fs.bd.read(1024, fs.blockSize)
    sb = setU32(sb, 12, (u32(sb, 12) or 0) + dBlocks)
    sb = setU32(sb, 16, (u32(sb, 16) or 0) + dInodes)
    fs.bd.write(1024, sb)
    local gdt = fs.bd.read(fs.gdtOffset, 32)
    gdt = setU16(gdt, 12, (u16(gdt, 12) or 0) + dBlocks)
    gdt = setU16(gdt, 14, (u16(gdt, 14) or 0) + dInodes)
    fs.bd.write(fs.gdtOffset, gdt)
end

--- 分配一个空闲数据块。
local function allocBlock(fs)
    local gd = readGroupDesc(fs, 0)
    local bitmap = readBlockStr(fs, gd.blockBitmap)
    local limit = math.min(fs.blocks, fs.blocksPerGroup) - 1
    for bit = 0, limit do
        local b = math.floor(bit / 8)
        local v = bitmap:byte(b + 1) or 0
        if math.floor(v / 2 ^ (bit % 8)) % 2 == 0 then
            local pos = b + 1
            bitmap = bitmap:sub(1, pos - 1) .. string.char(v + 2 ^ (bit % 8)) .. bitmap:sub(pos + 1)
            writeBlockStr(fs, gd.blockBitmap, bitmap)
            updateFreeCounters(fs, -1, 0)
            return bit
        end
    end
    return nil
end
ext2.allocBlock = allocBlock

--- 分配并初始化一个 inode。
local function allocInode(fs, mode, uid, gid)
    local gd = readGroupDesc(fs, 0)
    local bitmap = readBlockStr(fs, gd.inodeBitmap)
    for bit = (fs.firstIno - 1), (fs.inodesPerGroup - 1) do
        local v = bitmap:byte(math.floor(bit / 8) + 1) or 0
        if math.floor(v / 2 ^ (bit % 8)) % 2 == 0 then
            local pos = math.floor(bit / 8) + 1
            bitmap = bitmap:sub(1, pos - 1) .. string.char(v + 2 ^ (bit % 8)) .. bitmap:sub(pos + 1)
            writeBlockStr(fs, gd.inodeBitmap, bitmap)
            local ino = bit + 1
            local now = os.epoch("utc")
            local inode = { ino = ino, mode = mode, uid = uid or 0, gid = gid or 0, links = 1, size = 0, blocks = 0, atime = now, ctime = now, mtime = now, ptrs = {} }
            for i = 1, 15 do inode.ptrs[i] = 0 end
            ext2.writeInode(fs, inode)
            updateFreeCounters(fs, 0, -1)
            return ino
        end
    end
    return nil
end
ext2.allocInode = allocInode

local function alignedSize(n) return n + ((4 - (n % 4)) % 4) end

--- 往目录 inode 里加一条目录项。
function ext2.addDirEntry(fs, dirIno, name, childIno, fileType)
    local nameLen = #name
    local rec = alignedSize(8 + nameLen)
    local size = dirIno.size or 0
    local pos = 0
    while pos < size do
        local blockNum = dirIno.ptrs[math.floor(pos / fs.blockSize) + 1]
        if blockNum then
            local data = readBlockStr(fs, blockNum)
            local off = 0
            while off < #data do
                local entRecLen = u16(data, off + 4)
                if entRecLen == 0 then break end
                local entNameLen = data:byte(off + 7)
                local actual = alignedSize(8 + entNameLen)
                local slack = entRecLen - actual
                if slack >= rec then
                    data = setU16(data, off + 4, actual)
                    local newOff = off + actual
                    local entry = w32(childIno) .. w16(rec) .. string.char(nameLen, fileType) .. name .. string.rep("\0", rec - (8 + nameLen))
                    data = data:sub(1, newOff) .. entry .. data:sub(newOff + 1)
                    writeBlockStr(fs, blockNum, data)
                    return true
                end
                off = off + entRecLen
            end
        end
        pos = pos + fs.blockSize
    end
    -- 块都满了: 新分配一块
    local newBlock = allocBlock(fs)
    if not newBlock then return nil, "no free block" end
    local idx = math.floor(size / fs.blockSize) + 1
    dirIno.ptrs[idx] = newBlock
    dirIno.size = size + fs.blockSize
    dirIno.blocks = dirIno.blocks + math.floor(fs.blockSize / 512)
    ext2.writeInode(fs, dirIno)
    local lastRec = fs.blockSize -- 首条目 rec_len 填满整块
    local entry = w32(childIno) .. w16(lastRec) .. string.char(nameLen, fileType) .. name .. string.rep("\0", fs.blockSize - (8 + nameLen))
    writeBlockStr(fs, newBlock, entry)
    return true
end

--- 创建文件或目录。
---@return number|nil ino, string|nil err
function ext2.create(fs, dirPath, name, mode)
    local parent = ext2.lookup(fs, dirPath)
    if not parent or parent.type ~= T_DIR then return nil, "parent not a dir" end
    if findDirEntry(fs, parent, name) then return nil, "exists" end
    local ino = allocInode(fs, mode, 0, 0)
    if not ino then return nil, "alloc inode failed" end
    local inode = ext2.readInode(fs, ino)
    local now = os.epoch("utc")
    inode.mtime = now; inode.ctime = now; inode.atime = now
    if math.floor(mode / 0x1000) * 0x1000 == T_DIR then
        local blk = allocBlock(fs)
        if not blk then return nil, "no block for dir" end
        inode.ptrs[1] = blk
        inode.size = fs.blockSize
        inode.blocks = inode.blocks + math.floor(fs.blockSize / 512)
        inode.links = 2
        local e1 = w32(ino) .. w16(12) .. string.char(1, 2) .. "." .. string.rep("\0", 3)
        local e2 = w32(parent.ino) .. w16(fs.blockSize - 12) .. string.char(2, 2) .. ".." .. string.rep("\0", 2)
        writeBlockStr(fs, blk, e1 .. e2)
    end
    ext2.writeInode(fs, inode)
    ext2.addDirEntry(fs, parent, name, ino, math.floor(mode / 0x1000) * 0x1000 == T_DIR and 2 or 1)
    return ino
end

--- 写文件内容(覆盖)。分配块按需。
function ext2.writeFile(fs, ino, content)
    local inode = ext2.readInode(fs, ino)
    if not inode or inode.type ~= T_REG then return nil, "not a regular file" end
    local blockSize = fs.blockSize
    local nBlocks = math.ceil(#content / blockSize)
    for b = 1, 15 do inode.ptrs[b] = inode.ptrs[b] or 0 end
    for b = 1, nBlocks do
        if not inode.ptrs[b] or inode.ptrs[b] == 0 then
            local blk = allocBlock(fs)
            if not blk then return nil, "no block" end
            inode.ptrs[b] = blk
            inode.blocks = inode.blocks + math.floor(blockSize / 512)
        end
        local cs = (b - 1) * blockSize + 1
        local chunk = content:sub(cs, cs + blockSize - 1)
        writeBlockStr(fs, inode.ptrs[b], chunk)
    end
    inode.size = #content
    inode.mtime = os.epoch("utc")
    ext2.writeInode(fs, inode)
    return true
end

--- 删除目录项(标记为未使用)。
function ext2.removeDirEntry(fs, dirIno, name)
    local size = dirIno.size or 0
    local pos = 0
    while pos < size do
        local blockNum = dirIno.ptrs[math.floor(pos / fs.blockSize) + 1]
        if blockNum then
            local data = readBlockStr(fs, blockNum)
            local off = 0
            while off < #data do
                local entRecLen = u16(data, off + 4)
                if entRecLen == 0 then break end
                local entNameLen = data:byte(off + 7)
                if entNameLen == #name and data:sub(off + 9, off + 8 + entNameLen) == name then
                    -- 标记为未使用: inode=0, name_len=0, file_type=0
                    data = setU32(data, off, 0)
                    data = setU16(data, off + 6, 0)
                    data = setU16(data, off + 8, 0)
                    writeBlockStr(fs, blockNum, data)
                    return true
                end
                off = off + entRecLen
            end
        end
        pos = pos + fs.blockSize
    end
    return false
end

--- 释放一个 inode。
function ext2.freeInode(fs, ino)
    local gd = readGroupDesc(fs, 0)
    local bitmap = readBlockStr(fs, gd.inodeBitmap)
    local bit = ino - 1
    local pos = math.floor(bit / 8) + 1
    local v = bitmap:byte(pos) or 0
    if math.floor(v / 2 ^ (bit % 8)) % 2 == 1 then
        v = v - 2 ^ (bit % 8)
        bitmap = bitmap:sub(1, pos - 1) .. string.char(v) .. bitmap:sub(pos + 1)
        writeBlockStr(fs, gd.inodeBitmap, bitmap)
        updateFreeCounters(fs, 0, 1)
        fs.bd.write(inodeDiskOffset(fs, ino), string.rep("\0", fs.inodeSize))
    end
end

return ext2
