--[[ Delin sysfs: 挂在 /sys 的虚拟配置文件系统。
     布局(对齐 Linux sysfs 的 class 子树):
       /sys/class/display/<设备名>/   —— 每个已注册显示设备一个目录, 目录下是属性文件:
         - 只读: name, type, size
         - 可读写: 设备通过 listConfig() 声明的项(如 tom 的 resolution, void 的 offset/rotation/scale)
     读 = 查当前值; 写 = 设值。若设置改变了设备尺寸(getSize 变化), 会热重算派生 tty/fb。
     挂载点是 /sys 本身(与 /dev、/proc 同为挂载根), 所以 /sys、/sys/class 都是可 ls 的目录。 ]]

local vfs     = require("kernel.vfs")
local display = require("kernel.display")

local sysfs = {}

local CLASS_DIR   = "class"
local DISPLAY_DIR = "display"

local function norm(rel) return (rel or ""):gsub("^/+", "") end

--- 解析 /sys 下的相对路径。
---@param rel string
---@return string|nil kind "root"|"class"|"display"|"dev"|"attr" (nil = 路径不存在)
---@return string|nil dev  设备名(kind=dev|attr)
---@return string|nil attr 属性名(kind=attr)
local function parse(rel)
    rel = norm(rel)
    if rel == "" then return "root" end
    local parts = {}
    for p in rel:gmatch("[^/]+") do parts[#parts + 1] = p end
    if parts[1] ~= CLASS_DIR then return nil end
    if #parts == 1 then return "class" end
    if parts[2] ~= DISPLAY_DIR then return nil end
    if #parts == 2 then return "display" end
    if #parts == 3 then return "dev", parts[3] end
    if #parts == 4 then return "attr", parts[3], parts[4] end
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

--- 属性是否属于该设备。
local function hasAttr(dev, attr)
    for _, a in ipairs(readAttrs(dev)) do if a == attr then return true end end
    return false
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
--- 属性内容是单行当前值(sysfs 语义): 读完一次即 EOF(nil)。否则按 readLine 循环到 nil
--- 的工具(cat/grep/sed/head)会无限重复打印同一个值。
local function openAttr(dev, attr)
    local pos = 0 -- 已读字节偏移
    local function content() return getAttr(dev, attr) or "" end
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
        read = function(_, n)
            local c = content()
            if pos >= #c then return nil end
            if type(n) ~= "number" then pos = #c; return c end
            local chunk = c:sub(pos + 1, pos + n)
            pos = pos + #chunk
            return chunk
        end,
        readLine = function()
            if pos >= #content() then return nil end
            pos = #content()
            return content()
        end,
        readAll = function()
            if pos >= #content() then return nil end
            pos = #content()
            return content()
        end,
        write    = function(self, s) return writeImpl(s) end,
        writeLine = function(self, s) return writeImpl(s .. "\n") end,
        close    = function() end,
        flush    = function() return true end,
    }
end

local backend = {
    kind = "virtual",
    list = function(rel)
        local kind, dev = parse(rel)
        if kind == "root" then return { CLASS_DIR } end
        if kind == "class" then return { DISPLAY_DIR } end
        if kind == "display" then
            local out = {}
            for _, id in ipairs(display.list()) do
                local d = display.get(id)
                if d and d.name then out[#out + 1] = d.name end
            end
            return out
        end
        if kind == "dev" then
            local d = display.byName(dev)
            if not d then return nil end
            return readAttrs(d)
        end
        return nil
    end,
    exists = function(rel)
        local kind, dev, attr = parse(rel)
        if kind == "root" or kind == "class" or kind == "display" then return true end
        if kind == nil then return false end
        local d = display.byName(dev)
        if not d then return false end
        if kind == "dev" then return true end
        return hasAttr(d, attr)
    end,
    isDir = function(rel)
        local kind = parse(rel)
        return kind == "root" or kind == "class" or kind == "display" or kind == "dev"
    end,
    attributes = function(rel)
        local kind, dev, attr = parse(rel)
        if kind == "root" then return { size = 0, isDir = true, isReadOnly = true, name = "sys" } end
        if kind == "class" then return { size = 0, isDir = true, isReadOnly = true, name = CLASS_DIR } end
        if kind == "display" then return { size = 0, isDir = true, isReadOnly = true, name = DISPLAY_DIR } end
        if kind == nil then return nil end
        local d = display.byName(dev)
        if not d then return nil end
        if kind == "dev" then return { size = 0, isDir = true, isReadOnly = true, name = dev } end
        if not hasAttr(d, attr) then return nil end
        return { size = 0, isDir = false, isReadOnly = not isWritable(d, attr), name = attr }
    end,
    getSize = function() return 0 end,
    getDrive = function() return "sys" end,
    getFreeSpace = function() return 0 end,
    getCapacity = function() return 0 end,
    isReadOnly = function(rel)
        local kind, dev, attr = parse(rel)
        if kind ~= "attr" then return true end
        local d = display.byName(dev)
        if not d then return true end
        return not isWritable(d, attr)
    end,
    open = function(rel, mode)
        local kind, dev, attr = parse(rel)
        if kind ~= "attr" then
            if kind then return nil, "is a directory" end
            return nil, "no such path: /sys/" .. norm(rel)
        end
        local d = display.byName(dev)
        if not d then return nil, "no such display: " .. dev end
        if not hasAttr(d, attr) then return nil, "no such attribute: " .. attr end
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

--- 挂载 sysfs 到 /sys。
function sysfs.mount()
    vfs.mount("/sys", backend, { device = "sysfs", fstype = "sysfs" })
    return true
end

return sysfs
