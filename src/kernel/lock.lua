--[[ Delin 内核临界区锁(抢占式调度用).

     **为什么需要**: 协作式调度下"一段内核代码跑到让出点"是天然原子的; 开了抢占之后,
     一条 `fs.write` 可能在任何一条 VM 指令处被打断, 另一个进程就能在同一份内核状态
     (ext2 的位图/inode 表、挂载表、tty 的 grid、管道缓冲...)上做同类操作 —— 元数据会被写坏。
     所以内核入口处必须进临界区。

     **这一版的粒度是"全局内核锁"**(一把锁罩住全部内核入口), 规则三条:
       1. 进程进内核(syscall / VFS 门面 / tty 句柄)时 `lock.enter()`, 出来 `lock.leave()`;
       2. **持锁时不让出**: 调度器的切片钩子看 `lock.depth`, >0 就直接返回(把这一段留成
          不可抢占的临界区)。否则"持锁被抢走"会让调度器自己的内核活儿(事件路由/光标闪烁)
          与被挂起的半截操作交错 —— 那正是锁要防的事。
       3. **内核里要阻塞等事件的地方**(tty 读、管道读写、FIFO open)必须先 `lock.pause(fn)`
          放锁再等, 醒来再拿回来。持锁阻塞会把锁焊死(所有进程都进不了内核, 包括读键盘的那个)。

     持锁者可能**在核心里阻塞**(内核里有的是会等事件的地方: `proc.wait`、管道、FIFO、
     `init.start` 里的 os.sleep...), 也可能在让出点被调度器换下去。所以撞上别人持锁时
     `enter()` **排队等待**(yield "__lock", 由 `leave()` 唤醒队首), 而不是 fail-fast ——
     真机上 fail-fast 的代价是"另一个进程当场死掉"(实测: systemctl 调 init.start 时持锁睡了
     50ms, syslogd 与 3 个 login 全被这条打死)。

     等待不会死锁: 持锁者要么在可运行队列里(会被调度器恢复), 要么在等事件(事件到了就恢复),
     两种情况都会跑到 `leave()`。进程带着锁死掉时由调度器调 `lock.forget(pid)` 兜底。

     将来要细化(比如 ext2 一把、tty 一把、管道一把, 允许持锁也被抢占)时, 把 `enter/leave`
     换成带等待队列的多锁、并让钩子改成"只对不可抢占的锁屏蔽"即可 —— 调度器那边不用动。 ]]

local lock = {}

--- 抢占式调度没开时, 锁**整个不启用**: 代理表直接把原函数交出去, 一次额外的调用/ pcall
--- 都不发生(协作式下内核本来就是"跑到让出点才切换", 不需要临界区)。默认关闭, 所以
--- 默认路径的开销与改动前逐字一致 —— 这是"原型默认关"的硬要求。
local enabled = false

--- 由调度器开关驱动(scheduler.setPreempt 调用)。
function lock.setEnabled(on) enabled = on and true or false end
function lock.isEnabled() return enabled end

-- 宿主测试台是 Lua 5.1(table.pack 是 5.2 才有的), 真机 Cobalt 是 5.2 —— 两处都要能跑。
local pack = table.pack or function(...) return { n = select("#", ...), ... } end
local unpack = table.unpack or unpack

-- 全局内核锁的状态(depth = 重入深度, owner = 持有者 pid)。
local depth = 0
local owner = nil

-- 当前正在跑的进程 pid: 由**调度器**在 resume 前后设置(resume 一个进程 = 从此处开始在
-- 这个进程的上下文里跑内核代码)。这样 enter/leave 是纯 O(1) 表读写, 不碰 require,
-- 也不做 coroutine.running() 反查 —— 锁在每条 syscall 上都会被摸一次。
local curPid = nil

--- 调度器用: 声明"接下来跑的进程是 pid"(传 nil = 回到内核上下文)。
function lock.setCurrent(pid)
    curPid = pid
end

--- 当前是否在(本进程的)内核临界区里 —— 调度器的切片钩子据此决定要不要让出。
---@return boolean
function lock.inKernel()
    return depth > 0
end

--- 临界区里"时间片用完了"的记号(由切片钩子置上)。
--- **为什么需要它**: 计数钩子只数用户态 VM 指令; 而 `find`/`ls` 这种"密集小内核调用"的进程,
--- 指令几乎全花在被屏蔽的临界区里 —— 每 N 条指令的窗口都落在核心里被吞掉, 于是**永远抢不到**
--- CPU(真机实测: `find /` 一跑, 其他终端读键盘的进程每秒只被恢复 1-2 次, 一轮调度 0.5~1 秒)。
--- 现在的做法: 核心里只记号, **出临界区的那一刻立刻让出** —— 每个内核调用之后都是一个安全点。
local preemptPending = false

function lock.markPreempt()
    preemptPending = true
end

--- 出临界区之后调用: 若钩子在临界区里标记过就让出(此时已不在内核里, 安全)。
---@return boolean 是否让出了
function lock.yieldIfPending()
    if not preemptPending or curPid == nil then
        preemptPending = false
        return false
    end
    preemptPending = false
    coroutine.yield("__preempt")
    return true
end

function lock.depthOf() return depth end
function lock.ownerOf() return owner end

-- 等待队列(FIFO 存 pid) + 唤醒器(由调度器注入: 让某个 pid 重新可运行)。
local waiters = {}
local waker = nil

--- 调度器注入: 把某进程放回可运行队列(抢占模式下由 wakePid 实现)。
--- **必须在调度器模块加载完之后注册**(模块加载期引用 `scheduler.wakePid` 拿到的是 nil):
--- 注册成 nil 的后果是"等着锁的进程永远不会被唤醒", 真机上表现为某个终端提示符再也不回来。
function lock.setWaker(fn) waker = fn end

--- 唤醒器是否已注册(给宿主回归/自检用; 没注册就等锁 = 必然挂死)。
function lock.wakerReady() return waker ~= nil end

--- 放锁后唤醒队首(没有等待者就什么都不做)。
local function wakeNext()
    local pid = table.remove(waiters, 1)
    if pid and waker then waker(pid) end
end

--- 进临界区(可重入)。撞上别人持锁时**排队等**(yield "__lock"), 醒来重试。
function lock.enter()
    local pid = curPid
    while true do
        if depth == 0 then
            depth, owner = 1, pid
            return
        elseif owner == pid then
            depth = depth + 1
            return
        end
        -- 没有唤醒器就必然挂死(排队后没人叫醒) —— fail-fast, 别留一个静默的永久阻塞。
        if not waker then
            error("kernel lock: no waker registered, a lock wait would hang forever", 2)
        end
        waiters[#waiters + 1] = pid
        coroutine.yield("__lock") -- 调度器会把它停住, 直到 leave() 唤醒队首
    end
end

--- 出临界区。放到 0 时唤醒一个等待者(把锁交给它)。
function lock.leave()
    if depth == 0 then error("kernel lock released while not held", 2) end
    depth = depth - 1
    if depth == 0 then
        owner = nil
        wakeNext()
    end
end

--- 进程带着锁死了: 强制放锁并唤醒等待者(调度器在回收进程时调用, 兜底防死锁)。
---@param pid integer
function lock.forget(pid)
    if depth ~= 0 and owner == pid then
        depth, owner = 0, nil
        wakeNext()
    end
    for i = #waiters, 1, -1 do
        if waiters[i] == pid then table.remove(waiters, i) end
    end
end

-- 已经包过的函数(弱键): 重复包装会一层套一层, 而包装器是惰性重建的 —— 漏了这条
-- 就会"每次取用再包一层", 最终 stack overflow(真机踩过: cmp/syslogd/sh/init 全死在这里)。
local wrappedFns = setmetatable({}, { __mode = "k" })

--- 把函数包成临界区(错误也保证离开; 错误原样抛出)。
---@param fn function
---@return function
function lock.wrap(fn)
    if not enabled then return fn end
    if wrappedFns[fn] then return fn end
    local w
    w = function(...)
        lock.enter()
        local r = pack(pcall(fn, ...))
        lock.leave()
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, r.n)
    end
    wrappedFns[w] = true
    return w
end

--- 把一张表里的函数全部包成临界区(惰性: 用到谁才包谁)。
---
--- **方法调用要把 self 换回原表**: 代理表拿到 `proxy:write(s)` 之后, 若原样把它转给原表,
--- 原表的方法收到的 self 就是**代理**而不是句柄自己。Delin 的句柄是"两种调用风格都接受"的
--- (见 kernel/vfs.lua 的 wrapCCHandle: CC 原生句柄方法靠 `self == 自己` 判断点号/冒号),
--- self 换成代理就落进"点号"那一支 —— 真机症状正是文件里出现 `table: 0x...`(不报错,
--- 极难查: 实测 `/etc/systemd/system/...` 上的 `echo ... > /mnt/hdd/parts/manifest` 写成了
--- `table: 6030d5c6`, 于是 /dev/sda1 的分区路径变成 "/6030d5c6", mkfs/mount/fsck 全找不到文件)。
--- 判据 `a == proxy` 是可靠的: 参数里不会有代理表自己。
---
--- 缓存放在自己的表里, 不能写回 proxy(proxy[k] = w 会走 __newindex 把包装后的函数写进原表,
--- 下一次取用又会包一层 —— 无限套娃, 真机踩过一次)。
---@param t table
---@return table
function lock.wrapTable(t)
    local cache, present = {}, {}
    local proxy
    local function wrapFn(v)
        if wrappedFns[v] then return v end
        local w
        w = function(a, ...)
            local self = (a == proxy) and t or a
            if not enabled then return v(self, ...) end -- 关锁: 只做 self 修正(不加一层 pcall)
            lock.enter()
            local r = pack(pcall(v, self, ...))
            lock.leave()
            -- 临界区里用完了时间片: 在这里(已经出了临界区)让出, 让别的进程有机会跑。
            if preemptPending and curPid ~= nil then
                preemptPending = false
                coroutine.yield("__preempt")
            end
            if not r[1] then error(r[2], 0) end
            return unpack(r, 2, r.n)
        end
        wrappedFns[w] = true
        return w
    end
    proxy = setmetatable({}, {
        __index = function(_, k)
            local v = t[k]
            if type(v) ~= "function" then return v end
            if present[k] then return cache[k] end
            present[k] = true
            cache[k] = wrapFn(v)
            return cache[k]
        end,
        __newindex = function(_, k, v) t[k] = v; cache[k] = nil; present[k] = false end,
        __pairs = function() return pairs(t) end,
    })
    return proxy
end

--- **在内核里阻塞等事件**(tty 读/管道读写/FIFO open): 先放锁, 跑 fn(里面 os.pullEvent/os.sleep),
--- 醒来再把锁拿回来。fn 抛错时也要把锁拿回来再抛。
---@param fn function
---@return ...
function lock.pause(fn)
    if depth == 0 then
        -- 不在临界区里(比如宿主测试台/内核直接调用): 直接跑。
        return fn()
    end
    local saved = depth
    depth, owner = 0, nil
    wakeNext() -- 放锁就把等待者让进来(否则他们白等这一整段)
    local r = pack(pcall(fn))
    -- 拿回来(可能要让出等: 这段等待期间别人可能已经持锁)
    for _ = 1, saved do lock.enter() end
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, r.n)
end

--- 宿主测试台/未启用抢占时, 提供一个彻底的空实现(不引入任何开销与不变式)。
function lock.disabled()
    lock.inKernel = function() return false end
    lock.enter = function() end
    lock.leave = function() end
    lock.wrap = function(fn) return fn end
    lock.wrapTable = function(t) return t end
    lock.pause = function(fn) return fn() end
    lock.depthOf = function() return 0 end
    lock.ownerOf = function() return nil end
    lock.setCurrent = function() end
    lock.markPreempt = function() end
    lock.yieldIfPending = function() return false end
    lock.setWaker = function() end
    lock.forget = function() end
    lock.wakerReady = function() return true end
end

return lock
