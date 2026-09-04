-- 显示系统测试(仅在 CC-fs 引导时跑, 因为驱动模块由模块系统加载)。
print("display-init: pid=" .. pid .. " uid=" .. uid)
local dl = syscalls and syscalls["display.list"] and syscalls["display.list"]() or {}
print("display-init: displays=" .. table.concat(dl or {}, ","))
if dl and dl[1] then
    local w, h = syscalls["display.size"](dl[1])
    print("display-init: " .. dl[1] .. " size=" .. tostring(w) .. "x" .. tostring(h))
    syscalls["display.fill"](dl[1], 0x000000)
    syscalls["display.write"](dl[1], 0, 0, "Delin OS display test")
    syscalls["display.write"](dl[1], 0, 10, "pid " .. pid .. " via " .. dl[1])
    print("display-init: wrote to " .. dl[1])
end
sleep(0.3)
print("display-init: done")
