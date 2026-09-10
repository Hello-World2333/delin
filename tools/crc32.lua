--[[ CRC32 (IEEE, 多项式 0xEDB88320), 纯 Lua, 宿主与 CC 通用。
     用途: 构建产物清单 + 安装器下载校验。CC 没有 md5/sha 内建, CRC32 实现小且能立刻发现
     截断/串包; 它不是密码学校验, 只用于传输完整性。

     可移植性: 宿主 lua5.1 没有位运算, CC(Lua 5.2) 有 bit32 但两边必须算出同一个值,
     所以这里**不用任何位运算符**, 用 16x16 半字节 XOR 表 + 除/模代替(与内核其他模块同一约定)。
     用法: local crc32 = dofile("tools/crc32.lua"); crc32.of(s) -> number; crc32.hex(n) -> 8 位十六进制 ]]

local crc32 = {}

-- 16x16 半字节 XOR 表: 纯算术构造一次。
local NX = {}
for a = 0, 15 do
    NX[a] = {}
    for b = 0, 15 do
        local r, bit, x, y = 0, 1, a, b
        while x > 0 or y > 0 do
            if x % 2 ~= y % 2 then r = r + bit end
            x = math.floor(x / 2); y = math.floor(y / 2); bit = bit * 2
        end
        NX[a][b] = r
    end
end

--- 32 位异或(无位运算)。
local function xor32(a, b)
    local r, mul = 0, 1
    for _ = 1, 8 do
        r = r + NX[a % 16][b % 16] * mul
        a = math.floor(a / 16); b = math.floor(b / 16); mul = mul * 16
    end
    return r
end

local TAB = nil
local function buildTable()
    local t = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if c % 2 == 1 then
                c = xor32(math.floor(c / 2), 0xEDB88320)
            else
                c = math.floor(c / 2)
            end
        end
        t[i] = c
    end
    return t
end

--- 计算字符串的 CRC32(无符号 32 位值)。
---@param s string
---@return number
function crc32.of(s)
    if not TAB then TAB = buildTable() end
    local crc = 0xFFFFFFFF
    for i = 1, #s do
        crc = xor32(TAB[xor32(crc, s:byte(i)) % 256], math.floor(crc / 256))
    end
    return 0xFFFFFFFF - crc
end

--- 8 位十六进制小写。分两半格式化: lua5.1 的 %x 对 >2^31 的浮点数不可靠。
---@param n number
---@return string
function crc32.hex(n)
    return string.format("%04x%04x", math.floor(n / 65536), n % 65536)
end

return crc32
