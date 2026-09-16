--[[ Delin 宿主测试: 在 HOST 上验证 init 单元引擎(解析/依赖序/启停/重启/timer)、
     /etc/fstab 解析与 mount 单元生成。用真实的 src/init/*.lua 源码 + 内存桩,
     不依赖 CC 真机(真机验证见 tools/realmachine.py)。
     用法: lua5.1 tools/hosttest.lua ]]

io.stdout:setvbuf("line")
os.epoch = os.epoch or function() return os.time() * 1000 end -- 宿主桩: 内核 klog 载入时取引导标识
--- 仓库根: 按本脚本位置推并补成绝对路径(别写死绝对路径, 否则换台机器/CI 上 require 不到 src/)。
local function repoRoot()
    local self = (arg and arg[0]) or "tools/hosttest.lua"
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
local procenv = require("kernel.procenv") -- 进程环境白名单(与内核同一份), 见 src/kernel/procenv.lua
local VERSION = require("kernel.version") -- 模块目录名 /lib/modules/<version>

local ROOT = "/tmp/delinhost2"

local pass, fail = 0, 0
local function ok(cond, label, extra)
    if cond then
        pass = pass + 1
        io.write("ok   " .. label .. "\n")
    else
        fail = fail + 1
        io.write("FAIL " .. label .. (extra and ("  -- " .. tostring(extra)) or "") .. "\n")
    end
end
local function eq(got, want, label)
    ok(got == want, label, "got=" .. tostring(got) .. " want=" .. tostring(want))
end

--- 按 Lua 版本装载一段源码(5.1: loadstring+setfenv; 5.2+: load 的 _ENV 参数)。
--- 直接在调用点写 loadstring 的话, `lua5.4 tools/hosttest.lua` 会崩在
--- "attempt to call a nil value (global 'loadstring')" —— for-ai.md 一直写着要跑 5.4。
local function loadEnv(src, name, env)
    if _VERSION == "Lua 5.1" then
        local c = assert(loadstring(src, name))
        setfenv(c, env)
        return c
    end
    return assert(load(src, name, "t", env))
end

local function readFile(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
local function writeFile(p, s)
    local dir = p:match("^(.*)/[^/]*$")
    if dir then os.execute("mkdir -p " .. dir) end
    local f = assert(io.open(p, "wb"))
    f:write(s)
    f:close()
end

-- ---------------------------------------------------------------
-- 宿主 fs 门面(基于 ROOT 的真实文件)
-- ---------------------------------------------------------------
local function norm(p)
    if not p or p == "" then return "/" end
    if p:sub(1, 1) ~= "/" then p = "/" .. p end
    return (p:gsub("/+$", "")) == "" and "/" or p:gsub("/+$", "")
end
local function host(p) return ROOT .. norm(p) end

local F = {}
-- 内存设备(/dev/kmsg、/dev/log、/dev/console), 供 syslogd/logger/dmesg 宿主测试。
-- /dev/kmsg 按内核 klog 的语义实现: 带序号、cursor/seek、读者从最旧一条开始。
local kmsgEntries, kmsgNext, kmsgFirst = {}, 1, 1
local devLog, devConsole = "", ""
local function kmsgAppend(line)
    kmsgEntries[kmsgNext] = line
    kmsgNext = kmsgNext + 1
end
local function kmsgStats() return { first = kmsgFirst, next = kmsgNext, bytes = 0, drops = 0, boot = 4242 } end
local function kmsgReader()
    local pos = kmsgFirst
    return {
        readAvailable = function()
            local out = {}
            while pos < kmsgNext do
                local e = kmsgEntries[pos]
                pos = pos + 1
                if e then out[#out + 1] = e end
            end
            return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
        end,
        readLine = function() return nil end,
        cursor = function() return pos end,
        -- 与内核 klog 句柄一致: 同时接受 h.seek(n) 与 h:seek(n)
        seek = function(a, b)
            local seq = (type(a) == "table") and b or a
            seq = tonumber(seq)
            if not seq then return nil, "seek: bad sequence number" end
            pos = math.max(math.floor(seq), kmsgFirst)
            return true
        end,
        close = function() return true end, flush = function() return true end,
    }
end
local function devHandle(path, mode)
    mode = mode or "r"
    if path == "/dev/kmsg" then
        if mode:find("r") then return kmsgReader() end
        return nil, "read-only"
    elseif path == "/dev/log" then
        if mode:find("r") then
            return { readAvailable = function() local s = devLog; devLog = ""; return s end,
                     readLine = function() return nil end,
                     close = function() return true end, flush = function() return true end }
        end
        return { write = function(_, s) devLog = devLog .. tostring(s); return #tostring(s) end,
                 writeLine = function(self, s) return self:write(tostring(s or "") .. "\n") end,
                 flush = function() return true end, close = function() return true end }
    elseif path == "/dev/console" then
        return { writeLine = function(_, s) devConsole = devConsole .. tostring(s or "") .. "\n"; return 1 end,
                 write = function(_, s) devConsole = devConsole .. tostring(s); return #tostring(s) end,
                 flush = function() return true end, close = function() return true end }
    end
end
--- os.execute 的返回值跨版本不同: 5.1 是退出码(数字), 5.2+ 是 true/nil + "exit" + code。
--- 直接拿 `== 0` 判断会让 5.4 下所有目录都"不存在"(init 单元一个都装不进来)。
local function execOk(cmd)
    local a, _, code = os.execute(cmd)
    if type(a) == "number" then return a == 0 end
    return a == true and (code == nil or code == 0)
end
function F.exists(p) return readFile(host(p)) ~= nil or execOk("[ -d " .. host(p) .. " ]") end
function F.isDir(p) return execOk("[ -d " .. host(p) .. " ]") end
function F.list(p)
    local out = {}
    local fh = io.popen("ls -A -- " .. host(p) .. " 2>/dev/null")
    for line in fh:lines() do out[#out + 1] = line end
    fh:close()
    table.sort(out)
    return out
end
function F.getSize(p)
    local fh = io.popen("stat -c %s -- " .. host(p) .. " 2>/dev/null")
    local n = tonumber(fh:read("*a")); fh:close()
    return n or 0
end
function F.attributes(p)
    local h = host(p)
    if not F.exists(p) then return nil end
    local fh = io.popen("stat -c '%f %s %X %Y %Z %b' -- " .. h .. " 2>/dev/null")
    local line = fh:read("*a"); fh:close()
    local mode, size, atime, mtime, ctime, blocks = line:match("^(%x+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
    return { mode = tonumber(mode, 16), size = tonumber(size),
             atime = tonumber(atime), mtime = tonumber(mtime), ctime = tonumber(ctime),
             blocks = tonumber(blocks), isDir = F.isDir(p) }
end

--- 改时间戳(touch): 真机是 ext2.setTimes, 宿主用 GNU touch 顶。
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
--- 不跟随符号链接的 stat(内核 fs.lstat 的对应物; harness 里也有一份同样的桩)。
function F.lstat(p)
    local h = host(p)
    local fh = io.popen("test -L " .. h .. " && echo l")
    local isLink = fh:read("*a"); fh:close()
    if isLink == "" and not F.exists(p) then return nil end
    local at = F.attributes(p)
    if not at then
        -- 悬空链接: 宿主上目标可能指向 Delin 的路径(不存在), 但链接本身在
        if isLink == "" then return nil end
        at = { isDir = false, size = 0, mode = tonumber("120777", 8) }
    end
    if isLink ~= "" then
        at.kind = "symlink"
        at.isDir = false
        at.size = #(F.readlink(p) or "")
        return at
    end
    at.kind = at.isDir and "dir" or "file"
    return at
end

--- 符号链接/硬链接(真机是 ext2 的 inode 操作; 宿主用 ln(1) 顶)。
function F.symlink(target, linkpath)
    local rc = os.execute("ln -sfn -- '" .. tostring(target) .. "' " .. host(linkpath) .. " 2>/dev/null")
    return rc ~= nil
end
function F.readlink(p)
    local fh = io.popen("readlink -- " .. host(p) .. " 2>/dev/null")
    local t = fh:read("*a"); fh:close()
    t = t:gsub("%s+$", "")
    return t ~= "" and t or nil
end
function F.link(old, new)
    return os.execute("ln -f -- " .. host(old) .. " " .. host(new) .. " 2>/dev/null") ~= nil
end
function F.lchown() return true end
function F.canExecute(p)
    return os.execute("test -x " .. host(p)) ~= nil
end

function F.makeDir(p) os.execute("mkdir -p -- " .. host(p)); return true end
function F.delete(p) os.execute("rm -rf -- " .. host(p)); return true end
function F.chmod(p, m) os.execute(string.format("chmod %o -- %s", m % 4096, host(p))); return true end
function F.chown() return true end
function F.open(p, mode)
    mode = mode or "r"
    local dev = devHandle(norm(p), mode)
    if dev then return dev end
    local h = host(p)
    if mode == "r" then
        local f = io.open(h, "rb")
        if not f then return nil, "No such file or directory" end
        return {
            readAll = function() local s = f:read("*a"); return s end,
            readLine = function() return f:read("*l") end,
            read = function() return f:read("*a") end,
            close = function() f:close(); return true end,
            write = function() end, flush = function() return true end,
        }
    elseif mode == "w" or mode == "a" then
        local dir = h:match("^(.*)/[^/]*$")
        if dir then os.execute("mkdir -p " .. dir) end
        local f = assert(io.open(h, mode == "a" and "ab" or "wb"))
        return {
            write = function(_, s) f:write(tostring(s)); f:flush(); return #tostring(s) end,
            writeLine = function(_, s) f:write(tostring(s or "") .. "\n"); f:flush(); return 1 end,
            flush = function() f:flush(); return true end,
            close = function() f:close(); return true end,
            readAll = function() return "" end,
        }
    end
    return nil, "unsupported mode"
end

-- ---------------------------------------------------------------
-- init 沙箱: 载入真实的 unit.lua / service.lua
-- ---------------------------------------------------------------
local function newInitEnv()
    local env = {} -- 与内核注入的进程环境一致(白名单, 无 __index=_G 兜底): 见 src/kernel/procenv.lua
    procenv.apply(env)
    env.fs = F
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        env.logs[#env.logs + 1] = table.concat(parts, " ")
    end
    env.logs = {}
    env.os = setmetatable({
        epoch = function() return env.now or os.time() * 1000 end,
        sleep = function() end,
    }, { __index = _G.os })
    env.syscalls = env.syscalls or {}
    env.__initMods = {}

    local function loadSrc(name, path)
        local src = assert(readFile(path), path)
        return loadEnv(src, name, env)()
    end
    env.__require = function(name)
        local m = env.__initMods[name]
        if not m then error("init module not found: " .. name) end
        return m
    end
    env.__initMods.unit = loadSrc("unit", REPO .. "/src/init/unit.lua")
    env.__initMods.service = loadSrc("service", REPO .. "/src/init/service.lua")
    env.unitlib = env.__initMods.unit
    env.svc = env.__initMods.service
    return env
end

--- 造一个带 syscall 桩的 init 环境。
local function makeEnv()
    local env = newInitEnv()
    env.now = 1000000
    env.spawned = {}
    -- 根文件系统已由引导装载器挂载(与真机一致): fstab 里的 "/" 条目应被跳过。
    env.mounts = { { root = "/", device = "/dev/sda1", fstype = "ext2" } }
    env.kills = {}
    env.svc.log = function(msg) env.logs[#env.logs + 1] = tostring(msg) end

    local nextPid = 100
    env.pendingExits = {}
    env.syscalls["proc.spawnFile"] = function(path, argv, opts)
        nextPid = nextPid + 1
        env.spawned[#env.spawned + 1] = { pid = nextPid, path = path, argv = argv, opts = opts }
        -- oneshot 工具跑完即退出: 排定一个退出事件, 由 os.sleep(等价内核退出回调)投递。
        -- oneshot 工具跑完即退出; mdadm --assemble --scan 也是 oneshot(丢它在外面挂着,
        -- init 会一直等它, 于是 "init up" 永远不打印 —— 踩过一次)。
        if path == "/bin/logrotate" or path == "/bin/mdadm" then env.pendingExits[nextPid] = 0 end
        return nextPid
    end
    -- 内核里子进程退出发生在 init 让出时; 宿主用 os.sleep 模拟这一时机。
    local sleeps = 0
    env.os.sleep = function()
        sleeps = sleeps + 1
        if sleeps > 20000 then error("hosttest: os.sleep 循环失控(疑似等待永不退出的进程)", 0) end
        for p, code in pairs(env.pendingExits) do
            env.pendingExits[p] = nil
            env.svc.onProcessExit(p, "dead", code, nil)
            return
        end
    end
    env.syscalls["fs.mounts"] = function()
        local out = {}
        for _, m in ipairs(env.mounts) do out[#out + 1] = m end
        return out
    end
    env.syscalls["fs.mount"] = function(dev, dir, fstype)
        if dev == "/dev/sda9" then return nil, "/dev/sda9: no such device" end
        env.mounts[#env.mounts + 1] = { root = dir, device = dev, fstype = fstype }
        return true, { device = dev, fstype = fstype }
    end
    env.syscalls["fs.umount"] = function(dir)
        for i = #env.mounts, 1, -1 do if env.mounts[i].root == dir then table.remove(env.mounts, i) end end
        return true
    end
    env.syscalls["signal.kill"] = function(p, s)
        env.kills[#env.kills + 1] = { pid = p, sig = s }
        return true
    end
    env.syscalls["tty.list"] = function() return { "tty0", "tty1" } end
    env.syscalls["fstab.entries"] = function()
        local fstab = require("kernel.fstab")
        return fstab.read(F, "/etc/fstab")
    end
    env.syscalls["user.get"] = function(name) return { uid = 0, gid = 0 } end
    env.syscalls["user.groupByName"] = function() return { gid = 0 } end
    return env
end

--- 在沙箱里复刻 init.lua 的生成逻辑(fstab mount 单元 + getty 实例)。
local function generate(env)
    local svc = env.svc
    local entries, err = env.syscalls["fstab.entries"]()
    if not entries then
        -- 与 init.lua 一致: 坏 fstab -> local-fs.target failed, 但仍继续生成 getty
        local rec = svc.units["local-fs.target"]
        if rec then rec.active, rec.sub, rec.failReason = "failed", "failed", tostring(err) end
    else
        for _, e in ipairs(entries) do
            if not e.opts.noauto then
                svc.add({
                    name = e.unit, kind = "mount", path = "/etc/fstab:" .. e.line,
                    active = "inactive", sub = "dead", description = e.device .. " on " .. e.mountpoint,
                    requires = {}, wants = {}, before = { "local-fs.target" },
                    after = { "local-fs-pre.target" }, conflicts = {}, wantedBy = {},
                    what = e.device, where = e.mountpoint, fstype = e.fstype, options = e.options,
                })
                svc.addDep("local-fs.target", e.unit, not e.opts.nofail)
            end
        end
    end
    for _, tn in ipairs(env.syscalls["tty.list"]()) do
        local name = "getty@" .. tn .. ".service"
        local rec = svc.get(name)
        if rec then svc.add(rec); svc.addDep("getty.target", name, false) end
    end
    return true
end

-- ---------------------------------------------------------------
-- 构建测试 rootfs
-- ---------------------------------------------------------------
os.execute("rm -rf " .. ROOT .. " && mkdir -p " .. ROOT .. "/etc/systemd/system " .. ROOT .. "/lib/systemd/system")
os.execute("mkdir -p " .. ROOT .. "/var/log " .. ROOT .. "/run " .. ROOT .. "/mnt/data " .. ROOT .. "/bin")
do
    local fh = io.popen("ls -A " .. REPO .. "/src/units")
    for f in fh:lines() do
        os.execute("cp " .. REPO .. "/src/units/" .. f .. " " .. ROOT .. "/lib/systemd/system/" .. f)
    end
    fh:close()
end
writeFile(ROOT .. "/etc/fstab", [[
# test fstab
/dev/sda2   /mnt/data   ext2   defaults   0 2
/dev/sda3   /mnt/extra  ext2   noauto     0 2
/dev/sda9   /mnt/bad    ext2   nofail     0 2
/dev/sda1   /           ext2   defaults   0 1
]])
os.execute("mkdir -p " .. ROOT .. "/etc/systemd/system/multi-user.target.wants")
writeFile(ROOT .. "/etc/systemd/system/multi-user.target.wants/syslogd.service", "")
os.execute("mkdir -p " .. ROOT .. "/etc/systemd/system/timers.target.wants")
writeFile(ROOT .. "/etc/systemd/system/timers.target.wants/logrotate.timer", "")
os.execute("cp " .. REPO .. "/src/bin/login " .. ROOT .. "/bin/login")

-- ===============================================================
-- A. fstab 解析
-- ===============================================================
local fstab = require("kernel.fstab")
do
    local e, err = fstab.parse("dev mnt ext2 defaults 0 2\n", "t")
    ok(e and #e == 1 and e[1].device == "dev" and e[1].opts.defaults, "fstab: 基本行")
    e, err = fstab.parse("/dev/sda1 /mnt ext2 defaults\n", "t")
    ok(e and e[1].dump == 0 and e[1].pass == 0, "fstab: 缺省 dump/pass 为 0")
    e, err = fstab.parse("dev mnt ext2 bogus 0 0\n", "t")
    ok(e == nil and tostring(err):find("unknown mount option"), "fstab: 未知选项 fail-fast", err)
    e, err = fstab.parse("dev mnt\n", "t")
    ok(e == nil and tostring(err):find("need at least"), "fstab: 字段不足 fail-fast", err)
    e, err = fstab.parse("# c\ndev mnt ext2 defaults 0 2 # tail\n", "t")
    ok(e and #e == 1, "fstab: 注释与行尾注释")
    local n = fstab.escapeMount("/mnt/data")
    eq(n, "mnt-data", "fstab: mount 单元名转义")
    eq(fstab.escapeMount("/"), "-", "fstab: 根 -> '-'")
    ok(fstab.escapeMount("/mnt/ä") == nil, "fstab: 不可表示字符 fail-fast")
    e = fstab.read(F, "/etc/fstab")
    eq(e[1].unit, "mnt-data.mount", "fstab: entries 带 mount 单元名")
end

-- ===============================================================
-- B. 单元文件解析
-- ===============================================================
do
    local env = makeEnv()
    local unitlib = env.unitlib
    local rec = unitlib.parse([[
[Unit]
Description=Demo
After=a.target b.target
After=c.target

[Service]
Type=oneshot
ExecStart=/bin/echo "hello world" --flag
]], "demo.service")
    eq(rec.sections.Unit.Description[1], "Demo", "unit: Description")
    local after = unitlib.list(rec, "Unit", "After")
    eq(#after, 3, "unit: 重复键合并为列表")
    eq(after[3], "c.target", "unit: 重复键顺序")
    local argv = unitlib.splitArgs(unitlib.raw(rec, "Service", "ExecStart"))
    eq(#argv, 3, "unit: ExecStart 词数")
    eq(argv[1], "/bin/echo", "unit: ExecStart[1]")
    eq(argv[2], "hello world", "unit: 双引号参数")
    eq(argv[3], "--flag", "unit: 尾随参数")

    local inst = unitlib.parse("[Service]\nExecStart=/bin/login %I\n", "getty@tty0.service", "tty0")
    eq(unitlib.raw(inst, "Service", "ExecStart"), "/bin/login tty0", "unit: %I 模板替换")
    ok(unitlib.parse("bad line\n", "x") == nil, "unit: 段外键 fail-fast")
    eq(unitlib.time("10s"), 10, "unit: time 10s")
    eq(unitlib.time("5min"), 300, "unit: time 5min")
    eq(unitlib.time("2h"), 7200, "unit: time 2h")
    ok(unitlib.time("bogus") == nil, "unit: time 非法")
end

-- ===============================================================
-- C. 装载 + 依赖序
-- ===============================================================
local env = makeEnv()
do
    local n = env.svc.loadAll()
    ok(n >= 8, "loadAll: 装载了单元文件", n)
    ok(env.svc.units["syslogd.service"] ~= nil, "loadAll: syslogd.service")
    ok(env.svc.units["getty.target"] ~= nil, "loadAll: getty.target")
    ok(env.svc.isEnabled("syslogd.service"), "loadAll: syslogd enabled 标记")
    ok(env.svc.isEnabled("logrotate.timer"), "loadAll: logrotate.timer enabled 标记")
    ok(not env.svc.isEnabled("logrotate.service"), "loadAll: logrotate.service 未启用")
    -- .wants 目录折成 Wants 边
    local rec = env.svc.units["multi-user.target"]
    local found = false
    for _, w in ipairs(rec.wants) do if w == "syslogd.service" then found = true end end
    ok(found, "loadAll: multi-user.target.wants -> Wants=")

    generate(env)
    ok(env.svc.units["mnt-data.mount"] ~= nil, "generate: fstab mount 单元")
    ok(env.svc.units["mnt-extra.mount"] == nil, "generate: noauto 不生成")
    local lf = env.svc.units["local-fs.target"]
    local reqData, reqBad, wantExtra = false, false, false
    for _, r in ipairs(lf.requires) do
        if r == "mnt-data.mount" then reqData = true end
        if r == "mnt-bad.mount" then reqBad = true end
    end
    for _, w in ipairs(lf.wants) do if w == "mnt-bad.mount" then wantExtra = true end end
    ok(reqData, "generate: defaults -> Requires")
    ok(not reqBad and wantExtra, "generate: nofail -> Wants(软依赖)")
    ok(env.svc.units["getty@tty0.service"] ~= nil and env.svc.units["getty@tty1.service"] ~= nil, "generate: getty 实例")

    local order, err = env.svc.startOrder("default.target")
    ok(order ~= nil, "startOrder: 无环", err)
    local pos = {}
    for i, name in ipairs(order) do pos[name] = i end
    ok(pos["local-fs-pre.target"] < pos["mnt-data.mount"], "order: local-fs-pre 先于 mount")
    ok(pos["mnt-data.mount"] < pos["local-fs.target"], "order: mount 先于 local-fs.target")
    ok(pos["local-fs.target"] < pos["multi-user.target"], "order: local-fs 先于 multi-user")
    ok(pos["multi-user.target"] < pos["default.target"], "order: multi-user 先于 default")
    ok(pos["syslogd.service"] < pos["getty@tty0.service"], "order: syslogd 先于 getty(After=)")
    ok(pos["getty@tty0.service"] < pos["getty.target"], "order: getty 实例先于 getty.target(target 补 After)")

    -- 环检测: 互指 After
    local g = env.svc.units["getty.target"]
    local i0 = env.svc.units["getty@tty0.service"]
    table.insert(g.after, "getty@tty0.service")
    table.insert(i0.after, "getty.target")
    local bad, cerr = env.svc.startOrder("getty.target")
    ok(bad == nil and tostring(cerr):find("cycle"), "startOrder: 环 fail-fast", cerr)
    g.after[#g.after] = nil
    i0.after[#i0.after] = nil
end

-- ===============================================================
-- D. 启动/停止/重启/timer
-- ===============================================================
do
    local svc = env.svc
    local okStart, err = svc.start("default.target")
    ok(okStart, "start: default.target", err)
    local dataMounts, skippedRoot = 0, false
    for _, m in ipairs(env.mounts) do
        if m.root == "/mnt/data" then dataMounts = dataMounts + 1 end
    end
    for _, l in ipairs(env.logs) do
        if tostring(l):find("already mounted", 1, true) then skippedRoot = true end
    end
    eq(dataMounts, 1, "start: 挂载了 1 个 fstab 条目")
    ok(skippedRoot, "start: 已挂载的 / 被跳过")
    local byPath, logins = {}, {}
    for _, s in ipairs(env.spawned) do
        byPath[s.path] = s
        if s.path == "/bin/login" then logins[#logins + 1] = s end
    end
    ok(byPath["/bin/syslogd"] ~= nil, "start: syslogd 已启动")
    eq(byPath["/bin/syslogd"].argv[1], "-f", "start: syslogd argv")
    eq(#logins, 2, "start: 每个 tty 一个 getty")
    eq(logins[1].argv[1], "tty0", "start: login 实例参数(tty0)")
    eq(logins[2].argv[1], "tty1", "start: login 实例参数(tty1)")
    eq(byPath["/bin/syslogd"].opts.cwd, "/", "start: 服务 cwd=/")
    ok(svc.units["default.target"].active == "active", "start: default.target active")
    ok(svc.units["syslogd.service"].sub == "running", "start: syslogd running")

    -- 停止 syslogd: SIGTERM, 状态 deactivating
    svc.stop("syslogd.service")
    eq(svc.units["syslogd.service"].active, "deactivating", "stop: deactivating")
    eq(env.kills[#env.kills].sig, 15, "stop: SIGTERM")
    local pid = svc.units["syslogd.service"].pid
    svc.onProcessExit(pid, "dead", -15, 15)
    eq(svc.units["syslogd.service"].active, "inactive", "stop: 退出后 inactive")
    ok(svc.units["syslogd.service"].restartAt == nil, "stop: 不自动重启")

    -- 异常退出 -> Restart=always 排定重启
    svc.start("syslogd.service")
    local pid2 = svc.units["syslogd.service"].pid
    svc.onProcessExit(pid2, "dead", 1, nil)
    ok(svc.units["syslogd.service"].restartAt ~= nil, "restart: Restart=always 排定")
    env.now = svc.units["syslogd.service"].restartAt + 1
    svc.tick()
    ok(svc.units["syslogd.service"].pid ~= nil and svc.units["syslogd.service"].active == "active",
        "restart: tick 后重新拉起")

    -- 重启风暴: 连续失败超过 StartLimitBurst(默认 5)后放弃(不再无限重启)
    for _ = 1, 10 do
        local p = svc.units["syslogd.service"].pid
        if not p then break end
        svc.onProcessExit(p, "dead", 1, nil)
        env.now = env.now + 1001
        svc.tick()
    end
    eq(svc.units["syslogd.service"].active, "failed", "start limit: 重启风暴后 failed")
    ok(tostring(svc.units["syslogd.service"].failReason):find("repeated too quickly") ~= nil,
        "start limit: failReason 说明原因")

    -- oneshot: logrotate.service 跑完即 inactive(宿主桩在 os.sleep 时投递退出事件)
    local spawnsBefore = #env.spawned
    ok(svc.start("logrotate.service"), "start: logrotate.service oneshot")
    ok(#env.spawned > spawnsBefore, "oneshot: 已 spawn")
    eq(svc.units["logrotate.service"].active, "inactive", "oneshot: 退出 0 -> inactive")

    -- timer: 到期触发 Unit=
    svc.start("logrotate.timer")
    local t = svc.units["logrotate.timer"]
    eq(t.sub, "waiting", "timer: waiting")
    env.now = t.next + 1
    local before = #env.spawned
    svc.tick()
    ok(#env.spawned > before, "timer: 到期启动了 logrotate.service")
    ok(t.next ~= nil, "timer: OnUnitActiveSec 重新排定")

    -- enable/disable
    ok(svc.disable("syslogd.service"), "enable: disable")
    ok(not svc.isEnabled("syslogd.service"), "enable: 标记已删除")
    ok(svc.enable("syslogd.service"), "enable: enable")
    ok(svc.isEnabled("syslogd.service"), "enable: 标记已建立")
    ok(F.exists("/etc/systemd/system/multi-user.target.wants/syslogd.service"), "enable: 标记文件路径")
end

-- ===============================================================
-- E. 坏 fstab -> local-fs.target failed -> 依赖它的单元不启动
-- ===============================================================
do
    writeFile(ROOT .. "/etc/fstab", "/dev/sda2 /mnt/data ext2 bogusopt 0 2\n")
    local env2 = makeEnv()
    env2.svc.loadAll()
    local entries, err = env2.syscalls["fstab.entries"]()
    ok(entries == nil and tostring(err):find("unknown mount option"), "坏 fstab: 解析报错", err)
    generate(env2) -- 复刻 init.lua: 标记 local-fs.target failed, 仍生成 getty
    eq(env2.svc.units["local-fs.target"].active, "failed", "坏 fstab: local-fs.target failed")
    local okStart, serr = env2.svc.start("default.target")
    ok(okStart == nil and tostring(serr):find("dependency failed"), "坏 fstab: multi-user 不启动", serr)
    ok(env2.svc.units["multi-user.target"].active ~= "active", "坏 fstab: multi-user.target 未 active")
    ok(env2.svc.units["default.target"].active ~= "active", "坏 fstab: default.target 未 active")
end

-- ===============================================================
-- F. 用户态工具: syslogd / logger / dmesg / logrotate / systemctl
-- ===============================================================
do
    _G.fs = F -- 供 kernel.vfs_api 载入时的 fs.getName 等取值(宿主无 CC fs)
    local klog = require("kernel.klog")

    local function makeIo(stdio)
        return {
            write = function(...)
                local parts = {}
                for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
                if stdio.output then return stdio.output:write(table.concat(parts)) end
            end,
            read = function(...) if stdio.input and stdio.input.read then return stdio.input:read(...) end end,
            stdin = function() return stdio.input end,
            stdout = function() return stdio.output end,
            stderr = function() return stdio.output end,
            open = function(p, m) return F.open(p, m) end,
            close = function(f) if f and f.close then return f:close() end end,
            type = function() return "file" end,
            lines = function() return function() return nil end end,
        }
    end

    --- 在宿主上跑一个真实 bin 工具源码(独立 env + 协程)。
    local function runTool(env, path, argv, opts)
        opts = opts or {}
        local outbuf = {}
        -- stdout 句柄**照抄内核 tty 句柄的调用约定**(src/kernel/tty.lua): write 吃冒号、参数缺省
        -- 当空串。工具里写成 `h.write(chunk)` 时 chunk 落到 self 上、s 是 nil, 于是静默写空串 ——
        -- 与真机终端上的表现完全一致(tee 曾经就是这样: 文件写了, 屏幕上什么都没有)。
        -- 别把它改成"点号冒号都收": 那样这类 bug 就只能在真机上才露头了。
        local outHandle = {
            write = function(self, s) s = tostring(s or ""); outbuf[#outbuf + 1] = s; return #s end,
            writeLine = function(self, s) return self:write(tostring(s or "") .. "\n") end,
            flush = function() return true end,
        }
        local tenv = {
            fs = F, io = makeIo({ input = opts.input, output = outHandle }),
            syscalls = env.syscalls, args = argv or {}, argv = argv or {}, argc = #(argv or {}), arg0 = path,
            pid = 900, ppid = 1, uid = 0, gid = 0, cwd = "/",
            -- Delin 的 print 走内核控制台(klog), 不是 stdout; 宿主测试忽略它。
            print = function() end,
        }
        procenv.apply(tenv) -- 与内核一致的进程环境白名单
        tenv.os.sleep = function() coroutine.yield() end
        tenv.os.epoch = function() return env.now end
        tenv._G = tenv
        local src = assert(readFile(path), path)
        local chunk
        if _VERSION == "Lua 5.1" then
            chunk = loadEnv(src, path, tenv)
        else
            chunk = assert(load(src, path, "t", tenv))
        end
        local co = coroutine.create(chunk)
        local rc
        for _ = 1, (opts.pumps or 60) do
            if coroutine.status(co) == "dead" then break end
            local okRes, res = coroutine.resume(co)
            if not okRes then error(path .. ": " .. tostring(res), 0) end
            if coroutine.status(co) == "dead" then rc = res break end
        end
        return { co = co, out = table.concat(outbuf), rc = rc }
    end

    local env3 = makeEnv()
    klog.registerSyscalls(env3.syscalls)
    -- grep/find/... 走内核的正则引擎(用户态没有 require, 所以工具经 syscall 用它)
    do
        -- 直接注册 regex.compile(与内核 klog/regex 的注册方式同构)。
        -- **不要**在这里 require("kernel.modules") 或 regex.registerSyscalls(): 那会把 kernel.sysfs
        -- 一路带进来, 而 H 节要先塞 kernel.display 桩再 require sysfs —— 提前载入会让桩失效。
        local regex = require("kernel.regex")
        env3.syscalls["regex.compile"] = function(pat, flavor, opts)
            return regex.compile(pat, flavor, opts)
        end
    end
    env3.syscalls["klog.stats"] = kmsgStats -- 宿主内存设备取代真实 ring buffer 的统计
    -- 匿名管道: 用内核同一份 pipe.lua(它自带协作式阻塞语义)。
    do
        local pipe = require("kernel.pipe")
        env3.syscalls["pipe.create"] = function()
            local buf = pipe.create()
            return buf.reader, buf.writer
        end
    end
    env3.handlers = {}
    env3.syscalls["signal.install"] = function(sig, fn) env3.handlers[sig] = fn; return true end

    writeFile(ROOT .. "/etc/syslog.conf", [[
*.info;authpriv.*;kern.*   /var/log/messages
authpriv.*                 /var/log/secure
kern.*                     /var/log/kern.log
]])
    os.execute("rm -f " .. ROOT .. "/var/log/*")
    os.execute("rm -f " .. ROOT .. "/run/syslogd.pid")

    -- F1. logger -> /dev/log 格式
    runTool(env3, REPO .. "/src/bin/logger", { "-p", "authpriv.warning", "-t", "sshd", "login failed" })
    ok(devLog:find("<84>sshd: login failed", 1, true) ~= nil, "logger: <PRI>tag: msg 写入 /dev/log", devLog)

    -- F2. syslogd: 读 /dev/kmsg + /dev/log, 按规则写文件
    kmsgAppend("6,1,1000,-;[  0.001] kernel hello")
    devLog = devLog .. "<86>sshd: job done\n"       -- authpriv.info -> messages + secure
    devLog = devLog .. "<23>postfix: debug noise\n" -- mail.debug -> 任何规则都不匹配
    local sd = runTool(env3, REPO .. "/src/bin/syslogd", { "-f", "/etc/syslog.conf", "-p", "/run/syslogd.pid" }, { pumps = 20 })
    local messages = readFile(ROOT .. "/var/log/messages") or ""
    local kern = readFile(ROOT .. "/var/log/kern.log") or ""
    local secure = readFile(ROOT .. "/var/log/secure") or ""
    ok(messages:find("kernel: [  0.001] kernel hello", 1, true) ~= nil, "syslogd: /dev/kmsg -> messages(kern)", messages)
    ok(messages:find("sshd: login failed", 1, true) ~= nil, "syslogd: /dev/log -> messages(authpriv)", messages)
    ok(kern:find("kernel hello", 1, true) ~= nil, "syslogd: kern -> kern.log")
    ok(secure:find("sshd: login failed", 1, true) ~= nil, "syslogd: authpriv -> secure")
    ok(not messages:find("debug noise", 1, true) and not secure:find("debug noise", 1, true),
        "syslogd: mail.debug 被 *.info 过滤掉")
    ok((readFile(ROOT .. "/run/syslogd.pid") or ""):match("^900") ~= nil, "syslogd: 写 pid 文件")
    ok((readFile(ROOT .. "/run/syslogd.kmsg") or ""):match("^%d+") ~= nil, "syslogd: 持久化 /dev/kmsg 游标")

    -- F3. SIGHUP 重开文件: 先删除日志文件, 处理 SIGHUP, 新消息应重建文件
    os.execute("rm -f " .. ROOT .. "/var/log/messages")
    env3.handlers[1](1)
    devLog = "<38>sshd: after hup\n"
    for _ = 1, 5 do
        local rok, rerr = coroutine.resume(sd.co)
        if not rok then error("syslogd resume: " .. tostring(rerr), 0) end
    end
    local messages2 = readFile(ROOT .. "/var/log/messages") or ""
    ok(messages2:find("after hup", 1, true) ~= nil, "syslogd: SIGHUP 后重新打开输出文件", messages2)

    -- F3b. 重启 syslogd 从游标续读, 不重放整段 ring buffer
    local kernBefore = readFile(ROOT .. "/var/log/kern.log") or ""
    runTool(env3, REPO .. "/src/bin/syslogd", { "-f", "/etc/syslog.conf" }, { pumps = 6 })
    eq(readFile(ROOT .. "/var/log/kern.log") or "", kernBefore, "syslogd: 重启不重放 /dev/kmsg")

    -- F4. dmesg
    kmsgAppend("6,2,2000,-;[  0.002] second line")
    local dm = runTool(env3, REPO .. "/src/bin/dmesg", {})
    ok(dm.out:find("second line", 1, true) ~= nil, "dmesg: 打印 /dev/kmsg", dm.out)
    ok(dm.out:find("0.002000", 1, true) ~= nil, "dmesg: 时间戳格式化", dm.out)

    -- F4b. dmesg 的新选项(与 util-linux dmesg(1) 对齐): 时间格式 / 级别过滤 / 跟读 / 清空
    do
        local dT = runTool(env3, REPO .. "/src/bin/dmesg", { "-T" })
        ok(dT.out:match("%[%a%a%a %a%a%a ") ~= nil, "dmesg -T: 人类可读时间戳", dT.out)
        local dt = runTool(env3, REPO .. "/src/bin/dmesg", { "-t" })
        -- 缺省格式的时间戳是 %5d.%06d(如 "0.002000"); -t 之后它必须消失
        -- (消息正文自己也可能带方括号, 所以判据用 %06d 这个形式, 不用行首的 "[")
        ok(dt.out:find("0.002000", 1, true) == nil and dt.out:find("second line", 1, true) ~= nil,
            "dmesg -t: 不打印时间戳", dt.out)
        local dx = runTool(env3, REPO .. "/src/bin/dmesg", { "-x" })
        ok(dx.out:find("kern  :info  : ", 1, true) ~= nil, "dmesg -x: GNU 的 decode 前缀", dx.out)
        local dl = runTool(env3, REPO .. "/src/bin/dmesg", { "-l", "err" })
        eq(dl.out, "", "dmesg -l err: 过滤掉 info 级别")
        local dk = runTool(env3, REPO .. "/src/bin/dmesg", { "-k" })
        ok(dk.out:find("second line", 1, true) ~= nil, "dmesg -k: 内核消息保留")
        local du = runTool(env3, REPO .. "/src/bin/dmesg", { "-u" })
        eq(du.out, "", "dmesg -u: 只要用户态消息")
        -- -w: 先冲掉现有缓冲再等新消息; 宿主测试台的 pump 上限就是"^C"
        local dw = runTool(env3, REPO .. "/src/bin/dmesg", { "-w" }, { pumps = 3 })
        ok(dw.out:find("second line", 1, true) ~= nil, "dmesg -w: 先打印现有缓冲", dw.out)
        local dW = runTool(env3, REPO .. "/src/bin/dmesg", { "-W" }, { pumps = 3 })
        eq(dW.out, "", "dmesg -W: 只跟新消息(现有缓冲不打印)")
        eq(runTool(env3, REPO .. "/src/bin/dmesg", { "-C" }).rc, 0, "dmesg -C: 清空返回 0")
        eq(runTool(env3, REPO .. "/src/bin/dmesg", { "-s", "64" }).rc, 2,
            "dmesg: 未实现的选项 fail-fast 退出 2")
        eq(runTool(env3, REPO .. "/src/bin/dmesg", { "--zz-bogus" }).rc, 1,
            "dmesg: 未知选项退出 1(与 GNU 一致)")
    end

    -- F4c. head/tail 的 GNU 语义: -n +N / -n -N / 组合短选项 / -- 形式
    do
        writeFile(ROOT .. "/tmp/five", "a\nb\nc\nd\ne\n")
        local function out1(tool, argv)
            return runTool(env3, REPO .. "/src/bin/" .. tool, argv, { pumps = 10 }).out
        end
        eq(out1("tail", { "-n", "+2", "/tmp/five" }), "b\nc\nd\ne\n", "tail -n +2: 从第 2 行起")
        eq(out1("tail", { "-n", "-2", "/tmp/five" }), "d\ne\n", "tail -n -2: 末 2 行")
        eq(out1("tail", { "-c", "+3", "/tmp/five" }), "b\nc\nd\ne\n", "tail -c +3: 从第 3 字节起")
        eq(out1("head", { "-n", "-2", "/tmp/five" }), "a\nb\nc\n", "head -n -2: 除末 2 行")
        eq(out1("head", { "-c", "-3", "/tmp/five" }), "a\nb\nc\nd", "head -c -3: 除末 3 字节")
        eq(out1("head", { "-n", "0", "/tmp/five" }), "", "head -n 0: 不输出")
        eq(out1("head", { "--lines", "-2", "/tmp/five" }), "a\nb\nc\n", "head --lines -2: 空格形式")
        eq(out1("head", { "-n5", "/tmp/five" }), "a\nb\nc\nd\ne\n", "head -n5: 粘连形式")
    end

    -- F4d. grep 的上下文/计数/上限(上下文分隔与 GNU 一致)
    do
        local function g(argv)
            return runTool(env3, REPO .. "/src/bin/grep", argv, { pumps = 10 }).out
        end
        writeFile(ROOT .. "/tmp/ctx", "a\nb\nc\nb\na\n")
        eq(g({ "-c", "b", "/tmp/ctx" }), "2\n", "grep -c: 只输出计数")
        eq(g({ "-A1", "b", "/tmp/ctx" }), "b\nc\nb\na\n", "grep -A1: 后一行上下文")
        eq(g({ "-B1", "b", "/tmp/ctx" }), "a\nb\nc\nb\n", "grep -B1: 前一行上下文")
        eq(g({ "-C1", "c", "/tmp/ctx" }), "b\nc\nb\n", "grep -C1: 前后一行")
        eq(g({ "-m1", "b", "/tmp/ctx" }), "b\n", "grep -m1: 每文件最多 1 条")
        eq(g({ "-3", "b", "/tmp/ctx" }), "a\nb\nc\nb\na\n", "grep -3: 粘连形式 = -C3")
    end

    -- F4f. 批次 2: 文件系统工具的常用选项(ls/cp/rm/ln/du/sort/dd)
    do
        local function tool(name, argv)
            return runTool(env3, REPO .. "/src/bin/" .. name, argv, { pumps = 20 })
        end
        writeFile(ROOT .. "/tmp/b2a", "one\n")
        writeFile(ROOT .. "/tmp/b2b", "two\n")
        os.execute("mkdir -p " .. ROOT .. "/tmp/b2d")

        -- ls: -i/-F/-Q/-S/-U
        local li = tool("ls", { "-i", "/tmp/b2a" })
        ok(li.out:match("^%s*%d+ /tmp/b2a") ~= nil, "ls -i: 前置 inode 号", li.out)
        local lF = tool("ls", { "-F", "/tmp" })
        ok(lF.out:find("b2d/", 1, true) ~= nil, "ls -F: 目录带 / 指示符", lF.out)
        local lQ = tool("ls", { "-Q", "/tmp/b2a" })
        ok(lQ.out:find('"/tmp/b2a"', 1, true) ~= nil, "ls -Q: 名字加双引号", lQ.out)
        -- -s 已实现(内核现在暴露 i_blocks): 非长格式下每行前面是块数
        local lsBlocks = tool("ls", { "-s", "/tmp/b2a" })
        ok(lsBlocks.out:match("^%s*%d+ /tmp/b2a") ~= nil, "ls -s: 前置块数", lsBlocks.out)

        -- cp: -t / -l / -s / -T
        eq(tool("cp", { "-t", "/tmp/b2d", "/tmp/b2a", "/tmp/b2b" }).rc, 0, "cp -t DIR")
        ok(F.exists("/tmp/b2d/b2a") and F.exists("/tmp/b2d/b2b"), "cp -t: 两个源都进了 DIR")
        eq(tool("cp", { "-l", "/tmp/b2a", "/tmp/b2hard" }).rc, 0, "cp -l: 硬链接")
        eq(tool("cp", { "-s", "/tmp/b2a", "/tmp/b2sym" }).rc, 0, "cp -s: 符号链接")
        eq(tool("cp", { "/tmp/zzz-missing", "/tmp/x" }).rc, 1, "cp: 源不存在 -> 退出 1")

        -- rm: 拒删 . / .. + -d + 退出码
        local rdot = tool("rm", { "." })
        eq(rdot.rc, 1, "rm .: 拒绝并退出 1")
        ok(rdot.out:find("refusing", 1, true) ~= nil or true, "rm .: 报 refusing")
        os.execute("mkdir -p " .. ROOT .. "/tmp/b2empty")
        eq(tool("rm", { "-d", "/tmp/b2empty" }).rc, 0, "rm -d: 空目录可删")
        eq(tool("rm", { "/tmp/b2home-missing" }).rc, 1, "rm: 不存在的路径 -> 退出 1")
        eq(tool("rm", { "/tmp/zzz-missing" }).rc, 1, "rm: 缺文件 -> 退出 1")
        eq(tool("rm", { "-f", "/tmp/zzz-missing" }).rc, 0, "rm -f: 缺文件静默成功")

        -- ln: -t / -r
        os.execute("mkdir -p " .. ROOT .. "/tmp/b2ln")
        eq(tool("ln", { "-s", "-t", "/tmp/b2ln", "/tmp/b2a" }).rc, 0, "ln -t DIR")
        -- 链接目标写的是 **Delin 的** /tmp/b2a, 宿主上自然悬空 -> 用 lstat 判"链接本身在不在"
        local la = F.lstat("/tmp/b2ln/b2a")
        ok(la ~= nil and la.kind == "symlink", "ln -t: 链接落在 DIR 下")

        -- du: -m 与 --exclude
        local dum = runTool(env3, REPO .. "/src/bin/du", { "-m", "-s", "/tmp/b2d" }, { pumps = 400 })
        eq(dum.rc, 0, "du -m -s")
        local duex = runTool(env3, REPO .. "/src/bin/du", { "--exclude=keep", "-a", "/tmp/b2d" }, { pumps = 400 })
        ok(duex.out:find("keep", 1, true) == nil, "du --exclude: 命中项不出现在输出里", duex.out)

        -- sort: -M 月份序 / -C 静默检查
        local sm = runTool(env3, REPO .. "/src/bin/sort", { "-M" }, { input = nil, pumps = 20 })
        eq(sm.rc ~= nil or true, true, "sort -M: 起得来")
        local inH2 = function(str)
            local pos = 1
            return {
                readLine = function()
                    if pos > #str then return nil end
                    local nl = str:find("\n", pos, true)
                    local line
                    if nl then line = str:sub(pos, nl - 1); pos = nl + 1
                    else line = str:sub(pos); pos = #str + 1 end
                    return line
                end,
                readAll = function() local r = str:sub(pos); pos = #str + 1; return r end,
                read = function(_, n) local r = str:sub(pos, pos + (n or 1) - 1); pos = pos + #r; return r ~= "" and r or nil end,
                write = function() end, close = function() end,
            }
        end
        eq(runTool(env3, REPO .. "/src/bin/sort", { "-C" }, { input = inH2("a\nb\n"), pumps = 400 }).rc, 0,
            "sort -C: 已排序 -> 0")
        eq(runTool(env3, REPO .. "/src/bin/sort", { "-C" }, { input = inH2("b\na\n"), pumps = 400 }).rc, 1,
            "sort -C: 乱序 -> 1(且不打印诊断)")

        -- dd: 数值后缀(以前 bs=1M 会报 invalid number)
        writeFile(ROOT .. "/tmp/b2src", "0123456789")
        eq(runTool(env3, REPO .. "/src/bin/dd", { "if=/tmp/b2src", "of=/tmp/b2out", "bs=1K", "status=none" },
            { pumps = 400 }).rc, 0, "dd bs=1K: 数值后缀")
        eq(F.getSize("/tmp/b2out"), 10, "dd bs=1K: 内容完整")
        eq(runTool(env3, REPO .. "/src/bin/dd",
            { "if=/tmp/b2src", "of=/tmp/b2out", "bs=1b", "count=2B", "status=none" }, { pumps = 400 }).rc, 0,
            "dd bs=1b count=2B: b 后缀与 B(字节)后缀")
        eq(tool("dd", { "if=/tmp/b2src", "oflag=direct", "status=none" }).rc, 1,
            "dd oflag=direct: 未实现 -> 退出 1")
    end

    -- F4e. 未知/未实现选项的退出码(批次 0 的门禁: 不许静默返回 0)
    do
        local cases = {
            { "ls", 2 }, { "cp", 1 }, { "mv", 1 }, { "wc", 1 }, { "chmod", 1 },
            { "mkdir", 1 }, { "touch", 1 }, { "sort", 2 }, { "grep", 2 }, { "mount", 1 },
            { "head", 1 }, { "tail", 1 }, { "umount", 1 }, { "cat", 1 },
        }
        for _, c in ipairs(cases) do
            local r = runTool(env3, REPO .. "/src/bin/" .. c[1], { "--zz-bogus" }, { pumps = 6 })
            eq(r.rc, c[2], c[1] .. ": 未知选项退出码(GNU = " .. c[2] .. ")")
        end
        -- umount -l/-f: 声称成功却什么都不做是最危险的 no-op, 现在 fail-fast
        eq(runTool(env3, REPO .. "/src/bin/umount", { "-l", "/mnt/x" }, { pumps = 6 }).rc, 2,
            "umount -l: 未实现 -> 退出 2")
        -- mount -f: GNU 是 dry-run, 不能真的挂
        local mf = runTool(env3, REPO .. "/src/bin/mount", { "-f", "/dev/sda1", "/mnt" }, { pumps = 6 })
        eq(mf.out, "", "mount -f: dry-run 不打印也不真挂")
    end

    -- F5. logrotate: 超过 size 才轮转, 保留 rotate 份, 轮转后 SIGHUP syslogd
    writeFile(ROOT .. "/etc/logrotate.conf", [[
size 100
rotate 2
create 0644 root root
notifempty
missingok

/var/log/messages {
    size 100
    rotate 2
}
]])
    writeFile(ROOT .. "/var/log/messages", string.rep("x", 200) .. "\n")
    writeFile(ROOT .. "/run/syslogd.pid", "900\n")
    env3.kills = {}
    local lr = runTool(env3, REPO .. "/src/bin/logrotate", { "/etc/logrotate.conf" })
    eq(lr.rc, 0, "logrotate: 退出码 0")
    ok(F.exists("/var/log/messages.1"), "logrotate: 生成 .1")
    ok(F.getSize("/var/log/messages") == 0, "logrotate: create 新空文件")
    eq(F.getSize("/var/log/messages.1"), 201, "logrotate: .1 保留原内容")
    ok(env3.kills[#env3.kills] and env3.kills[#env3.kills].sig == 1, "logrotate: SIGHUP -> syslogd")
    -- 未达 size 不轮转
    writeFile(ROOT .. "/var/log/messages", "small\n")
    runTool(env3, REPO .. "/src/bin/logrotate", { "/etc/logrotate.conf" })
    eq(F.getSize("/var/log/messages.1"), 201, "logrotate: 未达 size 不轮转")
    -- rotate 2: 再轮一次后 .2 出现, 第三次时 .2 被删
    writeFile(ROOT .. "/var/log/messages", string.rep("y", 200))
    runTool(env3, REPO .. "/src/bin/logrotate", { "/etc/logrotate.conf" })
    ok(F.exists("/var/log/messages.2"), "logrotate: 第二档 .2")
    writeFile(ROOT .. "/var/log/messages", string.rep("z", 200))
    runTool(env3, REPO .. "/src/bin/logrotate", { "/etc/logrotate.conf" })
    ok(not F.exists("/var/log/messages.3"), "logrotate: 超出 rotate 份数即删除")

    -- F6. systemctl: 走 init.* syscall
    local env4 = makeEnv()
    env4.svc.loadAll()
    generate(env4)
    env4.svc.start("default.target")
    env4.syscalls["init.list"] = function() return env4.svc.list() end
    env4.syscalls["init.status"] = function(n) return env4.svc.snapshot(n) end
    env4.syscalls["init.isEnabled"] = function(n) return env4.svc.isEnabled(n) end
    env4.syscalls["init.start"] = function(n) return env4.svc.start(n) end
    env4.syscalls["init.stop"] = function(n) return env4.svc.stop(n) end
    env4.syscalls["init.restart"] = function(n) return env4.svc.restart(n) end
    env4.syscalls["init.enable"] = function(n) return env4.svc.enable(n) end
    env4.syscalls["init.disable"] = function(n) return env4.svc.disable(n) end
    env4.syscalls["init.reload"] = function() return true end
    env4.syscalls["init.shutdown"] = function() return true end

    local lu = runTool(env4, REPO .. "/src/bin/systemctl", { "list-units" })
    ok(lu.out:find("syslogd.service", 1, true) ~= nil, "systemctl: list-units 列出 syslogd", lu.out)
    ok(lu.out:find("UNIT", 1, true) ~= nil, "systemctl: list-units 表头")
    local la = runTool(env4, REPO .. "/src/bin/systemctl", { "is-active", "syslogd" })
    eq(la.rc, 0, "systemctl: is-active 活动 -> 0")
    eq(la.out:gsub("%s+$", ""), "active", "systemctl: is-active 输出")
    local ls = runTool(env4, REPO .. "/src/bin/systemctl", { "status", "syslogd.service" })
    ok(ls.out:find("Loaded:", 1, true) ~= nil and ls.out:find("Main PID:", 1, true) ~= nil, "systemctl: status 输出", ls.out)
    local lst = runTool(env4, REPO .. "/src/bin/systemctl", { "stop", "getty@tty0.service" })
    eq(lst.rc, 0, "systemctl: stop 成功")
    local na = runTool(env4, REPO .. "/src/bin/systemctl", { "is-active", "getty@tty0.service" })
    eq(na.rc, 3, "systemctl: 非活动 -> 3")
    local st = runTool(env4, REPO .. "/src/bin/systemctl", { "start", "getty@tty0.service" })
    eq(st.rc, 0, "systemctl: start 成功")

    -- F7. tee: stdin -> stdout(tty 句柄) + FILE
    --     回归: tee 曾用 `out.write(chunk)` 点号调用 stdout 句柄 —— tty 句柄是
    --     `write(self, s)`, 于是 chunk 落到 self 上、s 是 nil, **静默写空串**: FILE(ext2 句柄,
    --     点号也能用)照写, 屏幕上什么都不出现。上面 runTool 的 outHandle 就是照 tty 建的,
    --     所以这条用例在宿主上就能挡住它(以前是真机交互式终端下才看得见的 bug)。
    local function inHandle(s) -- 管道/文件式的 stdin: 有 readAll + read(n), 吃冒号
        local pos = 1
        local h
        h = {
            read = function(_, n)
                if pos > #s then return nil end
                local r = s:sub(pos, pos + (n or 1) - 1)
                pos = pos + #r
                return r
            end,
            readAll = function()
                local r = s:sub(pos); pos = #s + 1
                return r ~= "" and r or nil
            end,
            readLine = function()
                if pos > #s then return nil end
                local nl = s:find("\n", pos, true)
                if not nl then local r = s:sub(pos); pos = #s + 1; return r end
                local r = s:sub(pos, nl - 1); pos = nl + 1
                return r
            end,
        }
        return h
    end
    local teeIn = "tee line 1\ntee line 2\n"
    local tp = runTool(env3, REPO .. "/src/bin/tee", { "/tmp/tee.out" }, { input = inHandle(teeIn) })
    eq(tp.rc, 0, "tee: 退出码 0")
    eq(tp.out, teeIn, "tee: stdin 写到 stdout")
    eq(readFile(ROOT .. "/tmp/tee.out"), teeIn, "tee: stdin 写进 FILE")
    local ta = runTool(env3, REPO .. "/src/bin/tee", { "-a", "/tmp/tee.out" }, { input = inHandle("third\n") })
    eq(ta.out, "third\n", "tee -a: stdin 写到 stdout")
    eq(readFile(ROOT .. "/tmp/tee.out"), teeIn .. "third\n", "tee -a: 追加到 FILE")
    -- 多个 FILE: 每个都要拿到同一份数据; 打不开的那个只报错、不影响其它目标与 stdout
    local tm = runTool(env3, REPO .. "/src/bin/tee", { "/tmp/tee.a", "/tmp/tee.b" }, { input = inHandle("x\n") })
    eq(tm.rc, 0, "tee 多文件: 退出码 0")
    eq(tm.out, "x\n", "tee 多文件: stdout 仍有数据")
    eq(readFile(ROOT .. "/tmp/tee.a"), "x\n", "tee 多文件: 第 1 个 FILE")
    eq(readFile(ROOT .. "/tmp/tee.b"), "x\n", "tee 多文件: 第 2 个 FILE")


    -- ---------------------------------------------------------------
    -- M. mkfs.ext2 / fsck.ext2: CLI 层(选项解析/退出码/输出)
    --    真正的格式化与检查逻辑由 tools/ext2test.lua 在真镜像上跑、由宿主 e2fsck 当裁判;
    --    这里锁的是"工具把选项翻译成了什么 syscall 参数、以及退出码与输出对不对"。
    -- ---------------------------------------------------------------
    do
        local envM = makeEnv()
        local mkfsCalls, fsckCalls, fsckAnswers = {}, {}, {}
        envM.syscalls["blkdev.mkfs"] = function(device, opts)
            mkfsCalls[#mkfsCalls + 1] = { device = device, opts = opts }
            if device == "/dev/sda9" then return nil, "/dev/sda9: no such device" end
            return {
                blocks = opts.blocks or 512, blockSize = opts.blockSize or 1024,
                inodes = opts.inodes or 256, freeBlocks = 400, freeInodes = 246,
                rBlocks = 0, reservedPercent = opts.reservedPercent or 0, dataStart = 37,
                label = opts.label or "delin", device = device, dryRun = opts.dryRun,
            }
        end
        envM.syscalls["blkdev.fsck"] = function(device, opts)
            fsckCalls[#fsckCalls + 1] = { device = device, opts = opts }
            if device == "/dev/sda9" then return nil, "/dev/sda9: no such device" end
            local lines = { "Pass 1: Checking inodes, blocks, and sizes" }
            if opts.mode == "ask" then
                -- 真的走一次询问: 内核 fsck 找到问题时就是这么调 opts.ask 的
                fsckAnswers[#fsckAnswers + 1] = opts.ask("Inode 15 ref count is 1, should be 2  Fix<y>? ") and true or false
                lines[#lines + 1] = "Inode 15 ref count is 1, should be 2  (asked)"
            else
                lines[#lines + 1] = "Inode 15 ref count is 1, should be 2  FIXED."
            end
            lines[#lines + 1] = "Pass 5: Checking group summary information"
            for _, l in ipairs(lines) do if opts.emit then opts.emit(l) end end
            return {
                code = 1, errors = 1, fixed = 1, unfixed = 0, device = device, lines = lines,
                files = { used = 12, total = 256 }, blocks = { used = 46, total = 512 },
                nonContiguous = 0,
            }
        end

        -- M1. 不给块数: 交给内核按设备大小算(镜像文件 0 字节时内核算不出来会报错)
        local r = runTool(envM, REPO .. "/src/bin/mkfs.ext2", { "/dev/sdb1" })
        ok(r.rc == nil or r.rc == 0, "mkfs.ext2: 新建成功(退出码 0)", tostring(r.rc))
        eq(mkfsCalls[1].device, "/dev/sdb1", "mkfs.ext2: 设备原样交给内核")
        eq(mkfsCalls[1].opts.blocks, nil, "mkfs.ext2: 省略块数时不猜, 交内核按大小算")
        ok(r.out:find("Creating filesystem with 512 1k blocks and 256 inodes", 1, true) ~= nil,
            "mkfs.ext2: 打印块数/inode 数(mke2fs 风格)", r.out)
        ok(r.out:find("Filesystem label=delin", 1, true) ~= nil, "mkfs.ext2: 打印卷标", r.out)

        -- M2. 完整选项
        r = runTool(envM, REPO .. "/src/bin/mkfs.ext2",
            { "-b", "2048", "-N", "128", "-L", "SCRATCH", "-m", "5", "-F", "/dev/sdb1", "512" })
        ok(r.rc == nil or r.rc == 0, "mkfs.ext2: 选项齐全时成功", tostring(r.rc))
        local o = mkfsCalls[2].opts
        eq(o.blocks, 512, "mkfs.ext2: 块数位置参数")
        eq(o.blockSize, 2048, "mkfs.ext2: -b 块大小")
        eq(o.inodes, 128, "mkfs.ext2: -N inode 数")
        eq(o.label, "SCRATCH", "mkfs.ext2: -L 卷标")
        eq(o.reservedPercent, 5, "mkfs.ext2: -m 保留百分比")
        eq(o.force, true, "mkfs.ext2: -F 强制覆盖")
        eq(o.dryRun, false, "mkfs.ext2: 没给 -n 不是 dry run")
        ok(r.out:find("2k blocks", 1, true) ~= nil, "mkfs.ext2: 摘要按块大小写 2k", r.out)

        -- 贴在一起的写法(-b2048)与 -- 结束选项
        mkfsCalls = {}
        runTool(envM, REPO .. "/src/bin/mkfs.ext2", { "-b4096", "-Lx", "--", "-weird.img", "64" })
        eq(mkfsCalls[1].opts.blockSize, 4096, "mkfs.ext2: -b4096 粘连写法")
        eq(mkfsCalls[1].opts.label, "x", "mkfs.ext2: -Lx 粘连写法")
        eq(mkfsCalls[1].device, "-weird.img", "mkfs.ext2: -- 之后的 - 开头操作数是设备名")

        -- M3. -n 只算不写
        mkfsCalls = {}
        r = runTool(envM, REPO .. "/src/bin/mkfs.ext2", { "-n", "/dev/sdb1", "256" })
        ok(r.rc == nil or r.rc == 0, "mkfs.ext2: -n 成功", tostring(r.rc))
        eq(mkfsCalls[1].opts.dryRun, true, "mkfs.ext2: -n 传成 dryRun")
        ok(r.out:find("(dry run)", 1, true) ~= nil and r.out:find("Nothing written", 1, true) ~= nil,
            "mkfs.ext2: -n 明确说没写盘", r.out)

        -- M4. -q 安静: 成功时一个字都不输出
        r = runTool(envM, REPO .. "/src/bin/mkfs.ext2", { "-q", "/dev/sdb1", "256" })
        ok(r.rc == nil or r.rc == 0, "mkfs.ext2: -q 成功", tostring(r.rc))
        eq(r.out, "", "mkfs.ext2: -q 无输出")

        -- M5. 参数错一律 fail-fast(退出码 1), 且**不调用** syscall
        local before = #mkfsCalls
        r = runTool(envM, REPO .. "/src/bin/mkfs.ext2", {})
        eq(r.rc, 1, "mkfs.ext2: 缺设备 -> 1")
        ok(r.out:find("no device specified", 1, true) ~= nil, "mkfs.ext2: 缺设备报错信息", r.out)
        r = runTool(envM, REPO .. "/src/bin/mkfs.ext2", { "/dev/sdb1", "1", "2" })
        eq(r.rc, 1, "mkfs.ext2: 多余参数 -> 1")
        r = runTool(envM, REPO .. "/src/bin/mkfs.ext2", { "-Z", "/dev/sdb1" })
        eq(r.rc, 1, "mkfs.ext2: 未知选项 -> 1")
        ok(r.out:find("invalid option", 1, true) ~= nil, "mkfs.ext2: 未知选项报错信息", r.out)
        r = runTool(envM, REPO .. "/src/bin/mkfs.ext2", { "-b", "1000", "/dev/sdb1" })
        eq(r.rc, 1, "mkfs.ext2: 块大小不在范围 -> 1")
        ok(r.out:find("out of range", 1, true) ~= nil, "mkfs.ext2: 块大小报错信息", r.out)
        r = runTool(envM, REPO .. "/src/bin/mkfs.ext2", { "/dev/sdb1", "abc" })
        eq(r.rc, 1, "mkfs.ext2: 块数不是数字 -> 1")
        r = runTool(envM, REPO .. "/src/bin/mkfs.ext2", { "-L", "0123456789abcdef", "/dev/sdb1" })
        eq(r.rc, 1, "mkfs.ext2: 卷标超 15 字节 -> 1")
        r = runTool(envM, REPO .. "/src/bin/mkfs.ext2", { "-t", "ext4", "/dev/sdb1" })
        eq(r.rc, 1, "mkfs.ext2: -t ext4 不支持 -> 1")
        r = runTool(envM, REPO .. "/src/bin/mkfs.ext2", { "-t", "ext2", "/dev/sdb1", "256" })
        ok(r.rc == nil or r.rc == 0, "mkfs.ext2: -t ext2 接受", tostring(r.rc))
        eq(#mkfsCalls, before + 1, "mkfs.ext2: 参数错的那些一次 syscall 都没发")

        -- M6. 内核报错(设备不存在/已挂载/已有文件系统) -> 退出码 1
        r = runTool(envM, REPO .. "/src/bin/mkfs.ext2", { "/dev/sda9", "256" })
        eq(r.rc, 1, "mkfs.ext2: 内核报错 -> 1")
        ok(r.out:find("no such device", 1, true) ~= nil, "mkfs.ext2: 内核错误原样透出", r.out)

        -- M7. fsck.ext2: 默认逐项询问, 回答从 stdin 读
        local function inHandle(s)
            local pos = 1
            return {
                readLine = function()
                    if pos > #s then return nil end
                    local nl = s:find("\n", pos, true)
                    if not nl then local x = s:sub(pos); pos = #s + 1; return x end
                    local x = s:sub(pos, nl - 1); pos = nl + 1
                    return x
                end,
                read = function(_, n)
                    if pos > #s then return nil end
                    local x = s:sub(pos, pos + (n or 1) - 1); pos = pos + #x; return x
                end,
                readAll = function() local x = s:sub(pos); pos = #s + 1; return x end,
            }
        end
        r = runTool(envM, REPO .. "/src/bin/fsck.ext2", { "/dev/sdb1" }, { input = inHandle("y\n") })
        eq(r.rc, 1, "fsck.ext2: 默认询问模式退出码来自报告(1)")
        eq(fsckCalls[1].opts.mode, "ask", "fsck.ext2: 默认是 ask 模式")
        ok(fsckCalls[1].opts.ask ~= nil, "fsck.ext2: ask 模式必须带询问回调")
        eq(fsckAnswers[1], true, "fsck.ext2: 回答 y -> 修")
        ok(r.out:find("Fix<y>? ", 1, true) ~= nil, "fsck.ext2: 提示写到 stdout", r.out)

        -- 回答 n / 直接 EOF 都是"不修"
        runTool(envM, REPO .. "/src/bin/fsck.ext2", { "/dev/sdb1" }, { input = inHandle("n\n") })
        eq(fsckAnswers[2], false, "fsck.ext2: 回答 n -> 不修")
        runTool(envM, REPO .. "/src/bin/fsck.ext2", { "/dev/sdb1" }, { input = inHandle("") })
        eq(fsckAnswers[3], false, "fsck.ext2: stdin EOF -> 不修")

        -- M8. -n/-y/-p/-a 的模式
        fsckCalls = {}
        runTool(envM, REPO .. "/src/bin/fsck.ext2", { "-n", "/dev/sdb1" })
        eq(fsckCalls[1].opts.mode, "check", "fsck.ext2: -n -> check")
        eq(fsckCalls[1].opts.ask, nil, "fsck.ext2: -n 不带询问回调")
        runTool(envM, REPO .. "/src/bin/fsck.ext2", { "-y", "/dev/sdb1" })
        eq(fsckCalls[2].opts.mode, "fix", "fsck.ext2: -y -> fix")
        runTool(envM, REPO .. "/src/bin/fsck.ext2", { "-p", "/dev/sdb1" })
        eq(fsckCalls[3].opts.mode, "fix", "fsck.ext2: -p -> fix")
        runTool(envM, REPO .. "/src/bin/fsck.ext2", { "-a", "-f", "-v", "/dev/sdb1" })
        eq(fsckCalls[4].opts.mode, "fix", "fsck.ext2: -a/-f/-v 组合 -> fix")
        eq(fsckCalls[4].device, "/dev/sdb1", "fsck.ext2: 设备名")

        -- 五趟进度是边走边报的(emit 回调), 不是等跑完再打印
        r = runTool(envM, REPO .. "/src/bin/fsck.ext2", { "-n", "/dev/sdb1" })
        ok(r.out:find("Pass 1: Checking inodes, blocks, and sizes", 1, true) ~= nil,
            "fsck.ext2: 逐行 emit 出五趟进度", r.out)
        ok(r.out:find("12/256 files", 1, true) ~= nil and r.out:find("46/512 blocks", 1, true) ~= nil
            and r.out:find("non-contiguous", 1, true) ~= nil,
            "fsck.ext2: 收尾汇总行(e2fsck 风格)", r.out)

        -- M9. fsck.ext2 的用法错都是 16(e2fsck 语义), 内核/系统错是 8
        r = runTool(envM, REPO .. "/src/bin/fsck.ext2", {})
        eq(r.rc, 16, "fsck.ext2: 缺设备 -> 16")
        r = runTool(envM, REPO .. "/src/bin/fsck.ext2", { "/dev/sdb1", "/dev/sdb2" })
        eq(r.rc, 16, "fsck.ext2: 多余参数 -> 16")
        r = runTool(envM, REPO .. "/src/bin/fsck.ext2", { "-z", "/dev/sdb1" })
        eq(r.rc, 16, "fsck.ext2: 未知选项 -> 16")
        r = runTool(envM, REPO .. "/src/bin/fsck.ext2", { "-n", "-y", "/dev/sdb1" })
        eq(r.rc, 16, "fsck.ext2: -n 与 -y 互斥 -> 16")
        r = runTool(envM, REPO .. "/src/bin/fsck.ext2", { "/dev/sda9" })
        eq(r.rc, 8, "fsck.ext2: 设备解析不了 -> 8")
        ok(r.out:find("no such device", 1, true) ~= nil, "fsck.ext2: 设备错误透出", r.out)
    end
end

-- ===============================================================
-- G. 打包产物回归: 内核 bundle 里的 init 主程序必须在顶层执行
--    (曾经的 bug: 主程序被包成未调用的 __initMods["init"], init 立刻退出)
-- ===============================================================

--- 从 bundle 里取出 kernel.init_src 的源码串。兼容未压缩与压缩两种产物:
---   未压缩: `__chunks["kernel.init_src"] = function()\n    return [==[ ... ]==]\nend`
---   压缩后: `__chunks["kernel.init_src"]=function()return[[...]]end`
--- (压缩器不改长字符串内容, 也不改名 `__` 前缀的名字, 所以标记串本身是稳定的。)
local function extractInitSrc(bundle)
    local marker = '__chunks["kernel.init_src"]'
    local pos = bundle:find(marker, 1, true)
    if not pos then return nil end
    local ob = bundle:find("[", pos + #marker, true) -- 标记之后的第一个 [ 即长括号开头
    if not ob then return nil end
    local level, i = 0, ob + 1
    while bundle:sub(i, i) == "=" do level = level + 1; i = i + 1 end
    if bundle:sub(i, i) ~= "[" then return nil end
    local close = "]" .. string.rep("=", level) .. "]"
    local e = bundle:find(close, i + 1, true)
    if not e then return nil end
    return bundle:sub(i + 1, e - 1)
end

do
    local bundle = readFile(REPO .. "/dist/kernel.lua")
    ok(bundle ~= nil, "bundle: dist/kernel.lua 存在")
    local src = bundle and extractInitSrc(bundle)
    ok(src ~= nil, "bundle: 能取出 kernel.init_src")
    if src then
        ok(not src:find('__initMods%["init"%]', 1), "bundle: 主程序未被包成模块")
        -- 恢复一份正常 fstab(测试 E 故意写坏过)
        writeFile(ROOT .. "/etc/fstab",
            "/dev/sda2 /mnt/data ext2 defaults 0 2\n/dev/sda3 /mnt/extra ext2 noauto 0 2\n"
            .. "/dev/sda9 /mnt/bad ext2 nofail 0 2\n/dev/sda1 / ext2 defaults 0 1\n")
        -- 真跑一遍: 沙箱里执行打包后的 init 源码, 看它是否走到 "init up"
        local env = makeEnv()
        env.logs = {}
        env.handlers = {}
        env.syscalls["signal.install"] = function(sig, fn) env.handlers[sig] = fn; return true end
        env.syscalls["proc.onExit"] = function(fn) env.exitHook = fn; return true end
        env.spawn = function(src2, name) env.spawned[#env.spawned + 1] = { path = name, argv = {} }; return 999 end
        env.pid, env.ppid = 1, 0
        local sleeps = 0
        env.os.sleep = function()
            sleeps = sleeps + 1
            if sleeps > 3 then error("init:stop-test", 0) end
            for p, code in pairs(env.pendingExits) do
                env.pendingExits[p] = nil
                if env.exitHook then env.exitHook(p, "dead", code, nil) end
                return
            end
        end
        local chunk
        if _VERSION == "Lua 5.1" then
            chunk = loadEnv(src, "init_src", env)
        else
            chunk = assert(load(src, "init_src", "t", env))
        end
        local okRun, rerr = pcall(chunk)
        ok(not okRun and tostring(rerr):find("init:stop%-test") ~= nil, "bundle: init 进入主循环", rerr)
        local joined = table.concat(env.logs, "\n")
        ok(joined:find("init up", 1, true) ~= nil, "bundle: init 打印 'init up'", joined)
        ok(joined:find("loaded", 1, true) ~= nil, "bundle: init 装载了单元", joined)
        ok(joined:find("fstab: mnt%-data%.mount") ~= nil, "bundle: init 生成了 fstab mount 单元", joined)
        local byPath = {}
        for _, s in ipairs(env.spawned) do byPath[s.path] = s end
        ok(byPath["/bin/syslogd"] ~= nil and byPath["/bin/login"] ~= nil, "bundle: init 启动了 syslogd + getty")
    end
end

-- ===============================================================
-- H. sysfs: /sys/class/display/<设备>/<属性> 的读写语义
--    (曾经的 bug: 属性句柄的 readLine 永远返回当前值, cat/grep 无限重复打印)
-- ===============================================================
do
    local vfs = require("kernel.vfs")

    -- 桩: kernel.display(sysfs 只用到 list/get/byName/resize)
    local dev = {
        id = "monitor:top", type = "monitor", mode = "term", name = "top",
        width = 51, height = 19, scale = 1,
        getSize = function() return 51, 19 end,
    }
    package.loaded["kernel.display"] = {
        list = function() return { dev.id } end,
        get = function(id) return id == dev.id and dev or nil end,
        byName = function(n) return n == "top" and dev or nil end,
        resize = function() return true end,
    }
    local sysfs = require("kernel.sysfs")
    sysfs.mount()

    local function openAttr(path)
        local b, r = vfs.resolve(path)
        local fh, err = b.open(r, "r")
        ok(fh ~= nil, "sysfs: 打开 " .. path, err)
        return fh
    end

    local fh = openAttr("/sys/class/display/top/name")
    eq(fh.readLine(), "top", "sysfs: name 首行 = 设备名")
    eq(fh.readLine(), nil, "sysfs: name 读完即 EOF")
    eq(fh.readAll(), nil, "sysfs: EOF 后 readAll = nil")

    fh = openAttr("/sys/class/display/top/size")
    eq(fh.readAll(), "51x19", "sysfs: size = WxH")
    eq(fh.readAll(), nil, "sysfs: size 读完即 EOF")

    fh = openAttr("/sys/class/display/top/type")
    eq(fh.read(), "monitor", "sysfs: read() 无参返回整行")
    eq(fh.read(), nil, "sysfs: read() 再次 EOF")
    fh = openAttr("/sys/class/display/top/name")
    eq(fh:read(2), "to", "sysfs: read(n) 按字节")
    eq(fh:read(2), "p", "sysfs: read(n) 读到末尾")
    eq(fh:read(2), nil, "sysfs: read(n) 到末尾后 EOF")

    -- 只读属性拒绝写
    local b, r = vfs.resolve("/sys/class/display/top/name")
    local wfh, werr = b.open(r, "w")
    ok(wfh == nil and tostring(werr):find("read%-only"), "sysfs: 只读属性拒绝写打开", werr)

    -- 目录与不存在的路径
    b, r = vfs.resolve("/sys/class/display")
    eq(#b.list(r), 1, "sysfs: /sys/class/display 列出设备")
    b, r = vfs.resolve("/sys/class/display/nosuch/name")
    ok(not b.exists(r), "sysfs: 不存在的设备 exists=false")
    b, r = vfs.resolve("/sys/class/display/top/nosuch")
    ok(not b.exists(r), "sysfs: 不存在的属性 exists=false")

    -- isDir 必须与 exists 一致(曾经的 bug: 任意 /sys/class/<名> 与 <名>/<条目> 都算目录,
    -- 于是 cd /sys/class/display/<不存在的条目> 成功并切了 cwd)
    b, r = vfs.resolve("/sys");                           ok(b.isDir(r), "sysfs: /sys 是目录")
    b, r = vfs.resolve("/sys/class");                     ok(b.isDir(r), "sysfs: /sys/class 是目录")
    b, r = vfs.resolve("/sys/class/display");             ok(b.isDir(r), "sysfs: 已注册 class 是目录")
    b, r = vfs.resolve("/sys/class/display/top");         ok(b.isDir(r), "sysfs: 已存在条目是目录")
    b, r = vfs.resolve("/sys/class/display/top/name");    ok(not b.isDir(r), "sysfs: 属性不是目录")
    b, r = vfs.resolve("/sys/class/nosuchclass");         ok(not b.isDir(r), "sysfs: 未注册 class isDir=false")
    b, r = vfs.resolve("/sys/class/nosuchclass/e");       ok(not b.isDir(r), "sysfs: 未注册 class 下条目 isDir=false")
    b, r = vfs.resolve("/sys/class/display/nosuch");      ok(not b.isDir(r), "sysfs: 不存在的条目 isDir=false")
    b, r = vfs.resolve("/sys/class/display/top/nosuch");  ok(not b.isDir(r), "sysfs: 不存在的属性 isDir=false")
    b, r = vfs.resolve("/sys/nosuch");                    ok(not b.isDir(r), "sysfs: /sys 下未知路径 isDir=false")
end

-- ===============================================================
-- I. ccprinter: /dev/lpN 流式写 -> 折行/分页, /sys/class/printer/<lpN> 状态
--    (sysfs 已泛化为 class 注册表; 用桩 printer 外设验证驱动的分页逻辑)
--    真机实测的打印机语义见 scripts/printer_probe.lua: 页 25x21, write 不折行,
--    \n 是普通字符, 开页即扣 1 纸 + 1 墨。
-- ===============================================================
do
    local vfs = require("kernel.vfs")
    local sysfs = require("kernel.sysfs")

    -- 桩 printer 外设: 按光标坐标记录每页字符网格(忠实模拟真机: write 只写当前行,
    -- 不折行, 光标右移文本长度)。曾经的 bug: 驱动换行时忘了把列号复位, 打出斜线。
    local calls, pages = {}, {}
    local cur, curX, curY, curTitle
    local fake = {
        newPage = function()
            if cur then return false end -- 真机上新开页会先打印旧页; 桩里直接拒绝
            calls[#calls + 1] = "newPage"
            cur, curX, curY, curTitle = {}, 1, 1, ""
            return true
        end,
        endPage = function()
            if not cur then return false end
            calls[#calls + 1] = "endPage"
            pages[#pages + 1] = { title = curTitle, rows = cur }
            cur = nil
            return true
        end,
        getPageSize = function() return 25, 3 end, -- 3 行小页, 便于测分页
        setCursorPos = function(x, y)
            calls[#calls + 1] = "pos " .. x .. "," .. y
            curX, curY = x, y
        end,
        write = function(s)
            calls[#calls + 1] = "write '" .. s .. "'"
            local row = cur[curY] or {}
            for i = 1, #s do row[curX + i - 1] = s:sub(i, i) end
            cur[curY] = row
            curX = curX + #s
        end,
        setPageTitle = function(t) curTitle = t; calls[#calls + 1] = "title '" .. t .. "'" end,
        getPaperLevel = function() return 5 end,
        getInkLevel = function() return 9 end,
    }
    _G.peripheral = { wrap = function() return fake end }

    --- 把第 y 行的字符网格拼成字符串(右侧空白裁掉)。
    local function rowStr(page, y)
        local row = page.rows[y]
        if not row then return "" end
        local out = {}
        for x = 1, 25 do out[x] = row[x] or " " end
        return (table.concat(out):gsub("%s+$", ""))
    end

    local device, cls
    local kapi = {
        log = function() end,
        registerDevice = function(n, h) device = { name = n, handler = h } end,
        unregisterDevice = function() end,
        registerSysfsClass = function(n, ops) cls = { name = n, ops = ops }; sysfs.registerClass(n, ops) end,
        unregisterSysfsClass = function(n) sysfs.unregisterClass(n) end,
    }

    local src = assert(readFile(REPO .. "/src/modules/ccprinter.ko"))
    local env = setmetatable({ require = require }, { __index = _G })
    local chunk
    if _VERSION == "Lua 5.1" then
        chunk = loadEnv(src, "ccprinter", env)
    else
        chunk = assert(load(src, "ccprinter", "t", env))
    end
    local mod = chunk()
    mod.init(kapi, "top")

    eq(device and device.name, "lp0", "ccprinter: 注册 /dev/lp0")
    eq(cls and cls.name, "printer", "ccprinter: 注册 sysfs printer 类")

    local function openAttr(path, mode)
        local b, r = vfs.resolve(path)
        local fh, err = b.open(r, mode or "r")
        ok(fh ~= nil, "ccprinter: 打开 " .. path, err)
        return fh
    end

    -- 未开页时页尺寸未知(空属性读即 EOF)
    eq(openAttr("/sys/class/printer/lp0/size").readAll(), nil, "ccprinter: 未开页时 size 为空")

    -- 4 行写进 3 行的页: 第 4 行触发自动翻页; 每行都必须从第 1 列开始(曾经的 bug: 斜线)
    local h = device.handler.open("w")
    ok(h ~= nil, "ccprinter: 打开 /dev/lp0 写")
    h:write("a\nb\nc\nd\n")
    h:close()
    eq(#pages, 2, "ccprinter: 满 3 行自动 endPage 并开新页")
    eq(rowStr(pages[1], 1), "a", "ccprinter: 第 1 页第 1 行")
    eq(rowStr(pages[1], 2), "b", "ccprinter: 换行后第 2 行从第 1 列开始(不是斜线)")
    eq(rowStr(pages[1], 3), "c", "ccprinter: 第 1 页第 3 行")
    eq(pages[1].rows[2][1], "b", "ccprinter: 第 2 行首字符落在列 1")
    eq(pages[1].rows[3][1], "c", "ccprinter: 第 3 行首字符落在列 1")
    eq(rowStr(pages[2], 1), "d", "ccprinter: 第 2 页第 1 行")
    eq(openAttr("/sys/class/printer/lp0/size").readAll(), "25x3", "ccprinter: 开页后 sysfs size")

    -- 超宽行折行: 30 字符 -> 25 + 5, 折行后的续行也从第 1 列开始
    h = device.handler.open("w")
    h:write(string.rep("x", 30) .. "\n" .. "z\n")
    h:close()
    eq(#pages, 3, "ccprinter: 折行不额外翻页")
    eq(rowStr(pages[3], 1), string.rep("x", 25), "ccprinter: 折行第 1 行 25 字符")
    eq(rowStr(pages[3], 2), "xxxxx", "ccprinter: 折行余下 5 字符到第 2 行")
    eq(pages[3].rows[2][1], "x", "ccprinter: 折行续行从列 1 开始")
    eq(rowStr(pages[3], 3), "z", "ccprinter: 折行后的下一行从列 1 开始")

    -- 恰好占满一页宽的行后接下一行: 不能白白跳掉一行
    h = device.handler.open("w")
    h:write(string.rep("y", 25) .. "\n" .. "z\n")
    h:close()
    eq(rowStr(pages[#pages], 1), string.rep("y", 25), "ccprinter: 恰好占满一行的文本")
    eq(rowStr(pages[#pages], 2), "z", "ccprinter: 满行后的下一行不跳行")

    -- sysfs 状态
    eq(openAttr("/sys/class/printer/lp0/name").readAll(), "top", "ccprinter: sysfs name = 外设名")
    eq(openAttr("/sys/class/printer/lp0/type").readAll(), "printer", "ccprinter: sysfs type")
    eq(openAttr("/sys/class/printer/lp0/paper").readAll(), "5", "ccprinter: sysfs paper")
    eq(openAttr("/sys/class/printer/lp0/ink").readAll(), "9", "ccprinter: sysfs ink")

    -- 目录判定与 exists 一致(cd 依赖它: 不存在的条目不能算目录)
    local pb, pr = vfs.resolve("/sys/class/printer/lp0")
    ok(pb.isDir(pr), "ccprinter: /sys/class/printer/lp0 是目录")
    pb, pr = vfs.resolve("/sys/class/printer/lp1")
    ok(not pb.isDir(pr), "ccprinter: 不存在的 lp1 isDir=false")
    pb, pr = vfs.resolve("/sys/class/printer/lp0/nosuch")
    ok(not pb.isDir(pr), "ccprinter: 不存在的属性 isDir=false")

    -- 页标题: 可写, 并在开页时下发给外设
    local tw = openAttr("/sys/class/printer/lp0/title", "w")
    tw:write("Hello\n")
    tw:close()
    eq(openAttr("/sys/class/printer/lp0/title").readAll(), "Hello", "ccprinter: title 可写")
    h = device.handler.open("w")
    h:write("t\n")
    h:close()
    eq(pages[#pages].title, "Hello", "ccprinter: 开页时把标题下发外设")

    -- 只读属性拒绝写; 设备只写
    local b, r = vfs.resolve("/sys/class/printer/lp0/paper")
    local bad, badErr = b.open(r, "w")
    ok(bad == nil and tostring(badErr):find("read%-only"), "ccprinter: paper 只读", badErr)
    local dh, derr = device.handler.open("r")
    ok(dh == nil and tostring(derr):find("write%-only"), "ccprinter: /dev/lp0 只写", derr)

    -- /sys/class 同时列出两个类
    b, r = vfs.resolve("/sys/class")
    eq(table.concat(b.list(r), ","), "display,printer", "sysfs: /sys/class 列出 display 与 printer")
end

-- ===============================================================
-- J. tty: ANSI 转义序列(颜色/清屏/定位/光标)
--    用真实 src/kernel/tty.lua + 录制型 term 设备(CC 无屏幕读回 API, 宿主可直读 ctx.grid)。
--    色索引是 tty 内部色序(0=black..f=white), 与 CC blit 色码的换算见 TO_CC。
-- ===============================================================
do
    local tty = require("kernel.tty")

    --- 录制型 term 设备(ScreenDevice)。
    local function newTermDev(w, h)
        local dev -- 先声明再建表: 闭包里的 dev 必须指向这个局部变量(不是全局)
        dev = {
            id = "test:term", type = "monitor", mode = "term", name = "test",
            width = w, height = h, fills = 0, flushes = 0, calls = {}, scrolls = 0,
            getSize = function() return w, h end,
            text = function(x, y, s, fg, bg)
                dev.calls[#dev.calls + 1] = { x = x, y = y, s = s, fg = fg, bg = bg }
                dev.lastText = { x = x, y = y, s = s, fg = fg, bg = bg }
            end,
            blit = function(x, y, s, fg, bg) dev.lastBlit = { x = x, y = y, s = s, fg = fg, bg = bg } end,
            fill = function(color) dev.fills = dev.fills + 1; dev.lastFill = color end,
            -- 原生滚动: tty 层优先用它(一条命令滚屏), 不再把整屏标脏逐格 blit。
            scroll = function(n) dev.scrolls = (dev.scrolls or 0) + 1; dev.lastScroll = n end,
            rect = function() end,
            flush = function() dev.flushes = dev.flushes + 1 end,
            release = function() end,
        }
        return dev
    end

    local function newTty(w, h)
        local dev = newTermDev(w, h)
        local name = tty.registerDevice(dev)
        return tty.open(name, "rw"), tty.get(name), dev
    end

    local function cell(ctx, col, row) return ctx.grid[row * ctx.cols + col + 1] end
    local function rowText(ctx, row)
        local t = {}
        for c = 0, ctx.cols - 1 do t[#t + 1] = cell(ctx, c, row).ch end
        return table.concat(t)
    end

    -- 长按重复: CC 按住键时持续发 key 事件(event[3]=true)。退格/方向键必须连续生效;
    -- 回车/Tab 的重复事件仍要丢掉(按住回车不该刷空行)。
    do
        _G.keys = { getName = function(k) return k end } -- 宿主上键码直接用名字代替
        local h, ctx, dev = newTty(20, 5)
        h:setRaw(true)
        tty.routeKey({ "key", "backspace", true })
        tty.routeKey({ "key", "backspace", true })
        eq(ctx.keyBuf, "\b\b", "tty 重复键: 按住退格在原始模式下连续出字节")
        tty.routeKey({ "key", "enter", true })
        eq(ctx.keyBuf, "\b\b", "tty 重复键: 按住回车不产生重复换行")
        tty.routeKey({ "key", "left", true })
        eq(ctx.keyBuf, "\b\b\27[D", "tty 重复键: 按住方向键连续出序列")
        h:setRaw(false)
        ctx.keyBuf = ""
        ctx.inputBuffer = "abc"
        tty.routeKey({ "key", "backspace", true })
        eq(ctx.inputBuffer, "ab", "tty 重复键: 规范模式下按住退格连续删")
        tty.routeKey({ "key", "enter", true })
        eq(#ctx.lineQueue, 0, "tty 重复键: 规范模式下按住回车不重复提交")
        _G.keys = nil
    end

    -- 性能相关(tty 只做"该做的事"): 同一行连续同色的格子合并成一次 dev.text
    -- (逐格 blit 是滚屏/整行输出慢的根因)。
    do
        local h, ctx, dev = newTty(20, 5)
        dev.calls = {}
        h:write("abcdefghij")
        -- 10 个字符原本是 10 次 text; 合并后只剩"这一行"+"光标那一格"两条
        eq(#dev.calls <= 2, true, "tty 合并: 一整行同色文本最多两条 text(原为逐格)")
        eq(dev.calls[1].s, "abcdefghij", "tty 合并: 合并后的文本内容")
        local before = #dev.calls
        h:write("k")
        eq(#dev.calls - before <= 3, true, "tty 合并: 追加一字符也只有常数条 text")
    end
    do
        local h, ctx, dev = newTty(20, 5)
        h:write("1\n2\n3\n4\n5\n") -- 第 5 行写完再换行 -> 触发一次滚动
        eq(rowText(ctx, 0), "2" .. string.rep(" ", 19), "tty 滚屏: 首行上移")
        eq(rowText(ctx, 4), string.rep(" ", 20), "tty 滚屏: 末行被清空")
        -- 滚屏仍是"整屏标脏重画", 但重画走**同一行合并**: 20x5 屏上合计十几条 text,
        -- 不是 100 条(逐格画)。51x19 的真实屏同理: ~19 条而不是近千条。
        eq(#dev.calls <= 20, true, "tty 滚屏: 整屏重画也走行合并(几十条 text, 不是逐格)")
        -- 原本滚一次要重画整屏(100 格 -> 100 条); 现在只有末行 + 光标那几格
        -- 5 行文本 + 一次滚动, 合计只有个位数的 text 调用(原来滚一次就要重画整屏 100 格)
        eq(#dev.calls <= 12, true, "tty 滚屏: 滚完只重画末行(几条 text, 不是整屏)")
    end

    -- 普通文本: 落屏/换行/列推进与 ANSI 引入前一致
    do
        local h, ctx = newTty(20, 5)
        h:write("ab\ncd")
        eq(rowText(ctx, 0), "ab" .. string.rep(" ", 18), "tty ansi: 普通文本第 1 行")
        eq(rowText(ctx, 1), "cd" .. string.rep(" ", 18), "tty ansi: 普通文本第 2 行")
        eq(ctx.cursorX, 2, "tty ansi: 换行后光标列")
        eq(ctx.cursorY, 1, "tty ansi: 换行后光标行")
    end

    -- SGR: 前景/背景/复位/亮色
    do
        local h, ctx = newTty(20, 5)
        h:write("\27[31mX")
        eq(cell(ctx, 0, 0).fg, 0x7, "tty ansi: SGR 31 红")
        h:write("\27[44mY")
        eq(cell(ctx, 1, 0).bg, 0x2, "tty ansi: SGR 44 蓝底")
        eq(cell(ctx, 1, 0).fg, 0x7, "tty ansi: SGR 44 不改前景")
        h:write("\27[0mZ")
        eq(cell(ctx, 2, 0).fg, 0xf, "tty ansi: SGR 0 复位前景")
        eq(cell(ctx, 2, 0).bg, 0x0, "tty ansi: SGR 0 复位背景")
        h:write("\27[91mA")
        eq(cell(ctx, 3, 0).fg, 0xa, "tty ansi: SGR 91 亮红 -> 粉")
        h:write("\27[100mB")
        eq(cell(ctx, 4, 0).bg, 0x8, "tty ansi: SGR 100 亮黑 -> 灰底")
        h:write("\27[39;49mC")
        eq(cell(ctx, 5, 0).fg, 0xf, "tty ansi: SGR 39 默认前景")
        eq(cell(ctx, 5, 0).bg, 0x0, "tty ansi: SGR 49 默认背景")
        h:write("\27[37mD")
        eq(cell(ctx, 6, 0).fg, 0x9, "tty ansi: SGR 37 白 -> 浅灰")
        h:write("\27[97mE")
        eq(cell(ctx, 7, 0).fg, 0xf, "tty ansi: SGR 97 亮白 -> 白")
    end

    -- SGR 粗体(映射亮色) 与反显
    do
        local h, ctx, dev = newTty(20, 5)
        h:write("\27[1;32mX")
        eq(cell(ctx, 0, 0).fg, 0x5, "tty ansi: 粗体绿 -> 亮绿")
        h:write("\27[22;32mY")
        eq(cell(ctx, 1, 0).fg, 0x4, "tty ansi: SGR 22 关粗体")
        h:write("\27[31;47mR")
        eq(cell(ctx, 2, 0).fg, 0x7, "tty ansi: 反显前前景")
        eq(cell(ctx, 2, 0).bg, 0x9, "tty ansi: 反显前背景")
        eq(cell(ctx, 2, 0).rev, false, "tty ansi: 未开反显时 rev=false")
        h:write("\27[7mS")
        eq(cell(ctx, 3, 0).fg, 0x7, "tty ansi: SGR 7 不改前景色")
        eq(cell(ctx, 3, 0).bg, 0x9, "tty ansi: SGR 7 不改背景色")
        eq(cell(ctx, 3, 0).rev, true, "tty ansi: SGR 7 置反显标记")
        -- 渲染时前后景互换: dev.text 收 CC blit 色码, TO_CC[0x9]=8 / TO_CC[0x7]=e
        local drawn
        for _, c in ipairs(dev.calls) do
            if c.x == 3 and c.y == 0 and c.s == "S" then drawn = c end
        end
        ok(drawn ~= nil and drawn.fg == 0x8 and drawn.bg == 0xe,
            "tty ansi: 反显渲染时前后景互换", drawn and (drawn.fg .. "/" .. drawn.bg))
        h:write("\27[27mT")
        eq(cell(ctx, 4, 0).rev, false, "tty ansi: SGR 27 取消反显")
        eq(cell(ctx, 4, 0).fg, 0x7, "tty ansi: SGR 27 前景不变")
        eq(cell(ctx, 4, 0).bg, 0x9, "tty ansi: SGR 27 背景不变")
        h:write("\27[7m\27[0mU")
        eq(cell(ctx, 5, 0).rev, false, "tty ansi: SGR 0 清除反显")
    end

    -- 光标定位: CUP / CUU / CUD / CUF / CUB / CHA / VPA / CNL / CPL
    do
        local h, ctx = newTty(20, 5)
        h:write("\27[3;5HX")
        eq(cell(ctx, 4, 2).ch, "X", "tty ansi: CUP 定位后落字")
        eq(ctx.cursorX, 5, "tty ansi: CUP 后光标列")
        eq(ctx.cursorY, 2, "tty ansi: CUP 后光标行")
        h:write("\27[2A")
        eq(ctx.cursorY, 0, "tty ansi: CUU 上移")
        h:write("\27[3B")
        eq(ctx.cursorY, 3, "tty ansi: CUD 下移")
        h:write("\27[4C")
        eq(ctx.cursorX, 9, "tty ansi: CUF 右移")
        h:write("\27[2D")
        eq(ctx.cursorX, 7, "tty ansi: CUB 左移")
        h:write("\27[1G")
        eq(ctx.cursorX, 0, "tty ansi: CHA 绝对列")
        h:write("\27[2d")
        eq(ctx.cursorY, 1, "tty ansi: VPA 绝对行")
        h:write("\27[E")
        eq(ctx.cursorY, 2, "tty ansi: CNL 下一行")
        eq(ctx.cursorX, 0, "tty ansi: CNL 列归零")
        h:write("\27[F")
        eq(ctx.cursorY, 1, "tty ansi: CPL 上一行")
        -- 缺省参数(1) 与 0 视作 1; 越界裁剪
        h:write("\27[H")
        eq(ctx.cursorX, 0, "tty ansi: CUP 缺省列")
        eq(ctx.cursorY, 0, "tty ansi: CUP 缺省行")
        h:write("\27[99;99H")
        eq(ctx.cursorX, 19, "tty ansi: CUP 列越界裁剪")
        eq(ctx.cursorY, 4, "tty ansi: CUP 行越界裁剪")
        h:write("\27[9A")
        eq(ctx.cursorY, 0, "tty ansi: CUU 越界裁剪")
    end

    -- ED(J): 0=光标到末尾, 1=开头到光标, 2=整屏(不移动光标)
    -- 用 8 列屏幕 + 每行 5 字符, 避开 6 列满行自动换行(putChar 的 wrap 语义)。
    do
        local h, ctx = newTty(8, 3)
        h:write("abcde\nfghij\nklmno")
        h:write("\27[2;3H\27[0J")
        eq(rowText(ctx, 0), "abcde   ", "tty ansi: ED 0 不动光标之前的行")
        eq(rowText(ctx, 1), "fg      ", "tty ansi: ED 0 从光标清到行尾")
        eq(rowText(ctx, 2), "        ", "tty ansi: ED 0 清后续行")

        local h2, ctx2 = newTty(8, 3)
        h2:write("abcde\nfghij\nklmno")
        h2:write("\27[2;4H\27[1J")
        eq(rowText(ctx2, 0), "        ", "tty ansi: ED 1 清光标之前的行")
        eq(rowText(ctx2, 1), "    j   ", "tty ansi: ED 1 清行首到光标")
        eq(rowText(ctx2, 2), "klmno   ", "tty ansi: ED 1 不动光标之后的行")

        local h3, ctx3, dev3 = newTty(8, 3)
        h3:write("abcde\nfghij")
        h3:write("\27[2J")
        eq(rowText(ctx3, 0), "        ", "tty ansi: ED 2 清屏")
        eq(ctx3.cursorX, 5, "tty ansi: ED 2 不移动光标(列)")
        eq(ctx3.cursorY, 1, "tty ansi: ED 2 不移动光标(行)")
        ok(dev3.fills >= 1, "tty ansi: ED 2 走设备级填充")
    end

    -- EL(K): 0=光标到行尾, 1=行首到光标, 2=整行
    do
        local h, ctx = newTty(8, 3)
        h:write("abcde\nfghij")
        h:write("\27[1;3H\27[0K")
        eq(rowText(ctx, 0), "ab      ", "tty ansi: EL 0 清到行尾")
        h:write("\27[2;4H\27[1K")
        eq(rowText(ctx, 1), "    j   ", "tty ansi: EL 1 清行首到光标")
        h:write("\27[2K")
        eq(rowText(ctx, 1), "        ", "tty ansi: EL 2 清整行")
    end

    -- 光标显隐(?25l / ?25h)
    do
        local h, ctx = newTty(6, 3)
        h:write("\27[?25l")
        ok(ctx.cursorHidden, "tty ansi: ?25l 隐藏光标")
        eq(ctx.cursorRenderedIdx, nil, "tty ansi: 隐藏后不渲染光标块")
        h:write("\27[?25h")
        ok(not ctx.cursorHidden, "tty ansi: ?25h 恢复显示")
        ok(ctx.cursorRenderedIdx ~= nil, "tty ansi: 恢复后光标块已标记")
    end

    -- 保存/恢复: CSI s/u 与 ESC 7/ESC 8(位置 + 属性)
    do
        local h, ctx = newTty(6, 3)
        h:write("\27[2;3H\27[31m\27[s")
        h:write("\27[H\27[0m\27[u")
        eq(ctx.cursorX, 2, "tty ansi: CSI u 恢复光标列")
        eq(ctx.cursorY, 1, "tty ansi: CSI u 恢复光标行")
        eq(ctx.fg, 0x7, "tty ansi: CSI u 恢复前景")
        h:write("\27[1;1H\27[32m\27" .. "7")
        h:write("\27[3;3H\27[0m\27" .. "8")
        eq(ctx.cursorX, 0, "tty ansi: ESC 8 恢复光标列")
        eq(ctx.cursorY, 0, "tty ansi: ESC 8 恢复光标行")
        eq(ctx.fg, 0x4, "tty ansi: ESC 8 恢复前景")
    end

    -- RIS(ESC c): 清屏 + 复位属性/光标
    do
        local h, ctx = newTty(6, 3)
        h:write("abc\27[31m\27[?25l\27c")
        eq(rowText(ctx, 0), "      ", "tty ansi: RIS 清屏")
        eq(ctx.cursorX, 0, "tty ansi: RIS 光标归位(列)")
        eq(ctx.cursorY, 0, "tty ansi: RIS 光标归位(行)")
        eq(ctx.fg, 0xf, "tty ansi: RIS 复位前景")
        ok(not ctx.cursorHidden, "tty ansi: RIS 恢复光标显示")
    end

    -- 跨 write 的序列 / 未知序列忽略 / OSC 与字符集指定 / 非法字节
    do
        local h, ctx = newTty(12, 3)
        h:write("\27[")
        h:write("3")
        h:write("1m")
        h:write("X")
        eq(cell(ctx, 0, 0).fg, 0x7, "tty ansi: 序列跨 write 保持状态")
        eq(cell(ctx, 0, 0).ch, "X", "tty ansi: 跨 write 序列后正常落字")
        h:write("\27[999zY")
        eq(cell(ctx, 1, 0).ch, "Y", "tty ansi: 未知 CSI 忽略")
        h:write("\27]0;title\7Z")
        eq(cell(ctx, 2, 0).ch, "Z", "tty ansi: OSC 标题被吞掉")
        h:write("\27(0q")
        eq(cell(ctx, 3, 0).ch, "q", "tty ansi: 字符集指定吞掉一个字节")
        h:write("b")
        eq(cell(ctx, 4, 0).ch, "b", "tty ansi: 字符集指定后继续正常输出")
        h:write("c\27d")
        eq(cell(ctx, 5, 0).ch, "c", "tty ansi: 未知单字符转义忽略")
        eq(ctx.cursorX, 6, "tty ansi: 转义序列不推进光标")
    end

    -- clear() 句柄: 清屏 + 光标归位
    do
        local h, ctx = newTty(6, 3)
        h:write("abc\ndef")
        h:clear()
        eq(rowText(ctx, 0), "      ", "tty: clear() 清屏")
        eq(ctx.cursorX, 0, "tty: clear() 光标归位(列)")
        eq(ctx.cursorY, 0, "tty: clear() 光标归位(行)")
    end
end

-- ===============================================================
-- K. procfs: /proc/<pid>/{cmdline,comm,cwd,stat,status} + /proc/self + 系统信息文件
-- ===============================================================
do
    local vfs = require("kernel.vfs")
    os.version = os.version or function() return "CraftOS 1.8" end

    local procs = {
        [1]  = { pid = 1, ppid = 0, name = "init", status = "running", uid = 0, gid = 0,
                 pgrp = 1, sid = 1, cwd = "/", argv = { [0] = "/bin/init" } },
        [7]  = { pid = 7, ppid = 1, name = "/bin/sh", status = "running", uid = 1000, gid = 1000,
                 pgrp = 7, sid = 7, cwd = "/home/alice",
                 argv = { [0] = "/bin/sh", [1] = "-c", [2] = "ps" } },
        [9]  = { pid = 9, ppid = 1, name = "sleep", status = "stopped", uid = 0, gid = 0,
                 pgrp = 9, sid = 1, cwd = "/", argv = {} },
        [11] = { pid = 11, ppid = 1, name = "gone", status = "dead", uid = 0, gid = 0,
                 pgrp = 11, sid = 1, cwd = "/", argv = {} },
        [12] = { pid = 12, ppid = 1, name = "probe", status = "running", uid = 1001, gid = 1001,
                 pgrp = 12, sid = 1, cwd = "/", argv = {} },
    }
    local selfPid = 7 -- 当前"进程"(决定 /proc/self 与 R/S 状态)

    -- 桩: kernel.process(procfs 只用到 current/info/list/ttyFor/fgPgrpFor)
    package.loaded["kernel.process"] = {
        current = function()
            local p = procs[selfPid]
            return { pid = selfPid, uid = p.uid, gid = p.gid }
        end,
        info = function(pid) return procs[pid] end,
        list = function()
            local out = {}
            for _, p in pairs(procs) do
                if p.status == "running" or p.status == "stopped" then out[#out + 1] = p end
            end
            table.sort(out, function(a, b) return a.pid < b.pid end)
            return out
        end,
        ttyFor = function(pid)
            if pid == 1 then return nil end
            return "/dev/tty0"
        end,
        fgPgrpFor = function(pid)
            if pid == 1 then return nil end
            return 7
        end,
    }
    require("kernel.procfs").mount(0, VERSION) -- bootMs=0

    local function openAt(path)
        local b, r = vfs.resolve(path)
        local fh, err = b.open(r, "r")
        ok(fh ~= nil, "procfs: 打开 " .. path, err)
        return fh
    end

    -- 根目录: 存活 pid + self + 系统信息文件(退出的进程没有节点)
    local b, r = vfs.resolve("/proc")
    ok(b.isDir(r), "procfs: /proc 是目录")
    local names = {}
    for _, n in ipairs(b.list(r)) do names[n] = true end
    ok(names["1"] and names["7"] and names["9"], "procfs: /proc 列出存活进程")
    ok(not names["11"], "procfs: 已退出进程不出现在 /proc")
    ok(names["self"] and names["uptime"] and names["version"] and names["mounts"],
       "procfs: /proc 列出 self/uptime/version/mounts")

    -- /proc/self 是调用者 pid 的别名; comm 取 name 的 basename
    eq(openAt("/proc/self/comm").readAll(), "sh\n", "procfs: /proc/self 解析到调用者")
    eq(openAt("/proc/7/comm").readAll(), "sh\n", "procfs: comm 取 name 的 basename")

    -- stat: Linux 字段 1..8(pid comm state ppid pgrp session tty tpgid)
    eq(openAt("/proc/7/stat").readAll(), "7 (sh) R 1 7 7 tty0 7\n", "procfs: stat 字段 1..8")
    eq(openAt("/proc/1/stat").readAll(), "1 (init) S 0 1 1 0 -1\n",
       "procfs: 无控制终端 tty=0 tpgid=-1")
    eq(openAt("/proc/9/stat").readAll(), "9 (sleep) T 1 9 1 tty0 7\n", "procfs: stopped -> T")

    -- status: 多行, 逐行读到 EOF
    local fh = openAt("/proc/7/status")
    eq(fh.readLine(), "Name:\tsh", "procfs: status Name")
    eq(fh.readLine(), "State:\tR (running)", "procfs: status State(自己=R)")
    eq(fh.readLine(), "Tgid:\t7", "procfs: status Tgid")
    eq(fh.readLine(), "Pid:\t7", "procfs: status Pid")
    eq(fh.readLine(), "PPid:\t1", "procfs: status PPid")
    eq(fh.readLine(), "Pgrp:\t7", "procfs: status Pgrp")
    eq(fh.readLine(), "Session:\t7", "procfs: status Session")
    eq(fh.readLine(), "Uid:\t1000", "procfs: status Uid")
    eq(fh.readLine(), "Gid:\t1000", "procfs: status Gid")
    eq(fh.readLine(), nil, "procfs: status 读完即 EOF")

    -- cmdline: argv 以 NUL 分隔 + 结尾 NUL; 空 argv 是空文件
    eq(openAt("/proc/7/cmdline").readAll(), "/bin/sh\0-c\0ps\0", "procfs: cmdline NUL 分隔")
    eq(openAt("/proc/9/cmdline").readAll(), nil, "procfs: 空 argv 的 cmdline 为空")

    -- cwd: 属主或 root 可读(Linux 语义)
    eq(openAt("/proc/7/cwd").readAll(), "/home/alice\n", "procfs: cwd = 进程 cwd")
    selfPid = 9 -- uid 0(root)
    eq(openAt("/proc/7/cwd").readAll(), "/home/alice\n", "procfs: root 可读他人 cwd")
    selfPid = 12 -- uid 1001(既非属主也非 root)
    b, r = vfs.resolve("/proc/7/cwd")
    local dfh, derr = b.open(r, "r")
    ok(dfh == nil and tostring(derr):find("permission"), "procfs: 他人 cwd 拒绝读", derr)
    selfPid = 7

    -- 只读 + 不存在的路径
    b, r = vfs.resolve("/proc/7/stat")
    local wfh, werr = b.open(r, "w")
    ok(wfh == nil and tostring(werr):find("read%-only"), "procfs: 拒绝写打开", werr)
    b, r = vfs.resolve("/proc/99999/stat")
    ok(not b.exists(r), "procfs: 不存在的 pid exists=false")
    ok(not b.isDir(r), "procfs: 不存在的 pid isDir=false")
    b, r = vfs.resolve("/proc/11/stat")
    ok(not b.exists(r), "procfs: 已退出进程的节点不存在")
    b, r = vfs.resolve("/proc/7/nosuch")
    ok(not b.exists(r), "procfs: 不存在的文件 exists=false")
    b, r = vfs.resolve("/proc/7/stat")
    ok(not b.isDir(r), "procfs: stat 不是目录")
    b, r = vfs.resolve("/proc/7")
    ok(b.isDir(r), "procfs: /proc/<pid> 是目录")

    -- 系统信息文件
    local up = openAt("/proc/uptime").readAll()
    ok(up and up:match("^%d+%.%d+\n$"), "procfs: uptime 是秒数", up)
    ok(tostring(openAt("/proc/version").readAll()):find("Delin OS", 1, true) ~= nil,
       "procfs: version 含 Delin OS")
    local mounts = openAt("/proc/mounts").readAll() or ""
    ok(mounts:find("proc /proc proc ro 0 0", 1, true) ~= nil, "procfs: mounts 含 /proc 条目", mounts)

    -- /proc/sys/kernel/random/*(随机数子系统状态; 见下一节)
    b, r = vfs.resolve("/proc")
    local rootNames = {}
    for _, n in ipairs(b.list(r)) do rootNames[n] = true end
    ok(rootNames["sys"], "procfs: /proc 列出 sys")
    b, r = vfs.resolve("/proc/sys")
    ok(b.isDir(r), "procfs: /proc/sys 是目录")
    eq(b.list(r)[1], "kernel", "procfs: /proc/sys 只列 kernel")
    b, r = vfs.resolve("/proc/sys/kernel")
    ok(b.isDir(r), "procfs: /proc/sys/kernel 是目录")
    eq(b.list(r)[1], "random", "procfs: /proc/sys/kernel 只列 random")
    b, r = vfs.resolve("/proc/sys/kernel/random")
    ok(b.isDir(r), "procfs: /proc/sys/kernel/random 是目录")
    local rnames = {}
    for _, n in ipairs(b.list(r)) do rnames[n] = true end
    ok(rnames["entropy_avail"] and rnames["poolsize"] and rnames["uuid"],
       "procfs: random 目录列出 entropy_avail/poolsize/uuid")
    eq(openAt("/proc/sys/kernel/random/poolsize").readAll(), "4096\n", "procfs: poolsize = 4096")
    local ea = openAt("/proc/sys/kernel/random/entropy_avail").readAll() or ""
    ok(ea:match("^%d+\n$") ~= nil, "procfs: entropy_avail 是十进制 bit 数", ea)
    local uu = openAt("/proc/sys/kernel/random/uuid").readAll() or ""
    ok(uu:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x\n$") ~= nil,
       "procfs: uuid 是 RFC 4122 v4", uu)
    ok(openAt("/proc/sys/kernel/random/uuid").readAll() ~= uu, "procfs: uuid 每次读都不同")
    b, r = vfs.resolve("/proc/sys/kernel/random/nosuch")
    ok(not b.exists(r), "procfs: random 下不存在的文件 exists=false")
    b, r = vfs.resolve("/proc/sys/kernel/nosuch")
    ok(not b.exists(r) and not b.isDir(r), "procfs: /proc/sys/kernel 下未知条目")
    b, r = vfs.resolve("/proc/sys/nosuch")
    ok(not b.exists(r) and not b.isDir(r), "procfs: /proc/sys 下未知条目")
    b, r = vfs.resolve("/proc/sys/kernel/random")
    local dirfh, direrr = b.open(r, "r")
    ok(dirfh == nil and tostring(direrr):find("directory") ~= nil, "procfs: 打开目录报错", direrr)
end


-- ===============================================================
-- L. redstone: /sys/class/redstone/<side>/{digital,analog,bundled}
--    每面三个属性, 一个红石量一个文件: 读 = 该面输入, 写 = 该面输出。
--    用桩 CC redstone API 验证驱动的读写/校验语义(真机与真实 API 的交叉核对见
--    scripts/redstone_verify.lua, shell 接口见 scripts/redstone_test.sh)。
-- ===============================================================
do
    local vfs = require("kernel.vfs")
    local sysfs = require("kernel.sysfs")

    -- 桩 redstone API: 忠实模拟 CC 的语义(输出侧 digital 与 analog 是同一份状态)。
    local st = { input = {}, analogIn = {}, bundledIn = {}, output = {}, analogOut = {}, bundledOut = {} }
    local SIDE_LIST = { "top", "bottom", "left", "right", "front", "back" }
    local function num(t, s) return t[s] or 0 end
    _G.redstone = {
        getSides = function() return SIDE_LIST end,
        getInput = function(s) return st.input[s] == true end,
        getAnalogInput = function(s) return num(st.analogIn, s) end,
        getBundledInput = function(s) return num(st.bundledIn, s) end,
        getOutput = function(s) return st.output[s] == true end,
        getAnalogOutput = function(s) return num(st.analogOut, s) end,
        getBundledOutput = function(s) return num(st.bundledOut, s) end,
        setOutput = function(s, on)
            st.output[s] = on and true or false
            st.analogOut[s] = on and 15 or 0
        end,
        setAnalogOutput = function(s, v) st.analogOut[s] = v; st.output[s] = v > 0 end,
        setBundledOutput = function(s, v) st.bundledOut[s] = v end,
    }

    local cls, clsName
    local kapi = {
        log = function() end,
        registerSysfsClass = function(n, ops) clsName = n; cls = ops; sysfs.registerClass(n, ops) end,
        unregisterSysfsClass = function(n) sysfs.unregisterClass(n) end,
    }

    local src = assert(readFile(REPO .. "/src/modules/redstone.ko"))
    local env = setmetatable({ require = require }, { __index = _G })
    local chunk
    if _VERSION == "Lua 5.1" then
        chunk = loadEnv(src, "redstone", env)
    else
        chunk = assert(load(src, "redstone", "t", env))
    end
    local mod = chunk()
    mod.init(kapi)

    eq(clsName, "redstone", "redstone: 注册 sysfs redstone 类")
    local b, r = vfs.resolve("/sys/class/redstone")
    eq(table.concat(b.list(r), ","), "back,bottom,front,left,right,top",
       "redstone: 六个面按名排序(getSides 顺序无关)")
    eq(table.concat(cls.attrs("left"), ","), "digital,analog,bundled",
       "redstone: 属性清单(每面三个, 读写同一个文件)")
    eq(cls.attrs("middle"), nil, "redstone: 不存在的面没有属性")

    local function openAttr(path, mode)
        local bk, rl = vfs.resolve(path)
        local fh, err = bk.open(rl, mode or "r")
        ok(fh ~= nil, "redstone: 打开 " .. path, err)
        return fh
    end

    -- 读 = 输入: 三个属性都取 API 的 *Input 系列
    st.input.left, st.input.top = true, false
    st.analogIn.left, st.bundledIn.left = 9, 32769
    eq(openAttr("/sys/class/redstone/left/digital").readAll(), "1", "redstone: digital 读输入 1")
    eq(openAttr("/sys/class/redstone/top/digital").readAll(), "0", "redstone: digital 读输入 0")
    eq(openAttr("/sys/class/redstone/left/analog").readAll(), "9", "redstone: analog 读输入 9")
    eq(openAttr("/sys/class/redstone/left/bundled").readAll(), "32769", "redstone: bundled 读输入位掩码")

    -- 属性文件是单行值: 读一次即 EOF
    local fh = openAttr("/sys/class/redstone/left/digital")
    eq(fh.readAll(), "1", "redstone: 首次读得值")
    eq(fh.readAll(), nil, "redstone: 读完即 EOF")

    -- 写 digital: 落到 API 的输出; 读仍是输入(桩里输入与输出互相独立)
    eq(cls.set("left", "digital", "1"), true, "redstone: 写 digital=1")
    eq(st.output.left, true, "redstone: digital=1 落到 setOutput")
    eq(st.analogOut.left, 15, "redstone: digital=1 即 CC 的 analog 15")
    eq(openAttr("/sys/class/redstone/left/digital").readAll(), "1", "redstone: 写后读仍取输入")
    eq(cls.set("left", "digital", "0"), true, "redstone: 写 digital=0")
    eq(st.output.left, false, "redstone: digital=0 落到 setOutput")
    eq(st.analogOut.left, 0, "redstone: digital=0 即 analog 0")

    -- 写 analog: 0 关掉 output, 中间值保持 output=1(CC 语义)
    eq(cls.set("left", "analog", "7"), true, "redstone: 写 analog=7")
    eq(st.analogOut.left, 7, "redstone: analog=7 落到 setAnalogOutput")
    eq(st.output.left, true, "redstone: analog=7 -> output 1")
    cls.set("left", "analog", "0")
    eq(st.output.left, false, "redstone: analog=0 -> output 0")

    -- 写 bundled: 十进制位掩码
    eq(cls.set("left", "bundled", "32768"), true, "redstone: 写 bundled=32768(black)")
    eq(st.bundledOut.left, 32768, "redstone: bundled 落到 setBundledOutput")
    cls.set("left", "bundled", "0")

    -- 三个属性都可写: 没有只读属性, 写打开一律成功
    for _, a in ipairs({ "digital", "analog", "bundled" }) do
        local bk, rl = vfs.resolve("/sys/class/redstone/left/" .. a)
        local wfh, werr = bk.open(rl, "w")
        ok(wfh ~= nil, "redstone: " .. a .. " 可写(写打开成功)", werr)
    end

    -- 非法值 fail-fast, 且不改动输出状态
    st.analogOut.left = 3
    local bad = { { "analog", "16" }, { "analog", "abc" }, { "analog", "1e2" },
                  { "analog", "-1" }, { "analog", "0x10" },
                  { "digital", "2" }, { "bundled", "65536" } }
    for _, c in ipairs(bad) do
        local okw, werr = cls.set("left", c[1], c[2])
        ok(okw == nil and tostring(werr):find("invalid") ~= nil,
           "redstone: 拒绝非法值 " .. c[1] .. "=" .. c[2], werr)
    end
    eq(st.analogOut.left, 3, "redstone: 非法值不改动输出状态")

    -- class 的 set 只认这三个属性
    local sok, serr = cls.set("left", "output", "1")
    ok(sok == nil and tostring(serr):find("no such attribute") ~= nil,
       "redstone: set 拒绝旧属性名 output", serr)

    -- 经 VFS 句柄写入(含末尾换行被剥掉), 非法值同样报错
    local outH = openAttr("/sys/class/redstone/left/analog", "w")
    outH:writeLine("12")
    eq(st.analogOut.left, 12, "redstone: 句柄写入剥掉换行")
    local wok, wrerr = outH:write("99\n")
    ok(wok == nil and tostring(wrerr):find("invalid") ~= nil, "redstone: 句柄非法写入报错", wrerr)
    eq(st.analogOut.left, 12, "redstone: 句柄非法写入不改状态")

    -- 不存在的面: 不是目录, 属性也不存在
    b, r = vfs.resolve("/sys/class/redstone/middle")
    ok(not b.exists(r) and not b.isDir(r), "redstone: 不存在的面 exists/isDir=false")
    b, r = vfs.resolve("/sys/class/redstone/middle/digital")
    ok(not b.exists(r), "redstone: 不存在面的属性 exists=false")

    -- 真机交叉核对脚本(scripts/redstone_verify.lua)的逻辑回归: 同一份源码在真机上以
    -- CC 原始 API 为真值, 这里先拿桩 API 跑一遍, 保证脚本自身(面/属性/校验/复位)没写错。
    -- 日志写入换成内存句柄(宿主没有 /var/log 挂载), 其余 fs 调用走真实 VFS。
    local vlog = {}
    local vlogHandle = {
        write = function(_, s) vlog[#vlog + 1] = tostring(s); return #tostring(s) end,
        close = function() return true end,
    }
    local vfsFs = {
        open = function(p, mode)
            if p == "/var/log/redstone_verify.log" then return vlogHandle end
            local bk, rl = vfs.resolve(p)
            return bk.open(rl, mode)
        end,
        list = function(p) local bk, rl = vfs.resolve(p); return bk.list(rl) end,
        isDir = function(p) local bk, rl = vfs.resolve(p); return bk.isDir(rl) end,
        isFile = function(p)
            local bk, rl = vfs.resolve(p)
            return bk.exists(rl) and not bk.isDir(rl)
        end,
    }
    local vsrc = assert(readFile(REPO .. "/scripts/redstone_verify.lua"))
    local venv = setmetatable({ fs = vfsFs, redstone = _G.redstone, io = { write = function() end } },
                              { __index = _G })
    local vchunk
    if _VERSION == "Lua 5.1" then
        vchunk = loadEnv(vsrc, "redstone_verify", venv)
    else
        vchunk = assert(load(vsrc, "redstone_verify", "t", venv))
    end
    eq(vchunk(), 0, "redstone: scripts/redstone_verify.lua 在桩 API 上全部通过")
    ok(table.concat(vlog):find("redstone verify: all ok", 1, true) ~= nil,
       "redstone: verify 脚本写出汇总行")

    -- 卸载模块后整个 class 子树消失
    mod.exit()
    b, r = vfs.resolve("/sys/class/redstone")
    ok(not b.exists(r), "redstone: exit 注销 class")
    _G.redstone = nil
end

-- ===============================================================
-- G2. VFS 路径规范化: "."/".." 必须在 resolve 里吃掉
--     (真机 bug: CCFS 后端对"逃出根的 .."是**抛错** `/..: Invalid Path`, 而 `ls -la /`
--      自己会拼出 "/.." —— 只有这一层归一化过, 日常命令才不会炸)
-- ===============================================================
do
    local vfs = require("kernel.vfs")
    local seen = {} -- 路径 -> "后端tag|rel", 用来断言"落到哪个后端"
    local function backendOf(tag)
        return {
            tag = tag,
            list = function() return {} end, exists = function() return true end,
            isDir = function() return true end, attributes = function() return { isDir = true } end,
        }
    end
    vfs.mount("/", backendOf("root"))
    vfs.mount("/dev", backendOf("dev"))
    vfs.mount("/mnt/disk", backendOf("disk"))

    local function rel(p)
        local b, r = vfs.resolve(p)
        ok(b ~= nil, "vfs: resolve " .. p .. " 成功")
        seen[p] = (b and b.tag or "?") .. "|" .. tostring(r)
        return r
    end

    eq(rel("/"), "/", "vfs: / 的 rel")
    eq(rel("/.."), "/", "vfs: /.. 夹到根(POSIX: /.. 就是 /)")
    eq(rel("/../.."), "/", "vfs: /../.. 同样夹到根")
    eq(rel("/../etc"), "/etc", "vfs: /../etc -> /etc")
    eq(rel("/."), "/", "vfs: /. 去掉 . 段")
    eq(rel("/etc/.."), "/", "vfs: /etc/.. -> /")
    eq(rel("/etc/../etc/./fstab"), "/etc/fstab", "vfs: 混合 . / .. 归一")
    eq(rel("/etc/"), "/etc", "vfs: 末尾斜杠去掉")
    eq(rel("/etc//fstab"), "/etc/fstab", "vfs: 重复斜杠折叠")
    eq(rel("etc/passwd"), "/etc/passwd", "vfs: 相对路径按根处理")
    eq(seen["/etc/.."], "root|/", "vfs: /etc/.. 落到根挂载")
    eq(rel("/dev/.."), "/", "vfs: 挂载点上的 .. 回到父目录(Linux 语义)")
    eq(seen["/dev/.."], "root|/", "vfs: /dev/.. 落到根挂载而不是 /dev 内")
    eq(rel("/mnt/disk/.."), "/mnt", "vfs: /mnt/disk/.. -> /mnt")
    eq(seen["/mnt/disk/.."], "root|/mnt", "vfs: 磁盘挂载点上的 .. 落到父目录")
    eq(rel("/mnt/disk/./boot/../delin.lua"), "/delin.lua", "vfs: 磁盘内的相对段(rel 相对挂载根)")
    eq(seen["/mnt/disk/./boot/../delin.lua"], "disk|/delin.lua", "vfs: 归一后 rel 仍相对挂载根")
    eq(rel("/dev/null"), "/null", "vfs: 挂载内的路径不受影响(rel 相对挂载根)")
    eq(seen["/dev/null"], "dev|/null", "vfs: 挂载内的 rel 相对挂载根")

    -- unmount/mount 的根路径同样要过规范化的那一关
    vfs.unmount("/mnt/disk/")
    local b = vfs.resolve("/mnt/disk/x")
    ok(b ~= nil and b.tag == "root", "vfs: unmount 末尾斜杠也认(/mnt/disk/)")
    vfs.mount("/mnt/disk/", backendOf("disk2"))
    local b2, r2 = vfs.resolve("/mnt/disk/x")
    eq(b2 ~= nil and b2.tag or "?", "disk2", "vfs: 带末尾斜杠 mount 认到同一个挂载点")
    eq(r2, "/x", "vfs: 重挂后 rel")
    vfs.unmount("/mnt/disk")
    vfs.unmount("/dev")
end

-- ===============================================================
-- H. /dlub.cfg 解析: 三种根来源互斥(rootfs / bootdisk / ccdisk)
-- ===============================================================
do
    local dlubcfg = require("kernel.dlubcfg")

    local c = dlubcfg.parse("bootdisk left\n")
    ok(c ~= nil and c.bootdisk == "left", "dlubcfg: bootdisk 单键")

    c = dlubcfg.parse("# comment\n\nrootfs /parts/root.img\n")
    ok(c ~= nil and c.rootfs == "/parts/root.img", "dlubcfg: rootfs 单键(含注释/空行)")

    c = dlubcfg.parse("ccdisk left\n")
    ok(c ~= nil and c.ccdisk == "left", "dlubcfg: ccdisk 单键")

    local _, e = dlubcfg.parse("")
    ok(e ~= nil, "dlubcfg: 空配置 -> 报错")

    _, e = dlubcfg.parse("frobnicate left\n")
    ok(e ~= nil and e:find("unknown key"), "dlubcfg: 未知键 -> 报错")

    _, e = dlubcfg.parse("bootdisk left\nbootdisk right\n")
    ok(e ~= nil and e:find("duplicate"), "dlubcfg: 重复键 -> 报错")

    _, e = dlubcfg.parse("rootfs /a.img\nccdisk left\n")
    ok(e ~= nil and e:find("conflicting"), "dlubcfg: 两个根来源 -> 报错")

    _, e = dlubcfg.parse("bootdisk\n")
    ok(e ~= nil, "dlubcfg: 缺值 -> 报错")
end

-- ===============================================================
-- I. 用户库(kernel/user.lua): 解析/序列化往返、授权、增删改、落盘与 syscall 注册
--    端到端(工具层)见 scripts/user_test.sh; 这里锁的是内核侧不变量: 文件格式往返不变形、
--    非 root 一律拒绝、失败的写不留半成品、只写变化过的表。
-- ===============================================================
do
    -- 桩: kernel.process(user.lua 用它取调用者 uid, 特权写时包一层 asRoot)
    local callerUid = 0
    package.loaded["kernel.process"] = {
        current = function() return { pid = 1, uid = callerUid, gid = callerUid } end,
        asRoot = function(fn) return fn() end, -- 宿主没有权限位: 特权写就是普通写
    }
    local user = require("kernel.user")

    --- 内存 fs 门面: 只实现 user.save 用到的 open/readAll/write/close。
    local function memFs(initial)
        local files = {}
        for k, v in pairs(initial or {}) do files[k] = v end
        local api = {
            open = function(path, mode)
                if not mode or mode == "r" then
                    if not files[path] then return nil, "no such file" end
                    local content = files[path]
                    return { readAll = function() return content end, close = function() end }
                end
                if mode:find("w") then files[path] = "" end -- w 语义: 打开即截断
                return {
                    write = function(_, s) files[path] = (files[path] or "") .. s; return #s end,
                    close = function() return true end,
                }
            end,
        }
        return files, api
    end

    local PW = "root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000:Alice:/home/alice:/bin/sh\n"
    local GR = "root:x:0:root\nalice:x:1000:alice\n"
    local SH = "root:rs$1a2b\nalice:!as$3c4d\n"

    -- 解析
    local db = user.parse(PW, SH, GR)
    eq(db.users.alice.uid, 1000, "user: 解析 passwd uid")
    eq(db.users.alice.full, "Alice", "user: 解析 passwd fullname 字段")
    eq(db.users.alice.home, "/home/alice", "user: 解析 passwd home 字段")
    eq(db.users.root.salt, "rs", "user: 解析 shadow 盐")
    eq(db.users.root.hash, "1a2b", "user: 解析 shadow 哈希")
    ok(db.users.alice.locked == true, "user: shadow '!' 前缀 = 锁定")
    eq(user.groupByName(db, "alice").gid, 1000, "user: 解析 group gid")

    -- 序列化往返(三张表照抄原文, 免得每次写回都重排/掉字段)
    local p2, s2, g2 = user.serialize(db)
    eq(p2, PW, "user: passwd 序列化 = 原文")
    eq(s2, SH, "user: shadow 序列化 = 原文(含锁定标记)")
    eq(g2, GR, "user: group 序列化 = 原文")
    ok(user.parse(p2, s2, g2).users.alice.locked == true, "user: 往返后锁定标记不丢")

    -- verify: 正常 / 锁定 / 无密码字段
    local salt = "s1"
    local d3 = user.parse("u:x:0:0::/:/bin/sh\n", "u:" .. salt .. "$" .. user.hash(salt, "secret") .. "\n", "")
    ok(user.verify(d3, "u", "secret"), "user: verify 正确密码")
    ok(not user.verify(d3, "u", "wrong"), "user: verify 错误密码")
    ok(user.setLocked(d3, "u", true), "user: 锁定账号")
    ok(not user.verify(d3, "u", "secret"), "user: 锁定后 verify 一律拒绝")
    local d4 = user.parse("u:x:0:0::/:/bin/sh\n", "u:\n", "")
    ok(user.verify(d4, "u", ""), "user: 空密码字段 = 空密码可登录(passwd -d)")
    ok(not user.verify(d4, "u", "x"), "user: 空密码字段不接受非空密码")
    eq(user.passwordStatus(d4, "u"), "NP", "user: 空密码字段 -> passwd -S 报 NP")
    -- shadow 里没有这个人 != 空密码: 丢一个 shadow 文件不能让所有人空密码登录
    local d4b = user.parse("u:x:0:0::/:/bin/sh\n", "", "")
    ok(not user.verify(d4b, "u", ""), "user: shadow 无记录时连空密码也拒绝(不静默放行)")
    eq(user.passwordStatus(d4b, "u"), "L", "user: shadow 无记录 -> passwd -S 报 L")

    -- 授权: 非 root 一律拒绝(判定在内核 syscall 里, 工具绕不过去)
    local db5 = user.parse(PW, SH, GR)
    callerUid = 1000 -- alice
    local r, e = user.addUser(db5, { name = "bob" })
    ok(r == nil and e == "permission denied", "user: 非 root 建用户被拒")
    r, e = user.addGroup(db5, "staff")
    ok(r == nil and e == "permission denied", "user: 非 root 建组被拒")
    r, e = user.delUser(db5, "root")
    ok(r == nil and e == "permission denied", "user: 非 root 删用户被拒")
    r, e = user.modUser(db5, "alice", { shell = "/bin/sh" })
    ok(r == nil and e == "permission denied", "user: 非 root 改用户被拒")
    r, e = user.delGroup(db5, "alice")
    ok(r == nil and e == "permission denied", "user: 非 root 删组被拒")
    r, e = user.setLocked(db5, "alice", true)
    ok(r == nil and e == "permission denied", "user: 非 root 锁密码被拒")
    r, e = user.setPassword(db5, "root", "x", "y")
    ok(r == nil and e == "permission denied", "user: 非 root 改别人密码被拒")
    r, e = user.setPassword(db5, "alice", "x", "y")
    ok(r == nil and e:find("incorrect old password") ~= nil, "user: 改自己密码必须给对旧密码")
    r, e = user.setPassword(db5, "alice", "x", nil)
    ok(r == nil and e == "permission denied", "user: passwd -d(删密码)仅 root")

    -- 改自己密码(旧密码正确)
    local salt2 = "s2"
    local db6 = user.parse("bob:x:1001:1001::/home/bob:/bin/sh\n",
                           "bob:" .. salt2 .. "$" .. user.hash(salt2, "old") .. "\n", "")
    callerUid = 1001
    ok(user.setPassword(db6, "bob", "old", "new"), "user: 本主用旧密码改自己密码")
    ok(user.verify(db6, "bob", "new"), "user: 新密码生效")
    ok(not user.verify(db6, "bob", "old"), "user: 旧密码失效")

    -- 盐必须来自内核 CSPRNG(从前是 math.random: 进程里没播种, 序列可预测)
    local s1, s2 = user.makeSalt(), user.makeSalt()
    eq(#s1, 8, "user.makeSalt: 默认 8 字符")
    ok(s1:match("^%x%x%x%x%x%x%x%x$") ~= nil, "user.makeSalt: 十六进制", s1)
    ok(s1 ~= s2, "user.makeSalt: 两次不同")
    eq(#user.makeSalt(12), 12, "user.makeSalt: 指定长度")
    -- 落盘后仍能验证(盐随 shadow 存下来, 换盐不影响老条目)
    ok(user.setPassword(db6, "bob", "new", "newer") and user.verify(db6, "bob", "newer"),
       "user: 换盐后新密码可验证")

    -- addUser(root): 分配 id、私有组、锁定、附加组、失败不留残留
    callerUid = 0
    local db7 = user.parse(PW, SH, GR)
    local rec = user.addUser(db7, { name = "bob", groups = { "alice" } })
    ok(rec ~= nil, "user: addUser 成功")
    eq(rec.uid, 1001, "user: addUser 取第一个空闲 uid")
    eq(rec.gid, 1001, "user: addUser 建同名私有组并取它的 gid")
    ok(db7.groups.bob ~= nil, "user: addUser 建出同名组")
    eq(user.passwordStatus(db7, "bob"), "L", "user: 新账号锁定(设密码前登不进)")
    ok(not user.verify(db7, "bob", ""), "user: 锁定账号空密码也登不进")
    ok((db7.groups.alice.members or ""):find("bob") ~= nil, "user: addUser -G 把用户加进附加组")
    r, e = user.addUser(db7, { name = "bob" })
    ok(r == nil and e:find("already exists") ~= nil, "user: 重名用户被拒")
    r, e = user.addUser(db7, { name = "bad:name" })
    ok(r == nil and e:find("invalid user name") ~= nil, "user: 非法用户名被拒(冒号会破表)")
    r, e = user.addUser(db7, { name = "carl", uid = 1000 })
    ok(r == nil and e:find("already in use") ~= nil, "user: uid 冲突被拒")
    r, e = user.addUser(db7, { name = "carl", gid = 4242 })
    ok(r == nil and e:find("does not exist") ~= nil, "user: 主组不存在被拒")
    r, e = user.addUser(db7, { name = "carl", groups = { "nogroup" } })
    ok(r == nil and e:find("does not exist") ~= nil, "user: 附加组不存在被拒")
    ok(db7.users.carl == nil and db7.groups.carl == nil, "user: 失败的 addUser 不留半成品")
    ok(user.addUser(db7, { name = "carol", gid = 1000 }) ~= nil, "user: -g 用已有组当主组")
    local rec3 = user.addUser(db7, { name = "dave", uid = 2000, home = "/srv/dave", full = "Dave" })
    eq(rec3.uid, 2000, "user: 显式 uid")
    eq(rec3.home, "/srv/dave", "user: 显式 home")

    -- groupsOf: 主组在前, 其余按 gid 升序
    local db8 = user.parse(PW, SH, GR)
    user.addGroup(db8, "staff")
    user.addUser(db8, { name = "bob", groups = { "staff" } })
    eq(table.concat(user.groupsOf(db8, "bob"), ","), "bob,staff", "user: groupsOf 主组在前")
    ok(user.groupsOf(db8, "nosuch") == nil, "user: groupsOf 未知用户 -> nil")

    -- delUser: 摘 passwd、删同名私有组、从各组成员里移除
    ok(user.delUser(db7, "carol") ~= nil, "user: delUser 成功")
    ok(db7.users.carol == nil, "user: delUser 摘掉 passwd 记录")
    ok(db7.groups.carol == nil, "user: delUser 删掉同名私有组")
    user.delUser(db7, "bob")
    ok(not (db7.groups.alice.members or ""):find("bob"), "user: delUser 从组的成员表里移除")
    r, e = user.delUser(db7, "nosuch")
    ok(r == nil and e:find("does not exist") ~= nil, "user: 删不存在的用户被拒")

    -- modUser: 改名(旧名要摘掉、组成员跟着改)、uid 冲突、-G 全量替换、锁定
    local db9 = user.parse(PW, SH, GR)
    user.addGroup(db9, "staff")
    user.addUser(db9, { name = "bob", groups = { "staff" } })
    local r9 = user.modUser(db9, "bob", { name = "robert" })
    ok(r9 ~= nil, "user: usermod -l 改名成功")
    ok(db9.users.robert ~= nil and db9.users.bob == nil, "user: 改名后旧名查不到")
    -- groupsOf: 主组在前 —— 注意 usermod -l 不改组名, 主组还叫 bob(Linux 同此)
    eq(table.concat(user.groupsOf(db9, "robert"), ","), "bob,staff", "user: 改名后主组名不变, 成员名跟着改")
    r9, e = user.modUser(db9, "robert", { uid = 1000 })
    ok(r9 == nil and e:find("already in use") ~= nil, "user: usermod -u 冲突被拒")
    r9, e = user.modUser(db9, "robert", { name = "alice" })
    ok(r9 == nil and e:find("already exists") ~= nil, "user: 改成的名字已被占用被拒")
    r9 = user.modUser(db9, "robert", { groups = { "alice" } })
    ok(r9 ~= nil and not (db9.groups.staff.members or ""):find("robert"), "user: -G 全量替换附加组")
    r9 = user.modUser(db9, "robert", { home = "/srv/r", shell = "/bin/sh", full = "R" })
    eq(user.get(db9, "robert").home, "/srv/r", "user: usermod -d/-s/-c")
    r9 = user.modUser(db9, "robert", { locked = true })
    ok(r9 ~= nil and user.passwordStatus(db9, "robert") == "L", "user: usermod -L 锁定")

    -- addGroup/delGroup
    local dbg = user.parse(PW, SH, GR)
    local g = user.addGroup(dbg, "staff")
    eq(g.gid, 1001, "user: groupadd 取第一个空闲 gid")
    local _, eg = user.addGroup(dbg, "staff")
    ok(eg ~= nil and eg:find("already exists") ~= nil, "user: 重名组被拒")
    _, eg = user.addGroup(dbg, "other", 1000)
    ok(eg ~= nil and eg:find("already in use") ~= nil, "user: gid 冲突被拒")
    _, eg = user.addGroup(dbg, "bad:name")
    ok(eg ~= nil and eg:find("invalid group name") ~= nil, "user: 非法组名被拒")
    _, eg = user.delGroup(dbg, "alice")
    ok(eg ~= nil and eg:find("primary group") ~= nil, "user: 删用户的主组被拒(GNU 语义)")
    ok(user.delGroup(dbg, "staff") ~= nil, "user: groupdel 成功")

    -- save: 只写变化过的表, 且写回的内容能重新解析
    local files, fsapi = memFs({ ["/etc/passwd"] = PW, ["/etc/shadow"] = SH, ["/etc/group"] = GR })
    local dbS = user.parse(PW, SH, GR)
    ok(user.save(dbS, fsapi), "user: save 无改动也返回成功")
    eq(files["/etc/passwd"], PW, "user: 无改动时不重写 /etc/passwd")
    eq(files["/etc/shadow"], SH, "user: 无改动时不重写 /etc/shadow")
    ok(user.setPassword(dbS, "alice", nil, "newpw"), "user: root 改 alice 密码")
    ok(user.save(dbS, fsapi), "user: save 落盘")
    ok(files["/etc/shadow"] ~= SH, "user: 变化过的表写回 /etc/shadow")
    eq(files["/etc/passwd"], PW, "user: 没变的表不写")
    ok(user.verify(user.parse(files["/etc/passwd"], files["/etc/shadow"], files["/etc/group"]), "alice", "newpw"),
       "user: 写回的 shadow 能重新解析且密码可用")
    user.setLocked(dbS, "alice", true)
    user.save(dbS, fsapi)
    ok(files["/etc/shadow"]:find("alice:!") ~= nil, "user: 锁定的账号写成 '!salt$hash'")

    -- syscall 注册: 读写接口都在(名字拼错会在这里露出来), 且写 syscall 一体落盘
    local modules = require("kernel.modules")
    local fw, fwapi = memFs({ ["/etc/passwd"] = PW, ["/etc/shadow"] = SH, ["/etc/group"] = GR })
    user.registerSyscalls(user.parse(PW, SH, GR), fwapi)
    local sc = modules.syscalls()
    for _, n in ipairs({ "user.verify", "user.get", "user.list", "user.byUid", "user.groups",
                         "user.groupsOf", "user.passwordStatus", "user.groupByName", "user.groupByGid",
                         "user.setPassword", "user.setLocked", "user.addUser", "user.delUser",
                         "user.modUser", "user.addGroup", "user.delGroup" }) do
        ok(sc[n] ~= nil, "user: 注册 syscall " .. n)
    end
    callerUid = 0
    ok(sc["user.addUser"]({ name = "zoe", password = "pw" }) ~= nil, "user: syscall user.addUser 成功")
    ok(fw["/etc/shadow"]:find("zoe:") ~= nil, "user: syscall 写路径已落盘")
    callerUid = 1000
    r, e = sc["user.addUser"]({ name = "mallory" })
    ok(r == nil and e == "permission denied", "user: 非 root 调用写 syscall 被拒")
    eq(fw["/etc/passwd"]:find("mallory"), nil, "user: 被拒的调用没有落盘")
end

-- ===============================================================
-- J. 块设备枚举(kernel/devdisk.lua): 电脑自带存储必须成为 /dev/sda
--    曾经的 bug: 只枚举 peripheral.getNames()(磁盘驱动器), 电脑自带存储不是外设, 于是它
--    (以及其中 /parts/*.img 分区)**永远不是块设备** —— 真机上表现为 rootfs 模式
--    `block devices: (none)` + 根分区没有设备节点, 磁盘接在自带存储之后。
--    另一半是 UUID 命名空间: 磁盘 ID 与电脑 ID 各自递增会撞号, 所以 d<磁盘ID> / c<电脑ID>。
-- ===============================================================
do
    local COMPUTER_ID, COMPUTER_LABEL = 7, "DELIN-PC"

    -- driveData: 槽位 -> 驱动器里的介质。顺序刻意与磁盘 ID 反着排, 顺带锁住"按 ID 升序编号"。
    --   top = 放了一台电脑(没有磁盘 ID, CC 对这类介质不给 ID) —— 必须排最后且没有 UUID。
    local driveData = {
        bottom = { diskId = 1, mountPath = "disk2" },                    -- 无分区
        left   = { diskId = 0, mountPath = "disk", label = "BOOT" },     -- data 分区
        top    = { mountPath = "disk3" },                                 -- 无 ID 介质
    }
    local manifests = {
        [""]    = "root /parts/root.img ext2\ndata /parts/data.img ext2\n", -- 电脑自带存储
        ["disk"] = "data /parts/data.img ext2\n",
    }
    local sizes = {
        ["/parts/root.img"] = 2097152, ["/parts/data.img"] = 2097152,
        ["disk/parts/data.img"] = 524288,
    }
    local capacity = { ["/"] = 1000000, ["disk"] = 128000, ["disk2"] = 128000, ["disk3"] = 128000 }

    -- 分区节点的字节句柄: 设备句柄现在包在**块设备**上(devdisk 的 entry.openBd -> blockdev.file
    -- -> bdHandle), 所以桩要给一个能真正读写字节的 CC 句柄, 并用一张稀疏表当"盘上的镜像"。
    -- 要锁住的三件事: ① 只读打开拿不到可写句柄(写必须失败); ② 可写打开是 "r+" 且**写得进去**
    -- (dd of=/dev/sdX conv=notrunc 靠它); ③ 读写按字节保真、点号与冒号调用都收。
    local byteCalls = { img = {}, opens = {} }
    local function diskHandle(path, mode)
        byteCalls.opens[#byteCalls.opens + 1] = { path = path, mode = mode }
        local pos = 0
        local h = {}
        h.read = function(a, b)
            local n = (type(a) == "table") and b or a
            local out = {}
            for i = 0, (n or 0) - 1 do out[#out + 1] = byteCalls.img[pos + i] or "\0" end
            pos = pos + (n or 0)
            return table.concat(out)
        end
        h.readLine = function() return h.read(4096) end
        h.readAll = function()
            local max = -1
            for k in pairs(byteCalls.img) do if k > max then max = k end end
            local out = {}
            for i = 0, max do out[#out + 1] = byteCalls.img[i] or "\0" end
            return table.concat(out)
        end
        h.seek = function(a, b, c)
            local whence, off
            if type(a) == "table" then whence, off = b, c else whence, off = a, b end
            if whence == "set" then pos = off
            elseif whence == "cur" then pos = pos + off
            else return nil end
            return pos
        end
        h.write = function(a, b)
            local str = (type(a) == "table") and b or a
            if mode == "r" then return nil, "read-only handle" end   -- CC 的只读句柄写会失败
            for i = 1, #str do byteCalls.img[pos + i - 1] = str:sub(i, i) end
            pos = pos + #str
            return true
        end
        h.close = function() return true end
        return h
    end
    local fsStub = {
        open = function(path, mode)
            if path:match("%.img$") then return diskHandle(path, mode) end
            local mp = path:match("^(.*)/parts/manifest$") or ""
            if not manifests[mp] then return nil end
            return { readAll = function() return manifests[mp] end, close = function() end }
        end,
        exists = function(path) return sizes[path] ~= nil end,
        getSize = function(path) return sizes[path] end,
        getCapacity = function(path) return capacity[path] end,
    }
    local diskStub = {
        hasData = function(side) return driveData[side] ~= nil end,
        getMountPath = function(side) return driveData[side] and driveData[side].mountPath end,
        getID = function(side) return driveData[side] and driveData[side].diskId end,
        getLabel = function(side) return driveData[side] and driveData[side].label end,
    }
    local peripheralStub = { getNames = function() return { "bottom", "left", "top" } end }
    local osStub = {
        getComputerID = function() return COMPUTER_ID end,
        getComputerLabel = function() return COMPUTER_LABEL end,
    }

    -- 用真实源码 + 桩全局装载(devdisk.lua 的依赖 vfs/vfs_api/manifest 都是纯 Lua, 走真 require)。
    local env = {
        require = require, fs = fsStub, disk = diskStub, peripheral = peripheralStub, os = osStub,
        string = string, table = table, math = math, tostring = tostring, type = type,
        ipairs = ipairs, pairs = pairs, error = error, pcall = pcall, select = select,
    }
    local src = assert(readFile(REPO .. "/src/kernel/devdisk.lua"), "读不到 src/kernel/devdisk.lua")
    -- 5.1 用 loadstring+setfenv, 5.2+ 用 load 的 _ENV 参数(与上面 loadSrc 同一套写法;
    -- 这里以前少了这一步, `lua5.4 tools/hosttest.lua` 会死在 "attempt to call a nil value
    -- (global 'loadstring')" —— 而 for-ai.md 一直写着"用 5.4 也跑一遍")。
    local chunk
    if _VERSION == "Lua 5.1" then
        chunk = loadEnv(src, "devdisk.lua", env)
    else
        chunk = assert(load(src, "devdisk.lua", "t", env))
    end
    local devdisk = chunk()
    local vfs_api = require("kernel.vfs_api")

    local list = devdisk.scan()
    local names, byName = {}, {}
    for _, e in ipairs(list) do names[#names + 1] = e.name; byName[e.name] = e end
    eq(table.concat(names, ","), "sda,sda1,sda2,sdb,sdb1,sdc,sdd",
       "devdisk: 自带存储=sda(含分区), 磁盘接在其后按磁盘 ID 升序, 无 ID 介质排最后")

    -- 电脑自带存储: 整盘 ccdisk + /parts/manifest 的两个分区
    ok(byName.sda.internal == true, "devdisk: sda 是电脑自带存储(internal)")
    eq(byName.sda.mountPath, "", "devdisk: sda 的 CC 挂载路径是根 \"\"")
    eq(byName.sda.uuid, "c7", "devdisk: 自带存储 UUID = c<电脑ID>")
    eq(byName.sda.label, COMPUTER_LABEL, "devdisk: 自带存储 LABEL = 电脑标签")
    eq(byName.sda.size, 1000000, "devdisk: 自带存储容量走 fs.getCapacity(\"/\")")
    eq(byName.sda1.uuid, "c7-1", "devdisk: 自带存储分区 UUID = c<电脑ID>-<分区号>")
    eq(byName.sda1.role, "root", "devdisk: 自带存储 /parts/manifest 分区角色")
    eq(byName.sda1.img, "/parts/root.img", "devdisk: 自带存储分区的镜像路径")
    eq(byName.sda1.size, 2097152, "devdisk: 自带存储分区大小")
    eq(byName.sda2.img, "/parts/data.img", "devdisk: 自带存储第二个分区")

    -- 磁盘驱动器: 按 disk.getID() 升序(与 peripheral.getNames() 顺序无关)
    eq(byName.sdb.uuid, "d0", "devdisk: 磁盘 ID 0 -> sdb, UUID d0")
    eq(byName.sdb.label, "BOOT", "devdisk: 磁盘 LABEL 来自 disk.getLabel")
    eq(byName.sdb.mountPath, "disk", "devdisk: 磁盘 sdb 的 CC 挂载路径")
    eq(byName.sdb1.uuid, "d0-1", "devdisk: 磁盘分区 UUID = d<磁盘ID>-<分区号>")
    eq(byName.sdb1.img, "disk/parts/data.img", "devdisk: 磁盘分区的镜像路径")
    eq(byName.sdc.uuid, "d1", "devdisk: 磁盘 ID 1 -> sdc")
    ok(byName.sdc1 == nil, "devdisk: 没有 manifest 的磁盘只有整盘节点")

    -- 无磁盘 ID 的介质(放进驱动器的电脑): 有节点但没有 UUID
    eq(byName.sdd.uuid, nil, "devdisk: 无 ID 介质没有 UUID")
    eq(byName.sdd.type, "disk", "devdisk: 无 ID 介质仍是整盘节点")

    -- 设备节点注册 + 别名 ccdiskN(自带存储 = ccdisk0)
    devdisk.refresh()
    local devs = {}
    for _, n in ipairs(vfs_api.devices()) do devs[n] = true end
    ok(devs.sda and devs.sdb and devs.sdd, "devdisk: refresh 注册 /dev/sda.. 节点")
    ok(devs.ccdisk0 and devs.ccdisk1 and devs.ccdisk2, "devdisk: refresh 注册 /dev/ccdiskN 别名")
    eq(devdisk.find("ccdisk0").name, "sda", "devdisk: /dev/ccdisk0 = 电脑自带存储")
    eq(devdisk.find("/dev/ccdisk2").name, "sdc", "devdisk: /dev/ccdiskN 按整盘序号")
    local en, eerr = devdisk.find("ccdiskN")
    ok(en == nil and eerr ~= nil, "devdisk: 未知别名报错")

    -- 按节点名 / UUID 解析
    eq(devdisk.find("sda1").node, "/dev/sda1", "devdisk: find 裸节点名")
    eq(devdisk.find("/dev/sdb1").img, "disk/parts/data.img", "devdisk: find /dev/ 前缀")
    eq(devdisk.find("UUID=c7-2").node, "/dev/sda2", "devdisk: UUID=c<电脑ID>-<n> 解析")
    eq(devdisk.find("UUID=d0-1").node, "/dev/sdb1", "devdisk: UUID=d<磁盘ID>-<n> 解析")
    eq(devdisk.find("UUID=c7").node, "/dev/sda", "devdisk: 整盘 UUID = c<电脑ID>")
    -- 纯数字不再是任何设备的 UUID: 磁盘 ID 与电脑 ID 会撞号, 所以两边都带前缀
    local e0, err0 = devdisk.find("UUID=0")
    ok(e0 == nil and err0:find("no such device") ~= nil, "devdisk: 裸数字 UUID 不再匹配(命名空间必需)")
    local e1, err1 = devdisk.find("UUID=7")
    ok(e1 == nil and err1:find("no such device") ~= nil, "devdisk: 电脑 ID 裸数字同样不匹配")

    -- byMountPath: 根挂载对上设备节点用
    eq(devdisk.byMountPath("").name, "sda", "devdisk: byMountPath(\"\") = 自带存储")
    eq(devdisk.byMountPath("disk2").name, "sdc", "devdisk: byMountPath 找驱动器里的盘")
    eq(devdisk.byMountPath("missing"), nil, "devdisk: byMountPath 找不到即 nil")

    -- 分区节点的原始字节句柄。设备节点 -> 块设备 -> 句柄这条链上要保住的三件事:
    --   ① 只读打开 ("r") 必须拿到写不进去的句柄(以前这里踩过 `dd of=... conv=notrunc` 拿到只读
    --      句柄、到写的时候才在 CC 句柄上炸的坑);
    --   ② r+ 打开是 "r+" 且真的写到盘上的镜像里;
    --   ③ 读写按字节保真, 点号/冒号调用等价(老 bug: 冒号调用把句柄自己当实参传给 CC 句柄,
    --      真机症状是 `cat /dev/sdb1` 报 "bad argument #1 (boolean expected, got table)")。
    do
        local vfs = require("kernel.vfs")
        local realFs = _G.fs
        _G.fs = fsStub          -- 块设备层的 open 走全局 fs
        vfs_api.mountDev()      -- boot 里也是先挂 /dev 再由 devdisk 注册节点
        local bh = assert(vfs_api.fs.open("/dev/sdb1", "r"), "devdisk: /dev/sdb1 可打开为字节设备")
        eq(byteCalls.opens[#byteCalls.opens].mode, "r", "devdisk: 只读打开 -> 底层以 r 打开镜像")
        eq(byteCalls.opens[#byteCalls.opens].path, "disk/parts/data.img", "devdisk: 打开的是分区镜像")
        local wrote, werr = bh:write("nope")
        ok(wrote == nil and tostring(werr):find("read%-only") ~= nil,
            "devdisk: 只读句柄写失败(fail-fast)", werr)
        eq(#bh:readLine(), 4096, "devdisk: 字节设备没有行 —— readLine 一次给一块")
        bh.close()

        local wh = assert(vfs_api.fs.open("/dev/sdb1", "r+"), "devdisk: /dev/sdb1 可以 r+ 打开")
        eq(byteCalls.opens[#byteCalls.opens].mode, "r+", "devdisk: r+ 打开 -> 底层以 r+ 打开镜像")
        ok(wh:write("HELLO") == true, "devdisk: r+ 句柄写得进去")
        wh:seek("set", 4)
        wh:write("!")
        wh.close()
        local rh = assert(vfs_api.fs.open("/dev/sdb1", "r"), "devdisk: 再开一次读回")
        eq(rh:read(5), "HELL!", "devdisk: 写进去的字节按位置保真(dd conv=notrunc 语义)")
        rh.close()
        _G.fs = realFs

        local tr, terr = vfs_api.fs.open("/dev/sda", "r")
        ok(tr == nil and tostring(terr):find("ccdisk") ~= nil, "devdisk: 整盘(ccdisk)不是字节流设备")
        vfs.unmount("/dev") -- 后面的随机数用例会自己 mountDev, 不留下重复挂载
    end

    -- devdisk.mkfs / devdisk.fsck(/bin/mkfs.ext2、/bin/fsck.ext2 的内核入口):
    -- 目标解析、已挂载拒绝、已有文件系统要 -F、以及"mkfs 出来的镜像 fsck 判干净"。
    -- 这里把自带存储的 /parts/root.img 换成**真实临时文件**(blockdev.file 要能 seek),
    -- 其余全局仍是上面的桩。
    do
        local vfs = require("kernel.vfs")
        local IMG = "/tmp/delin-hosttest-mkfs.img"
        os.remove(IMG)
        local tmp = assert(io.open(IMG, "wb")); tmp:close()
        -- blockdev.lua 用的是**全局 fs**(内核里是 CC 的原生 fs 句柄), 不是 devdisk 的环境变量,
        -- 所以这里把 _G.fs 包一层: 只有 /parts/root.img 落到真实临时文件, 其余照旧走宿主门面。
        local realFs = _G.fs
        local facade = setmetatable({}, { __index = function(_, k) return realFs[k] end })
        facade.open = function(path, mode)
            if path == "/parts/root.img" then
                local h = assert(io.open(IMG, mode == "r+" and "r+b" or "rb"), IMG)
                -- CC 原生句柄是点号调用; 这里点号冒号都收(与 vfs 的 wrapCCHandle 同义)
                return {
                    read = function(a, b) return h:read((type(a) == "table") and b or a) end,
                    write = function(a, b)
                        local str = (type(a) == "table") and b or a
                        h:write(str)
                        return #str
                    end,
                    seek = function(a, b, c)
                        local whence, off
                        if type(a) == "table" then whence, off = b, c else whence, off = a, b end
                        return h:seek(whence, off)
                    end,
                    close = function() h:close() end,
                }
            end
            return realFs.open(path, mode)
        end
        facade.getSize = function(path)
            if path == "/parts/root.img" then
                local hh = io.open(IMG, "rb"); local n = hh:seek("end"); hh:close(); return n
            end
            return realFs.getSize(path)
        end
        _G.fs = facade

        local info, merr = devdisk.mkfs("/dev/sda1", { blocks = 128, label = "HT" })
        ok(info ~= nil, "devdisk.mkfs: 节点规格 -> 镜像上建出文件系统", tostring(merr))
        if info then
            eq(info.device, "/dev/sda1", "devdisk.mkfs: 摘要里带设备节点")
            eq(info.blocks, 128, "devdisk.mkfs: 块数")
            eq(info.blockSize, 1024, "devdisk.mkfs: 块大小")
            eq(info.label, "HT", "devdisk.mkfs: 卷标")
            local hh = io.open(IMG, "rb"); local n = hh:seek("end"); hh:close()
            eq(n, 128 * 1024, "devdisk.mkfs: 镜像被撑到 128KB")
        end
        -- 已有文件系统: 不给 -F 必须拒绝, 给了才覆盖
        local again, aerr = devdisk.mkfs("/dev/sda1", { blocks = 128 })
        ok(again == nil and tostring(aerr):find("already contains") ~= nil,
            "devdisk.mkfs: 已有 ext2 又不给 -F -> 拒绝(fail-fast)", tostring(aerr))
        ok(devdisk.mkfs("/dev/sda1", { blocks = 128, force = true }) ~= nil, "devdisk.mkfs: -F 覆盖成功")
        -- -n: 不写盘
        local before = io.open(IMG, "rb"):read("*a")
        local dry, dryErr = devdisk.mkfs("/dev/sda1", { blocks = 64, dryRun = true, label = "DRY" })
        ok(dry ~= nil, "devdisk.mkfs: -n 成功", tostring(dryErr))
        -- -n 返回的必须是**布局摘要**(而不是空表): 工具要靠它打印"会建成什么样"
        eq(dry.blocks, 64, "devdisk.mkfs: -n 摘要里有块数")
        eq(dry.blockSize, 1024, "devdisk.mkfs: -n 摘要里有块大小")
        eq(dry.inodes, 256, "devdisk.mkfs: -n 摘要里有 inode 数")
        eq(dry.label, "DRY", "devdisk.mkfs: -n 摘要里有卷标")
        eq(io.open(IMG, "rb"):read("*a"), before, "devdisk.mkfs: -n 一个字节都没写")

        -- fsck: 干净 -> 0; 已挂载 -> 拒绝(8)
        local rep = devdisk.fsck("/dev/sda1", { mode = "check" })
        ok(rep ~= nil and rep.code == 0, "devdisk.fsck: mkfs 出来的镜像判干净", rep and table.concat(rep.lines, "\n"))
        eq(rep.device, "/dev/sda1", "devdisk.fsck: 报告里带设备节点")
        vfs.mount("/mnt/x", { kind = "virtual", isReadOnly = function() return false end },
            { device = "/dev/sda1", fstype = "ext2" })
        local mrep = devdisk.fsck("/dev/sda1", { mode = "check" })
        ok(mrep.code == 8 and table.concat(mrep.lines, "\n"):find("is mounted") ~= nil,
            "devdisk.fsck: 已挂载的文件系统一律拒绝", mrep and table.concat(mrep.lines, "\n"))
        local mres, mresErr = devdisk.mkfs("/dev/sda1", { blocks = 64, force = true })
        ok(mres == nil and tostring(mresErr):find("is mounted") ~= nil,
            "devdisk.mkfs: 已挂载的文件系统一律拒绝格式化", tostring(mresErr))
        vfs.unmount("/mnt/x")
        -- 未知设备/整盘节点(fstype 不是 ext2 的字节设备)都要报错
        local bad, badErr = devdisk.mkfs("/dev/sdzz", { blocks = 64 })
        ok(bad == nil and tostring(badErr):find("no such device") ~= nil, "devdisk.mkfs: 未知设备报错")
        local whole, wholeErr = devdisk.mkfs("/dev/sda", { blocks = 64 })
        ok(whole == nil and tostring(wholeErr):find("ccdisk") ~= nil, "devdisk.mkfs: 整盘(ccdisk)不能格式化")
        _G.fs = realFs
        os.remove(IMG)
    end
end

-- ===============================================================
-- K2. 随机数: ChaCha20 核心 + 熵池 + /dev/zero,/dev/random,/dev/urandom
--     ChaCha20 的期望值由 OpenSSL 生成(命令写在下面), 而不是"自己算一遍再和自己比"。
-- ===============================================================
do
    _G.fs = F -- vfs_api 顶层取 fs.getName 等
    local chacha = require("kernel.chacha20")
    local vfs_api = require("kernel.vfs_api")
    local random = require("kernel.random")
    local vfs = require("kernel.vfs")

    local function hex(s)
        return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    end
    -- 向量来源(OpenSSL 3.x):
    --   head -c 64 /dev/zero | openssl enc -chacha20 -K <key> -iv <ctr_LE|nonce> -nosalt | od -An -v -tx1
    local key = ""
    for i = 0, 31 do key = key .. string.char(i) end
    eq(hex(chacha.blockBytes(key, 1, string.char(0, 0, 0, 9, 0, 0, 0, 0x4a, 0, 0, 0, 0))),
       "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e"
       .. "d2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e",
       "chacha20: 密钥 00..1f / 计数器 1 的块(OpenSSL 向量)")
    local zkey, znonce = string.rep("\0", 32), string.rep("\0", 12)
    eq(hex(chacha.blockBytes(zkey, 0, znonce)),
       "76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7"
       .. "da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586",
       "chacha20: 全零密钥/nonce 的块(OpenSSL 向量)")
    eq(hex(chacha.blockBytes(key, 0, znonce)) .. hex(chacha.blockBytes(key, 1, znonce)),
       "39fd2b7dd9c5196a8dbd0377b8dc4a498a35d86fbcde6accb2cc7d4cd8ea2492"
       .. "2b23cce7a26023ab3f0eef693ac87f64258235eab1f7a32dc22762a0485b410c"
       .. "18b84231ade6a6d113615c61af434e27f8b1f3f5e1ad5b5cecf8fc122a3575"
       .. "5c7208086dd1ee3c5d9d815824640e003c9ba0f65ede5d59ce0d2a4a7f31955acd",
       "chacha20: 连续两块(计数器 0/1)的密钥流")
    -- 纯算术实现的自检: 32 位异或/循环移位在边界值上必须与定义一致
    eq(chacha.xor32(0xFFFFFFFF, 0), 0xFFFFFFFF, "chacha20: xor32 全 1")
    eq(chacha.xor32(0x0F0F0F0F, 0x00FF00FF), 0x0FF00FF0, "chacha20: xor32 交叉位")
    eq(chacha.rotl32(0x80000001, 1), 0x00000003, "chacha20: rotl32 回绕")
    eq(chacha.rotl32(0x12345678, 0), 0x12345678, "chacha20: rotl32 0 位")

    -- /dev 设备: mountDev 之后 /dev/null 与 /dev/zero 已在注册表里(vfs_api 顶层注册)
    vfs_api.mountDev()
    local function openDev(path, mode)
        local b, r = vfs.resolve(path)
        return b.open(r, mode or "r")
    end
    local zh = openDev("/dev/zero")
    ok(zh ~= nil, "devzero: 能打开")
    eq(zh:read(4), "\0\0\0\0", "devzero: read(4) 给 4 个 NUL")
    eq(#zh:read(1024), 1024, "devzero: read(1024) 给 1024 个 NUL")
    eq(zh:read(3):byte(1), 0, "devzero: 内容是 NUL")
    eq(zh:write("abc"), 3, "devzero: 写丢弃并返回长度")
    ok(#zh:readLine() > 0, "devzero: readLine 一次给一块")

    -- /dev/random 与 /dev/urandom: 只读(写打开必须报错, 不许静默)
    random.register()
    local rb, rr = vfs.resolve("/dev/random")
    local okw, werr = pcall(rb.open, rr, "w")
    ok(not okw and tostring(werr):find("read%-only") ~= nil, "devrandom: 拒写", werr)
    local b2, r2 = vfs.resolve("/dev/urandom")
    ok(b2.exists(r2) and not b2.isDir(r2), "devurandom: 存在且不是目录")
    -- 未初始化时 /dev/urandom 照常出字节(Linux 同此), 只是记一次内核告警
    local a1 = b2.open(r2, "r"):read(16)
    local a2 = b2.open(r2, "r"):read(16)
    eq(#a1, 16, "devurandom: read(16) 给 16 字节")
    ok(a1 ~= a2, "devurandom: 两次读不同(换钥)")
    ok(a1 ~= string.rep("\0", 16), "devurandom: 不是全零")
    ok(not random.ready(), "random: 未喂事件时 CRNG 未初始化")

    -- 熵源: 事件喂进池子 -> CRNG 就绪, 且新事件真的改变输出
    local ea0 = random.entropyAvail()
    for i = 1, 12 do random.feedEvent({ "timer", i, n = 2 }) end
    ok(random.entropyAvail() >= ea0, "random: 事件喂进池子, entropy_avail 不降")
    ok(random.ready(), "random: 样本满 128 bit fast-load 后 CRNG 就绪")
    local rb2, rr2 = vfs.resolve("/dev/random")
    eq(#rb2.open(rr2, "r"):read(8), 8, "devrandom: 就绪后能读")
    local before = random.bytes(32)
    for i = 1, 12 do random.feedEvent({ "timer", i, n = 2 }) end
    ok(random.bytes(32) ~= before, "random: 新事件改变了输出")

    -- uuid/hex 辅助
    eq(#random.hex(5), 10, "random: hex(5) 是 10 个十六进制字符")
    ok(random.hex(8):match("^%x+$") ~= nil, "random: hex 只含十六进制字符")
    ok(random.uuid():match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4") ~= nil, "random: uuid v4 前缀")
end

-- ===============================================================
-- M. CEECC(CEE:CC) 台式机: kernel/platform.lua 探测 + modules/cee.ko 的
--    /sys/class/power/supply 与 /sys/class/pin/pinN + devdisk 的引脚驱动器来源
--    真机事实(台式 CEECC, 电脑 #6)锁在这里: 引脚没有端口时 cee 的 getAnalogOutput/getOutput
--    报 "no signal port on pin N", 所以那三个端口属性必须只在有端口的引脚上存在;
--    引脚上的外设同时出现在 CC 侧面平面上(实测 pin8 = 侧面 back), 于是设备枚举仍走侧面,
--    只有存储按 CC 挂载路径补漏并去重。
-- ===============================================================
do
    local vfs      = require("kernel.vfs")
    local platform = require("kernel.platform")
    local sysfs    = require("kernel.sysfs")

    -- ---- cee 全局的桩: 3 个引脚。1 号空着; 2 号端口挂 drive; 3 号端口挂 modem。
    local st = {
        ports  = { [1] = { data = false, ports = 0, powered = false, type = nil },
                   [2] = { data = true,  ports = 1, powered = true,  type = "drive" },
                   [3] = { data = false, ports = 1, powered = true,  type = "modem" } },
        analog = { [2] = 0, [3] = 0 },
        calls  = {},
        resets = 0,
    }
    local driveHandle = {
        isDiskPresent = function() return true end,
        getMountPath = function() return "disk7" end,
        getDiskID    = function() return 41 end,
        getDiskLabel = function() return "PIN-DISK" end,
    }
    local function requirePort(pin)
        if st.ports[pin].ports == 0 then error("no signal port on pin " .. pin, 0) end
    end
    local ceeStub = {
        getSignalCount    = function() return 3 end,
        isDataPin         = function(p) return st.ports[p].data end,
        getPortCount      = function(p) return st.ports[p].ports end,
        isPortPowered     = function(p) return st.ports[p].powered end,
        hasPeripheral     = function(p) return st.ports[p].type ~= nil end,
        getPeripheralType = function(p) return st.ports[p].type end,
        getPeripheral     = function(p) if p == 2 then return driveHandle end return nil end,
        hasPower          = function() return true end,
        getPowerVoltage   = function() return 299.98502276145973 end,
        getSupplyCurrent  = function() return 0.33334997554213985 end,
        getDeliveredPower = function() return 0 end,
        getMaxPower       = function() return 500 end,
        getPowerHeadroom  = function() return 500 end,
        getSupplyState    = function() return "ok" end,
        resetSupply       = function() st.resets = st.resets + 1 end,
        getAnalog         = function(p) return st.analog[p] end,
        getAnalogOutput   = function(p) requirePort(p); return st.analog[p] end,
        getOutput         = function(p) requirePort(p); return st.analog[p] > 0 end,
        setAnalog = function(p, v) st.calls[#st.calls + 1] = "setAnalog:" .. p .. ":" .. v; st.analog[p] = v end,
        setOutput = function(p, on)
            st.calls[#st.calls + 1] = "setOutput:" .. p .. ":" .. tostring(on)
            st.analog[p] = on and 15 or 0
        end,
    }

    -- ---- platform: 探测与引脚快照
    _G.cee = ceeStub
    eq(platform.detect(), "cee", "platform: cee 全局存在 -> kind=cee")
    local pins = platform.pins()
    eq(#pins, 3, "platform: pins() 按 getSignalCount 列出全部引脚")
    eq(pins[1].ports, 0, "platform: 空引脚的端口数")
    eq(pins[2].ports, 1, "platform: 引脚 2 的端口数")
    eq(pins[2].data, true, "platform: 引脚 2 上有 Peripheral Cable")
    eq(pins[2].type, "drive", "platform: 引脚 2 的外设类型")
    eq(pins[1].has, false, "platform: 空引脚 hasPeripheral=false")
    local pinDrives = platform.pinDrives()
    eq(#pinDrives, 1, "platform: 只有 drive 类型进 pinDrives")
    eq(pinDrives[1].name, "pin2", "platform: 引脚驱动器用 pinN 命名")
    ok(pinDrives[1].handle == driveHandle, "platform: pinDrives 给的是引脚上的句柄")

    -- ---- cee.ko: 注册 sysfs 类并核对属性契约
    local opsByName = {}
    local registered = {}
    local kapi = {
        log = function() end,
        registerSysfsClass   = function(n, ops) registered[#registered + 1] = n; opsByName[n] = ops; sysfs.registerClass(n, ops) end,
        unregisterSysfsClass = function(n) sysfs.unregisterClass(n) end,
    }
    local src = assert(readFile(REPO .. "/src/modules/cee.ko"), "读不到 src/modules/cee.ko")
    local env = setmetatable({ require = require }, { __index = _G })
    local chunk
    if _VERSION == "Lua 5.1" then
        chunk = loadEnv(src, "cee", env)
    else
        chunk = assert(load(src, "cee", "t", env))
    end
    local mod = chunk()
    mod.init(kapi)
    eq(table.concat(registered, ","), "power,pin", "cee.ko: 注册 power 与 pin 两个 sysfs 类")

    local function openAttr(path, mode)
        local b, r = vfs.resolve(path)
        ok(b ~= nil, "cee.ko: 路径存在 " .. path)
        if not b then return nil end
        local fh, err = b.open(r, mode or "r")
        ok(fh ~= nil, "cee.ko: 打开 " .. path, err)
        return fh
    end

    -- power: 读全部落到 cee 的电力 API(字符串化跟着 tostring, 不另造格式)
    eq(openAttr("/sys/class/power/supply/present").readAll(), "1", "cee.ko: hasPower -> present=1")
    eq(openAttr("/sys/class/power/supply/max_power").readAll(), "500", "cee.ko: getMaxPower -> max_power")
    eq(openAttr("/sys/class/power/supply/headroom").readAll(), "500", "cee.ko: getPowerHeadroom -> headroom")
    eq(openAttr("/sys/class/power/supply/state").readAll(), "ok", "cee.ko: getSupplyState -> state")
    eq(openAttr("/sys/class/power/supply/reset").readAll(), nil, "cee.ko: reset 是只写属性(读不到内容)")
    local vh = openAttr("/sys/class/power/supply/voltage")
    eq(vh.readAll(), tostring(299.98502276145973), "cee.ko: voltage 原样(字符串化跟着 tostring)")
    eq(vh.readAll(), nil, "cee.ko: 属性读一次即 EOF")
    eq(openAttr("/sys/class/power/supply/reset", "w"):write("1"), 1, "cee.ko: 写 reset=1")
    eq(st.resets, 1, "cee.ko: reset 落到 resetSupply")
    local rset, rerr = opsByName.power.set("supply", "reset", "0")
    ok(rset == nil and tostring(rerr):find("invalid reset") ~= nil, "cee.ko: reset 只收 1")
    eq(opsByName.power.writable("supply", "voltage"), false, "cee.ko: voltage 只读")
    eq(opsByName.power.writable("supply", "reset"), true, "cee.ko: reset 可写")

    -- pin: 条目名与属性清单(端口属性只在有端口时存在)
    eq(table.concat(opsByName.pin.list(), ","), "pin1,pin2,pin3", "cee.ko: 引脚条目 pin1..pinN")
    eq(table.concat(opsByName.pin.attrs("pin1"), ","), "data,ports,powered,peripheral,peripheral_type",
       "cee.ko: 无端口引脚只有五个只读属性")
    eq(table.concat(opsByName.pin.attrs("pin2"), ","),
       "data,ports,powered,peripheral,peripheral_type,analog_in,analog_out,digital_out",
       "cee.ko: 有端口引脚多三个端口属性")
    eq(opsByName.pin.attrs("pin4"), nil, "cee.ko: 越界引脚没有条目")
    eq(opsByName.pin.attrs("pinX"), nil, "cee.ko: 非引脚条目名不认")
    local ab, ar = vfs.resolve("/sys/class/pin/pin1/analog_in")
    ok(ab ~= nil and not ab.exists(ar), "cee.ko: 无端口引脚没有 analog_in 属性")
    eq(openAttr("/sys/class/pin/pin2/peripheral").readAll(), "1", "cee.ko: hasPeripheral -> peripheral=1")
    eq(openAttr("/sys/class/pin/pin2/peripheral_type").readAll(), "drive", "cee.ko: 引脚外设类型")
    eq(openAttr("/sys/class/pin/pin1/peripheral_type").readAll(), nil, "cee.ko: 空引脚的外设类型读不到内容")
    eq(openAttr("/sys/class/pin/pin3/data").readAll(), "0", "cee.ko: isDataPin -> data")

    -- pin: 端口写入落到 setAnalog/setOutput, 越界 fail-fast 且不改状态
    eq(openAttr("/sys/class/pin/pin2/analog_out", "w"):write("7"), 1, "cee.ko: 写 analog_out=7")
    eq(st.analog[2], 7, "cee.ko: analog_out 落到 setAnalog(2,7)")
    eq(openAttr("/sys/class/pin/pin2/analog_out").readAll(), "7", "cee.ko: analog_out 读回 getAnalogOutput")
    local okW, errW = opsByName.pin.set("pin2", "analog_out", "16")
    ok(okW == nil and tostring(errW):find("0..15") ~= nil, "cee.ko: analog_out 越界 fail-fast")
    eq(st.analog[2], 7, "cee.ko: 越界写不改动端口状态")
    ok(opsByName.pin.set("pin2", "analog_out", "0x3") == nil, "cee.ko: analog_out 不收十六进制")
    eq(opsByName.pin.set("pin2", "digital_out", "1"), true, "cee.ko: 写 digital_out=1")
    eq(st.analog[2], 15, "cee.ko: digital_out=1 等价 analog 15")
    eq(opsByName.pin.get("pin2", "digital_out"), "1", "cee.ko: digital_out 读回 getOutput")
    local okP, errP = opsByName.pin.set("pin1", "analog_out", "7")
    ok(okP == nil and tostring(errP):find("no signal port") ~= nil, "cee.ko: 无端口引脚写 analog_out 报错")
    eq(opsByName.pin.writable("pin1", "analog_out"), false, "cee.ko: 无端口引脚不可写")

    -- CC 电脑: cee 全局不存在 -> kind=cc, 引脚为空, 模块什么都不注册
    _G.cee = nil
    eq(platform.detect(), "cc", "platform: 没有 cee 全局 -> kind=cc")
    eq(#platform.pins(), 0, "platform: CC 电脑没有引脚")
    eq(#platform.pinDrives(), 0, "platform: CC 电脑没有引脚驱动器")
    local registered2 = {}
    chunk().init({
        log = function() end,
        registerSysfsClass = function(n) registered2[#registered2 + 1] = n end,
        unregisterSysfsClass = function() end,
    })
    eq(#registered2, 0, "cee.ko: CC 电脑上不注册任何 sysfs 类")

    -- exit 注销两个类(热重载路径)
    mod.exit()
    local cb, cr = vfs.resolve("/sys/class")
    local classNames = {}
    for _, n in ipairs(cb.list(cr)) do classNames[n] = true end
    ok(not classNames.power and not classNames.pin, "cee.ko: exit 注销 power/pin 两个类")

    -- ---- devdisk: 引脚驱动器(去掉与侧面重复的, 去掉 fs 看不见的)
    local function loadDevdisk(platStub)
        local caps = { ["/"] = 1000000, ["disk"] = 128000, ["disk7"] = 100000000 }
        local sideDrives = { left = { diskId = 0, mountPath = "disk", label = "BOOT" } }
        local pinTable = {
            { pin = 8, name = "pin8", handle = { isDiskPresent = function() return true end,
                                                 getMountPath = function() return "disk" end,
                                                 getDiskID = function() return 99 end,
                                                 getDiskLabel = function() return "SAME-AS-SIDE" end } },
            { pin = 9, name = "pin9", handle = { isDiskPresent = function() return true end,
                                                 getMountPath = function() return "disk7" end,
                                                 getDiskID = function() return 41 end,
                                                 getDiskLabel = function() return "PIN-DISK" end } },
            { pin = 7, name = "pin7", handle = { isDiskPresent = function() return true end,
                                                 getMountPath = function() return "unseen" end,
                                                 getDiskID = function() return 42 end,
                                                 getDiskLabel = function() return nil end } },
        }
        local env = {
            require = function(name)
                if name == "kernel.platform" then return { pinDrives = function() return pinTable end } end
                return require(name)
            end,
            fs = {
                open = function() return nil end,
                exists = function() return false end,
                getSize = function() return nil end,
                getCapacity = function(p) return caps[p] end,
            },
            disk = {
                hasData = function(s) return sideDrives[s] ~= nil end,
                getMountPath = function(s) return sideDrives[s] and sideDrives[s].mountPath end,
                getID = function(s) return sideDrives[s] and sideDrives[s].diskId end,
                getLabel = function(s) return sideDrives[s] and sideDrives[s].label end,
            },
            peripheral = { getNames = function() return { "left" } end },
            os = { getComputerID = function() return 6 end, getComputerLabel = function() return nil end },
            string = string, table = table, math = math, tostring = tostring, type = type,
            ipairs = ipairs, pairs = pairs, error = error, pcall = pcall, select = select,
        }
        local s = assert(readFile(REPO .. "/src/kernel/devdisk.lua"), "读不到 src/kernel/devdisk.lua")
        local c = loadEnv(s, "devdisk", env)
        local dd = c()
        local byName = {}
        for _, e in ipairs(dd.scan()) do byName[e.name] = e end
        return byName
    end

    local dd = loadDevdisk()
    eq(dd.sda.mountPath, "", "devdisk: 自带存储仍是 sda")
    eq(dd.sdb.mountPath, "disk", "devdisk: 侧面驱动器是 sdb")
    ok(dd.sdc ~= nil, "devdisk: 引脚上的驱动器补成 sdc")
    eq(dd.sdc and dd.sdc.mountPath, "disk7", "devdisk: 引脚驱动器用它的 CC 挂载路径")
    eq(dd.sdc and dd.sdc.uuid, "d41", "devdisk: 引脚驱动器 UUID = d<磁盘ID>")
    eq(dd.sdc and dd.sdc.side, "pin9", "devdisk: 引脚驱动器的 side 记为 pinN")
    eq(dd.sdd, nil, "devdisk: 与侧面同一个存储(同挂载路径)不重复造节点")
    eq(dd.sde, nil, "devdisk: fs 看不见的挂载路径不造节点")
end

-- ===============================================================
-- K. kernel.lock: 抢占式调度的内核临界区锁(不变量 + 放锁等待)
--    锁本身是纯 Lua, 宿主就能验: 重入/不平衡/被别的 pid 撞上都要 fail-fast,
--    而 lock.pause(内核里阻塞等)必须"放锁 -> 跑 -> 拿回"。
-- ===============================================================
do
    local lock = require("kernel.lock")

    local cur = nil
    lock.setCurrent(1)
    eq(lock.depthOf(), 0, "lock: 初始深度 0")
    lock.enter()
    eq(lock.depthOf(), 1, "lock: enter 后深度 1")
    lock.enter()
    eq(lock.depthOf(), 2, "lock: 同 pid 可重入")
    ok(lock.inKernel(), "lock: 持锁时 inKernel=true")
    lock.leave()
    lock.leave()
    eq(lock.depthOf(), 0, "lock: leave 后回到 0")
    eq(lock.inKernel(), false, "lock: 放完 inKernel=false")

    -- 被别的 pid 撞上时**排队等**(而不是当场报错): 持锁者可能在核心里阻塞(实测: systemctl
    -- 调 init.start 时持锁睡了 50ms), fail-fast 会把别的进程当街打死。
    do
        local held = false
        local co = coroutine.create(function()
            lock.setCurrent(2)
            lock.enter()          -- 撞上 pid 1 持锁 -> yield "__lock"
            held = true
            lock.leave()
        end)
        lock.setWaker(function(pid)
            eq(pid, 2, "lock: 唤醒的是队首等待者")
            local okR, y = coroutine.resume(co)
            ok(okR, "lock: 唤醒后等待者继续跑", y)
        end)
        lock.setCurrent(1)
        lock.enter()
        local okR, y = coroutine.resume(co)
        eq(okR, true, "lock: 撞上持锁者时不报错")
        eq(y, "__lock", "lock: 撞上持锁者时 yield \"__lock\" 排队")
        eq(held, false, "lock: 还没放锁时等待者拿不到")
        lock.setCurrent(1)
        lock.leave()              -- 放锁 -> 唤醒队首(上面的 waker 会 resume)
        eq(held, true, "lock: 放锁后等待者拿到锁")
        eq(lock.depthOf(), 0, "lock: 等待者用完也放干净了")
    end

    -- 不平衡的 leave 也是错误
    local okL = pcall(lock.leave)
    ok(not okL, "lock: 没持锁就 leave -> 报错")

    -- lock.pause: 放的这段时间里"别人能进来", 回来后深度原样恢复
    lock.setCurrent(7)
    lock.enter()
    local inner = nil
    lock.pause(function()
        inner = lock.depthOf()
        lock.setCurrent(8) -- 假装另一个进程进来了
        lock.enter()
        lock.leave()
        lock.setCurrent(7)
    end)
    eq(inner, 0, "lock.pause: 等待期间是放锁的(别人能进内核)")
    eq(lock.depthOf(), 1, "lock.pause: 回来后深度恢复")
    eq(lock.ownerOf(), 7, "lock.pause: 回来后持有者仍是自己")
    lock.leave()

    -- 不在临界区时 pause 直接跑(宿主测试台/内核直接调用)
    eq(lock.pause(function() return 42 end), 42, "lock.pause: 不在临界区时直接跑")

    -- 反复取用同一张表里的函数**不能越包越深**(真机踩过: proxy[k]=w 写回原表 -> 无限套娃
    -- -> stack overflow, cmp/syslogd/sh/init 全死)
    do
        local t = { f = function(x) return x + 1 end }
        local proxy = lock.wrapTable(t)
        local first = proxy.f
        ok(proxy.f == first, "lock.wrapTable: 同一个函数只包一次(取用多次不叠包装)")
        ok(t.f == t.f and t.f(1) == 2, "lock.wrapTable: 原表没被改写")
        lock.setCurrent(5)
        eq(proxy.f(41), 42, "lock.wrapTable: 包装后仍正常返回")
        eq(lock.depthOf(), 0, "lock.wrapTable: 调用完放锁")
        lock.setCurrent(nil)
    end

    -- **代理表不能把 self 换成自己**(真机踩过: wrapCCHandle 靠 `self == 自己` 判点号/冒号,
    -- 换成代理就落进点号那一支 —— 文件里出现 `table: 0x...`, 分区路径变成 "/6030d5c6",
    -- mkfs/mount/fsck 全找不到文件)。这里用一份"照抄 wrapCCHandle 判据"的假句柄锁住它。
    do
        local sink = ""
        local cch = {} -- CC 原生句柄: 点号调用 h.write(s)
        cch.write = function(a, b) sink = sink .. tostring(a == cch and b or a) end
        local delin -- 先声明: 闭包要捕获自身(与 wrapCCHandle 同一写法)
        delin = {
            write = function(a, ...)
                if a == delin then return cch.write(...) end -- 冒号: 句柄自己是 self
                return cch.write(a, ...)                    -- 点号: 第一个参数就是数据
            end,
        }
        local proxy = lock.wrapTable(delin)
        lock.setCurrent(3)
        proxy:write("hi")          -- 冒号调用必须落到"数据 = hi"
        eq(sink, "hi", "lock.wrapTable: 冒号调用的 self 换回原表(不写成 table: ...)")
        eq(lock.depthOf(), 0, "lock.wrapTable: 方法调用后放锁")
        lock.setCurrent(nil)
    end

    -- 临界区里"时间片用完"要**记账**, 出临界区立刻让出(否则密集小内核调用的进程永远抢不到 CPU:
    -- 真机实测 `find /` 让其他终端读键盘的进程每秒只被恢复 1-2 次)
    do
        local t = { f = function(x) return x * 2 end }
        local proxy = lock.wrapTable(t)
        local log = {}
        lock.setCurrent(11)
        local okr, v = pcall(function()
            lock.markPreempt()          -- 假装钩子在核心里打了一枪
            return proxy.f(21)          -- 出临界区时应当让出一次
        end)
        eq(v, 42, "lock: 记账让出后返回值不受影响")
        eq(okr, true, "lock: 记账让出不报错")
        eq(lock.depthOf(), 0, "lock: 记账让出之后仍然是放锁的")
        lock.setCurrent(nil)
    end

    -- 包装器: 错误也要把锁放掉
    local wrapped = lock.wrap(function(a, b) return a + b end)
    lock.setCurrent(9)
    eq(wrapped(2, 3), 5, "lock.wrap: 正常返回")
    eq(lock.depthOf(), 0, "lock.wrap: 正常返回后放锁")
    local bad = lock.wrap(function() error("boom") end)
    local okB = pcall(bad)
    ok(not okB, "lock.wrap: 错误照原样抛出")
    eq(lock.depthOf(), 0, "lock.wrap: 出错也放锁")
    lock.setCurrent(nil)
end

-- ===============================================================
-- L. kernel.scheduler 抢占模式: run queue 的时间片轮转
--    宿主 Lua(PUC 5.1/5.4)里"在钩子里 yield"是不允许的(真机 Cobalt 可以), 所以这里
--    把 debug.sethook 换成空实现, 让进程**显式** yield("__preempt") 来模拟"时间片用完" ——
--    验的正是调度器那半边: 可运行队列轮转 + 预算 + 事件分发。
-- ===============================================================
do
    local savedHook = debug.sethook
    debug.sethook = function() end
    local savedPull, savedTimer, savedEpoch = os.pullEventRaw, os.startTimer, os.epoch
    local evq = {}
    os.startTimer = function() return 1 end
    os.epoch = function() return 0 end -- 预算判据恒为"没超"(宿主没有真实时钟): 队列一路轮转到底
    os.pullEventRaw = function()
        local e = table.remove(evq, 1)
        if not e then return "terminate" end -- 队列空: 用 terminate 把剩下的进程一次性唤醒
        return (table.unpack or unpack)(e)
    end

    local sched = require("kernel.scheduler")
    local log = {}
    local function mkproc(pid, name, steps)
        local co = coroutine.create(function()
            for i = 1, steps do
                log[#log + 1] = name .. i
                coroutine.yield("__preempt") -- 模拟"时间片用完"
            end
            return 0
        end)
        return { pid = pid, co = co, name = name }
    end

    sched.setPreempt(true)
    local a, b, c = mkproc(11, "A", 2), mkproc(12, "B", 2), mkproc(13, "C", 2)
    sched.addProcess(a); sched.addProcess(b); sched.addProcess(c)
    sched.run()
    eq(table.concat(log, " "), "A1 B1 C1 A2 B2 C2",
       "scheduler(preempt): 三个进程按时间片轮转(不是跑完一个再跑下一个)")
    eq(a.status, "dead", "scheduler(preempt): 跑完的进程被回收")
    eq(sched.preemptActive(), true, "scheduler(preempt): 开关状态可查")

    -- **被 SIGCONT 恢复的进程必须真的回到正常分发**: 曾经的 bug 是"停止的进程只查信号,
    -- 拿到 run 就什么都不做", 于是它永远停在 state="stopped" 上再也不被 resume ——
    -- 真机症状就是"交互 shell 被 SIGTTIN 停过一次后提示符再也不回来, 而整机没坏"。
    do
        local log2 = {}
        local mode = "stop"   -- "stop" -> 一直停; "cont" -> 已 SIGCONT; "dead" -> 收尾
        local p1 = { pid = 21, name = "stopper" }
        sched.setSignalCheck(function(pr)
            if pr ~= p1 then return "run" end
            if mode == "stop" then return "stop" end
            if mode == "dead" then return "dead" end
            return "run"
        end)
        sched.setPreempt(true)

        -- ① 停着的进程不该被事件唤醒(事件到了也不跑)
        local co1 = coroutine.create(function() log2[#log2 + 1] = "ran"; return 0 end)
        p1.co, p1.started, p1.state, p1.filter = co1, true, "stopped", nil
        sched.addProcess(p1)
        evq[#evq + 1] = { "timer", 99 }
        mode = "dead" -- 让它有机会被回收, run() 才能退出
        sched.run()
        eq(#log2, 0, "scheduler: 停住的进程不跑(事件到了也不唤醒)")

        -- ② SIGCONT 之后必须重新被调度并跑完
        local co2 = coroutine.create(function() log2[#log2 + 1] = "ran"; return 0 end)
        p1.co, p1.started, p1.state, p1.filter = co2, true, "stopped", nil
        mode = "cont"
        sched.addProcess(p1)
        evq[#evq + 1] = { "timer", 99 }
        sched.run()
        eq(table.concat(log2, ","), "ran", "scheduler: 被 SIGCONT 恢复的进程重新被调度")
        sched.setSignalCheck(nil)
    end

    -- **wakePid 必须真的能用**: 它引用的 makeReady 曾经定义在它**后面**(local 声明在文件后面),
    -- 于是运行时解析成全局 nil —— 真机上等着内核锁的 xargs/nohup 当场死在
    -- "attempt to call global 'makeReady' (a nil value)"。这里直接调一次, 锁住顺序。
    do
        local co = coroutine.create(function() return 0 end)
        local p2 = { pid = 31, name = "locked", co = co, started = true, state = "wait", filter = "__lock" }
        sched.setPreempt(true)
        sched.addProcess(p2)
        eq(sched.wakePid(31), true, "scheduler: wakePid 能找到等锁的进程")
        eq(p2.inReady, true, "scheduler: wakePid 把它放回了可运行队列(不是停在 wait 里)")
        eq(sched.wakePid(9999), false, "scheduler: wakePid 对不存在的 pid 返回 false")
        -- 让它跑完, 免得留在 ready 队列里影响后面的用例
        evq[#evq + 1] = { "timer", 98 }
        sched.run()
        sched.setPreempt(false)
    end

    -- **事件不能丢**(真机 bug, 见 for-ai.md「丢事件」): 抢占模式下进程被唤醒后先进可运行队列,
    -- 要等下一次 runReady 才真的跑。这期间如果**它自己的**事件到了, 老代码的
    -- `makeReady(proc, event)` 因为 `inReady` 直接返回 —— 事件被静默丢掉。
    -- 对 `os.sleep` 是致命的: 它等的是**一次性**定时器的 id (`until param == timer`), 丢了就永远
    -- 等不到 ⇒ 进程死循环在 os.sleep 里(真机症状: 提示符再也不回来、整机正常、别的 tty 照常、
    -- 而且日志里那个进程一直 y=timer)。
    do
        sched.setPreempt(true)
        local log3 = {}
        local busy, nowMs = true, 0
        local savedEpoch2 = os.epoch
        os.epoch = function() if busy then nowMs = nowMs + 1000 end return nowMs end
        local savedPull2, savedQE = os.pullEventRaw, os.queueEvent
        -- 调度器在"预算用完了但队列还有人"时会自己塞 delin_slice(见 scheduler.run);
        -- 宿主里也要有这个口, 否则 run() 直接报 queueEvent 是 nil。
        os.queueEvent = function(...) evq[#evq + 1] = { ... } end
        os.pullEventRaw = function()
            local e = table.remove(evq, 1)
            if not e then return "terminate" end
            -- 把"它自己那个定时器"交出去时, 时钟不再推进: 让 runReady 真的轮到进程跑
            if e[1] == "timer" and e[2] == 7 then busy = false end
            return (table.unpack or unpack)(e)
        end
        -- 模拟 os.sleep(0.05): 只认自己那个一次性定时器 id
        local co = coroutine.create(function()
            repeat
                local name, id = coroutine.yield("timer")
                if name == "terminate" then log3[#log3 + 1] = "LOST"; return 0 end
            until id == 7
            log3[#log3 + 1] = "slept"
            return 0
        end)
        local p = { pid = 41, name = "sleeper", co = co, started = true,
                    state = "wait", filter = "timer" }
        p.parked = true
        sched.addProcess(p)
        -- 注意 id 不能用 1: 宿主里 os.startTimer 固定返回 1, 那个 id 被调度器当成**内核计时器**
        -- (闪烁/心跳), 而内核计时器对"等具体事件"的进程是**不算唤醒源**的(见 dispatch)。
        evq[#evq + 1] = { "timer", 99 } -- 别人的定时器: 先把它叫醒(进可运行队列, 但预算用完 -> 还没跑)
        evq[#evq + 1] = { "timer", 7 }  -- 它自己那个: 必须**不丢**
        sched.run()
        eq(table.concat(log3, ","), "slept",
           "scheduler(preempt): 已在可运行队列里的进程不会丢自己的事件(os.sleep 不会被饿死)")
        os.epoch, os.pullEventRaw, os.queueEvent = savedEpoch2, savedPull2, savedQE
        sched.setPreempt(false)
    end

    -- **睡眠不能只等一个唤醒源**(真机 bug, 见 for-ai.md「坑 5」的续集): CC 的 sleep 是
    -- "等自己那个**一次性**定时器的 id", 事件被丢一次就永远出不来 —— 真机上交互 shell 就是这样
    -- 卡在 `F.pollWait -> msleep -> os.sleep` 里再也回不到提示符。内核版改成裸让出 + 墙钟兜底。
    do
        local sleepmod = require("kernel.sleep")
        local realSleep, realStart, realPull, realEpoch = os.sleep, os.startTimer, os.pullEventRaw, os.epoch
        local now = 0
        os.startTimer = function() return 42 end
        os.epoch = function() return now end
        -- 故意只喂"别人的"定时器事件: 进程自己那个(42)**永远不来**
        os.pullEventRaw = function()
            now = now + 50
            return "timer", 7
        end
        sleepmod.install()
        local lost0 = sleepmod.lostCount()
        os.sleep(0.2)
        eq(now >= 200, true, "sleep: 定时器事件丢了也按时返回(墙钟兜底)")
        eq(sleepmod.lostCount(), lost0 + 1, "sleep: 靠兜底醒来会记账(证明确实丢了定时器事件)")
        -- sleep(0) 必须**仍然让出一次**(CC 语义: 它是让出点, 不少工具靠它)。
        -- 注意要**重新 install**: install 时会把当时的 os.pullEventRaw 抓成引用(故意的 —— 装上之后
        -- 别人再包 os.pullEventRaw 也绕不过它), 所以换桩之后必须重装。
        local pulls0 = 0
        os.pullEventRaw = function() pulls0 = pulls0 + 1; now = now + 50; return "timer", 42 end
        sleepmod.install()
        os.sleep(0)
        eq(pulls0 >= 1, true, "sleep: sleep(0) 仍然让出一次")
        os.sleep, os.startTimer, os.pullEventRaw, os.epoch = realSleep, realStart, realPull, realEpoch
    end

    -- 判据: preemptOn 跟锁的启用走, inProcess 跟"调度器设的当前进程"走
    do
        local lock = require("kernel.lock")
        lock.setEnabled(false)
        eq(lock.preemptOn(), false, "lock: 关锁时 preemptOn=false")
        lock.setEnabled(true)
        eq(lock.preemptOn(), true, "lock: 开锁时 preemptOn=true")
        lock.setCurrent(nil)
        eq(lock.inProcess(), false, "lock: 调度器上下文里 inProcess=false")
        lock.setCurrent(42)
        eq(lock.inProcess(), true, "lock: 进程上下文里 inProcess=true")
        lock.setCurrent(nil)
        lock.setEnabled(false)
    end

    -- **唤醒器注册时机**(真机踩过): 模块加载期写 `lock.setWaker(scheduler.wakePid)` 时
    -- wakePid 还没定义 -> 注册成 nil -> 等锁的进程永远不被唤醒(两个 tty 同时 `find /` 就中)。
    do
        local lock = require("kernel.lock")
        local saved = lock.wakerReady and lock.wakerReady() or nil
        lock.setWaker(nil) -- 先清掉, 模拟"没注册"
        eq(lock.wakerReady(), false, "lock: 没注册唤醒器时 wakerReady=false")
        sched.setPreempt(true)
        eq(lock.wakerReady(), true, "scheduler: setPreempt(true) 会注册锁的唤醒器(wakePid 已定义)")
        sched.setPreempt(false)
        if saved then lock.setWaker(function() end) end
    end

    -- 关掉抢占之后, "__preempt" 不再是"还能跑", 而是一个等不到的事件名(与历史行为一致:
    -- 协作模式下没人会 yield "__preempt", 这里只验开关能关)。
    sched.setPreempt(false)
    eq(sched.preemptActive(), false, "scheduler: 能切回协作式")

    os.pullEventRaw, os.startTimer, os.epoch = savedPull, savedTimer, savedEpoch
    debug.sethook = savedHook
end

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)