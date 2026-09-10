--[[ Delin 安装器(CraftOS 程序; tools/bundle.lua 把它连同 blockdev/ext2/crc32 打成单文件
     dist/install.lua)。
     用法(游戏内):
         wget run http://<host>:10568/<版本>/install.lua
     然后在 TUI 里选安装类型/目标设备/安装源, 按 I 开始装。

     它做什么:
       - 从 http 安装源(发布树)拉 manifest, 再逐文件下载 payload/ 并校验 size + CRC32;
       - 把 payload 铺到目标: CCFS(直接铺文件) 或 EXT2(现场 mkfs 出镜像再写进去);
       - 写引导配置: /startup.lua(Delin BIOS, 旧的备份成 /startup.lua.craftos)、
         /boot/{delin.lua,dlub.lua}、/.boot、/dlub.cfg;
       - 装完提示重启。

     引导链(安装器产出的东西必须与它一致):
         CraftOS 开机跑 <电脑自身存储>/startup.lua = Delin BIOS
         BIOS 扫设备找 /.boot → 读里面的路径 → loadfile
         所以 **引导入口固定在电脑自身存储上**, 三种形态:
           CCFS(装到电脑存储)  /.boot = /boot/delin.lua   内核就在电脑存储上
           CCFS(装到磁盘)      /.boot = /boot/dlub.lua    /dlub.cfg = ccdisk <盘名>
           EXT2(电脑存储或磁盘) /.boot = /boot/dlub.lua    /dlub.cfg = rootfs <镜像> | bootdisk <盘名>

     设计要点:
       - **不需要外部工具**: ext2 格式化与写入用的是内核同一份 ext2 驱动(打包进本文件),
         安装完全发生在游戏内; 宿主机只负责用静态 http 服务托管发布树(tools/serve.sh)。
       - **安装源只有 http**: 游戏侧碰不到服务器文件系统, 只能下载。
       - **fail-fast**: 校验不过 / 空间不够 / 目标非法一律报错返回, 不写半成品引导配置。
       - 输出全 ASCII(CC 终端打中文乱码)。 ]]

local blockdev = require("kernel.blockdev")
local ext2     = require("kernel.ext2")
local crc32    = require("installer.crc32")

local M = {}

-- ===============================================================
-- 常量
-- ===============================================================

local CFG_PATH = "/delin-install.cfg"
local LOG_PATH = "/delin-install.log" -- 安装日志: CC 电脑读不了屏, 装完/装挂了都要能被宿主机读回
local DEFAULT_URL = "http://127.0.0.1:10568/0.0.2"

-- 骨架目录: 全新安装必须自己建, 否则 login/日志/挂载点都不存在
local SKELETON = {
    "bin", "boot", "dev", "etc", "etc/systemd/system", "home", "home/alice",
    "lib", "lib/modules", "lib/systemd/system", "mnt", "proc", "root", "run",
    "sys", "tmp", "var", "var/log",
}

-- payload 里需要可执行位的路径前缀
local EXEC_PREFIXES = { "bin/", "lib/modules/" }

-- ===============================================================
-- 终端小工具
-- ===============================================================

local W, H

local function setColor(fg, bg)
    if fg then term.setTextColor(fg) end
    if bg then term.setBackgroundColor(bg) end
end

local function at(x, y, text, fg, bg)
    term.setCursorPos(x, y)
    setColor(fg, bg)
    term.clearLine()
    term.write(text or "")
    setColor(colors.white, colors.black)
end

local function clear()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    setColor(colors.white, colors.black)
end

local function waitKey()
    local _, key = os.pullEvent("key")
    return key
end

local function inputLine(prompt, default)
    clear()
    print(prompt)
    if default and default ~= "" then print("[" .. default .. "]") end
    write("> ")
    local line = read(nil, nil, nil, default or "")
    if line == nil then return default end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return default end
    return line
end

local function human(bytes)
    if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / 1024 / 1024) end
    if bytes >= 1024 then return string.format("%.1f KB", bytes / 1024) end
    return tostring(bytes) .. " B"
end

-- ===============================================================
-- 安装源配置
-- ===============================================================

--- 读安装配置。TUI 只写 url; 无人值守安装可以写齐
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

local function saveConfig(cfg)
    local f = fs.open(CFG_PATH, "w")
    if not f then return nil, "cannot write " .. CFG_PATH end
    f.writeLine("url " .. cfg.url)
    f.close()
    return true
end

local function urlJoin(base, rel)
    return (base:gsub("/+$", "")) .. "/" .. rel
end

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

-- ===============================================================
-- 安装
-- ===============================================================

local progress -- 前向声明

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

--- 在 hostT 上建 ext2 镜像并把 payload 铺进镜像。返回镜像相对 hostT 的路径。
local function installExt2Image(hostT, blocks, mf, base)
    local ok, err = hostT.mkdirp("parts")
    if not ok then return nil, err end
    local imgAbs = hostT.root .. "/parts/root.img"

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
    return "parts/root.img", blocks
end

--- 一次完整安装。
local function runInstall(state, targets)
    local tgt = targets[state.target]
    clear()
    logReset()
    report("Delin installer")
    report("  source : " .. state.cfg.url)
    report("  type   : " .. state.type)
    report("  target : " .. tgt.name .. "  (free " .. human(tgt.free or 0) .. ")")
    report("")

    -- 1) 清单
    local text, err = fetchText(urlJoin(state.cfg.url, "manifest"))
    if not text then report("FAIL: " .. err); return false end
    local mf, merr = parseManifest(text)
    if not mf then report("FAIL: " .. tostring(merr)); return false end
    local need = manifestBytes(mf)
    report("manifest: version " .. mf.version .. ", " .. #mf.files .. " files, " .. human(need))

    -- 2) 空间预检(CCFS 直接铺文件时能提前发现装不下)
    if state.type == "ccfs" then
        if tgt.free and tgt.free < need + 4096 then
            report(string.format("FAIL: target has %s free, need %s", human(tgt.free), human(need)))
            return false
        end
    end

    -- 3) 铺 payload
    local imageRel, imageBlocks
    if state.type == "ccfs" then
        local pt = ccTarget(tgt.kind == "computer" and "" or tgt.mp)
        local ok, perr = makeSkeleton(pt)
        if not ok then report("FAIL: " .. tostring(perr)); return false end
        report("copying files ...")
        local wok, werr = writePayload(pt, mf, state.cfg.url)
        if not wok then report("FAIL: " .. tostring(werr)); return false end
    else
        local hostT = ccTarget(tgt.kind == "computer" and "" or tgt.mp)
        local blocks = state.sizeAuto and autoBlocks(need) or state.sizeKb
        report("making ext2 image: " .. tostring(blocks) .. " KB ...")
        local rel, berr = installExt2Image(hostT, blocks, mf, state.cfg.url)
        if not rel then report("FAIL: " .. tostring(berr)); return false end
        imageRel, imageBlocks = rel, blocks
        report("image ready: " .. rel .. " (" .. tostring(blocks) .. " KB)")
        -- bootdisk 模式需要分区清单
        if tgt.kind == "drive" then
            local mok, merman = hostT.write("parts/manifest", "root /parts/root.img ext2\nboot /boot/delin.lua\n")
            if not mok then report("FAIL: manifest -> " .. tostring(merman)); return false end
        end
    end

    -- 4) 引导配置(始终写在**电脑自身存储**上: BIOS 开机只跑 /startup.lua)
    local boot = ccTarget("")
    report("writing boot config ...")

    -- 4a) BIOS(旧的备份一次)
    if boot.exists("startup.lua") and not boot.exists("startup.lua.craftos") then
        local old = boot.read("startup.lua")
        if old then
            boot.write("startup.lua.craftos", old)
            report("  backup /startup.lua -> /startup.lua.craftos")
        end
    end
    local bios, biosErr = fetchText(urlJoin(state.cfg.url, "payload/startup.lua"))
    if not bios then report("FAIL: " .. tostring(biosErr)); return false end
    local okBio, eBio = boot.write("startup.lua", bios)
    if not okBio then report("FAIL: /startup.lua -> " .. tostring(eBio)); return false end

    -- 4b) 内核入口 + DLUB + /dlub.cfg
    local useDlub = (state.type == "ext2") or (state.type == "ccfs" and tgt.kind == "drive")
    local bootEntry
    local function fetchTo(t, rel, urlRel, label)
        local d, derr = fetchText(urlJoin(state.cfg.url, urlRel))
        if not d then return nil, label .. ": " .. tostring(derr) end
        local dir = rel:match("^(.*)/[^/]+$")
        if dir then t.mkdirp(dir) end
        local ok, werr = t.write(rel, d)
        if not ok then return nil, label .. ": " .. tostring(werr) end
        return true
    end

    if useDlub then
        local ok1, e1 = fetchTo(boot, "boot/dlub.lua", "payload/boot/dlub.lua", "DLUB")
        if not ok1 then report("FAIL: " .. tostring(e1)); return false end
        bootEntry = "/boot/dlub.lua"
        local line
        if state.type == "ext2" then
            line = (tgt.kind == "computer") and ("rootfs /" .. imageRel) or ("bootdisk " .. tgt.name)
        else
            line = "ccdisk " .. tgt.name
        end
        local okC, eC = boot.write("dlub.cfg", line .. "\n")
        if not okC then report("FAIL: /dlub.cfg -> " .. tostring(eC)); return false end
        report("  /dlub.cfg = " .. line)
    else
        local ok1, e1 = fetchTo(boot, "boot/delin.lua", "payload/boot/delin.lua", "kernel")
        if not ok1 then report("FAIL: " .. tostring(e1)); return false end
        bootEntry = "/boot/delin.lua"
    end

    local okB, eB = boot.write(".boot", bootEntry)
    if not okB then report("FAIL: /.boot -> " .. tostring(eB)); return false end
    report("  /.boot = " .. bootEntry)

    report("")
    report("Install OK.  Reboot to start Delin.")
    report("Press R to reboot now, any other key to go back.")
    if waitKey() == keys.r then os.reboot() end
    return true
end

-- ===============================================================
-- TUI
-- ===============================================================

local function drawMenu(state, targets)
    W, H = term.getSize()
    clear()
    at(1, 1, " Delin Installer", colors.white, colors.blue)
    at(1, 2, " Install type  (T to switch):", colors.lightGray)
    at(3, 3, (state.type == "ccfs" and "(*)" or "( )") .. " CCFS - copy files onto the target")
    at(3, 4, (state.type == "ext2" and "(*)" or "( )") .. " EXT2 - build an ext2 image on the target")
    at(1, 6, " Target  (press the number):", colors.lightGray)
    for i, tgt in ipairs(targets) do
        local line = string.format("%d) %s   free %s", i, tgt.name, human(tgt.free or 0))
        at(3, 6 + i, (state.target == i and "(*)" or "( )") .. " " .. line)
    end
    local y = 6 + #targets + 2
    at(1, y, " Source : " .. state.cfg.url .. "   (U to edit)", colors.lightGray)
    if state.type == "ext2" then
        at(1, y + 1, " Size   : " .. (state.sizeAuto and "auto" or (tostring(state.sizeKb) .. " KB")) .. "   (S to change)", colors.lightGray)
    end
    at(1, H, " I=install  T=type  U=url  S=size  Q=quit", colors.black, colors.gray)
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

function M.run()
    W, H = term.getSize()
    local cfg = loadConfig()
    local state = { type = "ccfs", target = 1, cfg = cfg, sizeAuto = true, sizeKb = 512 }
    local targets = listTargets()
    progress = function(i, n, path)
        at(1, H - 1, string.format("  [%d/%d] %s", i, n, path), colors.lightGray)
    end

    -- 无人值守: /delin-install.cfg 里写 auto 1 (可选 type/target/size)。
    -- 用途: 真机自动化验证, 以及"用户碰不到机器"的批量安装。
    if cfg.auto == "1" then
        if cfg.type == "ext2" then state.type = "ext2" end
        if cfg.size and cfg.size ~= "auto" then
            local n = tonumber(cfg.size)
            if n then state.sizeAuto = false; state.sizeKb = math.floor(n) end
        end
        local idx = pickTarget(cfg, targets)
        if not idx then
            logReset()
            report("FAIL: no such target: " .. tostring(cfg.target))
            return
        end
        state.target = idx
        -- 任何 Lua 级错误都要落盘: CC 电脑读不了屏, 静默卡住最难查。
        local ok, err = pcall(runInstall, state, targets)
        if not ok then report("FAIL: " .. tostring(err)) end
        return
    end

    progress = function(i, n, path)
        at(1, H - 1, string.format("  [%d/%d] %s", i, n, path), colors.lightGray)
    end
    while true do
        drawMenu(state, targets)
        local k = waitKey()
        if k == keys.q then
            clear()
            return
        elseif k == keys.t then
            state.type = (state.type == "ccfs") and "ext2" or "ccfs"
        elseif k == keys.u then
            state.cfg.url = inputLine("Install source base URL", state.cfg.url)
            local ok, err = saveConfig(state.cfg)
            if not ok then print("warning: " .. tostring(err)) end
        elseif k == keys.s then
            local line = inputLine("Image size KB (auto / 256 / 512 / 768 / 1024)", state.sizeAuto and "auto" or tostring(state.sizeKb))
            if line == "auto" then
                state.sizeAuto = true
            else
                local n = tonumber(line)
                if n and n >= 64 and n <= 8192 then
                    state.sizeAuto = false
                    state.sizeKb = math.floor(n)
                end
            end
        elseif k == keys.i then
            local okRun, res = pcall(runInstall, state, targets)
            local ok = okRun and res
            if not okRun then report("FAIL: " .. tostring(res)) end
            if not ok then
                print("")
                print("Install FAILED (see above).")
                print("Press any key to return.")
                waitKey()
            end
        elseif k >= keys.one and k <= keys.nine then
            local idx = k - keys.one + 1
            if targets[idx] then state.target = idx end
        end
    end
end

return M
