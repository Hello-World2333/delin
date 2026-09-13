--[[ Delin 软RAID 宿主回归: 内核 md(kernel/md.lua)各级别的数据路径、降级读取、重建与
     与真实 ext2 的端到端判定。判据分四层, 后三层都**不复用内核代码**:

       ① 阵列自身读写往返(通过 md 的块设备视图写一遍模式, 再读回来比对);
       ② **独立的布局模型**: 本文件按 for-ai.md 记录的 md 布局重写一份放置模型(条带/镜像/
          校验盘位置、raid10 的 near/far/offset 公式), 直接从成员镜像文件里取数据拼出逻辑阵列
          —— 放置错一个块, 这里就对不上;
       ③ RAID6 的 Q 校验用**独立的 GF(2^8) 乘法**(逐位 double/异或 0x1d, 不用 md.lua 的
          log/exp 表)重算每个条带, 与成员上的 Q 块比对;
       ④ `devdisk.mkfs /dev/mdN` 在阵列上造的 ext2, 用上面那套模型抽成普通镜像文件后交给
          宿主的 e2fsck -fn 判干净 —— e2fsck 是第三方裁判, 映射错一个扇区都会报损坏。

     用法: lua5.1 tools/mdtest.lua     (需要宿主 e2fsck)
]]

io.stdout:setvbuf("line")

local function repoRoot()
    local self = (arg and arg[0]) or "tools/mdtest.lua"
    local dir = self:match("^(.*)/[^/]*$") or "."
    local root = dir:match("^(.*)/[^/]+$") or "."
    if root:sub(1, 1) ~= "/" then
        local p = io.popen("pwd")
        local cwd = p:read("*l"); p:close()
        root = (root == ".") and cwd or (cwd .. "/" .. root:gsub("^%./", ""))
    end
    return root
end
local REPO = repoRoot()
package.path = REPO .. "/src/?.lua;" .. package.path

local ROOT = os.getenv("DELIN_MDTEST_ROOT") or "/tmp/delin-mdtest"
local MEMDIR = ROOT .. "/members"
local E2FSCK = "/usr/sbin/e2fsck"

-- ---------------------------------------------------------------
-- 宿主环境桩: kernel 层要的全局(fs/os/peripheral/disk)在宿主上没有, 给最小实现。
-- 与 tools/ext2test.lua 同一思路: 内存/host 文件直通, 不用 CC。
-- ---------------------------------------------------------------
os.epoch = os.epoch or function() return os.time() * 1000 end
local function hostPath(p)
    p = tostring(p or "")
    if p:sub(1, 1) ~= "/" then p = "/" .. p end
    return ROOT .. p
end

local function hostSize(p)
    local st = io.popen("stat -c %s '" .. hostPath(p) .. "' 2>/dev/null")
    local n = tonumber(st:read("*a")); st:close()
    return n or 0
end
local function hostExists(p)
    local st = io.popen("[ -e '" .. hostPath(p) .. "' ] && echo yes")
    local r = st:read("*a"); st:close()
    return r ~= ""
end
local function hostIsDir(p)
    local st = io.popen("[ -d '" .. hostPath(p) .. "' ] && echo yes")
    local r = st:read("*a"); st:close()
    return r ~= ""
end

--- CC 风格的文件句柄(点号/冒号调用都收)。
local function wrapHandle(h)
    local handle = {}
    handle.read = function(a, b)
        local n = (type(a) == "table") and b or a
        return h:read(n)
    end
    handle.readLine = function(a, b)
        local n = (type(a) == "table") and b or a
        return h:read(n or "*l")
    end
    handle.readAll = function() return h:read("*a") end
    handle.write = function(a, b)
        local s = (type(a) == "table") and b or a
        local ok = h:write(s)
        -- 立即落盘: 内核的成员句柄是**常开**的(阵列生命周期内不关), 而测试里另一条路径用
        -- 新开的句柄读同一个文件 —— 不 flush 就永远读到旧内容(CC 上 fs 是共享的, 没这个问题)。
        h:flush()
        return ok
    end
    handle.seek = function(a, b, c)
        local whence, off
        if type(a) == "table" then whence, off = b, c else whence, off = a, b end
        -- 注意: 真实 file:seek 只返回**一个**值(新位置), 写成 `local ok, pos = h:seek(...)`
        -- 再 return pos 会一直返回 nil —— 调试这个测试台时踩过。
        local pos = h:seek(whence, off or 0)
        if not pos then return nil, "seek failed" end
        return pos
    end
    handle.flush = function() return h:flush() end
    handle.close = function() return h:close() end
    return handle
end

_G.fs = {
    open = function(path, mode)
        local h = io.open(hostPath(path), mode == "r" and "rb" or "r+b")
        if not h then return nil, "cannot open " .. tostring(path) end
        -- no buffering: 内核的成员句柄常开且反复 seek/read/write 混用, 宿主 Lua 的缓冲会
        -- 让"另一条路径新开的句柄"读到旧内容(CC 的 fs 是共享的, 真机上没有这个问题)。
        h:setvbuf("no")
        return wrapHandle(h)
    end,
    getSize = function(path) return hostSize(path) end,
    exists = function(path) return hostExists(path) end,
    isDir = function(path) return hostIsDir(path) end,
    isFile = function(path) return hostExists(path) and not hostIsDir(path) end,
    getName = function(p) return (tostring(p):match("[^/]*$")) or "" end,
    getDir = function(p)
        local d = tostring(p):match("^(.*)/[^/]*$")
        if d == nil or d == "" then return "/" end
        return d
    end,
    combine = function(a, b)
        b = tostring(b or "")
        if b:sub(1, 1) == "/" then return b end
        if a == nil or a == "" then return b end
        return tostring(a):gsub("/+$", "") .. "/" .. b
    end,
    isDriveRoot = function(p) return tostring(p):match("^/[^/]*$") ~= nil end,
    complete = function() return {} end,
    getCapacity = function() return 1000000 end,
    getFreeSpace = function() return 500000 end,
    getDrive = function() return "hdd" end,
    list = function() return {} end,
    makeDir = function() return false end,
    delete = function() return false end,
    move = function() return false end,
    copy = function() return false end,
}
_G.peripheral = { getNames = function() return {} end, getType = function() return nil end }
_G.disk = {
    hasData = function() return false end, getID = function() return nil end,
    getMountPath = function() return nil end, getLabel = function() return nil end,
}
_G.os.getComputerID = _G.os.getComputerID or function() return 3 end
_G.os.getComputerLabel = _G.os.getComputerLabel or function() return nil end

local blockdev = require("kernel.blockdev")
local devdisk  = require("kernel.devdisk")
local md       = require("kernel.md")

-- 内核日志: 收进表里(断言"降级/重建"这类事件确实被记下来了)
local kernLog = {}
md.attach({ kern = function(m) kernLog[#kernLog + 1] = m end }, _G.fs)

-- ---------------------------------------------------------------
-- 判定
-- ---------------------------------------------------------------
local pass, fail = 0, 0
local function ok(cond, label, extra)
    if cond then
        pass = pass + 1
        io.write("ok   " .. label .. "\n")
    else
        fail = fail + 1
        io.write("FAIL " .. label .. (extra ~= nil and ("  -- " .. tostring(extra)) or "") .. "\n")
    end
end
--- 失败信息: 阵列内容是二进制, 原样打出来只会刷满乱码 —— 报长度 + 第一个不同的字节位置 + 该处两侧的十六进制。
local function hexAt(s, i) return string.format("%02x", s:byte(i) or 0) end
local function brief(v, other)
    local s = tostring(v)
    if type(other) == "string" and #other == #s then
        for i = 1, #s do
            if s:byte(i) ~= other:byte(i) then
                return string.format("[%d bytes] first diff at byte %d: %s vs %s",
                    #s, i, hexAt(s, i), hexAt(other, i))
            end
        end
    end
    if #s > 32 then return "[" .. #s .. " bytes] " .. (s:sub(1, 32):gsub("[^%g ]", ".")) end
    return s
end
local function eq(got, want, label)
    ok(got == want, label, "got=" .. brief(got, want) .. " want=" .. brief(want, got))
end

-- ---------------------------------------------------------------
-- 成员镜像文件
-- ---------------------------------------------------------------
local function memberPath(i) return MEMDIR .. "/mem" .. i .. ".img" end

--- 建一个 size 字节的成员镜像(全 0)。
local function makeMember(i, size, fill)
    local f = assert(io.open(memberPath(i), "wb"))
    f:write(string.rep(fill or "\0", size))
    f:close()
    return memberPath(i)
end

--- 注册成 devdisk 的块设备节点(/dev/f1 ..), 与真机上的 /dev/sdXN 走同一条路径。
--- 注意路径: 内核看到的是 VFS 视角("/members/mem1.img"), 测试台的 fs 桩把它映射到 ROOT 下,
--- 所以这里给的是**相对虚拟根**的路径(与真机上 "disk/parts/x.img" 一个性质)。
local function registerMember(i)
    local vpath = "/members/mem" .. i .. ".img"
    devdisk.registerNode({
        name = "f" .. i, node = "/dev/f" .. i, type = "part", fstype = "ext2",
        size = hostSize(vpath),
        openBd = function(mode) return blockdev.file(vpath, mode) end,
    })
end

-- ---------------------------------------------------------------
-- 独立的布局模型(测试自己按手册重写; 不复用 kernel/md.lua 的任何函数)
-- ---------------------------------------------------------------
local function bxor(a, b) -- 纯算术异或(宿主 5.1 没有 bit32)
    local r, bit, x, y = 0, 1, a, b
    for _ = 1, 8 do
        if x % 2 ~= y % 2 then r = r + bit end
        x, y, bit = math.floor(x / 2), math.floor(y / 2), bit * 2
    end
    return r
end

local function sxor(a, b)
    local out = {}
    for i = 1, #a do out[i] = string.char(bxor(a:byte(i), b:byte(i))) end
    return table.concat(out)
end

--- 独立的 GF(2^8) 乘法: 逐位 double + 0x1d 约简(Russian peasant), 与 md.lua 的 log/exp 表无关。
local function gfmul(a, b)
    local p = 0
    for _ = 1, 8 do
        if b % 2 == 1 then p = bxor(p, a) end
        b = math.floor(b / 2)
        a = a * 2
        if a >= 256 then a = bxor(a - 256, 0x1d) end
    end
    return p
end

local function gfscale(data, k)
    if k == 1 then return data end
    local out = {}
    for i = 1, #data do out[i] = string.char(gfmul(data:byte(i), k)) end
    return table.concat(out)
end

--- 一个阵列的"规格"(测试自己的一组参数 + 角色号 -> 成员文件号的映射, 与内核无关)。
--- layout: raid5/6 的算法编号(0=left-asymmetric 1=right-asymmetric 2=left-symmetric);
--- raid10 用 geo。
local function spec(level, nMembers, chunkSectors, dataOffset, comp, sizeSectors, files, layout, geo)
    return {
        level = level, n = nMembers, chunk = chunkSectors, dataOffset = dataOffset,
        comp = comp, size = sizeSectors, files = files, layout = layout, geo = geo,
        copies = (level == 1) and nMembers or (geo and geo.nc * geo.fc or nil),
        dataDisks = (level == 5) and (nMembers - 1) or (level == 6) and (nMembers - 2) or nMembers,
    }
end

--- 从 md 的阵列信息里取"角色号 -> 成员文件号"(roles 的顺序不一定是文件号的顺序:
--- 换过盘的阵列里, 新盘是后面那个文件号)。
local function filesFrom(info)
    local files = {}
    for _, m in ipairs(info.members) do
        local num = m.dev:match("^/dev/f(%d+)$")
        if num and m.role and m.role >= 0 and m.role < info.raidDisks then
            files[m.role + 1] = tonumber(num)
        end
    end
    return files
end

--- 读成员文件 fileNum(1 起)在成员内扇区 memSector 处的 512 字节(直接读文件, 不经过 md)。
--- 设备号(0 起, 逻辑视图)与文件号(1 起)差一, 这里统一收**文件号**, 调用点写 +1 —— 踩过一次。
local function rawSector(s, dev, memSector)
    assert(dev >= 1, "rawSector wants a 1-based member file number, got " .. tostring(dev))
    local f = assert(io.open(memberPath(dev), "rb"))
    f:seek("set", memSector * 512)
    local d = f:read(512)
    f:close()
    assert(d and #d == 512, "short read")
    return d
end

--- RAID5/6 的条带布局(测试版: 按 raid5.c 的手册重新推导 LA/RA/LS/RS 四种算法的 P/Q 位置与
--- 数据落位; 内核里是另一份代码, 两边独立)。
local function stripeInfo(s, t)
    local n, dd, level, algo = s.n, s.dataDisks, s.level, s.layout or 2
    local S = t % n
    local pd, qd, dev = -1, -1, {}
    if level == 5 then
        if algo == 0 then                          -- left-asymmetric
            pd = dd - S
            for k = 0, dd - 1 do dev[k] = (k >= pd) and (k + 1) or k end
        elseif algo == 1 then                      -- right-asymmetric
            pd = S
            for k = 0, dd - 1 do dev[k] = (k >= pd) and (k + 1) or k end
        elseif algo == 2 then                      -- left-symmetric(默认)
            pd = dd - S
            for k = 0, dd - 1 do dev[k] = (pd + 1 + k) % n end
        elseif algo == 3 then                      -- right-symmetric
            pd = S
            for k = 0, dd - 1 do dev[k] = (pd + 1 + k) % n end
        else
            error("test model: unsupported raid5 layout " .. tostring(algo))
        end
    else
        if algo == 0 or algo == 1 then
            pd = (algo == 0) and (n - 1 - S) or S
            if pd == n - 1 then
                qd = 0
                for k = 0, dd - 1 do dev[k] = k + 1 end
            else
                qd = pd + 1
                for k = 0, dd - 1 do dev[k] = (k >= pd) and (k + 2) or k end
            end
        elseif algo == 2 or algo == 3 then
            pd = (algo == 2) and (n - 1 - S) or S
            qd = (pd + 1) % n
            for k = 0, dd - 1 do dev[k] = (pd + 2 + k) % n end
        else
            error("test model: unsupported raid6 layout " .. tostring(algo))
        end
    end
    return pd, qd, dev
end

--- RAID6 的 Q 系数位置(从 Q 之后那块盘起环行数数据块)。
local function syndromePos(s, pd, qd, dev)
    local pos, d, idx = {}, (qd == s.n - 1) and 0 or (qd + 1), 0
    for _ = 1, s.n do
        if d ~= pd and d ~= qd then
            for k = 0, s.dataDisks - 1 do
                if dev[k] == d then pos[k] = idx end
            end
            idx = idx + 1
        end
        d = (d + 1) % s.n
    end
    return pos
end

--- 2^e(独立实现, 逐次 gfmul, 不用任何查表)。
local function gfpow2(e)
    local acc = 1
    for _ = 1, e do acc = gfmul(acc, 2) end
    return acc
end

--- 一块数据扇区(写进阵列的模式)。
local function patternSector(sec)
    local out = {}
    for i = 0, 511 do out[i + 1] = string.char((sec * 31 + i * 7 + 11) % 251) end
    return table.concat(out)
end

local function patternRange(from, count)
    local out = {}
    for i = 0, count - 1 do out[i + 1] = patternSector(from + i) end
    return table.concat(out)
end

--- 独立算出某个成员在条带 t 的偏移 o 处**应该**是什么(数据块按写入的模式, 校验块现算)。
--- 用来判定重建出来的新盘内容对不对。
local function expectStripeBlock(s, t, o, d)
    local pd, qd, dev = stripeInfo(s, t)
    local function dataOf(k)
        return patternSector((t * s.dataDisks + k) * s.chunk + o)
    end
    local pos = (s.level == 6) and syndromePos(s, pd, qd, dev) or nil
    local P, Q
    for k = 0, s.dataDisks - 1 do
        local v = dataOf(k)
        P = P and sxor(P, v) or v
        if s.level == 6 then
            Q = Q and sxor(Q, gfscale(v, gfpow2(pos[k]))) or gfscale(v, gfpow2(pos[k]))
        end
    end
    if d == pd then return P end
    if s.level == 6 and d == qd then return Q end
    for k = 0, s.dataDisks - 1 do
        if dev[k] == d then return dataOf(k) end
    end
    return nil
end

--- raid10 的正向放置: 返回逻辑扇区 s 的 { {dev, memSector}, ... }(第一份是真值来源)。
local function place10(s, logSector, geo)
    local nc, fc, fo = geo.nc, geo.fc, geo.fo
    local chunk = math.floor(logSector / s.chunk) * nc
    local offset = logSector % s.chunk
    local dev = chunk % s.n
    local stripe = math.floor(chunk / s.n)
    if fo == 1 then stripe = stripe * fc end
    local sector = offset + stripe * s.chunk
    local out = {}
    for _ = 1, nc do
        local d, sec = dev, sector
        out[#out + 1] = { d, sec }
        for _ = 2, fc do
            d = (d + nc) % s.n
            sec = sec + geo.stride
            out[#out + 1] = { d, sec }
        end
        dev = dev + 1
        if dev >= s.n then
            dev = 0
            sector = sector + s.chunk
        end
    end
    return out
end

--- 从成员镜像拼出逻辑阵列的内容(独立模型; 用于与"写进去的模式"比对)。
local function extract(s, geo)
    local out = {}
    for sec = 0, s.size - 1 do
        if s.level == 0 then
            local c = math.floor(sec / s.chunk)
            local o = sec % s.chunk
            out[#out + 1] = rawSector(s, s.files[c % s.n + 1], s.dataOffset + math.floor(c / s.n) * s.chunk + o)
        elseif s.level == 1 then
            out[#out + 1] = rawSector(s, s.files[1], s.dataOffset + sec)
        elseif s.level == 5 or s.level == 6 then
            local c = math.floor(sec / s.chunk)
            local o = sec % s.chunk
            local k = c % s.dataDisks
            local t = math.floor(c / s.dataDisks)
            local _, _, dev = stripeInfo(s, t)
            out[#out + 1] = rawSector(s, s.files[dev[k] + 1], s.dataOffset + t * s.chunk + o)
        else
            local ph = place10(s, sec, geo)
            out[#out + 1] = rawSector(s, s.files[ph[1][1] + 1], s.dataOffset + ph[1][2])
        end
    end
    return table.concat(out)
end

--- RAID5/6 的校验块独立核对(逐条带逐扇区算 P(/Q), 与成员上的块比对)。
local function checkParity(s, label)
    local bad, checked = 0, 0
    for t = 0, math.floor(s.comp / s.chunk) - 1 do
        local pd, qd, dev = stripeInfo(s, t)
        local pos = (s.level == 6) and syndromePos(s, pd, qd, dev) or nil
        for o = 0, s.chunk - 1 do
            local P, Q
            for k = 0, s.dataDisks - 1 do
                local v = rawSector(s, s.files[dev[k] + 1], s.dataOffset + t * s.chunk + o)
                P = P and sxor(P, v) or v
                if s.level == 6 then
                    local term = gfscale(v, gfpow2(pos[k]))
                    Q = Q and sxor(Q, term) or term
                end
            end
            if rawSector(s, s.files[pd + 1], s.dataOffset + t * s.chunk + o) ~= P then bad = bad + 1 end
            if s.level == 6 then
                if rawSector(s, s.files[qd + 1], s.dataOffset + t * s.chunk + o) ~= Q then bad = bad + 1 end
            end
            checked = checked + 1
        end
    end
    ok(bad == 0, label .. ": 校验块与独立重算一致(" .. checked .. " 条纹偏移)",
        bad .. " 处不一致")
end

-- ---------------------------------------------------------------
-- 用 md 的块设备视图读写阵列
-- ---------------------------------------------------------------
local function arrayBd(name)
    local t, err = devdisk.target("/dev/" .. name)
    assert(t, err)
    return t.openBd("r+")
end

local function writePattern(name, sizeSectors)
    local bd = arrayBd(name)
    for sec = 0, sizeSectors - 1 do
        local okw, err = bd.write(sec * 512, patternSector(sec))
        assert(okw, err)
    end
    bd.close()
end

local function readAll(name, sizeSectors)
    local bd = arrayBd(name)
    local parts = {}
    for sec = 0, sizeSectors - 1 do
        local v, err = bd.read(sec * 512, 512)
        assert(v, err)
        parts[#parts + 1] = v
    end
    bd.close()
    return table.concat(parts)
end

-- ---------------------------------------------------------------
-- 环境准备
-- ---------------------------------------------------------------
os.execute("rm -rf '" .. ROOT .. "'")
os.execute("mkdir -p '" .. MEMDIR .. "'")

local MEM_SIZE = 128 * 1024        -- 每个成员 128KB
local NODE = 0
local function newNode()
    NODE = NODE + 1
    makeMember(NODE, MEM_SIZE)
    registerMember(NODE)
    return "/dev/f" .. NODE
end
local function freshMember()
    NODE = NODE + 1
    makeMember(NODE, MEM_SIZE, "\255")   -- 新盘里全是垃圾(0xff), 用来验证重建确实覆盖了它
    registerMember(NODE)
    return "/dev/f" .. NODE, NODE
end

--- 取 n 块新成员(每块都是全新的 128KB 空镜像)。
local function take(n)
    local t = {}
    for i = 1, n do t[i] = newNode() end
    return t
end

-- ---------------------------------------------------------------
-- 1) 各级别: 创建 -> 写模式 -> 独立模型核对 -> 校验块核对 -> 读回
-- ---------------------------------------------------------------
local CASES = {
    { level = 1,  name = "raid1",  n = 2, layout = nil, chunk = 8 },
    { level = 0,  name = "raid0",  n = 2, layout = nil, chunk = 8 },
    { level = 5,  name = "raid5",  n = 3, layout = nil, chunk = 8 },
    { level = 6,  name = "raid6",  n = 4, layout = nil, chunk = 8 },
    { level = 10, name = "raid10", n = 4, layout = nil, chunk = 8 },
    { level = 5,  name = "raid5la", n = 3, layout = 0, chunk = 16 },
    { level = 6,  name = "raid6ra", n = 4, layout = 1, chunk = 16 },
    { level = 10, name = "raid10f2", n = 4, layout = 513, chunk = 8 },  -- f2
}

for ci, c in ipairs(CASES) do
    local devs = take(c.n)
    local info, err = md.create({
        name = c.name, level = c.level, layout = c.layout, chunk = c.chunk,
        devices = devs, force = true,
    })
    ok(info ~= nil, c.name .. ": 创建成功(" .. c.level .. ")", err)
    if info then
        local geo
        if c.level == 10 then
            local layout = c.layout or 258
            geo = { nc = layout % 256, fc = math.floor(layout / 256) % 256, fo = math.floor(layout / 65536) % 2 }
            if geo.nc == 0 then geo.nc = 1 end
            if geo.fc == 0 then geo.fc = 1 end
            -- stride 与内核一致: far_offset 时 = 1 chunk, 否则 = 每盘 chunk 数 / far
            local size = math.floor(math.floor(info.componentSectors / c.chunk) / geo.fc) * c.n
            size = math.floor(size / geo.nc)
            local usedChunks = math.ceil(size * geo.nc * geo.fc / c.n)
            geo.stride = (geo.fo == 1) and c.chunk or (math.floor(usedChunks / geo.fc) * c.chunk)
        end
        local layout = c.layout
        if c.level == 5 or c.level == 6 then layout = layout or 2 end
        local s = spec(c.level, c.n, c.chunk, info.dataOffsetSectors, info.componentSectors,
            info.sizeSectors, filesFrom(info), layout, geo)

        -- 复数: 级别 1 的副本 = 成员数
        eq(info.state, "clean", c.name .. ": 状态 clean")
        eq(info.degraded, 0, c.name .. ": 无缺员")

        writePattern(c.name, info.sizeSectors)

        -- ① 读回往返
        local got = readAll(c.name, info.sizeSectors)
        eq(got, patternRange(0, info.sizeSectors), c.name .. ": 读回与写入一致("
            .. info.sizeSectors .. " 扇区)")

        -- ② 独立模型
        local extracted = extract(s, geo)
        eq(extracted, patternRange(0, info.sizeSectors), c.name .. ": 独立布局模型与逻辑阵列一致")

        -- ③ 校验块独立核对
        if c.level == 5 or c.level == 6 then
            checkParity(s, c.name)
        end

        -- ⑨ blkid/lsblk 看得到这个设备节点
        local found
        for _, e in ipairs(devdisk.list()) do
            if e.name == c.name then found = e end
        end
        ok(found ~= nil and found.type == "raid" and found.raidLevel == md.levelName(c.level),
            c.name .. ": devdisk 里是 raid 节点(" .. md.levelName(c.level) .. ")",
            found and tostring(found.type) .. "/" .. tostring(found.raidLevel))
    end
end

-- ---------------------------------------------------------------
-- 2) 降级: --fail 一块盘后数据仍可读(重建路径), 且坏盘内容被破坏也不影响
-- ---------------------------------------------------------------
do
    local name, level, n = "degrade5", 5, 3
    local devs = take(n)
    local info = md.create({ name = name, level = level, chunk = 8, devices = devs, force = true })
    ok(info ~= nil, "degrade5: 创建 raid5")
    writePattern(name, info.sizeSectors)
    local target = devs[2]
    local bd = devdisk.target(target).openBd("r+")
    local okf, ferr = md.fail(name, target)
    ok(okf == true, "degrade5: --fail 成功", ferr)
    -- 物理损坏那块盘(读的时候必须完全绕过它)
    for sec = 0, math.floor(MEM_SIZE / 512) - 1 do bd.write(sec * 512, string.rep("\0", 512)) end
    bd.close()
    local info2 = md.detail(name)
    eq(info2.degraded, 1, "degrade5: 降级后 degraded=1")
    eq(info2.state, "degraded", "degrade5: 状态 degraded")
    local got = readAll(name, info.sizeSectors)
    eq(got, patternRange(0, info.sizeSectors), "degrade5: 缺一块盘仍能重建读出全部数据")

    -- 再失败一块: raid5 容不下。映射到故障盘的扇区必须 fail-fast 报错, 映射到健康盘的照常读。
    md.fail(name, devs[3])
    local s2 = spec(5, 3, 8, info.dataOffsetSectors, info.componentSectors, info.sizeSectors,
        filesFrom(md.detail(name)), 2)
    local bd3 = arrayBd(name)
    local errors, okRead, wrong = 0, 0, 0
    for sec = 0, info.sizeSectors - 1 do
        local want = patternSector(sec)
        local got = bd3.read(sec * 512, 512)
        local c = math.floor(sec / s2.chunk)
        local k = c % s2.dataDisks
        local t = math.floor(c / s2.dataDisks)
        local _, _, dev = stripeInfo(s2, t)
        local missing = (dev[k] == 1) or (dev[k] == 2)      -- 角色 1、2 已故障
        if got == nil then errors = errors + 1
        elseif missing then wrong = wrong + 1
        elseif got == want then okRead = okRead + 1
        else wrong = wrong + 1 end
    end
    bd3.close()
    ok(errors > 0 and wrong == 0,
        "degrade5: 缺两块盘时只有落在故障盘上的扇区失败, 且绝不返回错数据",
        "errors=" .. errors .. " ok=" .. okRead .. " wrong=" .. wrong)
    md.remove(name, devs[2], true)
    md.remove(name, devs[3], true)
    md.stop(name)
end

-- ---------------------------------------------------------------
-- 3) 重建: --add 一块新盘, 心跳推进重建, 完成后内容与模型一致
-- ---------------------------------------------------------------
do
    local name, n = "rebuild6", 4
    local devs = take(n)
    local info = md.create({ name = name, level = 6, chunk = 8, devices = devs, force = true })
    writePattern(name, info.sizeSectors)
    md.fail(name, devs[3])
    md.remove(name, devs[3])
    local newDev, newNodeIdx = freshMember()
    local okAdd, aerr = md.add(name, newDev)
    ok(okAdd == true, "rebuild6: --add 新盘成功", aerr)
    local infoA = md.detail(name)
    ok(infoA.resync ~= nil and infoA.resync.type == "recovery", "rebuild6: 重建已开始")
    -- 心跳推进(真机上是调度器 0.05s 心跳; 宿主直接循环调)
    local guard = 0
    while md.detail(name).resync do
        md.tick()
        guard = guard + 1
        if guard > 100000 then break end
    end
    ok(guard <= 100000, "rebuild6: 重建在有限拍内完成(" .. guard .. " 拍)")
    local infoB = md.detail(name)
    eq(infoB.degraded, 0, "rebuild6: 重建后不再降级")
    eq(infoB.state, "clean", "rebuild6: 重建后状态 clean")
    -- 新盘的内容必须与独立模型算出来的一致(逐块重算该成员在这一条带上应有的值)
    local role
    for _, m in ipairs(infoB.members) do
        if m.dev == newDev then role = m.role end
    end
    ok(role ~= nil, "rebuild6: 新盘拿到了一个角色槽位", tostring(role))
    local s = spec(6, 4, 8, infoB.dataOffsetSectors, infoB.componentSectors, infoB.sizeSectors,
        filesFrom(infoB), 2)
    eq(s.files[role + 1], newNodeIdx, "rebuild6: 角色 -> 新盘的映射正确")
    local badBlocks = 0
    for t = 0, math.floor(s.comp / s.chunk) - 1 do
        for o = 0, s.chunk - 1 do
            local want = expectStripeBlock(s, t, o, role)
            local got = rawSector(s, newNodeIdx, s.dataOffset + t * s.chunk + o)
            if want ~= got then badBlocks = badBlocks + 1 end
        end
    end
    ok(badBlocks == 0, "rebuild6: 重建出来的新盘逐块与独立模型一致", badBlocks .. " 块不一致")
    local got = readAll(name, infoB.sizeSectors)
    eq(got, patternRange(0, infoB.sizeSectors), "rebuild6: 重建后阵列数据完好(读回与写入一致)")
    checkParity(s, "rebuild6")
    -- 新加入的成员文件里不能再是 0xff 填充(重建确实写了)
    local f = assert(io.open(memberPath(newNodeIdx), "rb"))
    f:seek("set", infoB.dataOffsetSectors * 512)
    local head = f:read(512); f:close()
    ok(head ~= string.rep("\255", 512), "rebuild6: 新盘的数据区被重建覆盖(不再是填充值)")

    -- 停机 -> 组装: 内容与状态必须与停机前一致
    md.stop(name)
    local res, aerr2 = md.assemble({ name = name, devices = devs })
    ok(res ~= nil, "rebuild6: 停机后能重新组装", aerr2)
    if res then
        local got2 = readAll(name, infoB.sizeSectors)
        eq(got2, patternRange(0, infoB.sizeSectors), "rebuild6: 组装后数据不变")
    end
    md.stop(name)
end

-- ---------------------------------------------------------------
-- 4) 组装规则: 降级 + 不干净要 --run(mdadm 的 "cannot start dirty degraded array")
-- ---------------------------------------------------------------
do
    local name, n = "dirty1", 2
    local devs = take(n)
    local info = md.create({ name = name, level = 1, devices = devs, force = true })
    writePattern(name, info.sizeSectors)
    md.fail(name, devs[2])
    md.stop(name)
    local res, err = md.assemble({ name = name, devices = devs })
    ok(res == nil and tostring(err):find("--run", 1, true) ~= nil,
        "dirty1: 降级且不干净时拒绝组装并提示 --run", err)
    local res2, err2 = md.assemble({ name = name, devices = devs, run = true })
    ok(res2 ~= nil, "dirty1: 给了 --run 就能起", err2)
    if res2 then
        local got = readAll(name, info.sizeSectors)
        eq(got, patternRange(0, info.sizeSectors), "dirty1: 降级组装的阵列数据完好")
    end
    md.stop(name)
end

-- ---------------------------------------------------------------
-- 5) 超级块: --examine 的形状/校验和/角色, --zero-superblock
-- ---------------------------------------------------------------
do
    local name, n = "sbcheck", 3
    local devs = take(n)
    local info = md.create({ name = name, level = 5, chunk = 8, devices = devs, force = true })
    local e, err = md.examine(devs[1])
    ok(e ~= nil, "examine: 能读到超级块", err)
    if e then
        eq(e.magic, "a92b4efc", "examine: magic = a92b4efc")
        eq(e.version, "1.2", "examine: version 1.2")
        eq(e.checksumOk, true, "examine: 校验和正确")
        eq(e.raidDisks, 3, "examine: raid_disks = 3")
        eq(e.levelName, "raid5", "examine: level = raid5")
        eq(e.dataOffset, 16, "examine: data_offset = 16 扇区(8K)")
        eq(e.arrayState, "AAA", "examine: 阵列状态 AAA")
        eq(e.role, "Active device 0", "examine: 角色 = Active device 0")
    end
    eq(info.levelName, "raid5", "info: levelName = raid5")
    ok(md.mdstat():find("Personalities : ") ~= nil, "mdstat: 有 Personalities 行")
    ok(md.mdstat():find("sbcheck : active raid5", 1, true) ~= nil, "mdstat: 阵列行")
    ok(md.mdstat():find("[3/3] [UUU]", 1, true) ~= nil, "mdstat: 全部在同步 [UUU]")
    md.stop(name)
    local okz, zerr = md.zeroSuperblock(devs[1])
    ok(okz == true, "zero-superblock: 抹掉超级块", zerr)
    local e2 = md.examine(devs[1])
    ok(e2 == nil, "zero-superblock: 之后 examine 报没有超级块")
end

-- ---------------------------------------------------------------
-- 6) /etc/mdadm.conf: --detail --scan 的输出能被 --assemble --scan 读回
-- ---------------------------------------------------------------
do
    local name, n = "cfgarr", 2
    local devs = take(n)
    local info = md.create({ name = name, level = 1, devices = devs, force = true })
    writePattern(name, info.sizeSectors)
    md.stop(name)
    os.execute("mkdir -p '" .. ROOT .. "/etc'")
    local cfg = assert(io.open(ROOT .. "/etc/mdadm.conf", "w"))
    cfg:write("ARRAY " .. info.node .. " metadata=1.2 name=" .. info.name
        .. " UUID=" .. info.uuid .. "\n")
    cfg:close()
    local entries, cerr = md.readConfig("/etc/mdadm.conf")
    ok(entries ~= nil and #entries == 1, "mdadm.conf: 解析出一条 ARRAY", cerr)
    if entries then
        eq(entries[1].uuid, info.uuid, "mdadm.conf: uuid 解析正确")
        eq(entries[1].dev, info.node, "mdadm.conf: 阵列设备解析正确")
    end
    -- --scan 走的是 devdisk 里全部 part 设备: 这里注册过的成员都在
    local res, err = md.assemble({ scan = true })
    ok(res ~= nil, "--assemble --scan 按配置组装成功", err)
    if res then
        local got = readAll(name, info.sizeSectors)
        eq(got, patternRange(0, info.sizeSectors), "--assemble --scan: 数据完好")
    end
    md.stop(name)
    -- 没有 ARRAY 行时: 不算错误, 但什么都不做(开机自动组装必须能空手而归)
    local cfg2 = assert(io.open(ROOT .. "/etc/mdadm.conf", "w"))
    cfg2:write("# empty\n")
    cfg2:close()
    local res2, err2 = md.assemble({ scan = true })
    ok(res2 == nil and tostring(err2):find("nothing to assemble", 1, true) ~= nil,
        "--assemble --scan 空配置 = 无事可做", err2)
end

-- ---------------------------------------------------------------
-- 7) 端到端: mkfs.ext2 落在阵列上, 抽回镜像交给宿主 e2fsck 判干净
-- ---------------------------------------------------------------
local function extractToFile(s, geo, path)
    local data = extract(s, geo)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local E2_CASES = {
    { level = 1, name = "fs1", n = 2 },
    { level = 0, name = "fs0", n = 2 },
    { level = 5, name = "fs5", n = 3 },
    { level = 6, name = "fs6", n = 4 },
    { level = 10, name = "fs10", n = 4 },
}
for ci, c in ipairs(E2_CASES) do
    local devs = take(c.n)
    local info = md.create({ name = c.name, level = c.level, chunk = 8, devices = devs, force = true })
    ok(info ~= nil, c.name .. ": 创建(给 mkfs 用)")
    local mk, mkerr = devdisk.mkfs("/dev/" .. c.name, { force = true, label = "MD" })
    ok(mk ~= nil, c.name .. ": mkfs.ext2 在阵列上成功", mkerr)
    if mk then
        local geo
        if c.level == 10 then
            local layout = 258
            geo = { nc = 2, fc = 1, fo = 0 }
            local size = math.floor(math.floor(info.componentSectors / 8) / geo.fc) * c.n
            size = math.floor(size / geo.nc)
            local usedChunks = math.ceil(size * geo.nc * geo.fc / c.n)
            geo.stride = math.floor(usedChunks / geo.fc) * 8
        end
        local layout = (c.level == 5 or c.level == 6) and 2 or nil
        local s = spec(c.level, c.n, 8, info.dataOffsetSectors, info.componentSectors,
            info.sizeSectors, filesFrom(info), layout, geo)
        local img = ROOT .. "/" .. c.name .. ".img"
        extractToFile(s, geo, img)
        local p = io.popen(E2FSCK .. " -fn '" .. img .. "' 2>&1")
        local e2out = p:read("*a")
        local e2rc = p:close()
        -- e2fsck: 0 = 干净; 1 = 有错(不算干净); 2+ = 用法/崩溃
        local clean = (e2rc == 0 or e2rc == true)
        ok(clean, c.name .. ": e2fsck 判定镜像干净(第三方裁判)", e2out)
        -- 抽回镜像的字节必须与"从阵列读回"的一致
        local fromArray = readAll(c.name, info.sizeSectors)
        local f = assert(io.open(img, "rb"))
        local fromMembers = f:read("*a")
        f:close()
        eq(fromArray, fromMembers, c.name .. ": 独立模型抽出的镜像 == 阵列读回的内容")
    end
    md.stop(c.name)
end

-- ---------------------------------------------------------------
-- 8) 拒绝规则: 已有 ext2 不给 --force 不让建; 挂载中的不给 --stop
-- ---------------------------------------------------------------
do
    -- (a) 成员设备自己就是一个 ext2 文件系统(直接 mkfs 到成员节点上): 不给 --force 必须拒绝
    local devs = take(2)
    local mk = devdisk.mkfs(devs[1], { force = true })
    assert(mk, "mkfs on member failed")
    local info, err = md.create({ name = "busy1", level = 1, devices = devs })
    ok(info == nil and tostring(err):find("ext2", 1, true) ~= nil,
        "拒绝: 成员上有 ext2 且没给 --force", err)
    local info3 = md.create({ name = "busy1", level = 1, devices = devs, force = true })
    ok(info3 ~= nil, "给了 --force 就能覆盖", info3 == nil and "create failed" or nil)
    -- (b) 成员上已有 md 超级块(上一次用过的盘): 同样要 --force
    md.stop("busy1")
    local infoE, errE = md.create({ name = "busy1", level = 1, devices = devs })
    ok(infoE == nil and tostring(errE):find("md array", 1, true) ~= nil,
        "拒绝: 成员上有 md 超级块且没给 --force", errE)
    local infoF = md.create({ name = "busy1", level = 1, devices = devs, force = true })
    ok(infoF ~= nil, "给了 --force 就能重建", infoF == nil and "create failed" or nil)
    -- 挂载中的阵列不给 stop
    local vfs = require("kernel.vfs")
    local backend = vfs.virtual({ exists = function() return true end, isDir = function() return false end })
    vfs.mount("/mnt", backend, { device = "/dev/busy1", fstype = "ext2" })
    local _, serr = md.stop("busy1")
    ok(serr ~= nil and tostring(serr):find("mounted", 1, true) ~= nil,
        "拒绝: 挂载中的阵列不给 stop", serr)
    vfs.unmount("/mnt")
    md.stop("busy1")
end

-- ---------------------------------------------------------------
-- 9) 不支持的东西: fail-fast
-- ---------------------------------------------------------------
do
    local devs = take(2)
    local info, err = md.create({ name = "bad1", level = 4, devices = devs })
    ok(info == nil and tostring(err):find("unsupported raid level", 1, true) ~= nil,
        "fail-fast: raid4 不支持", err)
    local info2, err2 = md.create({ name = "bad1", level = 1, metadata = "0.90", devices = devs })
    ok(info2 == nil and tostring(err2):find("1.2", 1, true) ~= nil,
        "fail-fast: 只支持 1.2 元数据", err2)
    local info3, err3 = md.create({ name = "bad1", level = 10, layout = 2 ^ 17, devices = devs })
    ok(info3 == nil and tostring(err3):find("not supported", 1, true) ~= nil,
        "fail-fast: raid10 的非原版布局变体", err3)
    local one = take(1)
    local info4, err4 = md.create({ name = "bad1", level = 5, devices = one })
    ok(info4 == nil and tostring(err4):find("at least", 1, true) ~= nil,
        "fail-fast: 设备数不够", err4)
    local info5, err5 = md.create({ name = "bad1", level = 0, devices = one })
    ok(info5 == nil, "fail-fast: raid0 至少两块盘", err5)
end

-- ---------------------------------------------------------------
-- 10) 内核日志里留下了关键事件(降级/重建的痕迹)
-- ---------------------------------------------------------------
do
    local text = table.concat(kernLog, "\n")
    ok(text:find("active with", 1, true) ~= nil, "klog: 阵列启动有记录")
    ok(text:find("rebuilding", 1, true) ~= nil, "klog: 重建有记录")
    ok(text:find("marked faulty", 1, true) ~= nil, "klog: 故障标记有记录")
end

io.write(string.format("\nmdtest: %d passed, %d failed\n", pass, fail))
return fail == 0 and 0 or 1
