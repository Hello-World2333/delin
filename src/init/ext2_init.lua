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

sleep(0.6)
print("ext2-init: done pid=" .. pid)
