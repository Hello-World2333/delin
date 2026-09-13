-- Delin 真机自检: tty **原始模式**(kernel/tty.lua 的 setRaw/read 与按键字节映射)。
-- 由 rawtty-verify.service(oneshot)运行, 结果写 /tmp/rawtty.hex + /var/log/rawtty_verify.log。
--
-- 为什么要分成"脚本 + 内核模块"两半: 键盘事件只有内核态(tty.feedInput)能注入
-- (见 scripts/rawtty_test.ko 的头注释与 scripts/intr_test.ko 的实测), 而原始模式是**进程侧**
-- 的行为(句柄的 setRaw/read)。两边用 /tmp 下的标志文件握手:
--   rawtty_verify.lua 开 /dev/tty0 -> setRaw(true) -> 写 /tmp/rawtty.ready
--   rawtty_test.ko    看到 ready -> 喂按键(char/方向键/enter/Ctrl-D) -> 等 done
--   rawtty_verify.lua 读满 8 个字节 -> 写 /tmp/rawtty.hex -> setRaw(false) -> 写 /tmp/rawtty.done
-- 期望的字节: 78 20 1b 5b 41 37 0a 04
--   x | 空格 | ↑(CSI A) | 7 | enter(只有一次, 见去重闩锁) | ^D(原始模式下是普通字节)
-- 也就是说: `setRaw` 之后 read(n) 拿到的就是**终端字节流**, 特殊键是 ANSI 序列 ——
-- 与 Linux 上 raw 终端 + read(2) 的契约一致(分页器 more/less 就建立在这条契约上)。
--
-- 只用 /bin/lua 的白名单接口(fs/io/syscalls), 逐行 flush 落盘, 卡在哪一步看得见。
-- ASCII only(这个文件会装到 CC 电脑上)。

local LOG = "/var/log/rawtty_verify.log"
local OUT = "/tmp/rawtty.hex"
local READY = "/tmp/rawtty.ready"
local DONE = "/tmp/rawtty.done"
local WANT = 8
local EXPECT_HEX = "78201b5b41370a04"

local function openLog()
    local f = fs.open(LOG, "w")
    return f
end

local logf = openLog()
local function log(s)
    if logf then
        logf:write(s .. "\n")
        logf:flush()
    end
end

log("== rawtty verify ==")
-- 清掉上一轮(镜像会被反复使用, 残留会让握手立刻成立 —— 见 intr_test.ko 的同类注释)
for _, p in ipairs({ READY, DONE, OUT }) do
    if fs.exists(p) then fs.delete(p) end
end

local ttyh, err = fs.open("/dev/tty0", "r")
if not ttyh then
    log("FATAL: cannot open /dev/tty0 (" .. tostring(err) .. ")")
    return 1
end

if not ttyh.setRaw or not ttyh.isRaw then
    log("FATAL: /dev/tty0 handle has no setRaw (kernel tty raw mode missing)")
    return 1
end

ttyh:setRaw(true)
log("raw mode on (isRaw=" .. tostring(ttyh:isRaw()) .. ")")
local rf = fs.open(READY, "w")
rf:write("1\n")
rf:close()

local bytes = {}
local deadline = os.epoch("utc") + 30000
while #bytes < WANT and os.epoch("utc") < deadline do
    local b = ttyh:read(1)
    if b and b ~= "" then
        for k = 1, #b do bytes[#bytes + 1] = string.byte(b, k) end
        log("read #" .. #bytes)
    else
        os.sleep(0.05)
    end
end

ttyh:setRaw(false)
log("raw mode off (isRaw=" .. tostring(ttyh:isRaw()) .. ")")

local hex = {}
for _, b in ipairs(bytes) do
    hex[#hex + 1] = string.format("%02x", b)
end
local got = table.concat(hex)
log("got=" .. got .. " (want " .. EXPECT_HEX .. "), bytes=" .. #bytes)

local of = fs.open(OUT, "w")
of:write(got .. "\n")
of:close()
local df = fs.open(DONE, "w")
df:write("1\n")
df:close()

if got == EXPECT_HEX then
    log("RESULT ok")
    if logf then logf:close() end
    return 0
end
log("RESULT ng")
if logf then logf:close() end
return 1
