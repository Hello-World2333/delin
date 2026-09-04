--[[ Delin 显示设备注册表.
     驱动模块(.ko)把外设包装成一个 ScreenDevice 并注册; 内核/应用经统一接口使用。
     统一坐标: 0-based 左上 (0,0)。 设备内部基准差异由驱动在注册时转换。 ]]

local display = {}

local devices = {} -- id -> ScreenDevice

---@class ScreenDevice
---@field id string
---@field type string   -- monitor|gpu|hologram
---@field name string   -- 外设名(如 "right")
---@field device table  -- 底层外设句柄
---@field getSize fun(): number, number  -- 逻辑宽度,高度(0-based)
---@field blit fun(x:number,y:number,text:string,fg:any,bg:any)  -- 写文本单元格
---@field setPixel fun(x:number,y:number,color:any)
---@field fill fun(color:any)
---@field rect fun(x:number,y:number,w:number,h:number,color:any)
---@field text fun(x:number,y:number,s:string,fg:any,bg:any)
---@field flush fun()
---@field release fun()

--- 注册显示设备。
---@param dev ScreenDevice
---@return string id
function display.register(dev)
    devices[dev.id] = dev
    return dev.id
end

function display.unregister(id)
    local dev = devices[id]
    if dev and dev.release then pcall(dev.release) end
    devices[id] = nil
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
