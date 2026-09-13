--[[ Delin 软RAID(md): Linux md/mdadm 的移植。

     对照物是 mdadm 的 super1.c(1.2 元数据)与内核 drivers/md/raid{0,1,5,6,10}.c:
     超级块字段偏移、条带映射公式、布局编号都照那两份代码写, 偏离逐条记在 for-ai.md。

     **设备模型**: 成员是块设备 —— 与 mkfs/mount 收的规格同一套(/dev/sdXN、UUID=..、
     真实后端上的镜像路径), 由 devdisk.target 解析; 阵列本身经 devdisk.registerNode 注册成
     /dev/mdN, 于是 mount / mkfs.ext2 / fsck.ext2 / blkid / lsblk 不改一行就能用。

     **元数据(mdadm 1.2)**: 成员设备开头 4K 处放 4096 字节超级块(magic 0xa92b4efc,
     major_version 1), 数据区从 data_offset 起。角色表 dev_roles[] 按 dev_number 索引:
     0..raid_disks-1 = 该成员持有的数据槽位, 0xffff 备用, 0xfffe 故障。
     events 计数器是"新鲜度": 组装只认 events 最大的那一批成员 —— 被 --remove 掉的老盘
     因此自动变成过期盘(下次组装只能当备用), 不需要额外的"已移除"标记。

     **数据路径(一律 512 字节扇区)**:
       raid0   条带(original layout): 逻辑 chunk c 落在设备 c % n;
       raid1   写所有可写成员, 读挑一个在同步的成员;
       raid5/6 条带 + P[, Q], 布局算法与 raid5.c 的 raid5_compute_sector 逐行对应;
       raid10  near/far/offset 布局, 与 raid10.c 的 __raid10_find_phys / raid10_find_virt 对应。
     校验写一律 **reconstruct-write**: 读齐同一"条纹内偏移"上的其它数据块 -> 重算 P/Q ->
     写回被改的数据块与 P/Q。于是"新建阵列先全盘 resync 生成校验"这一步不需要了 ——
     校验永远与新写的数据一致。

     **初次同步**: raid1/raid10 每块数据取**第一份副本**为真值拷到其余副本(与 md 的初次
     resync 同义); raid5/6 靠 reconstruct-write, 不需要; raid0 没有冗余。

     **恢复(recovery)**: 给降级阵列 --add 一块盘后, 后台(调度器 0.05s 心跳 -> md.tick)
     按扇区分片重建该成员, 进度写回它超级块的 recovery_offset, 所以中途停机可以接着来。
     心跳钩子里**不能让出**(不在协程上下文), 每 tick 只搬一小片(见 RESYNC_SECTORS)。

     **干净(clean)语义**: 与 md 一样, 超级块的 resync_offset == MaxSector 表示"干净"。
     阵列降级或有成员在重建 -> 不干净: 这时组装一个降级阵列要显式 --run
     (mdadm 的 "cannot start dirty degraded array" 同义)。

     **已知偏离**(for-ai.md 有完整清单): 没有 write-intent bitmap(写不原子, 掉电可能留下
     不一致的校验块); 没有 reshape/--grow; 没有 DDF/PPL/journal; 只做 1.2 元数据;
     数组 UUID 是自造的 128 bit, 与宿主 mdadm 的元数据互不通用 —— CC 上根本没有
     能被 Linux 内核认出来的块设备, 互操作无从谈起, 所以这里只保证**自身闭环**:
     字段布局与算法对照 mdadm/内核源码, 不与真实 mdadm 产物比对。 ]]

local devdisk  = require("kernel.devdisk")
local ext2     = require("kernel.ext2")
local random   = require("kernel.random")
local vfs      = require("kernel.vfs")
local vfs_api  = require("kernel.vfs_api")

local md = {}

-- ---------------------------------------------------------------
-- 常量(mdadm 的 super1.c / mdadm.h / md_p.h)
-- ---------------------------------------------------------------
local SB_MAGIC   = 0xa92b4efc      -- MD_SB_MAGIC
local SB_SECTOR  = 8               -- v1.2: 超级块在设备 4K(= 8 个 512 字节扇区)处
local SB_BYTES   = 4096            -- MAX_SB_SIZE
local MAX_DEVS   = 1920            -- (4096 - 256) / 2
local ROLE_SPARE   = 0xffff        -- MD_DISK_ROLE_SPARE
local ROLE_FAULTY  = 0xfffe        -- MD_DISK_ROLE_FAULTY
local ROLE_JOURNAL = 0xfffd        -- MD_DISK_ROLE_JOURNAL(不支持, 只在解析时认出来)
local MAX_SECTOR   = -1            -- Linux 的 MaxSector: Lua 数字是 double, 0xffffffffffffffff 存不住
local FEATURE_RECOVERY_OFFSET = 2  -- MD_FEATURE_RECOVERY_OFFSET

local LEVEL_NAMES = { [0] = "raid0", [1] = "raid1", [5] = "raid5", [6] = "raid6", [10] = "raid10" }
local LEVEL_BY_NAME = {
    raid0 = 0, raid1 = 1, raid5 = 5, raid6 = 6, raid10 = 10,
    ["0"] = 0, ["1"] = 1, ["5"] = 5, ["6"] = 6, ["10"] = 10,
    stripe = 0, mirror = 1,
}
local MIN_DEVICES = { [0] = 2, [1] = 1, [5] = 2, [6] = 3, [10] = 2 }

-- RAID5/6 布局编号(mdadm.h 的 ALGORITHM_*)
local ALGO_LEFT_ASYMMETRIC  = 0
local ALGO_RIGHT_ASYMMETRIC = 1
local ALGO_LEFT_SYMMETRIC   = 2
local ALGO_RIGHT_SYMMETRIC  = 3
local ALGO_PARITY_0         = 4
local ALGO_PARITY_N         = 5
local ALGO_DDF_ZERO_RESTART = 8
local ALGO_DDF_N_RESTART    = 9
local ALGO_DDF_N_CONTINUE   = 10
local ALGO_LA_6 = 16
local ALGO_RA_6 = 17
local ALGO_LS_6 = 18
local ALGO_RS_6 = 19
local ALGO_P0_6 = 20

local ALGO_NAMES = {
    [ALGO_LEFT_ASYMMETRIC] = "left-asymmetric", [ALGO_RIGHT_ASYMMETRIC] = "right-asymmetric",
    [ALGO_LEFT_SYMMETRIC] = "left-symmetric", [ALGO_RIGHT_SYMMETRIC] = "right-symmetric",
    [ALGO_PARITY_0] = "parity-first", [ALGO_PARITY_N] = "parity-last",
    [ALGO_DDF_ZERO_RESTART] = "ddf-zero-restart", [ALGO_DDF_N_RESTART] = "ddf-n-restart",
    [ALGO_DDF_N_CONTINUE] = "ddf-n-continue",
    [ALGO_LA_6] = "left-asymmetric-6", [ALGO_RA_6] = "right-asymmetric-6",
    [ALGO_LS_6] = "left-symmetric-6", [ALGO_RS_6] = "right-symmetric-6",
    [ALGO_P0_6] = "parity-first-6",
}
-- 布局名 -> 编号(mdadm maps.c 的 r5layout / r6layout / r0layout)
local ALGO_BY_NAME = {
    ["left-asymmetric"] = ALGO_LEFT_ASYMMETRIC, ["right-asymmetric"] = ALGO_RIGHT_ASYMMETRIC,
    ["left-symmetric"] = ALGO_LEFT_SYMMETRIC, ["right-symmetric"] = ALGO_RIGHT_SYMMETRIC,
    la = ALGO_LEFT_ASYMMETRIC, ra = ALGO_RIGHT_ASYMMETRIC,
    ls = ALGO_LEFT_SYMMETRIC, rs = ALGO_RIGHT_SYMMETRIC,
    ["parity-first"] = ALGO_PARITY_0, ["parity-last"] = ALGO_PARITY_N,
    ["left-asymmetric-6"] = ALGO_LA_6, ["right-asymmetric-6"] = ALGO_RA_6,
    ["left-symmetric-6"] = ALGO_LS_6, ["right-symmetric-6"] = ALGO_RS_6,
    ["parity-first-6"] = ALGO_P0_6,
    original = 1, alternate = 2, dangerous = 0,
}

-- 重建每 tick 搬运的扇区数(20Hz 心跳 -> ~640KB/s; CC 的盘 1MB 上下, 一两秒就重建完)
local RESYNC_SECTORS = 64

-- ---------------------------------------------------------------
-- 字节/数字小工具(纯算术: 宿主测试台是 lua5.1, 没有 bit32 —— 与 kernel/chacha20.lua 同一约束)
-- ---------------------------------------------------------------
local CH = {}
for i = 0, 255 do CH[i] = string.char(i) end

local NX = {} -- 半字节异或表: NX[a * 16 + b]
for a = 0, 15 do
    for b = 0, 15 do
        local r, bit, x, y = 0, 1, a, b
        for _ = 1, 4 do
            if x % 2 ~= y % 2 then r = r + bit end
            x, y, bit = math.floor(x / 2), math.floor(y / 2), bit * 2
        end
        NX[a * 16 + b] = r
    end
end

local function xorb(a, b)
    local ah, al = math.floor(a / 16), a % 16
    local bh, bl = math.floor(b / 16), b % 16
    return NX[ah * 16 + bh] * 16 + NX[al * 16 + bl]
end

--- 等长字符串逐字节异或。
local function xorBytes(a, b)
    if a == nil then return b end
    if b == nil then return a end
    local n = #a
    local out = {}
    for i = 1, n do out[i] = CH[xorb(a:byte(i), b:byte(i))] end
    return table.concat(out)
end

-- GF(2^8), 生成多项式 0x11d(与 Linux raid6 相同)
local GEXP, GLOG = {}, {}
do
    local x = 1
    for i = 0, 254 do
        GEXP[i] = x
        GLOG[x] = i
        x = x * 2
        if x >= 256 then x = xorb(x - 256, 0x1d) end
    end
end

local function gfMul(a, b)
    if a == 0 or b == 0 then return 0 end
    return GEXP[(GLOG[a] + GLOG[b]) % 255]
end

local function gfDiv(a, b)
    if a == 0 then return 0 end
    return GEXP[(GLOG[a] - GLOG[b]) % 255]
end

--- 逐字节乘一个 GF 常数(RAID6 的 Q 校验用)。
local function gfScale(data, k)
    if k == 1 then return data end
    if k == 0 then return string.rep("\0", #data) end
    local out = {}
    for i = 1, #data do out[i] = CH[gfMul(data:byte(i), k)] end
    return table.concat(out)
end

--- 逐字节除以一个 GF 常数。
local function gfDivBytes(data, k)
    if k == 1 then return data end
    local out = {}
    for i = 1, #data do out[i] = CH[gfDiv(data:byte(i), k)] end
    return table.concat(out)
end

local function getU16(s, off)
    local a, b = s:byte(off + 1, off + 2)
    if not a or not b then return nil end
    return a + b * 256
end

local function getU32(s, off)
    local a, b, c, d = s:byte(off + 1, off + 4)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function getU64(s, off)
    local lo, hi = getU32(s, off), getU32(s, off + 4)
    if not lo or not hi then return nil end
    if lo == 4294967295 and hi == 4294967295 then return MAX_SECTOR end
    return lo + hi * 4294967296
end

local function setU16(s, off, v)
    v = v % 65536
    return s:sub(1, off) .. CH[v % 256] .. CH[math.floor(v / 256)] .. s:sub(off + 3)
end

local function setU32(s, off, v)
    v = v % 4294967296
    local b1 = v % 256; v = math.floor(v / 256)
    local b2 = v % 256; v = math.floor(v / 256)
    local b3 = v % 256; v = math.floor(v / 256)
    local b4 = v % 256
    return s:sub(1, off) .. CH[b1] .. CH[b2] .. CH[b3] .. CH[b4] .. s:sub(off + 5)
end

local function setU64(s, off, v)
    if v == MAX_SECTOR or v < 0 then
        return s:sub(1, off) .. string.rep("\255", 8) .. s:sub(off + 9)
    end
    return setU32(setU32(s, off, v % 4294967296), off + 4, math.floor(v / 4294967296))
end

-- ---------------------------------------------------------------
-- 超级块(struct mdp_superblock_1, super1.c 的字段偏移)
-- ---------------------------------------------------------------
local SB = {
    magic = 0, major_version = 4, feature_map = 8, pad0 = 12,
    set_uuid = 16, set_name = 32, ctime = 64, level = 72, layout = 76,
    size = 80, chunksize = 88, raid_disks = 92, bitmap_offset = 96,
    data_offset = 128, data_size = 136, super_offset = 144, recovery_offset = 152,
    dev_number = 160, device_uuid = 168, devflags = 184,
    utime = 192, events = 200, resync_offset = 208, sb_csum = 216, max_dev = 220,
}

--- 超级块校验和: **不是** CRC —— super1.c 的 calc_sb_1_csum 是"按 32 位小端字累加再折回 32 位",
--- 范围 sizeof(sb) + max_dev*2 字节(sb_csum 字段本身按 0 参与)。
local function sbChecksum(bytes, maxDev)
    local size = 256 + maxDev * 2
    local sum, i = 0, 0
    while size >= 4 do
        sum = sum + getU32(bytes, i)
        i = i + 4
        size = size - 4
    end
    if size == 2 then sum = sum + getU16(bytes, i) end
    sum = (sum % 4294967296) + math.floor(sum / 4294967296)
    return sum % 4294967296
end

--- 打包 4096 字节超级块。f.roles[i](1 起) = 第 i-1 号 dev_number 的角色。
local function packSuper(f, roles)
    local maxDev = f.max_dev
    local bytes = string.rep("\0", SB_BYTES)
    bytes = setU32(bytes, SB.magic, SB_MAGIC)
    bytes = setU32(bytes, SB.major_version, 1)
    bytes = setU32(bytes, SB.feature_map, f.feature_map or 0)
    bytes = bytes:sub(1, SB.set_uuid) .. f.set_uuid .. bytes:sub(SB.set_uuid + 17)
    local nm = (f.set_name or ""):sub(1, 31)
    bytes = bytes:sub(1, SB.set_name) .. nm
        .. string.rep("\0", 32 - #nm) .. bytes:sub(SB.set_name + 33)
    bytes = setU64(bytes, SB.ctime, f.ctime or 0)
    bytes = setU32(bytes, SB.level, f.level)
    bytes = setU32(bytes, SB.layout, f.layout or 0)
    bytes = setU64(bytes, SB.size, f.size or 0)
    bytes = setU32(bytes, SB.chunksize, f.chunksize or 0)
    bytes = setU32(bytes, SB.raid_disks, f.raid_disks)
    bytes = setU64(bytes, SB.data_offset, f.data_offset)
    bytes = setU64(bytes, SB.data_size, f.data_size or 0)
    bytes = setU64(bytes, SB.super_offset, SB_SECTOR)
    bytes = setU64(bytes, SB.recovery_offset, f.recovery_offset or 0)
    bytes = setU32(bytes, SB.dev_number, f.dev_number)
    if f.device_uuid then
        bytes = bytes:sub(1, SB.device_uuid) .. f.device_uuid .. bytes:sub(SB.device_uuid + 17)
    end
    bytes = setU64(bytes, SB.utime, f.utime or f.ctime or 0)
    bytes = setU64(bytes, SB.events, f.events or 1)
    bytes = setU64(bytes, SB.resync_offset, f.resync_offset)
    bytes = setU32(bytes, SB.max_dev, maxDev)
    for i = 1, maxDev do
        bytes = setU16(bytes, 256 + (i - 1) * 2, roles[i] or ROLE_SPARE)
    end
    return setU32(bytes, SB.sb_csum, sbChecksum(bytes, maxDev))
end

--- 解析超级块; 不是 mdadm 1.2 就返回 nil(故意不带错误消息: 调用方才有"没有超级块"的上下文)。
local function parseSuper(data)
    if not data or #data < 256 then return nil end
    if getU32(data, SB.magic) ~= SB_MAGIC then return nil end
    if getU32(data, SB.major_version) ~= 1 then return nil end
    local maxDev = getU32(data, SB.max_dev)
    if not maxDev or maxDev < 1 or maxDev > MAX_DEVS then return nil end
    if #data < 256 + maxDev * 2 then return nil end
    -- 卷标区是定长 32 字节、以 NUL 补齐: 用 %z 匹配 NUL(模式串里不能写 "\0" —— Lua 的模式
    -- 是按 C 字符串编译的, 内嵌 NUL 会把它截断成 "malformed pattern (missing ']')")。
    local name = data:sub(SB.set_name + 1, SB.set_name + 32):match("^([^%z]*)") or ""
    local roles = {}
    for i = 1, maxDev do roles[i] = getU16(data, 256 + (i - 1) * 2) end
    return {
        max_dev = maxDev,
        feature_map = getU32(data, SB.feature_map),
        set_uuid = data:sub(SB.set_uuid + 1, SB.set_uuid + 16),
        set_name = name,
        ctime = getU64(data, SB.ctime),
        level = getU32(data, SB.level),
        layout = getU32(data, SB.layout),
        size = getU64(data, SB.size),
        chunksize = getU32(data, SB.chunksize),
        raid_disks = getU32(data, SB.raid_disks),
        data_offset = getU64(data, SB.data_offset),
        data_size = getU64(data, SB.data_size),
        super_offset = getU64(data, SB.super_offset),
        recovery_offset = getU64(data, SB.recovery_offset),
        dev_number = getU32(data, SB.dev_number),
        utime = getU64(data, SB.utime),
        events = getU64(data, SB.events),
        resync_offset = getU64(data, SB.resync_offset),
        sb_csum = getU32(data, SB.sb_csum),
        roles = roles,
        raw = data,
    }
end

local function superCsumOk(sb)
    return sbChecksum(setU32(sb.raw, SB.sb_csum, 0), sb.max_dev) == sb.sb_csum
end

--- 16 字节原始 uuid -> "xxxxxxxx:xxxxxxxx:xxxxxxxx:xxxxxxxx"(mdadm 的显示/配置格式)。
local function uuidText(raw)
    local hex = {}
    for i = 1, 16 do hex[i] = string.format("%02x", raw:byte(i)) end
    local parts = {}
    for i = 0, 3 do parts[#parts + 1] = table.concat(hex, "", i * 4 + 1, i * 4 + 4) end
    return table.concat(parts, ":")
end

--- "xxxxxxxx:xxxxxxxx:xxxxxxxx:xxxxxxxx" -> 16 字节原始 uuid(非法返回 nil)。
local function uuidRaw(text)
    if type(text) ~= "string" then return nil end
    local hex = text:gsub(":", "")
    if #hex ~= 32 or hex:find("%X") then return nil end
    local out = {}
    for i = 1, 32, 2 do out[#out + 1] = CH[tonumber(hex:sub(i, i + 1), 16)] end
    return table.concat(out)
end

-- ---------------------------------------------------------------
-- RAID5/6 条带布局(raid5.c: raid5_compute_sector 的逐行移植)
-- ---------------------------------------------------------------
--- 一个条带组的布局: { pd, qd, dataDev = { [k] = 设备号 }, devInfo = { [设备号] = {kind, index} },
---                  pos = { [数据下标] = Q 系数位置 } }。
--- t = 条带组号(raid5.c 里的 stripe2 = 逻辑 chunk 号 / data_disks)。
local function stripeLayout(level, algo, n, dataDisks, t)
    local S = t % n
    local pd, qd = -1, -1
    local dataDev = {}
    if level == 5 then
        if algo == ALGO_LEFT_ASYMMETRIC then
            pd = dataDisks - S
            for k = 0, dataDisks - 1 do dataDev[k] = (k >= pd) and (k + 1) or k end
        elseif algo == ALGO_RIGHT_ASYMMETRIC then
            pd = S
            for k = 0, dataDisks - 1 do dataDev[k] = (k >= pd) and (k + 1) or k end
        elseif algo == ALGO_LEFT_SYMMETRIC then
            pd = dataDisks - S
            for k = 0, dataDisks - 1 do dataDev[k] = (pd + 1 + k) % n end
        elseif algo == ALGO_RIGHT_SYMMETRIC then
            pd = S
            for k = 0, dataDisks - 1 do dataDev[k] = (pd + 1 + k) % n end
        elseif algo == ALGO_PARITY_0 then
            pd = 0
            for k = 0, dataDisks - 1 do dataDev[k] = k + 1 end
        elseif algo == ALGO_PARITY_N then
            pd = dataDisks
            for k = 0, dataDisks - 1 do dataDev[k] = k end
        else
            error("md: unsupported raid5 layout " .. tostring(algo), 0)
        end
    elseif level == 6 then
        local function asym(p)
            if p == n - 1 then
                qd = 0
                for k = 0, dataDisks - 1 do dataDev[k] = k + 1 end
            else
                qd = p + 1
                for k = 0, dataDisks - 1 do dataDev[k] = (k >= p) and (k + 2) or k end
            end
            pd = p
        end
        if algo == ALGO_LEFT_ASYMMETRIC then
            asym(n - 1 - S)
        elseif algo == ALGO_RIGHT_ASYMMETRIC then
            asym(S)
        elseif algo == ALGO_LEFT_SYMMETRIC then
            pd = n - 1 - S
            qd = (pd + 1) % n
            for k = 0, dataDisks - 1 do dataDev[k] = (pd + 2 + k) % n end
        elseif algo == ALGO_RIGHT_SYMMETRIC then
            pd = S
            qd = (pd + 1) % n
            for k = 0, dataDisks - 1 do dataDev[k] = (pd + 2 + k) % n end
        elseif algo == ALGO_PARITY_0 then
            pd, qd = 0, 1
            for k = 0, dataDisks - 1 do dataDev[k] = k + 2 end
        elseif algo == ALGO_PARITY_N then
            pd, qd = dataDisks, dataDisks + 1
            for k = 0, dataDisks - 1 do dataDev[k] = k end
        elseif algo == ALGO_LA_6 then
            pd = dataDisks - (t % (n - 1))
            qd = n - 1
            for k = 0, dataDisks - 1 do dataDev[k] = (k >= pd) and (k + 1) or k end
        elseif algo == ALGO_RA_6 then
            pd = t % (n - 1)
            qd = n - 1
            for k = 0, dataDisks - 1 do dataDev[k] = (k >= pd) and (k + 1) or k end
        elseif algo == ALGO_LS_6 then
            pd = dataDisks - (t % (n - 1))
            qd = n - 1
            for k = 0, dataDisks - 1 do dataDev[k] = (pd + 1 + k) % (n - 1) end
        elseif algo == ALGO_RS_6 then
            pd = t % (n - 1)
            qd = n - 1
            for k = 0, dataDisks - 1 do dataDev[k] = (pd + 1 + k) % (n - 1) end
        elseif algo == ALGO_P0_6 then
            pd, qd = 0, n - 1
            for k = 0, dataDisks - 1 do dataDev[k] = k + 1 end
        else
            error("md: unsupported raid6 layout " .. tostring(algo), 0)
        end
    else
        error("md: stripeLayout: level " .. tostring(level) .. " is not striped", 0)
    end
    local devInfo = {}
    for k = 0, dataDisks - 1 do devInfo[dataDev[k]] = { kind = "data", index = k } end
    devInfo[pd] = { kind = "P" }
    if qd >= 0 then devInfo[qd] = { kind = "Q" } end
    local pos
    if level == 6 then
        -- Q 系数位置: 从 Q 之后那块盘起按设备号环行(raid5.c 的 raid6_d0 / raid6_idx_to_slot)
        pos = {}
        local d0 = (qd == n - 1) and 0 or (qd + 1)
        local d, idx = d0, 0
        repeat
            local info = devInfo[d]
            if info and info.kind == "data" then
                pos[info.index] = idx
                idx = idx + 1
            end
            d = (d + 1) % n
        until d == d0 or idx >= dataDisks
    end
    return { pd = pd, qd = qd, dataDev = dataDev, devInfo = devInfo, pos = pos }
end

--- RAID10 的 layout 解析(mdadm util.c 的 parse_layout_10 编解码)。
--- 返回 copies, near, far, offset; 不支持的 far_set_size 变体直接报错。
local function raid10Geo(layout, n)
    if math.floor(layout / 131072) ~= 0 then
        error("md: raid10 layout variant (layout>>17) is not supported: " .. layout, 0)
    end
    local nc = layout % 256
    local fc = math.floor(layout / 256) % 256
    local fo = math.floor(layout / 65536) % 2
    if nc == 0 then nc = 1 end
    if fc == 0 then fc = 1 end
    -- far_set_size: 原版布局(layout>>17 == 0)取 raid_disks —— 与 raid10.c 的 setup_geo 一致。
    -- last_far_set_start / last_far_set_size 是"最后一段不满的 far set"的起点与长度, 原版布局下
    -- 分别是 0 与 raid_disks(raid10.c: __raid10_find_phys 开头那两行)。
    return {
        n = n, nc = nc, fc = fc, fo = fo, copies = nc * fc,
        farSetSize = n,
        lastFarStart = 0,
        lastFarSize = n,
    }
end

-- ---------------------------------------------------------------
-- 阵列对象
-- ---------------------------------------------------------------
local Array = {}
Array.__index = Array

local arrays = {}   -- name -> Array
local byNode = {}   -- "/dev/md0" -> Array

function md.klog_write(msg)
    if md.klog then md.klog.kern(msg) end
end
local function log(msg) md.klog_write(msg) end

local function memberWritable(m)
    return m ~= nil and (m.state == "active" or m.state == "recovering")
end

local function memberReadable(m)
    return m ~= nil and m.state == "active"
end

function Array:memberByRole(r)
    for _, m in ipairs(self.members) do
        if m.role == r and m.state ~= "spare" then return m end
    end
    return nil
end

function Array:spares()
    local out = {}
    for _, m in ipairs(self.members) do
        if m.state == "spare" then out[#out + 1] = m end
    end
    return out
end

function Array:degradedCount()
    local n = 0
    for r = 0, self.raidDisks - 1 do
        if not memberReadable(self:memberByRole(r)) then n = n + 1 end
    end
    return n
end

--- 阵列当下算不算"干净"(md 的 resync_offset == MaxSector 同义)。
function Array:updateClean()
    self.clean = (self:degradedCount() == 0) and (self.recovering == nil)
end

-- ---------------------------------------------------------------
-- 地址映射
-- ---------------------------------------------------------------
--- 成员内第 sec 个扇区的字节偏移(数据区是从 data_offset 起的)。
--- **单位**: 阵列/成员里的 I/O 一律按 512 字节扇区记账, 而块设备句柄收的是字节偏移 ——
--- 换算只在这一个地方做, 免得散落一地(第一版就是这里漏乘 512, 数据写进了超级块区)。
local function atSector(sec) return sec * 512 end

--- 条带组 t、条纹内偏移 o 处, 成员内的字节偏移。
function Array:_stripeByte(t, o)
    return atSector(self.dataOffsetSectors + t * self.chunkSectors + o)
end

--- RAID0(original layout): 逻辑 chunk c 落在设备 c % n, 设备内偏移 = floor(c / n) * chunk + o。
---@return number dev, number byteOffset
function Array:_mapRaid0(s)
    local c = math.floor(s / self.chunkSectors)
    local o = s % self.chunkSectors
    local dev = c % self.raidDisks
    local group = math.floor(c / self.raidDisks)
    return dev, atSector(self.dataOffsetSectors + group * self.chunkSectors + o)
end

--- RAID5/6: 逻辑扇区 -> 条带组 t, 条纹内偏移 o, 数据下标 k, 设备号, 条带布局。
function Array:_mapStripe(s)
    local chunkOffset = s % self.chunkSectors
    local chunkNumber = math.floor(s / self.chunkSectors)
    local k = chunkNumber % self.dataDisks
    local t = math.floor(chunkNumber / self.dataDisks)
    local info = self:_stripeInfo(t)
    return t, chunkOffset, k, info.dataDev[k], info
end

--- 条带布局缓存(同一段扇区反复落在同一条带组上, 不缓存的话每个扇区都要重算一遍环行)。
function Array:_stripeInfo(t)
    if self._siT == t then return self._si end
    self._si = stripeLayout(self.level, self.layout, self.raidDisks, self.dataDisks, t)
    self._siT = t
    return self._si
end

--- RAID10: 逻辑扇区 -> { {设备号, 成员内扇区}, ... }(raid10.c 的 __raid10_find_phys)。
function Array:_mapRaid10(s)
    local geo = self.geo
    local chunk = math.floor(s / self.chunkSectors) * geo.nc
    local offset = s % self.chunkSectors
    local dev = chunk % geo.n
    local stripe = math.floor(chunk / geo.n)
    if geo.fo == 1 then stripe = stripe * geo.fc end
    local sector = offset + stripe * self.chunkSectors
    local out = {}
    for _ = 1, geo.nc do
        local d, sec = dev, sector
        out[#out + 1] = { d, sec }
        for _ = 2, geo.fc do
            local set = math.floor(d / geo.farSetSize)
            local nd = d + geo.nc
            if geo.n % geo.farSetSize ~= 0 and nd > geo.lastFarStart then
                nd = nd - geo.lastFarStart
                nd = nd % geo.lastFarSize
                nd = nd + geo.lastFarStart
            else
                nd = nd % geo.farSetSize
                nd = nd + geo.farSetSize * set
            end
            sec = sec + geo.stride
            out[#out + 1] = { nd, sec }
            d = nd
        end
        dev = dev + 1
        if dev >= geo.n then
            dev = 0
            sector = sector + self.chunkSectors
        end
    end
    return out
end

--- 反向: (设备号, 成员内扇区) -> 阵列扇区(raid10.c 的 raid10_find_virt), 重建时用。
function Array:_virtRaid10(dev, sector)
    local geo = self.geo
    local farSetStart = math.floor(dev / geo.farSetSize) * geo.farSetSize
    local farSetSize = geo.farSetSize
    if geo.n % geo.farSetSize ~= 0 and dev >= geo.lastFarStart then
        farSetSize = geo.farSetSize + geo.n % geo.farSetSize
        farSetStart = geo.lastFarStart
    end
    local offset = sector % self.chunkSectors
    local chunk
    if geo.fo == 1 then
        chunk = math.floor(sector / self.chunkSectors)
        local fc = chunk % geo.fc
        chunk = math.floor(chunk / geo.fc)
        dev = dev - fc * geo.nc
        if dev < farSetStart then dev = dev + farSetSize end
    else
        while sector >= geo.stride do
            sector = sector - geo.stride
            if dev < geo.nc + farSetStart then
                dev = dev + farSetSize - geo.nc
            else
                dev = dev - geo.nc
            end
        end
        chunk = math.floor(sector / self.chunkSectors)
    end
    local vchunk = math.floor((chunk * geo.n + dev) / geo.nc)
    return vchunk * self.chunkSectors + offset
end

-- ---------------------------------------------------------------
-- 成员读写与条带重建
-- ---------------------------------------------------------------
local function memberRead(m, offset, len)
    return m.bd.read(offset, len)
end

local function memberWrite(m, offset, data)
    return m.bd.write(offset, data)
end

--- 读条带组 t 内"条纹内偏移 o"各块的值(512 字节); 缺失的块现场重建后填进 values。
function Array:_stripeValues(t, o, len)
    len = len or 512
    local info = self:_stripeInfo(t)
    local values = {}
    local missing = {}
    local base = self:_stripeByte(t, o)
    for d = 0, self.raidDisks - 1 do
        local m = self:memberByRole(d)
        if memberReadable(m) then
            local v, err = memberRead(m, base, len)
            if not v then return nil, m.dev .. ": read error: " .. tostring(err) end
            values[d] = v
        else
            missing[#missing + 1] = d
        end
    end
    if #missing > 0 then
        local ok, err = self:_reconstructStripe(info, values, missing, len)
        if not ok then return nil, err end
    end
    return values
end

--- 用 P(/Q) 补出缺失块(raid5.c 的 compute_block / compute_parity 同构); values 就地填充。
function Array:_reconstructStripe(info, values, missing, len)
    local dataDisks = self.dataDisks
    local function dataXor(ex1, ex2)
        local acc
        for k = 0, dataDisks - 1 do
            local dev = info.dataDev[k]
            if dev ~= ex1 and dev ~= ex2 then
                local v = values[dev]
                if not v then return nil end
                acc = xorBytes(acc, v)
            end
        end
        return acc or string.rep("\0", len)
    end
    local function dataQ(ex1, ex2)
        local acc
        for k = 0, dataDisks - 1 do
            local dev = info.dataDev[k]
            if dev ~= ex1 and dev ~= ex2 then
                local v = values[dev]
                if not v then return nil end
                acc = xorBytes(acc, gfScale(v, GEXP[info.pos[k]]))
            end
        end
        return acc or string.rep("\0", len)
    end
    local function isMissing(d)
        for _, x in ipairs(missing) do if x == d then return true end end
        return false
    end

    if self.level == 5 then
        if #missing > 1 then
            return nil, "raid5: " .. #missing .. " devices missing, cannot reconstruct"
        end
        local d = missing[1]
        local kind = info.devInfo[d]
        if kind.kind == "P" then
            -- 缺的是校验盘: P = 所有数据块异或
            values[d] = dataXor()
        else
            -- 缺的是数据块: 该块 = P 异或(其余数据块)
            values[d] = xorBytes(values[info.pd], dataXor(d))
        end
        if not values[d] then return nil, "raid5: cannot rebuild device " .. d end
        return true
    end

    if #missing > 2 then
        return nil, "raid6: " .. #missing .. " devices missing, cannot reconstruct"
    end
    if #missing == 1 then
        local d = missing[1]
        local kind = info.devInfo[d]
        if kind.kind == "P" then
            values[d] = dataXor()
        elseif kind.kind == "Q" then
            values[d] = dataQ()
        elseif not isMissing(info.pd) then
            values[d] = xorBytes(values[info.pd], dataXor(d))
        else
            values[d] = gfDivBytes(xorBytes(values[info.qd], dataQ(d)), GEXP[info.pos[kind.index]])
        end
        if not values[d] then return nil, "raid6: cannot rebuild device " .. d end
        return true
    end

    local d1, d2 = missing[1], missing[2]
    local k1, k2 = info.devInfo[d1], info.devInfo[d2]
    if k1.kind ~= "data" then
        d1, d2, k1, k2 = d2, d1, k2, k1
    end
    if k1.kind ~= "data" then
        -- P 与 Q 都缺: 由数据块现算
        values[info.pd] = dataXor()
        values[info.qd] = dataQ()
        if not values[info.pd] or not values[info.qd] then return nil, "raid6: cannot rebuild P/Q" end
        return true
    end
    if k2.kind == "P" then
        values[d1] = gfDivBytes(xorBytes(values[info.qd], dataQ(d1)), GEXP[info.pos[k1.index]])
        values[info.pd] = dataXor()
        return true
    elseif k2.kind == "Q" then
        values[d1] = xorBytes(values[info.pd], dataXor(d1))
        values[info.qd] = dataQ()
        return true
    end
    -- 两块都是数据块: 解二元一次方程组(raid6.c 的 raid6_2data_recov 同构)
    --   p = X ^ Y ; q = g^pa*X ^ g^pb*Y  ->  X = (q ^ g^pb*p) / (g^pa ^ g^pb),  Y = p ^ X
    local pa, pb = info.pos[k1.index], info.pos[k2.index]
    local sP, sQ = dataXor(d1, d2), dataQ(d1, d2)
    if not sP or not sQ then return nil, "raid6: cannot rebuild two data blocks" end
    local p = xorBytes(values[info.pd], sP)
    local q = xorBytes(values[info.qd], sQ)
    local x = gfDivBytes(xorBytes(q, gfScale(p, GEXP[pb])), xorb(GEXP[pa], GEXP[pb]))
    values[d1] = x
    values[d2] = xorBytes(p, x)
    return true
end

--- 读一个阵列扇区(512 字节), 缺成员时重建。
function Array:_readSector(s)
    local level = self.level
    if level == 1 then
        for r = 0, self.raidDisks - 1 do
            local m = self:memberByRole(r)
            if memberReadable(m) then
                local v, err = memberRead(m, atSector(self.dataOffsetSectors + s), 512)
                if not v then return nil, m.dev .. ": read error: " .. tostring(err) end
                return v
            end
        end
        return nil, self.node .. ": no readable device (array is degraded)"
    elseif level == 0 then
        local dev, off = self:_mapRaid0(s)
        local m = self:memberByRole(dev)
        if not memberReadable(m) then
            return nil, self.node .. ": device " .. dev .. " is missing (raid0 is not redundant)"
        end
        return memberRead(m, off, 512)
    elseif level == 5 or level == 6 then
        local t, o, _, dev = self:_mapStripe(s)
        local m = self:memberByRole(dev)
        if memberReadable(m) then
            local v, err = memberRead(m, self:_stripeByte(t, o), 512)
            if v then return v end
            return nil, m.dev .. ": read error: " .. tostring(err)
        end
        local values, err = self:_stripeValues(t, o, 512)
        if not values then return nil, err end
        local v = values[dev]
        if not v then return nil, self.node .. ": cannot reconstruct device " .. dev end
        return v
    elseif level == 10 then
        for _, ph in ipairs(self:_mapRaid10(s)) do
            local m = self:memberByRole(ph[1])
            if memberReadable(m) then
                local v, err = memberRead(m, atSector(self.dataOffsetSectors + ph[2]), 512)
                if v then return v end
                return nil, m.dev .. ": read error: " .. tostring(err)
            end
        end
        return nil, self.node .. ": no readable copy (array is degraded)"
    end
    return nil, "md: unsupported level " .. tostring(level)
end

--- 一个阵列扇区的所有副本位置(第一份是"真值来源", 初次同步用)。
function Array:_sectorCopies(s)
    if self.level == 1 then
        local out = {}
        for r = 0, self.raidDisks - 1 do
            out[#out + 1] = { r, atSector(self.dataOffsetSectors + s) }
        end
        return out
    end
    if self.level == 10 then
        local out = {}
        for _, ph in ipairs(self:_mapRaid10(s)) do
            out[#out + 1] = { ph[1], atSector(self.dataOffsetSectors + ph[2]) }
        end
        return out
    end
    return nil, "md: level " .. tostring(self.level) .. " has no copies"
end

--- 写一个阵列扇区。校验级别走 reconstruct-write(读齐同偏移的其它数据块再重算 P/Q)。
function Array:_writeSector(s, data)
    local level = self.level
    if level == 1 or level == 10 then
        local wrote = 0
        local copies, err = self:_sectorCopies(s)
        if not copies then return nil, err end
        for _, ph in ipairs(copies) do
            local m = self:memberByRole(ph[1])
            if memberWritable(m) then
                local ok, werr = memberWrite(m, ph[2], data)
                if not ok then return nil, m.dev .. ": write error: " .. tostring(werr) end
                wrote = wrote + 1
            end
        end
        if wrote == 0 then return nil, self.node .. ": no writable device" end
        return true
    elseif level == 0 then
        local dev, off = self:_mapRaid0(s)
        local m = self:memberByRole(dev)
        if not memberWritable(m) then
            return nil, self.node .. ": device " .. dev .. " is missing (raid0 is not redundant)"
        end
        return memberWrite(m, off, data)
    elseif level == 5 or level == 6 then
        local t, o, _, dev, info = self:_mapStripe(s)
        local values, err = self:_stripeValues(t, o, 512)
        if not values then return nil, err end
        values[dev] = data
        local P
        for k = 0, self.dataDisks - 1 do
            local v = values[info.dataDev[k]]
            if not v then return nil, "md: missing data block while writing parity" end
            P = xorBytes(P, v)
        end
        local parities = { { info.pd, P } }
        if level == 6 then
            local Q
            for k = 0, self.dataDisks - 1 do
                Q = xorBytes(Q, gfScale(values[info.dataDev[k]], GEXP[info.pos[k]]))
            end
            parities[#parities + 1] = { info.qd, Q }
        end
        local base = self:_stripeByte(t, o)
        local function put(d, v)
            local m = self:memberByRole(d)
            if memberWritable(m) then
                local ok, werr = memberWrite(m, base, v)
                if not ok then return nil, m.dev .. ": write error: " .. tostring(werr) end
            end
            return true
        end
        local ok, werr = put(dev, data)
        if not ok then return nil, werr end
        for _, p in ipairs(parities) do
            ok, werr = put(p[1], p[2])
            if not ok then return nil, werr end
        end
        return true
    end
    return nil, "md: unsupported level " .. tostring(level)
end

-- ---------------------------------------------------------------
-- 块设备门面(devdisk 的 openBd / ext2 驱动都吃这一套)
-- ---------------------------------------------------------------
function Array:blkdev()
    local self_ = self
    return {
        kind = "md",
        path = self.node,
        blockSize = 512,
        read = function(offset, len)
            if offset % 512 == 0 and len >= 0 then
                if offset + len > self_.sectors * 512 then
                    return nil, self_.node .. ": read beyond end of device"
                end
                local out = {}
                for i = 0, math.floor(len / 512) - 1 do
                    local v, err = self_:_readSector(math.floor(offset / 512) + i)
                    if not v then return nil, err end
                    out[i + 1] = v
                end
                if len % 512 ~= 0 then
                    -- 长度不是整扇区(工具按任意大小读)
                    local v, err = self_:_readSector(math.floor((offset + len) / 512))
                    if not v then return nil, err end
                    out[#out + 1] = v:sub(1, len % 512)
                end
                return table.concat(out)
            end
            return self_:_readUnaligned(offset, len)
        end,
        write = function(offset, data) return self_:_writeUnaligned(offset, data) end,
        getSize = function() return self_.sectors * 512 end,
        close = function() end,
    }
end

--- 非 512 对齐的读: 逐扇区读出后切。
function Array:_readUnaligned(offset, len)
    if len <= 0 then return "" end
    if offset + len > self.sectors * 512 then
        return nil, self.node .. ": read beyond end of device"
    end
    local first = math.floor(offset / 512)
    local last = math.floor((offset + len - 1) / 512)
    local parts = {}
    for s = first, last do
        local v, err = self:_readSector(s)
        if not v then return nil, err end
        parts[#parts + 1] = v
    end
    local data = table.concat(parts)
    local skip = offset - first * 512
    return data:sub(skip + 1, skip + len)
end

--- 写: 整扇区的部分走 _writeSector(校验级别因此永远以整扇区重算 P/Q), 边界扇区做 read-modify-write。
function Array:_writeUnaligned(offset, data)
    if #data == 0 then return true end
    if offset + #data > self.sectors * 512 then
        return nil, self.node .. ": write beyond end of device"
    end
    local first = math.floor(offset / 512)
    local last = math.floor((offset + #data - 1) / 512)
    for s = first, last do
        local base = s * 512
        local from = math.max(offset, base)
        local to = math.min(offset + #data, base + 512)
        local sector
        if from == base and to == base + 512 then
            sector = data:sub(from - offset + 1, to - offset)
        else
            local old, err = self:_readSector(s)
            if not old then return nil, err end
            sector = old:sub(1, from - base) .. data:sub(from - offset + 1, to - offset)
                .. old:sub(to - base + 1)
        end
        local ok, werr = self:_writeSector(s, sector)
        if not ok then return nil, werr end
    end
    return true
end

-- ---------------------------------------------------------------
-- 超级块写回
-- ---------------------------------------------------------------
--- 成员 m 看到的角色表: 只有真正在同步/重建的成员占角色号, 其余(缺失/故障)记 0xfffe/0xffff。
function Array:_roleTable()
    local slots = math.max(self.maxDev or self.raidDisks, self.raidDisks)
    for _, m in ipairs(self.members) do
        slots = math.max(slots, m.devNumber + 1)
    end
    if slots > MAX_DEVS then slots = MAX_DEVS end
    local roles = {}
    for i = 1, slots do roles[i] = ROLE_SPARE end
    for _, m in ipairs(self.members) do
        local r
        if m.state == "active" or m.state == "recovering" then r = m.role
        elseif m.state == "faulty" then r = ROLE_FAULTY
        else r = ROLE_SPARE end
        roles[m.devNumber + 1] = r
    end
    return roles, slots
end

--- 把成员 m 的超级块写回设备。
function Array:_writeSuper(m)
    if not m.bd then return true end    -- 缺失的槽位没有设备可写
    local roles, maxDev = self:_roleTable()
    local resyncOffset = MAX_SECTOR
    if not self.clean or self.recovering then resyncOffset = 0 end
    if m.state == "recovering" and self.recovering and self.recovering.member == m then
        resyncOffset = self.recovering.offset
    end
    local bytes = packSuper({
        feature_map = (m.state == "recovering") and FEATURE_RECOVERY_OFFSET or 0,
        set_uuid = self.setUuid,
        set_name = self.sbName or self.name,
        ctime = self.ctime,
        level = self.level,
        layout = self.layout,
        size = self.componentSectors,
        chunksize = self.chunkSectors,
        raid_disks = self.raidDisks,
        data_offset = self.dataOffsetSectors,
        data_size = math.floor((m.size - self.dataOffsetSectors * 512) / 512),
        dev_number = m.devNumber,
        recovery_offset = (m.state == "active") and MAX_SECTOR or (m.recoveryOffset or 0),
        utime = math.floor((os.epoch and os.epoch("utc") or 0) / 1000),
        events = self.events,
        resync_offset = resyncOffset,
        max_dev = maxDev,
    }, roles)
    local ok, err = m.bd.write(SB_SECTOR * 512, bytes)
    if not ok then return nil, m.dev .. ": cannot write superblock: " .. tostring(err) end
    return true
end

function Array:_writeSupers(skip)
    for _, m in ipairs(self.members) do
        if m ~= skip then
            local ok, err = self:_writeSuper(m)
            if not ok then log("md: " .. self.name .. ": " .. tostring(err)) end
        end
    end
end

--- 成员集合变了(增删/故障)时: events +1(老盘因此过期), 重算 clean, 回写超级块。
function Array:stateChanged(why, skip)
    self.events = self.events + 1
    for _, m in ipairs(self.members) do
        if m.state ~= "spare" then m.events = self.events end
    end
    self:updateClean()
    self:_writeSupers(skip)
    if why then log("md: " .. self.name .. ": " .. why) end
end

-- ---------------------------------------------------------------
-- 恢复(recovery)
-- ---------------------------------------------------------------
--- 成员 d 在成员内扇区 memSector 处应有的内容(从别的成员算出来)。
function Array:_memberSectorValue(d, memSector)
    local level = self.level
    if level == 1 then
        return self:_readSector(memSector - self.dataOffsetSectors)
    elseif level == 5 or level == 6 then
        local rel = memSector - self.dataOffsetSectors
        local t = math.floor(rel / self.chunkSectors)
        local o = rel % self.chunkSectors
        local values, err = self:_stripeValues(t, o, 512)
        if not values then return nil, err end
        local v = values[d]
        if not v then return nil, self.node .. ": cannot rebuild device " .. d end
        return v
    elseif level == 10 then
        return self:_readSector(self:_virtRaid10(d, memSector - self.dataOffsetSectors))
    end
    return nil, "md: level " .. tostring(level) .. " has no redundancy, nothing to recover"
end

--- 推进重建。每 tick 一小片; **不能让出**(调度器心跳里同步调用)。
function Array:_resyncSlice()
    local rec = self.recovering
    if not rec then return end
    local m = rec.member
    local total = self.componentSectors
    local last = math.min(rec.offset + RESYNC_SECTORS, total) - 1
    for sec = rec.offset, last do
        local v, err = self:_memberSectorValue(rec.role, self.dataOffsetSectors + sec)
        if not v then
            log("md: " .. self.name .. ": recovery of " .. m.dev .. " failed: " .. tostring(err))
            self.recovering = nil
            m.state = "faulty"
            self:stateChanged("recovery failed")
            return
        end
        local ok, werr = memberWrite(m, atSector(self.dataOffsetSectors + sec), v)
        if not ok then
            log("md: " .. self.name .. ": recovery write to " .. m.dev .. " failed: " .. tostring(werr))
            self.recovering = nil
            m.state = "faulty"
            self:stateChanged("recovery failed")
            return
        end
    end
    rec.offset = last + 1
    m.recoveryOffset = rec.offset
    -- 每搬完一片就把进度写回该成员的超级块(掉电/停机后还能接着重建)
    self:_writeSuper(m)
    if rec.offset >= total then
        m.state = "active"
        m.recoveryOffset = MAX_SECTOR
        self.recovering = nil
        self:updateClean()
        self.events = self.events + 1
        for _, mm in ipairs(self.members) do
            if mm.state ~= "spare" then mm.events = self.events end
        end
        self:_writeSupers()
        log("md: " .. self.name .. ": recovery of " .. m.dev .. " finished")
    end
end

--- 把备用盘 s 顶到第一个缺员的槽位上, 开始重建。
function Array:assignSpare(s)
    for r = 0, self.raidDisks - 1 do
        local cur = self:memberByRole(r)
        if not memberReadable(cur) then
            if cur and cur.state == "faulty" and cur.bd then
                -- 槽位上还挂着一块(已故障的)盘: 与 md 一样, 得先 --remove 才能 --add 顶上
                return nil, "slot " .. r .. " is held by faulty device " .. cur.dev
                    .. " (remove it first)"
            end
            s.role = r
            s.state = "recovering"
            s.recoveryOffset = 0
            s.events = self.events
            self.recovering = { member = s, role = r, offset = 0 }
            self:stateChanged("rebuilding " .. s.dev .. " into slot " .. r)
            return true
        end
    end
    return nil, "no vacant slot"
end

-- ---------------------------------------------------------------
-- 注册表 / /dev 节点
-- ---------------------------------------------------------------
function md.list()
    local out = {}
    for _, a in pairs(arrays) do out[#out + 1] = a end
    table.sort(out, function(x, y) return x.minor < y.minor end)
    return out
end

function md.get(name) return arrays[name] end

function md.findByNode(node) return byNode[node] end

--- 数组 UUID -> 阵列(供 UUID= 挂载用)。
function md.findByUuid(text)
    local raw = uuidRaw(text)
    if not raw then return nil end
    for _, a in pairs(arrays) do
        if a.setUuid == raw then return a end
    end
    return nil
end

function Array:publish()
    local self_ = self
    devdisk.registerNode({
        name = self.name,
        node = self.node,
        type = "raid",
        raidLevel = md.levelName(self.level),
        -- Delin 只有 ext2 一种块文件系统: 不带 -t 的 mount 按 ext2 走(与 /dev/sdXN 同义)
        fstype = "ext2",
        uuid = uuidText(self.setUuid),
        size = self.sectors * 512,
        openBd = function() return self_:blkdev() end,
        raid = self_,
    })
    byNode[self.node] = self
    log("md: " .. self.node .. " active with " .. self.raidDisks .. " devices ("
        .. md.levelName(self.level) .. ")")
end

function Array:unpublish()
    devdisk.unregisterNode(self.name)
    byNode[self.node] = nil
end

function md.levelName(level)
    return LEVEL_NAMES[level] or ("level" .. tostring(level))
end

function md.levelFromName(s)
    if type(s) ~= "string" then return nil end
    return LEVEL_BY_NAME[s:lower()]
end

-- ---------------------------------------------------------------
-- 尺寸/偏移
-- ---------------------------------------------------------------
--- 数据区起点(扇区): 1.2 的超级块占 4K..8K, 所以最早 16 扇区;
--- 条带级别再向上对齐到 chunk 边界(mdadm 一样, 保证条纹对齐)。
local function dataOffsetFor(level, chunkSectors)
    local base = SB_SECTOR + SB_BYTES / 512      -- 8 + 8 = 16
    if level == 0 or level == 5 or level == 6 or level == 10 then
        return math.ceil(base / chunkSectors) * chunkSectors
    end
    return base
end

--- 成员可用扇区数(取所有出席成员的最小值; 条带级别向下取整到 chunk)。
local function componentSectors(members, level, chunkSectors, dataOffset)
    local min
    for _, m in ipairs(members) do
        if m.bd then
            local avail = math.floor((m.size - dataOffset * 512) / 512)
            if min == nil or avail < min then min = avail end
        end
    end
    if not min then return nil, "no present member device" end
    if level == 0 or level == 5 or level == 6 or level == 10 then
        min = math.floor(min / chunkSectors) * chunkSectors
    end
    if min <= 0 then return nil, "member devices are too small" end
    return min
end

--- 阵列扇区数(raid10 的换算与 raid10.c 的 setup_conf 一致)。
local function arraySectors(level, comp, n, chunkSectors, geo)
    if level == 0 then return comp * n end
    if level == 1 then return comp end
    if level == 5 then return comp * (n - 1) end
    if level == 6 then return comp * (n - 2) end
    if level == 10 then
        local size = math.floor(comp / chunkSectors)
        size = math.floor(size / geo.fc)
        size = size * n
        size = math.floor(size / geo.nc)
        return size * chunkSectors
    end
    error("md: unsupported level " .. tostring(level), 0)
end

--- mdadm 默认 chunk(mdadm.c 的 calc_default_geo): 小设备 4K, 中等 32K, 否则 512K。
--- CC 的存储按 MB 计, 所以默认落点在 4K/32K 两档。
local function defaultChunk(sizeSectors)
    if sizeSectors < 2048 then return 8 end        -- < 1MB: 4K
    if sizeSectors < 2097152 then return 64 end    -- < 1GB: 32K
    return 1024                                    -- 512K
end

-- ---------------------------------------------------------------
-- 成员解析
-- ---------------------------------------------------------------
--- 打开成员设备(解析规格 -> 常开块设备句柄)。
local function openMember(spec)
    local t, err = devdisk.target(spec)
    if not t then return nil, tostring(err) end
    local bd, berr = t.openBd("r+")
    if not bd then return nil, t.node .. ": " .. tostring(berr) end
    local size = bd.getSize and bd.getSize() or nil
    if not size or size < (SB_SECTOR + SB_BYTES / 512) * 512 then
        bd.close()
        return nil, t.node .. ": too small for md metadata"
    end
    return { dev = t.node, bd = bd, size = size }
end

local function closeMember(m)
    if m and m.bd then
        m.bd.close()
        m.bd = nil
    end
end

local function readSuper(m)
    local data = m.bd.read(SB_SECTOR * 512, SB_BYTES)
    return parseSuper(data)
end

--- 成员上有没有"别人的"东西(mdadm 在 --create 时同样拦: 已有 md 超级块 / 已有 ext2)。
local function checkBlank(m, force)
    if force then return true end
    if readSuper(m) then
        return nil, m.dev .. " appears to be part of an md array (use --force to override)"
    end
    if ext2.mount(m.bd) then
        return nil, m.dev .. " appears to contain an ext2 filesystem (use --force to override)"
    end
    return true
end

--- 解析成员规格列表: "missing" 是占位符(mdadm 同此), 表示该槽位没有盘。
local function parseSpecs(specs)
    local out = {}
    for _, s in ipairs(specs or {}) do
        if s == "missing" then
            out[#out + 1] = { dev = "missing", missing = true }
        else
            local m, err = openMember(s)
            if not m then return nil, err end
            out[#out + 1] = m
        end
    end
    return out
end

local function releaseAll(list)
    for _, m in ipairs(list or {}) do closeMember(m) end
end

-- ---------------------------------------------------------------
-- 创建(mdadm --create)
-- ---------------------------------------------------------------
---@param opts table { name, level, layout, chunk, raidDisks, devices, spares, uuid, force, metadata }
function md.create(opts)
    local name = opts.name or "md0"
    local level = md.levelFromName(tostring(opts.level))
    if not level then return nil, "unsupported raid level: " .. tostring(opts.level) end
    if (opts.metadata or "1.2") ~= "1.2" then
        return nil, "only 1.2 metadata is supported (got " .. tostring(opts.metadata) .. ")"
    end
    if arrays[name] then return nil, "/dev/" .. name .. " already exists" end

    local members, err = parseSpecs(opts.devices)
    if not members then return nil, err end
    local spares, serr = parseSpecs(opts.spares)
    if not spares then
        releaseAll(members)
        return nil, serr
    end
    local function abort(msg)
        releaseAll(members)
        releaseAll(spares)
        return nil, msg
    end
    for _, m in ipairs(members) do
        if m.bd then
            local ok, cerr = checkBlank(m, opts.force)
            if not ok then return abort(cerr) end
        end
    end

    local raidDisks = opts.raidDisks or #members
    while #members > raidDisks do
        spares[#spares + 1] = table.remove(members)
    end
    while #members < raidDisks do
        members[#members + 1] = { dev = "missing", missing = true }
    end
    local present = 0
    for _, m in ipairs(members) do if m.bd then present = present + 1 end end
    local minDevs = MIN_DEVICES[level] or 2
    if present < minDevs then
        return abort(md.levelName(level) .. " needs at least " .. minDevs .. " devices")
    end

    local layout, geo, copies
    if level == 5 or level == 6 then
        layout = opts.layout == nil and ALGO_LEFT_SYMMETRIC or opts.layout   -- mdadm 的 "default"
        if layout == ALGO_DDF_ZERO_RESTART or layout == ALGO_DDF_N_RESTART
            or layout == ALGO_DDF_N_CONTINUE then
            return abort("DDF raid layouts are not supported (layout " .. layout .. ")")
        end
    elseif level == 10 then
        layout = opts.layout == nil and 258 or opts.layout                    -- n2
        local ok, g = pcall(raid10Geo, layout, raidDisks)
        if not ok then return abort(g) end
        geo = g
        copies = geo.copies
        if geo.nc * geo.fc > raidDisks then
            return abort("raid10: near copies * far copies (" .. geo.nc * geo.fc
                .. ") exceeds raid-disks (" .. raidDisks .. ")")
        end
        if raidDisks % geo.nc ~= 0 then
            return abort("raid10: raid-disks (" .. raidDisks .. ") must be a multiple of near copies ("
                .. geo.nc .. ")")
        end
    else
        layout = 0
    end

    local chunkSectors = opts.chunk
    if not chunkSectors then
        local total = 0
        for _, m in ipairs(members) do if m.bd then total = total + m.bd.getSize() end end
        chunkSectors = defaultChunk(math.floor(total / 512))
    end
    if chunkSectors < 1 or chunkSectors % 1 ~= 0 then return abort("invalid chunk size") end

    local dataOffset = dataOffsetFor(level, chunkSectors)
    local comp, cerr = componentSectors(members, level, chunkSectors, dataOffset)
    if not comp then return abort(cerr) end
    local dataDisks = raidDisks
    if level == 5 then dataDisks = raidDisks - 1
    elseif level == 6 then dataDisks = raidDisks - 2 end

    local setName = opts.setName or name
    if #setName > 31 then return abort("array name too long (max 31 bytes)") end
    local setUuid = opts.uuid and uuidRaw(opts.uuid) or random.bytes(16)
    if not setUuid then return abort("invalid uuid (want xxxxxxxx:xxxxxxxx:xxxxxxxx:xxxxxxxx)") end

    local now = math.floor((os.epoch and os.epoch("utc") or 0) / 1000)
    local a = setmetatable({
        name = name, node = "/dev/" .. name,
        minor = tonumber(name:match("md(%d+)$")) or 0,
        level = level, layout = layout, chunkSectors = chunkSectors,
        raidDisks = raidDisks, dataDisks = dataDisks, copies = copies, geo = geo,
        dataOffsetSectors = dataOffset, componentSectors = comp,
        sbName = setName, setUuid = setUuid, ctime = now, utime = now, events = 1,
        members = {}, clean = true, recovering = nil,
    }, Array)
    a.sectors = arraySectors(level, comp, raidDisks, chunkSectors, geo)
    -- RAID10 的 stride(raid10.c 的 setup_conf: far_offset 时 = 1 chunk, 否则 = 每盘 chunk 数 / far_copies)
    if level == 10 then
        local size = math.floor(math.floor(comp / chunkSectors) / geo.fc) * raidDisks
        size = math.floor(size / geo.nc)
        local usedChunks = math.ceil(size * copies / raidDisks)
        geo.stride = (geo.fo == 1) and chunkSectors
            or (math.floor(usedChunks / geo.fc) * chunkSectors)
    end

    for i = 1, raidDisks do
        local m = members[i]
        if m.bd then
            m.devNumber = i - 1
            m.role = i - 1
            m.state = "active"
            m.events = a.events
            m.recoveryOffset = MAX_SECTOR
        else
            m.devNumber = i - 1
            m.role = i - 1
            m.state = "faulty"
            m.events = a.events
            m.recoveryOffset = 0
        end
        a.members[#a.members + 1] = m
    end
    local nextSlot = raidDisks
    for _, m in ipairs(spares) do
        if nextSlot >= MAX_DEVS then return abort("too many devices (max " .. MAX_DEVS .. ")") end
        m.devNumber = nextSlot
        m.role = ROLE_SPARE
        m.state = "spare"
        m.events = a.events
        m.recoveryOffset = 0
        nextSlot = nextSlot + 1
        a.members[#a.members + 1] = m
    end
    a.maxDev = nextSlot
    a:updateClean()

    -- 初次同步(raid1/10): 每块数据取第一份副本为真值, 拷到其余副本
    if level == 1 or level == 10 then
        local ok, syncerr = a:_initialSync()
        if not ok then
            a:shutdown()
            return nil, syncerr
        end
    end
    for _, m in ipairs(a.members) do
        local ok, werr = a:_writeSuper(m)
        if not ok then
            a:shutdown()
            return nil, werr
        end
    end

    arrays[name] = a
    a:publish()
    return a:info()
end

--- 初次同步: 逐阵列扇区把第一份副本的内容写到其余副本。
function Array:_initialSync()
    local total = self.sectors
    for s = 0, total - 1 do
        local copies, err = self:_sectorCopies(s)
        if not copies then return nil, err end
        local srcDev, srcOff = copies[1][1], copies[1][2]
        local src = self:memberByRole(srcDev)
        if not src or not src.bd then
            return nil, self.node .. ": source device " .. srcDev .. " is missing"
        end
        local v, rerr = memberRead(src, srcOff, 512)
        if not v then return nil, src.dev .. ": read error: " .. tostring(rerr) end
        local dirty = false
        for i = 2, #copies do
            local m = self:memberByRole(copies[i][1])
            if m and m.bd then
                local ok, werr = memberWrite(m, copies[i][2], v)
                if not ok then return nil, m.dev .. ": write error: " .. tostring(werr) end
                dirty = true
            end
        end
        if dirty and s % 64 == 63 and os.msleep then os.msleep(0) end
    end
    return true
end

function Array:shutdown()
    for _, m in ipairs(self.members) do closeMember(m) end
end

-- ---------------------------------------------------------------
-- 组装(mdadm --assemble)
-- ---------------------------------------------------------------
local function scanDevices()
    local out = {}
    for _, e in ipairs(devdisk.list()) do
        if e.type == "part" then out[#out + 1] = e.node end
    end
    return out
end

--- 由一个 set_uuid 的成员集合建阵列(start 前先把 state 定好)。
local function assembleFrom(name, found, opts)
    local maxEvents = -1
    for _, f in ipairs(found) do
        if (f.sb.events or 0) > maxEvents then maxEvents = f.sb.events or 0 end
    end
    local first = found[1].sb
    local slots, spares = {}, {}
    for _, f in ipairs(found) do
        local sb = f.sb
        local role = sb.roles[sb.dev_number + 1]
        local m = {
            dev = f.dev, bd = f.bd, size = f.size,
            devNumber = sb.dev_number,
            events = sb.events,
            recoveryOffset = sb.recovery_offset,
            resyncOffset = sb.resync_offset,
            role = role, state = "active",
        }
        if (sb.events or 0) < maxEvents then
            -- 过期成员(阵列启动后被 --remove 掉的盘、或中途插回来的旧盘)只能当备用
            m.role, m.state = ROLE_SPARE, "spare"
            spares[#spares + 1] = m
        elseif role == ROLE_SPARE then
            m.state = "spare"
            spares[#spares + 1] = m
        elseif role == ROLE_FAULTY or role == ROLE_JOURNAL or role == nil or role >= sb.raid_disks then
            m.state = "faulty"
            slots[role or -1] = slots[role or -1] or {}
            slots[role or -1][#slots[role or -1] + 1] = m
        else
            slots[role] = slots[role] or {}
            slots[role][#slots[role] + 1] = m
        end
    end

    local level = first.level
    local geo, copies
    if level == 10 then
        local ok, g = pcall(raid10Geo, first.layout, first.raid_disks)
        if not ok then
            for _, f in ipairs(found) do closeMember(f) end
            return nil, g
        end
        geo = g
        copies = geo.copies
        local size = math.floor(math.floor(first.size / first.chunksize) / geo.fc) * first.raid_disks
        size = math.floor(size / geo.nc)
        local usedChunks = math.ceil(size * copies / first.raid_disks)
        geo.stride = (geo.fo == 1) and first.chunksize
            or (math.floor(usedChunks / geo.fc) * first.chunksize)
    end

    local a = setmetatable({
        name = name, node = "/dev/" .. name,
        minor = tonumber(name:match("md(%d+)$")) or 0,
        level = level, layout = first.layout, chunkSectors = first.chunksize,
        raidDisks = first.raid_disks,
        dataDisks = (level == 5) and (first.raid_disks - 1)
            or (level == 6) and (first.raid_disks - 2) or first.raid_disks,
        copies = copies, geo = geo,
        dataOffsetSectors = first.data_offset,
        componentSectors = first.size,
        sbName = first.set_name ~= "" and first.set_name or name,
        setUuid = first.set_uuid, ctime = first.ctime,
        utime = math.floor((os.epoch and os.epoch("utc") or 0) / 1000),
        events = maxEvents, members = {}, clean = true, recovering = nil,
        maxDev = first.max_dev,
    }, Array)
    a.sectors = arraySectors(level, a.componentSectors, a.raidDisks, a.chunkSectors, geo)

    for r = 0, a.raidDisks - 1 do
        local list = slots[r]
        if list and #list > 0 then
            a.members[#a.members + 1] = list[1]
            for i = 2, #list do spares[#spares + 1] = list[i] end
        else
            a.members[#a.members + 1] = { dev = "missing", devNumber = r, role = r,
                state = "faulty", events = maxEvents, recoveryOffset = 0, missing = true }
        end
    end
    for _, m in ipairs(spares) do a.members[#a.members + 1] = m end

    -- 中途被打断的重建: 成员自己在超级块里挂着进度, 接着来
    local resume
    for _, m in ipairs(a.members) do
        if m.state == "active" and m.role < a.raidDisks and m.recoveryOffset ~= MAX_SECTOR then
            m.state = "recovering"
            resume = resume or { member = m, role = m.role, offset = m.recoveryOffset or 0 }
        end
    end
    if resume then a.recovering = resume end
    a:updateClean()

    local degraded = a:degradedCount()
    if level == 0 and degraded > 0 then
        a:shutdown()
        return nil, "/dev/" .. name .. ": raid0 with a missing device cannot start"
    end
    -- 各级别容得下几块盘不在: raid1 留一份就够, raid5 一块, raid6 两块, raid10 每面镜像组
    -- 至少留一份(按 copies-1 保守记账), raid0 一块都不能少。
    local maxDeg = 0
    if level == 1 then maxDeg = a.raidDisks - 1
    elseif level == 5 then maxDeg = 1
    elseif level == 6 then maxDeg = 2
    elseif level == 10 then maxDeg = copies - 1 end
    if degraded > maxDeg then
        a:shutdown()
        return nil, "/dev/" .. name .. ": not enough devices to start (" .. degraded
            .. " missing, " .. md.levelName(level) .. " tolerates " .. maxDeg .. ")"
    end
    if degraded > 0 and not opts.run then
        -- mdadm: 降级 + 元数据说"不干净"时不给起, 要 --run
        local dirty = false
        for _, m in ipairs(a.members) do
            if m.state == "active" and m.resyncOffset ~= MAX_SECTOR then dirty = true end
        end
        if dirty or a.recovering then
            a:shutdown()
            return nil, "/dev/" .. name .. ": cannot start dirty degraded array (use --run)"
        end
    end

    arrays[name] = a
    a:publish()
    -- 有备用盘又有缺员: 直接开始重建(md 组装时也会让 spare 顶上)
    for _, s in ipairs(a:spares()) do
        if a:degradedCount() > 0 then
            local ok, aerr = a:assignSpare(s)
            if not ok then log("md: " .. a.name .. ": spare " .. s.dev .. ": " .. tostring(aerr)) end
        end
    end
    -- 组装 = 阵列启动: events +1(被移除过的老盘由此过期), 重算 clean, 回写
    a:stateChanged()
    return a:info()
end

--- 组装。两种规格(mdadm --assemble):
---   devices 给定 -> 只用这些设备;
---   scan = true  -> 读 mdadm.conf, 逐条 ARRAY 组装。
---@return table[]|nil results, string|nil err
function md.assemble(opts)
    opts = opts or {}
    local entries
    if opts.scan then
        local cfg, cerr = md.readConfig(opts.config or "/etc/mdadm.conf")
        if not cfg then
            return nil, "no mdadm.conf at " .. (opts.config or "/etc/mdadm.conf") .. " (nothing to assemble)"
        end
        if #cfg == 0 then
            return nil, "no ARRAY line in " .. (opts.config or "/etc/mdadm.conf") .. " (nothing to assemble)"
        end
        entries = cfg
    else
        if not opts.name and not opts.uuid then
            return nil, "no identity information available - cannot assemble"
        end
        -- 显式给的阵列名是**节点名**(mdadm --assemble /dev/md0 ...), 不是 mdadm.conf 里那个
        -- 匹配用的元数据 name= —— 两者分开, 否则"名字对不上"会把显式指定的成员全筛掉。
        entries = { { node = opts.name, uuid = opts.uuid, devices = opts.devices } }
    end

    local allDevices = opts.devices and #opts.devices > 0 and opts.devices or scanDevices()

    local done = {}
    for _, ent in ipairs(entries) do
        local wantUuid = ent.uuid and uuidRaw(ent.uuid) or nil
        local devs = (ent.devices and #ent.devices > 0) and ent.devices or allDevices
        local found = {}
        for _, d in ipairs(devs) do
            local t = devdisk.target(d)
            if t then
                local bd = t.openBd("r+")
                if bd then
                    local sb = parseSuper(bd.read(SB_SECTOR * 512, SB_BYTES))
                    local match = sb ~= nil
                    if match and wantUuid then match = (sb.set_uuid == wantUuid) end
                    if match and not wantUuid and #found > 0 then
                        match = (sb.set_uuid == found[1].sb.set_uuid)
                    end
                    -- mdadm.conf 的 name= 是匹配键, 对的是元数据里的 set_name
                    if match and ent.name and (sb.set_name ~= ent.name) then match = false end
                    if match then
                        found[#found + 1] = { dev = t.node, sb = sb, bd = bd,
                            size = bd.getSize and bd.getSize() or nil }
                    else
                        bd.close()
                    end
                end
            end
        end
        if #found == 0 then
            return nil, (ent.dev or ent.name or "?") .. ": no matching device found"
        end
        -- 节点名: 配置里的阵列设备(/dev/md0) 或显式给的 --assemble 目标优先;
        -- 都没有(只有 uuid/name)时取一个空闲 minor。
        local name
        if ent.dev then
            name = md.normalizeName(ent.dev)
        elseif ent.node then
            name = md.normalizeName(ent.node)
        else
            local minor = 0
            while arrays["md" .. minor] do minor = minor + 1 end
            name = "md" .. minor
        end
        if arrays[name] then
            for _, f in ipairs(found) do f.bd.close() end
            return nil, "/dev/" .. name .. " already exists"
        end
        local info, aerr = assembleFrom(name, found, opts)
        if not info then return nil, aerr end
        done[#done + 1] = info
    end
    return done
end

-- ---------------------------------------------------------------
-- /etc/mdadm.conf(mdadm.conf(5) 的子集)
-- ---------------------------------------------------------------
--- 读 mdadm.conf。文件不存在返回 nil; 没有 ARRAY 行返回 {}。
--- 每行 `ARRAY <device> key=value ...`, # 起注释, 键大小写不敏感(mdadm 同)。
--- 支持键: uuid= name= level= num-devices= spares= devices=, 以及认下但不用的
--- metadata=/bitmap=/container=/member=/super-minor=。
function md.readConfig(path)
    local f = md.fs and md.fs.open(path, "r")
    if not f then return nil end
    local text = f.readAll() or ""
    f.close()
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local l = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if l ~= "" then
            local fields = {}
            for w in l:gmatch("%S+") do fields[#fields + 1] = w end
            if fields[1] and fields[1]:upper() == "ARRAY" then
                local ent = { devices = {} }
                for i = 2, #fields do
                    local k, v = fields[i]:match("^([%w%-_]+)=(.*)$")
                    if k then
                        local key = k:lower()
                        if key == "uuid" then ent.uuid = v
                        elseif key == "name" then ent.name = v:gsub("^.*:", "")
                        elseif key == "level" then ent.level = v
                        elseif key == "num-devices" then ent.numDevices = tonumber(v)
                        elseif key == "spares" then ent.spares = tonumber(v)
                        elseif key == "devices" then
                            for d in v:gmatch("[^,]+") do ent.devices[#ent.devices + 1] = d end
                        elseif key == "metadata" or key == "bitmap" or key == "container"
                            or key == "member" or key == "super-minor" then
                            -- 认下来不用(0.90/位图/容器都不支持)
                        else
                            return nil, "unrecognized mdadm.conf key: " .. k
                        end
                    elseif not ent.dev then
                        ent.dev = fields[i]
                    else
                        -- mdadm.conf(5): 位置参数是阵列设备; 多的当名字
                        ent.name = ent.name or fields[i]:gsub("^.*/", "")
                    end
                end
                if not ent.name and ent.dev then ent.name = ent.dev:gsub("^.*/", "") end
                out[#out + 1] = ent
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------
-- 停止 / 增删成员
-- ---------------------------------------------------------------
local function mountedAt(node)
    for _, mt in ipairs(vfs.list()) do
        if mt.meta and mt.meta.device == node then return mt.root end
    end
    return nil
end

--- 停止阵列(mdadm --stop): 成员标干净、写超级块、关句柄、摘掉 /dev/mdN。
function md.stop(name)
    local a = arrays[name]
    if not a then return nil, "/dev/" .. name .. ": no such array" end
    local where = mountedAt(a.node)
    if where then
        return nil, a.node .. " is mounted on " .. where .. " (refusing to stop a mounted array)"
    end
    if a.recovering then
        log("md: " .. a.name .. ": stopped while rebuilding (progress kept in superblock)")
    end
    a.events = a.events + 1
    for _, m in ipairs(a.members) do
        if m.state ~= "spare" then m.events = a.events end
    end
    a:updateClean()
    a:_writeSupers()
    local info = a:info()
    a:shutdown()
    a:unpublish()
    arrays[name] = nil
    log("md: " .. a.node .. " stopped")
    return info
end

--- 标故障(mdadm --fail)。
function md.fail(name, spec)
    local a = arrays[name]
    if not a then return nil, "/dev/" .. name .. ": no such array" end
    local t, err = devdisk.target(spec)
    if not t then return nil, tostring(err) end
    for _, m in ipairs(a.members) do
        if m.dev == t.node then
            if m.state == "faulty" then return nil, m.dev .. " is already marked faulty" end
            if m.state == "spare" then
                return nil, m.dev .. " is a spare (remove it instead)"
            end
            m.state = "faulty"
            if a.recovering and a.recovering.member == m then a.recovering = nil end
            -- 故障盘自己写不进去: 只把它"故障"这件事记在其它成员的超级块上
            a:stateChanged(m.dev .. " marked faulty", m)
            return true
        end
    end
    return nil, t.node .. " is not a member of " .. a.node
end

--- 移除成员(mdadm --remove): 只允许移除已故障的成员(除非 force)。
function md.remove(name, spec, force)
    local a = arrays[name]
    if not a then return nil, "/dev/" .. name .. ": no such array" end
    local t, err = devdisk.target(spec)
    if not t then return nil, tostring(err) end
    for i, m in ipairs(a.members) do
        if m.dev == t.node then
            if m.state == "active" and not force then
                return nil, t.node .. " is still active (use --fail or --force first)"
            end
            if a.recovering and a.recovering.member == m then a.recovering = nil end
            table.remove(a.members, i)
            closeMember(m)
            -- 剩下的成员提升 events: 被移除的盘由此变成过期盘, 下次组装只能当备用
            a:stateChanged(t.node .. " removed")
            return true
        end
    end
    return nil, t.node .. " is not a member of " .. a.node
end

--- 加入成员(mdadm --add): 先当备用; 有缺员就顶上开始重建。
function md.add(name, spec)
    local a = arrays[name]
    if not a then return nil, "/dev/" .. name .. ": no such array" end
    local m, err = openMember(spec)
    if not m then return nil, err end
    for _, mm in ipairs(a.members) do
        if mm.dev == m.dev then
            closeMember(m)
            return nil, m.dev .. " is already a member of " .. a.node
        end
    end
    local sb = readSuper(m)
    if sb then
        if sb.set_uuid ~= a.setUuid then
            closeMember(m)
            return nil, m.dev .. " is part of a different array (uuid " .. uuidText(sb.set_uuid) .. ")"
        end
    else
        local ok, cerr = checkBlank(m, false)
        if not ok then
            closeMember(m)
            return nil, cerr
        end
    end
    if m.size < a.componentSectors * 512 + a.dataOffsetSectors * 512 then
        closeMember(m)
        return nil, m.dev .. ": too small for this array (" .. m.size .. " bytes)"
    end
    local slot = a.raidDisks
    local used = {}
    for _, mm in ipairs(a.members) do used[mm.devNumber] = true end
    while used[slot] do slot = slot + 1 end
    if slot >= MAX_DEVS then
        closeMember(m)
        return nil, "too many devices (max " .. MAX_DEVS .. ")"
    end
    m.devNumber = slot
    m.role = ROLE_SPARE
    m.state = "spare"
    m.events = a.events
    m.recoveryOffset = 0
    a.members[#a.members + 1] = m
    a.maxDev = math.max(a.maxDev or 0, slot + 1)
    a:_writeSuper(m)
    log("md: " .. a.name .. ": " .. m.dev .. " added (spare, slot " .. slot .. ")")
    if a:degradedCount() > 0 then
        return a:assignSpare(m)
    end
    return true
end

-- ---------------------------------------------------------------
-- 查询
-- ---------------------------------------------------------------
function Array:info()
    local members = {}
    for i, m in ipairs(self.members) do
        members[#members + 1] = {
            number = m.devNumber, slot = i - 1, dev = m.dev, role = m.role,
            state = m.state, events = m.events, recoveryOffset = m.recoveryOffset,
            size = m.size,
        }
    end
    local degraded = self:degradedCount()
    local working, failed, spare = 0, 0, 0
    for _, m in ipairs(self.members) do
        if m.state == "active" or m.state == "recovering" then working = working + 1
        elseif m.state == "faulty" and not m.missing then failed = failed + 1
        elseif m.state == "spare" then spare = spare + 1 end
    end
    local state
    if self.recovering then state = "recovering"
    elseif degraded > 0 then state = "degraded"
    else state = "clean" end
    return {
        name = self.name, node = self.node, minor = self.minor,
        level = self.level, levelName = md.levelName(self.level),
        layout = self.layout, uuid = uuidText(self.setUuid), sbName = self.sbName or self.name,
        ctime = self.ctime, utime = self.utime, events = self.events,
        raidDisks = self.raidDisks, dataDisks = self.dataDisks,
        chunkSectors = self.chunkSectors,
        sizeSectors = self.sectors, componentSectors = self.componentSectors,
        dataOffsetSectors = self.dataOffsetSectors,
        active = self.raidDisks - degraded, working = working,
        failed = failed, spare = spare, degraded = degraded,
        state = state, clean = self.clean,
        resync = self.recovering and {
            type = "recovery", offset = self.recovering.offset,
            total = self.componentSectors, member = self.recovering.member.dev,
        } or nil,
        members = members,
    }
end

function md.info(name)
    local a = arrays[name]
    if not a then return nil, "/dev/" .. name .. ": no such array" end
    return a:info()
end

--- mdadm --detail 的目标: 阵列名("/dev/md0"|"md0"|"0")或**成员设备**的路径
--- (mdadm 也接受成员设备, 显示的是它所属的阵列)。
function md.detail(spec)
    if type(spec) ~= "string" or spec == "" then return nil, "no array given" end
    local a = arrays[md.normalizeName(spec)]
    if a then return a:info() end
    local t = devdisk.target(spec)
    if t then
        for _, arr in pairs(arrays) do
            for _, m in ipairs(arr.members) do
                if m.dev == t.node then return arr:info() end
            end
        end
    end
    return nil, "/dev/" .. md.normalizeName(spec) .. ": no such array"
end

--- 所有阵列的信息(按名字排序; /proc/mdstat 与 mdadm --detail --scan 用)。
function md.listInfo()
    local out = {}
    for _, a in ipairs(md.list()) do out[#out + 1] = a:info() end
    return out
end

--- "/dev/md0" | "md0" | "0" -> "md0"。
function md.normalizeName(spec)
    if spec:match("^%d+$") then return "md" .. spec end
    return (spec:gsub("^.*/", ""))
end

--- 读设备超级块, 整理成 --examine / --query 的形状。
function md.examine(spec)
    local t, err = devdisk.target(spec)
    if not t then return nil, tostring(err) end
    local bd = t.openBd("r")
    if not bd then return nil, t.node .. ": cannot open for reading" end
    local sb = parseSuper(bd.read(SB_SECTOR * 512, SB_BYTES))
    bd.close()
    if not sb then return nil, t.node .. ": no md superblock detected" end
    local role = sb.roles[sb.dev_number + 1]
    local roleText
    if role == ROLE_SPARE then roleText = "spare"
    elseif role == ROLE_FAULTY then roleText = "faulty"
    elseif role == ROLE_JOURNAL then roleText = "journal"
    else roleText = "Active device " .. role end
    local state = {}
    for i = 1, sb.raid_disks do
        local r = sb.roles[i]
        state[i] = (r ~= nil and r < sb.raid_disks) and "A" or "."
    end
    return {
        dev = t.node,
        magic = string.format("%x", SB_MAGIC),
        version = "1.2",
        featureMap = sb.feature_map,
        uuid = uuidText(sb.set_uuid),
        name = sb.set_name,
        ctime = sb.ctime,
        level = sb.level, levelName = md.levelName(sb.level),
        layout = sb.layout, layoutName = ALGO_NAMES[sb.layout],
        raidDisks = sb.raid_disks,
        sizeSectors = sb.size,
        chunksize = sb.chunksize,
        dataOffset = sb.data_offset,
        superOffset = sb.super_offset,
        dataSize = sb.data_size,
        devNumber = sb.dev_number,
        role = roleText,
        state = (sb.resync_offset == MAX_SECTOR) and "clean" or "active",
        utime = sb.utime, events = sb.events,
        recoveryOffset = sb.recovery_offset,
        resyncOffset = sb.resync_offset,
        checksum = sb.sb_csum,
        checksumOk = superCsumOk(sb),
        arrayState = table.concat(state),
    }
end

--- 抹掉设备上的 md 超级块(mdadm --zero-superblock)。
function md.zeroSuperblock(spec)
    local t, err = devdisk.target(spec)
    if not t then return nil, tostring(err) end
    local bd = t.openBd("r+")
    if not bd then return nil, t.node .. ": cannot open for writing" end
    if not parseSuper(bd.read(SB_SECTOR * 512, SB_BYTES)) then
        bd.close()
        return nil, t.node .. ": no md superblock detected"
    end
    local ok, werr = bd.write(SB_SECTOR * 512, string.rep("\0", SB_BYTES))
    bd.close()
    if not ok then return nil, t.node .. ": " .. tostring(werr) end
    return true
end

--- /proc/mdstat 的内容(Linux mdstat 的形状)。
function md.mdstat()
    local personalities = { "raid0", "raid1", "raid5", "raid6", "raid10" }
    local lines = {}
    local head = "Personalities : "
    for i, p in ipairs(personalities) do head = head .. "[" .. p .. "]" .. (i < #personalities and " " or " ") end
    lines[#lines + 1] = head
    for _, a in ipairs(md.list()) do
        local parts = {}
        for r = 0, a.raidDisks - 1 do
            local m = a:memberByRole(r)
            if m and m.dev ~= "missing" then
                local mark = ""
                if m.state == "faulty" then mark = "(F)"
                elseif m.state == "recovering" then mark = "(R)" end
                parts[#parts + 1] = (m.dev:gsub("^/dev/", "")) .. "[" .. r .. "]" .. mark
            end
        end
        for _, m in ipairs(a:spares()) do
            parts[#parts + 1] = (m.dev:gsub("^/dev/", "")) .. "[S]"
        end
        local info = a:info()
        lines[#lines + 1] = a.name .. " : active " .. md.levelName(a.level)
            .. (#parts > 0 and (" " .. table.concat(parts, " ")) or "")
        local status = ""
        for r = 0, a.raidDisks - 1 do
            local m = a:memberByRole(r)
            status = status .. ((memberReadable(m) or (m and m.state == "recovering")) and "U" or "_")
        end
        lines[#lines + 1] = string.format("      %d blocks super 1.2 [%d/%d] [%s]",
            a.componentSectors, a.raidDisks, info.active, status)
        if a.recovering then
            local done, total = a.recovering.offset, a.componentSectors
            local pct = total > 0 and (done / total * 100) or 0
            local bars = 21
            local filled = math.floor(pct / 100 * bars)
            if filled > bars then filled = bars end
            local bar = string.rep("=", math.max(filled - 1, 0))
                .. (filled > 0 and ">" or "") .. string.rep(".", bars - math.max(filled, 1) + 1)
            lines[#lines + 1] = string.format(
                "      [%s]  recovery = %5.1f%% (%d/%d) finish=0.0min speed=0K/sec",
                bar, pct, done, total)
        end
        lines[#lines + 1] = "      "
    end
    lines[#lines + 1] = "unused devices: <none>"
    return table.concat(lines, "\n") .. "\n"
end

--- 调度器心跳: 推进所有阵列的重建。**不能让出**(不在协程上下文里)。
function md.tick()
    for _, a in pairs(arrays) do
        if a.recovering then
            local ok, err = pcall(a._resyncSlice, a)
            if not ok then
                log("md: " .. a.name .. ": recovery error: " .. tostring(err))
                a.recovering = nil
            end
        end
    end
end

md.klog = nil              -- 内核日志(模块注入)
md.fs = vfs_api.fs         -- 读 mdadm.conf 的门面(vfs_api.fs; 测试台可换)

--- 由 modules/md.ko 在 init 里调用。
function md.attach(klogObj, fsObj)
    md.klog = klogObj
    if fsObj then md.fs = fsObj end
end

return md
