-- 真机: 把设备/镜像里从 offset 起 count 个字节清零 —— 给 fsck.ext2 造"元数据损坏"用。
-- 用法: lua /root/ext2_corrupt.lua <device> <offset> <count>
--   例: lua /root/ext2_corrupt.lua /dev/sda1 3072 1   清掉块位图的第一个字节
-- 为什么不用 dd: /dev/sdXN 的字节句柄没有 seek(dd 的 seek=/skip= 在这种设备上明确报
-- "cannot seek"), 所以这里整体读出 -> 改内存 -> 从偏移 0 写回。镜像只有几百 KB, 没问题;
-- 写回按 16KB 分片, 不给 CC 的文件句柄塞一整块大字符串。
-- 注意 "w" 打开块设备节点**不会截断**底层镜像(内核 devdisk 的 openRaw 一律用 r+),
-- 所以写回是"覆盖前 N 个字节", 不会把镜像截短。
local argv = arg or args or {}

local function stderr(s)
    local e = io.stderr()
    if e and e.write then e:write(s) end
end

local dev, off, count = argv[1], tonumber(argv[2]), tonumber(argv[3] or 1)
if not dev or not off or not count or off < 0 or count < 1 then
    stderr("usage: ext2_corrupt.lua <device> <offset> <count>\n")
    return 2
end

local h, err = fs.open(dev, "r")
if not h then
    stderr("ext2_corrupt: " .. tostring(err) .. "\n")
    return 1
end
local data = h:readAll() or ""
h:close()
if #data < off + count then
    stderr(string.format("ext2_corrupt: %s is %d bytes, cannot corrupt %d..%d\n",
        dev, #data, off, off + count - 1))
    return 1
end

local patched = data:sub(1, off) .. string.rep("\0", count) .. data:sub(off + count + 1)
local w, werr = fs.open(dev, "w")
if not w then
    stderr("ext2_corrupt: " .. tostring(werr) .. "\n")
    return 1
end
local CHUNK = 16384
for i = 1, #patched, CHUNK do
    w:write(patched:sub(i, i + CHUNK - 1))
end
w:close()
io.write(string.format("corrupted %s: %d byte(s) at offset %d zeroed\n", dev, count, off))
