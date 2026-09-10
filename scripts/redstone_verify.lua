-- 真机验证 redstone.ko: /sys/class/redstone/<side>/{digital,analog,bundled} 与 CC 原始 redstone API
-- 交叉核对。由 realmachine_verify.sh 调用(/root/redstone_verify.lua), 结果写 /var/log/redstone_verify.log;
-- 真值取自 CC 自己的 redstone API —— 断言文件接口读到的值与 API 逐项一致, 且经文件写入后 API 读回一致。
-- 宿主 harness 无法做这件事(桩 API 必然自洽), 故只在真机上跑。
-- 注意: 只写"输出"侧(本机自己拥有), 结束后复位为 0; 读侧只与 API 当前值比对, 不假设世界状态。

local LOG = "/var/log/redstone_verify.log"
local R = "/sys/class/redstone"
local ATTRS = { "digital", "analog", "bundled" }

local lines, fails = {}, 0
local function log(s) lines[#lines + 1] = s end
local function check(cond, label, extra)
    if cond then
        log("ok   " .. label)
    else
        fails = fails + 1
        log("FAIL " .. label .. (extra ~= nil and (" -- " .. tostring(extra)) or ""))
    end
end

local function readAttr(side, attr)
    local f, err = fs.open(R .. "/" .. side .. "/" .. attr, "r")
    if not f then return nil, tostring(err) end
    local v = f.readLine()
    f.close()
    return v
end

local function writeAttr(side, attr, value)
    local f, err = fs.open(R .. "/" .. side .. "/" .. attr, "w")
    if not f then return nil, tostring(err) end
    local ok, werr = f:write(tostring(value) .. "\n")
    f.close()
    if ok == nil and werr ~= nil then return nil, tostring(werr) end
    return true
end

local function eqAttr(side, attr, want, label)
    local got = readAttr(side, attr)
    check(got == tostring(want), label, "got=" .. tostring(got) .. " want=" .. tostring(want))
end

local function expectErr(label, ok, err, pattern)
    check(ok == nil and err ~= nil and tostring(err):find(pattern, 1, true) ~= nil, label,
          "ok=" .. tostring(ok) .. " err=" .. tostring(err))
end

log("=== redstone.ko verify (sysfs <-> CC redstone API) ===")

-- 1) 面清单: 文件接口的六个面必须与 API 的 getSides() 一致, 每面三个属性
local listed = {}
for _, name in ipairs(fs.list(R)) do listed[name] = true end
for _, side in ipairs(redstone.getSides()) do
    check(listed[side] == true, "side listed: " .. side)
    check(fs.isDir(R .. "/" .. side), "side is dir: " .. side)
    for _, attr in ipairs(ATTRS) do
        check(fs.isFile(R .. "/" .. side .. "/" .. attr), "attr exists: " .. side .. "/" .. attr)
    end
end
local count = 0
for _ in pairs(listed) do count = count + 1 end
check(count == #redstone.getSides(), "no extra side entries", "listed=" .. count)

-- 2) 读 = 输入: 每个面的三个属性都必须与 API 的 *Input 当前值逐项一致
for _, side in ipairs(redstone.getSides()) do
    eqAttr(side, "digital", redstone.getInput(side) and 1 or 0, "read digital == getInput: " .. side)
    eqAttr(side, "analog", redstone.getAnalogInput(side), "read analog == getAnalogInput: " .. side)
    eqAttr(side, "bundled", redstone.getBundledInput(side), "read bundled == getBundledInput: " .. side)
end

-- 3) 写 = 输出: 经文件设输出, API 必须看到(用 back 面, 结束时复位)
local S = "back"
check(writeAttr(S, "analog", 7) == true, "write analog 7")
check(redstone.getAnalogOutput(S) == 7, "api sees analog 7", redstone.getAnalogOutput(S))
check(redstone.getOutput(S) == true, "api sees output on after analog 7")

check(writeAttr(S, "digital", 1) == true, "write digital 1")
check(redstone.getAnalogOutput(S) == 15, "api analog 15 after digital 1", redstone.getAnalogOutput(S))
check(writeAttr(S, "digital", 0) == true, "write digital 0")
check(redstone.getAnalogOutput(S) == 0, "api analog 0 after digital 0", redstone.getAnalogOutput(S))

check(writeAttr(S, "analog", 15) == true, "write analog 15")
check(redstone.getAnalogOutput(S) == 15, "api sees analog 15", redstone.getAnalogOutput(S))

check(writeAttr(S, "bundled", 32768) == true, "write bundled 32768 (black)")
check(redstone.getBundledOutput(S) == 32768, "api sees bundled 32768", redstone.getBundledOutput(S))
check(writeAttr(S, "bundled", 3) == true, "write bundled 3 (white+orange)")
check(redstone.getBundledOutput(S) == 3, "api sees bundled 3", redstone.getBundledOutput(S))

-- 4) 读仍是输入: 写开输出后, 读到的值必须等于 API 的 *Input(不是 *Output)
local got = readAttr(S, "analog")
check(got == tostring(redstone.getAnalogInput(S)), "analog read stays input after write",
      "got=" .. tostring(got) .. " getAnalogInput=" .. tostring(redstone.getAnalogInput(S)))
got = readAttr(S, "bundled")
check(got == tostring(redstone.getBundledInput(S)), "bundled read stays input after write",
      "got=" .. tostring(got) .. " getBundledInput=" .. tostring(redstone.getBundledInput(S)))

-- 5) 非法写 fail-fast 且不改状态
check(writeAttr(S, "analog", 5) == true, "write analog 5 (baseline)")
local ok, err = writeAttr(S, "analog", 16)
expectErr("reject analog 16", ok, err, "invalid")
check(redstone.getAnalogOutput(S) == 5, "state kept after invalid analog", redstone.getAnalogOutput(S))
ok, err = writeAttr(S, "analog", "abc")
expectErr("reject analog abc", ok, err, "invalid")
ok, err = writeAttr(S, "analog", "0x10")
expectErr("reject analog 0x10", ok, err, "invalid")
ok, err = writeAttr(S, "digital", 2)
expectErr("reject digital 2", ok, err, "invalid")
ok, err = writeAttr(S, "bundled", 65536)
expectErr("reject bundled 65536", ok, err, "invalid")
ok, err = writeAttr(S, "output", 1)
expectErr("reject old attribute name output", ok, err, "no such")
ok, err = writeAttr("middle", "digital", 1)
expectErr("reject unknown side", ok, err, "no such")

-- 6) 复位输出
writeAttr(S, "digital", 0)
writeAttr(S, "bundled", 0)
check(redstone.getAnalogOutput(S) == 0 and redstone.getBundledOutput(S) == 0, "outputs reset")

log(fails == 0 and "=== redstone verify: all ok ===" or ("=== redstone verify: " .. fails .. " FAILED ==="))

local f = fs.open(LOG, "w")
if not f then
    io.write("redstone_verify: cannot write " .. LOG .. "\n")
    return 1
end
f:write(table.concat(lines, "\n") .. "\n")
f:close()
return fails == 0 and 0 or 1
