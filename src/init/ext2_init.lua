-- Delin 引导用的最小 PID 1(EXT2 根引导时用)。证明内核从 EXT2 根启动了进程树。
print("ext2-init: root booted, pid=" .. pid .. " ppid=" .. ppid)
print("ext2-init: / list=" .. table.concat(fs.list("/") or {}, ","))

local c = "print('ext2-child: hello from pid ' .. pid .. ' ppid ' .. ppid)\n"
    .. "sleep(0.3)\nprint('ext2-child: done pid=' .. pid)"
spawn(c, "ext2-child")

sleep(0.5)
print("ext2-init: done pid=" .. pid)
