--[[ Delin sysfs: 挂在 /sys 的虚拟配置文件系统。
     布局(对齐 Linux sysfs 的 class 子树):
       /sys/class/<class>/<条目>/<属性>
     class 由内核或模块注册(sysfs.registerClass; 模块经 kapi.registerSysfsClass):
       - display: 每个已注册显示设备一个条目(条目名 = 外设名), 属性 name/type/size
                  + 设备 listConfig() 声明的可读写项(如 tom 的 resolution, void 的 offset/rotation/scale)
       - printer: ccprinter 的每个打印设备一个条目(条目名 = 设备节点名, 如 lp0),
                  属性 name/type/size/paper/ink/title(title 可写)
     读 = 查当前值; 写 = 设值(仅 ops.writable 判定可写的属性)。若设置改变了设备尺寸(getSize 变化),
     由 class 的 set 自行调 display.resize 热重算派生 tty/fb。
     属性文件是单行值, 读一次即 EOF(sysfs 语义)。
     挂载点是 /sys 本身(与 /dev、/proc 同为挂载根), 所以 /sys、/sys/class 都是可 ls 的目录。 ]]

local vfs     = require("kernel.vfs")
local display = require("kernel.display")

local sysfs = {}

local CLASS_DIR = "class"

---@class SysfsClass
---@field list fun(): string[]                      条目名
---@field attrs fun(entry:string): string[]|nil     条目下的属性名
---@field get fun(entry:string, attr:string): string|nil
---@field writable fun(entry:string, attr:string): boolean|nil  可选; 缺省 = 有 set 即可写
---@field set fun(entry:string, attr:string, value:string): true|nil, string|nil  可选; 无则整个 class 只读

local classes = {} -- class 名 -> SysfsClass

--- 注册一个 sysfs class 子树 /sys/class/<name>。
---@param name string
---@param ops SysfsClass
function sysfs.registerClass(name, ops)
    classes[name] = ops
end

--- 注销一个 class(其子树立即消失)。
---@param name string
function sysfs.unregisterClass(name)
    classes[name] = nil
end

local function norm(rel) return (rel or ""):gsub("^/+", "") end

--- 解析 /sys 下的相对路径。
---@param rel string
---@return string|nil kind "root"|"class"|"classdir"|"entry"|"attr" (nil = 路径不存在)
---@return string|nil cls   class 名
---@return string|nil entry 条目名
---@return string|nil attr  属性名
local function parse(rel)
    rel = norm(rel)
    if rel == "" then return "root" end
    local parts = {}
    for p in rel:gmatch("[^/]+") do parts[#parts + 1] = p end
    if parts[1] ~= CLASS_DIR then return nil end
    if #parts == 1 then return "class" end
    if #parts == 2 then return "classdir", parts[2] end
    if #parts == 3 then return "entry", parts[2], parts[3] end
    if #parts == 4 then return "attr", parts[2], parts[3], parts[4] end
    return nil
end

local function entryExists(cls, entry)
    local ops = classes[cls]
    if not ops then return false end
    for _, e in ipairs(ops.list()) do
        if e == entry then return true end
    end
    return false
end

local function attrExists(cls, entry, attr)
    local ops = classes[cls]
    if not ops or not entryExists(cls, entry) then return false end
    local attrs = ops.attrs(entry)
    if not attrs then return false end
    for _, a in ipairs(attrs) do
        if a == attr then return true end
    end
    return false
end

--- 属性是否可写: class 提供了 set, 且(声明了 writable 时)该属性被声明为可写。
local function isWritable(cls, entry, attr)
    local ops = classes[cls]
    if not ops or not ops.set then return false end
    if not attrExists(cls, entry, attr) then return false end
    if ops.writable then return ops.writable(entry, attr) and true or false end
    return true
end

--- 打开属性文件句柄。
--- 属性内容是单行当前值(sysfs 语义): 读完一次即 EOF(nil)。否则按 readLine 循环到 nil
--- 的工具(cat/grep/sed/head)会无限重复打印同一个值。
local function openAttr(cls, entry, attr)
    local ops = classes[cls]
    local pos = 0 -- 已读字节偏移
    local function content() return ops.get(entry, attr) or "" end
    local function writeImpl(s)
        if not isWritable(cls, entry, attr) then return nil, "read-only attribute" end
        local v = s:gsub("[\r\n]+$", "")
        local ok, err = ops.set(entry, attr, v)
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
        local kind, cls, entry = parse(rel)
        if kind == "root" then return { CLASS_DIR } end
        if kind == "class" then
            local out = {}
            for n in pairs(classes) do out[#out + 1] = n end
            table.sort(out)
            return out
        end
        if kind == "classdir" then
            local ops = classes[cls]
            if not ops then return nil end
            return ops.list()
        end
        if kind == "entry" then
            if not entryExists(cls, entry) then return nil end
            return classes[cls].attrs(entry)
        end
        return nil
    end,
    exists = function(rel)
        local kind, cls, entry, attr = parse(rel)
        if kind == "root" or kind == "class" then return true end
        if kind == "classdir" then return classes[cls] ~= nil end
        if kind == "entry" then return entryExists(cls, entry) end
        if kind == "attr" then return attrExists(cls, entry, attr) end
        return false
    end,
    isDir = function(rel)
        local kind = parse(rel)
        return kind == "root" or kind == "class" or kind == "classdir" or kind == "entry"
    end,
    attributes = function(rel)
        local kind, cls, entry, attr = parse(rel)
        if kind == "root" then return { size = 0, isDir = true, isReadOnly = true, name = "sys" } end
        if kind == "class" then return { size = 0, isDir = true, isReadOnly = true, name = CLASS_DIR } end
        if kind == "classdir" then
            if not classes[cls] then return nil end
            return { size = 0, isDir = true, isReadOnly = true, name = cls }
        end
        if kind == nil then return nil end
        if kind == "entry" then
            if not entryExists(cls, entry) then return nil end
            return { size = 0, isDir = true, isReadOnly = true, name = entry }
        end
        if not attrExists(cls, entry, attr) then return nil end
        return { size = 0, isDir = false, isReadOnly = not isWritable(cls, entry, attr), name = attr }
    end,
    getSize = function() return 0 end,
    getDrive = function() return "sys" end,
    getFreeSpace = function() return 0 end,
    getCapacity = function() return 0 end,
    isReadOnly = function(rel)
        local kind, cls, entry, attr = parse(rel)
        if kind ~= "attr" then return true end
        return not isWritable(cls, entry, attr)
    end,
    open = function(rel, mode)
        local kind, cls, entry, attr = parse(rel)
        if kind ~= "attr" then
            if kind then return nil, "is a directory" end
            return nil, "no such path: /sys/" .. norm(rel)
        end
        if not attrExists(cls, entry, attr) then
            return nil, "no such attribute: " .. cls .. "/" .. tostring(entry) .. "/" .. tostring(attr)
        end
        if mode and mode:find("w") and not isWritable(cls, entry, attr) then
            return nil, "read-only attribute: " .. attr
        end
        return openAttr(cls, entry, attr)
    end,
    makeDir = function() error("read-only fs", 2) end,
    move    = function() error("read-only fs", 2) end,
    copy    = function() error("read-only fs", 2) end,
    delete  = function() error("read-only fs", 2) end,
}

-- ---------------------------------------------------------------
-- display class: 每个已注册显示设备一个条目(条目名 = 外设名)
-- ---------------------------------------------------------------
local function displayAttrs(entry)
    local d = display.byName(entry)
    if not d then return nil end
    local out = { "name", "type", "size" }
    if d.listConfig then
        for _, a in ipairs(d.listConfig()) do out[#out + 1] = a end
    end
    return out
end

local function displayWritable(entry, attr)
    if attr == "name" or attr == "type" or attr == "size" then return false end
    local d = display.byName(entry)
    if not (d and d.listConfig and d.setConfig) then return false end
    for _, a in ipairs(d.listConfig()) do
        if a == attr then return true end
    end
    return false
end

sysfs.registerClass("display", {
    list = function()
        local out = {}
        for _, id in ipairs(display.list()) do
            local d = display.get(id)
            if d and d.name then out[#out + 1] = d.name end
        end
        return out
    end,
    attrs = displayAttrs,
    writable = displayWritable,
    get = function(entry, attr)
        local d = display.byName(entry)
        if not d then return nil end
        if attr == "name" then return d.name or d.id end
        if attr == "type" then return tostring(d.type or "") end
        if attr == "size" then
            local w, h = d.getSize()
            return tostring(w) .. "x" .. tostring(h)
        end
        if d.getConfig then return d.getConfig(attr) end
        return nil
    end,
    set = function(entry, attr, value)
        local d = display.byName(entry)
        if not d then return nil, "no such display: " .. entry end
        local bw, bh = d.getSize()
        local ok, err = d.setConfig(attr, value)
        if ok then
            local nw, nh = d.getSize()
            if bw ~= nw or bh ~= nh then display.resize(d.id) end
            return true
        end
        return nil, err
    end,
})

--- 挂载 sysfs 到 /sys。
function sysfs.mount()
    vfs.mount("/sys", backend, { device = "sysfs", fstype = "sysfs" })
    return true
end

return sysfs
