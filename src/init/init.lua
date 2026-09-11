--[[ Delin PID 1 (init) —— 用户态服务管理器 (systemd 风格子集)。
     运行在隔离进程环境中(pid/ppid/spawn/print/fs/syscalls 由内核注入, 其余原始 API 直用)。

     启动序列:
       1. 建立 /run、/var/log(真实目录, 非 tmpfs —— Delin 无 tmpfs)
       2. 安装信号处理(SIGTERM/SIGINT/SIGQUIT -> 关机, SIGHUP -> 重载单元)
       3. 装载单元(/lib/systemd/system + /etc/systemd/system, .wants/.requires 标记目录)
       4. 由 /etc/fstab 生成 <mountpoint>.mount 单元并挂到 local-fs.target
       5. 为每个 /dev/ttyN 实例化 getty@ttyN.service 并挂到 getty.target
       6. 注册 init.* 控制 syscall(systemctl 的私有控制通道; Delin 无 Unix socket/D-Bus)
       7. 启动 default.target; 失败或缺失则进入 rescue(每个 tty 起 login)
       8. 主循环: 驱动服务引擎(timer/延迟重启/超时)直到收到关机请求

     不做任何自检 —— 测试代码见 scripts/ 与宿主测试台 tools/harness.lua。 ]]

local unitlib = __require("unit")
local svc     = __require("service")

local bootMs = os.epoch("utc")
svc.bootMs = bootMs
svc.log = function(...) print(...) end

local shutdownRequested = false
local reloadRequested = false

local function log(msg) print("[init] " .. tostring(msg)) end

-- ---------------------------------------------------------------
-- 信号: PID 1 不接受 ^C/^Z 之类的交互信号影响; 收到关机信号则走正常停机
-- ---------------------------------------------------------------
syscalls["signal.install"](15, function() shutdownRequested = true end) -- SIGTERM
syscalls["signal.install"](2,  function() shutdownRequested = true end) -- SIGINT
syscalls["signal.install"](3,  function() shutdownRequested = true end) -- SIGQUIT
syscalls["signal.install"](1,  function() reloadRequested = true end)   -- SIGHUP: daemon-reload
syscalls["signal.install"](20, function() end)                          -- SIGTSTP: 忽略
syscalls["signal.install"](21, function() end)                          -- SIGTTIN: 忽略
syscalls["signal.install"](22, function() end)                          -- SIGTTOU: 忽略

-- ---------------------------------------------------------------
-- 目录: /run(pid 文件)、/var/log(日志)。缺失即建, 建不了则 fail-fast 报错。
-- ---------------------------------------------------------------
for _, dir in ipairs({ "/run", "/var/log" }) do
    if not fs.exists(dir) then
        fs.makeDir(dir)
        if not fs.exists(dir) then error("init: cannot create " .. dir, 0) end
        log("created " .. dir)
    end
end

-- ---------------------------------------------------------------
-- 单元生成: /etc/fstab -> mount 单元
-- ---------------------------------------------------------------
local function generateFstabUnits()
    local entries, err = syscalls["fstab.entries"]()
    if not entries then
        -- 坏 fstab 一律 fail-fast: local-fs.target 失败 -> multi-user.target 失败 -> rescue
        log("FATAL: /etc/fstab: " .. tostring(err))
        local rec = svc.units["local-fs.target"]
        if rec then rec.active, rec.sub, rec.failReason = "failed", "failed", tostring(err) end
        return
    end
    for _, e in ipairs(entries) do
        if e.opts.noauto then
            log("fstab: " .. e.mountpoint .. " (noauto, skipped)")
        else
            local rec = {
                name = e.unit, kind = "mount", path = "/etc/fstab:" .. e.line,
                active = "inactive", sub = "dead",
                description = e.device .. " on " .. e.mountpoint,
                requires = {}, wants = {}, before = { "local-fs.target" },
                after = { "local-fs-pre.target" }, conflicts = {}, wantedBy = {},
                what = e.device, where = e.mountpoint, fstype = e.fstype, options = e.options,
            }
            svc.add(rec)
            svc.addDep("local-fs.target", rec.name, not e.opts.nofail)
            log("fstab: " .. e.unit .. " <- " .. e.device .. " " .. e.mountpoint
                .. " " .. e.fstype .. (e.opts.nofail and " (nofail)" or ""))
        end
    end
end

-- ---------------------------------------------------------------
-- 单元生成: 每个 /dev/ttyN 一个 getty@ttyN.service
-- ---------------------------------------------------------------
local function generateGettys()
    local ttys = syscalls["tty.list"]()
    local missing = false
    for _, tn in ipairs(ttys) do
        local name = "getty@" .. tn .. ".service"
        local rec, err = svc.get(name)
        if not rec then
            if not missing then
                log("getty@.service not available: " .. tostring(err))
                missing = true
            end
        else
            svc.add(rec)
            svc.addDep("getty.target", name, false)
        end
    end
    return #ttys
end

-- ---------------------------------------------------------------
-- rescue: 无可用 default.target(未部署单元 / 依赖启动失败)时, 每个 tty 起一个 login。
-- 等价 systemd 的 emergency/rescue 模式: 给管理员一个能修配置的 shell。
-- ---------------------------------------------------------------
local function rescue(reason)
    log("rescue mode: " .. reason)
    for _, rec in ipairs(svc.list()) do
        if rec.active ~= "inactive" then pcall(svc.stop, rec.name) end
    end
    local f = fs.open("/bin/login", "r")
    if not f then
        log("FATAL: /bin/login not found, no rescue shell")
        return
    end
    local src = f:readAll()
    f:close()
    for _, tn in ipairs(syscalls["tty.list"]()) do
        local lpid = spawn(src, "login", 0, 0, { [0] = "/bin/login", tn })
        log("rescue: login on " .. tn .. " pid=" .. tostring(lpid))
    end
end

-- ---------------------------------------------------------------
-- 控制接口: systemctl 经共享 syscall 表调用(等价的 private socket)。
-- 这些函数在调用者(systemctl)的进程上下文里执行; 需要等待时由调用者协程让出。
-- ---------------------------------------------------------------
local function registerControl()
    syscalls["init.start"]     = function(name) return svc.start(name) end
    syscalls["init.stop"]      = function(name) return svc.stop(name) end
    syscalls["init.restart"]   = function(name) return svc.restart(name) end
    syscalls["init.status"]    = function(name) return svc.snapshot(name) end
    syscalls["init.list"]      = function() return svc.list() end
    syscalls["init.enable"]    = function(name) return svc.enable(name) end
    syscalls["init.disable"]   = function(name) return svc.disable(name) end
    syscalls["init.isEnabled"] = function(name) return svc.isEnabled(name) end
    syscalls["init.reload"]    = function() reloadRequested = true; return true end
    syscalls["init.shutdown"]  = function() shutdownRequested = true; return true end
    syscalls["init.bootTime"]  = function() return bootMs end
end

-- ---------------------------------------------------------------
-- 装载 + 启动
-- ---------------------------------------------------------------
local function loadUnits()
    local n = svc.loadAll()
    log("loaded " .. n .. " unit(s) from /lib/systemd/system + /etc/systemd/system")
    generateFstabUnits()
    local nTty = generateGettys()
    log("generated getty on " .. nTty .. " tty(s)")
end

syscalls["proc.onExit"](svc.onProcessExit) -- 服务监督: 子进程退出回调
registerControl()
loadUnits()

local ok, err = svc.start("default.target")
if not ok then
    rescue(tostring(err))
end

-- ---------------------------------------------------------------
-- 主循环: 驱动服务引擎; init 永不退出(除非收到关机请求)
-- ---------------------------------------------------------------
log("init up (pid " .. pid .. "), default.target " .. (ok and "active" or "FAILED"))
while not shutdownRequested do
    if reloadRequested then
        reloadRequested = false
        log("reloading units (daemon-reload)")
        loadUnits()
    end
    svc.tick()
    os.sleep(0.1)
end

log("shutting down: stopping all units")
for _, rec in ipairs(svc.list()) do
    if rec.active ~= "inactive" then pcall(svc.stop, rec.name) end
end
os.sleep(1)
log("init: bye")
