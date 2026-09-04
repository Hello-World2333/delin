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
local INIT_SOURCE = require("kernel.init_src") -- 打包器注入的 init 源码字符串

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

local boot = {}

function boot.boot()
    -- 打开日志(电脑自身 FS)
    log = fs.open("/delin.log", "w")
    bootMs = os.epoch("utc")
    process.log = kprint

    kprint("Delin OS " .. modules.version .. " boot")
    kprint("craftos=" .. os.version())

    local okVfs, errVfs = pcall(setupVfs)
    if not okVfs then
        kprint("FATAL: setupVfs failed: " .. tostring(errVfs))
        return
    end
    kprint("vfs ready")

    -- 模块系统: 初始化 + 按 manifest 装载(fail-fast)
    modules.log = kprint
    local mdir = findModuleDir()
    if mdir then
        modules.init(mdir)
        local okM, errM = modules.loadAll()
        if not okM then
            kprint("FATAL: module load failed: " .. tostring(errM))
            return
        end
        kprint("modules loaded from " .. mdir)
    else
        kprint("no module dir found (modules skipped)")
    end

    local devNameList = table.concat(vfs_api.devices(), ",")
    local scNameList = {}
    for sn in pairs(modules.syscalls()) do scNameList[#scNameList + 1] = sn end
    kprint("devices=" .. devNameList)
    kprint("syscalls=" .. table.concat(scNameList, ","))

    if not (type(INIT_SOURCE) == "string") then
        kprint("FATAL: init source missing")
        return
    end

    local pid, proc, err = process.spawn(INIT_SOURCE, "init", 0)
    if not pid then
        kprint("FATAL: spawn init failed: " .. tostring(err))
        return
    end
    kprint("spawned init as pid #" .. pid)

    kprint("running scheduler (all processes concurrently) ...")

    scheduler.run()

    kprint("kernel: all processes exited, shutting down")
    if log then log.close(); log = nil end
end

return boot
