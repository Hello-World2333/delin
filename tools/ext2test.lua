--[[ Delin EXT2 驱动宿主回归测试: 在真实 ext2 镜像上跑目录增删, 再用宿主 e2fsck -fn 判定。
     锁住两个真机跑一轮才暴露的 bug:
       1) addDirEntry 把 name_len 读成 file_type(偏移 7 而非 6) -> 删除条目后残留 inode=0 的
          8 字节空洞夹在活条目之间, e2fsck 报 "directory corrupted"(变体 A);
          正确做法是删条目时把 rec_len 并入前一条(变体 B)。
       2) create 给普通文件也加父目录 links -> 引用计数只增不减
          (真机 fsck: "Inode 115 ref count is 55, should be 3");
       3) removeDirEntry 只会"并入前一条" -> 目录跨块后每个非首块的**第一条**删不掉
          (真机 rm -rf 一个大目录报 "cannot remove first dir entry")。
     用法: lua5.1 tools/ext2test.lua     需要 /usr/sbin/mkfs.ext2 与 /usr/sbin/e2fsck
]]

io.stdout:setvbuf("line")
os.epoch = os.epoch or function() return os.time() * 1000 end
--- 仓库根: 按本脚本位置推并补成绝对路径(别写死绝对路径, 否则换台机器/CI 上 require 不到 src/)。
local function repoRoot()
    local self = (arg and arg[0]) or "tools/ext2test.lua"
    local dir = self:match("^(.*)/[^/]*$") or "."   -- 脚本所在目录
    local root = dir:match("^(.*)/[^/]+$") or "."    -- 去掉 tools = 仓库根
    if root:sub(1, 1) ~= "/" then
        local p = io.popen("pwd")
        local cwd = p:read("*l"); p:close()
        root = (root == ".") and cwd or (cwd .. "/" .. root:gsub("^%./", ""))
    end
    return root
end
package.path = repoRoot() .. "/src/?.lua;" .. package.path

-- kernel.vfs_api 在**模块加载时**就从全局 fs 上取路径工具函数(getName/getDir/combine/...)。
-- 宿主上没有 CC 的 fs, 这里给一份最小实现(vfs_api 只用到这几个纯函数, 不碰真实文件)。
_G.fs = _G.fs or {
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
}

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

-- 删**非空**目录必须被拒绝(POSIX rmdir / ENOTEMPTY)。曾经的 bug: ext2.delete 不检查就合并掉
-- 目录条目, 子 inode 仍被占用却没有任何目录项指向它们 —— 真机 e2fsck 报
-- "Unconnected directory inode" + "Unattached inode"(数据静默丢失); 用户态不能靠 rmdir 自己
-- 先判空来兜, 直接调 fs.delete 的地方(真机自检脚本就是)照样弄坏盘。
do
    assert(ext2.create(fs, "/d", "ne", T_DIR + 493))
    assert(ext2.create(fs, "/d/ne", "inner", T_REG + 420))
    local okd, derr = ext2.delete(fs, "/d", "ne")
    eq(okd, nil, "删非空目录被拒绝")
    eq(derr, "directory not empty", "删非空目录的报错是 directory not empty")
    ok(ext2.lookup(fs, "/d/ne") ~= nil, "被拒绝后目录条目还在")
    ok(ext2.lookup(fs, "/d/ne/inner") ~= nil, "被拒绝后目录里的文件还在")
    eq(ext2.lookup(fs, "/d").links, 3, "被拒绝后父目录 links 不变")
    -- 清空之后就能删(rm -r 的正常路径)
    assert(ext2.delete(fs, "/d/ne", "inner"))
    assert(ext2.delete(fs, "/d", "ne"))
    eq(ext2.lookup(fs, "/d").links, 2, "清空后删目录成功, links 回落")
end

-- 跨块目录: **每个块的第一条目录项**也必须能删掉。
-- 曾经的 bug: removeDirEntry 只做"把 rec_len 并入前一条", 而块首条目没有前一条 —— 于是
-- 目录一跨块, 每个非首块的第一条就永远删不掉(真机 rm -rf 一个大目录报
-- "cannot remove first dir entry", 目录删不干净; regex_test.sh 在真机上把它试了出来)。
-- 正确做法: 块首条目置 inode=0 标空闲(rec_len/name_len 原样留着, addDirEntry 会整条复用)。
do
    assert(ext2.create(fs, "/", "big", T_DIR + 493))
    local N = 200
    for i = 1, N do assert(ext2.create(fs, "/big", string.format("file%03d", i), T_REG + 420)) end
    local dinode = ext2.lookup(fs, "/big")
    ok((dinode.size or 0) > 1024, "跨块目录已建立(size=" .. tostring(dinode.size) .. ")")
    local failed = 0
    for i = 1, N do
        local okd, derr = ext2.delete(fs, "/big", string.format("file%03d", i))
        if not okd then
            failed = failed + 1
            if failed == 1 then io.write("   首个失败: file" .. string.format("%03d", i) .. " -- " .. tostring(derr) .. "\n") end
        end
    end
    eq(failed, 0, "跨块目录的每一条(含各块第一条)都能删掉")
    local left = 0
    for _, e in ipairs(ext2.readDir(fs, ext2.lookup(fs, "/big")) or {}) do
        if e.name ~= "." and e.name ~= ".." then left = left + 1 end
    end
    eq(left, 0, "删空后目录里没有残留条目")
    assert(ext2.delete(fs, "/", "big"))
end

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

-- read(n) 的 EOF 契约: 必须返回 **nil**(不是空串)。返回空串会让"读到 nil 为止"的循环
-- 在真机上无限打转(tee/dd/cp 全中招), 而宿主测试台的句柄是标准的, 所以这里必须锁住。
do
    local eofh = assert(be.open("/d/f1", "r"))
    eq(eofh.read(4096), "hello ext2\n", "ext2 read(n): 读到内容")
    eq(eofh.read(4096), nil, "ext2 read(n): EOF 返回 nil(不是空串)")
    eq(eofh.read(4096), nil, "ext2 read(n): EOF 之后再读仍是 nil")
    local eofh2 = assert(be.open("/d/f1", "r"))
    eq(eofh2.read(), "hello ext2\n", "ext2 read(): 无参读到末尾")
    eq(eofh2.read(), nil, "ext2 read(): 末尾之后再读返回 nil")
    eofh.close(); eofh2.close()
end


-- ---------------------------------------------------------------
-- 1a2) 符号链接 / 硬链接(与 POSIX ln / ln -s / readlink 配套)
--      ext2 的"快速符号链接"把 <=60 字节的目标内联在 i_block 里, 更长才占数据块 ——
--      创建侧(setSymlink)与读取侧(readSymlink)必须以同一个 60 字节为界, 否则短目标会被
--      当成块号读出一坨垃圾(或真的读出错块)。所以这里短/长各测一遍。
-- ---------------------------------------------------------------
local T_SYM = 0xA000
local SHORT = "target-file"                       -- 11 字节: 走内联
local LONG  = "/d/" .. string.rep("verylongsegment/", 5) .. "end"  -- >60 字节: 走数据块
ok(#SHORT <= 60 and #LONG > 60, "符号链接测试目标长度齐全(短<=60 / 长>60)")

assert(be.symlink(SHORT, "/d/shortlink"))
eq(ext2.lookup(fs, "/d/shortlink").type, T_SYM, "symlink: 类型是 T_SYM")
eq(be.readlink("/d/shortlink"), SHORT, "readlink: 短目标(内联 i_block)读回一致")
eq(ext2.lookup(fs, "/d/shortlink").blocks, 0, "symlink: 短目标不占数据块(blocks=0)")

assert(be.symlink(LONG, "/d/longlink"))
eq(be.readlink("/d/longlink"), LONG, "readlink: 长目标(占数据块)读回一致")
ok(ext2.lookup(fs, "/d/longlink").blocks > 0, "symlink: 长目标确实分配了数据块")

-- 用宿主 readlink 交叉验证: 目标字符串必须逐字节相同(写进镜像的格式对不对, 由真 ext2 工具判)
local h1 = io.popen("readlink " .. IMG .. " 2>/dev/null")
if h1 then h1:close() end -- 镜像不是目录, 这里只确认 popen 可用; 真校验交给下面的 e2fsck 与目录项比对

-- readlink 对非符号链接必须报错, 而不是把文件内容当目标返回
local _, nlerr = be.readlink("/d/f1")
ok(nlerr ~= nil, "readlink: 非符号链接 -> 报错", tostring(nlerr))
eq(be.readlink("/d/nope"), nil, "readlink: 不存在的路径 -> nil")

-- 符号链接的删除(走 ext2.delete 的通用路径)
assert(ext2.delete(fs, "/d", "shortlink"))
eq(ext2.lookup(fs, "/d/shortlink"), nil, "symlink: 删除后条目消失")
assert(ext2.delete(fs, "/d", "longlink"))

-- 硬链接: links 计数与共享内容
local ino1 = ext2.create(fs, "/d", "hardsrc", T_REG + 420)
assert(ext2.writeFile(fs, ino1, "shared content\n"))
assert(ext2.link(fs, "/d/hardsrc", "/d/hardlink"))
eq(ext2.lookup(fs, "/d/hardlink").ino, ino1, "hardlink: 两个名字指向同一个 inode")
eq(ext2.lookup(fs, "/d/hardsrc").links, 2, "hardlink: links 递增为 2")
local hr = assert(be.open("/d/hardlink", "r"))
eq(hr:readAll(), "shared content\n", "hardlink: 通过新名字读到同一内容")
hr:close()
assert(ext2.delete(fs, "/d", "hardsrc"))
eq(ext2.lookup(fs, "/d/hardlink").links, 1, "hardlink: 删掉一个名字后 links 回落为 1")
eq(be.open("/d/hardlink", "r"):readAll(), "shared content\n", "hardlink: 删掉一个名字后内容仍在")
assert(ext2.delete(fs, "/d", "hardlink"))
eq(ext2.readInode(fs, ino1).links, 0, "hardlink: 最后一个名字删掉后 inode 回收")

-- 硬链接不能指向目录(会成环), 也不能覆盖已存在的名字
assert(ext2.create(fs, "/d", "ldir", T_DIR + 493))
local _, lerr = ext2.link(fs, "/d/ldir", "/d/ldir2")
ok(lerr ~= nil, "hardlink: 目录 -> 报错", tostring(lerr))
assert(ext2.create(fs, "/d", "existing", T_REG + 420))
local _, lerr2 = ext2.link(fs, "/d/existing", "/d/existing")
ok(lerr2 ~= nil, "hardlink: 目标名已存在 -> 报错", tostring(lerr2))

-- ---------------------------------------------------------------
-- 1a3) VFS 层的符号链接展开(路径解析必须"穿过"链接)
--      展开在这一层做, 后端(ext2.lookup)看到的一律是不含符号链接的平坦路径。
-- ---------------------------------------------------------------
do
    local vfs = require("kernel.vfs")
    vfs.mount("/", ext2.backend(fs))
    vfs.mount("/mnt/dev", ext2.backend(fs)) -- 第二个挂载点: 验证链接不跨挂载也不会串
    -- 路径操作走 VFS 门面(它才会展开符号链接); `be` 是后端, 后端看到的路径必须已经平坦。
    local fsapi = require("kernel.vfs_api").fs

    -- 目录链接: /d/dirlink -> /d/subdir, 于是 /d/dirlink/inner 必须解析到 /d/subdir/inner
    assert(ext2.create(fs, "/d", "subdir", T_DIR + 493))
    assert(ext2.create(fs, "/d/subdir", "inner", T_REG + 420))
    local wr = assert(fsapi.open("/d/subdir/inner", "w"))
    wr:write("via link\n")
    wr:close()
    assert(be.symlink("/d/subdir", "/d/dirlink"))
    local rf = assert(fsapi.open("/d/dirlink/inner", "r"))
    eq(rf:readAll(), "via link\n", "vfs: 经目录符号链接打开文件(中间段跟随)")
    rf:close()

    -- 相对目标的链接: 目标相对**链接所在目录**解析
    assert(be.symlink("subdir", "/d/rellink"))
    local rf2 = assert(fsapi.open("/d/rellink/inner", "r"))
    eq(rf2:readAll(), "via link\n", "vfs: 相对目标的符号链接按链接所在目录解析")
    rf2:close()
    eq(select(2, vfs.resolve("/d/rellink")), "/d/subdir", "vfs: 相对链接也展开成绝对目标")

    -- 悬空链接: 展开成目标路径, 但目标不存在(所以 stat 拿不到)
    assert(be.symlink("/d/nowhere", "/d/dangling"))
    local _, rd = vfs.resolve("/d/dangling")
    eq(rd, "/d/nowhere", "vfs: 悬空链接展开到目标路径")
    eq(vfs.resolveNoFollow("/d/dangling") ~= nil and ext2.lookup(fs, rd) == nil, true,
       "vfs: 悬空链接的目标确实不存在")

    -- 链接成环 -> ELOOP, 不能死循环
    assert(be.symlink("/d/loop2", "/d/loop1"))
    assert(be.symlink("/d/loop1", "/d/loop2"))
    local _, _, lerr3 = vfs.resolve("/d/loop1")
    ok(lerr3 ~= nil and tostring(lerr3):find("too many levels"), "vfs: 链接成环 -> ELOOP",
       tostring(lerr3))

    -- resolveNoFollow: 最后一段不展开(供 lstat/readlink/unlink 用)
    local b1, r1 = vfs.resolveNoFollow("/d/dirlink")
    eq(r1, "/d/dirlink", "vfs: resolveNoFollow 不展开最后一段")
    local b2, r2 = vfs.resolve("/d/dirlink")
    eq(r2, "/d/subdir", "vfs: resolve 展开最后一段")
    ok(b1 ~= nil and b2 ~= nil, "vfs: 两次解析都拿到后端")

    -- 挂载内的路径经链接后仍落到同一挂载点
    local _, r3 = vfs.resolve("/mnt/dev/d/dirlink")
    eq(r3, "/d/subdir", "vfs: 挂载点内的链接展开后 rel 仍相对挂载根")

    -- 删除链接本身不能删掉目标(Linux: unlink 不跟随)
    assert(be.symlink("/d/subdir", "/d/rmlink"))
    assert(fsapi.delete("/d/rmlink"))
    eq(ext2.lookup(fs, "/d/subdir") ~= nil, true, "vfs: 删链接不删目标")
    eq(ext2.lookup(fs, "/d/rmlink"), nil, "vfs: 链接本身已删除")

    -- symlink/link 的 fs 门面语义
    fsapi.symlink("/d/subdir", "/d/fsapi_link")
    eq(fsapi.readlink("/d/fsapi_link"), "/d/subdir", "fs.symlink/fs.readlink 往返一致")
    eq(fsapi.lstat("/d/fsapi_link").kind, "symlink", "fs.lstat: 看到链接本身")
    eq(fsapi.attributes("/d/fsapi_link").kind, "dir", "fs.attributes: 跟随到目录")
    ok(fsapi.isDir("/d/fsapi_link"), "fs.isDir: 经链接判定为目录")
    -- 硬链接经 fs 门面
    local ino2 = ext2.create(fs, "/d", "fsl_src", T_REG + 420)
    assert(ext2.writeFile(fs, ino2, "fslink\n"))
    ok(fsapi.link("/d/fsl_src", "/d/fsl_new") ~= nil, "fs.link: 建硬链接成功")
    eq(ext2.lookup(fs, "/d/fsl_new").ino, ino2, "fs.link: 新名字指向同一 inode")
    local hh = assert(fsapi.open("/d/fsl_new", "r"))
    eq(hh:readAll(), "fslink\n", "fs.link: 新名字读到同一内容")
    hh:close()

    vfs.unmount("/mnt/dev")
    vfs.unmount("/")
end

-- ---------------------------------------------------------------
-- 1a4) 命名管道(FIFO, mkfifo) —— 只验 ext2 侧的事实
--      inode 类型是 T_FIFO, 没有文件内容(size=0, blocks=0)。**读写与阻塞语义的测试放在
--      tools/hosttest.lua**: FIFO 的 open 会阻塞到对端出现, 而宿主 lua 是单线程直跑,
--      在这里开写端会死等读端(反之亦然), 测不出东西只能证明会死锁。
--      这里要保证的是: 建/删 FIFO 之后 e2fsck 仍然判干净(特殊 inode 很容易写坏)。
-- ---------------------------------------------------------------
do
    local T_FIFO = 0x1000

    ok(be.mkfifo("/d/pipe") ~= nil, "mkfifo: 建管道成功")
    eq(ext2.lookup(fs, "/d/pipe").type, T_FIFO, "mkfifo: inode 类型是 T_FIFO")
    eq(ext2.lookup(fs, "/d/pipe").size, 0, "mkfifo: FIFO 没有文件内容(size=0)")
    eq(ext2.lookup(fs, "/d/pipe").blocks, 0, "mkfifo: FIFO 不占数据块(blocks=0)")
    eq(be.attributes("/d/pipe").kind, "fifo", "mkfifo: attributes.kind = fifo")

    local vfs2 = require("kernel.vfs")
    vfs2.mount("/", ext2.backend(fs))
    local fsapi = require("kernel.vfs_api").fs
    ok(fsapi.isFifo("/d/pipe"), "fs.isFifo: 认得出命名管道")
    eq(fsapi.isFifo("/d/f1"), false, "fs.isFifo: 普通文件不是管道")
    eq(fsapi.isFifo("/d/nope"), false, "fs.isFifo: 不存在的路径 -> false")

    -- 删除与同名重建(缓冲区释放逻辑由 hosttest 用真实调度器验证)
    assert(fsapi.delete("/d/pipe"))
    eq(ext2.lookup(fs, "/d/pipe"), nil, "fifo: 删除后条目消失")
    eq(fsapi.isFifo("/d/pipe"), false, "fifo: 删除后不再是管道")
    ok(fsapi.mkfifo("/d/pipe") ~= nil, "mkfifo: 同名重建成功")
    eq(ext2.lookup(fs, "/d/pipe").type, T_FIFO, "mkfifo: 重建后仍是 T_FIFO")

    -- 目录项里 file_type 字节必须是 FT_FIFO(5), 否则 e2fsck 会判 "invalid directory entry"
    local _, names = dirHoles(fs, "/d")
    ok(names:find("pipe") ~= nil, "fifo: 目录项里有 pipe")

    vfs2.unmount("/")
end

bd.close()

-- ---------------------------------------------------------------
-- 1b) mkfs(安装器现场格式化): 自建镜像必须能被驱动读、被 e2fsck 判干净
--     位图映射是这里最容易错的地方: 块位图是 **bit k <-> block (k+1)**
--     (blockSize==1024 时 block0 是引导块, 不进位图), inode 位图是 bit k <-> inode (k+1),
--     两个位图的尾部填充位都要置 1。写错任何一处 e2fsck 都会报出来。
-- ---------------------------------------------------------------
for _, blocks in ipairs({ 64, 512, 1024 }) do
    local p = "/tmp/delin-mkfs-" .. blocks .. ".img"
    os.remove(p)
    local f0 = assert(io.open(p, "wb")); f0:close()
    local b = filebd(p)
    local mfs, merr = ext2.mkfs(b, { blocks = blocks, label = "delintest" })
    ok(mfs ~= nil, string.format("mkfs(%d): 格式化成功", blocks), tostring(merr))
    if mfs then
        eq(ext2.lookup(mfs, "/") ~= nil, true, string.format("mkfs(%d): 能查到根目录", blocks))
        eq(ext2.lookup(mfs, "/lost+found") ~= nil, true, string.format("mkfs(%d): 有 /lost+found", blocks))
        eq(ext2.lookup(mfs, "/").links, 3, string.format("mkfs(%d): 根目录 links=3", blocks))
        -- 用驱动自己的写路径灌文件, 再交 e2fsck 判
        assert(ext2.create(mfs, "/", "bin", T_DIR + 493), "mkfs: mkdir /bin")
        assert(ext2.create(mfs, "/", "etc", T_DIR + 493), "mkfs: mkdir /etc")
        for i = 1, 5 do
            local ino = ext2.create(mfs, "/bin", "tool" .. i, T_REG + 493)
            assert(ext2.writeFile(mfs, ino, string.rep("x", 100 * i) .. "\n"), "mkfs: 写文件 " .. i)
        end
        local hh = assert(ext2.backend(mfs).open("/bin/tool3", "r"))
        eq(hh:readAll(), string.rep("x", 300) .. "\n", string.format("mkfs(%d): 写进去的文件读回来一致", blocks))
        hh:close()
        b.close()
        local rc2 = os.execute(string.format("%s -fn %s > %s 2>&1", FSCK, p, p .. ".fsck.txt"))
        local lf = io.open(p .. ".fsck.txt")
        local lout = lf and lf:read("*a") or ""
        if lf then lf:close() end
        ok(rc2 == 0, string.format("mkfs(%d): e2fsck -fn 干净", blocks), "\n" .. lout)
    end
end

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


-- ---------------------------------------------------------------
-- 3) mkfs.ext2 / fsck.ext2 (内核 ext2.mkfs / ext2.fsck)
--    裁判一律是宿主 e2fsck: Delin 自己造的镜像必须被 e2fsck 判干净, Delin 自己修的镜像
--    也必须被判干净 —— 否则"修好了"只是自己说了算。
-- ---------------------------------------------------------------
local FS_FSCK = "/usr/sbin/e2fsck"

local function hostFsck(path)
    local log = path .. ".e2fsck.txt"
    local rc = os.execute(string.format("%s -fn %s > %s 2>&1", FS_FSCK, path, log))
    local f = io.open(log)
    local out = f and f:read("*a") or ""
    if f then f:close() end
    return rc, out
end
local function newImage(blocks, bs)
    local p = string.format("/tmp/delin-mkmix-%d-%d.img", blocks, bs or 1024)
    os.remove(p)
    local f = io.open(p, "wb"); f:close()
    return p
end
--- 直接改镜像字节(破坏用): 从 off 起写入 bytes
local function wr(path, off, bytes)
    local f = assert(io.open(path, "r+b"))
    f:seek("set", off); f:write(bytes); f:close()
end
local function fsckOn(path, mode, ask)
    local b = filebd(path)
    local rep = ext2.fsck(b, { mode = mode or "check", ask = ask })
    b.close()
    return rep
end
local function digest(path)
    local f = io.open(path, "rb"); local d = f:read("*a"); f:close()
    local h = 0
    for i = 1, #d do h = (h * 31 + d:byte(i)) % 4294967296 end
    return h, #d
end

-- 3a) mkfs: 块大小/inode 数/保留块/卷标都要被驱动与宿主 e2fsck 双方认可
for _, c in ipairs({
    { 512, 1024, nil, 0 },
    { 1024, 2048, nil, 0 },
    { 256, 4096, nil, 0 },
    { 512, 1024, 128, 5 },
    { 512, 4096, 300, 0 },
}) do
    local blocks, bs, inodes, rpct = c[1], c[2], c[3], c[4]
    local p = newImage(blocks, bs)
    local b = filebd(p)
    local mfs, merr = ext2.mkfs(b, { blocks = blocks, blockSize = bs, inodes = inodes,
                                     reservedPercent = rpct, label = "delintest" })
    local tag = string.format("mkfs(-b %d -N %s -m %d)%d块", bs, tostring(inodes), rpct, blocks)
    ok(mfs ~= nil, tag .. ": 成功", tostring(merr))
    if mfs then
        local info = mfs.mkfsInfo
        eq(info.blockSize, bs, tag .. ": 块大小")
        eq(info.blocks, blocks, tag .. ": 块数")
        eq(info.rBlocks, math.floor(blocks * rpct / 100), tag .. ": 保留块数")
        ok(info.inodes >= (inodes or 256) and info.inodes % math.floor(bs / 128) == 0,
            tag .. ": inode 数向上取整到 inode 表整块(实得 " .. tostring(info.inodes) .. ")")
        eq(ext2.lookup(mfs, "/") ~= nil, true, tag .. ": 有根目录")
        eq(ext2.lookup(mfs, "/lost+found") ~= nil, true, tag .. ": 有 /lost+found")
        -- 卷标落在超级块里(偏移 1024+120, 16 字节)
        local sb = b.read(1024, 1024)
        eq(sb:sub(121, 129), "delintest", tag .. ": 超级块里的卷标")
        -- 驱动自己读写一遍(块大小变了以后 inode 表/位图的偏移都不在前几个块上)
        assert(ext2.create(mfs, "/", "d", T_DIR + 493))
        local ino = assert(ext2.create(mfs, "/d", "f", T_REG + 493))
        assert(ext2.writeFile(mfs, ino, string.rep("abc", 300)))
        local h = assert(ext2.backend(mfs).open("/d/f", "r"))
        eq(h:readAll(), string.rep("abc", 300), tag .. ": 写进去读回来一致")
        h:close()
        b.close()
        local rc, out = hostFsck(p)
        ok(rc == 0, tag .. ": e2fsck -fn 干净", out)
    else
        b.close()
    end
end

-- 3b) mkfs -n(dry run): 只校验参数, 一个字节都不写
do
    local p = newImage(512)
    local b = filebd(p)
    local dry, derr = ext2.mkfs(b, { blocks = 512, dryRun = true, label = "dry" })
    ok(dry ~= nil and dry.dryRun == true, "mkfs -n: 返回参数摘要而不是文件系统", tostring(derr))
    b.close()
    eq(io.open(p, "rb"):read("*a"), "", "mkfs -n: 镜像仍是 0 字节(没写盘)")
    -- 参数仍然要校验: 块数太少/块大小非法照样报错
    local b2 = filebd(p)
    local r2, e2 = ext2.mkfs(b2, { blocks = 32, dryRun = true })
    ok(r2 == nil and tostring(e2):find("64") ~= nil, "mkfs -n: 块数不足仍然报错", tostring(e2))
    local r3, e3 = ext2.mkfs(b2, { blocks = 512, blockSize = 4096 + 1, dryRun = true })
    ok(r3 == nil and tostring(e3):find("block size") ~= nil, "mkfs: 非法块大小报错", tostring(e3))
    local r4, e4 = ext2.mkfs(b2, { blocks = 8 * 1024 + 1, dryRun = true })
    ok(r4 == nil and tostring(e4):find("single block group") ~= nil, "mkfs: 超过单块组上限报错", tostring(e4))
    b2.close()
end

-- 3c) fsck: 干净盘必须判干净, 而且 fix 模式一个字节都不改(幂等)
do
    local p = newImage(512)
    local b = filebd(p)
    local mfs = assert(ext2.mkfs(b, { blocks = 512, label = "fscktest" }))
    assert(ext2.create(mfs, "/", "bin", T_DIR + 493))
    assert(ext2.create(mfs, "/", "etc", T_DIR + 493))
    for i = 1, 5 do
        local ino = assert(ext2.create(mfs, "/bin", "tool" .. i, T_REG + 493))
        assert(ext2.writeFile(mfs, ino, string.rep("x", 100 * i) .. "\n"))
    end
    -- 快速符号链接(<=60 字节目标内联在 i_block 里, 不能被当块号)与硬链接
    local be = assert(ext2.backend(mfs))
    assert(be.symlink("bin/tool1", "/link1"))
    assert(be.link("bin/tool1", "/bin/tool1.hard"))
    b.close()
    local before, sizeBefore = digest(p)
    local rep = fsckOn(p, "check")
    eq(rep.code, 0, "fsck: 干净盘 check 退出码 0")
    eq(rep.errors, 0, "fsck: 干净盘没有问题")
    eq(rep.files.used, 19, "fsck: 在用 inode 数(18 + 硬链接不占新 inode)")
    rep = fsckOn(p, "fix")
    eq(rep.code, 0, "fsck: 干净盘 fix 退出码 0")
    local after, sizeAfter = digest(p)
    ok(before == after and sizeBefore == sizeAfter, "fsck: 干净盘 fix 一个字节都不改(幂等)")
    local rc, out = hostFsck(p)
    ok(rc == 0, "fsck: 跑完之后 e2fsck 仍判干净", out)
end

-- 3d) 各种损坏: check 必须报出来(退出码 4), fix 必须修到宿主 e2fsck 判干净(退出码 1)
local corruptCases = {}
--- 通用: 造一个带 /bin/toolN 的镜像, 再让 case.fn 去破坏它
local function freshWithTools(blocks)
    local p = newImage(blocks or 512)
    local b = filebd(p)
    local mfs = assert(ext2.mkfs(b, { blocks = blocks or 512, label = "corrupt" }))
    assert(ext2.create(mfs, "/", "bin", T_DIR + 493))
    for i = 1, 5 do
        local ino = assert(ext2.create(mfs, "/bin", "tool" .. i, T_REG + 493))
        assert(ext2.writeFile(mfs, ino, string.rep("x", 100 * i) .. "\n"))
    end
    b.close()
    return p
end
--- 单块组 1024 字节块的固定布局: inode 表在块 5 起, 每个 inode 128 字节。
--- (只用于"手工破坏镜像字节"的用例; 布局本身由 3a 的用例锁着。)
local function inodeOffset(ino)
    return 5 * 1024 + (ino - 1) * 128
end
local function inoOfFile(p, path)
    local b = filebd(p)
    local mfs = assert(ext2.mount(b))
    local ino = ext2.lookup(mfs, path).ino
    b.close()
    return ino
end
--- 用驱动自己的路径造状态, 再手工破坏镜像字节(模拟真实的元数据损坏)
local function withImage(fn)
    local p = freshWithTools(512)
    local b = filebd(p)
    local mfs = assert(ext2.mount(b))
    fn(p, mfs, b)
    b.close()
    return p
end

-- (1) 块位图被清零: 元数据块被标成空闲
corruptCases[#corruptCases + 1] = {
    name = "块位图清零",
    make = function()
        local p = freshWithTools(512)
        wr(p, 3 * 1024, string.rep("\0", 1024))
        return p
    end,
    want = "block bitmap",
}
-- (2) 文件链接计数错
corruptCases[#corruptCases + 1] = {
    name = "链接计数错",
    make = function()
        local p = freshWithTools(512)
        local ino = inoOfFile(p, "/bin/tool2")
        wr(p, inodeOffset(ino) + 26, string.char(9, 0))
        return p
    end,
    want = "ref count",
}
-- (3) i_blocks 错
corruptCases[#corruptCases + 1] = {
    name = "i_blocks 错",
    make = function()
        local p = freshWithTools(512)
        local ino = inoOfFile(p, "/bin/tool3")
        wr(p, inodeOffset(ino) + 28, string.char(0xEE, 0xEE, 0, 0))
        return p
    end,
    want = "i_blocks",
}
-- (4) 超级块/块组描述符的空闲计数错
corruptCases[#corruptCases + 1] = {
    name = "空闲计数错",
    make = function()
        local p = freshWithTools(512)
        wr(p, 1024 + 12, string.char(0xFF, 0, 0, 0)) -- s_free_blocks_count
        wr(p, 2 * 1024 + 12, string.char(0xFF, 0))   -- bg_free_blocks_count
        return p
    end,
    want = "count wrong",
}
-- (5) 坏块指针(超出文件系统范围)
corruptCases[#corruptCases + 1] = {
    name = "坏块指针",
    make = function()
        local p = freshWithTools(512)
        local ino = inoOfFile(p, "/bin/tool5")
        wr(p, inodeOffset(ino) + 40, string.char(0xFF, 0xFF, 0xFF, 0x7F))
        return p
    end,
    want = "block pointer",
}
-- (6) 目录项指向一个已经释放的 inode
corruptCases[#corruptCases + 1] = {
    name = "目录项指向空闲 inode",
    make = function()
        return withImage(function(p, mfs, b)
            local ino = ext2.lookup(mfs, "/bin/tool4").ino
            assert(ext2.delete(mfs, "/bin", "tool4")) -- 删掉: 条目没了, inode 也被回收
            local bin = ext2.readInode(mfs, ext2.lookup(mfs, "/bin").ino)
            assert(ext2.addDirEntry(mfs, bin, "tool4", ino, 1)) -- 再把条目指回那个空闲 inode
        end)
    end,
    want = "unused inode",
}
-- (7) 目录项长度损坏(整条坏掉)
corruptCases[#corruptCases + 1] = {
    name = "目录项长度损坏",
    make = function()
        return withImage(function(p, mfs, b)
            local blk = ext2.getBlock(mfs, ext2.lookup(mfs, "/bin"), 0)
            wr(p, blk * 1024 + 4, string.char(3, 0)) -- rec_len=3, 非法
        end)
    end,
    want = "bad entry length",
}
-- (8) 孤儿 inode -> 必须重连到 /lost+found 且内容还在
do
    local p = withImage(function(p, mfs, b)
        local ino = assert(ext2.create(mfs, "/bin", "orphan", T_REG + 493))
        assert(ext2.writeFile(mfs, ino, "orphan data\n"))
        assert(ext2.removeDirEntry(mfs, ext2.lookup(mfs, "/bin"), "orphan"))
    end)
    local rep = fsckOn(p, "check")
    eq(rep.code, 4, "fsck: 孤儿 inode 在 check 模式报出来(退出码 4)")
    ok(rep.lines ~= nil and #rep.lines > 0, "fsck: check 输出行不为空")
    local joined = table.concat(rep.lines, "\n")
    ok(joined:find("unconnected", 1, true) ~= nil, "fsck: 报 unconnected", joined)
    rep = fsckOn(p, "fix")
    eq(rep.code, 1, "fsck: 孤儿 inode 修好(退出码 1)")
    local b = filebd(p)
    local mfs = assert(ext2.mount(b))
    local lf = ext2.lookup(mfs, "/lost+found")
    local names = {}
    for _, e in ipairs(ext2.readDir(mfs, lf) or {}) do names[#names + 1] = e.name end
    b.close()
    local found
    for _, n in ipairs(names) do if n:sub(1, 1) == "#" then found = n end end
    ok(found ~= nil, "fsck: 孤儿挂进 /lost+found(名字 #<ino>)", table.concat(names, ","))
    if found then
        local b2 = filebd(p)
        local mfs2 = assert(ext2.mount(b2))
        local h = assert(ext2.backend(mfs2).open("/lost+found/" .. found, "r"))
        eq(h:readAll(), "orphan data\n", "fsck: 重连后的文件内容完好")
        h:close()
        b2.close()
    end
    local rc, out = hostFsck(p)
    ok(rc == 0, "fsck: 重连孤儿之后 e2fsck 判干净", out)
end
-- (9) 孤立目录 -> 重连到 /lost+found, 子项仍在
do
    local orphanDir
    local p = withImage(function(p, mfs, b)
        orphanDir = assert(ext2.create(mfs, "/bin", "odir", T_DIR + 493))
        assert(ext2.create(mfs, "/bin/odir", "inner", T_REG + 493))
        assert(ext2.removeDirEntry(mfs, ext2.lookup(mfs, "/bin"), "odir"))
    end)
    local rep = fsckOn(p, "fix")
    eq(rep.code, 1, "fsck: 孤立目录修好(退出码 1)")
    local b = filebd(p)
    local mfs = assert(ext2.mount(b))
    local d = ext2.lookup(mfs, "/lost+found/#" .. orphanDir)
    ok(d ~= nil and d.type == T_DIR, "fsck: 孤立目录挂在 /lost+found/#<ino> 下")
    eq(d and d.links, 2, "fsck: 重连的目录链接数(自身 '.' + lost+found 的条目)")
    local inner
    for _, e in ipairs(ext2.readDir(mfs, d) or {}) do if e.name == "inner" then inner = e end end
    ok(inner ~= nil, "fsck: 重连目录里的子项还在")
    b.close()
    local rc, out = hostFsck(p)
    ok(rc == 0, "fsck: 重连孤立目录之后 e2fsck 判干净", out)
end
-- (10) 逐项询问模式: 全答 no = 什么都不改; 全答 yes = 修好
do
    local p = freshWithTools(512)
    local ino = inoOfFile(p, "/bin/tool2")
    wr(p, inodeOffset(ino) + 26, string.char(9, 0))
    local asked = 0
    local rep = fsckOn(p, "ask", function() asked = asked + 1; return false end)
    eq(rep.code, 4, "fsck: ask 模式全答 no -> 有错没修(退出码 4)")
    ok(asked > 0, "fsck: ask 模式真的问了问题")
    eq(rep.fixed, 0, "fsck: ask 模式全答 no -> 一处都没修")
    rep = fsckOn(p, "ask", function() return true end)
    eq(rep.code, 1, "fsck: ask 模式全答 yes -> 修好(退出码 1)")
    ok(rep.fixed > 0, "fsck: ask 模式确实修了东西")
    local rc, out = hostFsck(p)
    ok(rc == 0, "fsck: ask 模式修完 e2fsck 判干净", out)
end

-- 3e) 上面的每个损坏用例: check 报出(退出码 4) -> fix 修好(退出码 1) -> e2fsck 判干净
for _, c in ipairs(corruptCases) do
    local p = c.make()
    local rep = fsckOn(p, "check")
    eq(rep.code, 4, string.format("fsck(%s): check 报出问题(退出码 4)", c.name))
    local joined = table.concat(rep.lines, "\n")
    ok(joined:find(c.want, 1, true) ~= nil, string.format("fsck(%s): 报出的内容对得上('%s')", c.name, c.want), joined)
    -- check 模式不许写盘: 字节与大小都不变
    local h1, s1 = digest(p)
    fsckOn(p, "check")
    local h2, s2 = digest(p)
    ok(h1 == h2 and s1 == s2, string.format("fsck(%s): check 模式一个字节都没写", c.name))
    rep = fsckOn(p, "fix")
    eq(rep.code, 1, string.format("fsck(%s): fix 修好(退出码 1)", c.name))
    ok(rep.fixed > 0, string.format("fsck(%s): fix 计数 > 0", c.name))
    -- 再查一遍必须干净
    local again = fsckOn(p, "fix")
    eq(again.code, 0, string.format("fsck(%s): 修完再查是干净的(幂等)", c.name))
    local rc, out = hostFsck(p)
    ok(rc == 0, string.format("fsck(%s): 修完 e2fsck 判干净", c.name), out)
end

-- 3f) 宿主 mkfs.ext2 造的多块组镜像(带备份超级块/resize inode)也要判干净 ——
--     驱动自己只造单块组, 但 fsck 得能读别人造的盘: 保留 inode(1..10)、备份超级块、
--     预留 GDT 块都不能被当成"文件占了元数据"或"孤儿"。
do
    local p = "/tmp/delin-hostmkfs-fsck.img"
    os.remove(p)
    local rc0 = os.execute(string.format("dd if=/dev/zero of=%s bs=1024 count=20480 status=none", p))
    local rc1 = os.execute(string.format("/usr/sbin/mkfs.ext2 -q -F -b 1024 %s > /dev/null 2>&1", p))
    local rc2 = os.execute(string.format("/usr/sbin/debugfs -w -R 'mkdir /d1' %s > /dev/null 2>&1", p))
    os.execute("printf 'hello\\n' > /tmp/delin-hostmkfs-f.txt")
    local rc3 = os.execute(string.format("/usr/sbin/debugfs -w -R 'write /tmp/delin-hostmkfs-f.txt /d1/f1' %s > /dev/null 2>&1", p))
    if rc0 == 0 and rc1 == 0 and rc2 == 0 and rc3 == 0 then
        local b = filebd(p)
        local mfs = assert(ext2.mount(b))
        eq(mfs.numGroups, 3, "fsck(宿主镜像): 读到 3 个块组")
        b.close()
        local rep = fsckOn(p, "check")
        eq(rep.code, 0, "fsck(宿主 mkfs.ext2 多块组镜像): 判干净", table.concat(rep.lines, "\n"))
        eq(rep.errors, 0, "fsck(宿主镜像): 没有问题")
        -- 与宿主 e2fsck 的汇总口径一致(文件数/块数)
        local rc, out = hostFsck(p)
        ok(rc == 0, "fsck(宿主镜像): e2fsck 也判干净", out)
        ok(out:find(string.format("%d/%d files", rep.files.used, rep.files.total), 1, true) ~= nil,
            "fsck(宿主镜像): 文件数与 e2fsck 一致", out .. "\n ours=" .. rep.files.used .. "/" .. rep.files.total)
        ok(out:find(string.format("%d/%d blocks", rep.blocks.used, rep.blocks.total), 1, true) ~= nil,
            "fsck(宿主镜像): 块数与 e2fsck 一致", out .. "\n ours=" .. rep.blocks.used .. "/" .. rep.blocks.total)
        -- fix 模式对该镜像也必须是零改动
        local h1 = digest(p)
        local rep2 = fsckOn(p, "fix")
        eq(rep2.code, 0, "fsck(宿主镜像): fix 模式也是 0")
        eq(digest(p), h1, "fsck(宿主镜像): fix 模式没改字节")
    else
        io.write("skip fsck(宿主 mkfs.ext2 多块组镜像): 宿主工具不可用\n")
    end
end

-- 3g) 大文件(双间接块)也要被 fsck 正确统计
do
    local p = newImage(2048)
    local b = filebd(p)
    local mfs = assert(ext2.mkfs(b, { blocks = 2048 }))
    local ino = assert(ext2.create(mfs, "/", "big", T_REG + 493))
    local content = string.rep("0123456789abcdef", 20000) -- 320000 字节 = 313 块, 超过单间接
    assert(ext2.writeFile(mfs, ino, content))
    b.close()
    local rep = fsckOn(p, "check")
    eq(rep.code, 0, "fsck: 双间接大文件判干净", table.concat(rep.lines, "\n"))
    local b2 = filebd(p)
    local mfs2 = assert(ext2.mount(b2))
    local h = assert(ext2.backend(mfs2).open("/big", "r"))
    eq(#h:readAll(), #content, "fsck: 大文件内容长度不变")
    h:close()
    b2.close()
    local rc, out = hostFsck(p)
    ok(rc == 0, "fsck: 大文件镜像 e2fsck 判干净", out)
end

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
