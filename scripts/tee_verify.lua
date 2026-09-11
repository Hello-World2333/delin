-- Delin 真机验证: tee 的 stdout 契约 —— stdout 是终端/管道句柄时必须真的把 stdin 写出去。
--
-- 历史 bug: tee 里写成 `out.write(chunk)`(点号)。内核的 tty/管道句柄是普通 Lua 表, 方法吃冒号
-- 且签名是 `write(self, s)` —— 点号调用把 chunk 传到了 self 上、s 是 nil, 于是**静默写空串**:
-- FILE(ext2 句柄点号也能用)照写, 屏幕上/下游管道里什么都没有。宿主测试台当时的 stdout 桩
-- 点号冒号都收, 所以这个 bug 只在真机上露头(现在 tools/harness.lua 与 tools/hosttest.lua 的
-- stdout 桩都照 tty 建了, 宿主上就能挡住)。
--
-- CC 没有屏幕读回 API, 所以"终端这一路"用**光标**观测: 写进 tty 的字节必须让光标前进。
-- 挑注册序号最大的 tty(tty0 是控制台, getty 会往上写), 它没人写 -> 光标位置完全可预期。
-- 由 scripts/posix_tools_verify.sh 用 `/bin/lua /root/tee_verify.lua` 调起, 结果打到 stdout。
local pass, fail = 0, 0
local function ok(cond, label, extra)
    if cond then pass = pass + 1; io.write("ok   " .. label .. "\n")
    else fail = fail + 1; io.write("FAIL " .. label .. (extra and ("  -- " .. tostring(extra)) or "") .. "\n") end
end
local function eq(got, want, label)
    ok(got == want, label, "got=" .. tostring(got) .. " want=" .. tostring(want))
end

local function writeFile(p, s)
    local f = assert(fs.open(p, "w"), p)
    f:write(s); f:close()
end
local function readFile(p)
    local f = fs.open(p, "r")
    if not f then return nil end
    local s = f:readAll(); f:close()
    return s
end

local BASE = "/var/tmp/tee-probe"
-- 先删目录里的东西再删目录: 内核的 fs.delete **不拦非空目录**(删了条目再失败/或直接把目录
-- inode 回收), 留下未连接 inode, 真机跑完 e2fsck 会报 "Unattached inode"(实测踩过)。
local function rmTree(p)
    -- 用 lstat: isDir/attributes 会跟着符号链接走, 而自检里故意造了成环的链接, 那样会直接
    -- 报 "too many levels of symbolic links" 把清理本身搞崩(实测踩过)。
    local a = fs.lstat(p)
    if a and a.isDir then
        for _, n in ipairs(fs.list(p) or {}) do rmTree(p .. "/" .. n) end
    end
    pcall(fs.delete, p)
end
rmTree(BASE)
assert(fs.makeDir(BASE), "cannot create " .. BASE)
local INPUT = "tee-probe\n"
writeFile(BASE .. "/in", INPUT)

-- ---------------------------------------------------------------
-- 1. tty 句柄的调用契约(根因控制组): 点号静默丢弃, 冒号才写进去
-- ---------------------------------------------------------------
local ttys = {}
for _, n in ipairs(fs.list("/dev")) do
    local i = n:match("^tty(%d+)$")
    if i then ttys[#ttys + 1] = { name = n, idx = tonumber(i) } end
end
table.sort(ttys, function(a, b) return a.idx < b.idx end)
local names = {}
for _, t in ipairs(ttys) do names[#names + 1] = t.name end
io.write("env: ttys = " .. table.concat(names, " ") .. "\n")
ok(#ttys > 0, "存在 /dev/ttyN", "fs.list('/dev') 里没有 tty")
if #ttys == 0 then
    io.write(string.format("\ntee-probe: %d passed, %d failed\n", pass, fail))
    return 1
end

local pick = ttys[#ttys] -- 最后注册的 tty: 不是控制台, 没有 getty/登录程序写它
local tty = fs.open("/dev/" .. pick.name, "w")
ok(tty ~= nil, "打开 /dev/" .. pick.name .. " 可写句柄")
if not tty then
    io.write(string.format("\ntee-probe: %d passed, %d failed\n", pass, fail))
    return 1
end
local cols, rows = tty:getSize()
local x0, y0 = tty:getCursor()
io.write(string.format("env: %s = %dx%d, 初始光标 (%d,%d)\n", pick.name, cols, rows, x0, y0))
-- 观测法成立的前提: 这一行放得下、下一行还在屏内(真机 51x19, 输入 10 字节)。断言都相对于
-- 起始光标 —— 万一落到控制台 tty0 上(那里有 getty 的提示符), 也不会因此误报。
ok(cols >= #INPUT and y0 + 1 < rows, pick.name .. " 有空间观测下一行",
   string.format("cols=%d rows=%d y0=%d", cols, rows, y0))

-- 点号调用(曾经的写法): 数据丢在 self 上 -> 光标一动不动
tty.write(INPUT)
local xd, yd = tty:getCursor()
eq(xd .. "," .. yd, x0 .. "," .. y0, "tty 句柄点号调用 write 静默丢弃(根因控制组)")

-- 冒号调用: 必须落屏并推进光标("tee-probe\n" 短于列宽 -> 落到下一行行首)
tty:write(INPUT)
local xc, yc = tty:getCursor()
eq(xc .. "," .. yc, "0," .. (y0 + 1), "tty 句柄冒号调用 write 写进去并推进光标(观测法有效)")

-- ---------------------------------------------------------------
-- 2. 端到端: /bin/tee 的 stdout 就是 tty 句柄
-- ---------------------------------------------------------------
local function runTee(outHandle, extraArgv)
    local inp = assert(fs.open(BASE .. "/in", "r"))
    local argv = {}
    if extraArgv then for _, a in ipairs(extraArgv) do argv[#argv + 1] = a end end
    argv[#argv + 1] = BASE .. "/out"
    local pid, perr = syscalls["proc.exec"]("/bin/tee", argv, { stdio = { input = inp, output = outHandle } })
    if not pid then return nil, perr end
    local code = syscalls["proc.wait"](pid)
    inp:close()
    return code
end

local xb, yb = tty:getCursor()
io.write(string.format("env: tee 起跑前光标 (%d,%d)\n", xb, yb))
local code = runTee(tty)
eq(code, 0, "tee( stdout=tty ): 退出码 0")
local xe, ye = tty:getCursor()
io.write(string.format("env: tee 结束后光标 (%d,%d)\n", xe, ye))
-- 输入正好一行: 光标回到下一行行首。老代码(点号调用)在这里一动不动。
eq(xe .. "," .. ye, "0," .. (yb + 1), "tee( stdout=tty ): stdin 到了终端上(光标前进)")
eq(readFile(BASE .. "/out"), INPUT, "tee( stdout=tty ): FILE 内容正确")

-- ---------------------------------------------------------------
-- 3. 端到端: /bin/tee 的 stdout 是管道写端
--    管道句柄也是 `write(_, s)`: 点号调用同样会把数据丢在 self 上(下游读到 0 字节)。
-- ---------------------------------------------------------------
do
    local rd, pw = syscalls["pipe.create"]()
    local inp = assert(fs.open(BASE .. "/in", "r"))
    local pid, perr = syscalls["proc.exec"]("/bin/tee", { BASE .. "/out2" }, { stdio = { input = inp, output = pw } })
    ok(pid ~= nil, "tee( stdout=pipe ): 能启动", tostring(perr))
    inp:close()
    -- 注意: 不能在这里 close 父进程手里的写端 —— 内核的管道端是**同一个句柄表**, close 会给
    -- 子进程也置上 closed(它写的时候直接拿到 "pipe closed"), 而不是 POSIX 的"各持一个 fd"。
    -- 子进程退出时内核 onExit 会关掉它的 stdio 管道端, 读端那时才 EOF(与 sh/ed 的用法一致)。
    local data = rd:readAll()
    local pcode = pid and syscalls["proc.wait"](pid) or nil
    eq(data, INPUT, "tee( stdout=pipe ): stdin 到了管道里")
    eq(pcode, 0, "tee( stdout=pipe ): 退出码 0")
    eq(readFile(BASE .. "/out2"), INPUT, "tee( stdout=pipe ): FILE 内容正确")
    rd:close(); pw:close()
end

-- -a 追加, 以及没有 FILE 操作数(stdin->stdout 直通)也各走一遍
-- (老代码这两路同样会把 stdout 写空)
do
    local pr, pw = syscalls["pipe.create"]()
    local inp = assert(fs.open(BASE .. "/in", "r"))
    local pid = syscalls["proc.exec"]("/bin/tee", { "-a", BASE .. "/out" }, { stdio = { input = inp, output = pw } })
    inp:close()
    local data = pr:readAll()
    syscalls["proc.wait"](pid)
    pr:close()
    eq(data, INPUT, "tee -a( stdout=pipe ): stdin 到了管道里")
    eq(readFile(BASE .. "/out"), INPUT .. INPUT, "tee -a: FILE 追加正确")
end
do
    local pr, pw = syscalls["pipe.create"]()
    local inp = assert(fs.open(BASE .. "/in", "r"))
    local pid = syscalls["proc.exec"]("/bin/tee", {}, { stdio = { input = inp, output = pw } })
    inp:close()
    local data = pr:readAll()
    eq(syscalls["proc.wait"](pid), 0, "tee( 无 FILE ): 退出码 0")
    pr:close()
    eq(data, INPUT, "tee( 无 FILE ): stdin 直通 stdout")
end

tty:close()
rmTree(BASE)
io.write(string.format("\ntee-probe: %d passed, %d failed\n", pass, fail))
return fail == 0 and 0 or 1
