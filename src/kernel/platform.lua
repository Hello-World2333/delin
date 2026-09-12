--[[ Delin 平台层: "这台电脑是什么平台"与"外设挂在哪"的唯一真源。
     CC:Tweaked 电脑的外设挂在六个侧面上(peripheral.getNames/getType/wrap);
     CEE:CC(CEECC) 的电脑在侧面之外还有 1..cee.getSignalCount() 个信号引脚,
     引脚上的端口(I/O 面)可以挂外设, 也可以按 0..15 驱动/读取红石量(见 modules/cee.ko)。

     判据只有一条: 全局 `cee` 表存在且带 getSignalCount —— 机架式与台式都成立。
     两者的差别(机架总线 busInfo / fabric / Data Hub)不在本层: 机架式自带存储 4096 字节,
     装不下 Delin 的内核(208KB)与模块, 本层不为它做任何分支。

     内核态直接持有 cee 表。它**不进进程环境**(kernel/procenv.lua 的白名单里没有 cee):
     用户态一律经 /sys/class/{power,pin} 或 /dev/sdX 访问, 与其它外设一个路子。

     实测(台式 CEECC, 电脑 #6): 9 个引脚; 引脚的端口外设同时出现在 CC 侧面平面上
     (pin8 的 modem 就是侧面的 back, 在一边 open 的信道在另一边 isOpen 为真),
     所以设备枚举仍以侧面平面为准, 本层只给存储一层补漏(见 devdisk 的引脚驱动器来源)。 ]]

local platform = {}

platform.kind = nil -- "cc" | "cee"; nil = 还没探测
platform.cee = nil  -- CEE:CC 的全局 cee 表

--- 探测平台(幂等)。boot 最早调用一次; modules/cee.ko 自己也调一次,
--- 好让模块单独装载时拿到的是当前平台而不是"没人探测过"。
---@return string "cc" | "cee"
function platform.detect()
    local api = cee -- CC 上没有这个名字(nil); CEE:CC 上是模组注入的全局表
    if type(api) == "table" and type(api.getSignalCount) == "function" then
        platform.kind, platform.cee = "cee", api
    else
        platform.kind, platform.cee = "cc", nil
    end
    return platform.kind
end

--- 引脚快照(按引脚号升序)。非 CEECC 返回空表。
---@return table[] { pin=number, data=boolean, ports=number, powered=boolean, has=boolean, type=string|nil }
function platform.pins()
    local api = platform.cee
    if not api then return {} end
    local out = {}
    for pin = 1, api.getSignalCount() do
        out[#out + 1] = {
            pin = pin,
            data = api.isDataPin(pin) and true or false,
            ports = api.getPortCount(pin),
            powered = api.isPortPowered(pin) and true or false,
            has = api.hasPeripheral(pin) and true or false,
            type = api.getPeripheralType(pin),
        }
    end
    return out
end

--- 引脚上的磁盘驱动器。只有存储要在这里补: 侧面平面看不到的引脚外设里,
--- 打印机/显示器/时钟少一个还有别的来源, 存储少一个就是这台机器少一块盘。
---@return table[] { pin=number, name=string, handle=table }
function platform.pinDrives()
    local api = platform.cee
    if not api then return {} end
    local out = {}
    for pin = 1, api.getSignalCount() do
        if api.getPeripheralType(pin) == "drive" then
            local h = api.getPeripheral(pin)
            if h then out[#out + 1] = { pin = pin, name = "pin" .. pin, handle = h } end
        end
    end
    return out
end

return platform
