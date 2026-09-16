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

     于是锁的持有者永远是"正在跑的进程", 任何进程被恢复时 `depth` 必然是 0 ——
     `enter()` 因此**不需要等待队列**, 它不是"撞上就阻塞"的锁, 而是"不该撞上"的锁:
     真撞上(另一个 pid 持锁)就是不变式被破坏, fail-fast。

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

function lock.depthOf() return depth end
function lock.ownerOf() return owner end

--- 进临界区(可重入)。
function lock.enter()
    local pid = curPid
    if depth == 0 then
        depth, owner = 1, pid
    elseif owner == pid then
        depth = depth + 1
    else
        -- 不变式: 持锁者不可能被抢占(见文件头第 2 条), 所以这里永远不该发生。
        error(string.format("kernel lock held by pid %s, but pid %s entered", tostring(owner), tostring(pid)), 2)
    end
end

--- 出临界区。
function lock.leave()
    if depth == 0 then error("kernel lock released while not held", 2) end
    depth = depth - 1
    if depth == 0 then owner = nil end
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
    local r = pack(pcall(fn))
    depth, owner = saved, curPid
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
end

return lock
