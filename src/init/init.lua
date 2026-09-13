--[[ Delin PID 1 (init) -- the user-space service manager (systemd-style subset).
     Runs inside an isolated process environment (pid/ppid/spawn/print/fs/syscalls are injected by
     the kernel, every other raw API is used directly).

     Boot sequence:
       1. create /run and /var/log (real directories, not tmpfs -- Delin has no tmpfs)
       2. install signal handlers (SIGTERM/SIGINT/SIGQUIT -> shutdown, SIGHUP -> reload units)
       3. load units (/lib/systemd/system + /etc/systemd/system, .wants/.requires marker dirs)
       4. generate <mountpoint>.mount units from /etc/fstab and hook them onto local-fs.target
       5. instantiate getty@ttyN.service for every /dev/ttyN and hook them onto getty.target
       6. register the init.* control syscalls (systemctl's private control channel; Delin has no
          Unix socket/D-Bus)
       7. start default.target; on failure or absence enter rescue (a login on every tty)
       8. main loop: drive the service engine (timers/delayed restarts/timeouts) until a shutdown
          request arrives

     No self-tests here -- test code lives in scripts/ and the host testbed tools/harness.lua. ]]

local unitlib = __require("unit")
local svc     = __require("service")

local bootMs = os.epoch("utc")
svc.bootMs = bootMs
svc.log = function(...) print(...) end

local shutdownRequested = false
local reloadRequested = false

local function log(msg) print("[init] " .. tostring(msg)) end

-- ---------------------------------------------------------------
-- Signals: PID 1 is not affected by interactive signals such as ^C/^Z; a shutdown signal
-- takes the normal shutdown path
-- ---------------------------------------------------------------
syscalls["signal.install"](15, function() shutdownRequested = true end) -- SIGTERM
syscalls["signal.install"](2,  function() shutdownRequested = true end) -- SIGINT
syscalls["signal.install"](3,  function() shutdownRequested = true end) -- SIGQUIT
syscalls["signal.install"](1,  function() reloadRequested = true end)   -- SIGHUP: daemon-reload
syscalls["signal.install"](20, function() end)                          -- SIGTSTP: ignore
syscalls["signal.install"](21, function() end)                          -- SIGTTIN: ignore
syscalls["signal.install"](22, function() end)                          -- SIGTTOU: ignore

-- ---------------------------------------------------------------
-- Directories: /run (pid files) and /var/log (logs). Created when missing, and a failed
-- creation is a fail-fast error.
-- ---------------------------------------------------------------
for _, dir in ipairs({ "/run", "/var/log" }) do
    if not fs.exists(dir) then
        fs.makeDir(dir)
        if not fs.exists(dir) then error("init: cannot create " .. dir, 0) end
        log("created " .. dir)
    end
end

-- ---------------------------------------------------------------
-- Unit generation: /etc/fstab -> mount units
-- ---------------------------------------------------------------
local function generateFstabUnits()
    local entries, err = syscalls["fstab.entries"]()
    if not entries then
        -- a bad fstab is always fail-fast: local-fs.target fails -> multi-user.target fails -> rescue
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
-- Unit generation: software RAID assembly (mdadm.service) before any mount
-- ---------------------------------------------------------------
-- Linux assembles md arrays in initramfs/udev before local-fs.target; Delin has neither, so init
-- wires /lib/systemd/system/mdadm.service (oneshot: /bin/mdadm --assemble --scan) into
-- local-fs-pre.target. Every mount unit generated from /etc/fstab runs After=local-fs-pre.target,
-- so an array listed in /etc/mdadm.conf is up before the filesystems on it are mounted.
-- Wants (soft), not Requires: a machine whose /lib/systemd/system predates this unit must still
-- boot (it just has no RAID assembly). A *failing* assembly still fails loudly: the array never
-- appears, so the fstab mount unit that needs it fails, and that is a hard dependency of
-- local-fs.target.
local function generateMdAssembly()
    local rec, err = svc.get("mdadm.service")
    if not rec then
        log("no mdadm.service: " .. tostring(err))
        return
    end
    svc.add(rec)
    svc.addDep("local-fs-pre.target", rec.name, false)
    log("mdassembly: mdadm.service <- local-fs-pre.target")
end

-- ---------------------------------------------------------------
-- Unit generation: one getty@ttyN.service per /dev/ttyN
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
-- rescue: when no default.target is usable (units not deployed / a dependency failed to start),
-- start a login on every tty. Equivalent to systemd's emergency/rescue mode: it hands the admin
-- a shell to fix the configuration.
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
-- Control interface: systemctl calls through the shared syscall table (the equivalent of a
-- private socket). These functions run in the caller's (systemctl's) process context; whenever
-- waiting is needed the caller's coroutine yields.
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
-- Load + start
-- ---------------------------------------------------------------
local function loadUnits()
    local n = svc.loadAll()
    log("loaded " .. n .. " unit(s) from /lib/systemd/system + /etc/systemd/system")
    generateFstabUnits()
    generateMdAssembly()
    local nTty = generateGettys()
    log("generated getty on " .. nTty .. " tty(s)")
end

syscalls["proc.onExit"](svc.onProcessExit) -- service supervision: child exit callback
registerControl()
loadUnits()

local ok, err = svc.start("default.target")
if not ok then
    rescue(tostring(err))
end

-- ---------------------------------------------------------------
-- Main loop: drive the service engine; init never exits (unless a shutdown is requested)
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
