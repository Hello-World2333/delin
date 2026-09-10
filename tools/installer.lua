--[[ Delin 安装器(CraftOS 程序; tools/bundle.lua 把它连同 blockdev/ext2/crc32/version 打成单文件
     dist/install.lua)。
     用法(游戏内):
         wget run https://raw.githubusercontent.com/Hello-World2333/delin/release/<版本>/install.lua
         (开发期也可以换成本地 http: wget run http://<host>:10568/<版本>/install.lua)
     然后跟着向导一步步走:
         安装方式(CCFS / EXT2) -> 目标设备 -> 安装源 -> (仅 EXT2) 镜像大小
         -> 摘要确认 -> 开始安装
     上下箭头选择, 回车确认; Backspace 返回上一步(文本输入里行首再退格 = 返回), Q 退出。
     注意: **CraftOS 不产生 Esc 键事件**(keys 表里没有 escape, keys.getName(256) 也是 nil),
     所以"回退"只能绑 Backspace, 别写 keys.escape = 1 这种在其他版本上才有的东西。

     它做什么:
       - 从 http 安装源(发布树)拉 manifest, 再逐文件下载 payload/ 并校验 size + CRC32;
       - 把 payload 铺到目标: CCFS(直接铺文件) 或 EXT2(现场 mkfs 出镜像再写进去);
       - 写引导配置: /startup.lua(Delin BIOS, 旧的备份成 /startup.lua.craftos)、
         /boot/{delin.lua,dlub.lua}、/.boot、/dlub.cfg;
       - 装完提示回车重启(其它键不处理)。

     引导链(安装器产出的东西必须与它一致):
         CraftOS 开机跑 <电脑自身存储>/startup.lua = Delin BIOS
         BIOS 扫设备找 /.boot → 读里面的路径 → loadfile
         所以 **引导入口固定在电脑自身存储上**, 三种形态:
           CCFS(装到电脑存储)  /.boot = /boot/delin.lua   内核就在电脑存储上
           CCFS(装到磁盘)      /.boot = /boot/dlub.lua    /dlub.cfg = ccdisk <盘名>
           EXT2(电脑存储或磁盘) /.boot = /boot/dlub.lua    /dlub.cfg = rootfs <镜像> | bootdisk <盘名>
         这份判断只有一处(bootPlan), 摘要页与安装过程共用, 不允许各写一遍。

     设计要点:
       - **不需要外部工具**: ext2 格式化与写入用的是内核同一份 ext2 driver(打包进本文件),
         安装完全发生在游戏内; 宿主机只负责用静态 http 服务托管发布树(tools/serve.sh)。
       - **安装源只有 http**: 游戏侧碰不到服务器文件系统, 只能下载。
       - **fail-fast**: 校验不过 / 空间不够 / 目标非法一律报错返回, 不写半成品引导配置。
         "安装源"这一步就会拉一次 manifest —— 源不通当场就能看见, 不用等到开始装。
       - **向导只依赖事件队列**: 每一步都是"重画整屏 + os.pullEvent", 不做增量刷新;
         真机自动化验证可以把按键事件预先 os.queueEvent 进队列来驱动它。
       - 输出全 ASCII(CC 终端打中文乱码)。 ]]

local blockdev = require("kernel.blockdev")
local ext2     = require("kernel.ext2")
local crc32    = require("installer.crc32")
local VERSION  = require("kernel.version")

local M = {}

-- ===============================================================
-- 常量
-- ===============================================================

local CFG_PATH = "/delin-install.cfg"
local LOG_PATH = "/delin-install.log" -- 安装日志: CC 电脑读不了屏, 装完/装挂了都要能被宿主机读回

-- 默认安装源: 发布树由 CI(.github/workflows/release.yml)在打 v* tag 时推到 release 分支,
-- 路径 <版本>/ 下就是 manifest + payload/ + install.lua。版本号取内核版本号唯一真源,
-- 于是"升版本"不会留下指向旧版本的默认源(那会静默装上旧内核)。
local DEFAULT_URL = string.format(
    "https://raw.githubusercontent.com/Hello-World2333/delin/release/%s", VERSION)
local IMAGE_REL = "parts/root.img"    -- ext2 镜像在目标上的相对路径(摘要页与安装共用)

-- 骨架目录: 全新安装必须自己建, 否则 login/日志/挂载点都不存在
local SKELETON = {
    "bin", "boot", "dev", "etc", "etc/systemd/system", "home", "home/alice",
    "lib", "lib/modules", "lib/systemd/system", "mnt", "proc", "root", "run",
    "sys", "tmp", "var", "var/log",
}

-- payload 里需要可执行位的路径前缀
local EXEC_PREFIXES = { "bin/", "lib/modules/" }

-- 向导里能改的配置文件键(保存时按这个顺序写回, 别的键丢弃)
local CFG_KEYS = { "url", "type", "target", "size", "auto" }

-- ===============================================================
-- 安装日志(屏幕 + 落盘)
-- ===============================================================

local function logReset()
    local f = fs.open(LOG_PATH, "w")
    if f then f.close() end
end

--- 既 print 又写日志。CC 电脑读不了屏, 所以安装过程的每一步都必须落盘。
local function report(s)
    s = tostring(s or "")
    print(s)
    local f = fs.open(LOG_PATH, "a")
    if f then f.writeLine(s); f.close() end
end

--- 只写日志不上屏。向导每一步/每个文本输入都留一行, 于是"卡在哪一步"从宿主机读日志
--- 就知道(真机自动化验证也是靠这些行同步注入按键的时机)。
local function logLine(s)
    local f = fs.open(LOG_PATH, "a")
    if f then f.writeLine(tostring(s or "")); f.close() end
end

-- ===============================================================
-- 终端小工具
-- ===============================================================

local W, H     -- 屏幕尺寸(每步重读, 允许用户中途改分辨率)
local progress -- 安装进度行(前向声明; M.run 里赋值)

local HELP_SELECT = "Up/Down select   Enter confirm   Backspace back   Q quit"
local HELP_INPUT  = "Type to edit   Enter confirm   Left/Right move   Backspace delete/back"

--- 读一次屏幕尺寸。
local function size()
    W, H = term.getSize()
end

--- 在 y 行写一整行(先清行, 超宽截断)。返回 y + 1。
--- bg 决定整行的背景色(clearLine 用当前背景色填充), 反显高亮就是这么来的。
local function put(y, text, fg, bg)
    text = tostring(text or "")
    if #text > W then text = text:sub(1, W) end
    term.setCursorPos(1, y)
    term.setBackgroundColor(bg or colors.black)
    term.setTextColor(fg or colors.white)
    term.clearLine()
    term.write(text)
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    return y + 1
end

--- 黑底清屏 + 光标归位(向导每个步骤重画整屏, 不做增量刷新)。
local function clear()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.white)
    term.setCursorBlink(false)
end

--- 蓝色标题栏, 右上角带步骤号。
local function banner(text, tag)
    local line = " " .. tostring(text)
    if tag then
        local pad = W - #line - #tag - 2
        if pad < 1 then pad = 1 end
        line = line .. string.rep(" ", pad) .. tag .. " "
    end
    put(1, line, colors.white, colors.blue)
end

--- 底部帮助行(灰条)。
local function helpLine(text)
    put(H, text, colors.black, colors.gray)
end

--- 画一屏: 标题 -> 正文行 -> 选项(光标行反显) -> 错误提示 -> 帮助行。
---@param items table { { value = any, label = string, desc = string|nil }, ... }
---@param cursor number 光标所在项(1 起)
---@param body table|nil 标题与选项之间的说明行(字符串数组, 灰色)
---@param note string|nil 红色错误提示(单选列表上的"上一步失败了"这类信息)
local function drawSelect(title, tag, items, cursor, body, note)
    size()
    clear()
    banner("Delin Installer", tag)
    local y = put(3, title, colors.white)
    if body then
        y = y + 1
        for _, line in ipairs(body) do y = put(y, line, colors.lightGray) end
    end
    y = y + 1
    for i, it in ipairs(items) do
        local cur = (i == cursor)
        local text = string.format("%s %s %s", cur and ">" or " ", cur and "[x]" or "[ ]", it.label)
        if it.desc then text = text .. "   " .. it.desc end
        y = put(y, text, cur and colors.black or colors.white, cur and colors.lightGray or nil)
    end
    if note then put(H - 1, "! " .. note, colors.red) end
    helpLine(HELP_SELECT)
end

--- 单选: 上下移动光标, 回车确认。返回 items[cursor].value; 或 nil, "back"/"quit"。
local function selectStep(title, tag, items, cursor, body, note)
    while true do
        drawSelect(title, tag, items, cursor, body, note)
        local ev, p1 = os.pullEvent()
        if ev == "key" then
            if p1 == keys.up then
                cursor = (cursor > 1) and (cursor - 1) or #items
            elseif p1 == keys.down then
                cursor = (cursor < #items) and (cursor + 1) or 1
            elseif p1 == keys.enter then
                return items[cursor].value
            elseif p1 == keys.backspace then
                return nil, "back"
            elseif p1 == keys.q then
                return nil, "quit"
            end
        end
    end
end

--- 单行文本输入(插入/删除/左右移动, 用终端自己的光标当插入点)。
--- 文本输入里 Q 是普通字符; 返回上一步靠"行首再按一次退格"。
--- 返回 text; 或 nil, "back"。
local function inputStep(title, tag, value, hint, note)
    local pos = #value
    logLine("wizard input: " .. title)
    while true do
        size()
        clear()
        banner("Delin Installer", tag)
        local y = put(3, title, colors.white)
        if hint then y = put(y, "  " .. hint, colors.lightGray) end
        local inputRow = y + 1
        y = put(inputRow, "> " .. value, colors.white)
        y = put(y, string.rep("-", math.min(#value + 2, W)), colors.gray)
        if note then put(y + 1, "! " .. note, colors.red) end
        helpLine(HELP_INPUT)
        term.setCursorPos(3 + pos, inputRow)
        term.setCursorBlink(true)

        local ev, p1 = os.pullEvent()
        if ev == "char" then
            local ch = tostring(p1)
            value = value:sub(1, pos) .. ch .. value:sub(pos + 1)
            pos = pos + #ch
        elseif ev == "key" then
            if p1 == keys.enter then
                term.setCursorBlink(false)
                return value
            elseif p1 == keys.backspace then
                if pos > 0 then
                    value = value:sub(1, pos - 1) .. value:sub(pos + 1)
                    pos = pos - 1
                else
                    term.setCursorBlink(false)
                    return nil, "back" -- 行首再退格 = 回上一步(没有 Esc 可用, 见下)
                end
            elseif p1 == keys.left then
                if pos > 0 then pos = pos - 1 end
            elseif p1 == keys.right then
                if pos < #value then pos = pos + 1 end
            end
        end
    end
end

--- 画一屏"正在忙"的提示(网络请求期间给用户反馈, 否则屏幕静止看不出在动)。
local function showBusy(title, tag, text)
    size()
    clear()
    banner("Delin Installer", tag)
    local y = put(3, title, colors.white)
    put(y + 1, "  " .. text, colors.lightGray)
    helpLine("please wait ...")
end

--- 等一个按键(不关心的其它事件丢掉)。返回 key 码。
local function waitKey()
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "key" then return p1 end
    end
end

local function human(bytes)
    if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / 1024 / 1024) end
    if bytes >= 1024 then return string.format("%.1f KB", bytes / 1024) end
    return tostring(bytes) .. " B"
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ===============================================================
-- 安装源配置
-- ===============================================================

--- 读安装配置。向导只改 url; 无人值守安装可以写齐
---   url <安装源>  type ccfs|ext2  target computer|<盘名>  size auto|<KB>  auto 1
local function loadConfig()
    local cfg = { url = DEFAULT_URL }
    local f = fs.open(CFG_PATH, "r")
    if f then
        local text = f.readAll(); f.close()
        for line in text:gmatch("[^\r\n]+") do
            local k, v = line:match("^(%S+)%s+(%S+)$")
            if k then cfg[k] = v end
        end
    end
    return cfg
end

--- 写回配置(已知键按固定顺序, 其余丢弃 —— 免得旧文件里的垃圾键被一直带着走)。
local function saveConfig(cfg)
    local f = fs.open(CFG_PATH, "w")
    if not f then return nil, "cannot write " .. CFG_PATH end
    for _, k in ipairs(CFG_KEYS) do
        if cfg[k] then f.writeLine(k .. " " .. tostring(cfg[k])) end
    end
    f.close()
    return true
end

local function urlJoin(base, rel)
    return (base:gsub("/+$", "")) .. "/" .. rel
end

-- ===============================================================
-- http
-- ===============================================================

local function httpGet(url)
    if not http then return nil, "http API is disabled on this server" end
    local res = http.get({ url = url, binary = true })
    if not res then return nil, "request failed: " .. url end
    local code = res.getResponseCode and res.getResponseCode() or 200
    if code ~= 200 then
        res.close()
        return nil, string.format("http %d: %s", code, url)
    end
    return res
end

local function fetchText(url)
    local res, err = httpGet(url)
    if not res then return nil, err end
    local body = res.readAll()
    res.close()
    return body
end

-- ===============================================================
-- 发布清单
-- ===============================================================

---   version <版本>
---   files <个数>
---   <相对路径> <字节数> <crc32 hex>      (相对 payload/)
local function parseManifest(text)
    local mf = { version = nil, count = nil, files = {} }
    local n = 0
    for line in text:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            n = n + 1
            if n == 1 then
                local v = line:match("^version%s+(%S+)$")
                if not v then return nil, "manifest: 第一行必须是 'version <版本>'" end
                mf.version = v
            elseif n == 2 and line:match("^files%s+%d+$") then
                mf.count = tonumber(line:match("^files%s+(%d+)$"))
            else
                local path, size, crc = line:match("^(%S+)%s+(%d+)%s+(%x+)$")
                if not path then return nil, "manifest: 无法解析: " .. line end
                mf.files[#mf.files + 1] = { path = path, size = tonumber(size), crc = crc }
            end
        end
    end
    if #mf.files == 0 then return nil, "manifest: 没有任何文件" end
    if mf.count and mf.count ~= #mf.files then
        return nil, string.format("manifest: 声明 %d 个文件, 实得 %d 个", mf.count, #mf.files)
    end
    return mf
end

local function manifestBytes(mf)
    local n = 0
    for _, f in ipairs(mf.files) do n = n + f.size end
    return n
end

--- 拉并解析清单。返回 mf, 或 nil, err(错误消息是给人看的, 会直接显示在屏幕上)。
local function fetchManifest(base)
    local text, err = fetchText(urlJoin(base, "manifest"))
    if not text then return nil, "cannot fetch manifest: " .. tostring(err) end
    local mf, merr = parseManifest(text)
    if not mf then return nil, "bad manifest: " .. tostring(merr) end
    return mf
end

-- ===============================================================
-- 目标抽象: CC 原生文件系统 或 ext2 镜像
-- ===============================================================

--- CC 原生文件系统目标(root = "" 电脑自身存储, 或 "disk" 等挂载路径)。
local function ccTarget(root)
    root = root or ""
    local t = { kind = "ccdisk", label = (root == "") and "computer storage" or root, root = root }
    local function p(rel) return root .. "/" .. rel end

    function t.mkdirp(rel)
        if fs.exists(p(rel)) then
            if not fs.isDir(p(rel)) then return nil, "not a directory: " .. p(rel) end
            return true
        end
        fs.makeDir(p(rel))
        if not fs.isDir(p(rel)) then return nil, "mkdir failed: " .. p(rel) end
        return true
    end

    function t.write(rel, data)
        local f, err = fs.open(p(rel), "w")
        if not f then return nil, tostring(err) end
        f.write(data)
        f.close()
        return true
    end

    function t.read(rel)
        local f = fs.open(p(rel), "r")
        if not f then return nil end
        local d = f.readAll(); f.close()
        return d
    end

    function t.exists(rel) return fs.exists(p(rel)) end
    function t.setMode() return true end -- ccdisk 没有权限位
    function t.free() return fs.getFreeSpace(root == "" and "/" or root) end
    return t
end

--- ext2 镜像目标(块设备 + 已 mkfs 的 fs 描述)。
local function ext2Target(bd, mfs)
    local t = { kind = "ext2" }

    function t.mkdirp(rel)
        rel = rel:gsub("^/+", "")
        local cur = ""
        for seg in rel:gmatch("[^/]+") do
            local path = cur .. "/" .. seg
            if not ext2.lookup(mfs, path) then
                local ok, err = ext2.create(mfs, (cur == "") and "/" or cur, seg, 0x4000 + 493) -- 0755
                if not ok then return nil, string.format("mkdir %s: %s", path, tostring(err)) end
                if path == "/home/alice" then
                    ext2.chown(mfs, path, 1000, 1000) -- 与 /etc/passwd 的 alice 一致
                end
            end
            cur = path
        end
        return true
    end

    function t.write(rel, data)
        rel = rel:gsub("^/+", "")
        local dir, name = rel:match("^(.*)/([^/]+)$")
        if not dir then dir, name = "", rel end
        local abs = "/" .. ((dir == "") and name or (dir .. "/" .. name))
        -- 注意: ext2.lookup 返回的是 **inode 表**, 而 ext2.writeFile 要的是 **inode 号** ——
        -- 这里踩过一次(游戏内表现为抛错后静默卡住, 因为屏幕读不到)。
        local inode = ext2.lookup(mfs, abs)
        if not inode then
            local ino, err = ext2.create(mfs, (dir == "") and "/" or ("/" .. dir), name, 0x8000 + 420) -- 0644
            if not ino then return nil, tostring(err) end
            inode = { ino = ino }
        end
        local ok, err = ext2.writeFile(mfs, inode.ino, data)
        if not ok then return nil, tostring(err) end
        return true
    end

    function t.exists(rel) return ext2.lookup(mfs, "/" .. rel:gsub("^/+", "")) ~= nil end
    function t.setMode(rel, mode) ext2.chmod(mfs, "/" .. rel:gsub("^/+", ""), mode); return true end
    function t.free() return nil end
    return t
end

-- ===============================================================
-- 设备枚举
-- ===============================================================

--- 可安装目标: 电脑自身存储 + 每个有数据的磁盘驱动器。
local function listTargets()
    local out = { { kind = "computer", name = "computer storage", free = fs.getFreeSpace("/") } }
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "drive" and disk.hasData(name) then
            local mp = disk.getMountPath(name)
            out[#out + 1] = { kind = "drive", name = name, mp = mp, free = fs.getFreeSpace(mp) }
        end
    end
    return out
end

--- 按配置里的 target 找到目标(名字或序号)。
local function pickTarget(cfg, targets)
    local want = cfg.target
    if not want then return 1 end
    local n = tonumber(want)
    if n and targets[n] then return n end
    for i, t in ipairs(targets) do
        if t.name == want or t.name:sub(1, #want) == want then return i end
    end
    return nil
end

--- 引导配置方案: 返回 /.boot 的内容, 以及 /dlub.cfg 那一行(nil = 不用 DLUB)。
--- 摘要页与安装过程共用这一份判断 —— 两处各写一遍迟早会不一致。
local function bootPlan(state, tgt)
    local useDlub = (state.type == "ext2") or (tgt.kind == "drive")
    if not useDlub then return "/boot/delin.lua" end
    local line
    if state.type == "ext2" then
        line = (tgt.kind == "computer") and ("rootfs /" .. IMAGE_REL) or ("bootdisk " .. tgt.name)
    else
        line = "ccdisk " .. tgt.name
    end
    return "/boot/dlub.lua", line
end

-- ===============================================================
-- 安装
-- ===============================================================

--- 建骨架目录。
local function makeSkeleton(t)
    for _, d in ipairs(SKELETON) do
        local ok, err = t.mkdirp(d)
        if not ok then return nil, err end
    end
    return true
end

--- 下载并把 payload 铺到目标。
local function writePayload(t, mf, base)
    for i, f in ipairs(mf.files) do
        progress(i, #mf.files, f.path)
        local res, err = httpGet(urlJoin(base, "payload/" .. f.path))
        if not res then return nil, err end
        local data = res.readAll()
        res.close()
        if #data ~= f.size then
            return nil, string.format("%s: 大小不符(期望 %d, 实得 %d)", f.path, f.size, #data)
        end
        local got = crc32.hex(crc32.of(data))
        if got ~= f.crc then
            return nil, string.format("%s: CRC32 不符(期望 %s, 实得 %s)", f.path, f.crc, got)
        end
        local dir = f.path:match("^(.*)/[^/]+$")
        if dir then
            local ok, derr = t.mkdirp(dir)
            if not ok then return nil, derr end
        end
        local ok, werr = t.write(f.path, data)
        if not ok then return nil, werr end
        for _, pre in ipairs(EXEC_PREFIXES) do
            if f.path:sub(1, #pre) == pre then t.setMode(f.path, 493) end -- 0755
        end
    end
    return true
end

--- ext2 镜像需要的块数(自动档): payload + 元数据 + 目录余量, 再上浮 15%, 对齐 64 块。
local function autoBlocks(payloadBytes)
    local blocks = math.ceil((math.ceil(payloadBytes / 1024) + 37 + 32) * 1.15 / 64) * 64
    if blocks < 256 then blocks = 256 end
    if blocks > 8192 then blocks = 8192 end
    return blocks
end

--- 在 hostT 上建 ext2 镜像并把 payload 铺进镜像。
local function installExt2Image(hostT, blocks, mf, base)
    local ok, err = hostT.mkdirp("parts")
    if not ok then return nil, err end
    local imgAbs = hostT.root .. "/" .. IMAGE_REL

    -- blockdev 用 "r+" 打开, 文件必须先存在
    local f, ferr = fs.open(imgAbs, "w")
    if not f then return nil, "cannot create " .. imgAbs .. ": " .. tostring(ferr) end
    f.close()

    local bd, berr = blockdev.file(imgAbs)
    if not bd then return nil, "blockdev: " .. tostring(berr) end
    local mfs, merr = ext2.mkfs(bd, { blocks = blocks, label = "delin" })
    if not mfs then bd.close(); return nil, "mkfs: " .. tostring(merr) end

    local et = ext2Target(bd, mfs)
    local sok, serr = makeSkeleton(et)
    if not sok then bd.close(); return nil, serr end
    local wok, werr = writePayload(et, mf, base)
    if not wok then bd.close(); return nil, werr end
    bd.close()
    return true
end

--- 一次完整安装。要求 state.mf 已就绪(向导在"安装源"步骤就拉到了; 无人值守路径在调用前拉)。
--- 返回 true; 或 false, err —— 失败原因由调用者 report 出来, 本函数只负责"别留半成品"。
local function runInstall(state, targets)
    local tgt = targets[state.target]
    local mf = assert(state.mf, "installer: manifest not fetched")
    local need = manifestBytes(mf)
    local entry, dlubLine = bootPlan(state, tgt)
    local blocks = (state.type == "ext2") and (state.sizeAuto and autoBlocks(need) or state.sizeKb) or nil

    size()
    clear()
    banner("Delin Installer", "installing")
    term.setCursorPos(1, 2)
    report("Delin installer")
    report("  source : " .. state.url)
    report("  type   : " .. state.type)
    report("  target : " .. tgt.name .. "  (free " .. human(tgt.free or 0) .. ")")
    report("  files  : " .. #mf.files .. " (" .. human(need) .. ")")
    if blocks then
        report(string.format("  image  : %d KB%s", blocks, state.sizeAuto and " (auto)" or ""))
    end
    report("  boot   : /.boot = " .. entry .. (dlubLine and ("   /dlub.cfg = " .. dlubLine) or ""))
    report("")

    -- 1) 空间预检(CCFS 直接铺文件时能提前发现装不下)
    if state.type == "ccfs" then
        if tgt.free and tgt.free < need + 4096 then
            return false, string.format("target has %s free, need %s", human(tgt.free), human(need))
        end
    end

    -- 2) 铺 payload
    if state.type == "ccfs" then
        local pt = ccTarget(tgt.kind == "computer" and "" or tgt.mp)
        local ok, perr = makeSkeleton(pt)
        if not ok then return false, tostring(perr) end
        report("copying files ...")
        local wok, werr = writePayload(pt, mf, state.url)
        if not wok then return false, tostring(werr) end
    else
        local hostT = ccTarget(tgt.kind == "computer" and "" or tgt.mp)
        report("making ext2 image: " .. tostring(blocks) .. " KB ...")
        local ok, berr = installExt2Image(hostT, blocks, mf, state.url)
        if not ok then return false, tostring(berr) end
        report("image ready: " .. IMAGE_REL .. " (" .. tostring(blocks) .. " KB)")
        -- bootdisk 模式需要分区清单
        if tgt.kind == "drive" then
            local mok, merman = hostT.write("parts/manifest", "root /parts/root.img ext2\nboot /boot/delin.lua\n")
            if not mok then return false, "manifest -> " .. tostring(merman) end
        end
    end

    -- 3) 引导配置(始终写在**电脑自身存储**上: BIOS 开机只跑 /startup.lua)
    local boot = ccTarget("")
    report("writing boot config ...")

    -- 3a) BIOS(旧的备份一次)
    if boot.exists("startup.lua") and not boot.exists("startup.lua.craftos") then
        local old = boot.read("startup.lua")
        if old then
            boot.write("startup.lua.craftos", old)
            report("  backup /startup.lua -> /startup.lua.craftos")
        end
    end
    local bios, biosErr = fetchText(urlJoin(state.url, "payload/startup.lua"))
    if not bios then return false, tostring(biosErr) end
    local okBio, eBio = boot.write("startup.lua", bios)
    if not okBio then return false, "/startup.lua -> " .. tostring(eBio) end

    -- 3b) 内核入口 + DLUB + /dlub.cfg
    local function fetchTo(t, rel, urlRel, label)
        local d, derr = fetchText(urlJoin(state.url, urlRel))
        if not d then return nil, label .. ": " .. tostring(derr) end
        local dir = rel:match("^(.*)/[^/]+$")
        if dir then t.mkdirp(dir) end
        local ok, werr = t.write(rel, d)
        if not ok then return nil, label .. ": " .. tostring(werr) end
        return true
    end

    if dlubLine then
        local ok1, e1 = fetchTo(boot, "boot/dlub.lua", "payload/boot/dlub.lua", "DLUB")
        if not ok1 then return false, tostring(e1) end
        local okC, eC = boot.write("dlub.cfg", dlubLine .. "\n")
        if not okC then return false, "/dlub.cfg -> " .. tostring(eC) end
        report("  /dlub.cfg = " .. dlubLine)
    else
        local ok1, e1 = fetchTo(boot, "boot/delin.lua", "payload/boot/delin.lua", "kernel")
        if not ok1 then return false, tostring(e1) end
    end

    local okB, eB = boot.write(".boot", entry)
    if not okB then return false, "/.boot -> " .. tostring(eB) end
    report("  /.boot = " .. entry)

    report("")
    report("Install OK.")
    return true
end

-- ===============================================================
-- 向导
-- ===============================================================

--- 安装方式。
local TYPE_ITEMS = {
    { value = "ccfs", label = "CCFS", desc = "copy files onto the target" },
    { value = "ext2", label = "EXT2", desc = "build an ext2 image on the target" },
}

local TYPE_DESC = { ccfs = "copy files onto the target", ext2 = "build an ext2 image on the target" }

--- 步骤 1: 安装方式。
local function stepType(tag, state)
    local cursor = (state.type == "ext2") and 2 or 1
    local v, reason = selectStep("Install type", tag, TYPE_ITEMS, cursor)
    if not v then return reason end
    state.type = v
    logLine("wizard type: " .. v)
    return "next"
end

--- 步骤 2: 目标设备。
local function stepTarget(tag, state, targets)
    local items = {}
    for i, t in ipairs(targets) do
        items[i] = { value = i, label = t.name, desc = "free " .. human(t.free or 0) }
    end
    local v, reason = selectStep("Install target", tag, items, state.target)
    if not v then return reason end
    state.target = v
    logLine("wizard target: " .. targets[v].name)
    return "next"
end

--- 步骤 3: 安装源。预置源(上次用过的 + 内置默认) + 手输。
--- 选完就拉一次 manifest —— 源不通当场看得见, 不必等到开始装才失败。
local function stepSource(tag, state, cfg)
    local items = {}
    local seen = {}
    local function addPreset(u)
        if u and u ~= "" and not seen[u] then
            seen[u] = true
            items[#items + 1] = { value = u, label = u }
        end
    end
    addPreset(state.url)
    addPreset(DEFAULT_URL)
    items[#items + 1] = { value = "custom", label = "custom ...", desc = "type a URL" }

    local cursor = 1
    for i, it in ipairs(items) do if it.value == state.url then cursor = i end end

    local note = nil
    while true do
        local chosen, reason = selectStep("Install source", tag, items, cursor, nil, note)
        if not chosen then return reason end
        local url = chosen
        if chosen == "custom" then
            cursor = #items
            local text, r2 = inputStep("Install source - custom URL", tag, "",
                "http://<host>/<version>", note)
            if not text then
                if r2 == "back" then
                    note = nil -- 回到预置列表
                    url = nil
                else
                    return r2
                end
            else
                url = trim(text)
                if url == "" then url = nil end
            end
        end
        if url then
            if not url:match("^https?://") then
                note = "URL must start with http:// or https://"
            else
                showBusy("Install source", tag, "fetching manifest from " .. url .. " ...")
                local mf, merr = fetchManifest(url)
                if not mf then
                    note = merr
                else
                    state.url, state.mf = url, mf
                    logLine(string.format("wizard source: %s (version %s, %d files)",
                        url, tostring(mf.version), #mf.files))
                    local ok, serr = saveConfig({ url = url })
                    if not ok then note = "warning: " .. tostring(serr) end
                    return "next"
                end
            end
        end
    end
end

--- 步骤 4(仅 EXT2): 镜像大小。预置值 + 自定义手输。
local function stepSize(tag, state)
    local items = {
        { value = "auto", label = "auto", desc = "size the image from the payload" },
        { value = 256,    label = "256 KB" },
        { value = 512,    label = "512 KB" },
        { value = 768,    label = "768 KB" },
        { value = 1024,   label = "1024 KB" },
        { value = "custom", label = "custom ...", desc = "type a size in KB" },
    }
    local cursor = 1
    for i, it in ipairs(items) do
        if (state.sizeAuto and it.value == "auto") or (not state.sizeAuto and it.value == state.sizeKb) then
            cursor = i
        end
    end

    while true do
        local v, reason = selectStep("Image size", tag, items, cursor)
        if not v then return reason end
        if v == "custom" then
            cursor = #items
            local note = nil
            while true do
                -- 自定义容量从空串开始(不要预填当前值: 改数字得先擦掉, 手输一串更干脆)
                local text, r2 = inputStep("Image size (KB)", tag, "", "64 - 8192", note)
                if not text then
                    if r2 == "back" then break end -- 回到预置列表
                    return r2
                end
                local n = tonumber(trim(text))
                if not n or n ~= math.floor(n) or n < 64 or n > 8192 then
                    note = "enter a whole number between 64 and 8192"
                else
                    state.sizeAuto, state.sizeKb = false, n
                    logLine("wizard size: custom " .. tostring(n) .. " KB")
                    return "next"
                end
            end
        else
            if v == "auto" then
                state.sizeAuto = true
            else
                state.sizeAuto, state.sizeKb = false, v
            end
            logLine("wizard size: " .. (state.sizeAuto and "auto" or (tostring(state.sizeKb) .. " KB")))
            return "next"
        end
    end
end

--- 步骤 5: 摘要确认。Cancel = 退回上一步接着改。
local function stepSummary(tag, state, targets)
    local tgt = targets[state.target]
    local entry, dlubLine = bootPlan(state, tgt)
    local mf = assert(state.mf, "installer: manifest not fetched")
    local need = manifestBytes(mf)

    local body = {
        string.format("  install type : %s   (%s)", string.upper(state.type), TYPE_DESC[state.type]),
        string.format("  target       : %s   (free %s)", tgt.name, human(tgt.free or 0)),
        string.format("  source       : %s", state.url),
        string.format("  payload      : version %s, %d files, %s", tostring(mf.version), #mf.files, human(need)),
    }
    if state.type == "ext2" then
        local blocks = state.sizeAuto and autoBlocks(need) or state.sizeKb
        body[#body + 1] = string.format("  image size   : %s%d KB", state.sizeAuto and "auto -> " or "", blocks)
    end
    body[#body + 1] = "  boot config  : /.boot = " .. entry
    if dlubLine then body[#body + 1] = "                 /dlub.cfg = " .. dlubLine end

    local items = {
        { value = "install", label = "Start installation" },
        { value = "cancel",  label = "Cancel", desc = "go back and change the settings" },
    }
    local v, reason = selectStep("Summary", tag, items, 1, body)
    if not v then return reason end
    if v == "install" then
        logLine("wizard confirm: start installation")
        return "install"
    end
    logLine("wizard confirm: cancel")
    return "back"
end

--- 跑安装并把结果告诉用户: 装完/装挂都落日志(CC 电脑读不了屏)。
--- 装成功后**只有回车**才重启(其它键一律不处理: 免得手滑把向导又带回摘要页重装一遍);
--- 失败则按任意键回摘要页(可以改配置再来一次)。
local function installWithUi(state, targets)
    -- pcall 三返回值: 协程里抛的错(ok=nil)与 fail-fast 的 (false, err) 都要报出来
    local pok, ok, err = pcall(runInstall, state, targets)
    if not pok then ok, err = false, tostring(ok) end
    if ok then
        report("")
        report("Reboot to start Delin.")
        report("Press Enter to reboot now (other keys are ignored).")
        while waitKey() ~= keys.enter do end -- 回车: 重启; 其它键: 什么都不做
        os.reboot()
    else
        report("FAIL: " .. tostring(err))
        report("")
        report("Install FAILED (details above and in " .. LOG_PATH .. ").")
        report("Press any key to go back to the summary.")
        waitKey()
    end
end

--- 向导主循环。返回 true = 装过(或退出时已确认), false = 用户放弃。
local function wizard(cfg, targets)
    local state = {
        type = "ccfs", target = 1, url = cfg.url or DEFAULT_URL,
        sizeAuto = true, sizeKb = 512, mf = nil,
    }
    local step = 1
    while true do
        local steps = { "type", "target", "source" }
        if state.type == "ext2" then steps[#steps + 1] = "size" end
        steps[#steps + 1] = "summary"
        if step > #steps then step = #steps end
        local name = steps[step]
        local tag = string.format("step %d/%d", step, #steps)
        logLine("wizard " .. tag .. ": " .. name)

        local action
        if name == "type" then
            action = stepType(tag, state)
        elseif name == "target" then
            action = stepTarget(tag, state, targets)
        elseif name == "source" then
            action = stepSource(tag, state, cfg)
        elseif name == "size" then
            action = stepSize(tag, state)
        else
            action = stepSummary(tag, state, targets)
        end

        if action == "quit" then return false end
        if action == "back" then
            if step == 1 then return false end -- 第一步再退 = 退出
            step = step - 1
        elseif action == "next" then
            step = step + 1
        elseif action == "install" then
            installWithUi(state, targets) -- 装完停在摘要页
        end
    end
end

function M.run()
    size()
    logReset() -- 一次运行一份日志: 向导走了什么、装了什么, 都在里面
    local cfg = loadConfig()
    local targets = listTargets()
    progress = function(i, n, path)
        put(H, string.format("  [%d/%d] %s", i, n, path), colors.black, colors.gray)
    end

    -- 无人值守: /delin-install.cfg 里写 auto 1 (可选 type/target/size)。
    -- 用途: 真机自动化验证, 以及"用户碰不到机器"的批量安装。
    if cfg.auto == "1" then
        local state = {
            type = "ccfs", target = 1, url = cfg.url or DEFAULT_URL,
            sizeAuto = true, sizeKb = 512, mf = nil,
        }
        if cfg.type == "ext2" then state.type = "ext2" end
        if cfg.size and cfg.size ~= "auto" then
            local n = tonumber(cfg.size)
            if n then state.sizeAuto = false; state.sizeKb = math.floor(n) end
        end
        local idx = pickTarget(cfg, targets)
        if not idx then
            clear()
            report("FAIL: no such target: " .. tostring(cfg.target))
            return
        end
        state.target = idx
        -- 任何 Lua 级错误都要落盘: CC 电脑读不了屏, 静默卡住最难查。
        local mf, merr = fetchManifest(state.url)
        if not mf then
            clear()
            report("FAIL: " .. tostring(merr))
            return
        end
        state.mf = mf
        local pok, ok, err = pcall(runInstall, state, targets)
        if not pok then
            report("FAIL: " .. tostring(ok))
        elseif not ok then
            report("FAIL: " .. tostring(err))
        end
        return
    end

    if not wizard(cfg, targets) then
        clear()
        print("Install cancelled.")
    end
end

return M
