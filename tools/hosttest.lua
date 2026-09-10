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
    local fh = io.popen("stat -c '%f %s %Y' -- " .. h .. " 2>/dev/null")
    local line = fh:read("*a"); fh:close()
    local mode, size, mtime = line:match("^(%x+)%s+(%d+)%s+(%d+)")
    return { mode = tonumber(mode, 16), size = tonumber(size), mtime = tonumber(mtime), isDir = F.isDir(p) }
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
        local chunk
        if _VERSION == "Lua 5.1" then
            chunk = assert(loadstring(src, name))
            setfenv(chunk, env)
        else
            chunk = assert(load(src, name, "t", env))
        end
        return chunk()
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
        if path == "/bin/logrotate" then env.pendingExits[nextPid] = 0 end
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
        local outHandle = {
            write = function(_, s) outbuf[#outbuf + 1] = tostring(s); return #s end,
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
            chunk = assert(loadstring(src, path))
            setfenv(chunk, tenv)
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
    env3.syscalls["klog.stats"] = kmsgStats -- 宿主内存设备取代真实 ring buffer 的统计
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
            chunk = assert(loadstring(src, "init_src"))
            setfenv(chunk, env)
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
        chunk = assert(loadstring(src, "ccprinter"))
        setfenv(chunk, env)
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
            width = w, height = h, fills = 0, flushes = 0, calls = {},
            getSize = function() return w, h end,
            text = function(x, y, s, fg, bg)
                dev.calls[#dev.calls + 1] = { x = x, y = y, s = s, fg = fg, bg = bg }
                dev.lastText = { x = x, y = y, s = s, fg = fg, bg = bg }
            end,
            blit = function(x, y, s, fg, bg) dev.lastBlit = { x = x, y = y, s = s, fg = fg, bg = bg } end,
            fill = function(color) dev.fills = dev.fills + 1; dev.lastFill = color end,
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
        chunk = assert(loadstring(src, "redstone"))
        setfenv(chunk, env)
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
        vchunk = assert(loadstring(vsrc, "redstone_verify"))
        setfenv(vchunk, venv)
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

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)