-- Delin 用户/权限测试(EXT2 根引导时跑)。 不交互, 用程序验证。
print("ext2-init: pid=" .. pid .. " uid=" .. uid .. " gid=" .. gid)

-- 准备测试文件权限(以 root, uid 0)
fs.chmod("/secret", 0x8180)     -- reg 0600 root-only
fs.chmod("/readonly", 0x8124)   -- reg 0444
fs.chmod("/pub", 0x81A4)        -- reg 0644
fs.chmod("/home", 0x41ED)       -- dir 0755
fs.chmod("/home/alice", 0x41C0) -- dir 0700 alice
fs.chown("/home/alice", 1000, 1000)
local w1 = fs.open("/secret", "w"); w1.write("top secret content"); w1.close()
local w2 = fs.open("/pub", "w"); w2.write("public data"); w2.close()

-- 用户库(syscall)
print("ext2-init: user.verify present=" .. tostring(type(syscalls and syscalls["user.verify"])))
print("ext2-init: verify alice ok=" .. tostring(syscalls["user.verify"]("alice", "p@ss")))
print("ext2-init: verify alice wrong=" .. tostring(syscalls["user.verify"]("alice", "bad")))
print("ext2-init: users=" .. table.concat(syscalls["user.list"](), ","))

-- root 绕过: root(uid0) 读 /secret
local rs = fs.open("/secret", "r")
print("ext2-init: root read /secret=[" .. (rs and rs.readAll() or "(none)") .. "]")
if rs then rs.close() end

-- spawn 一个 alice(uid 1000, gid 1000)进程测权限
local asrc = [[
print("alice: pid=" .. pid .. " uid=" .. uid .. " gid=" .. gid)
local function try(l, ok) print("alice: " .. l .. " => " .. tostring(ok)) end
-- 读 world-readable 0644 -> ok
local f = fs.open("/pub", "r")
try("read /pub (0644) ok", f ~= nil)
if f then f.close() end
-- 读 root-only 0600 -> 拒绝
local f2 = fs.open("/secret", "r")
try("read /secret (0600) denied", f2 == nil)
if f2 then f2.close() end
-- 写 0444 -> 拒绝
local okw = pcall(function() local w = fs.open("/readonly", "w"); w.write("x"); w.close() end)
try("write /readonly (0444) denied", okw == false)
-- 执行权限: 有读无 x 不可启动, 有 x(0755)才可启动
try("canExecute /pub (0644) false", fs.canExecute("/pub") == false)
try("canExecute /bin/ls (0755) true", fs.canExecute("/bin/ls") == true)
-- list alice-owned 0700 -> ok
print("alice: list /home/alice => [" .. table.concat((fs.list("/home/alice") or {}), ",") .. "]")
-- 在 /home/alice 里写文件(属主, 0700) -> ok
local okw, errw = pcall(function() local w = fs.open("/home/alice/x.txt", "w"); w.write("alice file"); w.close() end)
print("alice: write /home/alice/x.txt ok=" .. tostring(okw) .. (okw and "" or (" err=" .. tostring(errw))))
if okw then
    print("alice: exists=" .. tostring(fs.exists("/home/alice/x.txt")))
    local rf = fs.open("/home/alice/x.txt", "r")
    print("alice: read x.txt=[" .. (rf and rf.readAll() or "(none)") .. "]")
    if rf then rf.close() end
end
sleep(0.4)
print("alice: done")
]]
spawn(asrc, "alice", 1000, 1000)

sleep(0.2)

-- 显示设备抽象: /dev/ttyN(全类型) + /dev/fbN(pixel 型)。遵循 Linux, 进程面向设备文件。
print("ext2-init: tty=" .. table.concat((syscalls and syscalls["tty.list"] and syscalls["tty.list"]()) or {}, ",")
    .. " fb=" .. table.concat((syscalls and syscalls["fb.list"] and syscalls["fb.list"]()) or {}, ","))
local okDisp, dispErr = pcall(function()
    local tname = (syscalls and syscalls["tty.list"] and syscalls["tty.list"]()) or {}
    tname = tname[1]
    if tname then
        local t = fs.open("/dev/" .. tname, "w")
        if t then
            local w, h = t:getSize()
            print("ext2-init: /dev/" .. tname .. " size=" .. tostring(w) .. "x" .. tostring(h))
            t:clear(0x0)
            t:write("Delin OS display driver test")
            t:write("\n")
            t:writeLine("pid " .. pid .. " via " .. tname)
            t:flush()
            t:close()
            print("ext2-init: wrote to /dev/" .. tname)
        else
            print("ext2-init: open /dev/" .. tname .. " failed")
        end
    end
    local fbs = (syscalls and syscalls["fb.list"] and syscalls["fb.list"]()) or {}
    local fname = fbs[1]
    if fname then
        local fb = fs.open("/dev/" .. fname, "w")
        if fb then
            local w, h = fb:getSize()
            print("ext2-init: /dev/" .. fname .. " " .. tostring(w) .. "x" .. tostring(h) .. " bpp=" .. tostring(fb:getBpp()))
            fb:clear(0x000000)
            fb:setPixel(0, 0, 0xFF0000)
            fb:setPixel(1, 0, 0x00FF00)
            fb:setPixel(2, 0, 0x0000FF)
            fb:flush()
            fb:close()
            print("ext2-init: drew pixels to /dev/" .. fname)
        else
            print("ext2-init: open /dev/" .. fname .. " failed")
        end
    end
end)
print("ext2-init: display test ok=" .. tostring(okDisp) .. (okDisp and "" or (" err=" .. tostring(dispErr))))

-- /sys/class/display 配置文件接口(分辨率/位置等)。读=查当前值, 写=设值。
local okCfg, cfgErr = pcall(function()
    local function rd(p)
        local f = fs.open(p, "r"); if not f then return "(none)" end
        local s = f:readAll(); f:close(); return s
    end
    local function wrsys(p, v)
        local f = fs.open(p, "w"); if not f then return "openerr" end
        local ok, err = f:write(v); f:close(); return ok
    end
    local dlist = fs.list("/sys/class/display") or {}
    print("ext2-init: /sys/class/display=[" .. table.concat(dlist, ",") .. "]")
    for _, name in ipairs(dlist) do
        local attrs = fs.list("/sys/class/display/" .. name) or {}
        print("ext2-init: /sys/class/display/" .. name .. " attrs=[" .. table.concat(attrs, ",") .. "]")
    end
    print("ext2-init: right/resolution=" .. rd("/sys/class/display/right/resolution"))
    print("ext2-init: back/offset=" .. rd("/sys/class/display/back/offset"))
    print("ext2-init: back/scale=" .. rd("/sys/class/display/back/scale"))

    -- Void 位置: 写 offset(投影变换, 不改变尺寸)
    local woff = wrsys("/sys/class/display/back/offset", "5 6 7")
    print("ext2-init: write back/offset='5 6 7' => " .. tostring(woff) .. " read-back=" .. rd("/sys/class/display/back/offset"))

    -- Tom 分辨率: 写 32 -> 热重算 tty/fb 尺寸(getSize 变化)
    local before = fs.open("/dev/tty1", "w")
    local bsz = before and ({ before:getSize() }) or nil
    if before then before:close() end
    local wres = wrsys("/sys/class/display/right/resolution", "32")
    print("ext2-init: write right/resolution='32' => " .. tostring(wres))
    local after = fs.open("/dev/tty1", "w")
    local asz = after and ({ after:getSize() }) or nil
    if after then after:close() end
    print("ext2-init: tty1 size before=" .. (bsz and (bsz[1] .. "x" .. bsz[2]) or "?")
        .. " after=" .. (asz and (asz[1] .. "x" .. asz[2]) or "?")
        .. " (resolution hot-resize)")
    -- 恢复分辨率 64
    print("ext2-init: restore resolution=64 => " .. tostring(wrsys("/sys/class/display/right/resolution", "64")))
end)
print("ext2-init: sysfs config test ok=" .. tostring(okCfg) .. (okCfg and "" or (" err=" .. tostring(cfgErr))))

sleep(0.6)
print("ext2-init: done pid=" .. pid)

-- ═══════════ shell + tty 键盘输入 ═══════════
local console = syscalls["tty.console"]()
print("ext2-init: console tty=" .. tostring(console))

-- 1) tty 键盘输入: 模拟按键 -> canonical 行规程(回显+缓冲) -> readLine。
--    结果经 print 记录到 /delin.log(电脑自身 fs); 不写 ext2 根(避免触发 ext2 写 bug)。
local ttytest
do
    local t = fs.open("/dev/" .. console, "rw")
    if not t then
        ttytest = "no-open /dev/" .. tostring(console)
    else
        for _, ch in ipairs({ "h", "i" }) do os.queueEvent("char", ch) end
        os.queueEvent("key", keys.enter, false)
        sleep(0.05) -- 让调度器处理已入队事件(喂给前台 tty)
        local line = t:readLine()
        ttytest = "got=[" .. tostring(line) .. "]"
    end
end
print("ext2-init: tty keyboard test => " .. ttytest)

-- 2) shell 脚本模式: 内存命令行(stdin) -> 内存输出缓冲(stdout)。
--    验证内建(cd/pwd/echo/exit) + 只读外部工具(ls/cat) + spawn/argv/wait。
--    用内存 stdio, 不写 ext2 根; 结果经 print 记录到 /delin.log。
local shHand = fs.open("/bin/sh", "r")
local shSrc = shHand and shHand.readAll() or nil
if shHand then shHand.close() end
if not shSrc then
    print("ext2-init: /bin/sh not found")
else
    -- 清理上次残留的测试文件(在内存 stdio 里跑, 避免残留影响)。
    for _, d in ipairs({ "/tfile.txt", "/tmoved.txt", "/tcopy.txt", "/tpasswd.txt", "/dbg_src.txt" }) do
        if fs.exists(d) then pcall(fs.delete, d) end
    end

    -- 已知内容的源文件(避开 /etc/passwd 的 inode 状态, 便于逐字节比对)。
    local dbgSrc = fs.open("/dbg_src.txt", "w")
    if not dbgSrc then
        print("ext2-init: cannot create /dbg_src.txt")
    else
        dbgSrc.write("AAA\nBBB\nCCC\n"); dbgSrc.close()
    end

    local lines = {
        "pwd", "echo HELLO_SHELL", "ls /", "cat /etc/passwd",
        -- 扩展 POSIX 工具 (根级文件操作, 最小化 fs 变动)
        "touch /tfile.txt",
        "wc -c /tfile.txt",
        "cat /tfile.txt",
        "cp /dbg_src.txt /tcopy.txt",
        "wc -c /tcopy.txt",
        "cat /tcopy.txt",
        "cp /etc/passwd /tpasswd.txt",
        "wc -c /tpasswd.txt",
        "cat /tpasswd.txt",
        "wc -l /etc/passwd",
        "wc -w /etc/passwd",
        "head -n 2 /etc/passwd",
        "tail -n 2 /etc/passwd",
        "grep root /etc/passwd",
        "mv /tfile.txt /tmoved.txt",
        "wc -c /tmoved.txt",
        "cat /tmoved.txt",
        "rm /tcopy.txt",
        "rm /tpasswd.txt",
        "exit",
    }
    local li = 0
    local inH = { readLine = function(self) li = li + 1; return lines[li] end }
    local outbuf = {}
    local outH = {
        write = function(self, s) outbuf[#outbuf + 1] = tostring(s); return #s end,
        writeLine = function(self, s) outbuf[#outbuf + 1] = tostring(s) .. "\n"; return #s + 1 end,
    }
    syscalls["stdio.set"](inH, outH)
    local spid = spawn(shSrc, "sh", nil, nil, { [0] = "/bin/sh" })
    print("ext2-init: shell spawn pid=" .. tostring(spid))
    local code
    local tries = 0
    while tries < 30 do
        local p = syscalls["proc.info"](spid)
        if not p then code = -1; break end
        if p.status == "dead" or p.status == "error" then code = p.exitCode or 0; break end
        sleep(0.1); tries = tries + 1
    end
    if code == nil then code = "TIMEOUT" end
    print("ext2-init: shell exited code=" .. tostring(code))
    print("ext2-init: shell out=[" .. table.concat(outbuf, "|") .. "]")
    -- 清理测试文件(避免 ext2 根污染)。
    for _, d in ipairs({ "/dbg_src.txt", "/tfile.txt", "/tmoved.txt", "/tcopy.txt", "/tpasswd.txt" }) do
        if fs.exists(d) then pcall(fs.delete, d) end
    end
end

-- 3a) 非 root 用户 sh 的执行权限: 运行一个"可读但不可执行"的文件 -> 拒绝(不启动)。
--     通过 stdio 使 sh 以 alice(uid 1000)脚本模式跑; 输出经 print 记录到 /delin.log。
do
    local nx = fs.open("/home/alice/nonx", "w")
    if nx then nx.write("return 1"); nx.close() end
    local lines = { "/home/alice/nonx", "/bin/ls /bin", "echo AFTER" }
    local li = 0
    local inH = { readLine = function(self) li = li + 1; return lines[li] end }
    local outbuf = {}
    local outH = {
        write = function(self, s) outbuf[#outbuf + 1] = tostring(s); return #s end,
        writeLine = function(self, s) outbuf[#outbuf + 1] = tostring(s) .. "\n"; return #s + 1 end,
    }
    syscalls["stdio.set"](inH, outH)
    local spid = spawn(shSrc, "sh-alice", 1000, 1000, { [0] = "/bin/sh" })
    local tries = 0
    while spid and tries < 30 do
        local p = syscalls["proc.info"](spid)
        if not p then break end
        if p.status == "dead" or p.status == "error" then break end
        sleep(0.1); tries = tries + 1
    end
    local out = table.concat(outbuf)
    print("ext2-init: alice sh run nonx => [" .. out .. "]")
    print("ext2-init: alice sh refuses non-exec=" .. tostring(out:find("Permission denied", 1, true) ~= nil))
    print("ext2-init: alice sh runs executable=" .. tostring(out:find("cat", 1, true) ~= nil))
    if fs.exists("/home/alice/nonx") then pcall(fs.delete, "/home/alice/nonx") end
end

-- 3) 产品形态: 在每个 tty 上 spawn 一个 login 进程(登录到 sh)。init 保持存活。
--    login 各自绑定自己的 tty(per-process stdio), 经 Ctrl+Alt+数字切换前台焦点共用一把键盘。
local loginSrc
do
    local lf = fs.open("/bin/login", "r")
    if lf then loginSrc = lf.readAll(); lf.close() end
end
if loginSrc then
    for _, tn in ipairs((syscalls and syscalls["tty.list"] and syscalls["tty.list"]()) or {}) do
        local lpid = spawn(loginSrc, "login", 0, 0, { [0] = "/bin/login", tn })
        print("ext2-init: login on " .. tn .. " (pid " .. tostring(lpid) .. ")")
    end
else
    print("ext2-init: /bin/login not found")
end

-- init 永不退出; 否则 login 会变为孤儿。
while true do os.sleep(1) end
