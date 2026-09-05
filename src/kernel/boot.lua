--[[ Delin boot entry.
     1. 打开一个日志文件(写在电脑自身 FS, 便于宿主从 /mnt/computer/N 抓取)
     2. 安装内核受控 print(写入日志 + 终端)
     3. 以源码字符串 spawn 出 PID 1(init)
     4. 进入调度循环 ]]

local scheduler = require("kernel.scheduler")
local process    = require("kernel.process")
local vfs        = require("kernel.vfs")
local vfs_api    = require("kernel.vfs_api")
local modules    = require("kernel.modules")
local ext2       = require("kernel.ext2")
local tty        = require("kernel.tty")
local fb         = require("kernel.fb")
local INIT_SOURCE = require("kernel.init_src") -- 打包器注入的 init 源码字符串
local EXT2_INIT_SOURCE = require("kernel.ext2_init_src") -- EXT2 根引导用最小 PID1

local log = nil
local bootMs = nil

--- 内核受控 print: 时间戳(自引导起的毫秒)写到日志 + 终端。
local function kprint(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    local now = os.epoch("utc")
    local el = (bootMs and (now - bootMs)) or 0
    local line = string.format("[%8.3f] %s", el / 1000, table.concat(parts, "\t"))
    -- CC 的 fs 文件句柄方法用点号(非冒号), 否则会写成 tostring(handle)
    if log then log.writeLine(line); log.flush() end
    print(line) -- 也输出到终端(view 可见)
end

--- 挂载: 根 hdd + 各磁盘驱动 + /dev(+占位 /proc)。
local function setupVfs()
    -- 根 = 电脑 hdd(真实路径即 "/...")
    vfs.mount("/", vfs.real(""))
    -- 磁盘驱动: 挂到 /mnt/<side>(真实路径 = disk.getMountPath(side))
    for _, name in ipairs(peripheral.getNames()) do
        if disk.hasData(name) then
            local mp = disk.getMountPath(name)
            if mp then
                vfs.mount("/mnt/" .. name, vfs.real(mp))
                kprint("mount  /mnt/" .. name .. " <-> " .. mp)
            end
        end
    end
    vfs_api.mountDev()

    -- 终端 stdio(io.write/read 兜底)
    vfs_api.setStdio(
        { read = function(...) return read(...) end },
        { write = function(s) return write(s) end, writeLine = function(s) return write(s .. "\n") end, flush = function() return true end }
    )
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

--- 在磁盘上找带 /parts/manifest 的(引导盘)。返回真实 fs 路径。
-- (DLUB 独立文件自己扫描; 内核不再需要)

local function launch(initSrc, label)
    if type(initSrc) ~= "string" then kprint("FATAL: " .. label .. " init source missing"); return end
    local pid, proc, err = process.spawn(initSrc, "init", 0)
    if not pid then kprint("FATAL: spawn " .. label .. " init failed: " .. tostring(err)); return end
    kprint("spawned " .. label .. " init as pid #" .. pid)
    kprint("running scheduler (all processes concurrently) ...")
    scheduler.run()
    kprint("kernel: all processes exited, shutting down")
    if log then log.close(); log = nil end
end

--- 显示设备 syscalls(供进程枚举 /dev/ttyN、/dev/fbN; 写入走设备文件)。
--- 遵循 Linux: 进程面向 tty/fb 字符设备文件, 不设 display.* 写接口。
local function registerDisplaySyscalls()
    local sc = modules.syscalls()
    sc["tty.list"] = function() return tty.list() end
    sc["fb.list"]  = function() return fb.list() end
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

--- EXT2 根引导: 挂根分区为 "/", 再跑最小 PID1。
local function bootExt2(bi)
    kprint("EXT2 boot: root=" .. (bi.rootFstype or "?") .. " " .. (bi.rootPath or "?"))
    local rfs, ferr = ext2.mount(bi.blockDevice)
    if not rfs then kprint("FATAL: root ext2 mount: " .. tostring(ferr)); return end
    vfs.mount("/", ext2.backend(rfs)) -- 根 = ext2 分区
    vfs_api.mountDev()
    vfs_api.setStdio(
        { read = function(...) return read(...) end },
        { write = function(s) return write(s) end, writeLine = function(s) return write(s .. "\n") end, flush = function() return true end }
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
    launch(EXT2_INIT_SOURCE, "ext2")
end

local boot = {}

function boot.boot()
    -- 打开日志(电脑自身 FS, 追加以便 DLUB 引导的两段都记录)
    log = fs.open("/delin.log", "a")
    bootMs = os.epoch("utc")
    process.log = kprint

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
    launch(INIT_SOURCE, "")
end

return boot
