--[[ Delin boot entry.
     1. 打开一个日志文件(写在电脑自身 FS, 便于宿主从 /mnt/computer/N 抓取)
     2. 安装内核受控 print(写入日志 + 终端)
     3. 以源码字符串 spawn 出 PID 1(init)
     4. 进入调度循环 ]]

local scheduler = require("kernel.scheduler")
local process    = require("kernel.process")
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

local boot = {}

function boot.boot()
    -- 打开日志(电脑自身 FS)
    log = fs.open("/delin.log", "w")
    process.log = kprint

    kprint("Delin OS 0.0.1 boot")
    kprint("craftos=" .. os.version())

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
