-- Delin 用户/权限测试(EXT2 根引导时跑)。 不交互, 用程序验证。
print("ext2-init: pid=" .. pid .. " uid=" .. uid .. " gid=" .. gid)

-- 准备测试文件权限(以 root, uid 0)
fs.chmod("/secret", 0x8180)     -- reg 0600 root-only
fs.chmod("/readonly", 0x8124)   -- reg 0444
fs.chmod("/pub", 0x81A4)        -- reg 0644
fs.chmod("/home", 0x41ED)       -- dir 0755
fs.chmod("/home/alice", 0x41C0) -- dir 0700 alice
fs.chown("/home/alice", 1000, 1000)
-- 清理上次同一测试残留的 /home/alice/x.txt: 它可能被持久化成 root 属主。
-- 删除只要求父目录的写+执行权限(root uid0 恒过), 不依赖文件本身属主。
if fs.exists("/home/alice/x.txt") then pcall(fs.delete, "/home/alice/x.txt") end
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
-- 写 0444 -> 拒绝(open 即被权限检查拒绝, 而非拿到 nil 句柄后再崩溃)
local wr = fs.open("/readonly", "w")
try("write /readonly (0444) denied", wr == nil)
if wr then wr.close() end
-- 执行权限: 有读无 x 不可启动, 有 x(0755)才可启动
try("canExecute /pub (0644) false", fs.canExecute("/pub") == false)
try("canExecute /bin/ls (0755) true", fs.canExecute("/bin/ls") == true)
-- list alice-owned 0700 -> ok
print("alice: list /home/alice => [" .. table.concat((fs.list("/home/alice") or {}), ",") .. "]")
-- 在 /home/alice 里写文件(属主, 0700) -> ok。open 失败时透出真实原因,
-- 而不是对 nil 句柄取下标变成无意义的 "attempt to index local 'w'"。
local w, wopenerr = fs.open("/home/alice/x.txt", "w")
if not w then
    print("alice: write /home/alice/x.txt open-failed err=" .. tostring(wopenerr))
else
    local okw, errw = pcall(function() w.write("alice file"); w.close() end)
    print("alice: write /home/alice/x.txt ok=" .. tostring(okw) .. (okw and "" or (" err=" .. tostring(errw))))
    if okw then
        print("alice: exists=" .. tostring(fs.exists("/home/alice/x.txt")))
        local rf = fs.open("/home/alice/x.txt", "r")
        print("alice: read x.txt=[" .. (rf and rf.readAll() or "(none)") .. "]")
        if rf then rf.close() end
    end
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
    -- 无参 ls 应列出当前目录(cwd=/home/alice → 含 x.txt), 而非 "/"(含 etc/)。
    -- 读工具对 0600 root 的 /secret 应报 Permission denied 而非 "No such file"(文件存在)。
    local lines = {
        "/home/alice/nonx",
        "cat /secret",
        "grep root /secret",
        "head /secret",
        "tail /secret",
        "wc /secret",
        "ls",
        "echo AFTER",
    }
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
    local function has(s) return out:find(s, 1, true) ~= nil end
    print("ext2-init: alice sh run nonx => [" .. out .. "]")
    print("ext2-init: alice sh refuses non-exec=" .. tostring(has("Permission denied")))
    print("ext2-init: alice sh ls no-arg cwd=" .. tostring(has("x.txt"))
        .. "/not-root=" .. tostring(not has("etc/")))
    print("ext2-init: alice sh err-msgs cat/grep/head/tail/wc="
        .. tostring(has("cat: /secret: Permission denied"))
        .. "," .. tostring(has("grep: /secret: Permission denied"))
        .. "," .. tostring(has("head: /secret: Permission denied"))
        .. "," .. tostring(has("tail: /secret: Permission denied"))
        .. "," .. tostring(has("wc: /secret: Permission denied")))
    if fs.exists("/home/alice/nonx") then pcall(fs.delete, "/home/alice/nonx") end
end

-- ═══════════ sed 真机自测(内存 stdio, 直接 spawn /bin/sed) ═══════════
do
    local sh = fs.open("/bin/sed", "r")
    local sedSrc = sh and sh.readAll() or nil
    if sh then sh.close() end
    if not sedSrc then
        print("ext2-init: /bin/sed not found")
    else
        local function runSed(argv)
            -- 每次用独立内存 stdio; 子进程继承 init 的 stdio(set 后)。
            local inH = { readLine = function() return nil end }
            local outbuf = {}
            local outH = {
                write = function(self, s) outbuf[#outbuf + 1] = tostring(s); return #s end,
                writeLine = function(self, s) outbuf[#outbuf + 1] = tostring(s) .. "\n"; return #s + 1 end,
            }
            syscalls["stdio.set"](inH, outH)
            local pid = spawn(sedSrc, "sed", nil, nil, argv)
            local tries = 0
            while pid and tries < 30 do
                local p = syscalls["proc.info"](pid)
                if not p then break end
                if p.status == "dead" or p.status == "error" then break end
                sleep(0.1); tries = tries + 1
            end
            return table.concat(outbuf)
        end

        -- 输入文件(已知内容)
        local tf = fs.open("/dbg_sed.txt", "w")
        if tf then tf.write("foo 1\nbar 2\nbaz 3\n"); tf.close() end
        -- 替换(全局 + p 标志)
        print("ext2-init: sed sub=[" .. runSed({ [0] = "/bin/sed", "-n", "s/foo/F/gp", "/dbg_sed.txt" }) .. "]")
        -- 行删除
        print("ext2-init: sed del=[" .. runSed({ [0] = "/bin/sed", "2d", "/dbg_sed.txt" }) .. "]")
        -- 行号
        print("ext2-init: sed num=[" .. runSed({ [0] = "/bin/sed", "=", "/dbg_sed.txt" }) .. "]")
        -- 就地改写(-i)
        local tf2 = fs.open("/dbg_sed2.txt", "w")
        if tf2 then tf2.write("foo\nbar\nfoo\n"); tf2.close() end
        runSed({ [0] = "/bin/sed", "-i", "s/foo/F/", "/dbg_sed2.txt" })
        local rf = fs.open("/dbg_sed2.txt", "r")
        print("ext2-init: sed inplace=[" .. (rf and rf.readAll() or "") .. "]")
        if rf then rf.close() end
        if fs.exists("/dbg_sed.txt") then pcall(fs.delete, "/dbg_sed.txt") end
        if fs.exists("/dbg_sed2.txt") then pcall(fs.delete, "/dbg_sed2.txt") end
    end
end

-- ═══════════ 信号机制测试(内核信号/作业控制) ═══════════
do
    print("ext2-init: signal tests start")
    local function kill(pid, sig) return syscalls["signal.kill"](pid, sig) end
    local function info(pid) return syscalls["proc.info"](pid) end
    local sleeper = "while true do sleep(0.2) end"

    -- 1) SIGSTOP / SIGCONT / SIGTERM 默认动作
    local p1 = spawn(sleeper, "sigloop1")
    sleep(0.1)
    print("ext2-init: spawn sigloop1 pid=" .. tostring(p1))
    kill(p1, 19) -- SIGSTOP
    sleep(0.1)
    local i1 = info(p1)
    print("ext2-init: sigloop1 after SIGSTOP status=" .. (i1 and i1.status or "?") .. " (expect stopped)")
    kill(p1, 18) -- SIGCONT
    sleep(0.1)
    local i2 = info(p1)
    print("ext2-init: sigloop1 after SIGCONT status=" .. (i2 and i2.status or "?") .. " (expect running)")
    kill(p1, 15) -- SIGTERM
    sleep(0.1)
    local i3 = info(p1)
    print("ext2-init: sigloop1 after SIGTERM status=" .. (i3 and i3.status or "?")
        .. " termsig=" .. (i3 and i3.termSig or "-") .. " (expect dead,15)")

    -- 2) SIGKILL 不可捕获
    local p2 = spawn(sleeper, "sigloop2")
    sleep(0.1)
    kill(p2, 9) -- SIGKILL
    sleep(0.1)
    local j2 = info(p2)
    print("ext2-init: sigloop2 after SIGKILL status=" .. (j2 and j2.status or "?")
        .. " termsig=" .. (j2 and j2.termSig or "-") .. " (expect dead,9)")

    -- 3) SIGINT 无 handler -> 默认终止
    local p3 = spawn(sleeper, "sigloop3")
    sleep(0.1)
    kill(p3, 2) -- SIGINT
    sleep(0.1)
    local k3 = info(p3)
    print("ext2-init: sigloop3 SIGINT(no handler) status=" .. (k3 and k3.status or "?")
        .. " termsig=" .. (k3 and k3.termSig or "-") .. " (expect dead,2)")

    -- 4) SIGINT 带 handler -> 存活, handler 打印到 log(SIGINT_CAUGHT)
    local hsrc = [[
syscalls["signal.install"](2, function() print("SIGINT_CAUGHT") end)
while true do sleep(0.2) end
]]
    local p4 = spawn(hsrc, "sigint-handler")
    sleep(0.1)
    kill(p4, 2)
    sleep(0.1)
    local i4 = info(p4)
    print("ext2-init: sigint-handler after SIGINT status=" .. (i4 and i4.status or "?") .. " (expect running)")
    kill(p4, 15) -- 清理
    sleep(0.1)

    -- 5) 无效 pid 报错
    local ok5, e5 = syscalls["signal.kill"](999999, 15)
    print("ext2-init: kill invalid pid ok=" .. tostring(ok5) .. " err=" .. tostring(e5) .. " (expect nil)")

    -- 6) 会话(setsid)+进程组(killpg): leader 建会话, spawn worker, killpg 全组终止。
    local lsrc = [[
local sid = syscalls["job.setsid"]()
spawn("while true do sleep(0.2) end", "worker")
local pg, sid2 = syscalls["job.group"]()
print("LEADER sid=" .. tostring(sid) .. " pg=" .. tostring(pg))
while true do sleep(0.2) end
]]
    local lp = spawn(lsrc, "leader")
    sleep(0.2)
    local linfo = syscalls["proc.info"](lp)
    print("ext2-init: leader pid=" .. tostring(lp) .. " pgrp=" .. tostring(linfo and linfo.pgrp)
        .. " sid=" .. tostring(linfo and linfo.sid) .. " (expect pgrp==sid==pid)")
    local killpgRes = syscalls["signal.killpg"](lp, 15) -- SIGTERM 整个进程组
    sleep(0.1)
    local ldead = syscalls["proc.info"](lp)
    print("ext2-init: killpg(leader,TERM) n=" .. tostring(killpgRes)
        .. " leader status=" .. (ldead and ldead.status or "?") .. " termsig=" .. (ldead and ldead.termSig or "-")
        .. " (expect n>=1, dead,15)")

    -- 7) setpgid 自建进程组(交互 sh 用: sh 把自己移出自己的组为前台)。
    local sgsrc = [[
local before, _ = syscalls["job.group"]()
syscalls["job.setpgid"](pid, 0)
local after, _ = syscalls["job.group"]()
print("SETPGID before=" .. tostring(before) .. " after=" .. tostring(after))
while true do sleep(0.2) end
]]
    local spid = spawn(sgsrc, "sgchild")
    sleep(0.2)
    local sp = syscalls["proc.info"](spid)
    print("ext2-init: setpgid child pgrp=" .. tostring(sp and sp.pgrp)
        .. " (expect ==pid " .. tostring(spid) .. ")")
    syscalls["signal.kill"](spid, 9)
    sleep(0.1)
end

-- ═══════════ tty ^C / ^D 行规程 ═══════════
-- 用一个 reader 子进程真正阻塞在 tty readLine 上(置 ctx.reading), 再喂 ^C/^D 控制键。
do
    local rsrc = [[
local c = syscalls["tty.console"]()
local t = fs.open("/dev/" .. tostring(c), "rw")
local line = t:readLine()
print("READER_GOT=[" .. tostring(line) .. "]")
]]
    -- ^C(空缓冲): 取消行 -> readLine 返回 ""
    spawn(rsrc, "reader-ctrl-c")
    sleep(0.15)
    os.queueEvent("key", keys.leftCtrl, false)
    os.queueEvent("key", keys.c, false)
    os.queueEvent("key_up", keys.leftCtrl, false)
    sleep(0.2)
    print("ext2-init: ^C test queued (read READER_GOT=[] in log)")

    -- ^D(空缓冲): EOF -> readLine 返回 nil
    spawn(rsrc, "reader-ctrl-d")
    sleep(0.15)
    os.queueEvent("key", keys.leftCtrl, false)
    os.queueEvent("key", keys.d, false)
    os.queueEvent("key_up", keys.leftCtrl, false)
    sleep(0.2)
    print("ext2-init: ^D test queued (read READER_GOT=[nil] in log)")
end

-- ═══════════ 真机 sh 自检 + sysinfo: 把脚本内容喂给 sh, 输出捕获到 log ═══════════
do
    local shHand = fs.open("/bin/sh", "r")
    local shSrc = shHand and shHand.readAll() or nil
    if shHand then shHand.close() end
    if not shSrc then
        print("ext2-init: /bin/sh not found (scripts skipped)")
    else
        local function runScript(path, label)
            if not fs.exists(path) then
                print("ext2-init: " .. label .. ": script missing " .. path)
                return
            end
            local f = fs.open(path, "r")
            local lines = {}
            while true do
                local l = f and f.readLine and f.readLine()
                if l == nil then break end
                lines[#lines + 1] = l
            end
            if f then f.close() end
            local li = 0
            local inH = { readLine = function(self) li = li + 1; return lines[li] end }
            local outbuf = {}
            local outH = {
                write = function(self, s) outbuf[#outbuf + 1] = tostring(s); return #s end,
                writeLine = function(self, s) outbuf[#outbuf + 1] = tostring(s) .. "\n"; return #s + 1 end,
            }
            syscalls["stdio.set"](inH, outH)
            local spid = spawn(shSrc, "sh-" .. label, nil, nil, { [0] = "/bin/sh" })
            print("ext2-init: running " .. label .. " (pid " .. tostring(spid) .. ")")
            local tries = 0
            while spid and tries < 80 do
                local p = syscalls["proc.info"](spid)
                if not p then break end
                if p.status == "dead" or p.status == "error" then break end
                sleep(0.1); tries = tries + 1
            end
            print("ext2-init: " .. label .. " output:")
            for _, s in ipairs(outbuf) do print("  " .. s) end
        end
        runScript("/root/posix_test.sh", "posix-test")
        runScript("/root/sysinfo.sh", "sysinfo")
    end
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
