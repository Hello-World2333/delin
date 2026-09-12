--[[ Delin ChaCha20 核心(RFC 8439) —— 随机数子系统的密码学底座(src/kernel/random.lua)。

     为什么是纯算术的 32 位实现, 不用 CC 的 bit32:
       - 宿主测试台是 lua5.1(没有 bit32), 而内核模块必须在宿主上跑同一套自检;
       - 项目里一律不用位运算(sh 的 $(( )) 也是纯算术 32 位), 保持一致。
     32 位运算按"取模 + 半字节异或查表"做:
       xor32(a,b)    拆 4 字节 → 每字节拆两个半字节 → 16x16 查表 → 拼回
       rotl32(v,n)   (v % 2^(32-n)) * 2^n + v / 2^(32-n)   (n 在 1..31, 结果必 < 2^32)
       add32(a,b)    (a + b) % 2^32
     ChaCha20 只需要 xor / 加 / 循环移位, 所以用不到 and/or。
     数值全程是"精确可表示的 number"(Lua 5.2 的 ^ 返回浮点, 但 < 2^32 时精确无损)。

     布局 = IETF 变体(RFC 8439): 32 位块计数器 + **96 位 nonce**, 与 Linux 的 CRNG 同构。 ]]

local chacha = {}

local M32 = 4294967296

-- ---------------------------------------------------------------
-- 32 位纯算术运算
-- ---------------------------------------------------------------
-- 半字节异或表(16x16): 32 位异或拆成 8 次查表, 比逐 bit 循环快得多。
local NX = {}
do
    local function nibxor(a, b) -- 0..15
        local v, bit = 0, 1
        for _ = 1, 4 do
            if (a % 2) ~= (b % 2) then v = v + bit end
            a = math.floor(a / 2); b = math.floor(b / 2); bit = bit * 2
        end
        return v
    end
    for a = 0, 15 do
        for b = 0, 15 do NX[a * 16 + b] = nibxor(a, b) end
    end
end

--- 32 位异或(纯算术)。
---@param a integer 0..2^32-1
---@param b integer 0..2^32-1
---@return integer
local function xor32(a, b)
    local r, mul = 0, 1
    for _ = 1, 4 do
        local x, y = a % 256, b % 256
        a = math.floor(a / 256); b = math.floor(b / 256)
        r = r + (NX[math.floor(x / 16) * 16 + math.floor(y / 16)] * 16
              + NX[(x % 16) * 16 + (y % 16)]) * mul
        mul = mul * 256
    end
    return r
end
chacha.xor32 = xor32

-- 循环左移的乘除常数: rotl32 里不能现算 2^n(每个 quarter-round 要转 4 次)。
local RSHL, RSHR = {}, {}
for n = 1, 31 do
    RSHL[n] = 2 ^ n
    RSHR[n] = 2 ^ (32 - n)
end

--- 32 位循环左移(n=0 时原样返回; n 必须在 0..31)。
local function rotl32(v, n)
    if n == 0 then return v end
    local shr = RSHR[n]
    return (v % shr) * RSHL[n] + math.floor(v / shr)
end
chacha.rotl32 = rotl32

--- 32 位加法(带回绕)。
local function add32(a, b)
    local s = a + b
    if s >= M32 then s = s - M32 end
    return s
end
chacha.add32 = add32

--- 两串等长字节逐字节异或(半字节查表)。
---@param a string
---@param b string
---@return string
function chacha.xorBytes(a, b)
    local out = {}
    for i = 1, #a do
        local x, y = a:byte(i), b:byte(i) or 0
        out[i] = string.char(NX[math.floor(x / 16) * 16 + math.floor(y / 16)] * 16
                           + NX[(x % 16) * 16 + (y % 16)])
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------
-- 字节 ↔ 32 位字(小端, 与 RFC 8439 一致)
-- ---------------------------------------------------------------
--- 字符串偏移处的小端 32 位字(越界字节按 0, 于是尾部零填充天然成立)。
---@param s string
---@param off integer 1 起的字节偏移
---@return integer
function chacha.wordAt(s, off)
    local b1 = s:byte(off) or 0
    local b2 = s:byte(off + 1) or 0
    local b3 = s:byte(off + 2) or 0
    local b4 = s:byte(off + 3) or 0
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

--- 32 位字 → 4 字节小端串。
function chacha.wordBytes(w)
    return string.char(w % 256, math.floor(w / 256) % 256,
                       math.floor(w / 65536) % 256, math.floor(w / 16777216) % 256)
end

--- 32 字节密钥串 → 8 个 32 位字。
function chacha.keyWords(key)
    local k = {}
    for i = 0, 7 do k[i + 1] = chacha.wordAt(key, i * 4 + 1) end
    return k
end

--- 12 字节 nonce 串 → 3 个 32 位字。
function chacha.nonceWords(nonce)
    local n = {}
    for i = 0, 2 do n[i + 1] = chacha.wordAt(nonce, i * 4 + 1) end
    return n
end

-- ---------------------------------------------------------------
-- 块函数
-- ---------------------------------------------------------------
-- "expand 32-byte k"
local SIGMA = { 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574 }

local function quarterRound(x, a, b, c, d)
    x[a] = add32(x[a], x[b]); x[d] = rotl32(xor32(x[d], x[a]), 16)
    x[c] = add32(x[c], x[d]); x[b] = rotl32(xor32(x[b], x[c]), 12)
    x[a] = add32(x[a], x[b]); x[d] = rotl32(xor32(x[d], x[a]), 8)
    x[c] = add32(x[c], x[d]); x[b] = rotl32(xor32(x[b], x[c]), 7)
end

--- ChaCha20 块函数: 16 个 32 位字输入 → 16 个 32 位字输出(64 字节密钥流)。
---@param key integer[] 8 个 32 位字(32 字节密钥, 小端)
---@param counter integer 32 位块计数器(0..2^32-1)
---@param nonce integer[] 3 个 32 位字(96 位 nonce, 小端)
---@return integer[] 16 个 32 位字
function chacha.blockWords(key, counter, nonce)
    local st = {
        SIGMA[1], SIGMA[2], SIGMA[3], SIGMA[4],
        key[1], key[2], key[3], key[4], key[5], key[6], key[7], key[8],
        counter, nonce[1], nonce[2], nonce[3],
    }
    local w = {}
    for i = 1, 16 do w[i] = st[i] end
    for _ = 1, 10 do -- 20 轮 = 10 次双轮
        quarterRound(w, 1, 5, 9, 13)
        quarterRound(w, 2, 6, 10, 14)
        quarterRound(w, 3, 7, 11, 15)
        quarterRound(w, 4, 8, 12, 16)
        quarterRound(w, 1, 6, 11, 16)
        quarterRound(w, 2, 7, 12, 13)
        quarterRound(w, 3, 8, 9, 14)
        quarterRound(w, 4, 5, 10, 15)
    end
    local out = {}
    for i = 1, 16 do out[i] = add32(w[i], st[i]) end
    return out
end

--- ChaCha20 块函数(字节面): 32 字节密钥 + 计数器 + 12 字节 nonce → 64 字节密钥流。
---@param key string 32 字节
---@param counter integer
---@param nonce string 12 字节
---@return string 64 字节
function chacha.blockBytes(key, counter, nonce)
    local w = chacha.blockWords(chacha.keyWords(key), counter, chacha.nonceWords(nonce))
    local out = {}
    for i = 1, 16 do out[i] = chacha.wordBytes(w[i]) end
    return table.concat(out)
end

return chacha
