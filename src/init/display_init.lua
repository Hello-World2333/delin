-- 显示系统测试(仅在 CC-fs 引导时跑, 因为驱动模块由模块系统加载)。
-- 进程面向 /dev/ttyN、/dev/fbN 字符设备, 遵循 Linux。
print("display-init: pid=" .. pid .. " uid=" .. uid)
local ttys = (syscalls and syscalls["tty.list"] and syscalls["tty.list"]()) or {}
local fbs  = (syscalls and syscalls["fb.list"] and syscalls["fb.list"]()) or {}
print("display-init: tty=" .. table.concat(ttys or {}, ",") .. " fb=" .. table.concat(fbs or {}, ","))

local tname = ttys and ttys[1]
if tname then
    local t = fs.open("/dev/" .. tname, "w")
    if t then
        local w, h = t:getSize()
        print("display-init: /dev/" .. tname .. " size=" .. tostring(w) .. "x" .. tostring(h))
        t:clear(0x0)
        t:write("Delin OS tty test")
        t:write("\n")
        t:writeLine("pid " .. pid .. " via " .. tname)
        t:flush()
        t:close()
        print("display-init: wrote to /dev/" .. tname)
    else
        print("display-init: open /dev/" .. tname .. " failed")
    end
end

local fname = fbs and fbs[1]
if fname then
    local fb = fs.open("/dev/" .. fname, "w")
    if fb then
        local w, h = fb:getSize()
        print("display-init: /dev/" .. fname .. " " .. tostring(w) .. "x" .. tostring(h) .. " bpp=" .. tostring(fb:getBpp()))
        fb:clear(0x000000)
        fb:setPixel(0, 0, 0xFF0000)
        fb:setPixel(1, 0, 0x00FF00)
        fb:setPixel(2, 0, 0x0000FF)
        fb:setPixel(0, 1, 0xFFFF00)
        fb:flush()
        fb:close()
        print("display-init: drew pixels to /dev/" .. fname)
    else
        print("display-init: open /dev/" .. fname .. " failed")
    end
end

sleep(0.3)
print("display-init: done")
