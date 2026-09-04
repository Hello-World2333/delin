--[[ Delin 块设备层.
     块设备 = 可从字节地址读写的存储。CC 没有 raw 块 API, 所以用普通文件实现:
     fs.open(path,"r+") 拿一个不截断的读写句柄, 每个操作 seek("set",offset) + read(n)/write(data)。
     /parts/*.img 就是这种文件块设备。 ]]

local blockdev = {}

local devices = {} -- name -> bd

--- 注册块设备。
---@param name string
---@param bd table  { read(offset,len)->string, write(offset,data), getSize(), close() }
function blockdev.register(name, bd)
    devices[name] = bd
end

function blockdev.get(name)
    return devices[name]
end

function blockdev.names()
    local out = {}
    for n in pairs(devices) do out[#out + 1] = n end
    return out
end

--- 文件块设备: 一个 /parts/*.img 文件。
---@param path string 真实 fs 路径(如 "disk/parts/root.img")
---@return table|nil bd, string|nil err
function blockdev.file(path)
    local handle, err = fs.open(path, "r+")
    if not handle then return nil, err or ("cannot open " .. path) end
    local size = fs.getSize(path)
    local bd = {
        kind = "file",
        path = path,
        handle = handle,
        blockSize = 512, -- 块设备扇区粒度; 文件系统(ext2)从 superblock 读自己的块大小
        ---@param offset number 字节偏移
        ---@param len number 字节数
        read = function(offset, len)
            local ok, p = handle.seek("set", offset)
            if not ok then return nil, tostring(p) end
            local data = handle.read(len)
            return data
        end,
        write = function(offset, data)
            local ok, p = handle.seek("set", offset)
            if not ok then return nil, tostring(p) end
            return handle.write(data)
        end,
        getSize = function() return fs.getSize(path) end,
        close = function() handle.close() end,
    }
    return bd
end

return blockdev
