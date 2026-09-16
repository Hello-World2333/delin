--[[ Delin kernel scheduler.
     两种调度模式:

       * **协作式**(默认, 与历史行为逐字一致): 进程只在 CC 的 os.pullEvent/os.sleep 上让出;
         一轮调度 = 取一个事件 -> 路由 -> resume 所有"过滤匹配该事件"的进程 -> 再取事件。
         问题(真机实测): 不让出的进程能把整机冻住 ~9.4s(CC 的 watchdog), 而且每个等输入的
         进程都会被每个事件唤醒 —— 空闲时事件泵就吃掉 70~85% 的 CPU。

       * **抢占式**(原型, 默认关, 见 scheduler.setPreempt): 每个进程协程挂一个
         `debug.sethook` 计数钩子, 每 SLICE 条 VM 指令 yield 一次("__preempt"), 调度器据此
         做**时间片轮转**(run queue), 每轮最多跑 BUDGET_MS 就回到事件泵(事件投递与 CC 的
         watchdog 都不会挨饿)。于是"命令霸住整机"不再可能 —— 不管工具里有没有写 yieldCheck。

     内核临界区由 kernel/lock.lua 保护: 钩子在"进程持有内核锁"时不让出(那一段是临界区)。
     本模块只做两件事: ① 把 lock.setCurrent(pid) 挂在每次 resume 前后; ② 让钩子问 lock.inKernel()。

     信号投递: 由 process.lua 经 scheduler.setSignalCheck 注入一个检查函数, 在 resume 前处理
     进程的 pending 信号(dead->移除 / stop->本轮跳过 / run->继续)。抢占模式下每个时间片之前
     都会查一次 —— ^C/kill 的投递延迟因此从"一个事件"降到"一个时间片"。

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
local lock = require("kernel.lock")

-- 宿主测试台是 Lua 5.1(table.pack/unpack 是 5.2 的名字), 真机 Cobalt 是 5.2 —— 两处都要能跑。
local pack = table.pack or function(...) return { n = select("#", ...), ... } end
local unpack = table.unpack or unpack

-- 内核日志是**可选**依赖: 调度器要能被宿主测试台单独装载(见下面 setDiskHook 的说明),
-- 所以 klog 不在就直接不记日志。
local klog = nil
pcall(function() klog = require("kernel.klog") end)

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

--- 事件钩子(random 注入): 每个系统事件(名称/参数/到达间隔)都喂给熵池。
--- 与 diskHook 同样是**注入**而不是 require —— 调度器不依赖任何子系统,
--- 而且这样宿主测试台(没有 CC fs)也能单独装载它。
local eventHook = nil

function scheduler.setEventHook(fn)
    eventHook = fn
end

--- 心跳钩子(内核后台工作的驱动者, 由 md 这类子系统注入): 每次 0.05s 调度心跳调用一次。
--- 钩子跑在调度器自己的上下文里(**不是进程协程**), 所以它**绝不能让出** ——
--- 软RAID 的重建就是靠它每拍搬一小片(见 kernel/md.lua 的 RESYNC_SECTORS)。
local tickHook = nil

function scheduler.setTickHook(fn)
    tickHook = fn
end

-- ---------------------------------------------------------------
-- 抢占式调度(原型)
-- ---------------------------------------------------------------
--- 时间片: 计数钩子的单位。实测(电脑 #3, Cobalt)一次钩子 ≈3.3us。
--- **5000 太密**: 每次让出都是一次调度器往返, fs/输出密集的工具(如没有 yieldCheck 的 find)
--- 会因此慢到跑不完(真机实测: 让人以为提示符卡死)。20000 条指令 ≈ 0.3~0.5ms 纯计算,
--- 仍然远小于"整机停摆"的量级(那要几秒), 却把往返次数降到 1/4。
local SLICE_TICKS = 20000
--- 每轮最多跑多少毫秒 CPU 就回事件泵(保证事件投递与 CC 的 watchdog 都不挨饿)。
local BUDGET_MS = 8

local preempt = false
--- 可运行队列(抢占模式): 等 CPU 的进程按 FIFO 轮转。
---@type DelinProc[]
local ready = {}
--- 我们自己塞进事件队列的 "delin_slice" 是否还有一颗没被 pull 出来。
--- **必须记账**: 不记的话, 只要可运行队列一直非空, 每轮都塞一颗, 塞得比处理得快 ->
--- 队列越积越长, 真实事件(按键!)被埋在后面 —— 实测延迟从 30ms 一路涨到 963ms。
local sliceInFlight = false

--- 时间片钩子(挂在每个进程协程上): 用完一片就把 CPU 还给调度器。
--- **持内核锁时不让出** —— 那一段是不可抢占的临界区(见 kernel/lock.lua 的文件头)。
local function sliceHook()
    if lock.inKernel() then
        -- 核心里不让出(那是临界区), 但**记账**: 出临界区时补一次让出。
        -- 不记账的话, "密集小内核调用"的进程(fs.list/attributes 那种)永远抢不到 —— 见 lock.lua。
        lock.markPreempt()
        return
    end
    coroutine.yield("__preempt")
end

--- 给一个进程协程装/卸时间片钩子(线程形式: 协程还没跑也能装)。
local function setHook(proc, on)
    if not proc.co then return end
    if on then
        pcall(debug.sethook, proc.co, sliceHook, "", SLICE_TICKS)
    else
        pcall(debug.sethook, proc.co) -- 不传钩子 = 卸掉
    end
end

--- 抢占开关(默认关)。开着的时候新老进程都会挂上时间片钩子;
--- 关掉时把钩子卸干净(不留一点开销量)。
---@param on boolean
---@return boolean 打开后的状态
function scheduler.setPreempt(on)
    preempt = on and true or false
    lock.setEnabled(preempt) -- 关掉时锁整个不启用(默认路径零额外开销)
    if klog then
        klog.kern(string.format("[scheduler] setPreempt(%s) lock=%s enabled=%s",
            tostring(on), tostring(lock), tostring(lock.preemptOn())))
    end
    -- **锁的唤醒器必须在这里注册**: 模块加载期写 `lock.setWaker(scheduler.wakePid)` 时
    -- wakePid 还没定义(Lua 的表字段此刻是 nil), 于是注册进去的是 nil —— 等着锁的进程
    -- **永远不会被唤醒**(即使锁已经放了)。真机症状: 两个 tty 同时 `find /` 这种锁竞争一出现,
    -- 某个 shell/login 就永久停在等锁上, 提示符再也不回来、^C/^D 都没反应(信号只在 resume 前
    -- 投递), 而整机与别的 tty 都正常。见 kernel/lock.lua 的 setWaker。
    if preempt then lock.setWaker(scheduler.wakePid) end
    for i = 1, #procs do setHook(procs[i], preempt) end
    if not preempt then ready = {}; sliceInFlight = false end
    return preempt
end

function scheduler.preemptActive()
    return preempt
end

--- 进入可运行队列(同一进程不会重复入队)。
local function makeReady(proc, eventArgs)
    if proc.inReady then return end
    proc.inReady = true
    if eventArgs then proc.pendingEvent = eventArgs end
    ready[#ready + 1] = proc
end

--- 让某个进程重新可运行(内核锁的等待队列唤醒用: 见 kernel/lock.lua)。
---@param pid integer
---@return boolean
function scheduler.wakePid(pid)
    for i = 1, #procs do
        local p = procs[i]
        if p.pid == pid and not p.dead then
            p.state = "wait"
            p.filter = nil
            makeReady(p)
            return true
        end
    end
    return false
end

--- 进程让出后的状态判定(两种模式共用)。
---@param proc DelinProc
---@param param any 协程 yield 出来的值
local function park(proc, param)
    if preempt and param == "__preempt" then
        -- 时间片用完: 还是可运行的, 排到队尾。
        makeReady(proc)
        return
    end
    proc.filter = param
    proc.state = "wait"
end

--- 向调度器注册一个进程协程。
---@param proc DelinProc
function scheduler.addProcess(proc)
    procs[#procs + 1] = proc
    proc.state = "new"
    if preempt then setHook(proc, true) end
end

--- 处理当前事件的键盘/终端路由(在 resume 每个进程前调用)。
--- 确保 ^C/^Z 的信号投递在进程被 resume 前完成。
local function routeEvent(event)
    if event[1] == "char" or event[1] == "paste" then
        tty.feedInput(event)
    elseif event[1] == "key" or event[1] == "key_up" then
        tty.routeKey(event)
    elseif (event[1] == "disk" or event[1] == "disk_eject"
            or event[1] == "peripheral" or event[1] == "peripheral_detach") and diskHook then
        -- 在被该事件唤醒的进程 resume 之前刷新, 保证它看到的 /dev 已是最新。
        -- peripheral/peripheral_detach 也要接: CC 的电缆网络(modem 枢纽)把远端外设挂到本机的
        -- 名字空间是**异步**的, 而内核在引导时已经扫过一次设备 —— 只认 disk 事件的话,
        -- 晚到的那批设备要等到有人插拔磁盘才出现(台式 CEECC 实测: 同一次装机两次冷启动,
        -- 一次在引导时看见 28 个磁盘, 另一次只看见本机那一个)。
        diskHook(event)
    end
end

--- 进程退出/出错时的收尾(两种模式共用)。
---@param proc DelinProc
---@param i integer procs 里的下标
local function reap(proc, i, status, err, result)
    proc.status = status == "error" and "error" or "dead"
    proc.dead = true
    proc.state = "dead"
    lock.forget(proc.pid) -- 带着内核锁死掉的进程: 强制放锁并唤醒等待者(兜底)
    if proc.onExit then proc.onExit(proc, status, err, result) end
    table.remove(procs, i)
end

--- resume 一个进程(信号检查 + 钩子上下文记账 + 状态更新)。
---@param proc DelinProc
---@param i integer procs 下标
---@param eventArgs table
---@param first boolean 首次启动(用空事件启动)
local function resumeProc(proc, i, eventArgs, first)
    local state = "run"
    if signalCheck then state = signalCheck(proc) end
    if state == "dead" then
        reap(proc, i, "dead", nil)
        return "removed"
    elseif state == "stop" then
        proc.state = "stopped"
        return "stopped"
    end

    proc.inReady = false
    local args = eventArgs or proc.pendingEvent
    proc.pendingEvent = nil
    local ok, param
    lock.setCurrent(proc.pid) -- 从这里开始在"这个进程"的上下文里跑内核代码(锁要用)
    if first then
        ok, param = coroutine.resume(proc.co)
    else
        ok, param = coroutine.resume(proc.co, unpack(args or { n = 0 }, 1, (args and args.n) or 0))
    end
    lock.setCurrent(nil)

    if not ok then
        -- 进程出错。**必须写进内核日志**: 父进程(sh)只拿到一个退出码 1,
        -- 工具内部崩了在真机上就完全看不到原因(排查 mkfs.ext2 时被卡住过一次)。
        if klog then
            klog.kern(string.format("process %s (pid %s) died: %s",
                tostring(proc.name), tostring(proc.pid), tostring(param)))
        end
        reap(proc, i, "error", param)
        return "removed"
    elseif coroutine.status(proc.co) == "dead" then
        -- 进程正常结束。协程的返回值即进程退出码(数字时由 onExit 记录)。
        reap(proc, i, "dead", nil, param)
        return "removed"
    else
        park(proc, param)
        return "kept"
    end
end

--- 事件分发(协作模式的"resume"阶段 / 抢占模式的"标可运行"阶段)。
---@param event table
---@param kernelTimer boolean 当前 timer 事件是否属于内核(闪烁/心跳)
local function dispatch(event, kernelTimer)
    -- "delin_slice" 只是"把控制权还回事件泵"的标记(见 run 里自己 queue 的那一段):
    -- 它不是系统事件, 不路由、也不唤醒任何进程(裸让出/等 timer 的进程不该被它叫醒)。
    if event[1] == "delin_slice" then return end
    local i = 1
    while i <= #procs do
        local proc = procs[i]
        local step = true -- 本轮结束后下标是否 +1(进程被回收时不加: 后一个会滑到当前下标)
        local skip = false -- 这一轮不参与正常分发(停止中)
        if proc.state == "stopped" then
            -- 停止的进程先看信号: SIGCONT 到了就要**放回正常分发**(它还是活的, 只是被暂停)。
            -- **曾经的 bug**: 这里只查信号、拿到 "run" 就什么都不做 —— 于是被 SIGCONT 恢复的
            -- 进程永远停在 state="stopped" 上, 再也不会被 resume。真机症状: 交互 shell 被
            -- SIGTTIN 停过一次(比如读 tty 时正好不在前台进程组)之后, 提示符再也不回来,
            -- ^C/^D 都没反应(信号发给了前台组=已经死掉的子进程), 但整机没坏、别的 tty 照常。
            local state = signalCheck and signalCheck(proc) or "run"
            if state == "dead" then
                reap(proc, i, "dead", nil)
                step = false
                skip = true
            elseif state == "stop" then
                skip = true
            else
                proc.state = "wait" -- 已被 SIGCONT 恢复: 走下面的正常分发
            end
        end
        if skip then
            -- 什么都不做(停着的进程不该被事件唤醒)
        elseif not proc.started then
            -- 新进程用空事件启动。
            if preempt then
                makeReady(proc)
            else
                proc.started = true
                if resumeProc(proc, i, nil, true) == "removed" then step = false end
            end
        elseif event[1] == "terminate" then
            -- terminate 事件: 一律唤醒(与历史行为一致)。
            if preempt then
                makeReady(proc, event)
            else
                if resumeProc(proc, i, event, false) == "removed" then step = false end
            end
        elseif proc.filter == nil or proc.filter == event[1] then
            -- 裸让出(filter=nil)匹配任意事件(含心跳); 内核计时器不唤醒等 "timer" 的进程。
            if not kernelTimer then
                if preempt then
                    makeReady(proc, event)
                else
                    if resumeProc(proc, i, event, false) == "removed" then step = false end
                end
            end
        end
        if step then i = i + 1 end
    end
end

--- 可运行队列轮转(抢占模式): 跑到队列空或预算用完。
---@param budgetMs number
---@return boolean 是否还有没跑完的可运行进程
local function runReady(budgetMs)
    local t0 = os.epoch("utc")
    while #ready > 0 do
        if os.epoch("utc") - t0 >= budgetMs then return true end
        local proc = ready[1]
        table.remove(ready, 1)
        proc.inReady = false
        -- 找到它在 procs 里的下标(退出/信号处理要按下标删)。
        local idx = nil
        for j = 1, #procs do if procs[j] == proc then idx = j; break end end
        if idx then
            if proc.started then
                resumeProc(proc, idx, nil, false)
            else
                proc.started = true
                resumeProc(proc, idx, nil, true)
            end
        end
    end
    return false
end

--- 事件循环。直到没有任何存活进程才返回。
function scheduler.run()
    local event = { n = 0 }
    local blinkTimer = os.startTimer(0.5) -- 光标闪烁节拍
    -- 调度心跳: 裸让出(filter=nil, 如 tty.readLine 里的 os.pullEvent())的进程只在事件到来
    -- 时才会被恢复; 空闲期没有键盘/定时器事件, 必须靠心跳推进, 否则会永久挂起。
    -- 20Hz 对事件队列(上限 256)压力可忽略 —— 与旧 hse_tick 2kHz 推模式完全不是一回事。
    local beatTimer = os.startTimer(0.05)
    local kernelTimer = false -- 当前 timer 事件是否属于内核(闪烁/心跳)
    while #procs > 0 do
        kernelTimer = false

        -- 0) 键盘路由: 在 resume 进程前, 先把当前事件路由给 tty。
        --    这确保 ^C 的 SIGINT 在进程被 resume 前已投递到前台进程组。
        if event[1] == "timer" then
            if event[2] == blinkTimer then
                tty.blinkTick()
                blinkTimer = os.startTimer(0.5)
                kernelTimer = true
            elseif event[2] == beatTimer then
                beatTimer = os.startTimer(0.05)
                kernelTimer = true
                if tickHook then tickHook() end
            end
        end
        routeEvent(event)

        -- 1) 分发事件(协作式: 直接 resume; 抢占式: 只标可运行)
        dispatch(event, kernelTimer)

        -- 2) 抢占式: 跑可运行队列, 预算用完就让出(但要保证事件泵还能被 pull 到)
        local more = false
        if preempt then more = runReady(BUDGET_MS) end

        if #procs > 0 then
            if more and not sliceInFlight then
                -- 队列里还有人, 但这一轮的预算用完了: **自己塞一个事件**再 pull ——
                -- pull 立刻返回(FIFO 里排在真实的键盘/定时器事件之后), 于是既让出了主机
                -- (CC 的 watchdog 计数归零), 又不会去等一个游戏刻(50ms)而白白饿着可运行的进程。
                -- 同时最多只留一颗在队里(见 sliceInFlight): 多塞就变成"自己淹自己"。
                sliceInFlight = true
                os.queueEvent("delin_slice")
            end
            event = pack(os.pullEventRaw())
            if event[1] == "delin_slice" then sliceInFlight = false end
            -- 随机数熵源: 每一个系统事件都掺进内核熵池(见 kernel/random.lua)。
            -- 放在这里而不是 routeEvent 里 —— 这是**唯一的事件入口**, 每个事件恰好掺一次,
            -- 与"哪些进程在等什么事件"无关。
            if eventHook and event[1] ~= "delin_slice" then eventHook(event) end
        end
    end
end

return scheduler
