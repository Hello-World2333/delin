--[[ Delin boot entry.
     1. 打开引导日志文件(写在电脑自身 FS, 便于宿主从 /mnt/computer/N 抓取)
     2. 安装内核受控 print(进 klog ring buffer + 引导日志 + 终端)
     3. 挂载/枚举设备/注册控制台, 装载模块
     4. 以源码字符串 spawn 出 PID 1(init, 用户态服务管理器)
     5. 进入调度循环

     日志: 内核消息走 klog(kern facility) -> /dev/kmsg -> syslogd -> /var/log/*;
           进程 print 走 user facility。引导日志 /delin.log 是内核自己的早期落盘副本,
           在 syslogd 起来之前/起不来时仍能排障(CC 无法读屏)。 ]]

local scheduler = require("kernel.scheduler")
local process    = require("kernel.process")
local vfs        = require("kernel.vfs")
local vfs_api    = require("kernel.vfs_api")
local devdisk    = require("kernel.devdisk")
local modules    = require("kernel.modules")
local ext2       = require("kernel.ext2")
local tty        = require("kernel.tty")
local fb         = require("kernel.fb")
local display    = require("kernel.display")
local sysfs      = require("kernel.sysfs")
local procfs     = require("kernel.procfs")
local pipe       = require("kernel.pipe")
local klog       = require("kernel.klog")
local fstab      = require("kernel.fstab")
local INIT_SOURCE = require("kernel.init_src") -- 打包器注入的 init 源码字符串

local bootLog = nil
local bootMs = nil

local PRI_KERN = klog.makePri(klog.FACILITIES.kern, klog.SEVERITIES.info)
local PRI_USER = klog.makePri(klog.FACILITIES.user, klog.SEVERITIES.info)

--- 内核受控 print: 时间戳(自引导起的毫秒)进 klog + 引导日志 + 终端。
local function emit(pri, ...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    local now = os.epoch("utc")
    local el = (bootMs and (now - bootMs)) or 0
    local line = string.format("[%8.3f] %s", el / 1000, table.concat(parts, "\t"))
    klog.write(pri, line)
    -- CC 的 fs 文件句柄方法用点号(非冒号), 否则会写成 tostring(handle)
    if bootLog then bootLog.writeLine(line); bootLog.flush() end
    write(line .. "\n") -- 也输出到终端(view 可见)
end

--- 内核消息(facility=kern)。
local function kprint(...) return emit(PRI_KERN, ...) end
--- 进程 print(facility=user)。Delin 的内核 print 是控制台, 不是进程 stdout。
local function userprint(...) return emit(PRI_USER, ...) end

--- 挂载: 根 hdd + /dev + /proc(procfs)。磁盘驱动器不自动挂载 —— 只作为 /dev/sdX 设备节点
--- 暴露(见 setupDevices), 由 fstab/mount 显式挂载。
local function setupVfs()
    -- 根 = 电脑 hdd(真实路径即 "/...")
    vfs.mount("/", vfs.real(""), { device = "rootfs", fstype = "ccdisk" })
    vfs_api.mountDev()
    klog.register() -- /dev/kmsg + /dev/log
    procfs.mount(bootMs, modules.version) -- /proc: 进程/系统信息

    -- 终端 stdio(io.write/read 兜底)。用冒号调用(io.write 经 stdio.output:write)。
    vfs_api.setStdio(
        { read = function(self, ...) return read(...) end },
        { write = function(self, s) return write(s) end, writeLine = function(self, s) return write(s .. "\n") end, flush = function(self) return true end }
    )
end

--- 磁盘设备: 扫描所有磁盘驱动器, 把整盘/分区注册成 /dev/sdX 节点, 并挂上热插拔刷新钩子。
local function setupDevices()
    local list = devdisk.refresh()
    local names = {}
    for _, e in ipairs(list) do
        names[#names + 1] = e.name .. "(" .. e.fstype .. (e.uuid and (",uuid=" .. e.uuid) or "") .. ")"
    end
    kprint("block devices: " .. (#names > 0 and table.concat(names, " ") or "(none)"))
    scheduler.setDiskHook(function() devdisk.refresh() end)
end

--- 在磁盘上找模块目录: /lib/modules/<version>/ (真实 fs 路径)。
local function findModuleDir()
    local v = modules.version
    for _, name in ipairs(peripheral.getNames()) do
        if disk.hasData(name) then
            local mp = disk.getMountPath(name)
            if mp and fs.exists(mp .. "/lib/modules/" .. v .. "/manifest") then
                return mp .. "/lib/modules/" .. v
            end
        end
    end
    return nil
end

local function launch(initSrc, label)
    if type(initSrc) ~= "string" then kprint("FATAL: " .. label .. " init source missing"); return end
    local pid, proc, err = process.spawn(initSrc, "init", 0)
    if not pid then kprint("FATAL: spawn " .. label .. " init failed: " .. tostring(err)); return end
    kprint("spawned " .. label .. " init as pid #" .. pid)
    kprint("running scheduler (all processes concurrently) ...")
    scheduler.run()
    kprint("kernel: all processes exited, shutting down")
    if bootLog then bootLog.close(); bootLog = nil end
end

--- 显示设备 syscalls(供进程枚举 /dev/ttyN、/dev/fbN; 写入走设备文件)。
--- 遵循 Linux: 进程面向 tty/fb 字符设备文件, 不设 display.* 写接口。
local function registerDisplaySyscalls()
    local sc = modules.syscalls()
    sc["tty.list"] = function() return tty.list() end
    sc["fb.list"]  = function() return fb.list() end
end

--- 运行时 syscalls(给 shell / 工具用): 等待子进程、注入 stdio、前台 tty 控制。
local function registerRuntimeSyscalls()
    local sc = modules.syscalls()
    sc["proc.wait"] = function(pid)
        -- 阻塞等待一个子进程退出(轮询; 进程自身 yield, 调度器驱动)。
        while true do
            local p = process.info(pid)
            if not p then return -1 end
            if p.status == "dead" or p.status == "error" then
                if p.termSig then return -p.termSig end
                return p.exitCode or 0
            end
            if os.sleep then os.sleep(0.05) end
        end
    end
    sc["proc.info"] = function(pid) return process.info(pid) end
    -- 子进程退出钩子(init 服务监督用; 回调在调度器上下文同步调用, 不得让出)。
    sc["proc.onExit"] = function(fn) process.setExitHook(fn) end
    -- execve 语义: 按路径装载可执行文件(处理 shebang)并 spawn。init 的 ExecStart 用它。
    sc["proc.spawnFile"] = function(path, argv, opts)
        local fsapi = vfs_api.fs
        if not fsapi.exists(path) then return nil, path .. ": no such file" end
        if not fsapi.canExecute(path) then return nil, path .. ": permission denied" end
        local f, oerr = fsapi.open(path, "r")
        if not f then return nil, path .. ": " .. tostring(oerr) end
        local src = f.readAll()
        f.close()
        local outArgv = {}
        local shebang = src:match("^#!([^\n]*)")
        local progName = path
        if shebang then
            local interp, rest = shebang:match("^%s*(%S+)%s*(.-)%s*$")
            if not interp then return nil, path .. ": empty shebang" end
            if interp:match("[^/]+$") == "env" then
                local prog = rest:match("^(%S+)")
                if not prog then return nil, path .. ": shebang env without program" end
                rest = rest:sub(#prog + 1)
                interp = prog
            end
            if not fsapi.exists(interp) then return nil, path .. ": shebang interpreter not found: " .. interp end
            if not fsapi.canExecute(interp) then return nil, path .. ": shebang interpreter not executable: " .. interp end
            local hf = fsapi.open(interp, "r")
            if not hf then return nil, interp .. ": permission denied" end
            src = hf.readAll()
            hf.close()
            outArgv[0] = interp
            local n = 1
            for w in rest:gmatch("%S+") do outArgv[n] = w; n = n + 1 end
            outArgv[n] = path; n = n + 1
            for i = 1, #argv do outArgv[n] = argv[i]; n = n + 1 end
            progName = interp
        else
            outArgv[0] = path
            for i = 1, #argv do outArgv[i] = argv[i] end
        end
        local caller = process.current()
        return process.spawn(src, progName, caller.pid, nil, nil, outArgv, opts)
    end
    sc["pipe.create"] = function() return pipe.create() end
    sc["stdio.set"] = function(input, output) return process.setStdio(input, output) end
    sc["tty.setFocus"] = function(name) return tty.setFocus(name) end
    sc["tty.console"] = function() return tty.getFocus() end
    -- 挂载/卸载: device 可为 /dev/sdX(整盘 ccdisk / manifest 分区 ext2)、/dev/ccdiskN、
    --   UUID=<uuid>(UUID 由磁盘 ID 模拟: 整盘 <id>, 分区 <id>-<n>), 或真实后端上的镜像路径(旧式)。
    --   fs.umount(dir): 卸载并关闭块设备; fs.mounts(): 列出当前挂载(含 uuid)。
    sc["fs.mount"] = function(device, dir, fstype) return devdisk.mount(device, dir, fstype) end
    sc["fs.umount"] = function(dir) return devdisk.umount(dir) end
    sc["fs.mounts"] = function()
        local out = {}
        for _, m in ipairs(vfs.list()) do
            out[#out + 1] = {
                root = m.root,
                device = m.meta and m.meta.device,
                fstype = m.meta and m.meta.fstype,
                uuid = m.meta and m.meta.uuid,
                ro = m.backend.isReadOnly("") and true or false,
            }
        end
        return out
    end
    sc["fs.fstypes"] = function() return devdisk.fstypes() end
    sc["blkdev.list"] = function() return devdisk.list() end
    -- /etc/fstab: 解析结果给 init(生成 mount 单元)与 mount -a。
    sc["fstab.entries"] = function(path) return fstab.read(vfs_api.fs, path) end
    klog.registerSyscalls(sc)
    -- 终端信号路由: ^C(SIGINT)/^Z(SIGTSTP) 发给 tty 前台进程组。
    tty.onSignal = function(sig)
        local fg = process.tcgetpgrp(tty.getFocus())
        if fg then process.signalGroup(fg, sig) end
    end
end

--- 注册电脑自身 term 作为 /dev/ttyN 控制台(console), 并派生 /dev/console 别名(Linux 语义)。
local function registerConsole()
    pcall(term.setCursorBlink, false) -- 光标由 tty 层自己反显, 关掉 CC 原生闪烁避免双光标
    local function hex(c) return string.format("%x", c) end
    local cons = {
        id = "console",
        type = "console",
        mode = "term",
        name = "term",
        device = term,
        getSize = function() return term.getSize() end,
        text = function(x, y, s, fg, bg)
            term.setCursorPos(x + 1, y + 1)
            if fg and bg then
                local n = #s
                term.blit(s, string.rep(hex(fg), n), string.rep(hex(bg), n))
            else
                term.write(s)
            end
        end,
        blit = function(x, y, text, fg, bg)
            term.setCursorPos(x + 1, y + 1)
            local n = #text
            term.blit(text, string.rep(hex(fg or 0), n), string.rep(hex(bg or 0), n))
        end,
        fill = function(color)
            term.setBackgroundColor(color or 0)
            term.clear()
        end,
        flush = function() end,
        release = function() end,
    }
    display.register(cons)
    local ttyName = tty.getFocus()
    -- /dev/console = 系统控制台(同 /dev/ttyN 中第一个注册的 tty)。
    vfs_api.registerDevice("console", {
        writable = true,
        open = function(mode) return tty.open(ttyName, mode) end,
    })
    kprint("console tty registered -> " .. ttyName .. " (/dev/console alias)")
end

--- 装载内核模块: init(目录) -> loadAll -> loadAliases -> 按外设 autoload 驱动。
--- @param reader table|nil 读模块文件的 fs 门面(默认真实 fs; EXT2 根引导传 vfs_api.fs)
--- @param dir string 模块目录(reader 为真 fs 时是真实路径, 为 vfs 时是 VFS 路径)
--- @return boolean, string|nil
local function setupModules(reader, dir)
    modules.log = kprint
    if reader then modules.fs = reader end
    modules.init(dir)
    local okM, errM = modules.loadAll()
    if not okM then return nil, errM end
    kprint("modules loaded from " .. dir)

    -- 别名 + 按外设自动加载驱动模块 (modprobe 风格, modules.use)
    local okA, errA = modules.loadAliases()
    if okA then
        for _, name in ipairs(peripheral.getNames()) do
            local typ = peripheral.getType(name)
            if typ then
                local okU, errU = modules.use(typ, name)
                if not okU and errU and errU:find("no module for alias") then
                    -- 无别名, 忽略(普通外设)
                elseif not okU then
                    kprint("autoload " .. typ .. ": " .. tostring(errU))
                end
            end
        end
    elseif errA and errA:find("no modules.alias") then
        kprint("no modules.alias (drivers not auto-loaded)")
    end
    return true
end

--- EXT2 根引导: 挂根分区为 "/", 再跑 init。
local function bootExt2(bi)
    kprint("EXT2 boot: root=" .. (bi.rootFstype or "?") .. " " .. (bi.rootPath or "?"))
    local rfs, ferr = ext2.mount(bi.blockDevice)
    if not rfs then kprint("FATAL: root ext2 mount: " .. tostring(ferr)); return end
    vfs_api.mountDev()
    klog.register()
    procfs.mount(bootMs, modules.version) -- /proc: 进程/系统信息
    registerConsole() -- 电脑自身 term 控制台(键盘输入焦点)
    setupDevices()    -- /dev/sdX 设备节点(磁盘不自动挂载)
    -- 根分区对上设备节点, 使 mount/lsblk 里根挂载显示为 /dev/sdXN 而不是 "rootfs"。
    local rootDev
    for _, e in ipairs(devdisk.list()) do
        if e.type == "part" and e.img == bi.blockDevice.path then rootDev = e; break end
    end
    if not rootDev then
        -- 从电脑自带存储启动时, 根分区可能没有对应的 /dev 节点
        -- 使用虚拟设备节点
        kprint("ext2 boot: no /dev node for root partition, using virtual device")
        local device = bi.rootPath or "rootfs"
        local uuid = nil
        vfs.mount("/", ext2.backend(rfs), { device = device, fstype = "ext2", uuid = uuid })
    else
        vfs.mount("/", ext2.backend(rfs), { device = rootDev.node, fstype = rootDev.fstype, uuid = rootDev.uuid })
    end
    vfs_api.setStdio(
        { read = function(self, ...) return read(...) end },
        { write = function(self, s) return write(s) end, writeLine = function(self, s) return write(s .. "\n") end, flush = function(self) return true end }
    )
    -- 用户库(从 EXT2 根 /etc/passwd 读) + 注册 user.* syscalls
    local user = require("kernel.user")
    local db = user.init(vfs_api.fs)
    user.registerSyscalls(db)
    kprint("users loaded: " .. table.concat(user.list(db), ","))

    -- 内核模块: 只从 ext2 根镜像自带的 /lib/modules/<version>/ 装载(自包含, fail-fast)。
    -- 绝不回退到引导盘/CC fs 的 /lib —— 那上面本就不该有模块。
    local mdir = "/lib/modules/" .. modules.version
    if not vfs_api.fs.exists(mdir .. "/manifest") then
        kprint("FATAL: ext2 root has no module dir " .. mdir)
        return
    end
    -- 关闭任意别处回退: 显式以 vfs(fs) 作为读模块文件的门面, 只读 ext2 根。
    local okMod, errMod = setupModules(vfs_api.fs, mdir)
    if not okMod then
        kprint("FATAL: module load failed: " .. tostring(errMod))
        return
    end

    registerDisplaySyscalls()
    registerRuntimeSyscalls()
    sysfs.mount() -- /sys/class/display 虚拟配置 fs(display 已注册)
    launch(INIT_SOURCE, "ext2")
end

local boot = {}

function boot.boot()
    -- 打开引导日志(电脑自身 FS, 追加以便 DLUB 引导的两段都记录)
    bootLog = fs.open("/delin.log", "a")
    bootMs = os.epoch("utc")
    process.log = userprint

    kprint("Delin OS " .. modules.version .. " boot")
    kprint("craftos=" .. os.version())

    -- 1) 已被 DLUB 设置了 bootInfo -> EXT2 根引导
    if __boot_info then
        return bootExt2(__boot_info)
    end

    -- 2) 默认 CC-fs 引导
    local okVfs, errVfs = pcall(setupVfs)
    if not okVfs then
        kprint("FATAL: setupVfs failed: " .. tostring(errVfs))
        return
    end
    kprint("vfs ready")
    setupDevices()    -- /dev/sdX 设备节点(磁盘不自动挂载)
    registerConsole() -- 电脑自身 term 控制台(键盘输入焦点)

    local mdir = findModuleDir()
    if mdir then
        local okM, errM = setupModules(nil, mdir)
        if not okM then
            kprint("FATAL: module load failed: " .. tostring(errM))
            return
        end
    else
        kprint("no module dir found (modules skipped)")
    end

    local devNameList = table.concat(vfs_api.devices(), ",")
    local scNameList = {}
    for sn in pairs(modules.syscalls()) do scNameList[#scNameList + 1] = sn end
    kprint("devices=" .. devNameList)
    kprint("syscalls=" .. table.concat(scNameList, ","))

    registerDisplaySyscalls()
    registerRuntimeSyscalls()
    sysfs.mount() -- /sys/class/display 虚拟配置 fs(display 已注册)
    launch(INIT_SOURCE, "")
end

return boot
