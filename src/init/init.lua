-- Delin OS PID 1 (init) —— CC-fs 引导路径的演示/自检
-- 运行在隔离进程环境中(pid/ppid/spawn/print/syscalls 由内核注入, 其余原始 API 直用)。

print("init: hello, pid=" .. pid .. " ppid=" .. ppid)

-- VFS: 写真实 hdd 根
local f = fs.open("/hello-vfs.txt", "w")
f.writeLine("hello via Delin VFS from pid " .. pid)
f.close()
print("init: wrote /hello-vfs.txt")

-- 模块注册的 syscall
if syscalls and syscalls["demo.echo"] then
    print("init: demo.echo => " .. syscalls["demo.echo"]("hello", "from", "module"))
else
    print("init: no demo.echo syscall")
end

-- 模块注册的 /dev 设备
print("init: /dev list=" .. table.concat(fs.list("/dev"), ","))
print("init: /dev/demo exists=" .. tostring(fs.exists("/dev/demo")))

-- 模块注册的 /proc 虚拟文件系统
print("init: /proc/cpu exists=" .. tostring(fs.exists("/proc/cpu")))
local pf = fs.open("/proc/cpu", "r")
print("init: /proc/cpu content=" .. (pf and ("[" .. pf.readAll() .. "]") or "(none)"))
if pf then pf.close() end

-- 磁盘设备抽象: /dev/sdX (整盘 = CC 原生 fs / ccdisk; /dev/sdXN = manifest 分区 / ext2)。
-- 磁盘不再自动挂到 /mnt/<side>, 一律经 `mount` 显式挂载。
local devs = (syscalls and syscalls["blkdev.list"] and syscalls["blkdev.list"]()) or {}
print("init: blkdevs=" .. #devs)
for _, e in ipairs(devs) do
    print(string.format("init: %s uuid=%s type=%s size=%s mounted=%s",
        e.node, tostring(e.uuid), e.fstype, tostring(e.size), table.concat(e.mounted or {}, ",")))
end

-- 挂载第一个 ext2 分区, 读 /etc/hostname 再卸载。
local part
for _, e in ipairs(devs) do
    if e.type == "part" then part = e; break end
end
if not part then
    print("init: no ext2 partition on any disk (skip mount test)")
else
    if not fs.exists("/mnt") then fs.makeDir("/mnt") end
    local ok, info = syscalls["fs.mount"](part.node, "/mnt")
    print("init: mount " .. part.node .. " /mnt -> " .. tostring(ok) .. " type=" .. tostring(info and info.fstype or info))
    local h = fs.open("/mnt/etc/hostname", "r")
    print("init: /mnt/etc/hostname=[" .. (h and h.readAll() or "(none)") .. "]")
    if h then h.close() end
    print("init: /mnt list=" .. table.concat(fs.list("/mnt") or {}, ","))
    print("init: umount /mnt -> " .. tostring(syscalls["fs.umount"]("/mnt")))
    -- UUID 解析: 按 UUID 再挂一次, 然后卸载。
    if part.uuid then
        local ok2, info2 = syscalls["fs.mount"]("UUID=" .. part.uuid, "/mnt")
        print("init: mount UUID=" .. part.uuid .. " -> " .. tostring(ok2)
            .. " dev=" .. tostring(info2 and info2.device or info2))
        if ok2 then print("init: umount by device -> " .. tostring(syscalls["fs.umount"](part.node))) end
    end
end

-- 子进程经 VFS 读回 + 看 syscalls
local childSrc = "local fd = fs.open('/hello-vfs.txt','r')\n"
    .. "print('child: readback=' .. (fd and fd.readAll() or '(none)'))\n"
    .. "print('child: syscalls type=' .. tostring(type(syscalls)))\n"
    .. "if fd then fd.close() end\n"
    .. "sleep(0.3)\nprint('child: done pid=' .. pid .. ' ppid=' .. ppid)"

spawn(childSrc, "child")

sleep(0.6)
print("init: done pid=" .. pid)
