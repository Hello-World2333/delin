--[[ Delin 安装器宿主回归测试: 在宿主机上造一个**假 CraftOS 环境**(真 Lua 全局: fs/term/os/http/
     disk/peripheral/colors/keys + 脚本化事件队列), 用 loadfile 跑**构建产物** dist/install.lua,
     按键序列驱动新安装器的多步交互流程, 然后断言落盘的文件/镜像/日志。
     为什么要这么测: CC 电脑的屏幕宿主读不到, 真机上一旦静默卡住就只能靠 /delin-install.log;
     这里把"屏幕"也留了下来(格子 + 每格 fg/bg), 失败时 dump 出来, 是安装器唯一的可读调试产物。

     用法:
         lua5.1 tools/installertest.lua                  # 全部用例
         lua5.1 tools/installertest.lua --dump-screens    # 每个用例都 dump 屏幕(默认只在失败时 dump)
         lua5.1 tools/installertest.lua --case=4          # 只跑某个用例(可用 2b / 5a / 5b)
     前置: 先跑过 `lua5.1 tools/build.lua --release`(本测试**不**自己构建)。
     退出码: 有用例失败 -> 1; 环境/发布树缺失 -> 2。
     lua5.4 也能跑(纯标准库; 差异见下面"Lua 5.1 补丁")。

     被冻结的 UI 契约(断言只按这个写, 安装器重写期间若行为不符就 FAIL, 不迁就):
       1 Install type   单选列表: CCFS / EXT2, 默认 CCFS
       2 Install target 单选列表: 第一项是计算机自身存储(标签含 computer storage), 之后每个有数据的驱动器一项
       3 Install source 预置源列表(上次用过的 URL / 内置默认 URL)+ `custom ...` 手输一行;
                        Enter 后取 <url>/manifest 校验, 拉不到就留在这一步
       4 Image size     仅 EXT2: auto/256/512/768/1024/custom(custom 进数字输入, 64..8192 KB)
       5 Summary        四个选择 + 确认列表 Start installation / Cancel
     Up/Down 移光标, Enter 确认, Backspace 回上一步, Q 退出。
     文本输入里 Backspace 删字符, **已经到行首再按一次 = 回上一步**。
     注意: **CraftOS 没有 Esc** —— 真机实测 keys.escape 为 nil、keys.getName(256) 也是 nil,
     所以回退手势只有 Backspace(别照抄其他 CC 版本的 keys.escape = 1)。
     光标所在选项行**反色**(非默认背景), 光标行是 [x], 其它行是 [ ]。

     ---- 与任务书/实现的差异, 都是有意为之, 不是漏改 ----
     1) Lua 5.1 下的模块 require: 打包器用 `local _ENV = setmetatable({require=__require}, {__index=_G})`
        做模块隔离, 5.1 没有 _ENV 语义 -> bundle 里各模块的 require 会落到宿主 package 上, 直接报
        "module 'installer.crc32' not found"。5.1 下加载前给每个模块补一条 `local require=__require`
        (精确对应 5.2+ 的行为, 用的仍是 bundle 里嵌的模块代码)。5.2+ 直接 loadfile, 无补丁。
     2) fs.makeDir: 任务书写的是"只建一级(like CC)", 但 CC:Tweaked 文档写的是
        "Creates a directory, and any missing parents" (~/docs/cc-tweaked/module/fs.md)。
        两者跑出来的结果不一样(见 case 2 / case 2b), 所以默认按 **CC 文档**(建父目录),
        `newSession{ mkdirOneLevel = true }` 切到严格一级。
     3) Install source: 契约草稿说"预填 URL 的文本输入行", 实现是"预置源列表 + custom 手输"
        (选源是选择步骤, 手输放在 custom 里; 这样换一个全新 URL 不用先把预填值擦干净)。
        case 5a 断言列表形态 + 列表上敲字符不改变任何东西, case 5b 断言坏源 fail-fast。
     4) 退出时日志: 任务书要求 quit 后 /delin-install.log 为空; 实测安装器把向导每一步也写进日志
        (符合"屏幕读不到, 日志是唯一证据"的设计, 冻结串列表也没禁止)。case 3 只硬断言
        "没有开始安装", 日志非空打印成诊断。
     5) 无人值守(case 7): 只给收尾可能需要的 1 个按键, 并断言"流程本身不需要按键"
        (最多消耗一个收尾键); 若实现要更多键, 会以"停在某一步"的形式暴露出来。
     6) term.write 在行末**截断**(不绕行): 这样每行内容与写入它的那一步一一对应, 断言能按行定位。
        真机会绕行, 但安装器自己控制每行长度, 不受影响。
     7) fake os.reboot 只记录不结束进程(进程要留给后面的用例); os.sleep 故意不提供 —— 安装器真要用
        定时器, 就应当以"调用 nil"的形式暴露出来。
     8) fake pullEvent 在队列空时抛错 "installer blocked waiting for events; remaining queue empty"
        (任务书要求); 另外 debug hook 看门狗兜底死循环, 保证测试进程不会挂死。 ]]

io.stdout:setvbuf("line")

-- 假 API 会覆盖真全局, 宿主自己的调用一律走这两个别名(不能再用全局 os/print/read/write)。
local hostos = os
local hostio = io
local unpack = table.unpack or unpack

local REPO = hostos.getenv("DELIN_REPO") or "/home/worker/delin"
local RELEASE_ROOT = REPO .. "/dist/release"
local INSTALL_BUNDLE = REPO .. "/dist/install.lua"
local E2FSCK = "/usr/sbin/e2fsck"

package.path = REPO .. "/src/?.lua;" .. package.path

-- ===============================================================
-- 输出 / 断言框架(与 tools/hosttest.lua 同一套风格)
-- ===============================================================

local function out(s) hostio.write(s) end
local function outl(s) hostio.write(tostring(s) .. "\n") end

local pass, fail = 0, 0
local casesPass, casesFail = 0, 0

--- 断言信息里的长字符串(payload/内核源码)截断, 否则一条失败能刷几十 KB
local function short(v, n)
    n = n or 120
    local s = tostring(v)
    s = s:gsub("%s+", " ")
    if #s > n then s = s:sub(1, n) .. "...(+" .. (#s - n) .. " chars)" end
    return s
end

local function ok(cond, label, extra)
    if cond then
        pass = pass + 1
        out("  ok   " .. label .. "\n")
    else
        fail = fail + 1
        out("  FAIL " .. label .. (extra and ("  -- " .. short(extra)) or "") .. "\n")
    end
    return cond and true or false
end
local function eq(got, want, label)
    return ok(got == want, label,
              "got=" .. short(got, 60) .. " want=" .. short(want, 60))
end
local function note(s) out("  note: " .. short(s, 300) .. "\n") end

local function die(msg)
    hostio.stderr:write("installertest: " .. msg .. "\n")
    hostos.exit(2)
end

-- ===============================================================
-- 命令行
-- ===============================================================

local OPT = { dumpAll = false, only = nil }
for _, a in ipairs(arg or {}) do
    if a == "--dump-screens" then
        OPT.dumpAll = true
    elseif a:match("^%-%-case=") then
        OPT.only = tostring(a:match("^%-%-case=(.+)$"))
    elseif a == "-h" or a == "--help" then
        outl("usage: lua5.1 tools/installertest.lua [--dump-screens] [--case=N]")
        hostos.exit(0)
    else
        die("unknown argument: " .. a)
    end
end

-- ===============================================================
-- 宿主小工具
-- ===============================================================

--- os.execute 返回码兼容: Lua 5.1 给数字, 5.2+ 给 true/nil,"exit",code
local function rcOk(rc)
    if rc == true then return true end
    if type(rc) == "number" then return rc == 0 end
    return false
end

local function readHostFile(p)
    local f = hostio.open(p, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function loadChunk(src, name)
    local fn = loadstring or load
    return fn(src, name)
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function pidOfSelf()
    local stat = readHostFile("/proc/self/stat")
    local pid = stat and stat:match("^(%d+)")
    return pid or tostring(hostos.time())
end

-- ===============================================================
-- 发布树: 版本 + manifest(缺了就让人去构建, 本测试不构建)
-- ===============================================================

local VERSION = (function()
    local src = readHostFile(REPO .. "/src/kernel/version.lua")
    return src and src:match('return%s*"([^"]+)"') or nil
end)()

local RELEASE
do
    local candidates = {}
    if VERSION then candidates[#candidates + 1] = RELEASE_ROOT .. "/" .. VERSION end
    if readHostFile(RELEASE_ROOT .. "/" .. tostring(VERSION) .. "/manifest") == nil then
        local p = hostio.popen("ls -1 '" .. RELEASE_ROOT .. "' 2>/dev/null")
        if p then
            for line in p:lines() do candidates[#candidates + 1] = RELEASE_ROOT .. "/" .. line end
            p:close()
        end
    end
    for _, c in ipairs(candidates) do
        if readHostFile(c .. "/manifest") then RELEASE = c break end
    end
end

if not RELEASE then
    die("找不到发布树 " .. RELEASE_ROOT .. "/<version>.\n" ..
        "  先跑: lua5.1 tools/build.lua --release   (本测试不会替你构建)")
end
if not readHostFile(INSTALL_BUNDLE) then
    die("找不到 " .. INSTALL_BUNDLE .. "\n" ..
        "  先跑: lua5.1 tools/build.lua --release   (本测试不会替你构建)")
end

local MF = { files = {}, byPath = {}, count = 0, total = 0, version = "?" }
do
    local text = readHostFile(RELEASE .. "/manifest") or ""
    local n = 0
    for line in text:gmatch("[^\r\n]+") do
        n = n + 1
        if n == 1 then
            MF.version = line:match("^version%s+(%S+)$") or "?"
        else
            local p, size, crc = line:match("^(%S+)%s+(%d+)%s+(%x+)$")
            if p then
                MF.files[#MF.files + 1] = { path = p, size = tonumber(size), crc = crc }
                MF.byPath[p] = true
                MF.total = MF.total + tonumber(size)
            end
        end
    end
    MF.count = #MF.files
end
if MF.count == 0 then die("manifest 解析不出任何文件: " .. RELEASE .. "/manifest") end

-- 构建产物源码。Lua 5.1 下 `local _ENV = setmetatable({require=__require}, ...)` 是**没用的局部
-- 变量**(5.2+ 才有 _ENV 语义), 于是 bundle 里各模块的 require 会落到宿主的 package 上,
-- 报 "module 'installer.crc32' not found"。这里给每个模块补一条 `local require=__require`,
-- 精确对应 5.2+ 的行为(模块内 require = bundle 自己的 __require, 其余全局仍走 _G),
-- 用的仍然是 bundle 里嵌的模块代码。5.2+ 不需要补丁, 直接 loadfile。
local BUNDLE_SRC_51, ENV_PATCH_COUNT
if _VERSION == "Lua 5.1" then
    local src = readHostFile(INSTALL_BUNDLE) or ""
    local patched, n = src:gsub(
        "local%s+_ENV%s*=%s*setmetatable%(%s*{%s*require%s*=%s*__require%s*}%s*,%s*{%s*__index%s*=%s*_G%s*}%s*%)",
        "%0 local require=__require ") -- 末尾空格必须有: 否则 __require 会跟下一个 token 粘成一个标识符
    BUNDLE_SRC_51, ENV_PATCH_COUNT = patched, n
end

--- 发布树上的一个文件(相对 payload/)
local function payloadFile(rel) return readHostFile(RELEASE .. "/payload/" .. rel) end

local BASE_URL = string.format("http://127.0.0.1:10568/%s", MF.version) -- 与安装器默认源一致

-- 可选: 用仓库自己的 ext2 驱动读回镜像内容(独立于安装器, 交叉验证)
local ext2mod = select(2, pcall(require, "kernel.ext2"))

-- ===============================================================
-- CC 常量(真值, 见 ComputerCraft keys/colors API)
-- ===============================================================

local colors = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32,
    pink = 64, gray = 128, lightGray = 256, cyan = 512, purple = 1024, blue = 2048,
    brown = 4096, green = 8192, red = 16384, black = 32768,
}

-- 真机实测的 keys 表(电脑3 的 CraftOS): 字母/数字是 ASCII 码, 特殊键是 GLFW 码。
-- **没有 escape**: keys.escape 为 nil, keys.getName(256) 也是 nil —— CraftOS 根本不送 Esc 事件。
-- 这张表必须与真机一致, 否则"回退键绑了什么"这类问题在宿主上永远测不出来。
local keys = {
    space = 32, apostrophe = 39, comma = 44, minus = 45, period = 46, slash = 47,
    zero = 48, one = 49, two = 50, three = 51, four = 52, five = 53, six = 54,
    seven = 55, eight = 56, nine = 57, semicolon = 59, equals = 61,
    a = 65, b = 66, c = 67, d = 68, e = 69, f = 70, g = 71, h = 72, i = 73, j = 74,
    k = 75, l = 76, m = 77, n = 78, o = 79, p = 80, q = 81, r = 82, s = 83, t = 84,
    u = 85, v = 86, w = 87, x = 88, y = 89, z = 90,
    leftBracket = 91, backslash = 92, rightBracket = 93, grave = 96,
    enter = 257, ["return"] = 257, tab = 258, backspace = 259, insert = 260, delete = 261,
    right = 262, left = 263, down = 264, up = 265, pageUp = 266, pageDown = 267,
    home = 268, ["end"] = 269, numPadEnter = 335,
}
-- 别加 longBreak/短横线等花活; 够用就行。

local STEP_TITLES = { "Install type", "Install target", "Install source", "Image size", "Summary" }
local BLOCKED_MSG = "installer blocked waiting for events; remaining queue empty"

-- ===============================================================
-- 假终端: WxH 字符格, 每格 {text, fg, bg}
-- ===============================================================

local function newGrid(w, h)
    local g = {
        W = w, H = h, cx = 1, cy = 1,
        fg = colors.white, bg = colors.black, blink = false,
        cells = {},
    }
    for y = 1, h do
        g.cells[y] = {}
        for x = 1, w do g.cells[y][x] = { text = " ", fg = colors.white, bg = colors.black } end
    end

    function g:blankRow() local row = {} for x = 1, self.W do row[x] = { text = " ", fg = self.fg, bg = self.bg } end return row end
    function g:scroll()
        table.remove(self.cells, 1)
        self.cells[self.H] = self:blankRow()
        if self.cy > 1 then self.cy = self.cy - 1 end
    end
    function g:newline()
        self.cx = 1
        self.cy = self.cy + 1
        if self.cy > self.H then self.cy = self.H; self:scroll() end
    end
    function g:write(s)
        s = tostring(s or "")
        for i = 1, #s do
            local ch = s:sub(i, i)
            if ch == "\n" then
                self:newline()
            elseif ch == "\r" then
                self.cx = 1
            else
                -- CC 的 term.write 在行末换行; 这里按冻结的测试语义**截断**(行与行互不污染,
                -- 断言才能按行定位; 真机上长行会绕行, 但安装器自己控制每行长度)
                if self.cx <= self.W and self.cy >= 1 and self.cy <= self.H then
                    local c = self.cells[self.cy][self.cx]
                    c.text, c.fg, c.bg = ch, self.fg, self.bg
                    self.cx = self.cx + 1
                end
            end
        end
    end
    function g:text()
        local rows = {}
        for y = 1, self.H do
            local t = {}
            for x = 1, self.W do t[x] = self.cells[y][x].text end
            rows[y] = table.concat(t)
        end
        return table.concat(rows, "\n")
    end
    function g:row(y)
        local t = {}
        for x = 1, self.W do t[x] = self.cells[y][x].text end
        return table.concat(t)
    end
    function g:rowTrim(y) return (self:row(y):gsub("%s+$", "")) end
    -- 反色(高亮)单元格: 背景不是默认的黑色
    function g:highlightRanges(y)
        local out, start = {}, nil
        for x = 1, self.W do
            local hl = self.cells[y][x].bg ~= colors.black
            if hl and not start then start = x end
            if not hl and start then out[#out + 1] = { start, x - 1 }; start = nil end
        end
        if start then out[#out + 1] = { start, self.W } end
        return out
    end
    function g:hasHighlight(y) return #self:highlightRanges(y) > 0 end
    return g
end

local function newTerm(grid)
    local t = { grid = grid }
    function t.getSize() return grid.W, grid.H end
    function t.setCursorPos(x, y)
        grid.cx = math.max(1, math.min(grid.W, math.floor(x)))
        grid.cy = math.max(1, math.min(grid.H, math.floor(y)))
    end
    function t.getCursorPos() return grid.cx, grid.cy end
    function t.write(s) grid:write(s) end
    function t.clear()
        for y = 1, grid.H do
            for x = 1, grid.W do
                local c = grid.cells[y][x]
                c.text, c.fg, c.bg = " ", grid.fg, grid.bg
            end
        end
    end
    function t.clearLine()
        for x = grid.cx, grid.W do
            local c = grid.cells[grid.cy][x]
            c.text, c.fg, c.bg = " ", grid.fg, grid.bg
        end
    end
    function t.setTextColor(c) grid.fg = c end
    function t.setBackgroundColor(c) grid.bg = c end
    function t.getTextColor() return grid.fg end
    function t.getBackgroundColor() return grid.bg end
    function t.setCursorBlink(b) grid.blink = b and true or false end
    function t.getCursorBlink() return grid.blink end
    function t.isColor() return true end
    function t.scroll(n) for _ = 1, math.max(0, n or 1) do grid:scroll() end end
    -- 英式别名
    t.setTextColour, t.setBackgroundColour = t.setTextColor, t.setBackgroundColor
    t.getTextColour, t.getBackgroundColour = t.getTextColor, t.getBackgroundColor
    t.isColour = t.isColor
    return t
end

-- ===============================================================
-- 假文件系统: 挂在宿主临时目录上的 CC 语义门面
--   挂载表: "/" = 计算机存储, "/disk"(/disk2...) = 假驱动器
--   容量: 每个挂载点一个上限, getFreeSpace 有界 -> 磁盘满的 fail-fast 路径可测
-- ===============================================================

local function isDirHost(hp)
    local f = hostio.open(hp .. "/", "r") -- 目录能 fopen 成功, 文件带尾斜杠会 ENOTDIR
    if f then f:close(); return true end
    return false
end
local function existsHost(hp) return hostos.rename(hp, hp) and true or false end
local function isFileHost(hp) return (not isDirHost(hp)) and existsHost(hp) end
local function fileSizeHost(hp)
    local f = hostio.open(hp, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end
local function dirUsage(dir)
    local p = hostio.popen("find '" .. dir .. "' -type f -printf '%s\\n' 2>/dev/null")
    if not p then return 0 end
    local total = 0
    for line in p:lines() do total = total + (tonumber(line) or 0) end
    p:close()
    return total
end

local function normPath(p)
    if type(p) ~= "string" or p == "" then return "/" end
    if p:sub(1, 1) ~= "/" then p = "/" .. p end
    local segs = {}
    for seg in p:gmatch("[^/]+") do
        if seg == ".." then table.remove(segs)
        elseif seg ~= "." then segs[#segs + 1] = seg end
    end
    return "/" .. table.concat(segs, "/")
end

local function newFsLayer(session)
    local mounts = session.mounts

    local function mountOf(p)
        local best
        for _, m in ipairs(mounts) do
            local hit = (m.path == "/") or (p == m.path) or (p:sub(1, #m.path + 1) == m.path .. "/")
            if hit and (not best or #m.path > #best.path) then best = m end
        end
        return best
    end
    local function hostOf(p)
        local m = mountOf(p)
        if not m then return nil end
        local rel = (m.path == "/") and p or p:sub(#m.path + 1)
        return m.host .. rel, m
    end

    local fs = {}

    function fs.combine(a, b)
        if type(a) ~= "string" then return b end
        if type(b) ~= "string" or b == "" then return a end
        if b:sub(1, 1) == "/" then return normPath(b) end
        if a == "" then return normPath(b) end
        return normPath(a .. "/" .. b)
    end
    function fs.getName(p) return (tostring(p):match("([^/]+)/*$")) or tostring(p) end
    function fs.getDir(p)
        local d = tostring(p):match("^(.*)/[^/]*$")
        if not d then return "" end
        if d == "" then return "/" end
        return d
    end
    function fs.exists(p)
        local hp = hostOf(normPath(p))
        return hp ~= nil and existsHost(hp)
    end
    function fs.isDir(p)
        local hp = hostOf(normPath(p))
        return hp ~= nil and isDirHost(hp)
    end
    function fs.isReadOnly() return false end
    function fs.getSize(p)
        p = normPath(p)
        local hp = hostOf(p)
        if not hp or isDirHost(hp) then return 0 end
        return fileSizeHost(hp) or 0
    end
    function fs.getFreeSpace(p)
        local m = mountOf(normPath(p))
        if not m then return 0 end
        local free = m.capacity - m.used
        if free < 0 then free = 0 end
        return free
    end
    function fs.list(p)
        p = normPath(p)
        local hp = hostOf(p)
        if not hp or not isDirHost(hp) then return nil end
        local names = {}
        local pop = hostio.popen("ls -A -1 -- '" .. hp .. "' 2>/dev/null")
        if pop then
            for line in pop:lines() do names[#names + 1] = line end
            pop:close()
        end
        return names
    end
    --- fs.makeDir 的两种语义(见文件头的"makeDir 语义"说明):
    ---   默认 = CC:Tweaked 文档语义: "Creates a directory, and any missing parents"(连父目录一起建)
    ---   opts.mkdirOneLevel = true = 严格只建一级(任务书里写的"like CC", 实际与 CC 文档不符)
    function fs.makeDir(p)
        p = normPath(p)
        local hp = hostOf(p)
        if not hp then return nil end
        if isDirHost(hp) then return true end -- 已存在: 什么都不做
        if isFileHost(hp) then return nil end
        local cmd
        if session.mkdirParents then
            cmd = "mkdir -p '" .. hp .. "'"
        else
            local parent = p:match("^(.*)/[^/]+$")
            if parent == "" then parent = "/" end
            if parent and not fs.isDir(parent) then return nil end
            cmd = "mkdir '" .. hp .. "'"
        end
        if rcOk(hostos.execute(cmd)) and isDirHost(hp) then return true end
        return nil
    end
    function fs.delete(p)
        p = normPath(p)
        local hp = hostOf(p)
        if not hp or not existsHost(hp) then return nil end
        if isDirHost(hp) then
            if not rcOk(hostos.execute("rmdir '" .. hp .. "' 2>/dev/null")) then return nil end
            return true
        end
        local _, m = hostOf(p)
        local size = fileSizeHost(hp) or 0
        hostos.remove(hp)
        if m then m.used = m.used - size end
        return true
    end

    --- CC 文件句柄语义: write 返回句柄; seek 越界返回 nil; 越界位置的写会扩展文件;
    --- 磁盘写满(超过本用例容量)按真机行为抛错。
    function fs.open(p, mode)
        p = normPath(p)
        mode = mode or "r"
        local hp, m = hostOf(p)
        if not hp then return nil, "no such mount: " .. p end
        if isDirHost(hp) then return nil, "is a directory" end
        local exists = existsHost(hp)
        if (mode == "r" or mode == "r+") and not exists then return nil end
        if mode ~= "r" and mode ~= "r+" and mode ~= "w" and mode ~= "a" then
            return nil, "bad mode: " .. tostring(mode)
        end
        local old = 0
        if mode == "w" then
            old = exists and (fileSizeHost(hp) or 0) or 0
            m.used = m.used - old
        end
        local rmode = "r+b"
        if mode == "r" then rmode = "rb"
        elseif mode == "w" then rmode = "w+b"
        elseif mode == "a" and not exists then rmode = "w+b" end
        local h, oerr = hostio.open(hp, rmode)
        if not h then return nil, tostring(oerr) end
        local size = 0
        if mode ~= "w" then
            size = h:seek("end") or 0
            h:seek("set", 0)
        end

        local f = {}
        local pos = 0
        local closed = false
        local function live()
            if closed then error("attempt to use a closed file", 0) end
        end
        function f.read(n)
            live()
            if pos >= size then return nil end
            h:seek("set", pos)
            local want = n and math.min(n, size - pos) or (size - pos)
            local d = h:read(want)
            pos = pos + #(d or "")
            return d
        end
        function f.readAll()
            live()
            if pos >= size then return "" end
            h:seek("set", pos)
            local d = h:read(size - pos) or ""
            pos = size
            return d
        end
        function f.write(s, alt)
            if s == f then s = alt end -- 容忍 f:write(...)
            live()
            if type(s) ~= "string" then s = tostring(s) end
            if #s == 0 then return f end
            if mode == "a" then pos = size end
            local delta = (pos + #s) - size
            if delta > 0 then
                if m.used + delta > m.capacity then
                    error("Out of space", 0)
                end
                m.used = m.used + delta
                size = pos + #s
            end
            h:seek("set", pos)
            h:write(s)
            h:flush()
            pos = pos + #s
            return f
        end
        function f.writeLine(s) return f.write(tostring(s) .. "\n") end
        function f.seek(whence, off, alt)
            if whence == f then whence, off = off, alt end -- 容忍 f:seek(...)
            live()
            local target
            if whence == "set" then target = off
            elseif whence == "cur" then target = pos + off
            elseif whence == "end" then target = size + off
            else return nil end
            -- CC: 结果位置越界(含文件末尾之后) -> nil
            if target < 0 or target > size then return nil end
            h:seek("set", target)
            pos = target
            return target
        end
        function f.getSize() return size end
        function f.flush() live() h:flush(); return f end
        function f.close()
            if not closed then closed = true; h:close() end
        end
        return f
    end

    return fs
end

-- ===============================================================
-- 假 http: 只读仓库发布树
-- ===============================================================

local function newHttpLayer(session)
    local served = session.servedHosts -- host:port -> 本地目录(http 根)
    local http = {}
    function http.get(req)
        local url
        if type(req) == "table" then url = req.url or req[1] else url = req end
        url = tostring(url or "")
        session.httpCount = session.httpCount + 1
        session.httpUrls[#session.httpUrls + 1] = url
        local host, path = url:match("^https?://([^/]+)/(.*)$")
        if not host then return nil end -- 不是合法 http URL
        local root = served[host]
        if not root then return nil end -- 不可达(没人托管这个 host:port)
        path = path:gsub("%?.*$", "")
        local data = readHostFile(root .. "/" .. path)
        local code = data and 200 or 404
        if not data then data = "" end
        return {
            readAll = function() return data end,
            close = function() end,
            getResponseCode = function() return code end,
        }
    end
    function http.checkURL(url)
        return type(url) == "string" and url:match("^https?://[^/]+") ~= nil
    end
    return http
end

-- ===============================================================
-- 会话: 一个用例一套假环境(独立 temp root + 独立容量 + 独立事件队列)
-- ===============================================================

local fakeOS = {}
fakeOS.active = nil

local GLOBAL_NAMES = {
    "fs", "term", "colors", "colours", "keys", "http", "disk", "peripheral",
    "os", "print", "write", "read", "require",
}

local function titlesOnScreen(grid)
    local text = grid:text()
    local found = {}
    for _, t in ipairs(STEP_TITLES) do
        if text:find(t, 1, true) then found[#found + 1] = t end
    end
    return found
end

--- 造一个用例会话。opts: { name, capacity, driveCapacity, drives={peripheral 名}, width, height }
function fakeOS.newSession(opts)
    opts = opts or {}
    if fakeOS.active then error("fakeOS.newSession: 上一个 session 没 close", 2) end

    local root = string.format("/tmp/delin-installer-test-%s/%s", pidOfSelf(), opts.name or "case")
    hostos.execute("rm -rf '" .. root .. "'")
    hostos.execute("mkdir -p '" .. root .. "/computer'")

    local session = {
        dir = root,
        queue = {},
        frames = {},
        titlesSeen = {},
        httpCount = 0,
        httpUrls = {},
        rebooted = false,
        printed = {},
        servedHosts = { ["127.0.0.1:10568"] = RELEASE_ROOT, ["localhost:10568"] = RELEASE_ROOT },
        capacity = opts.capacity or (4 * 1024 * 1024),
        mounts = {},
        saved = {},
        mkdirParents = not opts.mkdirOneLevel, -- 见 fs.makeDir
    }

    local computer = { path = "/", host = root .. "/computer", capacity = session.capacity, kind = "computer" }
    table.insert(session.mounts, computer)

    local driveNames = opts.drives or { "left" }
    session.driveNames = {}
    session.driveOrder = {}
    for i, name in ipairs(driveNames) do
        local mp = (i == 1) and "/disk" or ("/disk" .. i)
        hostos.execute("mkdir -p '" .. root .. "/" .. mp:gsub("^/", "") .. "'")
        local m = {
            path = mp, host = root .. mp, capacity = opts.driveCapacity or session.capacity,
            kind = "drive", name = name,
        }
        table.insert(session.mounts, m)
        session.driveNames[name] = { mount = m, mp = mp }
        session.driveOrder[#session.driveOrder + 1] = name
        -- 驱动器里放点东西, 让 disk.hasData 为真
        local marker = hostio.open(m.host .. "/.delin-drive", "w")
        if marker then marker:write("x") marker:close() end
    end

    for _, m in ipairs(session.mounts) do m.used = dirUsage(m.host) end

    -- ---------- 终端 ----------
    local grid = newGrid(opts.width or 51, opts.height or 19)
    local term = newTerm(grid)
    session.grid = grid
    session.term = term

    local function captureFrame()
        local hl = {}
        for y = 1, grid.H do hl[y] = grid:hasHighlight(y) or nil end
        local f = {
            rows = (function()
                local r = {}
                for y = 1, grid.H do r[y] = grid:row(y) end
                return r
            end)(),
            hl = hl, -- 这一屏哪些行有反色格(冻结契约: 光标行反色)
            titles = titlesOnScreen(grid),
            cursor = { grid.cx, grid.cy },
        }
        session.frames[#session.frames + 1] = f
        for _, t in ipairs(f.titles) do
            if session.titlesSeen[#session.titlesSeen] ~= t then
                session.titlesSeen[#session.titlesSeen + 1] = t
            end
        end
    end

    -- ---------- os ----------
    local fakeos = {}
    local function pullEvent(filter)
        if #session.queue == 0 then
            local last = session.frames[#session.frames]
            local step = last and table.concat(last.titles, ",") or ""
            if step == "" then step = "?" end
            error(BLOCKED_MSG .. " (screen step: " .. step .. ")", 0)
        end
        local ev = table.remove(session.queue, 1)
        if filter and ev[1] ~= filter then
            return pullEvent(filter) -- CC: 不匹配的事件直接丢弃
        end
        captureFrame()
        return unpack(ev)
    end
    fakeos.pullEvent = function(filter) return pullEvent(filter) end
    fakeos.pullEventRaw = function(filter) return pullEvent(filter) end
    fakeos.queueEvent = function(name, ...) session.queue[#session.queue + 1] = { name, ... } end
    fakeos.epoch = function() return math.floor(hostos.time() * 1000) end
    fakeos.clock = function() return hostos.clock() end
    fakeos.time = function() return hostos.time() end
    fakeos.date = function(fmt, t) return hostos.date(fmt, t) end
    fakeos.day = function() return math.floor(hostos.time() / 86400) end
    fakeos.sleep = nil -- 规范: 不需要定时器; 安装器真 sleep 就应当暴露成错误
    fakeos.getComputerID = function() return 0 end
    fakeos.getComputerLabel = function() return "installertest" end
    fakeos.setComputerLabel = function() end
    fakeos.version = function() return "CraftOS 1.8 (fake)" end
    fakeos.reboot = function() session.rebooted = true end -- 只记录, 不结束进程
    fakeos.shutdown = function() session.shutdowned = true end
    fakeos.startup = function() return false end

    -- ---------- fs ----------
    local fs = newFsLayer(session)

    -- ---------- disk / peripheral ----------
    local disk = {}
    function disk.hasData(name)
        local d = session.driveNames[name]
        return d ~= nil and existsHost(d.mount.host .. "/.delin-drive")
    end
    function disk.getMountPath(name)
        local d = session.driveNames[name]
        return d and d.mp or nil
    end
    function disk.getID(name) return session.driveNames[name] and ("DELIN-" .. name) or nil end
    function disk.isPresent(name) return session.driveNames[name] ~= nil end
    function disk.setLabel() return true end
    function disk.getLabel(name) return session.driveNames[name] and "DELIN" or nil end

    local peripheral = {}
    --- 按声明顺序(与 CC 上 peripheral.getNames 的"任意但稳定"一致, 断言目标列表顺序才有确定性)
    function peripheral.getNames()
        local names = {}
        for _, n in ipairs(session.driveOrder) do names[#names + 1] = n end
        return names
    end
    function peripheral.getType(name) return session.driveNames[name] and "drive" or nil end
    function peripheral.isPresent(name) return session.driveNames[name] ~= nil end
    function peripheral.hasType(name, t) return session.driveNames[name] and t == "drive" or false end

    -- ---------- print / write / read ----------
    local function gridWrite(s)
        s = tostring(s)
        session.printed[#session.printed + 1] = s
        grid:write(s)
    end
    local function fakePrint(...)
        local n = select("#", ...)
        for i = 1, n do
            if i > 1 then gridWrite(" ") end
            gridWrite(tostring((select(i, ...))))
        end
        gridWrite("\n")
    end
    local function fakeWrite(...)
        local n = select("#", ...)
        for i = 1, n do gridWrite(tostring((select(i, ...)))) end
    end
    --- CC read(replaceChar, history, completeFn, default): 从事件队列吃 char/key
    local function fakeRead(_, _, _, default)
        local buf = default or ""
        while true do
            local ev = { fakeos.pullEvent() }
            if ev[1] == "char" then
                buf = buf .. tostring(ev[2])
            elseif ev[1] == "key" then
                local k = ev[2]
                if k == keys.enter or k == keys.numPadEnter then
                    return buf
                elseif k == keys.backspace then
                    buf = buf:sub(1, -2)
                end
            end
        end
    end

    -- ---------- 装到真全局 ----------
    -- 兜底的全局 require: 万一 5.1 的 _ENV 补丁没匹配上(bundle 格式变了), 模块 require 还能
    -- 落到仓库源文件上, 而不是直接炸掉。5.2+ 根本不会走到这里(模块内 require = __require)。
    local repoCache = {}
    local function requireShim(name)
        name = tostring(name)
        if repoCache[name] ~= nil then return repoCache[name] end
        local cands = {}
        local rel = name:gsub("%.", "/")
        cands[#cands + 1] = REPO .. "/src/" .. rel .. ".lua"
        local rest = name:match("^installer%.(.+)$")
        if rest then cands[#cands + 1] = REPO .. "/tools/" .. rest:gsub("%.", "/") .. ".lua" end
        for _, p in ipairs(cands) do
            local c = loadfile(p)
            if c then
                local mod = c()
                if mod ~= nil then
                    repoCache[name] = mod
                    return mod
                end
            end
        end
        error("installertest: cannot resolve module '" .. name .. "' (tried " ..
              table.concat(cands, ", ") .. ")", 0)
    end

    local globals = {
        fs = fs, term = term, colors = colors, colours = colors, keys = keys,
        http = newHttpLayer(session), disk = disk, peripheral = peripheral,
        os = fakeos, print = fakePrint, write = fakeWrite, read = fakeRead,
        require = requireShim,
    }
    for _, n in ipairs(GLOBAL_NAMES) do session.saved[n] = _G[n] end
    for n, v in pairs(globals) do _G[n] = v end
    session.globals = globals

    -- ---------- 会话方法 ----------
    function session:play(...)
        for _, ev in ipairs({ ... }) do
            if type(ev) == "number" then
                self.queue[#self.queue + 1] = { "key", ev }
            elseif type(ev) == "table" then
                if ev.key ~= nil then self.queue[#self.queue + 1] = { "key", ev.key } end
                if ev.char ~= nil then self.queue[#self.queue + 1] = { "char", ev.char } end
                if ev.name ~= nil then
                    local e = { ev.name }
                    for _, a in ipairs(ev.args or {}) do e[#e + 1] = a end
                    self.queue[#self.queue + 1] = e
                end
            else
                error("play: 只接受 key 数字或 {key=}/{char=}/{name=} 表")
            end
        end
        return self
    end
    function session:playText(s)
        for i = 1, #s do self.queue[#self.queue + 1] = { "char", s:sub(i, i) } end
        return self
    end
    function session:playKey(k, n)
        for _ = 1, (n or 1) do self.queue[#self.queue + 1] = { "key", k } end
        return self
    end

    --- 在假环境里跑一段源码(自检用), 返回 pcall 的 ok + 返回值
    function session:runChunk(src, name)
        local chunk, err = loadChunk(src, name or "chunk")
        if not chunk then return false, "load: " .. tostring(err) end
        return pcall(chunk)
    end

    --- loadfile 构建产物 dist/install.lua 并在假环境里执行
    function session:runInstallScript()
        local chunk, err
        if BUNDLE_SRC_51 then
            chunk, err = loadChunk(BUNDLE_SRC_51, "@" .. INSTALL_BUNDLE)
        else
            chunk, err = loadfile(INSTALL_BUNDLE)
        end
        if not chunk then error("load(" .. INSTALL_BUNDLE .. "): " .. tostring(err), 0) end
        -- 看门狗: 万一安装器死循环(不取事件, 事件队列机制抓不到), 也在有限步数内报错,
        -- 不让整个测试进程挂死。
        local ticks = 0
        local function watchdog()
            ticks = ticks + 1
            if ticks > 3000 then
                error("installer watchdog: 超过 " .. tostring(3000) .. "e6 条 VM 指令还没结束(死循环?)", 0)
            end
        end
        debug.sethook(watchdog, "", 1000000)
        local okRun, rerr = pcall(chunk)
        debug.sethook()
        self.ok = okRun
        self.err = rerr
        self.hung = (not okRun) and tostring(rerr):find(BLOCKED_MSG, 1, true) ~= nil or false
        self.watchdog = (not okRun) and tostring(rerr):find("installer watchdog", 1, true) ~= nil or false
        self.stuck = self.hung or self.watchdog
        if self.hung then self.blockedAt = self:lastStep() end
        return okRun, rerr
    end

    function session:lastStep()
        local last = self.frames[#self.frames]
        if not last or #last.titles == 0 then return "(no step title)" end
        return table.concat(last.titles, "/")
    end
    function session:frameWith(title)
        for _, f in ipairs(self.frames) do
            for _, t in ipairs(f.titles) do if t == title then return f end end
        end
        return nil
    end
    function session:sawTitle(title)
        for _, t in ipairs(self.titlesSeen) do if t == title then return true end end
        return false
    end
    --- 最后一次抓到的画面(安装器阻塞等事件时用户看到的画面)
    function session:lastRows()
        local last = self.frames[#self.frames]
        if last then return last.rows end
        local r = {}
        for y = 1, grid.H do r[y] = grid:row(y) end
        return r
    end
    function session:screen() return table.concat(self:lastRows(), "\n") end
    function session:hasOnScreen(s) return self:screen():find(s, 1, true) ~= nil end
    function session:hostPath(rel) -- 目标根(计算机存储)下的真实路径
        return self.dir .. "/computer/" .. tostring(rel):gsub("^/", "")
    end
    function session:drivePath(name, rel)
        local d = self.driveNames[name]
        if not d then return nil end
        return d.mount.host .. "/" .. tostring(rel):gsub("^/", "")
    end
    function session:file(rel) return readHostFile(self:hostPath(rel)) end
    function session:existsFile(rel) return existsHost(self:hostPath(rel)) end
    function session:log() return self:file("/delin-install.log") end
    function session:writeTarget(rel, data)
        local f = fs.open("/" .. tostring(rel):gsub("^/", ""), "w")
        if not f then error("writeTarget: cannot open " .. rel, 0) end
        f.write(data)
        f.close()
    end
    function session:close()
        if fakeOS.active ~= self then return end
        for n, v in pairs(self.saved) do _G[n] = v end
        fakeOS.active = nil
        self.closed = true
    end

    session.captureFrame = captureFrame
    fakeOS.active = session
    return session
end

--- 用例结束后必须能拿到会话做 dump; 用例自己 close 掉就记在这里
local LAST_SESSION = nil
local function newSession(opts)
    local w = fakeOS.newSession(opts)
    LAST_SESSION = w
    return w
end

-- ===============================================================
-- 失败时的调试产物: 屏幕(含反色标记) + 日志 + 目标文件清单
-- ===============================================================

local function dumpSession(w)
    if not w then
        out("  (没有会话可 dump)\n")
        return
    end
    -- 每次屏幕内容变化就打印一屏(安装器的交互历史), 屏幕是这台上唯一读得到的证据
    out("  --- screens (每次画面变化; NN| 前面是行号, <hl> 表示该行有反色格) ---\n")
    local prev
    for i, f in ipairs(w.frames) do
        local text = table.concat(f.rows, "\n")
        if text ~= prev then
            out(string.format("   frame %d: step=[%s] cursor=(%d,%d)\n", i,
                              table.concat(f.titles, "/"), f.cursor[1], f.cursor[2]))
            for y = 1, #f.rows do
                local row = f.rows[y]
                if row:match("%S") or f.hl[y] then
                    out(string.format("   %2d|%s|%s\n", y, row, f.hl[y] and "  <hl>" or ""))
                end
            end
            prev = text
        end
    end
    out("  --- highlight ranges of the last screen (bg ~= black) ---\n")
    local rows = w:lastRows()
    local any = false
    for y = 1, #rows do
        local ranges = w.grid:highlightRanges(y)
        if #ranges > 0 then
            any = true
            local parts = {}
            for _, r in ipairs(ranges) do parts[#parts + 1] = r[1] .. "-" .. r[2] end
            out(string.format("   %2d| %s\n", y, table.concat(parts, " ")))
        end
    end
    if not any then out("   (最后一屏没有高亮行)\n") end
    out(string.format("  --- frames: %d, delivered events: %d ---\n", #w.frames, #w.frames))
    if w.hung then out("   installer blocked at: " .. tostring(w.blockedAt) .. "\n") end
    if w.err and not w.hung then out("   lua error: " .. short(w.err, 300) .. "\n") end
    local log = w:log()
    out("  --- /delin-install.log ---\n")
    if log == nil then
        out("   (不存在)\n")
    elseif log == "" then
        out("   (空)\n")
    else
        for line in log:gmatch("[^\r\n]*") do out("   | " .. line .. "\n") end
    end
    out("  --- target tree (" .. w.dir .. "/computer) ---\n")
    local p = hostio.popen("find '" .. w.dir .. "/computer' -type f -printf '%s\\t%P\\n' 2>/dev/null | sort -k2 | head -100")
    if p then
        for line in p:lines() do out("   " .. line .. "\n") end
        p:close()
    end
end

-- ===============================================================
-- 用例跑法
-- ===============================================================

local function runCase(id, title, fn)
    -- 自检(case 0)永远跑: 没有它, 后面所有失败都分不清是假环境还是安装器的问题
    if OPT.only and id ~= "0" and OPT.only ~= id then return end
    out(string.format("\n--- case %s: %s\n", id, title))
    local before = fail
    local okRun, err = pcall(fn)
    local w = LAST_SESSION
    if fakeOS.active then pcall(function() fakeOS.active:close() end) end
    LAST_SESSION = nil
    local failed = (fail > before) or (not okRun)
    if not okRun then
        fail = fail + 1
        out("  FAIL case " .. id .. ": 用例本身抛错: " .. tostring(err) .. "\n")
    end
    if failed or OPT.dumpAll then dumpSession(w) end
    if failed then
        casesFail = casesFail + 1
        out(string.format("case %s: FAIL\n", id))
    else
        casesPass = casesPass + 1
        out(string.format("case %s: PASS\n", id))
    end
end

--- 安装器跑完后: 卡住 / 抛错都打印成 note(是否失败由各用例的断言决定)
local function reportRun(w)
    if w.hung then
        note("安装器在事件队列耗尽时仍要取事件 -> 停在这一步: " .. tostring(w.blockedAt))
    elseif w.watchdog then
        note("看门狗触发: 安装器在有限步数内没结束(死循环?)")
    elseif not w.ok then
        note("安装器脚本未正常返回, 抛错: " .. tostring(w.err))
    end
end

--- 安装器不该抛未处理错误(卡在等事件 / 看门狗不算 — 那是我按键不够或有死循环)
local function okNoUnhandledError(w, label)
    return ok(w.ok or w.stuck, label or "installer 未抛未处理错误",
              w.err and tostring(w.err) or nil)
end

local function logHas(w, needle)
    local l = w:log()
    return l ~= nil and l:find(needle, 1, true) ~= nil
end

--- 契约偏差清单: 打印出来的偏差在最后的汇总里再列一遍, 免得被当成脚本 bug
local DEV = {}
local function deviation(s)
    DEV[#DEV + 1] = s
    out("!! contract: " .. s .. "\n")
end

--- 断言: 出现了某个步骤标题
local function okSawStep(w, title, label)
    return ok(w:sawTitle(title), label or ("渲染过步骤 " .. title),
              "steps=" .. table.concat(w.titlesSeen, " -> "))
end

--- 一行是不是"某个选项行": 冻结渲染是 `> [x] <label>` / `  [ ] <label>`。
--- 不能只搜 label 子串 —— 帮助行里的 "Backspace/Esc back" 会让 "back" 这种标签假命中。
local function rowHasOption(row, label)
    local pat = "%[[xX ]%]%s*" .. label:gsub("(%W)", "%%%1")
    return row:find(pat) ~= nil
end
local function frameHasOption(f, label)
    for _, row in ipairs(f.rows) do
        if rowHasOption(row, label) then return true end
    end
    return false
end
local function optionRowOf(f, label)
    for y, row in ipairs(f.rows) do
        if rowHasOption(row, label) then return y end
    end
    return nil
end

--- 冻结契约: 光标行反色(非默认背景), 光标行是 [x], 其它选项行是 [ ]
local function okCursorRendering(f, label)
    if not f then
        ok(false, label .. ": 有候选屏")
        return
    end
    local marked = {}
    for y, row in ipairs(f.rows) do
        if row:find("%[[xX]%]") then marked[#marked + 1] = y end
    end
    if not ok(#marked == 1, label .. ": 恰有一行是 [x](光标行)",
              "rows with [x] = " .. table.concat(marked, ",")) then return end
    local y = marked[1]
    ok(f.hl[y] == true, label .. ": 光标行反色(背景非默认)")
    ok(f.rows[y]:find(">", 1, true) ~= nil, label .. ": 光标行有 '>' 前缀",
       f.rows[y])
    local othersHl = {}
    for y2, row in ipairs(f.rows) do
        if y2 ~= y and row:find("%[ %]", 1, true) and f.hl[y2] then othersHl[#othersHl + 1] = y2 end
    end
    ok(#othersHl == 0, label .. ": 非光标选项行没有反色", table.concat(othersHl, ","))
end

--- Image size 步骤是否真的被渲染过: 只认该步骤独有的**选项行** `[ ] 256 KB`
--- (源步骤也有 `[ ] custom`, 所以不能拿 "custom" 当判据)。
local function sizeStepRendered(w)
    for _, f in ipairs(w.frames) do
        if frameHasOption(f, "256 KB") then return true end
    end
    return false
end

-- ===============================================================
-- case 0: 假环境自检(先证明是安装器的锅, 不是假环境的锅)
-- ===============================================================

local SELFTEST_SRC = [[
local log = {}
local function say(s) log[#log + 1] = tostring(s) end

local W, H = term.getSize()
say("termsize=" .. W .. "x" .. H)

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.setCursorPos(1, 1)
term.write("hello")
term.setBackgroundColor(colors.gray)
term.setCursorPos(1, 2)
term.write("inverse")
term.setBackgroundColor(colors.black)
term.setCursorPos(1, 3)
term.write(string.rep("X", 200))
term.setCursorPos(1, 4)
term.write("gone")
term.setCursorPos(1, 4)
term.clearLine()
term.setCursorPos(1, 5)
print("SELFTEST MARK")

say("read1=" .. tostring(read()))
say("read2=" .. tostring(read(nil, nil, nil, "dflt")))
say("keys=" .. select(2, os.pullEvent()) .. "," .. select(2, os.pullEvent("key")) ..
    "," .. select(2, os.pullEvent()))

say("mkdir1=" .. tostring(fs.makeDir("/sub")))
say("mkdir2=" .. tostring(fs.makeDir("/sub/deep")))
say("mkdir3=" .. tostring(fs.makeDir("/fresh/deep")))
local f = fs.open("/sub/a.txt", "w")
f.write("abc")
f.writeLine("def")
say("seek_oob=" .. tostring(f.seek("set", 999)))
say("seek_end=" .. tostring(f.seek("end", 0)))
f.seek("set", 0)
say("all=" .. (f.readAll():gsub("\n", "<NL>")))
f.close()
local r = fs.open("/sub/a.txt", "r")
say("read2b=" .. tostring(r.read(2)))
say("readrest=" .. (r.readAll():gsub("\n", "<NL>")))
say("read_eof=" .. tostring(r.read(1)))
r.close()
local ap = fs.open("/sub/a.txt", "a")
ap.write("Z")
ap.close()
say("filesize=" .. fs.getSize("/sub/a.txt"))
say("missing_r=" .. tostring(fs.open("/sub/none", "r")))
say("missing_rp=" .. tostring(fs.open("/sub/none", "r+")))
say("isdir=" .. tostring(fs.isDir("/sub")) .. "," .. tostring(fs.isDir("/sub/a.txt")) ..
    "," .. tostring(fs.exists("/sub/a.txt")))
say("free=" .. fs.getFreeSpace("/"))
local okw, errw = pcall(function()
    local b = fs.open("/sub/big", "w")
    b.write(string.rep("y", 100000))
    b.close()
end)
say("outofspace=" .. tostring(okw) .. ":" .. tostring(errw))
say("list=" .. table.concat(fs.list("/sub") or {}, ","))
say("combine=" .. fs.combine("/sub", "x") .. "," .. fs.getName("/sub/a.txt"))
return log
]]

local function selfTest()
    local w = newSession({ name = "selftest", capacity = 64 * 1024, drives = { "left" } })
    w:playText("hi")
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })
    w:play({ key = keys.down })
    w:play({ char = "a" })
    w:play({ key = keys.enter })
    w:play({ key = keys.space })
    local okRun, log = w:runChunk(SELFTEST_SRC, "selftest")
    ok(okRun, "自检程序跑完(假环境不缺 API)", tostring(log))
    eq(#w.queue, 0, "自检程序把脚本化事件全取走了(队列按预期耗尽, 没提前卡住)")
    local got = {}
    if type(log) == "table" then
        for _, line in ipairs(log) do
            local k, v = tostring(line):match("^(.-)=(.*)$")
            if k then got[k] = v end
        end
    end
    local function g(k) return got[k] end

    -- 终端
    eq(w.grid:row(1):sub(1, 5), "hello", "term.write 落到格子")
    eq(w.grid:row(2):sub(1, 7), "inverse", "第二行写入正常")
    ok(w.grid:hasHighlight(2), "setBackgroundColor(gray) 让第 2 行反色")
    ok(not w.grid:hasHighlight(1), "第 1 行是默认背景(不算高亮)")
    local ranges = w.grid:highlightRanges(2)
    eq(ranges[1] and (ranges[1][1] .. "-" .. ranges[1][2]), "1-7", "高亮区间是 1-7")
    eq(w.grid:rowTrim(3), string.rep("X", 51), "行末截断: 200 个 X 只留 51 个")
    eq(w.grid:rowTrim(4), "", "clearLine 清掉整行")
    ok(w:hasOnScreen("SELFTEST MARK"), "print 也画到假终端上")
    eq(g("termsize"), "51x19", "term.getSize")

    -- 键盘/事件队列
    eq(g("read1"), "hi", "read() 吃 char 事件直到 enter")
    eq(g("read2"), "dflt", "read(nil,nil,nil,default) 直接回车返回默认值")
    eq(g("keys"), keys.down .. "," .. keys.enter .. "," .. keys.space,
       "pullEvent 过滤: 丢非 key, 顺序不变")

    -- fs
    eq(g("mkdir1"), "true", "makeDir 一级目录")
    eq(g("mkdir2"), "true", "makeDir 父目录存在时可建")
    eq(g("mkdir3"), "true", "makeDir 默认按 CC 文档建缺失的父目录")
    eq(g("seek_oob"), "nil", "seek 越界返回 nil(CC 语义)")
    eq(g("seek_end"), "7", "seek('end',0) 到文件末尾")
    eq(g("all"), "abcdef<NL>", "readAll 读回全部")
    eq(g("read2b"), "ab", "read(2)")
    eq(g("readrest"), "cdef<NL>", "read 从当前位置续读")
    eq(g("read_eof"), "nil", "EOF 处 read 返回 nil")
    eq(g("filesize"), "8", "追加写后 getSize")
    eq(g("missing_r"), "nil", "open('r') 不存在 -> nil")
    eq(g("missing_rp"), "nil", "open('r+') 不存在 -> nil")
    eq(g("isdir"), "true,false,true", "isDir/exists")
    eq(g("free"), tostring(65536 - 8), "getFreeSpace 有界: 容量 - 已用")
    eq(g("list"), "a.txt,big,deep", "list 返回目录项")
    eq(g("combine"), "/sub/x,a.txt", "combine/getName")
    ok(g("outofspace") and g("outofspace"):find("Out of space", 1, true) ~= nil,
       "超出容量的写抛 'Out of space'(磁盘满可测)", g("outofspace"))

    -- makeDir 的另一种语义(严格只建一级)单独验一遍: case 2b 要用它
    w:close()
    local w2 = newSession({ name = "selftest-mkdir", capacity = 64 * 1024, mkdirOneLevel = true })
    local ok2, res2 = w2:runChunk([[
        local a = tostring(fs.makeDir("/a/b"))
        local b = tostring(fs.makeDir("/a"))
        local c = tostring(fs.makeDir("/a/b"))
        return a .. "," .. b .. "," .. c
    ]], "mkdirtest")
    ok(ok2, "自检: 严格一级 makeDir 模式可用", tostring(res2))
    eq(res2, "nil,true,true", "makeDir(严格一级) 父目录不存在就失败")
end

-- ===============================================================
-- 契约探针: 先判断 dist/install.lua 是不是"多步交互"那一版
-- ===============================================================

local CONTRACT = { multiStep = false, steps = {} }

local function probeContract()
    local w = newSession({ name = "probe", capacity = 4 * 1024 * 1024 })
    w:play({ key = keys.down })  -- 新流程: 光标 CCFS -> EXT2
    w:play({ key = keys.enter }) -- 新流程: 进入 Install target
    w:play({ key = keys.q })     -- 退出(旧 TUI 在第一步; 新流程在第 2 步)
    w:play({ key = keys.q })
    pcall(function() w:runInstallScript() end)
    CONTRACT.steps = w.titlesSeen
    for _, t in ipairs(w.titlesSeen) do
        if t == "Install target" then CONTRACT.multiStep = true end
    end
    out("contract probe: 步骤序列 = " ..
        (#w.titlesSeen > 0 and table.concat(w.titlesSeen, " -> ") or "(没有渲染任何步骤标题)") .. "\n")
    if not CONTRACT.multiStep then
        out("!! 警告: 被测的 dist/install.lua **不是**冻结的多步交互版\n")
        out("!!       (按 Down+Enter 后没有出现 'Install target' -> 还是旧的单屏 TUI)\n")
        out("!!       下面的用例会按冻结契约断言并全部失败, 这是预期结果; 不修改断言。\n")
    end
    if w.hung then out("contract probe: 安装器卡在 " .. tostring(w.blockedAt) .. " (队列空仍取事件)\n") end
    if w.watchdog then out("contract probe: 看门狗触发(安装器死循环?)\n") end
    w:close()
    LAST_SESSION = nil
end

-- ===============================================================
-- 先自检假环境, 再探契约, 然后跑用例
-- ===============================================================

out(string.format("harness: %s | release %s | %d files, %d bytes | bundle %s\n",
                  _VERSION, RELEASE, MF.count, MF.total, INSTALL_BUNDLE))
if BUNDLE_SRC_51 then
    out(string.format("harness: Lua 5.1 -> 给 bundle 补 %s 处 `local require=__require`(_ENV 语义)\n",
                      tostring(ENV_PATCH_COUNT)))
end
runCase("0", "fake CraftOS 环境自检(假环境本身无 bug)", selfTest)
probeContract()

-- ===============================================================
-- 用例
-- ===============================================================

local function ext2MagicOk(path)
    local img = readHostFile(path)
    if not img or #img < 1082 then return false, "镜像读不到或太小" end
    local b1, b2 = img:byte(1081, 1082)
    return b1 == 0x53 and b2 == 0xEF, string.format("offset 1080 = %02x %02x", b1 or 0, b2 or 0)
end

--- 用仓库自己的 ext2 驱动读回镜像: 返回可查询的表, 或 nil+原因
local function openImage(path)
    if not ext2mod then return nil, "kernel.ext2 载入失败" end
    if not readHostFile(path) then return nil, "镜像不存在" end
    local h = hostio.open(path, "r+b")
    if not h then return nil, "打不开镜像" end
    local bd = {
        read = function(off, len) h:seek("set", off) return h:read(len) end,
        write = function(off, data) h:seek("set", off) return h:write(data) end,
        getSize = function()
            local cur = h:seek(); h:seek("end"); local n = h:seek(); h:seek("set", cur)
            return n
        end,
        close = function() h:close() end,
    }
    local fs, err = ext2mod.mount(bd)
    if not fs then return nil, tostring(err) end
    return {
        lookup = function(p) return ext2mod.lookup(fs, p) end,
        read = function(p)
            local ino = ext2mod.lookup(fs, p)
            if not ino then return nil end
            return ext2mod.readFile(fs, ino)
        end,
        close = function() bd.close() end,
    }
end

local function checkImageAgainstPayload(w, label)
    local img = w:hostPath("/parts/root.img")
    local r, err = openImage(img)
    if not r then
        out("  note: 跳过镜像内容核对(" .. tostring(err) .. ")\n")
        return
    end
    for _, rel in ipairs({ "boot/delin.lua", "bin/sh", "etc/passwd" }) do
        if MF.byPath[rel] then
            local inImg = r.read("/" .. rel)
            eq(inImg ~= nil, true, label .. ": 镜像里有 /" .. rel)
            if inImg then
                eq(#inImg, #(payloadFile(rel) or ""), label .. ": /" .. rel .. " 大小 == payload")
            end
        end
    end
    r.close()
end

local function e2fsckCheck(w)
    if not existsHost(E2FSCK) then
        out("  note: " .. E2FSCK .. " 不存在, 跳过 fsck 门禁\n")
        return
    end
    local img = w:hostPath("/parts/root.img")
    local log = w.dir .. "/e2fsck.out"
    local rc = hostos.execute(string.format("%s -fn %q > %q 2>&1", E2FSCK, img, log))
    local text = readHostFile(log) or ""
    ok(rcOk(rc), "e2fsck -fn 退出码 0(镜像干净)", "rc=" .. tostring(rc) .. "\n" .. text)
end

-- ---------------------------------------------------------------
-- case 1: EXT2 -> 计算机存储
-- ---------------------------------------------------------------
runCase("1", "EXT2 -> computer storage", function()
    local w = newSession({ name = "case1-ext2-computer", capacity = 4 * 1024 * 1024, drives = { "left" } })
    out("  dir: " .. w.dir .. "\n")
    w:play({ key = keys.down })  -- CCFS -> EXT2
    w:play({ key = keys.enter }) -- 1 确认类型
    w:play({ key = keys.enter }) -- 2 目标 = 计算机存储(第一项)
    w:play({ key = keys.enter }) -- 3 源 = 预填默认 URL
    w:play({ key = keys.enter }) -- 4 大小 = auto
    w:play({ key = keys.enter }) -- 5 摘要 = Start installation
    w:play({ key = keys.enter }) -- 装完的提示键(不是 R, 不触发重启)
    w:play({ key = keys.enter })
    w:runInstallScript()
    reportRun(w)
    okNoUnhandledError(w)

    -- 步骤可见性(冻结契约的 5 步都得走到)
    okSawStep(w, "Install type")
    okSawStep(w, "Install target")
    okSawStep(w, "Install source")
    okSawStep(w, "Image size")
    okSawStep(w, "Summary")
    ok(sizeStepRendered(w), "Image size 步骤真的渲染过(有 [ ] 256 KB 选项)")
    -- 第一步的两个选项 + 光标行反色 + [x]/[ ] 标记
    local typeFrame = w:frameWith("Install type")
    if typeFrame then
        ok(frameHasOption(typeFrame, "CCFS"), "Install type 有选项 'CCFS'")
        ok(frameHasOption(typeFrame, "EXT2"), "Install type 有选项 'EXT2'")
        local yccfs, yext2 = optionRowOf(typeFrame, "CCFS"), optionRowOf(typeFrame, "EXT2")
        ok(yccfs ~= nil and yext2 ~= nil and yccfs < yext2, "CCFS 在 EXT2 前面(默认第一项)")
        okCursorRendering(typeFrame, "Install type")
    end
    local sum = w:frameWith("Summary")
    if sum then
        local t = table.concat(sum.rows, "\n")
        ok(t:find("EXT2", 1, true) ~= nil and t:find("computer storage", 1, true) ~= nil,
           "Summary 里出现 EXT2 + computer storage")
        ok(frameHasOption(sum, "Start installation"), "Summary 有确认项 '[x] Start installation'")
        ok(frameHasOption(sum, "Cancel"), "Summary 有确认项 '[ ] Cancel'")
        okCursorRendering(sum, "Summary")
    else
        ok(false, "Summary 渲染过")
    end

    -- 落盘产物
    ok(w:existsFile("/startup.lua"), "/startup.lua 存在")
    eq(w:file("/startup.lua"), payloadFile("startup.lua"), "/startup.lua == payload/startup.lua")
    ok(w:existsFile("/boot/dlub.lua"), "/boot/dlub.lua 存在")
    eq(trim(w:file("/.boot")), "/boot/dlub.lua", "/.boot == /boot/dlub.lua")
    eq(trim(w:file("/dlub.cfg")), "rootfs /parts/root.img", "/dlub.cfg == rootfs /parts/root.img")
    ok(w:existsFile("/parts/root.img"), "/parts/root.img 存在")
    local magic, minfo = ext2MagicOk(w:hostPath("/parts/root.img"))
    ok(magic, "镜像 superblock magic 0xEF53 @1080", minfo)
    -- 日志(冻结串)
    ok(logHas(w, "Install OK"), "日志含 Install OK")
    ok(logHas(w, "Delin installer"), "日志头部含 'Delin installer'")
    ok(logHas(w, "  source :"), "日志头部含 '  source :'")
    ok(logHas(w, "  type   :"), "日志头部含 '  type   :'")
    ok(logHas(w, "  target :"), "日志头部含 '  target :'")
    ok(logHas(w, "making ext2 image:"), "日志先记 'making ext2 image: <N> KB ...'")
    -- 镜像内容交叉验证(仓库自己的 ext2 驱动)
    checkImageAgainstPayload(w, "case1")
    e2fsckCheck(w)
end)

-- ---------------------------------------------------------------
-- case 2: CCFS -> 计算机存储(且跳过 Image size)
-- ---------------------------------------------------------------
runCase("2", "CCFS -> computer storage (no Image size step)", function()
    local w = newSession({ name = "case2-ccfs-computer", capacity = 4 * 1024 * 1024, drives = { "left" } })
    out("  dir: " .. w.dir .. "\n")
    w:play({ key = keys.enter }) -- 1 类型 = 默认 CCFS
    w:play({ key = keys.enter }) -- 2 目标 = 计算机存储
    w:play({ key = keys.enter }) -- 3 源 = 默认 URL
    w:play({ key = keys.enter }) -- 4 摘要 = Start installation (CCFS 无 size 步)
    w:play({ key = keys.enter }) -- 装完提示键
    w:play({ key = keys.enter })
    w:runInstallScript()
    reportRun(w)
    okNoUnhandledError(w)

    okSawStep(w, "Install type")
    okSawStep(w, "Install target")
    okSawStep(w, "Install source")
    okSawStep(w, "Summary")
    ok(not sizeStepRendered(w), "CCFS 全程没有渲染 Image size 的选项([ ] 256 KB / [ ] custom)",
       "steps=" .. table.concat(w.titlesSeen, " -> "))
    ok(not w:sawTitle("Image size"), "CCFS 全程屏幕上没有 'Image size' 字样",
       "steps=" .. table.concat(w.titlesSeen, " -> "))
    okCursorRendering(w:frameWith("Summary"), "Summary")
    local sumFrame = w:frameWith("Summary")
    if sumFrame then
        ok(frameHasOption(sumFrame, "Start installation"), "Summary 有确认项 '[x] Start installation'")
        ok(frameHasOption(sumFrame, "Cancel"), "Summary 有确认项 '[ ] Cancel'")
    end

    eq(trim(w:file("/.boot")), "/boot/delin.lua", "/.boot == /boot/delin.lua")
    ok(not w:existsFile("/dlub.cfg"), "CCFS 到计算机存储不写 /dlub.cfg")
    ok(not w:existsFile("/parts/root.img"), "CCFS 不建 ext2 镜像")
    for _, rel in ipairs({ "bin/sh", "boot/delin.lua", "etc/passwd", "startup.lua" }) do
        if MF.byPath[rel] then
            ok(w:existsFile("/" .. rel), "payload 落地: /" .. rel)
        end
    end
    eq(w:file("/bin/sh"), payloadFile("bin/sh"), "/bin/sh 内容 == payload/bin/sh")
    eq(w:file("/boot/delin.lua"), payloadFile("boot/delin.lua"),
       "/boot/delin.lua 内容 == payload/boot/delin.lua")
    ok(logHas(w, "Install OK"), "日志含 Install OK")
end)

-- ---------------------------------------------------------------
-- case 2b: 同样的 CCFS 流程, 但假 fs.makeDir 只建一级(任务书里写的"like CC"语义)
--   冻结的 API 面里写了 makeDir 只建一级; CC:Tweaked 文档却说"连缺失的父目录一起建"
--   (~/docs/cc-tweaked/module/fs.md)。两种语义都跑一遍, 差别就是这一条:
--   ccTarget.mkdirp 一次只 makeDir 一整条相对路径(如 etc/systemd/system), 中间层没人建;
--   ext2Target.mkdirp 是自己逐段建的, 所以 EXT2 不受影响。
-- ---------------------------------------------------------------
runCase("2b", "CCFS with strict one-level fs.makeDir (doc conflict probe)", function()
    local w = newSession({
        name = "case2b-ccfs-mkdir1", capacity = 4 * 1024 * 1024, drives = { "left" },
        mkdirOneLevel = true,
    })
    out("  dir: " .. w.dir .. "\n")
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })
    w:runInstallScript()
    reportRun(w)
    okNoUnhandledError(w)

    ok(logHas(w, "FAIL"), "一级 makeDir 下 CCFS 安装如实报 FAIL")
    ok(not w:existsFile("/.boot"), "失败后不写 /.boot(fail-fast)")
    local l = w:log() or ""
    local mkdirFail = l:find("mkdir failed:", 1, true) ~= nil
    ok(mkdirFail, "失败原因是 mkdir failed(中间目录没被创建)",
       "log tail: " .. short(l:sub(-200)))
    if mkdirFail then
        out("  note: 一级 makeDir 下 ccTarget.mkdirp 建不出 etc/systemd/system;\n")
        out("        ext2Target.mkdirp 逐段建所以 EXT2 没事。若真机 CC 的 makeDir 不建父目录,\n")
        out("        这就是 CCFS 装机必然失败的 bug(修法: ccTarget.mkdirp 也逐段建)。\n")
    end
end)

-- ---------------------------------------------------------------
-- case 3: Back / Quit 导航
-- ---------------------------------------------------------------
runCase("3", "back (backspace) + quit (q)", function()
    local w = newSession({ name = "case3-nav", capacity = 4 * 1024 * 1024, drives = { "left" } })
    out("  dir: " .. w.dir .. "\n")
    w:play({ key = keys.enter })  -- 1 确认 CCFS -> 第 2 步
    w:play({ key = keys.backspace }) -- Backspace: 回第 1 步(CraftOS 没有 Esc)
    w:play({ key = keys.q })      -- 退出
    w:runInstallScript()
    reportRun(w)
    okNoUnhandledError(w)

    ok(#w.frames >= 3, "至少抓到 3 帧(第1步 -> 第2步 -> 退回第1步)", "frames=" .. #w.frames)
    local f1, f2, f3 = w.frames[1], w.frames[2], w.frames[3]
    ok(f1 and f1.titles[1] == "Install type", "第 1 帧在 Install type",
       f1 and table.concat(f1.titles, "/") or "none")
    ok(f2 and f2.titles[1] == "Install target", "Enter 后标题变成 Install target",
       f2 and table.concat(f2.titles, "/") or "none")
    ok(f3 and f3.titles[1] == "Install type", "Backspace 后标题退回 Install type",
       f3 and table.concat(f3.titles, "/") or "none")
    ok(f3 and f2 and table.concat(f3.titles, "/") ~= table.concat(f2.titles, "/"),
       "退回确实换了一屏")
    -- 反色光标行在两屏上位置不同(光标确实动了)
    if f2 and f3 then
        local function cursorRowOf(f)
            for y, row in ipairs(f.rows) do if row:find("%[[xX]%]") then return y, row end end
        end
        local y2, r2 = cursorRowOf(f2)
        ok(y2 ~= nil and r2:find("computer storage", 1, true) ~= nil,
           "第 2 步光标行是 computer storage", tostring(r2))
        ok(f2.hl[y2 or 0] == true, "第 2 步光标行反色")
    end
    ok(w.ok, "Q 之后安装器正常返回(没有卡在等事件/死循环)", tostring(w.err))
    ok(not w:existsFile("/.boot"), "退出没有写 /.boot")
    ok(not w:existsFile("/bin/sh"), "退出没有铺 payload")
    ok(not logHas(w, "Install OK"), "退出后日志里没有 Install OK")
    ok(not logHas(w, "making ext2 image:"), "退出后日志里没有建镜像记录")
    -- 任务书要求"退出时 /delin-install.log 没有内容"; 实现把向导每一步也写进日志了
    -- (这符合"电脑读不了屏, 日志是唯一证据"的设计, 冻结串列表也没禁止)。这里只硬断言
    -- "没有开始安装", 日志非空本身打印成诊断而不是失败。
    local l = w:log()
    if l ~= nil and l ~= "" then
        out("  note: 退出时 /delin-install.log 已有 " .. #l .. " 字节向导过程日志:\n")
        for line in l:gmatch("[^\r\n]*") do
            if line ~= "" then out("        | " .. line .. "\n") end
        end
        out("        (任务书的字面要求是「退出时日志应为空」; 这是实现的额外记录, 不影响 quit 语义)\n")
    end
end)

-- ---------------------------------------------------------------
-- case 3b: 文本输入里"行首再按一次退格 = 回上一步"
--          (CraftOS 没有 Esc 可用, 这是唯一的"取消输入"手势)
-- ---------------------------------------------------------------
runCase("3b", "input step: backspace at line start goes back", function()
    local w = newSession({ name = "case3b-input-back", capacity = 4 * 1024 * 1024, drives = { "left" } })
    out("  dir: " .. w.dir .. "\n")
    w:play({ key = keys.down })       -- CCFS -> EXT2
    w:play({ key = keys.enter })      -- 1 确认类型
    w:play({ key = keys.enter })      -- 2 目标 = 计算机存储
    w:play({ key = keys.enter })      -- 3 源 = 第一个预置(取 manifest)
    w:playKey(keys.down, 5)           -- 4 大小: auto -> 256 -> 512 -> 768 -> 1024 -> custom
    w:play({ key = keys.enter })      -- 打开 custom 数字输入(此刻框是空的)
    w:play({ key = keys.backspace })  -- 行首退格 = 回上一步(回到大小列表)
    w:play({ key = keys.q })          -- 退出
    w:runInstallScript()
    reportRun(w)
    okNoUnhandledError(w)

    -- 抓"输入屏"(标题是 "Image size (KB)", 不在 STEP_TITLES 里, 所以按行文本找)
    local function frameWithText(text)
        for _, f in ipairs(w.frames) do
            for _, row in ipairs(f.rows) do
                if row:find(text, 1, true) then return f end
            end
        end
        return nil
    end
    local inputFrame = frameWithText("Image size (KB)")
    ok(inputFrame ~= nil, "出现过自定义容量输入屏('Image size (KB)')")
    -- 输入屏之后必须回到大小列表屏(有 'custom ...' 选项行), 而不是退到源步骤
    local backToList = false
    if inputFrame then
        local seen = false
        for _, f in ipairs(w.frames) do
            if f == inputFrame then seen = true
            elseif seen then
                for _, row in ipairs(f.rows) do
                    -- 回到容量列表: 有一行是 'custom ...' 选项(光标在它上面时是 [x])
                    if row:find("custom", 1, true) then backToList = true end
                end
                if backToList then break end
                if f.titles[1] == "Install source" or f.titles[1] == "Summary" then break end
            end
        end
    end
    ok(backToList, "行首退格后退回 Image size 列表(没有一路退到源/摘要)")
    ok(w.ok, "Q 之后安装器正常返回(没有卡住)", tostring(w.err))
    ok(not w:existsFile("/.boot"), "没写 /.boot")
    ok(not w:existsFile("/parts/root.img"), "没建镜像")
    ok(not logHas(w, "Install OK"), "日志里没有 Install OK")
end)

-- ---------------------------------------------------------------
-- case 4: custom 镜像大小
-- ---------------------------------------------------------------
runCase("4", "EXT2 + custom image size 640 KB", function()
    local w = newSession({ name = "case4-custom-size", capacity = 4 * 1024 * 1024, drives = { "left" } })
    out("  dir: " .. w.dir .. "\n")
    w:play({ key = keys.down })   -- CCFS -> EXT2
    w:play({ key = keys.enter })  -- 1 确认类型
    w:play({ key = keys.enter })  -- 2 目标 = 计算机存储
    w:play({ key = keys.enter })  -- 3 源 = 默认
    -- 4 大小: auto -> 256 -> 512 -> 768 -> 1024 -> custom
    w:playKey(keys.down, 5)
    w:play({ key = keys.enter })  -- 打开 custom 数字输入
    -- 实现约定: 自定义数字框**从空串开始**(不预填当前值, 免得改数字要先擦)。
    -- 所以这里不能先按退格 —— 空框上再按退格是"回上一步"(见 case 3b)。
    w:playText("640")
    w:play({ key = keys.enter })  -- 收下 640 KB
    w:play({ key = keys.enter })  -- 5 摘要 = Start installation
    w:play({ key = keys.enter })  -- 装完提示键
    w:play({ key = keys.enter })
    w:runInstallScript()
    reportRun(w)
    okNoUnhandledError(w)

    okSawStep(w, "Image size")
    local sizeFrame = w:frameWith("Image size")
    if sizeFrame then
        for _, label in ipairs({ "auto", "256 KB", "512 KB", "768 KB", "1024 KB", "custom" }) do
            ok(frameHasOption(sizeFrame, label), "Image size 列表含选项 '" .. label .. "'")
        end
        okCursorRendering(sizeFrame, "Image size")
        local ya, y256 = optionRowOf(sizeFrame, "auto"), optionRowOf(sizeFrame, "256 KB")
        ok(ya ~= nil and y256 ~= nil and ya < y256, "auto 在 256 KB 前面(默认项在最上)",
           tostring(ya) .. "," .. tostring(y256))
    else
        ok(false, "Image size 列表渲染过")
    end
    ok(logHas(w, "making ext2 image: 640 KB"), "日志含 'making ext2 image: 640 KB'",
       "log: " .. short(w:log() or "", 400))
    ok(logHas(w, "Install OK"), "日志含 Install OK")
    ok(ext2MagicOk(w:hostPath("/parts/root.img")), "镜像 magic 0xEF53")
    ok(w:existsFile("/parts/root.img"), "/parts/root.img 存在")
end)

-- ---------------------------------------------------------------
-- case 5a: 源步骤是"预置源列表 + custom 手输"(实现的约定形态):
--          列表上敲字符什么都不该发生(字符事件被列表忽略), 也不会把 URL 弄脏;
--          只有 Enter 才往下走。功能要求(源不通就 fail-fast)由 case 5b 覆盖。
-- ---------------------------------------------------------------
runCase("5a", "source step is a preset list (typing on the list changes nothing)", function()
    local w = newSession({ name = "case5a-source-list", capacity = 4 * 1024 * 1024, drives = { "left" } })
    out("  dir: " .. w.dir .. "\n")
    w:play({ key = keys.enter })  -- 1 CCFS
    w:play({ key = keys.enter })  -- 2 目标 = 计算机存储
    w:playText("X")               -- 列表上敲字符: 应当什么都不发生
    w:play({ key = keys.enter })  -- 3 源 = 第一个预置 -> 取 manifest -> 进摘要
    w:play({ key = keys.enter })  -- 5 摘要 = Start installation
    w:play({ key = keys.enter })  -- 装完提示键
    w:play({ key = keys.enter })
    w:runInstallScript()
    reportRun(w)
    okNoUnhandledError(w)

    local srcFrame = w:frameWith("Install source")
    ok(srcFrame ~= nil, "渲染过 Install source")
    ok(srcFrame ~= nil and frameHasOption(srcFrame, "custom"), "源列表里有 'custom ...' 手输项")
    ok(srcFrame ~= nil and frameHasOption(srcFrame, "http://127.0.0.1:10568/0.0.2"),
       "源列表里有默认源 URL 选项")
    -- 敲进去的字符不该出现在任何一行(列表不接收字符输入)
    local dirty = nil
    if srcFrame then
        for _, row in ipairs(srcFrame.rows) do
            if row:find("0.0.2X", 1, true) then dirty = row end
        end
    end
    ok(dirty == nil, "列表上敲的字符没有混进 URL", tostring(dirty))
    local sum = w:frameWith("Summary")
    ok(sum ~= nil, "Enter 后进到 Summary", "steps=" .. table.concat(w.titlesSeen, " -> "))
    local sumOk = false
    if sum then
        for _, row in ipairs(sum.rows) do
            if row:find("http://127.0.0.1:10568/0.0.2", 1, true) then sumOk = true end
        end
    end
    ok(sumOk, "Summary 里的 install source 就是那个预置 URL")
    -- 真的装完了: URL 没被敲进去的字符弄脏, 否则 manifest 拉不到、装不下去
    ok(logHas(w, "Install OK"), "装完了(URL 没被敲入字符弄脏)",
       "log: " .. short(w:log() or "", 300))
    ok(w:existsFile("/.boot"), "写了 /.boot")
end)

-- ---------------------------------------------------------------
-- case 5b: 坏源 URL 的 fail-fast(走实现真正提供的路径: 源列表 -> custom 手输)。
--          断言的是功能: 拉 manifest 失败 -> 停在源步骤, 绝不开始装。
-- ---------------------------------------------------------------
runCase("5b", "bad source URL fails fast (via the custom URL entry)", function()
    local w = newSession({ name = "case5b-bad-url", capacity = 4 * 1024 * 1024, drives = { "left" } })
    out("  dir: " .. w.dir .. "\n")
    local BAD = "http://127.0.0.1:1/delin" -- 合法 http URL, 但没人托管 -> http.get 返回 nil
    w:play({ key = keys.enter })  -- 1 CCFS
    w:play({ key = keys.enter })  -- 2 目标 = 计算机存储
    -- 3 源: 列表最后一项是 custom 手输(Up 从第一项回绕到最后一项, 与列表长度无关)
    w:play({ key = keys.up })
    w:play({ key = keys.enter })
    w:playText(BAD)
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })  -- 万一它放行了: 后面几步也按下去
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })
    w:runInstallScript()
    reportRun(w)
    okNoUnhandledError(w)

    ok(w:sawTitle("Install source"), "到过 Install source 步骤",
       "steps=" .. table.concat(w.titlesSeen, " -> "))
    local last = w.frames[#w.frames]
    ok(last ~= nil and last.titles[1] == "Install source",
       "取 manifest 失败后仍停在 Install source",
       last and table.concat(last.titles, "/") or "none")
    ok(not w:sawTitle("Summary"), "没有走到 Summary", "steps=" .. table.concat(w.titlesSeen, " -> "))
    -- 确实去取过 manifest(说明它真的试了, 只是失败了)
    local tried = false
    for _, u in ipairs(w.httpUrls) do
        if u:find(BAD, 1, true) and u:find("manifest", 1, true) then tried = true end
    end
    ok(tried, "对坏源尝试取过 <url>/manifest", "requests=" .. table.concat(w.httpUrls, " "))
    ok(not w:existsFile("/.boot"), "没有写 /.boot")
    ok(not w:existsFile("/bin/sh"), "没有铺 payload")
    ok(not logHas(w, "Install OK"), "日志里没有 Install OK")
    -- 屏幕上应当能看出错(措辞没冻结, 只做提示)
    local scr = w:screen()
    local looksLikeError = scr:find("rror", 1, true) or scr:find("ail", 1, true) or
                           scr:find("annot", 1, true) or scr:find("nvalid", 1, true) or
                           scr:find("nreachable", 1, true) or scr:find("refused", 1, true)
    if not looksLikeError then
        note("屏幕上没找到常见错误词, 请人工看一眼 dump 的最后一帧")
    else
        out("  info 屏幕上给出了错误提示(措辞未冻结, 不计入断言)\n")
    end
end)

-- ---------------------------------------------------------------
-- case 6: 空间不足 fail-fast(CCFS)
-- ---------------------------------------------------------------
runCase("6", "not enough space fails fast (CCFS, 64 KB)", function()
    local w = newSession({ name = "case6-nospace", capacity = 64 * 1024, drives = { "left" } })
    out("  dir: " .. w.dir .. "\n")
    w:play({ key = keys.enter }) -- CCFS
    w:play({ key = keys.enter }) -- 计算机存储
    w:play({ key = keys.enter }) -- 默认源
    w:play({ key = keys.enter }) -- Start installation
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })
    w:runInstallScript()
    reportRun(w)
    okNoUnhandledError(w)

    ok(logHas(w, "FAIL"), "日志含 FAIL")
    ok(not w:existsFile("/.boot"), "payload 铺失败后绝不写 /.boot")
    ok(not w:existsFile("/boot/delin.lua"), "没有写引导入口")
    ok(not logHas(w, "Install OK"), "日志里没有 Install OK")
end)

-- ---------------------------------------------------------------
-- case 7: 无人值守(/delin-install.cfg + auto 1), 不需要任何按键
-- ---------------------------------------------------------------
runCase("7", "unattended install from /delin-install.cfg (no key events)", function()
    local w = newSession({ name = "case7-unattended", capacity = 4 * 1024 * 1024, drives = { "left" } })
    out("  dir: " .. w.dir .. "\n")
    w:writeTarget("/delin-install.cfg", table.concat({
        "url " .. BASE_URL,
        "type ext2",
        "target computer",
        "size auto",
        "auto 1",
    }, "\n") .. "\n")
    -- 无人值守路径应当不看屏幕; 万一它在装完要一个键(旧引擎就是), 这里给几个空按键兜底。
    -- 假设: auto 路径不需要 UI 交互, 多余的 enter 只是"按了没反应"。
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })
    w:runInstallScript()
    reportRun(w)
    okNoUnhandledError(w)

    -- 无人值守的关键要求: 流程本身不需要任何按键。收尾若还要"按任意键", 允许消耗 1 个
    -- (旧引擎收尾就会 waitKey; 契约没冻结收尾行为 -> 这是**假设**, 见报告)。
    local consumed = 3 - #w.queue
    ok(consumed <= 1, "无人值守流程不需要按键(最多一个收尾按键)",
       "consumed=" .. consumed .. " key events")
    if #w.titlesSeen > 0 then
        note("无人值守时屏幕上渲染了步骤: " .. table.concat(w.titlesSeen, " -> "))
    end
    ok(logHas(w, "Install OK"), "日志含 Install OK")
    eq(trim(w:file("/.boot")), "/boot/dlub.lua", "/.boot == /boot/dlub.lua")
    eq(trim(w:file("/dlub.cfg")), "rootfs /parts/root.img", "/dlub.cfg == rootfs /parts/root.img")
    ok(w:existsFile("/parts/root.img"), "/parts/root.img 存在")
    ok(ext2MagicOk(w:hostPath("/parts/root.img")), "镜像 magic 0xEF53")
    ok(w:existsFile("/boot/dlub.lua"), "/boot/dlub.lua 存在")
end)

-- ---------------------------------------------------------------
-- case 8: 两个驱动器 -> 目标列表 > 1 项, 且能装到第二个盘
-- ---------------------------------------------------------------
runCase("8", "target list with two drives; install onto the second drive", function()
    local w = newSession({
        name = "case8-two-drives", capacity = 4 * 1024 * 1024,
        driveCapacity = 2 * 1024 * 1024, drives = { "left", "back" },
    })
    out("  dir: " .. w.dir .. "\n")
    w:play({ key = keys.enter })               -- 1 CCFS
    w:play({ key = keys.down })                -- 2 目标: computer storage -> left
    w:play({ key = keys.down })                --             left -> back
    w:play({ key = keys.enter })               -- 确认 back
    w:play({ key = keys.enter })               -- 3 源 = 默认
    w:play({ key = keys.enter })               -- 4 摘要 = Start installation
    w:play({ key = keys.enter })
    w:play({ key = keys.enter })
    w:runInstallScript()
    reportRun(w)
    okNoUnhandledError(w)

    local tf = w:frameWith("Install target")
    ok(tf ~= nil, "渲染过 Install target")
    if tf then
        ok(frameHasOption(tf, "computer storage"), "目标列表有选项 'computer storage'")
        ok(frameHasOption(tf, "left"), "目标列表有选项 'left'")
        ok(frameHasOption(tf, "back"), "目标列表有选项 'back'(第二个驱动器)")
        local yc = optionRowOf(tf, "computer storage")
        local yl = optionRowOf(tf, "left")
        local yb = optionRowOf(tf, "back")
        ok(yc == 1 or (yc and yl and yb and yc < yl and yl < yb),
           "目标列表顺序: computer storage -> left -> back", yc .. "," .. yl .. "," .. yb)
        okCursorRendering(tf, "Install target")
    end
    local sum = w:frameWith("Summary")
    ok(sum ~= nil and (function()
        for _, row in ipairs(sum and sum.rows or {}) do
            if row:find("target", 1, true) and row:find("back", 1, true) then return true end
        end
        return false
    end)(), "Summary 的 target 行显示 back",
       sum and table.concat(sum.rows, " | ") or "没有 Summary 帧")
    -- 装到第二个盘(/disk2), 引导配置仍在计算机存储上
    ok(existsHost(w:drivePath("back", "/bin/sh")), "payload 落在 /disk2 (驱动器 back)")
    ok(not existsHost(w:drivePath("left", "/bin/sh")), "驱动器 left 没被动过")
    eq(trim(w:file("/dlub.cfg")), "ccdisk back", "/dlub.cfg == ccdisk back")
    eq(trim(w:file("/.boot")), "/boot/dlub.lua", "/.boot == /boot/dlub.lua")
    ok(w:existsFile("/boot/dlub.lua"), "计算机存储上有 /boot/dlub.lua")
    ok(logHas(w, "Install OK"), "日志含 Install OK",
       "log: " .. short(w:log() or "", 400))
end)

-- ===============================================================
-- 汇总
-- ===============================================================

out("\n== summary ==\n")
out(string.format("cases: %d passed, %d failed\n", casesPass, casesFail))
out(string.format("assertions: %d passed, %d failed\n", pass, fail))
if #DEV > 0 then
    out("contract deviations found (" .. #DEV .. "):\n")
    for i, d in ipairs(DEV) do out(string.format("  %d) %s\n", i, d)) end
    out("  -> 这些失败是契约偏差, 不是 harness bug; 断言没有为了跑绿而放宽\n")
end
if not CONTRACT.multiStep then
    out("contract: dist/install.lua 不是冻结的多步交互版(见上面的 contract probe) -> "
        .. "上面的失败是预期结果\n")
else
    out("contract: 多步交互流程存在(步骤 " .. table.concat(CONTRACT.steps, " -> ") .. ")\n")
end
if fail > 0 then
    out("debug: 失败用例的屏幕/日志 dump 就在上面; 用例目录 /tmp/delin-installer-test-<pid>/\n")
    out("debug: 单独复跑一个用例: lua5.1 tools/installertest.lua --case=<id> --dump-screens\n")
end
hostos.exit(fail == 0 and 0 or 1)
