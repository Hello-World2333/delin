--[[ 内核自己的 `os.sleep`: **绝不只等一个唤醒源**。

     CC 的 sleep(bios.lua 的 `sleep` / `os.sleep`)是这样实现的:
         local timer = os.startTimer(t)
         repeat local _, param = os.pullEvent("timer") until param == timer
     它只认**自己那个一次性定时器**的事件 —— 那个事件只要被丢一次, 进程就**永远**出不来。
     真机症状(用户三次复现, 电脑 #3 tty0): 交互 shell 跑完一条命令后提示符再也不回来,
     ^C/^D 没反应, 整机正常、别的 tty 照常, 日志里那个进程一直 `y=timer`, 栈上是
     `F.pollWait -> msleep -> os.sleep -> pullEvent` —— 它卡住的不是"被饿着", 而是
     **等一个永远不会再来的事件**(抢占模式下的事件分发出过丢事件的问题, 见 scheduler.deliver)。

     所以这里把它换成:**裸让出**(任何事件都唤醒) + **自己的墙钟兜底**。定时器事件丢了也不要紧 ——
     调度心跳(20Hz)会把我们叫醒, 到点就返回。代价是睡前多醒几次(与 tty 读、cc_hse 的 hseWait
     同款取舍: "绝不只等一个唤醒源"是那里先总结出来的教训)。

     顺带: 走兜底返回说明**确实丢了定时器事件**, 记一笔(klog + 计数器), 下次复现就有硬证据。
]]

local klog = require("kernel.klog")

local M = {}

--- 走墙钟兜底醒来的次数(= 丢失的定时器事件次数)。
local lost = 0
function M.lostCount() return lost end

--- 装上这个 os.sleep。**必须在模块装载之前调用**: kernel module `cc_hse` 在装载期就抓走了
--- `os.sleep` 的引用(`local realSleep = os.sleep`), 而它的 `os.msleep` 就是我们这里要保护的那条路。
function M.install()
    local realStartTimer, realPull, realEpoch = os.startTimer, os.pullEventRaw, os.epoch

    --- 睡够 sec 秒; **sec <= 0 也要让出一次**(CC 语义: sleep(0) = 让出点, 不少工具靠它)。
    ---@param sec number
    local function sleep(sec)
        sec = math.max(tonumber(sec) or 0, 0)
        local deadline = realEpoch("utc") + sec * 1000
        repeat
            local left = deadline - realEpoch("utc")
            local tid = realStartTimer(math.max(left, 0) / 1000)
            local got = false
            repeat
                local name, id = realPull()
                if name == "terminate" then error("Terminated", 0) end
                if id == tid then got = true end
            until got or realEpoch("utc") >= deadline
            if not got and left > 0 then
                lost = lost + 1
                klog.kern(string.format(
                    "sleep: timer event lost (waited %dms, lost=%d) -- woke by wall clock instead",
                    math.floor(sec * 1000), lost))
            end
        until realEpoch("utc") >= deadline
    end

    os.sleep = sleep
end

return M
