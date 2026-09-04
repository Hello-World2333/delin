-- Delin OS PID 1 (init)
-- 运行在隔离进程环境中(pid/ppid/spawn/print 由内核注入, 其余原始 API 直用)。
-- 注意: 不用嵌套 [[ ]] 长括号(CC 的 Lua 会报 deprecation), 改用普通字符串拼接。

local function q(s) return string.format("%q", s) end

print("init: hello, pid=" .. pid .. " ppid=" .. ppid)

local grandSrc = "print('grandA: hello pid=' .. pid .. ' ppid=' .. ppid)\n"
    .. "sleep(0.2)\nprint('grandA: done pid=' .. pid)"

local childA = "print('childA: hello pid=' .. pid .. ' ppid=' .. ppid)\n"
    .. "spawn(" .. q(grandSrc) .. ", 'grand-a')\n"
    .. "sleep(0.4)\nprint('childA: done pid=' .. pid)"

local childB = "print('childB: hello pid=' .. pid .. ' ppid=' .. ppid)\n"
    .. "sleep(0.6)\nprint('childB: done pid=' .. pid)"

spawn(childA, "child-a")
spawn(childB, "child-b")
print("init: spawned children, waiting ...")

sleep(0.8)
print("init: done pid=" .. pid)
