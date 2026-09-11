--[[ Delin 命名管道 (POSIX FIFO, mkfifo(1)/mkfifo(4)).
     与匿名管道(kernel/pipe.lua)共用同一套缓冲区与协作式阻塞语义, 区别在于**生命周期**:
       - 匿名管道由 pipe.create() 一次性配好两端, 只活在打开它的那条进程链里;
       - 命名管道挂在文件系统的一个 inode 上, 可以被**反复打开**: 每次 open 都在同一个缓冲区上
         挂一个新的读端/写端, 于是 `cat fifo` 与 `echo x > fifo` 能各自独立地开与关, 互不干扰。
     于是 mkfifo + 重定向就是"shell 里两根不相干的命令怎么连起来"的答案(匿名管道管不了这种)。

     open 的阻塞语义按 POSIX(这是 FIFO 与普通文件最大的不同):
       - 以读打开: 阻塞到至少有一个写端打开 —— 否则 `cat fifo` 在还没人写时会立刻 EOF,
         Linux 上它是**阻塞等待**, 这条差异会直接改变脚本行为, 所以按 Linux 来;
       - 以写打开: 阻塞到至少有一个读端打开。
     缓冲归属: 由 (后端对象, inode 号) 唯一确定。同一块盘卸载再挂载, inode 号不变, 缓冲区保留;
     文件被 unlink 时由后端调 forget 释放。

     已知限制: FIFO 端句柄记在缓冲区计数里, 进程若**不 close 就直接被杀**, 计数不会回落
     (与匿名管道同一个限制)。stdio 上的管道端由 process.onExit 统一关闭, 所以 `cat fifo > 文件`
     这类最常见的用法不受影响。 ]]

local pipe = require("kernel.pipe")

local fifo = {}

-- 后端对象 -> { [inode/路径] = 缓冲区 }。弱键: 文件系统被卸载并回收后, 它的管道一起消失。
local bufs = setmetatable({}, { __mode = "k" })

local function bufFor(owner, id)
    local t = bufs[owner]
    if not t then t = {}; bufs[owner] = t end
    local b = t[id]
    if not b then b = pipe.newBuf(); t[id] = b end
    return b
end

--- 打开一个命名管道端。会阻塞到对端出现(POSIX 阻塞 open 语义)。
--- 等待条件同时用三样东西, 缺一样都会踩坑(三个都是实测踩出来的):
---   1. 已挂上的对端(readers/writers)         —— 对端早就在, 直接过;
---   2. 正在 open 的对端(pending*)            —— 双方都只在等对方时必须有一个人先走,
---      否则 `cat fifo & echo x > fifo` 双双等到天荒地老;
---   3. 对端的挂上次数(epoch, 进函数时记下)   —— 闩锁, 防止丢唤醒: 对端挂上、写完、关掉,
---      自己才被调度到, 此时 1 和 2 又都回到 0, 条件重新变假 -> 永久阻塞。
--- pipe.lua 那边的 EOF / broken pipe 判据也把 pending* 算作"对端在场", 与这里配套。
---@param owner table 所属后端(作弱表键, 用来隔离不同文件系统里的同名 inode)
---@param id any 该文件系统内唯一标识该 FIFO 的键(ext2 用 inode 号)
---@param mode string "r" / "w" / "a"
---@return table 句柄(带 .pipe 标记, 由 process.onExit 的 stdio 清理路径统一关闭)
function fifo.open(owner, id, mode)
    mode = mode or "r"
    local buf = bufFor(owner, id)
    -- 缓冲区可能来自更早的版本: 缺字段补齐, 免得 nil 参与算术比较。
    buf.pendingReaders = buf.pendingReaders or 0
    buf.pendingWriters = buf.pendingWriters or 0
    buf.readerEpoch = buf.readerEpoch or 0
    buf.writerEpoch = buf.writerEpoch or 0

    if mode:find("w") or mode:find("a") then
        local seen = buf.readerEpoch
        buf.pendingWriters = buf.pendingWriters + 1
        while buf.readers == 0 and buf.pendingReaders == 0 and buf.readerEpoch == seen do
            os.sleep(0.05)
        end
        buf.pendingWriters = buf.pendingWriters - 1
        return pipe.attachWrite(buf)
    end
    if mode:find("r") then
        local seen = buf.writerEpoch
        buf.pendingReaders = buf.pendingReaders + 1
        while buf.writers == 0 and buf.pendingWriters == 0 and buf.writerEpoch == seen do
            os.sleep(0.05)
        end
        buf.pendingReaders = buf.pendingReaders - 1
        return pipe.attachRead(buf)
    end
    error("fifo: unsupported open mode: " .. tostring(mode), 2)
end

--- 该 FIFO 当前是否有人在读/写(供诊断; 不参与语义)。
---@return integer readers, integer writers
function fifo.counts(owner, id)
    local t = bufs[owner]
    local b = t and t[id]
    if not b then return 0, 0 end
    return b.readers, b.writers
end

--- 释放一个 FIFO 的缓冲区(inode 被删除时调用)。
function fifo.forget(owner, id)
    local t = bufs[owner]
    if t then t[id] = nil end
end

return fifo
