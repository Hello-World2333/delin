-- Delin 宿主测试台: 在 HOST 上运行真实的 Delin bin 工具源码(src/bin/*),
-- 提供与内核一致的 fs/io/syscalls/spawn 环境, 以便本地快速调试 sh/工具逻辑。
-- 用法:
--   lua5.1 tools/harness.lua <tool> <args...>   (stdin 作为工具输入, stdout 即 stdout)
--   如: printf 'echo hi\n' | lua5.1 tools/harness.lua /bin/sh
-- ROOT 会先重建并填充 ROOT/bin(=src/bin), /etc, /home, /root 与示例文件。

-- 测试根目录(所有 "/" 路径映射到它下面)。默认 /tmp/delinhost; 并行跑多份 harness 时
-- 用 DELIN_HARNESS_ROOT 各给一个独立的根, 否则会互相 rm -rf 掉对方的树。
local ROOT = os.getenv("DELIN_HARNESS_ROOT") or "/tmp/delinhost"

-- Lua 5.2+ 没有 loadstring/setfenv; 用 load + 改 _ENV upvalue 顶上, 这样同一套测试
-- 也能在 lua5.4 下跑 (CC 的 Lua 是 5.2 语义 —— 压缩器等改动必须在 5.2 语义下也验一遍)。
loadstring = loadstring or function(s, n) return load(s, n) end
setfenv = setfenv or function(f, env)
    local i = 1
    while true do
        local n = debug.getupvalue(f, i)
        if not n then break end
        if n == "_ENV" then debug.setupvalue(f, i, env); return f end
        i = i + 1
    end
    error("harness setfenv shim: chunk has no _ENV upvalue")
end

-- 内核模块(与真机同一份源码): 进程环境白名单等要用真实实现, 不能在测试台上另写一套。
-- REPO 可用 DELIN_REPO 覆盖: 压缩器等价性门禁会在一个"压缩后的镜像树"上跑同一套测试。
-- 没给 DELIN_REPO 时按**本脚本所在目录**推仓库根, 并补成绝对路径 —— 别写死绝对路径:
-- 换台机器/CI 上跑就会变成 "module 'kernel.procenv' not found"(v0.0.2 tag 第一次跑 CI 就是这么炸的)。
local function repoRoot()
    local self = (arg and arg[0]) or "tools/harness.lua"
    local dir = self:match("^(.*)/[^/]*$") or "."   -- 脚本所在目录
    local root = dir:match("^(.*)/[^/]+$") or "."    -- 去掉 tools = 仓库根
    if root:sub(1, 1) ~= "/" then
        local p = io.popen("pwd")
        local cwd = p:read("*l"); p:close()
        root = (root == ".") and cwd or (cwd .. "/" .. root:gsub("^%./", ""))
    end
    return root
end
local REPO = os.getenv("DELIN_REPO") or repoRoot()
package.path = REPO .. "/src/?.lua;" .. package.path
local procenv = require("kernel.procenv")
local VERSION = require("kernel.version") -- 模块目录名 /lib/modules/<version>
local includeLib = dofile(REPO .. "/tools/include.lua") -- 构建期 --#include(与 build.lua 同一份实现)

-- pipe 内核模块用 os.sleep 做协作式阻塞; 在宿主上把它改成 yield 给调度器
-- (宿主 lua5.1 的 os 没有 sleep, 且这里必须能让出当前协程让调度器切走)。
os.sleep = function() coroutine.yield() end
-- 工具的让出是时间片式的(os.epoch("utc") 毫秒); 宿主用 os.clock 顶上。
-- 宿主调度器不推进真实时间, 时间片基本不会到期 —— 逻辑测试不受影响。
os.epoch = os.epoch or function() return math.floor(os.clock() * 1000) end

local function cmd(...) return { ... } end

-- 文件系统门面(基于 HOST 真实文件)。
local F = {}
-- 假终端开关与句柄: 在下面(F.open 用到)之前声明, 之后才赋值 ——
-- Lua 的 local 作用域从**声明语句之后**才开始, 声明晚了的话 F.open 里读到的是全局 nil。
local ttyMode = os.getenv("DELIN_HARNESS_TTY") == "1"
local inputHandle
local function norm(p)
    if p == nil or p == "" then return "/" end
    if p:sub(1, 1) ~= "/" then p = "/" .. p end
    -- 消解 "." 与 ".."(到根为止): 内核 VFS 的 normalize 就是这么做的, 测试台里以路径为键的
    -- 东西(FIFO 表等)必须用同一套视角 —— 否则 `find . -type p` 会因为 "./x" != "/x" 把管道
    -- 当普通文件(实测踩过)。
    local out = {}
    for seg in p:gmatch("[^/]+") do
        if seg == ".." then
            if #out > 0 then out[#out] = nil end
        elseif seg ~= "." then
            out[#out + 1] = seg
        end
    end
    if #out == 0 then return "/" end
    return "/" .. table.concat(out, "/")
end
local function host(p) local n = norm(p); return ROOT .. n end

function F.list(p)
    -- CC 语义: 路径不存在或不是目录时 `fs.list` 返回**空表**(ext2 后端返回 nil, 工具侧两者
    -- 等价处理)。不能直接照搬 GNU ls: `ls -A <文件>` 会把该文件路径自己打印出来, 宿主的
    -- fs.list(文件) 于是返回一条**路径**而不是空表 —— 工具在宿主上跑得过、真机才炸。
    if not F.isDir(p) then return {} end
    local h = host(p)
    local out = {}
    local f = assert(io.popen("ls -A -- " .. h))
    for line in f:lines() do out[#out + 1] = line end
    f:close()
    return out
end
function F.exists(p)
    local h = host(p)
    local f = io.open(h, "r")
    if f then f:close(); return true end
    local st = io.popen("[ -d " .. h .. " ] && echo yes")
    local r = st:read("*a"); st:close()
    return r ~= ""
end
function F.isDir(p)
    local st = io.popen("[ -d " .. host(p) .. " ] && echo yes")
    local r = st:read("*a"); st:close()
    return r ~= ""
end
function F.isFile(p)
    local st = io.popen("[ -f " .. host(p) .. " ] && echo yes")
    local r = st:read("*a"); st:close()
    return r ~= ""
end
function F.canExecute(p)
    local st = io.popen("[ -x " .. host(p) .. " ] && echo yes")
    local r = st:read("*a"); st:close()
    return r ~= ""
end
function F.getSize(p)
    local st = io.popen("stat -c %s -- " .. host(p) .. " 2>/dev/null")
    local r = tonumber(st:read("*a")); st:close()
    return r or 0
end
-- 补齐内核 vfs_api 里 fs 门面的其余方法。测试台与内核的 fs 面必须**同名同语义**,
-- 否则工具在宿主上跑得过、真机才炸(这正是这台机器的存在意义)。
function F.getName(p) return norm(p):match("[^/]*$") or "" end
function F.getDir(p)
    local n = norm(p)
    local d = n:match("^(.*)/[^/]*$")
    if d == nil or d == "" then return "/" end
    return d
end
function F.combine(a, b)
    b = tostring(b or "")
    if b:sub(1, 1) == "/" then return b end
    if a == nil or a == "" then return b end
    return norm(a .. "/" .. b)
end
function F.isDriveRoot(p) return norm(p):match("^/[^/]*$") ~= nil end
function F.complete(p, opts)
    -- 与 CC fs.complete 同形的补全: 返回 { name..., "/" 结尾表示目录前缀 }。
    local n = norm(p or "")
    local dir, frag = n:match("^(.*)/([^/]*)$")
    if not dir then dir, frag = "", n end
    local h = host(dir == "" and "/" or dir)
    local out = {}
    local f = io.popen("ls -Ap -- " .. h .. " 2>/dev/null")
    if f then
        for line in f:lines() do
            if line:sub(1, #frag) == frag then out[#out + 1] = line end
        end
        f:close()
    end
    table.sort(out)
    return out
end
function F.isReadOnly(p)
    local st = io.popen("[ -w " .. host(p) .. " ] && echo writable")
    local r = st:read("*a"); st:close()
    return r == "" -- 不可写即只读
end
function F.getDrive(p) return norm(p):match("^/([^/]*)") or "" end
function F.getFreeSpace(p)
    local st = io.popen("df -Pk -- " .. host(p) .. " 2>/dev/null | tail -n 1 | awk '{print $4}'")
    local r = tonumber(st:read("*a")); st:close()
    return (r or 0) * 1024
end
function F.getCapacity(p)
    local st = io.popen("df -Pk -- " .. host(p) .. " 2>/dev/null | tail -n 1 | awk '{print $2}'")
    local r = tonumber(st:read("*a")); st:close()
    return (r or 0) * 1024
end
function F.find(p)
    local list = {}
    local function walk(cur)
        for _, n in ipairs(F.list(cur)) do
            local child = F.combine(cur, n)
            if F.isDir(child) then walk(child) else list[#list + 1] = child end
        end
    end
    walk(norm(p))
    local i = 0
    return function() i = i + 1; return list[i] end
end
function F.makeDir(p) os.execute("mkdir -p -- " .. host(p)); return true end
function F.delete(p)
    if F.isDir(p) then os.execute("rm -rf -- " .. host(p)) else os.execute("rm -f -- " .. host(p)) end
    return true
end
function F.copy(a, b)
    os.execute("cp -r -- " .. host(a) .. " " .. host(b)); return true
end
function F.move(a, b)
    os.execute("mv -- " .. host(a) .. " " .. host(b)); return true
end
-- 符号链接 / 硬链接: 用宿主真实 ln/readlink, 使 ln/readlink/realpath/find 在宿主上可验证。
local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
function F.symlink(target, linkpath)
    -- target 是 **VFS 路径**; 以 "/" 开头时前缀测试根, 否则宿主解析这个绝对链接时会跑到真实 /,
    -- 跟随就 ENOENT。readlink 再把它剥回去(见下), 于是工具看到的始终是 VFS 路径。
    local t = target
    if t:sub(1, 1) == "/" then t = ROOT .. t end
    local r = os.execute("ln -s " .. shq(t) .. " " .. shq(host(linkpath)) .. " 2>/dev/null")
    if r ~= true and r ~= 0 then return nil, "cannot create symbolic link" end
    return true
end
function F.readlink(p)
    local h = io.popen("readlink " .. shq(host(p)) .. " 2>/dev/null")
    local r = h:read("*a"); h:close()
    r = (r or ""):gsub("%s+$", "")
    if r == "" then return nil, "not a symbolic link" end
    if ROOT ~= "" and r:sub(1, #ROOT) == ROOT then r = r:sub(#ROOT + 1) end
    return r
end
function F.link(a, b)
    local r = os.execute("ln " .. shq(host(a)) .. " " .. shq(host(b)) .. " 2>/dev/null")
    if r ~= true and r ~= 0 then return nil, "cannot create hard link" end
    return true
end
--- 不跟随最后一段的 chown(内核 fs.lchown 的对应物): `chown -h`。
function F.lchown(p, uid, gid)
    local spec = ""
    if uid ~= nil then spec = spec .. tostring(uid) end
    if gid ~= nil then spec = spec .. ":" .. tostring(gid) end
    if spec == "" then return true end
    return os.execute("chown -h " .. spec .. " -- " .. shq(host(p)) .. " 2>/dev/null") ~= nil
end
--- 不跟随符号链接的 stat(内核 fs.lstat 的对应物)。
function F.lstat(p)
    local h = io.popen("test -L " .. shq(host(p)) .. " && echo l")
    local isLink = h:read("*a"); h:close()
    -- 不存在的路径必须返回 nil(与内核 fs.lstat 一致)。hostAttrs 永远给出一张表, 所以这里
    -- 自己先判存在性 —— 否则任何"用 lstat 判存在性"的工具在宿主上都会与真机不一致。
    if isLink == "" and not F.exists(p) then return nil end
    local a = F.attributes(p)
    if not a then return nil end
    if isLink ~= "" then
        a.kind = "symlink"
        a.isDir = false
        a.size = #(F.readlink(p) or "")
        return a
    end
    a.kind = a.isDir and "dir" or "file"
    return a
end

function F.attributes(p)
    local n = norm(p)
    local sz = F.getSize(p)
    local typebits = F.isDir(p) and 0x4000 or 0x8000
    -- 读宿主真实权限(八进制) -> 低 9 位, 与 ext2 的 mode 语义一致(低 12 位)。
    local func = "stat -c %a -- " .. host(p) .. " 2>/dev/null"
    local h = io.popen(func)
    local perms = tonumber(((h:read("*a") or ""):gsub("%s+$", "")), 8)
    h:close()
    if not perms then perms = F.isDir(p) and tonumber("755", 8) or tonumber("644", 8) end
    -- 读宿主真实 uid/gid, 便于 ls -l / chown 反映变化。
    local hu = io.popen("stat -c %u -- " .. host(p) .. " 2>/dev/null")
    local gu = io.popen("stat -c %g -- " .. host(p) .. " 2>/dev/null")
    local uid = tonumber(((hu:read("*a") or ""):gsub("%s+$", ""))) or 0
    local gid = tonumber(((gu:read("*a") or ""):gsub("%s+$", ""))) or 0
    hu:close(); gu:close()
    -- 时间戳与已分配块数: 真机 ext2 的 attributes 给 mtime/atime/ctime/blocks, 宿主桩也得给,
    -- 否则 ls -l/-s、find -newermt、touch、du 在宿主上的行为与真机对不上。
    local hs = io.popen("stat -c '%X %Y %Z %b' -- " .. host(p) .. " 2>/dev/null")
    local atime, mtime, ctime, blocks = (hs:read("*a") or ""):match("(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
    hs:close()
    return { size = sz, isDir = F.isDir(p), mode = typebits + (perms % tonumber("1000", 8)),
             name = n:match("[^/]+$") or "", uid = uid, gid = gid,
             mtime = tonumber(mtime), atime = tonumber(atime), ctime = tonumber(ctime),
             blocks = tonumber(blocks) }
end

--- 改时间戳(touch 用)。真机是 ext2.setTimes; 宿主用 GNU touch 的 @epoch 形式顶。
function F.setTimes(p, atime, mtime)
    if not F.exists(p) then return nil, "no such file" end
    local h = host(p)
    if atime and mtime and atime == mtime then
        return os.execute("touch -d '@" .. tostring(atime) .. "' " .. h .. " 2>/dev/null") ~= nil
    end
    local ok = true
    if atime then
        ok = os.execute("touch -a -d '@" .. tostring(atime) .. "' " .. h .. " 2>/dev/null") ~= nil and ok
    end
    if mtime then
        ok = os.execute("touch -m -d '@" .. tostring(mtime) .. "' " .. h .. " 2>/dev/null") ~= nil and ok
    end
    return ok
end

function F.chmod(p, mode)
    local h = host(p)
    local ok = os.execute("chmod " .. string.format("%o", (mode or 0) % tonumber("1000", 8)) .. " -- " .. h)
    return ok == true or ok == 0
end

function F.chown(p, uid, gid)
    local h = host(p)
    local spec = ""
    if uid ~= nil then spec = spec .. tostring(uid) end
    if gid ~= nil then spec = spec .. ":" .. tostring(gid) end
    if spec == "" then return true end
    os.execute("chown " .. spec .. " -- " .. h .. " 2>/dev/null")
    return true
end

-- 文件句柄: 同时支持 `.method` 与 `:method`(CC 原生句柄两者皆可)。
local unpack = table.unpack or unpack
local Handle = {}
local function mkHandle(file, name, isTTY)
    local h = { f = file, name = name, isTTY = isTTY or false, kind = "file" }
    local function m(fn)
        return function(...)
            local n = select("#", ...)
            local a = { ... }
            if n > 0 and a[1] == h then return fn(unpack(a, 2, n)) else return fn(unpack(a, 1, n)) end
        end
    end
    h.close     = m(function() file:close() end)
    h.flush     = m(function() file:flush() return true end)
    h.write     = m(function(s) file:write(tostring(s)); file:flush(); return #tostring(s) end)
    h.writeLine = m(function(s) file:write(tostring(s or "") .. "\n"); file:flush(); return #tostring(s or "") + 1 end)
    h.read      = m(function(fmt) return file:read(fmt) end)
    h.readLine = m(function() return file:read("*l") end)
    h.readAll   = m(function() return file:read("*a") end)
    h.getSize   = m(function() return 0 end)
    h.getDeviceName = m(function() return nil end)
    -- seek: 与内核 vfs 包装的 CC 句柄同签名(whence="set"/"cur"/"end")。
    h.seek = m(function(whence, off)
        local p, err = file:seek(whence, off)
        if p == nil then return nil, err end
        return p
    end)
    h.isReadOnly = m(function() return false end)
    h.setEcho   = m(function() end)
    return h
end
-- 保持 Handle.new 兼容内部签名
Handle.new = function(file, name, isTTY) return mkHandle(file, name, isTTY) end

-- ---------------------------------------------------------------
-- 每个进程的 io 门面(捕获该进程 stdio)
-- ---------------------------------------------------------------
local function makeIo(stdio)
    return {
        stdin  = function() return stdio.input end,
        stdout = function() return stdio.output end,
        stderr = function() return stdio.output end,
        write = function(...)
            if stdio.output and stdio.output.write then
                local parts = {}
                for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
                stdio.output:write(table.concat(parts))
            end
        end,
        read = function(...) if stdio.input and stdio.input.read then return stdio.input:read(...) end end,
        flush = function() if stdio.output and stdio.output.flush then stdio.output:flush() end end,
        open = function(p, m)
            return F.open(p, m)
        end,
        type = function(v) return "file" end,
        close = function(v) end,
        lines = function(f) local h, i = F.open(f, "r"), 0; return function() i = i + 1; return h and h:readLine() end end,
    }
end

-- /dev/null(与内核 devtmpfs 的 null 设备一致): 读立即 EOF, 写丢弃。
local NULL_HANDLE = {
    isTTY = false,
    read = function() return nil end,
    readLine = function() return nil end,
    write = function(_, s) return #tostring(s or "") end,
    flush = function() return true end,
    close = function() return true end,
    getDeviceName = function() return nil end,
    seek = function() return 0 end,
    isReadOnly = function() return true end,
}

-- io.open 落在 F.open / fs.open
function F.open(p, mode)
    p = norm(p)
    if p == "/dev/null" then return NULL_HANDLE end
    -- /dev/tty = 调用者自己的控制终端(真机由 boot 注册, 见 kernel/boot.lua);
    -- 测试台上它就是那把假终端句柄, 分页器的宿主自检靠它拿到按键。
    if p == "/dev/tty" and ttyMode then return inputHandle end
    local m = mode or "r"
    local hostp = host(p)
    if m == "r" then
        local f = io.open(hostp, "rb")
        if not f then return nil, "No such file or directory" end
        return Handle.new(f, p)
    elseif m == "w" then
        local f = assert(io.open(hostp, "wb"))
        return Handle.new(f, p)
    elseif m == "a" then
        local f = assert(io.open(hostp, "ab"))
        return Handle.new(f, p)
    elseif m == "r+" or m == "rw" then
        local f = assert(io.open(hostp, "r+b"))
        return Handle.new(f, p)
    end
    return nil, "unsupported mode"
end

-- ---------------------------------------------------------------
-- syscalls(最小桩)
-- ---------------------------------------------------------------
local procs = {}
local curPid = nil -- 调度器当前 resume 的进程(供 job.group/signal.install 定位调用者)
local syscalls = {}
local PIPE = nil -- 内核 pipe 模块(lazy require), 提供 pipe.create
local function pipeCreate()
    if not PIPE then
        package.path = REPO .. "/src/?.lua;" .. package.path
        PIPE = require("kernel.pipe")
    end
    return PIPE.create()
end
syscalls["proc.info"] = function(pid) return procs[pid] end
syscalls["proc.wait"] = function(pid)
    -- 阻塞等待子进程退出(通过 os.sleep 让出调度器, 轮询)。
    while true do
        local p = procs[pid]
        if not p then return -1 end
        if p.status == "dead" or p.status == "error" then
            if p.termSig then return -p.termSig end
            return (p.status == "error" and 1) or (p.exitCode or 0)
        end
        os.sleep(0.01)
    end
end
syscalls["pipe.create"] = function() return pipeCreate() end

-- 信号/作业控制桩: 与内核 signal.lua/process.lua 的语义对齐(编号/默认动作/进程组),
-- 使 sh 的 `&`/jobs/fg/bg/wait/kill %job 能在宿主上被真实验证(前台 tty 部分除外)。
local SIG = {
    [1] = "HUP", [2] = "INT", [3] = "QUIT", [9] = "KILL", [10] = "USR1", [12] = "USR2",
    [13] = "PIPE", [14] = "ALRM", [15] = "TERM", [17] = "CHLD", [18] = "CONT",
    [19] = "STOP", [20] = "TSTP", [21] = "TTIN", [22] = "TTOU",
}
local SIGNO = {}
for n, nm in pairs(SIG) do SIGNO[nm] = n end
local SIG_LIST = {}
for n in pairs(SIG) do SIG_LIST[#SIG_LIST + 1] = n end
table.sort(SIG_LIST)
local STOP_SIGS = { [19] = true, [20] = true, [21] = true, [22] = true }

local function deliver(pid, sig)
    local p = procs[pid]
    if not p then return nil, "no such process: " .. tostring(pid) end
    if p.status == "dead" or p.status == "error" then return true end -- 已死: 无效果但不算错
    -- SIG_IGN(沿内核语义): 被显式忽略的信号直接丢弃, 连停止/终止都不走。
    if p.ignored and p.ignored[sig] then return true end
    if sig == 18 then -- SIGCONT
        if p.status == "stopped" then p.status = "running" end
        return true
    end
    local h = p.handlers and p.handlers[sig]
    if h then pcall(h, sig); return true end
    if sig == 9 or STOP_SIGS[sig] == nil then
        p.termSig = sig
        p.status = "dead"
    else
        p.status = "stopped"
    end
    return true
end

syscalls["signal.list"] = function() return SIG_LIST end
syscalls["signal.name"] = function(n) return SIG[n] or "?" end
syscalls["signal.number"] = function(name)
    return SIGNO[(name or ""):upper():gsub("^SIG", "")]
end
syscalls["signal.kill"] = function(pid, sig) return deliver(pid, sig) end
syscalls["signal.killpg"] = function(pgid, sig)
    local n = 0
    for pid, p in pairs(procs) do
        if p.pgrp == pgid then deliver(pid, sig); n = n + 1 end
    end
    if n == 0 then return nil, "no such process group" end
    return n
end
syscalls["signal.install"] = function(sig, fn)
    local p = procs[curPid]
    if not p then return nil, "no current process" end
    p.handlers = p.handlers or {}
    p.ignored = p.ignored or {}
    -- "ignore"/"default" 与内核 process.setHandler 同一套语义("ignore" 还会跨 spawn 继承)。
    if fn == "ignore" then p.handlers[sig] = nil; p.ignored[sig] = true; return true end
    if fn == "default" then p.handlers[sig] = nil; p.ignored[sig] = nil; return true end
    p.ignored[sig] = nil
    p.handlers[sig] = fn
    return true
end
syscalls["job.group"] = function()
    local p = procs[curPid]
    return p and p.pgrp or 0
end
syscalls["job.setpgid"] = function(pid, pgid)
    local p = procs[pid]
    if not p then return nil, "no such process: " .. tostring(pid) end
    p.pgrp = (not pgid or pgid == 0) and pid or pgid
    return true
end
syscalls["job.setsid"] = function()
    local p = procs[curPid]
    if not p then return nil, "no current process" end
    p.pgrp, p.sid = curPid, curPid
    return curPid
end
syscalls["job.tcsetpgrp"] = function() return true end
syscalls["stdio.set"] = function(i, o) return true end
syscalls["tty.console"] = function() return "tty0" end
syscalls["tty.list"] = function() return { "tty0", "tty1" } end
syscalls["tty.setFocus"] = function() return true end
syscalls["tty.getFocus"] = function() return "tty0" end
-- user.* syscalls 不在这里放桩: 用**真实的** kernel/user.lua(与真机同一份源码), 在 setupRoot()
-- 之后从 /etc 三张表装载并注册。用户管理工具(passwd/useradd/...)的授权与落盘逻辑因此在宿主上也是真的。

-- 挂载/卸载桩: 记录到内存表, 供 `mount`/`umount` 命令在宿主上验证参数与列表。
-- 行为对齐内核 devdisk: 按节点名/UUID 解析设备, 未知设备或 fstype 不符即报错。
local mountTable = {}
local function blkFind(spec)
    local byUuid = spec:sub(1, 5) == "UUID="
    local want = byUuid and spec:sub(6) or spec:gsub("^/dev/", "")
    for _, e in ipairs(syscalls["blkdev.list"]()) do
        if (byUuid and e.uuid == want) or (not byUuid and e.name == want) then return e end
    end
    return nil
end
syscalls["fs.mount"] = function(device, dir, fstype)
    local e = blkFind(device)
    if not e then return nil, device .. ": no such device" end
    local fst = fstype or e.fstype
    if fst ~= e.fstype then return nil, e.node .. " is " .. e.fstype .. ", not " .. fst end
    mountTable[#mountTable + 1] = { device = e.node, dir = dir, fstype = fst, uuid = e.uuid }
    return true, { device = e.node, fstype = fst, uuid = e.uuid }
end
syscalls["fs.umount"] = function(dir)
    for i = #mountTable, 1, -1 do if mountTable[i].dir == dir then table.remove(mountTable, i) end end
    return true
end
syscalls["fs.mounts"] = function()
    local out = {}
    for _, m in ipairs(mountTable) do out[#out + 1] = { root = m.dir, device = m.device, fstype = m.fstype, uuid = m.uuid } end
    return out
end

-- 块设备桩: 电脑自带存储(恒为 sda) + 两个磁盘驱动器, 与真机 devdisk 的字段一致
-- (自带存储 c<电脑ID>, 磁盘 d<磁盘ID>, 且磁盘一律接在自带存储之后按磁盘 ID 升序)。
-- mounted 由当前挂载表算出, 使 lsblk 的 MOUNTPOINT 列可验证。
local blkDevices = {
    { name = "sda",  node = "/dev/sda",  type = "disk", fstype = "ccdisk", uuid = "c1",   size = 1000000, label = "DELIN" },
    { name = "sda1", node = "/dev/sda1", type = "part", fstype = "ext2",   uuid = "c1-1", size = 2097152, role = "root" },
    { name = "sdb",  node = "/dev/sdb",  type = "disk", fstype = "ccdisk", uuid = "d0",   size = 128000,  label = "BOOT" },
    { name = "sdb1", node = "/dev/sdb1", type = "part", fstype = "ext2",   uuid = "d0-1", size = 2097152, role = "root" },
    { name = "sdc",  node = "/dev/sdc",  type = "disk", fstype = "ccdisk", uuid = "d1",   size = 128000 },
    { name = "sdc1", node = "/dev/sdc1", type = "part", fstype = "ext2",   uuid = "d1-1", size = 2097152, role = "data" },
}
syscalls["blkdev.list"] = function()
    local out = {}
    for _, e in ipairs(blkDevices) do
        local copy = {}
        for k, v in pairs(e) do copy[k] = v end
        copy.mounted = {}
        for _, m in ipairs(mountTable) do
            if m.device == e.node then copy.mounted[#copy.mounted + 1] = m.dir end
        end
        out[#out + 1] = copy
    end
    return out
end

-- ---------------------------------------------------------------
-- spawn: 以协程起一个 Delin 工具源码(独立 env), 由顶层的协作式调度器驱动。
--        os.sleep 会 yield 给调度器, 使阻塞(管道/proc.wait)能并发进展。
-- ---------------------------------------------------------------
local nextPid = 0
local curStdio = nil
local REAL_G = _G
local running = {} -- 调度器进程队列 { pid, co, status }
local function spawn(src, name, ppid, uid, gid, argv, opts)
    nextPid = nextPid + 1
    local pid = nextPid
    -- 未显式给 stdio 时继承**父进程**的 stdio(内核 process.spawn 的语义)。
    -- 原来取的是顶层的 curStdio, 于是子进程的输出会跑到测试台自己的 stdout 上,
    -- 用管道/重定向跑 `find -exec`、`xargs` 时宿主与真机对不上。
    local parent = procs[ppid]
    local stdio = (opts and opts.stdio) or (parent and parent.stdio) or curStdio
    -- 环境块(与内核 process.spawn 一致): 继承父进程, opts.env 覆盖/追加;
    -- opts.envClear = true 表示不继承(env -i 的语义, 见 src/bin/env 与 kernel/process.lua)。
    local envvars = {}
    if not (opts and opts.envClear) and parent and parent.envvars then
        for k, v in pairs(parent.envvars) do envvars[k] = v end
    end
    if opts and opts.env then
        for k, v in pairs(opts.env) do envvars[k] = tostring(v) end
    end
    local env = {
        pid = pid, ppid = ppid or 0, uid = uid or 0, gid = gid or 0,
        cwd = (opts and opts.cwd) or "/",
        argv = argv or {}, args = {}, argc = 0, arg0 = "",
        env = envvars, getenv = function(n) return envvars[n] end,
        fs = F, io = makeIo(stdio), syscalls = syscalls,
        print = function(...) end,
    }
    -- 与内核一致的白名单(见 src/kernel/procenv.lua): 测试台不放宽, 否则工具用到名单外的
    -- 全局在宿主上照样能跑, 真机才炸。
    procenv.apply(env)
    -- os.sleep / os.msleep 都让出当前协程(调度器据此切换进程), 模拟内核按事件驱动恢复。
    -- 真机的 os.msleep 来自 cc_hse.ko(逐 HSE 拍让出), 宿主没有那个模块, 这里给个等价桩,
    -- 好让工具走的是真机上那条 msleep 分支。
    env.os.sleep = function() coroutine.yield() end
    env.os.msleep = function() coroutine.yield() end
    if argv then
        env.argv = argv
        env.arg0 = argv[0] or ""
        for i = 1, #argv do env.args[i] = argv[i] end
        env.argc = #argv
    end
    env.spawn = function(s, n, cu, cg, ca, co) return spawn(s, n, pid, cu, cg, ca, co) end
    env._G = env
    -- Lua 5.1: load 收函数, loadstring 收字符串; 5.2: load 亦可收字符串。统一用 compat。
    local loadcompat = _G.load
    local chunk, lerr
    if _VERSION == "Lua 5.1" then
        chunk, lerr = loadstring(src, name or ("proc" .. pid))
        if chunk then setfenv(chunk, env) end
    else
        chunk, lerr = loadcompat(src, name or ("proc" .. pid), "t", env)
    end
    if not chunk then
        procs[pid] = { pid = pid, name = name, status = "error", error = lerr, exitCode = 1 }
        return nil, "load failed: " .. tostring(lerr)
    end
    -- 进程组/会话: 子进程继承父进程的 pgrp/sid(与内核 process.spawn 一致)。
    local pgrp = parent and parent.pgrp or pid
    local sid = parent and parent.sid or 0
    procs[pid] = { pid = pid, ppid = ppid or 0, name = name, status = "running", exitCode = 0,
                   stdio = stdio, pgrp = pgrp, sid = sid, handlers = {}, envvars = envvars,
                   -- umask 子进程继承父进程(与内核 process.spawn 一致), 缺省 022。
                   umask = (parent and parent.umask) or tonumber("022", 8),
                   -- 被忽略的信号同样继承(内核语义): nohup 的 SIG_IGN 要能传给子进程。
                   ignored = (function()
                       local t = {}
                       if parent and parent.ignored then for s in pairs(parent.ignored) do t[s] = true end end
                       if opts and opts.sigIgnore then for s in pairs(opts.sigIgnore) do t[s] = true end end
                       return t
                   end)(),
                   uid = uid or 0, gid = gid or 0, argv = argv or {},
                   cwd = (opts and opts.cwd) or "/" }
    running[#running + 1] = { pid = pid, co = coroutine.create(chunk) }
    return pid
end

-- 进程退出时释放其 stdio 管道端(与内核 process.onExit 一致), 使下游读到 EOF。
-- 只关带 .pipe 标记的句柄, 避免误关宿主 stdout 文件句柄。
local function closeProcPipes(pid)
    local stdio = procs[pid] and procs[pid].stdio
    if not stdio then return end
    if stdio.output and stdio.output.pipe and stdio.output.close then pcall(stdio.output.close) end
    if stdio.input  and stdio.input.pipe  and stdio.input.close  then pcall(stdio.input.close)  end
end

-- 协作式调度器: 轮流 resume 每个未退出进程; 进程 yield(os.sleep)则让位, 下轮再恢复。
-- 被信号杀死/停止的进程(procs[pid].status)不再被 resume —— 对应内核调度器的信号投递。
-- 只剩 stopped 进程时结束调度(宿主无事件循环, 停住的作业被遗弃; 真机由 SIGCONT/fg 恢复)。
local function schedulerRun()
    while true do
        local anyAlive = false
        for _, pr in ipairs(running) do
            local p = procs[pr.pid]
            if p.status == "running" then
                anyAlive = true
                curPid = pr.pid
                local ok, res = coroutine.resume(pr.co)
                curPid = nil
                if not ok then
                    p.status = "error"; p.error = res; p.exitCode = 1
                    io.stderr:write("[harness] " .. (p.name or pr.pid) .. " error: " .. tostring(res) .. "\n")
                    closeProcPipes(pr.pid)
                elseif coroutine.status(pr.co) == "dead" then
                    p.status = "dead"
                    -- 协程返回值即退出码(与内核 process.onExit 一致)。
                    if type(res) == "number" then p.exitCode = res end
                    closeProcPipes(pr.pid)
                end
            end
        end
        if not anyAlive then break end
    end
end

-- ---------------------------------------------------------------
-- 构建 ROOT
-- ---------------------------------------------------------------
local SRCBIN = os.getenv("DELIN_SRCBIN") or (REPO .. "/src/bin")
--- 把 src/bin 下的工具铺进测试台 ROOT/bin。
--- **必须展开 `--#include`**(而不是 cp): 目标机上的产物是拼接后的自包含单文件, 而测试台的
--- 文件系统里没有 /lib 源码树可读 —— 不展开的话, 宿主跑的是"引用了一堆不存在文件"的入口,
--- 真机反而正常, 白白浪费一轮排查。与 build.lua 共用 tools/include.lua, 于是
--- "测试台跑的"与"装到 CC 上的"是同一段源码。
local function copyTool(name)
    local f0 = assert(io.open(SRCBIN .. "/" .. name, "rb"), "cannot read " .. SRCBIN .. "/" .. name)
    local raw = f0:read("*a"); f0:close()
    local src = includeLib.expand(raw, REPO, "src/bin/" .. name)
    local f = assert(io.open(ROOT .. "/bin/" .. name, "w"))
    f:write(src); f:close()
    os.execute("chmod 755 " .. ROOT .. "/bin/" .. name)
end
local function setupRoot()
    os.execute("rm -rf " .. ROOT .. " && mkdir -p " .. ROOT)
    os.execute("mkdir -p " .. ROOT .. "/bin " .. ROOT .. "/etc " .. ROOT .. "/home/alice " .. ROOT .. "/root " .. ROOT .. "/tmp " .. ROOT .. "/mnt/cc")
    for _, f in ipairs({ "cat","clear","cp","ed","grep","head","kill","login","ls","mkdir","mv","rm","sed","sh","sleep","tail","touch","wc","chmod","chown","mount","umount","blkid","lsblk","lp","ps","pgrep","pkill","killall","lua",
                          "passwd","useradd","userdel","usermod","groupadd","groupdel","id","whoami","groups" }) do
        copyTool(f)
    end
    -- 上面是手写白名单(历史遗留)。**再补全 src/bin 下的其余文件**: 维护两份清单必然会漏,
    -- 漏了就在测试台上报 "cannot read /bin/<新工具>"(而真机上是好的), 白白浪费一轮排查。
    do
        local p = io.popen("ls -A " .. SRCBIN)
        if p then
            for f in p:lines() do
                if not f:find("^%.") then copyTool(f) end
            end
            p:close()
        end
    end
    -- 用户库: 格式与真机一致(哈希用内核同一份 user.hash 算, 所以 verify 是真判定)。
    local user = require("kernel.user")
    local function mksecret(pw, salt) return salt .. "$" .. user.hash(salt, pw) end
    local pw = "root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000:Alice:/home/alice:/bin/sh\n"
    local gr = "root:x:0:root\nalice:x:1000:alice\n"
    local sh = "root:" .. mksecret("rootpw", "r00ts4lt") .. "\nalice:" .. mksecret("alicepw", "a1b2c3d4") .. "\n"
    local function w(path, s) local f = assert(io.open(ROOT .. path, "w")); f:write(s); f:close() end
    w("/etc/passwd", pw); w("/etc/group", gr); w("/etc/shadow", sh)
    -- 测试负载: 用户管理自检(scripts/user_test.sh)要用的辅助程序, 真机上由 realmachine.py
    -- 注入到同一个路径, 于是那份自检在两个环境里跑的是同一段脚本。
    os.execute("mkdir -p " .. ROOT .. "/root && cp -f " .. REPO .. "/scripts/user_helper.lua " .. ROOT .. "/root/user_helper.lua")
    w("/etc/hostname", "delin-host\n")
    w("/pub", "public data\n"); w("/secret", "top secret content\n"); w("/readonly", "ro\n")
    -- /long: 40 行的"长文件", 给分页器(more/less)的宿主自检当输入(它们要跨屏才算真跑)
    do
        local t = {}
        for k = 1, 40 do t[k] = string.format("line %02d", k) end
        t[12] = t[12] .. " needle"
        w("/long", table.concat(t, "\n") .. "\n")
    end
    w("/home/alice/x.txt", "alice file\n")
    -- /dev 占位
    os.execute("mkdir -p " .. ROOT .. "/dev " .. ROOT .. "/proc " .. ROOT .. "/sys/class/display")
    os.execute("touch " .. ROOT .. "/dev/null " .. ROOT .. "/dev/lp0") -- 占位(打开走设备桩, 使 ls /dev 一致)
    os.execute("mkdir -p " .. ROOT .. "/lib/modules/" .. VERSION)
end

-- ---------------------------------------------------------------
-- /sys: 用真实内核 sysfs 后端(src/kernel/sysfs.lua)取代宿主目录,
-- 让 `cat /sys/class/display/top/name` 这类命令在宿主上得到与真机一致的行为。
-- 显示设备用一个桩(kernel.display 只被 sysfs 用于 list/get/byName/resize)。
-- ---------------------------------------------------------------
local sysfsDev = {
    id = "monitor:top", type = "monitor", mode = "term", name = "top",
    getSize = function() return 51, 19 end,
}
package.loaded["kernel.display"] = {
    list = function() return { sysfsDev.id } end,
    get = function(id) return id == sysfsDev.id and sysfsDev or nil end,
    byName = function(n) return n == "top" and sysfsDev or nil end,
    resize = function() return true end,
}
-- kernel.vfs_api / procfs / random 装载时会抓全局 fs(与内核同一份源码); 宿主上没有 CC 的 fs,
-- 用宿主门面顶上 —— 必须在 require 之前设好(vfs_api 顶层就取 fs.getName 等)。
_G.fs = _G.fs or F
local vfs = require("kernel.vfs")
require("kernel.sysfs").mount()

-- ---------------------------------------------------------------
-- /proc: 用真实内核 procfs 后端 + 桩进程表(本 harness 的 procs/curPid),
-- 让 ps/pgrep/pkill/killall 在宿主上走与真机完全一致的文件接口。
-- ---------------------------------------------------------------
REAL_G.os.version = REAL_G.os.version or function() return "CraftOS 1.8" end
package.loaded["kernel.process"] = {
    current = function()
        local p = curPid and procs[curPid]
        return { pid = curPid or 0, uid = (p and p.uid) or 0, gid = (p and p.gid) or 0 }
    end,
    -- 特权写(与内核同签名): 宿主 fs 没有权限位, 直接运行即可。
    asRoot = function(fn) return fn() end,
    info = function(pid) return procs[pid] end,
    list = function()
        local out = {}
        for _, p in pairs(procs) do
            if p.status == "running" or p.status == "stopped" then out[#out + 1] = p end
        end
        table.sort(out, function(a, b) return a.pid < b.pid end)
        return out
    end,
    ttyFor = function(pid) return procs[pid] and "/dev/tty0" or nil end,
    fgPgrpFor = function(pid) return procs[pid] and procs[pid].pgrp or nil end,
}
require("kernel.procfs").mount(os.epoch("utc"), VERSION)

--- /sys 与 /proc 下的路径走虚拟后端, 其余仍走宿主文件。
local function vfsFor(p)
    p = norm(p)
    local underSys = (p == "/sys" or p:sub(1, 5) == "/sys/")
    local underProc = (p == "/proc" or p:sub(1, 6) == "/proc/")
    if not underSys and not underProc then return nil end
    return vfs.resolve(p)
end

local hostList, hostExists, hostIsDir, hostIsFile = F.list, F.exists, F.isDir, F.isFile
local hostAttrs, hostSize, hostReadOnly, hostOpen = F.attributes, F.getSize, F.isReadOnly, F.open
function F.list(p)
    local b, r = vfsFor(p)
    if b then return b.list(r) end
    return hostList(p)
end
function F.exists(p)
    local b, r = vfsFor(p)
    if b then return b.exists(r) end
    return hostExists(p)
end
function F.isDir(p)
    local b, r = vfsFor(p)
    if b then return b.isDir(r) end
    return hostIsDir(p)
end
function F.isFile(p)
    local b, r = vfsFor(p)
    if b then return b.exists(r) and not b.isDir(r) end
    return hostIsFile(p)
end
function F.attributes(p)
    local b, r = vfsFor(p)
    if b then
        local a = b.attributes(r)
        if a then a.uid, a.gid, a.mode = 0, 0, a.isDir and tonumber("40555", 8) or tonumber("100444", 8) end
        return a
    end
    return hostAttrs(p)
end
function F.getSize(p)
    local b, r = vfsFor(p)
    if b then return b.getSize(r) end
    return hostSize(p)
end
function F.isReadOnly(p)
    local b, r = vfsFor(p)
    if b then return b.isReadOnly(r) end
    return hostReadOnly(p)
end
function F.open(p, mode)
    local b, r = vfsFor(p)
    if b then return b.open(r, mode or "r") end
    return hostOpen(p, mode)
end

-- ---------------------------------------------------------------
-- 命名管道(FIFO) 的测试台支持
--   宿主上**不能**用真的 mkfifo: 真的 FIFO 阻塞的是整个 lua 进程, 测试台的协作式调度器
--   根本转不动(对端永远没机会跑), 结果只能是死锁。所以这里用**内核同一份 kernel/fifo.lua**
--   在进程内实现: 缓冲、阻塞 open、EOF、broken pipe 的语义与真机完全一致, 而阻塞走的是
--   测试台的 os.sleep(= coroutine.yield), 于是 `cat fifo` 与 `echo x > fifo` 能真正并发跑起来。
--   宿主侧只留一个占位文件, 好让 ls / fs.isFile 之类的路径行为保持自然。
-- ---------------------------------------------------------------
do
    local fifoMod = require("kernel.fifo")
    local fifoOwner = {}      -- 固定 owner: 测试台只有一个"文件系统"
    local fifoPaths = {}      -- 归一化路径 -> true
    local prevOpen, prevAttrs, prevLstat, prevDelete = F.open, F.attributes, F.lstat, F.delete

    function F.mkfifo(p, mode)
        p = norm(p)
        if F.exists(p) then return nil, "file exists" end
        local dir = p:match("^(.*)/[^/]*$")
        if dir == nil or dir == "" then dir = "/" end
        if not F.isDir(dir) then return nil, "parent not a dir" end
        os.execute(": > " .. shq(host(p)))
        fifoPaths[p] = true
        return true
    end
    function F.isFifo(p) return fifoPaths[norm(p)] == true end
    function F.open(p, mode)
        if fifoPaths[norm(p)] then return fifoMod.open(fifoOwner, norm(p), mode or "r") end
        return prevOpen(p, mode)
    end
    function F.attributes(p)
        local a = prevAttrs(p)
        if a and fifoPaths[norm(p)] then
            a.kind, a.isDir, a.size = "fifo", false, 0
        end
        return a
    end
    function F.lstat(p)
        local a = prevLstat(p)
        if a and fifoPaths[norm(p)] then
            a.kind, a.isDir, a.size = "fifo", false, 0
        end
        return a
    end
    function F.delete(p)
        local n = norm(p)
        local isFifo = fifoPaths[n] == true
        if isFifo then
            fifoPaths[n] = nil
            fifoMod.forget(fifoOwner, n)
        end
        return prevDelete(p)
    end
end

setupRoot()

-- DELIN_HARNESS_SEED=<宿主目录>: 把该目录的内容递归铺进测试根(ROOT)。
-- 用于"进程起来之前就得摆好某些文件"的场景 —— 典型是交互式自检要先放一份 ~/.deshrc 或
-- 历史文件, 而 setupRoot 每次都会 rm -rf 掉测试根。测试脚本自己用 mktemp 造好这个目录。
do
    local seed = os.getenv("DELIN_HARNESS_SEED")
    if seed and seed ~= "" then os.execute("cp -a " .. seed .. "/. " .. ROOT .. "/") end
end

-- ---------------------------------------------------------------
-- user.* syscalls: 用真实内核模块(与真机同一份源码)。db 从上面写好的 /etc 三张表解析,
-- 写接口照 syscall 语义授权后特权写回 —— 所以 passwd/useradd/... 在宿主上跑的是真逻辑。
-- ---------------------------------------------------------------
do
    local user = require("kernel.user")
    user.registerSyscalls(user.init(F), F)
    -- 标准正则引擎: 与真机同一份内核源码(kernel/regex.lua) —— grep/sed/ed/expr/pgrep 都用它。
    require("kernel.regex").registerSyscalls()
    -- 内核日志(syslog.* / klog.*): dmesg / logger / syslogd 要用的名表与 ring buffer 统计。
    -- 真机上由 boot 调 klog.registerSyscalls; 测试台漏了它, 于是 dmesg 在宿主上会报
    -- "attempt to call local 'toNum' (a nil value)" —— 这种"只有测试台才有的缺口"必须补,
    -- 否则新写的自检脚本在宿主上跑不过, 只能等到真机那一轮才发现。
    require("kernel.klog").registerSyscalls(require("kernel.modules").syscalls())
    -- user.registerSyscalls 写进的是**内核的** syscall 表(kernel.modules), 而工具拿到的是
    -- 测试台自己那张(proc/job/signal/... 的桩都在这儿) —— 把 user.* 并进来。
    for k, v in pairs(require("kernel.modules").syscalls()) do syscalls[k] = v end
end

-- ---------------------------------------------------------------
-- proc.exec / umask.*: 与内核同一套语义, 但走测试台自己的 spawn 与 F
--   (内核实现绑在 process.spawn 上, 而这里 process 是桩, 所以照着内核的语义另写一份;
--    两边必须对得上, 否则 xargs/nohup/command 在宿主上跑得过、真机才炸)。
-- ---------------------------------------------------------------
syscalls["umask.get"] = function()
    local p = curPid and procs[curPid]
    return (p and p.umask) or tonumber("022", 8)
end
syscalls["umask.set"] = function(mask)
    local p = curPid and procs[curPid]
    if not p then return nil, "umask: no such process" end
    if type(mask) ~= "number" or mask < 0 or mask > tonumber("777", 8) then
        return nil, "umask: mask out of range (0..0777)"
    end
    local old = p.umask or tonumber("022", 8)
    p.umask = math.floor(mask)
    return old
end

do
    local function findInPath(name, pathEnv)
        if name:find("/", 1, true) then return name end
        for dir in tostring(pathEnv or "/bin"):gmatch("[^:]+") do
            local cand = (dir == "/" and "" or dir) .. "/" .. name
            if F.exists(cand) then return cand end
        end
        return nil
    end
    local function parseShebang(line)
        if line:sub(1, 2) ~= "#!" then return nil, nil end
        local rest = line:sub(3):gsub("^[ \t]+", "")
        local interp = rest:match("^(%S+)")
        if not interp then return nil, nil end
        return interp, rest:match("^%S+[ \t]+(.-)[ \t]*$")
    end
    syscalls["proc.exec"] = function(cmd, argv, opts)
        opts = opts or {}
        local me = curPid
        local caller = me and procs[me]
        local pathEnv = (caller and caller.envvars and caller.envvars.PATH) or "/bin"
        local path = findInPath(cmd, pathEnv)
        if not path then return nil, cmd .. ": command not found" end
        if not F.canExecute(path) then return nil, path .. ": permission denied" end
        local fh = F.open(path, "r")
        if not fh then return nil, path .. ": cannot open" end
        local src = fh:readAll(); fh:close()
        local interp, iarg = parseShebang(src:match("^([^\n]*)") or "")
        local childArgv = { [0] = path }
        if interp then
            local prog, arg = interp, iarg
            if interp:match("[^/]+$") == "env" then
                if not arg or arg == "" then return nil, "shebang: env without a program" end
                prog = arg:match("^(%S+)")
                arg = arg:match("^%S+%s+(.*)$")
            end
            local ipath = findInPath(prog, pathEnv)
            if not ipath then return nil, "shebang interpreter not found: " .. prog end
            local ih = F.open(ipath, "r")
            if not ih then return nil, "shebang interpreter: cannot open " .. ipath end
            local isrc = ih:readAll(); ih:close()
            local n = 0
            childArgv = { [0] = ipath }
            if arg and arg ~= "" then n = 1; childArgv[n] = arg end
            n = n + 1; childArgv[n] = path
            for i = 1, #(argv or {}) do n = n + 1; childArgv[n] = argv[i] end
            return spawn(isrc, ipath, me, opts.uid, opts.gid, childArgv, opts)
        end
        for i = 1, #(argv or {}) do childArgv[i] = argv[i] end
        return spawn(src, path, me, opts.uid, opts.gid, childArgv, opts)
    end
end

-- ---------------------------------------------------------------
-- 桩 printer: /dev/lp0 的写入落到 ROOT/printer.out, /sys/class/printer/lp0 提供状态与可写标题。
-- 让 /bin/lp 在宿主上跑完整路径(ccprinter 内核驱动的分页逻辑由 tools/hosttest.lua 单测)。
-- ---------------------------------------------------------------
local printerOut = assert(io.open(ROOT .. "/printer.out", "w"))
local printerTitle = ""
require("kernel.sysfs").registerClass("printer", {
    list = function() return { "lp0" } end,
    attrs = function(e)
        if e ~= "lp0" then return nil end
        return { "name", "type", "size", "paper", "ink", "title" }
    end,
    writable = function(_, a) return a == "title" end,
    get = function(e, a)
        if e ~= "lp0" then return nil end
        if a == "name" then return "top" end
        if a == "type" then return "printer" end
        if a == "size" then return "25x21" end
        if a == "paper" then return "10" end
        if a == "ink" then return "10" end
        if a == "title" then return printerTitle end
        return nil
    end,
    set = function(e, a, v)
        if e ~= "lp0" then return nil, "no such printer: " .. tostring(e) end
        if a ~= "title" then return nil, "read-only attribute: " .. tostring(a) end
        printerTitle = v
        local tf = io.open(ROOT .. "/printer.title", "w")
        tf:write(v)
        tf:close()
        return true
    end,
})
local LP_HANDLE = {
    write = function(_, s) printerOut:write(s); return #tostring(s) end,
    writeLine = function(_, s) printerOut:write(s .. "\n"); return #tostring(s) + 1 end,
    flush = function() return true end,
    close = function() printerOut:close(); return true end,
    read = function() return nil end,
    readLine = function() return nil end,
}
local openBeforeLp = F.open
function F.open(p, mode)
    if norm(p) == "/dev/lp0" then
        if mode and (mode:find("w") or mode:find("a")) then return LP_HANDLE end
        return nil, "write-only device: /dev/lp0"
    end
    return openBeforeLp(p, mode)
end

-- ---------------------------------------------------------------
-- 桩 CC redstone API + 真实的 redstone.ko 模块源码: /sys/class/redstone/<side>/{digital,analog,bundled}。
-- 宿主上没有红石, 输入恒 0; 输出状态由桩保存, 于是"写文件 -> API 读回"的路径与真机一致
-- (scripts/redstone_test.sh 用 /bin/lua 走 API 读回, 故宿主与真机输出相同;
-- 真机与真实 API 的逐项核对见 scripts/redstone_verify.lua)。
-- ---------------------------------------------------------------
local rs = { input = {}, analogIn = {}, bundledIn = {}, output = {}, analogOut = {}, bundledOut = {} }
local RS_SIDES = { "top", "bottom", "left", "right", "front", "back" }
local function rsNum(t, s) return t[s] or 0 end
_G.redstone = {
    getSides = function() return RS_SIDES end,
    getInput = function(s) return rs.input[s] == true end,
    getAnalogInput = function(s) return rsNum(rs.analogIn, s) end,
    getBundledInput = function(s) return rsNum(rs.bundledIn, s) end,
    getOutput = function(s) return rs.output[s] == true end,
    getAnalogOutput = function(s) return rsNum(rs.analogOut, s) end,
    getBundledOutput = function(s) return rsNum(rs.bundledOut, s) end,
    setOutput = function(s, on)
        rs.output[s] = on and true or false
        rs.analogOut[s] = on and 15 or 0
    end,
    setAnalogOutput = function(s, v) rs.analogOut[s] = v; rs.output[s] = v > 0 end,
    setBundledOutput = function(s, v) rs.bundledOut[s] = v end,
}
do
    local f = assert(io.open(REPO .. "/src/modules/redstone.ko"))
    local src = f:read("*a"); f:close()
    local env = setmetatable({ require = require }, { __index = _G })
    local chunk = assert(loadstring(src, "redstone")); setfenv(chunk, env)
    local sysfs = require("kernel.sysfs")
    chunk().init({
        log = function() end,
        registerSysfsClass = function(n, ops) sysfs.registerClass(n, ops) end,
        unregisterSysfsClass = function(n) sysfs.unregisterClass(n) end,
    })
end

-- ---------------------------------------------------------------
-- 运行工具: 顶层进程。argv[0] = 工具名(参数1), args = 其余。
-- ---------------------------------------------------------------
local argsIn = {}
for i = 1, #arg do argsIn[i] = arg[i] end
local toolPath = argsIn[1] or "/bin/sh"
local toolArgs = {}
for i = 2, #argsIn do toolArgs[#toolArgs + 1] = argsIn[i] end

-- 读 stdin(作为脚本内容)。**按字节缓冲**, 不是按行 —— 按行读会吃掉 NUL 与行尾换行信息,
-- 于是 cksum/od/tr 这类"字节级 stdin"的工具在测试台上根本没法与宿主逐字节对照
-- (以前只能用文件操作数绕开)。readLine/read(n)/read("*a") 都从这个游标上取。
local stdinData = io.read("*a") or ""
local stdinPos = 1
-- DELIN_HARNESS_TTY=1: 把 stdin 伪装成终端, 让 sh 走交互式分支(测 PS1/PS2 提示符)。
-- **提示符处按 ^C**: 输入里以 `\3`(真 ^C 字节, 见 scripts/sh_intr_test.sh) 结尾的一行表示
-- "用户打了一半之后按了中断键"; 单独一行 `\3` 就是"空行上按了中断键"。内核那边是两件事一起
-- 发生(kernel/tty.lua 的 tty.ctrlC): 行规程丢掉当前行、读返回 ("", "intr"); 同时给 tty 前台
-- 进程组投 SIGINT。宿主测试台照这两件事一起模拟 —— 少了投信号那一半, "提示符处的 SIGINT 被漏到
-- 下一轮"这类 bug 在宿主上就复现不出来(见 src/bin/sh 交互循环里那段注释); 少了第二个返回值,
-- "PS2 续行下按 ^C 能不能取消整条输入"就测不了。
local ttyMode = os.getenv("DELIN_HARNESS_TTY") == "1"
-- 由下面的引导代码填: 把 SIGINT 投给 tty 前台进程组(此时即顶层 sh 那一组)。
local ttyForegroundIntr = function() end
local ttyRaw = false -- 原始模式(分页器 more/less 用; 见下面 inputHandle.setRaw)
inputHandle = {
    isTTY = ttyMode,
    -- 真 tty 句柄有 getDeviceName(见 kernel/tty.lua 的 openHandle): sh 靠它判断"有没有作业控制"。
    getDeviceName = ttyMode and function() return "tty0" end or nil,
    -- 原始模式(内核 tty 的 setRaw 的等价物): 进了原始模式后, read(n) 就是"读 n 个字节",
    -- 测试脚本里直接写空格/q 这类按键即可驱动分页器(不必回车)。
    setRaw = function(_, enable)
        ttyRaw = (enable ~= false)
        return true
    end,
    isRaw = function() return ttyRaw end,
    getSize = function() return 51, 19 end, -- CC 缺省终端尺寸(与 kernel tty 的缺省一致)
}
local function rawStdinLine()
    if stdinPos > #stdinData then return nil end
    local nl = stdinData:find("\n", stdinPos, true)
    if not nl then
        local line = stdinData:sub(stdinPos)
        stdinPos = #stdinData + 1
        return line
    end
    local line = stdinData:sub(stdinPos, nl - 1)
    stdinPos = nl + 1
    return line
end
inputHandle.readLine = function()
    local line = rawStdinLine()
    if ttyMode and line and line:sub(-1) == "\3" then
        ttyForegroundIntr()
        -- ^C 丢掉当前行(连已打进缓冲的那半截); "intr" 让 shell 把整条输入作废, 见 kernel/tty.lua
        return "", "intr"
    end
    return line
end
-- read 同时收点号与冒号: 内核里所有 stdin 句柄(管道/文件/tty)都是普通 Lua 表, 方法吃冒号,
-- 工具一律写 `h:read(n)`。桩只认点号的话, 按内核写法写的工具(tee)在测试台上会把 4096 当成
-- self 传进来 -> tonumber(table)=nil -> 返回空串 -> 无限循环挂死(已经踩过一次)。
local function readFmt(a, b) return (a == inputHandle) and b or a end
inputHandle.read = function(a, b)
    local fmt = readFmt(a, b)
    if stdinPos > #stdinData then return nil end
    if fmt == nil or fmt == "*l" or fmt == "l" then return inputHandle.readLine() end
    if fmt == "*a" or fmt == "a" then
        local rest = stdinData:sub(stdinPos)
        stdinPos = #stdinData + 1
        return rest
    end
    local n = tonumber(fmt)
    if not n or n <= 0 then return "" end
    -- 原始模式下的 ^C: 内核 tty 把它变成"打断阻塞中的 read"(SIGINT 投给前台进程组 +
    -- 让 rawRead 返回 nil,"interrupted", 见 kernel/tty.lua)。测试台照抄这一条, 于是
    -- 行编辑器(desh)的 ^C 路径在宿主上也能测。
    if ttyMode and ttyRaw and n == 1 and stdinData:sub(stdinPos, stdinPos) == "\3" then
        stdinPos = stdinPos + 1
        ttyForegroundIntr()
        return nil, "interrupted"
    end
    if stdinPos + n - 1 > #stdinData then
        local rest = stdinData:sub(stdinPos)
        stdinPos = #stdinData + 1
        return rest ~= "" and rest or nil
    end
    local chunk = stdinData:sub(stdinPos, stdinPos + n - 1)
    stdinPos = stdinPos + n
    return chunk
end
inputHandle.readAll = function() return inputHandle.read("*a") end

local outputHandle = Handle.new(io.stdout, "<stdout>")
-- 顶层 stdout = 内核的**终端句柄**, 所以照 src/kernel/tty.lua 的约定来: write 吃冒号, 参数缺省
-- 当空串。工具里写成 `h.write(chunk)` 时 chunk 落到 self 上、s 是 nil, 于是静默写空串 ——
-- 与真机终端上的表现完全一致(tee 曾经就这样: FILE 写了, 屏幕上什么都没有)。
-- 别改回"点号冒号都收": 那样这一类 bug 就只有真机上才露头了(文件句柄两种都收是另一回事,
-- 见 kernel/vfs.lua 的 wrapCCHandle)。
outputHandle.write = function(self, s)
    s = tostring(s or "")
    io.stdout:write(s)
    io.stdout:flush()
    return #s
end
outputHandle.writeLine = function(self, s) return outputHandle:write(tostring(s or "") .. "\n") end
-- 假终端模式下 stdout 也是"终端"(分页器 more/less 靠 isTTY 判断要不要分页;
-- 真机上 stdout 是 tty 字符设备, isTTY 由 kernel/tty.lua 给)。
if ttyMode then
    outputHandle.isTTY = true
    outputHandle.getSize = function() return 51, 19 end
    outputHandle.setRaw = function() return true end
end

curStdio = { input = inputHandle, output = outputHandle }

local tsrc = F.open(toolPath, "r")
if not tsrc then
    io.stderr:write("harness: cannot read " .. toolPath .. "\n")
    os.exit(1)
end
local src = tsrc:readAll(); tsrc:close()

local argv0 = { [0] = toolPath }
for i = 1, #toolArgs do argv0[i] = toolArgs[i] end
-- DELIN_HARNESS_UID/GID: 顶层工具的 uid/gid(默认 root), 用于验证普通用户视角的权限行为
-- (如 alice 跑 passwd 改自己密码 / 试改别人的 / 被拒绝建用户)。
local topUid = tonumber(os.getenv("DELIN_HARNESS_UID") or "")
local topGid = tonumber(os.getenv("DELIN_HARNESS_GID") or "")
local topPid = spawn(src, toolPath, nil, topUid, topGid, argv0, { cwd = "/" })
-- tty 前台进程组 = 顶层那组(交互式 sh 会把自己那条进程组设成 tty 前台)。
ttyForegroundIntr = function()
    local pgid = procs[topPid] and procs[topPid].pgrp
    for pid, p in pairs(procs) do
        if p.pgrp == pgid then deliver(pid, 2) end
    end
end

-- 运行协作式调度器, 驱动顶层进程及其 spawn 出的子进程(管道/作业控制)。
schedulerRun()

-- flush
io.stdout:flush()
-- 顶层进程的退出码 = 工具的退出码(与内核一致), 便于脚本按 $? 断言。
local top = procs[topPid]
os.exit((top and top.exitCode) or 0)
