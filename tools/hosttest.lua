--[[ Delin 宿主测试: 在 HOST 上验证 init 单元引擎(解析/依赖序/启停/重启/timer)、
     /etc/fstab 解析与 mount 单元生成。用真实的 src/init/*.lua 源码 + 内存桩,
     不依赖 CC 真机(真机验证见 tools/realmachine.py)。
     用法: lua5.1 tools/hosttest.lua ]]

io.stdout:setvbuf("line")
os.epoch = os.epoch or function() return os.time() * 1000 end -- 宿主桩: 内核 klog 载入时取引导标识
package.path = "/home/worker/delin/src/?.lua;" .. package.path

local REPO = "/home/worker/delin"
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
function F.exists(p) return readFile(host(p)) ~= nil or os.execute("[ -d " .. host(p) .. " ]") == 0 end
function F.isDir(p) return os.execute("[ -d " .. host(p) .. " ]") == 0 end
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
    local env = setmetatable({}, { __index = _G }) -- 与内核注入的进程环境一致: __index = _G
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
        local tenv = setmetatable({
            fs = F, io = makeIo({ input = opts.input, output = outHandle }),
            syscalls = env.syscalls, args = argv or {}, argv = argv or {}, argc = #(argv or {}), arg0 = path,
            pid = 900, ppid = 1, uid = 0, gid = 0, cwd = "/",
            -- Delin 的 print 走内核控制台(klog), 不是 stdout; 宿主测试忽略它。
            print = function() end,
            os = setmetatable({
                sleep = function() coroutine.yield() end,
                epoch = function() return env.now end,
            }, { __index = _G.os }),
        }, { __index = _G })
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
do
    local bundle = readFile(REPO .. "/dist/kernel.lua")
    ok(bundle ~= nil, "bundle: dist/kernel.lua 存在")
    local lvl, src = bundle:match('__chunks%["kernel%.init_src"%] = function%(%)\n%s+return %[(=*)%[(.*)%]%1%]%s*\nend')
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
end

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
