--[[ Delin EXT2 驱动宿主回归测试: 在真实 ext2 镜像上跑目录增删, 再用宿主 e2fsck -fn 判定。
     锁住两个真机跑一轮才暴露的 bug:
       1) addDirEntry 把 name_len 读成 file_type(偏移 7 而非 6) -> 删除条目后残留 inode=0 的
          8 字节空洞夹在活条目之间, e2fsck 报 "directory corrupted"(变体 A);
          正确做法是删条目时把 rec_len 并入前一条(变体 B)。
       2) create 给普通文件也加父目录 links -> 引用计数只增不减
          (真机 fsck: "Inode 115 ref count is 55, should be 3")。
     用法: lua5.1 tools/ext2test.lua     需要 /usr/sbin/mkfs.ext2 与 /usr/sbin/e2fsck
]]

io.stdout:setvbuf("line")
os.epoch = os.epoch or function() return os.time() * 1000 end
package.path = "/home/worker/delin/src/?.lua;" .. package.path

local ext2 = require("kernel.ext2")

local IMG = "/tmp/delin-ext2test.img"
local MKFS, FSCK = "/usr/sbin/mkfs.ext2", "/usr/sbin/e2fsck"
local T_DIR, T_REG = 0x4000, 0x8000

local pass, fail = 0, 0
local function ok(cond, label, extra)
    if cond then
        pass = pass + 1
        io.write("ok   " .. label .. "\n")
    else
        fail = fail + 1
        io.write("FAIL " .. label .. (extra and ("  -- " .. tostring(extra)) or "") .. "\n")
    end
end
local function eq(got, want, label)
    ok(got == want, label, "got=" .. tostring(got) .. " want=" .. tostring(want))
end

-- 文件块设备(与 kernel/blockdev.lua 的 file 后端同一接口)
local function filebd(path)
    local h = assert(io.open(path, "r+b"), "cannot open " .. path)
    return {
        read = function(off, len) h:seek("set", off); return h:read(len) end,
        write = function(off, data) h:seek("set", off); return h:write(data) end,
        close = function() h:close() end,
    }
end

-- 目录块里不允许出现 inode=0 的条目(删除必须并入前一条, 否则 e2fsck 判损坏)
local function dirHoles(fs, path)
    local inode = assert(ext2.lookup(fs, path), "no such dir: " .. path)
    local holes, names = 0, {}
    local n = math.ceil((inode.size or 0) / fs.blockSize)
    for idx = 0, n - 1 do
        local blk = ext2.getBlock(fs, inode, idx)
        if not blk or blk == 0 then break end
        local data = fs.bd.read(blk * fs.blockSize, fs.blockSize)
        local off = 0
        while off < #data do
            local a, b = data:byte(off + 5, off + 6)   -- rec_len 在条目内偏移 4
            local recLen = a + b * 256
            if recLen == 0 then break end
            local a2, b2, c2, d2 = data:byte(off + 1, off + 4)
            local entIno = a2 + b2 * 256 + c2 * 65536 + d2 * 16777216
            local nameLen = data:byte(off + 7)
            if entIno == 0 then holes = holes + 1
            elseif nameLen > 0 then
                local nm = data:sub(off + 9, off + 8 + nameLen)
                if nm ~= "." and nm ~= ".." then names[#names + 1] = nm end
            end
            off = off + recLen
        end
    end
    return holes, table.concat(names, ",")
end

local function mkfs()
    os.remove(IMG)
    local rc = os.execute(string.format("%s -q -t ext2 -b 1024 %s 2048", MKFS, IMG))
    assert(rc == 0, "mkfs failed")
    return filebd(IMG)
end

-- ---------------------------------------------------------------
-- 1) 目录增删
-- ---------------------------------------------------------------
local bd = mkfs()
local fs = assert(ext2.mount(bd))
eq(ext2.lookup(fs, "/") ~= nil, true, "挂载后能查到根目录")

local rootBefore = ext2.lookup(fs, "/").links   -- mkfs 自带 /lost+found, 所以不假定具体值
assert(ext2.create(fs, "/", "d", T_DIR + 493))
eq(ext2.lookup(fs, "/d").links, 2, "新建目录 links=2")
eq(ext2.lookup(fs, "/").links, rootBefore + 1, "新建子目录使父目录 links +1")

for i = 1, 3 do assert(ext2.create(fs, "/d", "f" .. i, T_REG + 420)) end
eq(ext2.lookup(fs, "/d").links, 2, "普通文件不增加父目录 links")
eq(ext2.lookup(fs, "/").links, rootBefore + 1, "普通文件不改变根目录 links")

-- 删除再重建: 目录块里不能留下 inode=0 的空洞
assert(ext2.delete(fs, "/d", "f2"))
assert(ext2.create(fs, "/d", "f2", T_REG + 420))
local holes, names = dirHoles(fs, "/d")
eq(holes, 0, "删除条目后目录块无 inode=0 空洞")
eq(names, "f1,f2,f3", "重建后条目顺序正确")

-- 删空子目录: 父目录 links 回落, 子目录 inode 回收
assert(ext2.create(fs, "/d", "sub", T_DIR + 493))
eq(ext2.lookup(fs, "/d").links, 3, "新建子目录 /d/sub 后 links=3")
local subIno = ext2.lookup(fs, "/d/sub").ino
assert(ext2.delete(fs, "/d", "sub"))
eq(ext2.lookup(fs, "/d").links, 2, "删除子目录后 /d links 回落为 2")
eq(ext2.lookup(fs, "/d/sub"), nil, "子目录条目已删除")
local freed = ext2.readInode(fs, subIno)
eq(freed.links, 0, "删除的空目录 inode 已回收(links=0)")

-- 写文件 + 读回(句柄路径)
local h = assert(ext2.backend(fs).open("/d/f1", "w"))
h:write("hello ext2\n")
h:close()
local r = assert(ext2.backend(fs).open("/d/f1", "r"))
eq(r:readAll(), "hello ext2\n", "写文件后读回内容一致")

-- canExecute: 执行位判定。POSIX 下 root 也要求文件**至少有一个 x 位**(root 绕过的是 r/w,
-- 不绕过 x)—— 否则 644 的脚本 `./script` 也能跑起来(真机暴露过的 bug: 验伪服务以 root 跑,
-- 于是所有文件都"可执行")。目录/不存在的文件一律 false。
local be = ext2.backend(fs)
assert(ext2.create(fs, "/d", "x644", T_REG + tonumber("644", 8)))
assert(ext2.create(fs, "/d", "x755", T_REG + tonumber("755", 8)))
assert(ext2.create(fs, "/d", "x111", T_REG + tonumber("111", 8)))
eq(be.canExecute("/d/x644"), false, "canExecute: 644 不可执行(root 也不能)")
eq(be.canExecute("/d/x755"), true,  "canExecute: 755 可执行")
eq(be.canExecute("/d/x111"), true,  "canExecute: 111 可执行(有 x 位即可, 不要求可读)")
eq(be.canExecute("/d"),      false, "canExecute: 目录不可执行")
eq(be.canExecute("/d/nope"), false, "canExecute: 不存在的文件 -> false")

bd.close()

-- ---------------------------------------------------------------
-- 2) 宿主 e2fsck 判定
-- ---------------------------------------------------------------
-- 注意: Lua 5.1 的 io.popen():close() 不返回退出码, 用 os.execute 取
local LOG = "/tmp/delin-ext2test.fsck.txt"
local rc = os.execute(string.format("%s -fn %s > %s 2>&1", FSCK, IMG, LOG))
local f = io.open(LOG)
local out = f and f:read("*a") or ""
if f then f:close() end
ok(rc == 0, "e2fsck -fn 干净", "\n" .. out)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
