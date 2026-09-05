--[[ Delin /sys/class/display 虚拟配置 fs(sysfs 风格)。
     每个已注册显示设备出现为一个目录(名 = 外设名/side), 目录下是属性文件:
       - 只读: name, type, size
       - 可读写: 设备通过 listConfig() 声明的项(如 tom 的 resolution, void 的 offset/rotation/scale)
     读 = 查当前值; 写 = 设值。若设置改变了设备尺寸(getSize 变化), 会热重算派生 tty/fb。 ]]

local vfs     = require("kernel.vfs")
local display = require("kernel.display")

local sysfs = {}

local function norm(rel) return (rel or ""):gsub("^/+", "") end

--- 拆分 rel -> 设备名, 属性名。
local function split(rel)
    rel = norm(rel)
    if rel == "" then return nil end
    local parts = {}
    for p in rel:gmatch("[^/]+") do parts[#parts + 1] = p end
    if #parts == 0 then return nil end
    if #parts == 1 then return parts[1], nil end
    if #parts == 2 then return parts[1], parts[2] end
    return nil
end

--- 设备可读的属性列表(内建 + 设备声明的)。
local function readAttrs(dev)
    local out = { "name", "type", "size" }
    if dev.listConfig then
        for _, a in ipairs(dev.listConfig()) do out[#out + 1] = a end
    end
    return out
end

--- 读取一个属性(字符串)。
local function getAttr(dev, attr)
    if attr == "name" then return dev.name or dev.id end
    if attr == "type" then return tostring(dev.type or "") end
    if attr == "size" then
        local w, h = dev.getSize()
        return tostring(w) .. "x" .. tostring(h)
    end
    if dev.getConfig then return dev.getConfig(attr) end
    return nil
end

--- 属性是否可写(设备 listConfig 里声明的且实现了 setConfig)。
local function isWritable(dev, attr)
    if attr == "name" or attr == "type" or attr == "size" then return false end
    if dev.listConfig and dev.setConfig then
        for _, a in ipairs(dev.listConfig()) do
            if a == attr then return true end
        end
    end
    return false
end

--- 打开属性文件句柄。
local function openAttr(dev, attr)
    local function writeImpl(s)
        if not isWritable(dev, attr) then return nil, "read-only attribute" end
        local v = s:gsub("[\r\n]+$", "")
        local bw1, bh1 = dev.getSize()
        local ok, err = dev.setConfig(attr, v)
        if ok then
            local bw2, bh2 = dev.getSize()
            if bw1 ~= bw2 or bh1 ~= bh2 then display.resize(dev.id) end
        end
        if ok then return #s else return nil, err end
    end
    return {
        read     = function() return getAttr(dev, attr) or "" end,
        readLine = function() return getAttr(dev, attr) or "" end,
        readAll  = function() return getAttr(dev, attr) or "" end,
        write    = function(self, s) return writeImpl(s) end,
        writeLine = function(self, s) return writeImpl(s .. "\n") end,
        close    = function() end,
        flush    = function() return true end,
    }
end

local backend = {
    kind = "virtual",
    list = function(rel)
        local name, attr = split(rel)
        if name == nil then
            local out = {}
            for _, id in ipairs(display.list()) do
                local d = display.get(id)
                if d and d.name then out[#out + 1] = d.name end
            end
            return out
        end
        if attr == nil then
            local d = display.byName(name)
            if not d then return nil end
            return readAttrs(d)
        end
        return nil
    end,
    exists = function(rel)
        local name, attr = split(rel)
        if name == nil then return true end
        local d = display.byName(name)
        if not d then return false end
        if attr == nil then return true end
        for _, a in ipairs(readAttrs(d)) do if a == attr then return true end end
        return false
    end,
    isDir = function(rel)
        local name, attr = split(rel)
        if name == nil then return true end
        return attr == nil
    end,
    attributes = function(rel)
        local name, attr = split(rel)
        if name == nil then return { size = 0, isDir = true, isReadOnly = true, name = "display" } end
        local d = display.byName(name)
        if not d then return nil end
        if attr == nil then return { size = 0, isDir = true, isReadOnly = true, name = name } end
        return { size = 0, isDir = false, isReadOnly = not isWritable(d, attr), name = attr }
    end,
    getSize = function() return 0 end,
    getDrive = function() return "sys" end,
    getFreeSpace = function() return 0 end,
    getCapacity = function() return 0 end,
    isReadOnly = function(rel)
        local name, attr = split(rel)
        if attr == nil then return true end
        local d = display.byName(name)
        if not d then return true end
        return not isWritable(d, attr)
    end,
    open = function(rel, mode)
        local name, attr = split(rel)
        if name == nil or attr == nil then return nil, "is a directory" end
        local d = display.byName(name)
        if not d then return nil, "no such display: " .. name end
        if mode and mode:find("w") and not isWritable(d, attr) then
            return nil, "read-only attribute: " .. attr
        end
        return openAttr(d, attr)
    end,
    makeDir = function() error("read-only fs", 2) end,
    move    = function() error("read-only fs", 2) end,
    copy    = function() error("read-only fs", 2) end,
    delete  = function() error("read-only fs", 2) end,
}

--- 挂载 /sys/class/display。
function sysfs.mount()
    vfs.mount("/sys/class/display", backend)
    return true
end

return sysfs
