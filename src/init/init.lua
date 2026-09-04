-- Delin OS PID 1 (init)
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
print("init: /proc list=" .. table.concat(fs.list("/proc"), ","))

-- 模块装的 EXT2 只读挂载(phase A) + 现在写(phase B)
print("init: /mnt/ext2 list=" .. table.concat(fs.list("/mnt/ext2") or {}, ","))
local h2 = fs.open("/mnt/ext2/etc/hostname", "r")
print("init: hostname=[" .. (h2 and h2.readAll() or "(none)") .. "]")
if h2 then h2.close() end
local ea = fs.attributes("/mnt/ext2/etc/hostname")
print("init: hostname attrs mode=" .. (ea and string.format("%o", ea.mode) or "?")
    .. " uid=" .. (ea and tostring(ea.uid) or "?")
    .. " gid=" .. (ea and tostring(ea.gid) or "?")
    .. " size=" .. (ea and tostring(ea.size) or "?"))

-- phase B: EXT2 写
local wf = fs.open("/mnt/ext2/etc/delin-test.txt", "w")
wf.writeLine("written from Delin EXT2 write (pid " .. pid .. ")")
wf.close()
local rf = fs.open("/mnt/ext2/etc/delin-test.txt", "r")
print("init: delin-test.txt=[" .. (rf and rf.readAll() or "(none)") .. "]")
if rf then rf.close() end
print("init: mkdir /mnt/ext2/newdir -> " .. tostring((fs.makeDir("/mnt/ext2/newdir") or true)))
print("init: delete /mnt/ext2/etc/hostname -> " .. tostring(fs.delete("/mnt/ext2/etc/hostname")))
print("init: /mnt/ext2/etc list=" .. table.concat(fs.list("/mnt/ext2/etc") or {}, ","))
print("init: /mnt/ext2 list=" .. table.concat(fs.list("/mnt/ext2") or {}, ","))

-- 子进程经 VFS 读回 + 看 syscalls
local childSrc = "local fd = fs.open('/hello-vfs.txt','r')\n"
    .. "print('child: readback=' .. (fd and fd.readAll() or '(none)'))\n"
    .. "print('child: syscalls type=' .. tostring(type(syscalls)))\n"
    .. "if fd then fd.close() end\n"
    .. "sleep(0.3)\nprint('child: done pid=' .. pid .. ' ppid=' .. ppid)"

spawn(childSrc, "child")

sleep(0.6)
print("init: done pid=" .. pid)
