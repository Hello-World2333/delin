--[[ Delin boot entry.
     1. 打开一个日志文件(写在电脑自身 FS, 便于宿主从 /mnt/computer/N 抓取)
     2. 安装内核受控 print(写入日志 + 终端)
     3. 以源码字符串 spawn 出 PID 1(init)
     4. 进入调度循环 ]]

local scheduler = require("kernel.scheduler")
local process    = require("kernel.process")
local vfs        = require("kernel.vfs")
local vfs_api    = require("kernel.vfs_api")
local INIT_SOURCE = require("kernel.init_src") -- 打包器注入的 init 源码字符串

local log = nil

--- 内核受控 print: 时间戳行写到日志 + 终端。
local function kprint(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    local line = string.format("[%7.3f] %s", os.clock(), table.concat(parts, "\t"))
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

    -- 演示设备: null(丢弃写/返回 EOF读) 与 test(读回写入内容)
    vfs_api.registerDevice("null", {
        open = function()
            local buf = ""
            return {
                read = function() return nil end,
                readLine = function() return nil end,
                readAll = function() return "" end,
                write = function(s) return #s end,
                writeLine = function(s) return #s + 1 end,
                close = function() end,
            }
        end,
    })
    local testBuf = {}
    vfs_api.registerDevice("test", {
        open = function()
            return {
                read = function() return table.concat(testBuf) end,
                write = function(s) testBuf[#testBuf + 1] = s; return #s end,
                close = function() end,
            }
        end,
    })

    -- 终端 stdio(io.write/read 兜底)
    vfs_api.setStdio(
        { read = function(...) return read(...) end },
        { write = function(s) return write(s) end, writeLine = function(s) return write(s .. "\n") end, flush = function() return true end }
    )
end

local boot = {}

function boot.boot()
    -- 打开日志(电脑自身 FS)
    log = fs.open("/delin.log", "w")
    process.log = kprint

    kprint("Delin OS 0.0.1 boot")
    kprint("craftos=" .. os.version())

    local okVfs, errVfs = pcall(setupVfs)
    if not okVfs then
        kprint("FATAL: setupVfs failed: " .. tostring(errVfs))
        return
    end
    kprint("vfs ready; devices=" .. table.concat(vfs_api.devices(), ","))

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
