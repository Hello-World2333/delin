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
            if mode and mode:find("w") then error("ext2 read-only", 2) end
            local i = ext2.lookup(fs, rel)
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
    }
end

return ext2
