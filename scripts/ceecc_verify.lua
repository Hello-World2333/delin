-- 真机验证 CEECC(台式 CEE:CC 电脑): 平台探测 + /sys/class/power/supply + /sys/class/pin/pinN
-- + 红石与块设备回归。由 ceecc.service(oneshot)调用, 结果写 /var/log/ceecc.log;
-- 宿主机 tools/ceecc_realmachine.py 读回并逐项复核(它只认这里的 KEY=VALUE 与 ok/FAIL 行)。
--
-- 为什么用 Lua 而不是 sh: 这个自检要发上百条 `$(...)`(每一条都是一次 spawn + 管道读),
-- 真机上 sh 跑到 ~90 个子进程时会**整个挂住**(服务被 init 的 60s 超时 SIGKILL, 日志停在
-- 那一行)。单进程 Lua 只 spawn 一次, 见 for-ai.md 的踩坑记录。

local LOG    = "/var/log/ceecc.log"
local POWER  = "/sys/class/power"
local SUPPLY = POWER .. "/supply"
local PIN    = "/sys/class/pin"
local RED    = "/sys/class/redstone"

local POWER_ATTRS = { "present", "voltage", "current", "power", "max_power", "headroom", "state", "reset" }
local PIN_ATTRS   = { "data", "ports", "powered", "peripheral", "peripheral_type" }
local PORT_ATTRS  = { "analog_in", "analog_out", "digital_out" }

-- 日志边跑边落盘(每行 flush): 真机上服务被 init 的 60s 超时杀掉时, 光靠"跑完再写一次"
-- 会一个字都留不下 —— 第一次跑真机就是这么瞎掉的。
local out = fs.open(LOG, "w")
if not out then
    io.write("ceecc_verify: cannot write " .. LOG .. "\n")
    return 1
end
local lines, fails = {}, 0
local t0 = os.epoch("utc")
local function log(s)
    lines[#lines + 1] = s
    out:write(s .. "\n")
    out:flush()
end
--- 耗时打点: 服务被 init 的超时杀掉时, 这些 t=... 能区分"挂了"与"只是慢"
local function stage(s) log("stage: " .. s .. " t=" .. tostring(os.epoch("utc") - t0) .. "ms") end
local function check(cond, label, extra)
    if cond then
        log("ok   " .. label)
    else
        fails = fails + 1
        log("FAIL " .. label .. (extra ~= nil and ("  -- " .. tostring(extra)) or ""))
    end
end
local function eq(got, want, label)
    check(got == want, label, "got=" .. tostring(got) .. " want=" .. tostring(want))
end

local function readAttr(path)
    local f, err = fs.open(path, "r")
    if not f then return nil, tostring(err) end
    local v = f.readLine()
    f.close()
    return v
end

local function writeAttr(path, value)
    local f, err = fs.open(path, "w")
    if not f then return nil, tostring(err) end
    local ok, werr = f:write(tostring(value) .. "\n")
    f.close()
    if ok == nil and werr ~= nil then return nil, tostring(werr) end
    return true
end

local function isDigits(s) return type(s) == "string" and s:match("^%d+$") ~= nil end

--- 条目清单(排序, 便于与宿主机逐字比对)
local function sortedList(dir)
    local out = {}
    for _, name in ipairs(fs.list(dir) or {}) do out[#out + 1] = name end
    table.sort(out)
    return out
end

log("=== Delin CEECC verify ===")

-- 1) 平台: 引导日志第 3 行必须是 platform=cee(内核 kernel/platform.lua 的探测结果)
local delinLog = fs.open("/delin.log", "r")
if not delinLog then
    check(false, "读引导日志 /delin.log")
else
    local head = {}
    for _ = 1, 6 do
        local l = delinLog.readLine()
        if not l then break end
        head[#head + 1] = l
    end
    delinLog.close()
    local text = table.concat(head, " | ")
    log("boot_delin_log=" .. text)
    check(text:find("platform=cee", 1, true) ~= nil, "引导日志里有 platform=cee", text)
end

-- 2) /sys/class 里两个新类都在
local classes = sortedList("/sys/class")
local classSet = {}
for _, n in ipairs(classes) do classSet[n] = true end
check(classSet.power == true, "存在 /sys/class/power")
check(classSet.pin == true, "存在 /sys/class/pin")
log("sysfs_classes=" .. table.concat(classes, ","))

local powerEntries = sortedList(POWER)
log("sysfs_power_entries=" .. #powerEntries)
eq(#powerEntries, 1, "power 类只有 supply 一个条目")
eq(powerEntries[1], "supply", "power 条目名是 supply")

local pinEntries = sortedList(PIN)
log("sysfs_pin_entries=" .. #pinEntries)
check(#pinEntries >= 1, "pin 类按 getSignalCount 列出引脚")
for _, n in ipairs(pinEntries) do
    check(n:match("^pin%d+$") ~= nil, "引脚条目名是 pinN: " .. n)
end

-- 3) 电力: 八个属性都在, 数值来自 cee 的电力 API(真机实测 ~300V / 500W / state=ok)
local powerAttrs = sortedList(SUPPLY)
log("power_supply_attrs=" .. table.concat(powerAttrs, ",") .. ",")
eq(#powerAttrs, #POWER_ATTRS, "power/supply 有八个属性")
for _, a in ipairs(POWER_ATTRS) do
    local v, err = readAttr(SUPPLY .. "/" .. a)
    if a == "reset" then
        -- 只写属性: 读不到内容(空属性文件读一次即 EOF)
        check(v == nil, "reset 是只写属性(读不到内容)", "got=" .. tostring(v))
    else
        check(v ~= nil, "属性可读: " .. a, err)
    end
end
log("power_present=" .. tostring(readAttr(SUPPLY .. "/present")))
log("power_state=" .. tostring(readAttr(SUPPLY .. "/state")))
log("power_max_power=" .. tostring(readAttr(SUPPLY .. "/max_power")))
log("power_voltage=" .. tostring(readAttr(SUPPLY .. "/voltage")))
log("power_headroom=" .. tostring(readAttr(SUPPLY .. "/headroom")))
log("power_current=" .. tostring(readAttr(SUPPLY .. "/current")))
log("power_power=" .. tostring(readAttr(SUPPLY .. "/power")))

eq(readAttr(SUPPLY .. "/present"), "1", "present == hasPower == 1")
check(isDigits(readAttr(SUPPLY .. "/max_power")), "max_power 是十进制整数",
      readAttr(SUPPLY .. "/max_power"))
check(tonumber(readAttr(SUPPLY .. "/max_power") or "0") > 0, "max_power > 0")
check((readAttr(SUPPLY .. "/state") or "") ~= "", "state 非空")
check((readAttr(SUPPLY .. "/voltage") or "0") ~= "0", "voltage 非 0",
      readAttr(SUPPLY .. "/voltage"))

local resetOk = writeAttr(SUPPLY .. "/reset", 1)
log("power_reset_rc=" .. (resetOk and "0" or "1"))
check(resetOk == true, "写 reset=1 成功(只写属性)")

local vw, vwerr = writeAttr(SUPPLY .. "/voltage", 5)
log("power_voltage_write_rc=" .. (vw and "0" or "1"))
check(vw == nil and tostring(vwerr):find("read-only", 1, true) ~= nil,
      "写只读属性 voltage 被拒且报 read-only", vwerr)

-- 4) 引脚: 每个引脚都有五个只读属性
local portPin, portlessPin = nil, nil
for _, name in ipairs(pinEntries) do
    local dir = PIN .. "/" .. name
    local attrs = sortedList(dir)
    local attrSet = {}
    for _, a in ipairs(attrs) do attrSet[a] = true end
    for _, a in ipairs(PIN_ATTRS) do
        check(attrSet[a] == true, name .. " 有属性 " .. a)
    end
    for _, a in ipairs(PIN_ATTRS) do
        local v, err = readAttr(dir .. "/" .. a)
        -- peripheral_type 在空引脚上是空属性文件 -> readLine 返回 nil(与空文件同义)
        if a ~= "peripheral_type" then check(v ~= nil, name .. "." .. a .. " 可读", err) end
    end
    log(string.format("pin %s data=%s ports=%s powered=%s peripheral=%s type=%s attrs=%s,",
        name, tostring(readAttr(dir .. "/data")), tostring(readAttr(dir .. "/ports")),
        tostring(readAttr(dir .. "/powered")), tostring(readAttr(dir .. "/peripheral")),
        tostring(readAttr(dir .. "/peripheral_type")), table.concat(attrs, ",")))

    local ports = readAttr(dir .. "/ports")
    local hasPort = isDigits(ports) and tonumber(ports) > 0
    if hasPort then
        portPin = portPin or name
        for _, a in ipairs(PORT_ATTRS) do
            check(attrSet[a] == true, name .. "(有端口) 有属性 " .. a)
        end
    else
        portlessPin = portlessPin or name
        for _, a in ipairs(PORT_ATTRS) do
            -- 真机实测: 没有端口时 cee 的 getAnalogOutput/getOutput 直接报 "no signal port", 
            -- 所以这三个属性在无端口引脚上**不该存在**。
            check(attrSet[a] ~= true, name .. "(无端口) 没有属性 " .. a)
        end
        local f = fs.open(dir .. "/analog_in", "r")
        log("portless_analog_in_rc=" .. (f and "0" or "1"))
        check(f == nil, name .. "(无端口) 打开 analog_in 失败")
    end
end
log("port_pin=" .. (portPin and (PIN .. "/" .. portPin) or ""))
log("portless_pin=" .. (portlessPin and (PIN .. "/" .. portlessPin) or ""))

-- 5) 有端口的引脚: 端口属性读写 + 越界 fail-fast 且不改状态
if portPin then
    local dir = PIN .. "/" .. portPin
    log("port_pin_analog_in=" .. tostring(readAttr(dir .. "/analog_in")))
    log("port_pin_digital_out=" .. tostring(readAttr(dir .. "/digital_out")))
    log("port_pin_analog_out_before=" .. tostring(readAttr(dir .. "/analog_out")))

    local w = writeAttr(dir .. "/analog_out", 7)
    log("port_pin_write_rc=" .. (w and "0" or "1"))
    check(w == true, "写 analog_out=7 成功")
    log("port_pin_analog_out_after=" .. tostring(readAttr(dir .. "/analog_out")))
    eq(readAttr(dir .. "/analog_out"), "7", "analog_out 读回 7(落到 setAnalog)")

    local bad, badErr = writeAttr(dir .. "/analog_out", 16)
    log("port_pin_bad_write_rc=" .. (bad and "0" or "1"))
    check(bad == nil and tostring(badErr):find("0..15", 1, true) ~= nil, "写 analog_out=16 被拒", badErr)
    log("port_pin_analog_out_after_bad=" .. tostring(readAttr(dir .. "/analog_out")))
    eq(readAttr(dir .. "/analog_out"), "7", "越界写没有改动端口状态")

    local junk = writeAttr(dir .. "/analog_out", "0x3")
    check(junk == nil, "写 analog_out=0x3 被拒(只收十进制)")

    local don = writeAttr(dir .. "/digital_out", 1)
    check(don == true, "写 digital_out=1 成功")
    eq(readAttr(dir .. "/analog_out"), "15", "digital_out=1 等价 analog 15")
    writeAttr(dir .. "/digital_out", 0)
    eq(readAttr(dir .. "/analog_out"), "0", "digital_out=0 复位")

    stage("write analog_out=0")
    local rst = writeAttr(dir .. "/analog_out", 0)
    stage("wrote analog_out=0 ok=" .. tostring(rst))
    log("port_pin_analog_out_restored=" .. tostring(readAttr(dir .. "/analog_out")))
    eq(readAttr(dir .. "/analog_out"), "0", "端口已复位到 0")
end
stage("port block done")

-- 6) 越界引脚不存在
stage("before pin999")
local f999 = fs.open(PIN .. "/pin999/data", "r")
log("pin999_rc=" .. (f999 and "0" or "1"))
check(f999 == nil, "越界引脚 pin999 不存在")
if f999 then f999.close() end
check(fs.isDir(PIN .. "/pin999") ~= true, "越界引脚不是目录")

-- 7) 回归: 红石六个面 + 写入
stage("before redstone")
local sides = sortedList(RED)
log("redstone_sides=" .. table.concat(sides, ",") .. ",")
eq(#sides, 6, "红石仍是六个面")
local rw = writeAttr(RED .. "/back/analog", 9)
log("redstone_write_rc=" .. (rw and "0" or "1"))
check(rw == true, "红石写仍可用")
writeAttr(RED .. "/back/analog", 0)

-- 8) 回归: 块设备与挂载
stage("before block devices")
check(fs.exists("/dev/sda") == true, "电脑自带存储是 /dev/sda")
local sdCount = 0
for _, n in ipairs(fs.list("/dev") or {}) do
    if n:match("^sd%a+$") then sdCount = sdCount + 1 end
end
log("block_devices=" .. sdCount)
check(sdCount >= 1, "至少有一个 /dev/sdX 节点")
local mf = fs.open("/proc/mounts", "r")
if mf then
    local mounts = mf.readAll() or ""
    mf.close()
    log("mounts=" .. mounts:gsub("\n", " | "))
    check(mounts:find("/dev/sda", 1, true) ~= nil, "/proc/mounts 里根挂在 /dev/sda 上")
else
    check(false, "读 /proc/mounts")
end

log("fails=" .. fails)
log("=== ceecc verify done ===")

out:close()
return fails == 0 and 0 or 1
