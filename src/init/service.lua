--[[ Delin init 服务引擎 (systemd 风格子集, 跑在 PID 1 的用户态里)。
     单元来源: /lib/systemd/system(厂商) 与 /etc/systemd/system(管理员, 同名覆盖),
     <target>.wants/ 与 <target>.requires/ 目录里的条目等价于在该 target 上加 Wants=/Requires=
     (Delin 的 CC 原生 fs 无符号链接, 故用同名空标记文件而非 systemd 的 symlink)。
     依赖: Requires(硬依赖, 失败则本单元不启动) / Wants(软依赖) / After/Before(仅排序) /
           Conflicts(启动前停掉冲突单元)。启动顺序 = 闭包 + 拓扑排序, 有环即 fail-fast。
     类型: service(Type=simple|oneshot, Restart=no|always|on-failure|on-abnormal, RestartSec=) /
           target / timer(OnBootSec= OnActiveSec= OnUnitActiveSec=) / mount(What= Where= Type=)。
     服务监督: init 注册 proc.onExit 钩子, 子进程退出时在此更新状态并按 Restart= 排定重启。
     本模块不做 I/O 阻塞, 唯一会让出的是等待 oneshot 启动完成(经 os.sleep, 由内核调度器驱动)。 ]]

local unitlib = __require("unit")

local svc = {}

svc.log = print          -- init 可换成带前缀的日志函数
svc.units = {}           -- name -> rec
svc.bootMs = 0           -- init 记录引导时刻(OnBootSec 基准)
local byPid = {}         -- pid -> rec(服务监督)

local UNIT_DIRS = { "/lib/systemd/system", "/etc/systemd/system" }
local STATE_DIR = "/etc/systemd/system" -- enable 标记写在这里(systemd 的 /etc 覆盖层)

local function log(...) svc.log(...) end

local function readFile(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f:readAll()
    f:close()
    return s
end

--- 在单元目录里定位单元文件(支持 getty@tty0.service -> getty@.service 模板)。
---@param name string
---@return string|nil path, string|nil templatePath
local function findUnitFile(name)
    local kind = unitlib.kind(name)
    if not kind then return nil end
    local base, instance = name:match("^([^@]+)@(.+)%.[%a]+$")
    local template = base and (base .. "@." .. kind) or nil
    for i = #UNIT_DIRS, 1, -1 do -- 管理员目录优先(覆盖厂商)
        local dir = UNIT_DIRS[i]
        if fs.exists(dir .. "/" .. name) then return dir .. "/" .. name end
    end
    if template then
        for i = #UNIT_DIRS, 1, -1 do
            local dir = UNIT_DIRS[i]
            if fs.exists(dir .. "/" .. template) then return dir .. "/" .. template, instance end
        end
    end
end

--- 装载一个单元(按名字)。已在表中则直接返回。
---@param name string
---@return table|nil rec, string|nil err
function svc.get(name)
    local rec = svc.units[name]
    if rec then return rec end
    local path, instance = findUnitFile(name)
    if not path then return nil, name .. ": unit not found" end
    local text = readFile(path)
    if not text then return nil, path .. ": cannot read" end
    local parsed, err = unitlib.parse(text, name, instance)
    if not parsed then return nil, err end
    rec = svc.finalize(parsed, name, path)
    if not rec then return nil, name .. ": invalid unit" end
    svc.units[name] = rec
    return rec
end

--- 把解析结果归一化成运行时记录(校验 + 字段提取)。fail-fast: 非法值直接返回 nil+err。
---@param parsed table
---@param name string
---@param path string
---@return table|nil rec, string|nil err
function svc.finalize(parsed, name, path)
    local kind = unitlib.kind(name)
    if not kind then return nil, name .. ": unknown unit type" end
    local rec = {
        name = name, kind = kind, path = path, parsed = parsed,
        active = "inactive", sub = "dead",
        description = unitlib.get(parsed, "Unit", "Description") or name,
        requires = unitlib.list(parsed, "Unit", "Requires"),
        wants    = unitlib.list(parsed, "Unit", "Wants"),
        after    = unitlib.list(parsed, "Unit", "After"),
        before   = unitlib.list(parsed, "Unit", "Before"),
        conflicts= unitlib.list(parsed, "Unit", "Conflicts"),
        wantedBy = unitlib.list(parsed, "Install", "WantedBy"),
    }
    if kind == "service" then
        rec.type = (unitlib.get(parsed, "Service", "Type") or "simple"):lower()
        if rec.type ~= "simple" and rec.type ~= "oneshot" then
            return nil, name .. ": unsupported Type=" .. rec.type .. " (simple|oneshot)"
        end
        local exec = unitlib.raw(parsed, "Service", "ExecStart")
        if not exec or exec == "" then return nil, name .. ": missing ExecStart=" end
        local argv = unitlib.splitArgs(exec)
        rec.exec = argv[1]
        rec.execArgs = {}
        for i = 2, #argv do rec.execArgs[#rec.execArgs + 1] = argv[i] end
        rec.restart = (unitlib.get(parsed, "Service", "Restart") or "no"):lower()
        if not ({ no = true, always = true, ["on-failure"] = true, ["on-abnormal"] = true })[rec.restart] then
            return nil, name .. ": unsupported Restart=" .. rec.restart
        end
        rec.restartSec = unitlib.time(unitlib.get(parsed, "Service", "RestartSec")) or 1
        rec.timeoutStartSec = unitlib.time(unitlib.get(parsed, "Service", "TimeoutStartSec")) or 60
        rec.timeoutStopSec = unitlib.time(unitlib.get(parsed, "Service", "TimeoutStopSec")) or 10
        rec.remainAfterExit = (unitlib.get(parsed, "Service", "RemainAfterExit") or "no"):lower() == "yes"
        rec.startLimitBurst = tonumber(unitlib.get(parsed, "Service", "StartLimitBurst")) or 5
        rec.startLimitIntervalSec = unitlib.time(unitlib.get(parsed, "Service", "StartLimitIntervalSec")) or 10
    elseif kind == "timer" then
        local function sec(key)
            local v = unitlib.get(parsed, "Timer", key)
            if not v then return nil end
            local t = unitlib.time(v)
            if not t then error(name .. ": bad " .. key .. "=" .. v, 0) end
            return t
        end
        local ok, onBoot = pcall(sec, "OnBootSec")
        if not ok then return nil, onBoot end
        local ok2, onActive = pcall(sec, "OnActiveSec")
        if not ok2 then return nil, onActive end
        local ok3, onUnitActive = pcall(sec, "OnUnitActiveSec")
        if not ok3 then return nil, onUnitActive end
        rec.onBootSec, rec.onActiveSec, rec.onUnitActiveSec = onBoot, onActive, onUnitActive
        if unitlib.get(parsed, "Timer", "OnCalendar") then
            return nil, name .. ": OnCalendar= is not supported (use OnBootSec=/OnUnitActiveSec=)"
        end
        if not (onBoot or onActive or onUnitActive) then
            return nil, name .. ": timer needs OnBootSec=, OnActiveSec= or OnUnitActiveSec="
        end
        rec.unit = unitlib.get(parsed, "Timer", "Unit") or (name:gsub("%.timer$", ".service"))
    elseif kind == "mount" then
        rec.what = unitlib.get(parsed, "Mount", "What")
        rec.where = unitlib.get(parsed, "Mount", "Where")
        rec.fstype = unitlib.get(parsed, "Mount", "Type")
        rec.options = unitlib.get(parsed, "Mount", "Options")
        if not (rec.what and rec.where and rec.fstype) then
            return nil, name .. ": mount unit needs What=, Where= and Type="
        end
    end
    return rec
end

--- 扫描单元目录: 载入全部单元文件, 再把 <unit>.wants/.requires 标记目录折进依赖。
---@return integer count
function svc.loadAll()
    local keep = svc.units
    svc.units = {}
    local files = {}
    for _, dir in ipairs(UNIT_DIRS) do
        if fs.exists(dir) and fs.isDir(dir) then
            local names = fs.list(dir) or {}
            table.sort(names)
            for _, fn in ipairs(names) do
                if unitlib.kind(fn) and fs.exists(dir .. "/" .. fn) and not fs.isDir(dir .. "/" .. fn) then
                    files[fn] = dir .. "/" .. fn -- 后扫到的目录(/etc)覆盖厂商
                end
            end
        end
    end
    local n = 0
    for name, path in pairs(files) do
        local text = readFile(path)
        if not text then
            log("[init] " .. path .. ": cannot read")
        else
            local parsed, err = unitlib.parse(text, name)
            if not parsed then
                log("[init] " .. tostring(err))
            else
                local rec = svc.finalize(parsed, name, path)
                if not rec then
                    log("[init] " .. name .. ": invalid unit")
                else
                    svc.units[name] = rec
                    n = n + 1
                end
            end
        end
    end
    -- <unit>.wants / <unit>.requires 目录
    for _, dir in ipairs(UNIT_DIRS) do
        if fs.exists(dir) and fs.isDir(dir) then
            for _, sub in ipairs(fs.list(dir) or {}) do
                local owner, depKind = sub:match("^(.+%.[%a]+)%.wants$"), "wants"
                if not owner then owner, depKind = sub:match("^(.+%.[%a]+)%.requires$"), "requires" end
                if owner and unitlib.kind(owner) then
                    local rec = svc.units[owner]
                    if not rec then
                        rec = { name = owner, kind = unitlib.kind(owner), path = "(implicit)", parsed = { name = owner, sections = {} },
                                active = "inactive", sub = "dead", description = owner,
                                requires = {}, wants = {}, after = {}, before = {}, conflicts = {}, wantedBy = {} }
                        svc.units[owner] = rec
                    end
                    local full = dir .. "/" .. sub
                    if fs.isDir(full) then
                        for _, dep in ipairs(fs.list(full) or {}) do
                            if unitlib.kind(dep) then
                                local list = (depKind == "wants") and rec.wants or rec.requires
                                local dup = false
                                for _, x in ipairs(list) do if x == dep then dup = true; break end end
                                if not dup then list[#list + 1] = dep end
                            end
                        end
                    end
                end
            end
        end
    end
    -- 重载时保留仍在运行的服务的状态
    for name, old in pairs(keep) do
        local rec = svc.units[name]
        if rec and old.pid and old.active ~= "inactive" then
            rec.active, rec.sub, rec.pid, rec.startMs = old.active, old.sub, old.pid, old.startMs
            byPid[old.pid] = rec
        end
    end
    return n
end

--- 把新单元注入内存(init 生成的 fstab mount 单元 / getty 实例)。
---@param rec table
function svc.add(rec)
    svc.units[rec.name] = rec
end

--- 给某单元追加 Wants/Requires 依赖(不存在则创建隐式 target 记录)。
function svc.addDep(owner, dep, hard)
    local rec = svc.units[owner]
    if not rec then
        rec = { name = owner, kind = unitlib.kind(owner), path = "(implicit)", parsed = { name = owner, sections = {} },
                active = "inactive", sub = "dead", description = owner,
                requires = {}, wants = {}, after = {}, before = {}, conflicts = {}, wantedBy = {} }
        svc.units[owner] = rec
    end
    local list = hard and rec.requires or rec.wants
    for _, x in ipairs(list) do if x == dep then return end end
    list[#list + 1] = dep
end

--- 计算启动顺序: 从 root 出发收集 Requires/Wants 闭包, 按 After/Before 拓扑排序。
---@param root string
---@return string[]|nil order, string|nil err
function svc.startOrder(root)
    local closure, stack = {}, { { name = root, hard = true } }
    while #stack > 0 do
        local item = table.remove(stack)
        local n = item.name
        if not closure[n] then
            local rec, err = svc.get(n)
            if not rec then
                if item.hard then return nil, err end
                log("[init] " .. n .. ": " .. tostring(err) .. " (soft dependency, skipped)")
            else
                closure[n] = rec
                for _, d in ipairs(rec.requires) do stack[#stack + 1] = { name = d, hard = true } end
                for _, d in ipairs(rec.wants) do stack[#stack + 1] = { name = d, hard = false } end
            end
        end
    end
    local indeg, adj = {}, {}
    for n in pairs(closure) do indeg[n] = 0; adj[n] = {} end
    local function edge(a, b)
        if a ~= b and closure[a] and closure[b] then
            for _, x in ipairs(adj[a]) do if x == b then return end end
            adj[a][#adj[a] + 1] = b
            indeg[b] = indeg[b] + 1
        end
    end
    for n, rec in pairs(closure) do
        for _, a in ipairs(rec.after) do edge(a, n) end
        for _, b in ipairs(rec.before) do edge(n, b) end
        -- systemd.target(5): target 的 Requires=/Wants= 自动补 After= ——
        -- target 只有在它拉起的单元都启动后才算 active。
        if rec.kind == "target" then
            for _, d in ipairs(rec.requires) do edge(d, n) end
            for _, d in ipairs(rec.wants) do edge(d, n) end
        end
    end
    local order, ready = {}, {}
    for n, d in pairs(indeg) do if d == 0 then ready[#ready + 1] = n end end
    table.sort(ready)
    local total = 0
    for _ in pairs(closure) do total = total + 1 end
    while #ready > 0 do
        local n = table.remove(ready, 1)
        order[#order + 1] = n
        for _, m in ipairs(adj[n]) do
            indeg[m] = indeg[m] - 1
            if indeg[m] == 0 then ready[#ready + 1] = m; table.sort(ready) end
        end
    end
    if #order < total then
        local cyc = {}
        for n, d in pairs(indeg) do if d > 0 then cyc[#cyc + 1] = n end end
        table.sort(cyc)
        return nil, "ordering cycle among: " .. table.concat(cyc, " ")
    end
    return order
end

local function markFailed(rec, why)
    rec.active, rec.sub = "failed", "failed"
    rec.failReason = why
    log("[init] " .. rec.name .. ": FAILED: " .. tostring(why))
end

--- 记录一次启动尝试; 超过 StartLimitBurst/StartLimitIntervalSec 则拒绝重启
--- (systemd 的 start limit: 防止配置错误的服务无限重启刷屏)。
---@return boolean allowed
local function noteStart(rec)
    local now = os.epoch("utc")
    rec.startTimes = rec.startTimes or {}
    local window = (rec.startLimitIntervalSec or 10) * 1000
    local keep = {}
    for _, t in ipairs(rec.startTimes) do
        if now - t < window then keep[#keep + 1] = t end
    end
    keep[#keep + 1] = now
    rec.startTimes = keep
    return #keep <= (rec.startLimitBurst or 5)
end

local function scheduleRestart(rec)
    if not noteStart(rec) then
        markFailed(rec, "start request repeated too quickly (StartLimitBurst=" .. rec.startLimitBurst .. ")")
        return
    end
    rec.restartAt = os.epoch("utc") + math.floor(rec.restartSec * 1000)
    rec.active, rec.sub = "activating", "auto-restart"
end

--- 启动单个单元(不做依赖检查, 由 svc.start 保证顺序)。
---@return boolean|nil ok, string|nil err
local function startOne(rec)
    if rec.kind == "target" then
        rec.active, rec.sub = "active", "active"
        return true
    elseif rec.kind == "timer" then
        rec.active, rec.sub = "active", "waiting"
        local now = os.epoch("utc")
        rec.next = rec.onBootSec and (svc.bootMs + rec.onBootSec * 1000) or (now + rec.onActiveSec * 1000)
        return true
    elseif rec.kind == "mount" then
        for _, m in ipairs(syscalls["fs.mounts"]()) do
            if m.root == rec.where then
                rec.active, rec.sub = "active", "mounted"
                log("[init] " .. rec.name .. ": " .. rec.where .. " already mounted, skipping")
                return true
            end
        end
        if not fs.exists(rec.where) then fs.makeDir(rec.where) end
        local ok, info = syscalls["fs.mount"](rec.what, rec.where, rec.fstype)
        if not ok then return nil, rec.what .. " -> " .. rec.where .. ": " .. tostring(info) end
        rec.active, rec.sub = "active", "mounted"
        rec.mounted = info
        return true
    elseif rec.kind == "service" then
        -- ppid=1: 服务挂在 init 名下(与 systemd 一致), 而不是发起 systemctl 的进程。
        local pid, err = syscalls["proc.spawnFile"](rec.exec, rec.execArgs, { cwd = "/", ppid = 1 })
        if not pid then return nil, rec.exec .. ": " .. tostring(err) end
        rec.pid = pid
        rec.exitCode, rec.termSig = nil, nil
        rec.startMs = os.epoch("utc")
        byPid[pid] = rec
        if rec.type == "oneshot" then
            rec.active, rec.sub = "activating", "start"
        else
            rec.active, rec.sub = "active", "running"
        end
        return true
    end
    return nil, rec.name .. ": unsupported unit kind"
end

--- 等待一个 oneshot 完成启动(或失败)。
--- 等待期间照常驱动引擎(延迟重启/timer/超时), 否则 init 会卡在一个慢 oneshot 上,
--- 让 timer 与重启排期停摆。
local function waitUnit(rec)
    local deadline = os.epoch("utc") + rec.timeoutStartSec * 1000
    while rec.active == "activating" do
        if os.epoch("utc") > deadline then
            markFailed(rec, "start timeout")
            if rec.pid then syscalls["signal.kill"](rec.pid, 9) end
            return
        end
        svc.tick()
        os.sleep(0.05)
    end
end

--- 启动一个单元(含其 Requires/Wants 闭包), 按依赖拓扑序执行。
---@param name string
---@return boolean|nil ok, string|nil err
function svc.start(name)
    local order, err = svc.startOrder(name)
    if not order then return nil, err end
    -- 显式 start 的根单元允许重试(等价 systemd 的 systemctl start 重试 failed 单元);
    -- 依赖链上已经 failed 的单元不再重试, 否则"坏配置"会被静默修好。
    local rootRec = svc.units[name]
    if rootRec and rootRec.active == "failed" then
        rootRec.active, rootRec.sub, rootRec.failReason = "inactive", "dead", nil
    end
    local failed = {}
    for _, n in ipairs(order) do
        local rec = svc.units[n]
        if rec.active == "failed" then
            failed[n] = true
        elseif rec.active ~= "active" and rec.active ~= "activating" then
            -- 硬依赖必须已 active
            local bad
            for _, d in ipairs(rec.requires) do
                local dr = svc.units[d]
                if not dr or dr.active ~= "active" then bad = d; break end
            end
            if bad then
                failed[n] = true
                markFailed(rec, "dependency failed: " .. bad)
            else
                -- Conflicts=: 启动前停掉冲突单元
                for _, c in ipairs(rec.conflicts) do
                    local cr = svc.units[c]
                    if cr and cr.active ~= "inactive" then svc.stop(c) end
                end
                local ok, e = startOne(rec)
                if not ok then failed[n] = true; markFailed(rec, e) end
            end
        end
        if rec.kind == "service" and rec.type == "oneshot" and rec.active == "activating" then
            waitUnit(rec)
        end
    end
    if failed[name] or svc.units[name].active == "failed" then
        return nil, svc.units[name].name .. ": " .. tostring(svc.units[name].failReason or "failed")
    end
    return true
end

--- 停止一个单元(服务发 SIGTERM, 超时 SIGKILL; mount 卸载)。
---@return boolean|nil ok, string|nil err
function svc.stop(name)
    local rec, err = svc.get(name)
    if not rec then return nil, err end
    if rec.kind == "mount" then
        local ok, uerr = syscalls["fs.umount"](rec.where)
        if not ok then return nil, uerr end
        rec.active, rec.sub = "inactive", "dead"
        return true
    end
    if rec.kind ~= "service" then
        rec.active, rec.sub = "inactive", "dead"
        return true
    end
    if rec.pid then
        rec.stopping = true
        rec.active, rec.sub = "deactivating", "stop"
        rec.stopMs = os.epoch("utc")
        local ok, kerr = syscalls["signal.kill"](rec.pid, 15)
        if not ok then return nil, kerr end
    else
        rec.active, rec.sub = "inactive", "dead"
    end
    return true
end

--- 重启一个单元: 若正在运行则停掉并在退出后重新启动(退出钩子里排定)。
---@return boolean|nil ok, string|nil err
function svc.restart(name)
    local rec, err = svc.get(name)
    if not rec then return nil, err end
    if rec.active == "active" or rec.active == "activating" or rec.active == "deactivating" then
        rec.restartPending = true
        return svc.stop(name)
    end
    return svc.start(name)
end

--- 子进程退出钩子(init 注册到内核 proc.onExit)。不得让出。
---@param pid integer
---@param status string "dead"|"error"
---@param code integer|nil
---@param termSig integer|nil
function svc.onProcessExit(pid, status, code, termSig)
    local rec = byPid[pid]
    if not rec then return end
    byPid[pid] = nil
    rec.pid = nil
    rec.exitCode, rec.termSig = code, termSig

    if rec.stopping or rec.active == "deactivating" then
        rec.stopping = nil
        rec.active, rec.sub = "inactive", "dead"
        if rec.restartPending then
            rec.restartPending = nil
            log("[init] " .. rec.name .. ": restarted")
            scheduleRestart(rec)
        end
        return
    end

    local okExit = (code == 0) and not termSig
    if rec.type == "oneshot" then
        if okExit then
            if rec.remainAfterExit then rec.active, rec.sub = "active", "exited"
            else rec.active, rec.sub = "inactive", "dead" end
        else
            markFailed(rec, "exit code " .. tostring(code) .. (termSig and (" signal " .. termSig) or ""))
        end
    elseif okExit then
        rec.active, rec.sub = "inactive", "dead"
    else
        markFailed(rec, "exit code " .. tostring(code) .. (termSig and (" signal " .. termSig) or ""))
    end

    local should
    if rec.restart == "always" then should = true
    elseif rec.restart == "on-failure" then should = not okExit
    elseif rec.restart == "on-abnormal" then should = termSig ~= nil end
    if should then
        log("[init] " .. rec.name .. ": exited, restarting in " .. rec.restartSec .. "s")
        scheduleRestart(rec)
    end
end

--- 周期驱动: 延迟重启 / timer 到期 / oneshot 与 stop 超时。init 主循环每 100ms 调用。
function svc.tick()
    local now = os.epoch("utc")
    for _, rec in pairs(svc.units) do
        if rec.restartAt and now >= rec.restartAt then
            rec.restartAt = nil
            local ok, err = startOne(rec)
            if not ok then markFailed(rec, err) end
        end
        if rec.kind == "timer" and rec.active == "active" and not rec.firing
            and rec.next and now >= rec.next then
            -- 先把下一次到期时间排好, 再启动 Unit=: svc.start 可能驱动 tick(等待 oneshot),
            -- 若此时 next 仍到期会重复触发同一个 timer(曾导致无限递归)。
            rec.firing = true
            rec.sub = "running"
            if rec.onUnitActiveSec then rec.next = now + rec.onUnitActiveSec * 1000
            else rec.next = nil end
            log("[timer] " .. rec.name .. " -> " .. rec.unit)
            local ok, err = svc.start(rec.unit)
            if not ok then log("[timer] " .. rec.name .. ": " .. tostring(err)) end
            rec.firing = nil
            if rec.onUnitActiveSec then
                rec.sub = "waiting"
            else
                rec.active, rec.sub = "inactive", "elapsed"
            end
        end
        if rec.active == "activating" and rec.startMs and rec.timeoutStartSec
            and now - rec.startMs > rec.timeoutStartSec * 1000 and not rec.restartAt then
            log("[init] " .. rec.name .. ": start timeout, killing pid " .. tostring(rec.pid))
            if rec.pid then syscalls["signal.kill"](rec.pid, 9) end
        end
        if rec.active == "deactivating" and rec.stopMs and now - rec.stopMs > rec.timeoutStopSec * 1000 then
            log("[init] " .. rec.name .. ": stop timeout, SIGKILL pid " .. tostring(rec.pid))
            if rec.pid then syscalls["signal.kill"](rec.pid, 9) end
            rec.stopMs = nil
        end
    end
end

--- 单元状态快照(供 systemctl)。
function svc.snapshot(name)
    local rec = svc.get(name)
    if not rec then return nil end
    return {
        name = rec.name, kind = rec.kind, description = rec.description,
        active = rec.active, sub = rec.sub, pid = rec.pid, path = rec.path,
        exec = rec.exec, exitCode = rec.exitCode, termSig = rec.termSig,
        failReason = rec.failReason, enabled = svc.isEnabled(rec.name),
        next = rec.next, unit = rec.unit, startMs = rec.startMs,
        where = rec.where, what = rec.what, wantedBy = rec.wantedBy,
    }
end

--- 列出全部已装载单元(按名字排序)。
function svc.list()
    local out = {}
    for name in pairs(svc.units) do out[#out + 1] = name end
    table.sort(out)
    local res = {}
    for _, n in ipairs(out) do res[#res + 1] = svc.snapshot(n) end
    return res
end

--- enable 标记路径(systemd 的 <target>.wants/<unit> 空标记文件)。
local function markerPath(unitName, targetName)
    return STATE_DIR .. "/" .. targetName .. ".wants/" .. unitName
end

--- 单元是否 enabled([Install] WantedBy= 目标下存在标记)。
---@param name string
---@return boolean
function svc.isEnabled(name)
    local rec = svc.units[name] or select(1, svc.get(name))
    if not rec then return false end
    for _, target in ipairs(rec.wantedBy) do
        for _, dir in ipairs(UNIT_DIRS) do
            if fs.exists(dir .. "/" .. target .. ".wants/" .. name) then return true end
        end
    end
    return false
end

--- 启用单元(按 [Install] WantedBy= 写标记文件)。
---@return boolean|nil ok, string|nil err
function svc.enable(name)
    local rec, err = svc.get(name)
    if not rec then return nil, err end
    if #rec.wantedBy == 0 then return nil, name .. ": no [Install] WantedBy= (nothing to enable)" end
    for _, target in ipairs(rec.wantedBy) do
        local dir = STATE_DIR .. "/" .. target .. ".wants"
        if not fs.exists(dir) then fs.makeDir(dir) end
        local f = fs.open(markerPath(name, target), "w")
        if not f then return nil, "cannot create " .. markerPath(name, target) end
        f:close()
        svc.addDep(target, name, false)
        log("[init] enabled " .. name .. " -> " .. target)
    end
    return true
end

--- 禁用单元(删除标记文件)。
---@return boolean|nil ok, string|nil err
function svc.disable(name)
    local rec, err = svc.get(name)
    if not rec then return nil, err end
    if #rec.wantedBy == 0 then return nil, name .. ": no [Install] WantedBy= (nothing to disable)" end
    for _, target in ipairs(rec.wantedBy) do
        local p = markerPath(name, target)
        if fs.exists(p) then fs.delete(p) end
        log("[init] disabled " .. name)
    end
    return true
end

return svc
