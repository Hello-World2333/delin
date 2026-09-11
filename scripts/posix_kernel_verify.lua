-- Delin 真机验证: 内核新增的 POSIX 能力(符号链接/硬链接/命名管道/umask/seek)。
-- 由 scripts/posix_tools_verify.sh 用 `/bin/lua /root/posix_kernel_verify.lua` 调起, 结果打到 stdout。
-- 为什么用 lua 而不是 sh: 这些能力目前有的还没有命令行入口(ln/readlink/mkfifo 是另一批在补),
-- 而 /bin/lua 的进程环境里 fs/syscalls 都在, 可以直接验证**内核**语义本身 —— 真机验证要验的
-- 正是内核, 不是某个工具的包装。
local pass, fail = 0, 0
local function ok(cond, label, extra)
    if cond then pass = pass + 1; io.write("ok   " .. label .. "\n")
    else fail = fail + 1; io.write("FAIL " .. label .. (extra and ("  -- " .. tostring(extra)) or "") .. "\n") end
end
local function eq(got, want, label)
    ok(got == want, label, "got=" .. tostring(got) .. " want=" .. tostring(want))
end

local BASE = "/var/tmp/posixk"
pcall(function() fs.delete(BASE) end)
assert(fs.makeDir(BASE), "cannot create " .. BASE)

-- ---------- 符号链接 ----------
local f = fs.open(BASE .. "/target", "w"); f:write("payload\n"); f:close()
ok(fs.symlink("target", BASE .. "/rel_link") ~= nil, "symlink: 建相对目标的链接")
eq(fs.readlink(BASE .. "/rel_link"), "target", "readlink: 相对目标原样保存")
ok(fs.symlink(BASE .. "/target", BASE .. "/abs_link") ~= nil, "symlink: 建绝对目标的链接")
eq(fs.readlink(BASE .. "/abs_link"), BASE .. "/target", "readlink: 绝对目标原样保存")

-- lstat 看链接本身, attributes 跟随到目标
eq(fs.lstat(BASE .. "/abs_link").kind, "symlink", "fs.lstat: kind=symlink")
eq(fs.attributes(BASE .. "/abs_link").kind, "file", "fs.attributes: 跟随到普通文件")
eq(fs.attributes(BASE .. "/abs_link").size, 8, "fs.attributes: 取到目标大小")

-- 权限: 符号链接不受 umask 影响, 恒 0777(Linux 语义)
eq(fs.lstat(BASE .. "/abs_link").mode % 4096, tonumber("777", 8), "symlink: 权限恒 0777(不受 umask 影响)")

-- 经链接读写(路径解析要穿过链接)
local r = fs.open(BASE .. "/abs_link", "r")
eq(r.readAll(), "payload\n", "经符号链接读到目标内容")
r.close()

-- 目录链接: 中间段也要跟随
assert(fs.makeDir(BASE .. "/sub"))
local g = fs.open(BASE .. "/sub/inner", "w"); g:write("inner\n"); g:close()
ok(fs.symlink(BASE .. "/sub", BASE .. "/dirlink") ~= nil, "symlink: 建目录链接")
local h = fs.open(BASE .. "/dirlink/inner", "r")
eq(h.readAll(), "inner\n", "经目录链接读到链接目录里的文件")
h.close()
ok(fs.isDir(BASE .. "/dirlink"), "fs.isDir: 目录链接判定为目录")

-- 悬空链接: readlink 有效, exists 为假
ok(fs.symlink(BASE .. "/nowhere", BASE .. "/dangling") ~= nil, "symlink: 建悬空链接")
eq(fs.readlink(BASE .. "/dangling"), BASE .. "/nowhere", "readlink: 悬空链接仍可读目标")
eq(fs.exists(BASE .. "/dangling"), false, "fs.exists: 悬空链接 -> false")

-- 链接成环: 必须 ELOOP 而不是死循环(这里只验证不挂死)
assert(fs.symlink(BASE .. "/loop2", BASE .. "/loop1"))
assert(fs.symlink(BASE .. "/loop1", BASE .. "/loop2"))
io.write("     (环检测: 下面这次 open 应当报错返回)\n")
local lp, lperr = fs.open(BASE .. "/loop1", "r")
ok(lp == nil, "ELOOP: 成环链接不返回句柄", tostring(lperr))

-- 删除链接不删目标
assert(fs.symlink(BASE .. "/target", BASE .. "/torm"))
ok(fs.delete(BASE .. "/torm") ~= nil, "delete: 删除链接")
eq(fs.exists(BASE .. "/target"), true, "delete: 删链接不删目标")
eq(fs.exists(BASE .. "/torm"), false, "delete: 链接本身已删")

-- ---------- 硬链接 ----------
local inoA = fs.lstat(BASE .. "/target").ino
ok(fs.link(BASE .. "/target", BASE .. "/hard") ~= nil, "link: 建硬链接")
eq(fs.lstat(BASE .. "/hard").ino, inoA, "link: 两个名字同一个 inode")
eq(fs.lstat(BASE .. "/hard").links, 2, "link: links 计数为 2")
ok(fs.link(BASE .. "/sub", BASE .. "/sub2") == nil, "link: 目录不可硬链接")
ok(fs.link(BASE .. "/target", BASE .. "/target") == nil, "link: 目标已存在 -> 报错")
ok(fs.delete(BASE .. "/target") ~= nil, "link: 删掉一个名字")
eq(fs.open(BASE .. "/hard", "r").readAll(), "payload\n", "link: 另一个名字内容仍在")
ok(fs.delete(BASE .. "/hard") ~= nil, "link: 删掉最后一个名字")

-- ---------- umask ----------
local oldmask = syscalls["umask.get"]()
eq(oldmask, tonumber("022", 8), "umask: 缺省 0022")
local prev = syscalls["umask.set"](tonumber("077", 8))
eq(prev, tonumber("022", 8), "umask.set: 返回旧值")
eq(syscalls["umask.get"](), tonumber("077", 8), "umask.get: 读到新值")
-- 新建文件的权限必须被 umask 收窄(内核在 create 时统一应用)
local uf = fs.open(BASE .. "/umaskfile", "w"); uf:write("x"); uf:close()
eq(fs.lstat(BASE .. "/umaskfile").mode % 4096, tonumber("600", 8), "umask: 新建文件为 0600(0666 & ~0077)")
fs.makeDir(BASE .. "/umaskdir")
eq(fs.lstat(BASE .. "/umaskdir").mode % 4096, tonumber("700", 8), "umask: 新建目录为 0700(0777 & ~0077)")
syscalls["umask.set"](tonumber("022", 8))

-- ---------- seek (dd 依赖) ----------
local sf = fs.open(BASE .. "/seek", "w"); sf:write("0123456789"); sf:close()
local rh = fs.open(BASE .. "/seek", "r")
eq(rh.seek("set", 3), 3, "seek: 读句柄 seek(set,3) 返回 3")
eq(rh.read(4), "3456", "seek: 从偏移 3 读 4 字节")
eq(rh.seek("end", 0), 10, "seek: seek(end,0) 返回文件长度")
eq(rh.seek("cur", -2), 8, "seek: seek(cur,-2)")
eq(rh.read(5), "89", "seek: 从偏移 8 读到末尾")
rh.close()

-- ---------- 命名管道: 只验 node 侧(阻塞的读写要在两个进程里做, 见 sh 脚本) ----------
ok(fs.mkfifo(BASE .. "/pipe") ~= nil, "mkfifo: 建命名管道")
eq(fs.lstat(BASE .. "/pipe").kind, "fifo", "mkfifo: lstat kind=fifo")
eq(fs.lstat(BASE .. "/pipe").size, 0, "mkfifo: FIFO 没有文件内容")
eq(fs.isFifo(BASE .. "/pipe"), true, "fs.isFifo: 认得出管道")
eq(fs.isFifo(BASE .. "/umaskfile"), false, "fs.isFifo: 普通文件不是管道")

pcall(function() fs.delete(BASE) end)
io.write(string.format("\nposix_kernel: %d passed, %d failed\n", pass, fail))
return fail == 0 and 0 or 1
