--[[ Delin kernel scheduler.
     Owns the os.pullEventRaw loop and drives every process coroutine.
     Processes yield via CC's raw API (os.sleep, os.pullEvent, ...); the
     scheduler resumes a process when the event it is filtering for arrives.

     信号投递: 由 process.lua 经 scheduler.setSignalCheck 注入一个检查函数,
     在 resume 前处理进程的 pending 信号(dead->移除 / stop->本轮跳过 / run->继续)。 ]]

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

--- 向调度器注册一个进程协程。
---@param proc DelinProc
function scheduler.addProcess(proc)
    procs[#procs + 1] = proc
end

--- 事件循环。直到没有任何存活进程才返回。
function scheduler.run()
    local event = { n = 0 }
    local blinkTimer = os.startTimer(0.5) -- 光标闪烁节拍
    while #procs > 0 do
        local i = 1
        while i <= #procs do
            local proc = procs[i]

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
                local shouldRun = (not proc.started)
                    or proc.filter == nil
                    or proc.filter == event[1]
                    or event[1] == "terminate"

                -- msleep 计数器: hse_tick 到来时, 若 __msleep_remaining > 0 则递减, 不 resume。
                if shouldRun and proc.filter == "hse_tick" and event[1] == "hse_tick" then
                    local rem = rawget(proc.co_env, "__msleep_remaining")
                    if rem and rem > 0 then
                        rawset(proc.co_env, "__msleep_remaining", rem - 1)
                        shouldRun = false
                    end
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
            -- 内核光标闪烁计时器: 翻转光标并继续, 不外发给进程(避免唤醒 os.sleep 等)。
            if event[1] == "timer" and event[2] == blinkTimer then
                tty.blinkTick()
                blinkTimer = os.startTimer(0.5)
                event = { n = 0 }
            end
            -- 键盘事件路由给前台 tty(canonical 行规程: 缓冲+回显)。
            -- key/key_up 走 routeKey(跟踪修饰键 + Ctrl+Alt+数字切换前台 tty + ^C/^D/^Z)。
            if event[1] == "char" or event[1] == "paste" then
                tty.feedInput(event)
            elseif event[1] == "key" or event[1] == "key_up" then
                tty.routeKey(event)
            end
        end
    end
end

return scheduler
