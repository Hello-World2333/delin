-- Delin 用户管理自检的辅助程序(被 scripts/user_test.sh 调用; 宿主测试台与真机各跑一次)。
--
-- 存在的理由: 没有 su/setuid 之类的身份切换命令, 而 `passwd` 改自己密码、`useradd` 被拒这类
-- 分支**必须以普通用户身份**跑才算数(内核 user.* syscall 按调用者 uid 授权)。普通用户进程
-- 只能用内核给的 spawn(src, name, uid, gid, argv, opts) 起 —— 于是这里替 shell 做那件事。
--
-- 用法:
--   lua user_helper.lua spawn <uid> <tool> <outPath> <inPath|-> [args...]
--       以 <uid> 跑 /bin/<tool>: stdout/stderr 写 <outPath>, stdin 接 <inPath>(`-` = 关掉)。
--       打印该进程的 pid 就**立即退出, 不等它** —— 本脚本是 /bin/lua 用 xpcall 跑的, 而
--       Lua 5.1(宿主测试台)不允许跨 pcall 让出, 在这里 proc.wait 会直接炸; 等待交给调用它
--       的 shell(`read` 拿 pid + `wait <pid>`, sh 是普通工具, 让出没有限制)。
--   lua user_helper.lua verify <name> <password>
--       直接问内核 user.verify(登录判定的同一真源), 打印 yes/no, 返回 0/1。
local a = arg -- 注意: /bin/lua 里 `args` 是解释器自己的 argv, 脚本参数在官方 arg 表里
local mode = a[1]

if mode == "verify" then
    local ok = syscalls["user.verify"](a[2], a[3])
    print(ok and "yes" or "no")
    return ok and 0 or 1
end

assert(mode == "spawn", "usage: user_helper.lua spawn|verify ...")
local asUid  = tonumber(a[2])
local tool   = a[3]
local outPath = a[4]
local inPath = a[5]

local argv = { [0] = "/bin/" .. tool }
for i = 6, #a do argv[i - 5] = a[i] end

local srcFile = assert(fs.open("/bin/" .. tool, "r"), "no such tool: " .. tostring(tool))
local src = srcFile.readAll(); srcFile.close()

local input = nil
if inPath ~= "-" then input = assert(fs.open(inPath, "r"), "no such input: " .. tostring(inPath)) end

-- 子进程写的是**同一个**输出句柄, 而 ext2 的 "w" 句柄只在 flush/close 时才落盘; 本程序又不等
-- 子进程就退出(见上), 于是没人替它 close —— 真机上输出文件会是空的(宿主测试台的宿主文件是直写
-- 的, 所以这个 bug 只在真机露出来: 第一轮真机跑的 alice_id_self/alice_whoami 就是这么 ng 的)。
-- 包一层"每次写都 flush": 子进程每写一次就落一次盘, 谁先退出都不丢内容。
local rawOut = assert(fs.open(outPath, "w"))
local output = {
    write     = function(self, s) if s == nil then s = self end
                    local n = rawOut:write(s); rawOut:flush(); return n end,
    writeLine = function(self, s) if s == nil then s = self end
                    local n = rawOut:writeLine(s); rawOut:flush(); return n end,
    flush     = function() return rawOut:flush() end,
    close     = function() return rawOut:close() end,
}

local pid = spawn(src, tool, asUid, asUid, argv, { stdio = { input = input, output = output } })
assert(pid, "spawn failed: " .. tostring(tool))
print(pid)
return 0
