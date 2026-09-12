--[[ Delin 随机数子系统: /dev/random、/dev/urandom 与它们的熵池底座。
     结构对齐 Linux 的两层(random(4) / random.c):

       输入池(512 字节 = 4096 bit, 128 个 32 位字)
         —— Linux primary entropy pool 的**同一个多项式**混合:
            x^128 + x^103 + x^76 + x^51 + x^25 + x + 1, 每掺一字节滚动 input_rotate 7 bit
            (池首那一个字多转 7 bit, 让多次掺入能均匀铺满整个池子)。
       熵估计 entropy_avail
         —— Linux add_timer_randomness 的估计法: 用相邻间隔的二阶/三阶差分的**最小值**取
            ilog2 作为这次采样的熵 bit 数(最小值为 0 记 0 bit, 为 1 记 1 bit), 毫秒时基
            (os.epoch)与 CPU 微秒时基(os.clock)各算一次相加。上限 = 池子大小。
       CRNG(ChaCha20, src/kernel/chacha20.lua)
         —— 密钥从池子里提取(poolHash); 每次输出后**立刻换钥**(Linux 的 fast key erasure:
            计数/nonce 全零, 每块 64 字节的头 32 字节当即成为下一次的密钥, 其余当随机数据),
            因此上一次输出被泄不出去推导出更早的输出。

     熵源 = **所有系统事件**: scheduler 每收到一个事件就调用 random.feedEvent(event),
     样本 = 事件名 + 参数(key/char/paste 的内容、外设名、红石面、modem 消息、timer id…)
            + 到达时刻 + 与上一个事件的间隔(两种时基) + 事件序号。
     真正不可预测的是**事件参数**(人按键、别的电脑发消息、磁盘插拔), 其次是间隔抖动。
     引导时的初始混合(时刻/CPU 时间/电脑 ID/CraftOS 版本/表地址)**不记账** —— 与 Linux 一样,
     这些只是"先搅进池子", 不计入熵估计。

     /dev/random 的阻塞语义按 Linux 5.6+ : **只在 CRNG 未初始化时阻塞**, 初始化之后与
     /dev/urandom 完全一致(不再阻塞)。初始化判据沿用 Linux 的 fast-load 偏置: 事件样本按
     "每字节 1 bit" 记账, 满 128 bit 即算初始化完成(内核日志打 Linux 那句 "random: crng init done")。
     为什么不学 5.6 之前"按熵估计阻塞": CC 的事件间隔被服务器 tick 量化(20Hz 心跳),
     毫秒时基的估计长期涨不上去, `cat /dev/random` 会长时间挂住 —— 那不是 Linux 现在的行为。

     已知偏离(记在 for-ai.md):
       - 池子提取用 ChaCha20 自造的键控 hash, Linux 用 BLAKE2s;
       - 熵估计只做 Linux 的 delta3/ilog2 那一档, 没有它的分组采样/中断合并策略;
       - /dev/random、/dev/urandom **只读**(Linux 允许写入并把写入内容当熵来源);
       - 字节流设备没有"行": readLine 等价于一次 read(4096)。 ]]

local chacha = require("kernel.chacha20")
local klog   = require("kernel.klog")
local vfs_api = require("kernel.vfs_api")

local random = {}

-- ---------------------------------------------------------------
-- 输入池(Linux primary pool 的参数)
-- ---------------------------------------------------------------
local POOL_WORDS = 128             -- 128 字 = 512 字节
local POOL_BITS = POOL_WORDS * 32  -- 4096 bit(Linux /proc/sys/kernel/random/poolsize)
local TAP1, TAP2, TAP3, TAP4, TAP5 = 103, 76, 51, 25, 1
-- Linux 的 twist_table: 把低 3 bit 折回高位(池子里的线性反馈要靠它保持满周期)。
local TWIST = {
    0x00000000, 0x3b6e20c8, 0x76dc4190, 0x4db26158,
    0xedb88320, 0xd6d6a3e8, 0x9b64c2b0, 0xa00ae278,
}

local pool = {}                    -- 32 位字(1 起, 长度 POOL_WORDS)
for i = 1, POOL_WORDS do pool[i] = 0 end
local addPtr = 0                   -- 0 起的字下标(Linux 的 add_ptr)
local inputRotate = 0              -- Linux 的 input_rotate(0..31)

--- 把一段字节掺进输入池(Linux _mix_pool_bytes 的移植: 逐字节, 池子反向滚动, 五个抽头异或)。
---@param data string
local function mixBytes(data)
    local ptr, rot = addPtr, inputRotate
    for bi = 1, #data do
        local w = chacha.rotl32(data:byte(bi), rot)
        ptr = (ptr - 1) % POOL_WORDS
        w = chacha.xor32(w, pool[ptr + 1])
        w = chacha.xor32(w, pool[(ptr + TAP1) % POOL_WORDS + 1])
        w = chacha.xor32(w, pool[(ptr + TAP2) % POOL_WORDS + 1])
        w = chacha.xor32(w, pool[(ptr + TAP3) % POOL_WORDS + 1])
        w = chacha.xor32(w, pool[(ptr + TAP4) % POOL_WORDS + 1])
        w = chacha.xor32(w, pool[(ptr + TAP5) % POOL_WORDS + 1])
        pool[ptr + 1] = chacha.xor32(math.floor(w / 8), TWIST[w % 8 + 1])
        -- 每掺一字节多转 7 bit; θ 在池首(i==0)那一次多转 7 bit, 使多轮掺入能铺满整个池子。
        rot = (rot + (ptr ~= 0 and 7 or 14)) % 32
    end
    addPtr, inputRotate = ptr, rot
end

-- ---------------------------------------------------------------
-- CRNG(ChaCha20) 状态
-- ---------------------------------------------------------------
local key = nil                    -- 32 字节 ChaCha20 密钥
local ZERO_NONCE = string.rep("\0", 12)
-- 域分隔: 提取密钥用的 nonce 与输出密钥流用的 nonce 分开, 免得两处密钥流撞在一起。
local NONCE_EXTRACT = { 0x00000001, 0x00000000, 0x00000000 }

--- 从输入池提取 32 字节密钥(键控吸收: 状态以全零起, 逐块 ChaCha20(state) 与池子字异或,
--- 最后再跑一块收尾)。Linux 用的是 BLAKE2s 对池子做 hash, 这里是同形状的自造 hash。
---@return string 32 字节
local function poolHash()
    local st = {}
    for i = 1, 8 do st[i] = 0 end
    local blocks = POOL_WORDS / 8 -- 每块 8 个字 = 32 字节
    for b = 0, blocks - 1 do
        local blk = chacha.blockWords(st, b, NONCE_EXTRACT)
        for w = 1, 8 do
            st[w] = chacha.xor32(chacha.xor32(st[w], blk[w]), pool[b * 8 + w])
        end
    end
    local fin = chacha.blockWords(st, blocks, NONCE_EXTRACT)
    local out = {}
    for w = 1, 8 do out[w] = chacha.wordBytes(fin[w]) end
    return table.concat(out)
end

-- ---------------------------------------------------------------
-- 熵估计(Linux add_timer_randomness)
-- ---------------------------------------------------------------
local entropyBits = 0              -- entropy_avail(bit)
local CRNG_RESEED_BITS = 128       -- 攒到这么多 bit 就重新播种 CRNG, 并且**消耗掉**这部分记账
-- 重播种 = 把整个池子跑一遍 ChaCha20(17 块), 是几十毫秒的量级 —— 这一步跑在**调度器**的
-- 事件路径上, 太勤会卡住所有进程。所以定一个最小间隔(Linux 的 crng_reseed_interval 是同一用意,
-- 那里是后台定时重播种; 这里是给"熵攒够了就播种"加个下限)。
local CRNG_RESEED_MIN_MS = 1000
local lastReseedMs = 0
local warnedUninit = false

--- 一组时基的二阶/三阶差分状态。
local tmStat  = { last = 0, last2 = 0 } -- 毫秒时基(os.epoch)
local cpuStat = { last = 0, last2 = 0 } -- CPU 微秒时基(os.clock)

--- 精确 ilog2(v)(v >= 1)。
local function ilog2(v)
    local n = 0
    while v > 1 do v = math.floor(v / 2); n = n + 1 end
    return n
end

--- Linux add_timer_randomness 的熵估计: delta/delta2/delta3 取绝对值后取最小,
--- min == 1 记 1 bit, 否则记 ilog2(min); min == 0(间隔完全可预测)记 0 bit。
---@param delta integer
---@param st table { last=, last2= }
---@return integer bits
local function estimateBits(delta, st)
    local d2 = delta - st.last
    local d3 = d2 - st.last2
    st.last, st.last2 = delta, d2
    local m = math.min(math.abs(delta), math.abs(d2), math.abs(d3))
    if m < 1 then return 0 end
    if m == 1 then return 1 end
    return ilog2(m)
end

-- ---------------------------------------------------------------
-- 引导熵(不记账) + 首个密钥
-- ---------------------------------------------------------------
do
    -- 电脑 ID / CraftOS 版本 / 时刻 / CPU 时间 / 若干表地址: 都给池子一点"机器自己的东西"。
    mixBytes(table.concat({
        tostring(os.epoch("utc")),
        string.format("%.9f", os.clock()),
        tostring(os.getComputerID and os.getComputerID() or 0),
        tostring(os.version and os.version() or ""),
        tostring(_VERSION),
        tostring({}), tostring({}), tostring({}),
    }, "\x1e"))
    key = poolHash()
end

-- ---------------------------------------------------------------
-- 事件进熵池(scheduler 的唯一入口)
-- ---------------------------------------------------------------
local eventSeq = 0
local lastEventMs = os.epoch("utc")
local lastEventCpuUs = math.floor(os.clock() * 1000000)
local CRNG_INIT_BIAS = 128         -- Linux 同名常量: fast-load 满 128 bit 就算初始化完成
local initBits = 0                 -- fast-load 记账(样本每字节 1 bit)
local ready = false                -- CRNG 是否已初始化(/dev/random 的阻塞判据)

--- 掺入一个系统事件(scheduler 每收到一个事件调用一次)。
--- **必须在调度器上下文调用**: 不做任何让步, 也不该变慢。
---@param event table os.pullEventRaw 的返回值(table.pack 包起来的: [1]=事件名, [2..n]=参数)
function random.feedEvent(event)
    local nowMs = os.epoch("utc")
    local cpuUs = math.floor(os.clock() * 1000000)
    local dtMs = nowMs - lastEventMs
    local dtCpu = cpuUs - lastEventCpuUs
    lastEventMs, lastEventCpuUs = nowMs, cpuUs
    eventSeq = eventSeq + 1

    local parts = { tostring(event[1]) }
    for i = 2, event.n or #event do
        local s = tostring(event[i])
        if #s > 64 then s = s:sub(1, 64) end -- 长参数(paste/modem 消息)只取前 64 字节
        parts[#parts + 1] = s
        if #parts >= 16 then break end
    end
    parts[#parts + 1] = string.format("%d\x1f%d\x1f%d\x1f%d\x1f%d", nowMs, dtMs, cpuUs, dtCpu, eventSeq)
    local sample = table.concat(parts, "\x1f")
    if #sample > 256 then sample = sample:sub(1, 256) end

    mixBytes(sample)

    -- 1) 熵估计(毫秒 + CPU 微秒两个时基)
    local bits = estimateBits(dtMs, tmStat) + estimateBits(dtCpu, cpuStat)
    if bits > 0 then
        entropyBits = math.min(entropyBits + bits, POOL_BITS)
        -- 攒够 128 bit 就重新播种(提取会消耗掉这部分记账, 与 Linux 提取熵的语义一致)。
        if entropyBits >= CRNG_RESEED_BITS and nowMs - lastReseedMs >= CRNG_RESEED_MIN_MS then
            key = poolHash()
            entropyBits = entropyBits - CRNG_RESEED_BITS
            lastReseedMs = nowMs
        end
    end

    -- 2) fast-load 记账(Linux crng_fast_load): 未初始化时样本每字节记 1 bit, 满 128 bit 完成初始化。
    if not ready then
        initBits = initBits + #sample
        if initBits >= CRNG_INIT_BIAS then
            ready = true
            key = poolHash()
            lastReseedMs = nowMs
            klog.kern("random: crng init done")
        end
    end
end

-- ---------------------------------------------------------------
-- 随机字节
-- ---------------------------------------------------------------
--- 生成 n 字节随机数据(ChaCha20 密钥流; 输出后立即换钥)。
--- Linux crng_fast_key_erasure 的原样做法: 计数器/nonce 全零, 每块 64 字节的**头 32 字节**
--- 当即成为下一次的密钥, 其余字节才是给出去的随机数据。
---@param n integer
---@return string
function random.bytes(n)
    local out, left, ctr = {}, n, 0
    local newKey = nil
    while left > 0 do
        local blk = chacha.blockBytes(key, ctr, ZERO_NONCE)
        if ctr == 0 then
            newKey = blk:sub(1, 32)
            local take = blk:sub(33, 32 + left)
            out[#out + 1] = take
            left = left - #take
        else
            local take = blk:sub(1, math.min(64, left))
            out[#out + 1] = take
            left = left - #take
        end
        ctr = ctr + 1
    end
    -- n == 0 时也换一次钥: 密钥流的第 0 块从不对外(它的后 32 字节没用到), 留着只会被复用。
    if newKey == nil then newKey = chacha.blockBytes(key, 0, ZERO_NONCE):sub(1, 32) end
    key = newKey
    return table.concat(out)
end

--- 十六进制随机串(2*n 个小写十六进制字符)。
function random.hex(n)
    local s = random.bytes(n)
    local out = {}
    for i = 1, #s do out[i] = string.format("%02x", s:byte(i)) end
    return table.concat(out)
end

--- RFC 4122 v4 UUID(每次调用取新值, 与 Linux /proc/sys/kernel/random/uuid 一致)。
---@return string
function random.uuid()
    local b = random.bytes(16)
    local s = {}
    for i = 1, 16 do s[i] = string.format("%02x", b:byte(i)) end
    s[7] = "4" .. string.format("%x", b:byte(7) % 16)                 -- version 4
    s[9] = string.format("%02x", b:byte(9) % 64 + 0x80)               -- variant 10xx
    return table.concat(s, "", 1, 4) .. "-" .. table.concat(s, "", 5, 6) .. "-"
        .. table.concat(s, "", 7, 8) .. "-" .. table.concat(s, "", 9, 10) .. "-"
        .. table.concat(s, "", 11, 16)
end

-- ---------------------------------------------------------------
-- 状态查询(procfs /proc/sys/kernel/random/*)
-- ---------------------------------------------------------------
function random.entropyAvail() return entropyBits end
function random.poolsize() return POOL_BITS end
function random.ready() return ready end

-- ---------------------------------------------------------------
-- 设备节点: /dev/random、/dev/urandom
-- ---------------------------------------------------------------
local DEFAULT_READ = 4096

--- 随机数读句柄。
---@param blocking boolean 未初始化时是否阻塞(/dev/random 是, /dev/urandom 否)
---@param name string 设备名(错误信息用)
local function randomHandle(blocking, name)
    local closed = false
    local function take(n)
        if closed then return nil, name .. ": closed" end
        if not ready then
            if blocking then
                -- CRNG 未初始化: 阻塞等事件把熵喂上来(Linux 5.6+ 的 /dev/random 同样在这里等)。
                -- os.sleep 让出给调度器, 心跳事件照常进池, 所以不会死等。
                while not ready do os.sleep(0.05) end
            elseif not warnedUninit then
                warnedUninit = true
                klog.kern("random: uninitialized urandom read (CRNG not ready)")
            end
        end
        return random.bytes(n)
    end
    return {
        read = function(self, n)
            if type(self) == "number" then n = self end -- 点号调用 read(n) 也认
            return take(n or DEFAULT_READ)
        end,
        -- 字节流设备没有"行"的概念: 一次给一块(与 Linux 侧 read(2) 唯一能对应的就是字节)。
        readLine = function() return take(DEFAULT_READ) end,
        -- 只读设备(写打开在 vfs 那层就被拒); 拿读句柄去写同样报错而不是静默吞掉。
        write = function() return nil, name .. ": read-only device" end,
        flush = function() return true end,
        close = function() closed = true; return true end,
        getDeviceName = function() return name end,
    }
end

--- 注册 /dev/random 与 /dev/urandom(boot 在 mountDev 之后调用一次)。
function random.register()
    vfs_api.registerDevice("random", {
        writable = false, -- 只读: Linux 允许往 /dev/random 写熵, Delin 不提供这条通道
        open = function() return randomHandle(true, "random") end,
    })
    vfs_api.registerDevice("urandom", {
        writable = false,
        open = function() return randomHandle(false, "urandom") end,
    })
    klog.kern(string.format("random: ChaCha20 CRNG, %d-bit entropy pool", POOL_BITS))
end

return random
