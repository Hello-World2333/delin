--[[ Delin 显示设备注册表.
     驱动模块(.ko)把外设包装成一个 ScreenDevice 并注册; 内核/应用经统一接口使用。
     统一坐标: 0-based 左上 (0,0)。 设备内部基准差异由驱动在注册时转换。
     注册时同时派生标准字符设备: /dev/ttyN(文本终端, 全类型), /dev/fbN(像素帧缓冲,
     仅 pixel 型 Tom/Void)。文件级接口遵循 Linux: /dev/ttyN = 控制台, /dev/fbN = 帧缓冲。 ]]

local vfs_api = require("kernel.vfs_api")
local tty     = require("kernel.tty")
local fb      = require("kernel.fb")

local display = {}

local devices = {} -- id -> ScreenDevice
local nodeMap = {} -- id -> { tty=name, fb=name }

---@class ScreenDevice
---@field id string
---@field type string   -- monitor|gpu|hologram
---@field mode string   -- "term"(原生字符终端) | "pixel"(像素帧缓冲)
---@field name string   -- 外设名(如 "right")
---@field device table  -- 底层外设句柄
---@field cellW number|nil  -- pixel 型字格宽(物理像素)
---@field cellH number|nil  -- pixel 型字格高(物理像素)
---@field getSize fun(): number, number  -- 逻辑宽度,高度(0-based; term=单元格, pixel=像素)
---@field blit fun(x:number,y:number,text:string,fg:any,bg:any)  -- 写文本单元格
---@field setPixel fun(x:number,y:number,color:any)
---@field fill fun(color:any)
---@field rect fun(x:number,y:number,w:number,h:number,color:any)
---@field text fun(x:number,y:number,s:string,fg:any,bg:any)
---@field flush fun()
---@field release fun()

--- 注册显示设备, 并派生 /dev/ttyN 与(若 pixel 型)/dev/fbN。
---@param dev ScreenDevice
---@return string id
function display.register(dev)
    devices[dev.id] = dev
    local nodes = {}
    -- 每个设备都有文本终端
    local ttyName, ttyHandler = tty.registerDevice(dev)
    vfs_api.registerDevice(ttyName, ttyHandler)
    nodes.tty = ttyName
    -- pixel 型(Tom/Void)才有帧缓冲
    if dev.mode ~= "term" and dev.setPixel then
        local fbName, fbHandler = fb.registerDevice(dev)
        vfs_api.registerDevice(fbName, fbHandler)
        nodes.fb = fbName
    end
    nodeMap[dev.id] = nodes
    return dev.id
end

function display.unregister(id)
    local dev = devices[id]
    if dev and dev.release then pcall(dev.release) end
    devices[id] = nil
    local nodes = nodeMap[id]
    if nodes then
        if nodes.tty then vfs_api.unregisterDevice(nodes.tty) end
        if nodes.fb then vfs_api.unregisterDevice(nodes.fb) end
    end
    nodeMap[id] = nil
end

function display.get(id)
    return devices[id]
end

function display.list()
    local out = {}
    for id, dev in pairs(devices) do out[#out + 1] = id end
    return out
end

return display
