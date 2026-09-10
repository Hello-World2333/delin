--[[ Delin 块设备层.
     块设备 = 可从字节地址读写的存储。CC 没有 raw 块 API, 所以用普通文件实现:
     fs.open(path,"r+") 拿一个不截断的读写句柄, 按需 seek("set",offset) + read(n)/write(data)。
     /parts/*.img 就是这种文件块设备, 安装器现场建 ext2 镜像也走它。 ]]

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
--- 位置跟踪: CC 的 `handle.seek("set", N)` 在 N **超出文件末尾** 时返回 nil(实测: 空文件
--- 写完第 1 块后, seek 到第 2 块起点就失败 —— mkfs 清零会当场挂)。所以这里自己记当前位置,
--- 只在目标位置与当前位置不同时才 seek: 顺序写(建镜像时清零、顺序落盘)因此不需要任何 seek,
--- 天然能扩展文件。
---@param path string 真实 fs 路径(如 "disk/parts/root.img")
---@return table|nil bd, string|nil err
function blockdev.file(path)
    local handle, err = fs.open(path, "r+")
    if not handle then return nil, err or ("cannot open " .. path) end
    local pos = 0
    local bd = {
        kind = "file",
        path = path,
        handle = handle,
        blockSize = 512, -- 块设备扇区粒度; 文件系统(ext2)从 superblock 读自己的块大小
        ---@param offset number 字节偏移
        ---@param len number 字节数
        read = function(offset, len)
            if offset ~= pos then
                local ok, p = handle.seek("set", offset)
                if not ok then return nil, tostring(p) end
                pos = offset
            end
            local data = handle.read(len)
            pos = pos + #(data or "")
            return data
        end,
        write = function(offset, data)
            if offset ~= pos then
                local ok, p = handle.seek("set", offset)
                if not ok then return nil, tostring(p) end
                pos = offset
            end
            local ok, werr = handle.write(data)
            pos = offset + #data
            if ok == nil and werr ~= nil then return nil, werr end
            return true
        end,
        getSize = function() return fs.getSize(path) end,
        close = function() handle.close() end,
    }
    return bd
end

return blockdev
