-- Delin OS PID 1 (init)
-- 运行在隔离进程环境中(pid/ppid/spawn/print 由内核注入, 其余原始 API 直用)。
-- 这里演示 VFS: 写到真实 hdd 根、列出虚拟 /dev、让子进程经 VFS 读回。

print("init: hello, pid=" .. pid .. " ppid=" .. ppid)

-- VFS 写真实 hdd "/"
local f = fs.open("/hello-vfs.txt", "w")
f.writeLine("hello via Delin VFS from pid " .. pid .. " ppid " .. ppid)
f.close()
print("init: wrote /hello-vfs.txt")

-- VFS 虚拟 /dev
print("init: /dev list=" .. table.concat(fs.list("/dev"), ","))
print("init: exists /dev/test=" .. tostring(fs.exists("/dev/test")))
print("init: exists /dev/null=" .. tostring(fs.exists("/dev/null")))

-- 子进程经 VFS 读回
local childSrc = "local fd = fs.open('/hello-vfs.txt','r')\n"
    .. "print('child: readback=' .. (fd and fd.readAll() or '(none)'))\n"
    .. "if fd then fd.close() end\n"
    .. "sleep(0.3)\nprint('child: done pid=' .. pid .. ' ppid=' .. ppid)"

spawn(childSrc, "child")
print("init: spawned child")

sleep(0.6)
print("init: done pid=" .. pid)
