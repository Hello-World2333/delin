--[[ Delin kernel scheduler.
     Owns the os.pullEventRaw loop and drives every process coroutine.
     Processes yield via CC's raw API (os.sleep, os.pullEvent, ...); the
     scheduler resumes a process when the event it is filtering for arrives.

     信号投递: 由 process.lua 经 scheduler.setSignalCheck 注入一个检查函数,
     在 resume 前处理进程的 pending 信号(dead->移除 / stop->本轮跳过 / run->继续)。

     键盘路由: 在 resume 每个进程之前, 先把当前事件路由给 tty(^C/^Z 信号投递),
     确保 SIGINT/SIGTSTP 在进程被 resume 前已进入 pending 队列。 ]]

---@class DelinProc
---@field pid integer
---@field co thread
---@field name string
---@field started boolean
---@field filter string|nil -- 该进程当前正在等待的事件类型(yield 返回值)
---@field dead boolean
---@field status string      -- running|dead|error
---@field error any
---@field onExit fun(self:DelinProc, status:string, err:any)|nil

local tty = require("kernel.tty")

local scheduler = {}

---@type DelinProc[]
local procs = {}

--- 信号检查函数(process.lua 注入): (proc) -> "run"|"stop"|"dead"。
local signalCheck = nil

function scheduler.setSignalCheck(fn)
    signalCheck = fn
end

--- 磁盘事件钩子(devdisk 注入): 盘插入/弹出时刷新 /dev 设备节点。
local diskHook = nil

function scheduler.setDiskHook(fn)
    diskHook = fn
end

--- 向调度器注册一个进程协程。
---@param proc DelinProc
function scheduler.addProcess(proc)
    procs[#procs + 1] = proc
end

--- 处理当前事件的键盘/终端路由(在 resume 每个进程前调用)。
--- 确保 ^C/^Z 的信号投递在进程被 resume 前完成。
local function routeEvent(event)
    if event[1] == "char" or event[1] == "paste" then
        tty.feedInput(event)
    elseif event[1] == "key" or event[1] == "key_up" then
        tty.routeKey(event)
    elseif (event[1] == "disk" or event[1] == "disk_eject") and diskHook then
        -- 在被该事件唤醒的进程 resume 之前刷新, 保证它看到的 /dev 已是最新。
        diskHook(event)
    end
end

--- 事件循环。直到没有任何存活进程才返回。
function scheduler.run()
    local event = { n = 0 }
    local blinkTimer = os.startTimer(0.5) -- 光标闪烁节拍
    -- 调度心跳: 裸让出(filter=nil, 如 tty.readLine 里的 os.pullEvent())的进程只在事件到来
    -- 时才会被恢复; 空闲期没有键盘/定时器事件, 必须靠心跳推进, 否则会永久挂起。
    -- 20Hz 对事件队列(上限 256)压力可忽略 —— 与旧 hse_tick 2kHz 推模式完全不是一回事。
    local beatTimer = os.startTimer(0.05)
    local routed = false -- 当前事件是否已路由过键盘(避免重复路由)
    local kernelTimer = false -- 当前 timer 事件是否属于内核(闪烁/心跳)
    while #procs > 0 do
        local i = 1
        routed = false
        kernelTimer = false
        while i <= #procs do
            local proc = procs[i]

            -- 0) 键盘路由: 在 resume 每个进程前, 先把当前事件路由给 tty。
            --    这确保 ^C 的 SIGINT 在进程被 resume 前已投递到前台进程组。
            if not routed then
                routed = true
                -- 内核自己的计时器: 翻转光标 / 心跳续期。两者都不投给等待 "timer" 的进程
                -- (那是进程自己 os.startTimer 的事件), 但裸让出进程照常被心跳唤醒。
                if event[1] == "timer" then
                    if event[2] == blinkTimer then
                        tty.blinkTick()
                        blinkTimer = os.startTimer(0.5)
                        kernelTimer = true
                    elseif event[2] == beatTimer then
                        beatTimer = os.startTimer(0.05)
                        kernelTimer = true
                    end
                end
                routeEvent(event)
            end

            -- 1) 投递信号: dead -> 移除; stop -> 暂停(本轮不 resume); run -> 继续。
            local state = "run"
            if signalCheck then state = signalCheck(proc) end
            if state == "dead" then
                proc.status = "dead"; proc.dead = true
                if proc.onExit then proc.onExit(proc, "dead", nil) end
                table.remove(procs, i)
            elseif state == "stop" then
                i = i + 1
            else
                -- 2) 新进程用空事件启动；已启动进程仅在 filter 匹配(或 terminate)时恢复。
                --    裸让出(filter=nil)匹配任意事件(含心跳); 内核计时器不唤醒等 "timer" 的进程。
                local shouldRun
                if not proc.started or event[1] == "terminate" then
                    shouldRun = true
                elseif proc.filter == nil then
                    shouldRun = true
                elseif proc.filter == event[1] then
                    shouldRun = not kernelTimer
                else
                    shouldRun = false
                end

                if shouldRun then
                    local ok, param
                    if not proc.started then
                        proc.started = true
                        ok, param = coroutine.resume(proc.co)
                    else
                        ok, param = coroutine.resume(proc.co, table.unpack(event, 1, event.n))
                    end

                    if not ok then
                        -- 进程出错。
                        proc.status = "error"; proc.error = param; proc.dead = true
                        if proc.onExit then proc.onExit(proc, "error", param) end
                        table.remove(procs, i)
                    elseif coroutine.status(proc.co) == "dead" then
                        -- 进程正常结束。
                        proc.status = "dead"; proc.dead = true
                        if proc.onExit then proc.onExit(proc, "dead", nil) end
                        table.remove(procs, i)
                    else
                        -- 进程让出：param 即其 filter。
                        proc.filter = param
                        i = i + 1
                    end
                else
                    i = i + 1
                end
            end
        end

        if #procs > 0 then
            event = table.pack(os.pullEventRaw())
        end
    end
end

return scheduler
