-- 真机验证 redstone.ko: /sys/class/redstone/<side>/* 与 CC 原始 redstone API 交叉核对。
-- 由 realmachine_verify.sh 调用(/root/redstone_verify.lua), 结果写 /var/log/redstone_verify.log;
-- 真值取自 CC 自己的 redstone API —— 断言文件接口读到的值与 API 逐项一致, 且经文件写入后
-- API 读回一致。宿主 harness 无法做这件事(桩 API 必然自洽), 故只在真机上跑。
-- 注意: 只写"输出"属性(本机自己拥有), 结束后复位为 0; 输入属性只与 API 比对, 不假设世界状态。

local LOG = "/var/log/redstone_verify.log"
local R = "/sys/class/redstone"

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

-- 1) 面清单: 文件接口的六个面必须与 API 的 getSides() 一致
local listed = {}
for _, name in ipairs(fs.list(R)) do listed[name] = true end
for _, side in ipairs(redstone.getSides()) do
    check(listed[side] == true, "side listed: " .. side)
    check(fs.isDir(R .. "/" .. side), "side is dir: " .. side)
    for _, attr in ipairs({ "input", "output", "analog_input", "analog_output", "bundled_input", "bundled_output" }) do
        check(fs.isFile(R .. "/" .. side .. "/" .. attr), "attr exists: " .. side .. "/" .. attr)
    end
end
local count = 0
for _ in pairs(listed) do count = count + 1 end
check(count == #redstone.getSides(), "no extra side entries", "listed=" .. count)

-- 2) 读: 每个面的六个属性都必须与 API 当前值逐项一致
for _, side in ipairs(redstone.getSides()) do
    eqAttr(side, "input", redstone.getInput(side) and 1 or 0, "read input: " .. side)
    eqAttr(side, "output", redstone.getOutput(side) and 1 or 0, "read output: " .. side)
    eqAttr(side, "analog_input", redstone.getAnalogInput(side), "read analog_input: " .. side)
    eqAttr(side, "analog_output", redstone.getAnalogOutput(side), "read analog_output: " .. side)
    eqAttr(side, "bundled_input", redstone.getBundledInput(side), "read bundled_input: " .. side)
    eqAttr(side, "bundled_output", redstone.getBundledOutput(side), "read bundled_output: " .. side)
end

-- 3) 写: 经文件设输出, API 与文件读回都必须变(用 back 面, 结束时复位)
local S = "back"
check(writeAttr(S, "analog_output", 7) == true, "write analog_output 7")
check(redstone.getAnalogOutput(S) == 7, "api sees analog 7", redstone.getAnalogOutput(S))
check(redstone.getOutput(S) == true, "api sees output on after analog 7")
eqAttr(S, "analog_output", 7, "read back analog 7")

check(writeAttr(S, "output", 1) == true, "write output 1")
check(redstone.getAnalogOutput(S) == 15, "api analog 15 after output 1", redstone.getAnalogOutput(S))
eqAttr(S, "output", 1, "read back output 1")

check(writeAttr(S, "output", 0) == true, "write output 0")
check(redstone.getAnalogOutput(S) == 0, "api analog 0 after output 0", redstone.getAnalogOutput(S))

check(writeAttr(S, "analog_output", 15) == true, "write analog_output 15")
check(redstone.getAnalogOutput(S) == 15, "api sees analog 15", redstone.getAnalogOutput(S))

check(writeAttr(S, "bundled_output", 32768) == true, "write bundled_output 32768 (black)")
check(redstone.getBundledOutput(S) == 32768, "api sees bundled 32768", redstone.getBundledOutput(S))
eqAttr(S, "bundled_output", 32768, "read back bundled 32768")
check(writeAttr(S, "bundled_output", 3) == true, "write bundled_output 3 (white+orange)")
check(redstone.getBundledOutput(S) == 3, "api sees bundled 3", redstone.getBundledOutput(S))

-- 4) 非法写 fail-fast 且不改状态
check(writeAttr(S, "analog_output", 5) == true, "write analog_output 5 (baseline)")
local ok, err = writeAttr(S, "analog_output", 16)
expectErr("reject analog_output 16", ok, err, "invalid")
check(redstone.getAnalogOutput(S) == 5, "state kept after invalid analog", redstone.getAnalogOutput(S))
ok, err = writeAttr(S, "analog_output", "abc")
expectErr("reject analog_output abc", ok, err, "invalid")
ok, err = writeAttr(S, "analog_output", "0x10")
expectErr("reject analog_output 0x10", ok, err, "invalid")
ok, err = writeAttr(S, "output", 2)
expectErr("reject output 2", ok, err, "invalid")
ok, err = writeAttr(S, "bundled_output", 65536)
expectErr("reject bundled_output 65536", ok, err, "invalid")
ok, err = writeAttr(S, "input", 1)
expectErr("reject write to read-only input", ok, err, "read-only")
ok, err = writeAttr("middle", "output", 1)
expectErr("reject unknown side", ok, err, "no such")

-- 5) 复位输出
writeAttr(S, "output", 0)
writeAttr(S, "bundled_output", 0)
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
