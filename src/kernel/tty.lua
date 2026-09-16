--[[ Delin 字符终端设备(/dev/ttyN)。
     内建文本缓冲(字符×前景/背景色) + 光标 + 换行 + 滚动 + 清屏。
     write(s) 在当前光标处绘制并推进; flush() 把脏单元格推到 ScreenDevice。
     term 型设备(CC monitor)按原生单元格绘制; pixel 型设备(Tom/Void)按
     像素字格(cellW×cellH)绘制, 颜色码(0-15)先换算成 ARGB 再下发。

     键盘输入: 每个 tty 维护前台焦点(focus)。调度器把 CC 的 char/key/paste
     事件经 tty.feedInput 路由给焦点 tty, 由它做行缓冲 + 回显(经典 canonical
     行规程); 句柄的 readLine()/read() 阻塞调用进程直到拿到一整行。 ]]

local signal = require("kernel.signal")

local lock = require("kernel.lock")

local tty = {}

-- ^C/^Z 信号路由回调(boot 注入): (sig) -> nil。避免 tty 依赖 process 造成循环。
tty.onSignal = nil

-- 读保护回调(process 注入): (ttyName) -> true 表示调用进程不是该 tty 前台进程组,
-- 按 POSIX 须投递 SIGTTIN 并阻塞(由注入方负责投递)。避免 tty 依赖 process 造成循环。
tty.readGuard = nil

local nextIndex = 0
local devices = {} -- "ttyN" -> console ctx
local focus = nil  -- 前台 tty 名(接收键盘输入)

-- tty 逻辑 16 色 -> ARGB(0xAARRGGBB)。索引为 tty 内部色序(0=black..f=white), 供 pixel 型
-- 设备渲染。注意这与 CC 的 blit 色码顺序相反(CC blit "0"=white.."f"=black), 见 TO_CC。
local PALETTE = {
    [0x0] = 0x000000, -- black
    [0x1] = 0xB300B3, -- purple
    [0x2] = 0x3344CC, -- blue
    [0x3] = 0x66CCCC, -- cyan
    [0x4] = 0x4CBB4C, -- green
    [0x5] = 0x66CC33, -- lime
    [0x6] = 0x7F3300, -- brown
    [0x7] = 0xCC3333, -- red
    [0x8] = 0x4C4C4C, -- grey
    [0x9] = 0x999999, -- lightGrey
    [0xa] = 0xE96699, -- pink
    [0xb] = 0xE6E633, -- yellow
    [0xc] = 0xE69C33, -- orange
    [0xd] = 0xE64CE6, -- magenta
    [0xe] = 0x99CCFF, -- lightBlue
    [0xf] = 0xFFFFFF, -- white
}

-- tty 色索引(0=black..f=white) -> CC blit 色码序号(0=white..f=black)。CC 的 blit 十六进制码
-- 顺序是 white..black, 与 PALETTE 相反; term 型设备的 dev.text/blit 用 hex() 生成 blit 码,
-- 若直接喂 PALETTE 索引会把黑白颠倒(白底黑字)。
local TO_CC = {
    [0x0] = 0xf, [0x1] = 0xa, [0x2] = 0xb, [0x3] = 0x9,
    [0x4] = 0xd, [0x5] = 0x5, [0x6] = 0xc, [0x7] = 0xe,
    [0x8] = 0x7, [0x9] = 0x8, [0xa] = 0x6, [0xb] = 0x4,
    [0xc] = 0x1, [0xd] = 0x2, [0xe] = 0x3, [0xf] = 0x0,
}
-- tty 色索引 -> CC colors.* 位掩码(term 型设备的 fill/setBackgroundColor 使用)。
local COLOR_BIT = {
    [0xf] = 0x1,    -- white
    [0xc] = 0x2,    -- orange
    [0xd] = 0x4,    -- magenta
    [0xe] = 0x8,    -- lightBlue
    [0xb] = 0x10,   -- yellow
    [0x5] = 0x20,   -- lime
    [0xa] = 0x40,   -- pink
    [0x8] = 0x80,   -- grey
    [0x9] = 0x100,  -- lightGrey
    [0x3] = 0x200,  -- cyan
    [0x1] = 0x400,  -- purple
    [0x2] = 0x800,  -- blue
    [0x6] = 0x1000, -- brown
    [0x4] = 0x2000, -- green
    [0x7] = 0x4000, -- red
    [0x0] = 0x8000, -- black
}

local DEFAULT_FG, DEFAULT_BG = 0xf, 0x0

-- ANSI SGR 颜色码(30-37/90-97 前景, 40-47/100-107 背景) -> tty 色索引(VGA 风格 16 色)。
-- 索引 1..8 = 30..37 / 40..47, 9..16 = 90..97 / 100..107:
--   黑 红 绿 棕(暗黄) 蓝 紫 青 浅灰 | 灰 粉(亮红) 黄绿(亮绿) 黄 浅蓝(亮蓝) 品红 青(亮青) 白
-- CC 没有亮红/亮青/亮蓝, 取色相最接近的粉/青/浅蓝(见 README「终端 ANSI 转义」)。
local ANSI_COLOR = {
    [1] = 0x0, [2] = 0x7, [3] = 0x4, [4] = 0x6, [5] = 0x2, [6] = 0x1, [7] = 0x3, [8] = 0x9,
    [9] = 0x8, [10] = 0xa, [11] = 0x5, [12] = 0xb, [13] = 0xe, [14] = 0xd, [15] = 0x3, [16] = 0xf,
}

-- SGR 1(粗体): CC 无粗体字形, 按 16 色终端惯例渲染成亮色(仅列出会变亮的色)。
local BOLD = {
    [0x0] = 0x8, [0x7] = 0xa, [0x4] = 0x5, [0x6] = 0xb,
    [0x2] = 0xe, [0x1] = 0xd, [0x3] = 0x3, [0x9] = 0xf,
}

--- 当前有效前景色(粗体按亮色渲染)。
local function effFg(ctx)
    return ctx.bold and (BOLD[ctx.fg] or ctx.fg) or ctx.fg
end

--- 构造一个控制台上下文。
---@param dev table ScreenDevice (mode="term"|"pixel"; getSize; text; flush)
local function newCtx(dev)
    local w, h = dev.getSize()
    local ctx
    if dev.mode == "term" then
        -- 原生字符终端: 一个终端单元格 = 屏幕一个字符格
        ctx = { dev = dev, mode = "term", cols = math.floor(w), rows = math.floor(h), cellW = 1, cellH = 1 }
    else
        local cw = dev.cellW
        local ch = dev.cellH
        ctx = {
            dev = dev, mode = "pixel",
            cols = math.floor(w / cw),
            rows = math.floor(h / ch),
            cellW = cw, cellH = ch,
        }
    end
    local n = ctx.cols * ctx.rows
    local grid = {}
    for i = 1, n do grid[i] = { ch = " ", fg = DEFAULT_FG, bg = DEFAULT_BG } end
    ctx.grid = grid
    ctx.cursorX, ctx.cursorY = 0, 0
    ctx.fg, ctx.bg = DEFAULT_FG, DEFAULT_BG
    ctx.dirty = {}      -- flat index -> true
    ctx.dirtyList = {}  -- array of flat index
    ctx.closed = false
    -- 行输入状态(canonical): 正在编辑的行 与 已完成的整行队列
    ctx.inputBuffer = ""
    ctx.lineQueue = {}
    ctx.echo = true -- 回显开(密码时 login 置 false)
    -- ^C/^D 中断状态: eof(^D 行首) / intr(^C/^Z 取消行) 由 readLine 消费。
    ctx.eof = false
    ctx.intr = false
    ctx.reading = false -- 是否有进程正阻塞在 readLine 上(判断 ^C 是否要打断读)
    -- 光标: cursorOn 当前是否显示(闪烁 tick 翻转); cursorHidden 是程序用 ?25l 隐藏的常驻开关;
    -- cursorRenderedIdx 已按光标反显渲染的单元格。
    ctx.cursorOn = true
    ctx.cursorHidden = false
    ctx.cursorRenderedIdx = nil
    -- ANSI 转义状态机: escState=nil(普通)/"esc"/"csi"/"osc"/"osc_esc"/"charset";
    -- escParams/escInter 收集 CSI 的参数字节与中间字节(序列可跨多次 write)。
    ctx.escState = nil
    ctx.escParams = ""
    ctx.escInter = ""
    ctx.bold = false
    ctx.reverse = false
    ctx.saved = nil -- 保存的光标/属性(ESC 7 / CSI s)
    -- 原始模式(cbreak, Linux termios 的 ICANON|ECHO 关、ISIG 开): 字符不经过行规程,
    -- 直接按字节进 keyBuf; 特殊键按 ANSI 序列进 keyBuf —— 于是分页器(more/less)这类
    -- 全屏程序拿到的是"终端字节流", 与 Linux 上 read(1) 的契约一致。见下面的 rawPush。
    ctx.raw = false
    ctx.rawEcho = true -- 进原始模式前的回显状态, 退出时恢复
    ctx.keyBuf = ""    -- 待读的输入字节(原始模式)
    -- 去重闩锁: CC 对 enter/backspace/tab 与 Ctrl+字母可能**同时**发 key 与 char 事件
    -- (GLFW 的 char 回调), 两种都处理就会"按一次删两个字符/出一空行"。置上期望的字节,
    -- 让紧随其后、值相同的那个 char 事件被丢掉(见 feedInput)。canonical 模式同样需要它。
    ctx.dupChar = nil
    return ctx
end

--- 光标当前是否应该显示(闪烁开 且 程序没隐藏它)。
local function cursorVisible(ctx)
    return ctx.cursorOn and not ctx.cursorHidden
end

--- 标记单元格(flat index)为脏。
local function markCell(ctx, idx)
    if not ctx.dirty[idx] then
        ctx.dirty[idx] = true
        ctx.dirtyList[#ctx.dirtyList + 1] = idx
    end
end

--- 某单元格(flat index)是否正位于光标之上。
local function cursorAt(ctx, idx)
    return (idx - 1) == ctx.cursorY * ctx.cols + ctx.cursorX
end

--- 光标移动/显隐后更新脏标记: 旧光标格恢复正显, 新光标格反显。
--- 调用后需 flushDirty 才能真正画到设备。
local function updateCursor(ctx)
    local old = ctx.cursorRenderedIdx
    local new = cursorVisible(ctx) and (ctx.cursorY * ctx.cols + ctx.cursorX + 1) or nil
    if old then markCell(ctx, old) end
    if new then markCell(ctx, new) end
    ctx.cursorRenderedIdx = new
end

local function scroll(ctx)
    -- 把内核自己的 grid 上移一行、末行清空(与设备侧的滚动保持一致)。
    for row = 0, ctx.rows - 2 do
        for col = 0, ctx.cols - 1 do
            ctx.grid[row * ctx.cols + col + 1] = ctx.grid[(row + 1) * ctx.cols + col + 1]
        end
    end
    for col = 0, ctx.cols - 1 do
        ctx.grid[(ctx.rows - 1) * ctx.cols + col + 1] =
            { ch = " ", fg = effFg(ctx), bg = ctx.bg, rev = ctx.reverse }
    end
    -- 滚动后旧的 cursorRenderedIdx 已失效(grid 内容移位), 必须重置。
    ctx.cursorRenderedIdx = nil
    -- 滚屏 = 把整屏标脏重画。**曾经试过调用设备原生滚动(`term.scroll`)只重画末行** ——
    -- 真机上文本不显示、光标残留(渲染与内核 grid 状态对不上, 而且那块屏没法读回来验证),
    -- 所以退回"老实重画"。真正的开销在**逐格 blit**(51x19 近千次 CC 调用), 那个已经由
    -- flushDirty 的"同一行连续同色合并成一次 dev.text"解决: 现在一次滚屏只有 ~19 次调用。
    for i = 1, ctx.rows * ctx.cols do markCell(ctx, i) end
    updateCursor(ctx)
end

local function putChar(ctx, ch)
    if ch == "\n" then
        ctx.cursorY = ctx.cursorY + 1
        ctx.cursorX = 0
    elseif ch == "\r" then
        ctx.cursorX = 0
        updateCursor(ctx)
        return
    elseif ch == "\b" then
        if ctx.cursorX > 0 then ctx.cursorX = ctx.cursorX - 1 end
        updateCursor(ctx)
        return
    elseif ch == "\t" then
        -- 前进到下一 tab 停靠点(8)
        ctx.cursorX = math.floor(ctx.cursorX / 8 + 1) * 8
    else
        local idx = ctx.cursorY * ctx.cols + ctx.cursorX + 1
        if idx <= ctx.rows * ctx.cols then
            ctx.grid[idx] = { ch = ch, fg = effFg(ctx), bg = ctx.bg, rev = ctx.reverse }
            markCell(ctx, idx)
        end
        ctx.cursorX = ctx.cursorX + 1
    end

    if ctx.cursorY >= ctx.rows then
        if ctx.cursorY > ctx.rows - 1 then
            ctx.cursorY = ctx.rows - 1
            if ctx.cursorX > ctx.cols - 1 then ctx.cursorX = ctx.cols - 1 end
            scroll(ctx)
        end
    elseif ctx.cursorX >= ctx.cols then
        ctx.cursorX = 0
        ctx.cursorY = ctx.cursorY + 1
        if ctx.cursorY >= ctx.rows then
            ctx.cursorY = ctx.rows - 1
            scroll(ctx)
        end
    end
    updateCursor(ctx)
end

--- 一格在设备上的最终前景/背景(SGR 7 反显 + 光标反显都在这里定)。
local function cellColors(ctx, idx)
    local cell = ctx.grid[idx]
    local fg, bg = cell.fg, cell.bg
    if cell.rev then fg, bg = bg, fg end -- SGR 7 反显(单元格级)
    if cursorAt(ctx, idx) and cursorVisible(ctx) then fg, bg = bg, fg end -- 光标反显
    return fg, bg
end

--- 绘制脏单元格到设备。光标所在格以反显(前景/背景互换)渲染, 形成区块光标。
--- **同一行里连续、同色的脏格合并成一次 dev.text**: term 型的 dev.text 是
--- `term.setCursorPos` + `term.blit` 两条 CC 调用, 逐格画一屏(51x19)要近千次 —— 整行输出
--- (ls/ps/grep 这类)因此慢得肉眼可见。合并之后一屏通常只剩十几次调用。
--- 一次 flush 最多画多少个**像素格**。
--- **为什么必须有这个上限**: 像素设备(台式机 tty2 = Tom GPU 那种)每格是 `rect` + `text` 两条
--- 外设调用, 而滚一次屏会把整屏(~1000 格)标脏 —— 那是一次**几千次外设调用**的同步阻塞,
--- 期间整台电脑不让出(外设调用不经过调度器), 别的进程全部停摆。真机实测: 在像素终端里跑
--- `find /`, 看门狗记到整机每次停 ~7 秒, `find` 自己被 CC 的 watchdog 以
--- "Too long without yielding" 杀掉(栈顶 rom/apis/peripheral.lua)。term 型设备本来就被
--- 合并成"每行一次", 一屏十几次调用, 不需要这个上限。
--- 超出的部分**留到下次 flush**(标脏不丢), 于是重画变成渐进式的: 屏幕先花后齐, 但不再卡住整机。
local PIXEL_CELL_BUDGET = 96

--- 一次 flush 最多连续干多少毫秒就放锁让出。
--- **为什么需要**: 像素/监视器的每次 `dev.text` 是**外设调用**(Tom GPU / monitor), 一次几毫秒,
--- 而它们**不消耗 VM 指令** —— 调度器的计数钩子在这段里根本不会触发。于是"不停往下写"的工具
--- (比如没有 yieldCheck 的 find/ls) 可以连续几秒不回到调度器: 整机停摆, 直到 CC 的 watchdog
--- 以 "Too long without yielding" 把它打死(真机实测 7 秒级停摆 + find 被杀)。
--- 这里补一个**按时间**的抢占点: 每 5ms 放锁让出一次(lock.pause 会先放锁再让出, 醒来拿回)。
local FLUSH_YIELD_MS = 5

local function flushDirty(ctx)
    local dev = ctx.dev
    local list = ctx.dirtyList
    local n = #list
    local i = 1
    local drawn = 0 -- 这一轮已经画了多少像素格(只对 pixel 型计数)
    local cut = nil   -- 预算用尽时的断点: 剩下的格子留到下一轮
    -- 只有"进程上下文里跑进来的"flush 才能让出(内核自己的 blink tick 在宿主上下文里, 让出会炸)。
    -- **判据用 inProcess 而不是 inKernel**: 有些句柄(引导期建的 stdio)绕过了包装器, 不持锁,
    -- 但一样在进程上下文里 —— 用 inKernel 判会漏掉它们, 于是狂写输出的进程完全不让出。
    local yieldAt = (lock.preemptOn() and lock.inProcess()) and os.epoch("utc") or nil
    while i <= n do
        local idx = list[i]
        local col = (idx - 1) % ctx.cols
        local row = math.floor((idx - 1) / ctx.cols)
        local fg, bg = cellColors(ctx, idx)
        local text = ctx.grid[idx].ch
        -- 往后吃同色的连续格(中间有没标记的格子、或跨行就断)
        local j = i + 1
        while j <= n do
            local idx2 = list[j]
            if idx2 ~= idx + (j - i) then break end
            if ((idx2 - 1) % ctx.cols) == 0 then break end
            local f2, b2 = cellColors(ctx, idx2)
            if f2 ~= fg or b2 ~= bg then break end
            text = text .. ctx.grid[idx2].ch
            j = j + 1
        end
        if ctx.mode == "term" then
            -- term 型: 传给 dev.text 的是 CC blit 色码序号(hex() 会用), 需从 tty 色序换算。
            dev.text(col, row, text, TO_CC[fg], TO_CC[bg])
        else
            -- pixel 型: 逐格画(先用背景色填满整个字格, 再居中绘制字形)。比例字体的字格左右
            -- 留白区不清会残留旧像素; 光标块也因此能整格填充。
            for k = i, j - 1 do
                if drawn >= PIXEL_CELL_BUDGET then cut = k; break end
                drawn = drawn + 1
                local idxk = list[k]
                local cell = ctx.grid[idxk]
                local colk = (idxk - 1) % ctx.cols
                local rowk = math.floor((idxk - 1) / ctx.cols)
                local fgk, bgk = cellColors(ctx, idxk)
                local px = colk * ctx.cellW
                local py = rowk * ctx.cellH
                dev.rect(px, py, ctx.cellW, ctx.cellH, PALETTE[bgk])
                local x = px
                if dev.getTextWidth then
                    local cw = dev.getTextWidth(cell.ch)
                    local off = math.floor((ctx.cellW - cw) / 2)
                    if off > 0 then x = x + off end
                end
                dev.text(x, py, cell.ch, PALETTE[fgk], PALETTE[bgk])
            end
        end
        if cut then break end
        -- 时间片的抢占点: 外设调用再慢也不占 VM 指令, 计数钩子看不见, 这里自己让。
        if yieldAt and os.epoch("utc") - yieldAt >= FLUSH_YIELD_MS then
            yieldAt = os.epoch("utc")
            if lock.inKernel() then
                lock.pause(function() coroutine.yield("__preempt") end) -- 持锁: 先放锁再让
            else
                coroutine.yield("__preempt")
            end
        end
        i = j
    end
    if cut then
        -- 预算用尽: 把**还没画**的格子重新标脏(已经画过的丢掉), 下次 flush 接着画。
        local rest = {}
        for k = cut, n do rest[#rest + 1] = list[k] end
        ctx.dirty = {}
        ctx.dirtyList = rest
        for _, idx in ipairs(rest) do ctx.dirty[idx] = true end
    else
        ctx.dirty = {}
        ctx.dirtyList = {}
    end
    dev.flush()
end

-- ---------------------------------------------------------------
-- ANSI 转义序列(核心集, 见 README「终端 ANSI 转义」)
--   颜色: SGR 0/1/7/22/27/30-37/39/40-47/49/90-97/100-107
--   清屏: ED(J 0/1/2)、EL(K 0/1/2)
--   定位: CUP(H/f)、CUU/CUD/CUF/CUB(A/B/C/D)、CHA(G)、VPA(d)、CNL(E)、CPL(F)
--   光标: ?25h/?25l 显隐、ESC 7/ESC 8 与 CSI s/CSI u 保存恢复、ESC c 复位(RIS)
-- 序列可跨多次 write()(状态机在 ctx 上); 未知/不支持的序列按真实终端惯例静默忽略 ——
-- 这是终端协议的一部分(程序常发本机不认识的能力探测), 不是错误。
-- ---------------------------------------------------------------

--- 擦除用的空格: 用当前背景色(BCE 语义), 前景取默认色。
local function blankCell(ctx)
    return { ch = " ", fg = DEFAULT_FG, bg = ctx.bg }
end

--- 用背景色填满整屏(设备级填充, 不逐格重画)。光标位置由调用方决定。
local function eraseScreen(ctx)
    for i = 1, ctx.rows * ctx.cols do ctx.grid[i] = blankCell(ctx) end
    if ctx.mode == "term" then
        ctx.dev.fill(COLOR_BIT[ctx.bg])
    else
        ctx.dev.fill(PALETTE[ctx.bg])
    end
    ctx.dev.flush()
    ctx.dirty = {}
    ctx.dirtyList = {}
    ctx.cursorRenderedIdx = nil
end

local function saveCursor(ctx)
    ctx.saved = {
        x = ctx.cursorX, y = ctx.cursorY,
        fg = ctx.fg, bg = ctx.bg, bold = ctx.bold, reverse = ctx.reverse,
    }
end

local function restoreCursor(ctx)
    local s = ctx.saved
    if not s then return end
    ctx.cursorX, ctx.cursorY = s.x, s.y
    ctx.fg, ctx.bg, ctx.bold, ctx.reverse = s.fg, s.bg, s.bold, s.reverse
    updateCursor(ctx)
end

--- 定位光标(0-based, 越界裁剪)。
local function moveCursor(ctx, x, y)
    ctx.cursorX = math.max(0, math.min(ctx.cols - 1, x))
    ctx.cursorY = math.max(0, math.min(ctx.rows - 1, y))
    updateCursor(ctx)
end

--- ED(J): 0=光标到屏幕末尾, 1=屏幕开头到光标, 2=整屏。ED 不移动光标(ECMA-48)。
local function eraseInDisplay(ctx, mode)
    local n = ctx.rows * ctx.cols
    if mode == 2 then
        eraseScreen(ctx)
        updateCursor(ctx)
        flushDirty(ctx)
        return
    end
    local cur = ctx.cursorY * ctx.cols + ctx.cursorX + 1
    local from, to = cur, n
    if mode == 1 then from, to = 1, cur end
    for i = from, to do
        ctx.grid[i] = blankCell(ctx)
        markCell(ctx, i)
    end
    updateCursor(ctx)
end

--- EL(K): 0=光标到行尾, 1=行首到光标, 2=整行。
local function eraseInLine(ctx, mode)
    local base = ctx.cursorY * ctx.cols
    local from, to = ctx.cursorX, ctx.cols - 1
    if mode == 1 then from, to = 0, ctx.cursorX
    elseif mode == 2 then from, to = 0, ctx.cols - 1 end
    for c = from, to do
        local idx = base + c + 1
        ctx.grid[idx] = blankCell(ctx)
        markCell(ctx, idx)
    end
    updateCursor(ctx)
end

--- SGR(m): 设置字符属性。未列出的属性(4 下划线 / 未知)无 CC 对应能力, 忽略。
local function setSgr(ctx, params)
    for i = 1, #params do
        local p = params[i]
        if p == 0 then
            ctx.fg, ctx.bg, ctx.bold, ctx.reverse = DEFAULT_FG, DEFAULT_BG, false, false
        elseif p == 1 then
            ctx.bold = true
        elseif p == 7 then
            ctx.reverse = true
        elseif p == 22 then
            ctx.bold = false
        elseif p == 27 then
            ctx.reverse = false
        elseif p >= 30 and p <= 37 then
            ctx.fg = ANSI_COLOR[p - 29]
        elseif p == 39 then
            ctx.fg = DEFAULT_FG
        elseif p >= 40 and p <= 47 then
            ctx.bg = ANSI_COLOR[p - 39]
        elseif p == 49 then
            ctx.bg = DEFAULT_BG
        elseif p >= 90 and p <= 97 then
            ctx.fg = ANSI_COLOR[p - 81]
        elseif p >= 100 and p <= 107 then
            ctx.bg = ANSI_COLOR[p - 91]
        end
    end
end

--- RIS(ESC c): 复位终端 —— 清屏、属性回默认、光标回左上并恢复显示。
local function resetTerm(ctx)
    ctx.fg, ctx.bg, ctx.bold, ctx.reverse = DEFAULT_FG, DEFAULT_BG, false, false
    ctx.cursorHidden = false
    ctx.saved = nil
    eraseScreen(ctx)
    ctx.cursorX, ctx.cursorY = 0, 0
    updateCursor(ctx)
    flushDirty(ctx)
end

--- CSI 参数字节 -> 数字数组(空参数记 0, 缺省由各序列自行按 1 处理)。
local function parseParams(s)
    local out = {}
    for p in (s .. ";"):gmatch("([^;]*);") do out[#out + 1] = tonumber(p) or 0 end
    return out
end

--- 计数参数: 缺省/0 视为 1(ECMA-48 约定)。
local function count1(p)
    return (p and p ~= 0) and p or 1
end

--- CSI 终结字节分发。priv 为私有标记("?"/"<"/"="...); 带中间字节的序列不支持。
local function handleCsi(ctx, final, priv, params, inter)
    if #inter > 0 then return end
    local p1, p2 = params[1], params[2]
    if final == "m" then
        setSgr(ctx, params)
    elseif final == "J" then
        eraseInDisplay(ctx, p1)
    elseif final == "K" then
        eraseInLine(ctx, p1)
    elseif final == "H" or final == "f" then
        moveCursor(ctx, count1(p2) - 1, count1(p1) - 1)
    elseif final == "A" then
        moveCursor(ctx, ctx.cursorX, ctx.cursorY - count1(p1))
    elseif final == "B" then
        moveCursor(ctx, ctx.cursorX, ctx.cursorY + count1(p1))
    elseif final == "C" then
        moveCursor(ctx, ctx.cursorX + count1(p1), ctx.cursorY)
    elseif final == "D" then
        moveCursor(ctx, ctx.cursorX - count1(p1), ctx.cursorY)
    elseif final == "E" then
        moveCursor(ctx, 0, ctx.cursorY + count1(p1))
    elseif final == "F" then
        moveCursor(ctx, 0, ctx.cursorY - count1(p1))
    elseif final == "G" then
        moveCursor(ctx, count1(p1) - 1, ctx.cursorY)
    elseif final == "d" then
        moveCursor(ctx, ctx.cursorX, count1(p1) - 1)
    elseif final == "s" then
        saveCursor(ctx)
    elseif final == "u" then
        restoreCursor(ctx)
    elseif priv == "?" and p1 == 25 then
        ctx.cursorHidden = (final == "l")
        updateCursor(ctx)
    end
end

--- 喂一个字节: 普通字符落屏, 转义序列进状态机(跨 write 保持)。
local function feedByte(ctx, ch)
    local st = ctx.escState
    if st == nil then
        if ch == "\27" then
            ctx.escState, ctx.escParams, ctx.escInter = "esc", "", ""
        else
            putChar(ctx, ch)
        end
        return
    end
    local b = string.byte(ch)
    if st == "esc" then
        if ch == "[" then ctx.escState = "csi"
        elseif ch == "]" then ctx.escState = "osc"
        elseif ch == "(" or ch == ")" or ch == "*" or ch == "+" then ctx.escState = "charset"
        elseif ch == "7" then ctx.escState = nil; saveCursor(ctx)
        elseif ch == "8" then ctx.escState = nil; restoreCursor(ctx)
        elseif ch == "c" then ctx.escState = nil; resetTerm(ctx)
        else ctx.escState = nil end -- 未知单字符转义: 忽略
    elseif st == "charset" then
        ctx.escState = nil -- ESC ( <ch>: 字符集指定, 忽略(CC 只有一种字体)
    elseif st == "osc" then
        if ch == "\7" then ctx.escState = nil -- BEL 结束
        elseif ch == "\27" then ctx.escState = "osc_esc" end
    elseif st == "osc_esc" then
        ctx.escState = nil -- ESC \ (ST) 结束; 其它字符同样结束
    elseif b >= 0x30 and b <= 0x3f then
        ctx.escParams = ctx.escParams .. ch
    elseif b >= 0x20 and b <= 0x2f then
        ctx.escInter = ctx.escInter .. ch
    elseif b >= 0x40 and b <= 0x7e then
        ctx.escState = nil
        local ps, priv = ctx.escParams, ""
        local marker = ps:match("^([?<>=])")
        if marker then priv = marker; ps = ps:sub(2) end
        handleCsi(ctx, ch, priv, parseParams(ps), ctx.escInter)
    else
        ctx.escState = nil -- 非法参数字节: 放弃本序列
    end
end

-- ---------------------------------------------------------------
-- 行输入行规程(canonical): 调度器把字符喂进来, 这里负责缓冲 + 回显。
-- ---------------------------------------------------------------
--- 回显一个字符(推进光标)。
local function echoChar(ctx, ch)
    putChar(ctx, ch)
    flushDirty(ctx)
end

--- 从行缓冲区删最后一个字符, 屏上回退并擦除一格(无回显时仅改缓冲)。
local function backspaceChar(ctx)
    if #ctx.inputBuffer > 0 then
        ctx.inputBuffer = ctx.inputBuffer:sub(1, -2)
        if ctx.echo and ctx.cursorX > 0 then
            putChar(ctx, "\b")
            putChar(ctx, " ")
            putChar(ctx, "\b")
            flushDirty(ctx)
        end
    end
end

--- 结束当前行: 换行并把已完成的行压入 lineQueue, 重置输入缓冲。
local function finalizeLine(ctx)
    putChar(ctx, "\n")
    flushDirty(ctx)
    ctx.lineQueue[#ctx.lineQueue + 1] = ctx.inputBuffer
    ctx.inputBuffer = ""
end

--- 不 echo 换行地冲刷当前行(^D 行中=返回部分行)。
local function flushLine(ctx)
    ctx.lineQueue[#ctx.lineQueue + 1] = ctx.inputBuffer
    ctx.inputBuffer = ""
end

--- 直接把一串字符写进 tty(回显 ^C/^Z 用)。
local function writeStr(ctx, s)
    for i = 1, #s do putChar(ctx, s:sub(i, i)) end
    flushDirty(ctx)
end

--- 取消当前行(^C/^Z): 丢弃正在编辑的输入, 若有进程阻塞在读, 置 intr 打断它。
local function abortLine(ctx)
    ctx.inputBuffer = ""
    ctx.eof = false
    if ctx.reading then ctx.intr = true end
end

-- ---------------------------------------------------------------
-- 原始模式(cbreak)输入: 非规范模式下终端给的是**字节流**, 特殊键给 ANSI 转义序列。
-- ---------------------------------------------------------------
-- CC 的按键名 -> 终端发出的字节(与 xterm/vt100 一致, 于是"终端程序看到的字节"
-- 和 Linux 上跑 less 时一样)。只列"不产生 char 事件"的键: 能产生字符的键(字母/数字/
-- 空格/Tab/Enter/Backspace)走 char 事件那条路, 免得同一按键被记两次。
local KEY_SEQ = {
    ["up"] = "\27[A", ["down"] = "\27[B", ["right"] = "\27[C", ["left"] = "\27[D",
    ["home"] = "\27[H", ["end"] = "\27[F",
    ["pageUp"] = "\27[5~", ["pageDown"] = "\27[6~",
    ["insert"] = "\27[2~", ["delete"] = "\27[3~",
    ["f1"] = "\27OP", ["f2"] = "\27OQ", ["f3"] = "\27OR", ["f4"] = "\27OS",
    ["f5"] = "\27[15~", ["f6"] = "\27[17~", ["f7"] = "\27[18~", ["f8"] = "\27[19~",
    ["f9"] = "\27[20~", ["f10"] = "\27[21~", ["f11"] = "\27[23~", ["f12"] = "\27[24~",
}

--- key 事件中"同时也会产生 char 事件"的键 -> 该 char 事件的字节。CC 两条都发时用来去重。
local KEY_CHAR = {
    ["enter"] = "\n", ["return"] = "\n", ["keypadenter"] = "\n", ["keypad_enter"] = "\n",
    ["backspace"] = "\b", ["tab"] = "\t",
}

--- 长按会**重复**的键。CC 在按住时持续发 key 事件, 第 3 个参数 `isHeld` 为 true —— 以前这些
--- 事件被整个丢掉, 于是"按住退格只删一个字符、按住方向键只动一格"(真机反馈)。
--- Enter/Tab 故意不在这里: 按住回车刷一屏空行、按住 Tab 狂刷补全都不是想要的行为。
--- 按键字节的去重闩锁(KEY_CHAR + dupChar)对重复事件同样成立: 每个重复的 key 事件推一个字节,
--- 紧随其后的那个重复 char 事件被吃掉, 不会一次删两个字符。
local REPEATABLE = {
    ["backspace"] = true, ["delete"] = true,
    ["left"] = true, ["right"] = true, ["up"] = true, ["down"] = true,
    ["home"] = true, ["end"] = true,
    ["pageUp"] = true, ["pageDown"] = true,
}

--- 把字节追加到原始输入缓冲。
local function rawPush(ctx, bytes)
    if bytes and bytes ~= "" then ctx.keyBuf = ctx.keyBuf .. bytes end
end

--- 喂一个按键(原始模式): 特殊键变成 ANSI 序列, 其余(方向键之外的修饰键)忽略。
local function rawFeedKey(ctx, keycode, isHeld)
    local name = _G.keys and keys.getName and keys.getName(keycode) or nil
    if not name then return end
    local seq = KEY_SEQ[name]
    if seq then
        -- 方向键/Home/End 等: 按住会重复(REPEATABLE 里的键由 CC 持续发 held 事件)
        if isHeld and not REPEATABLE[name] then return end
        rawPush(ctx, seq)
    elseif KEY_CHAR[name] and (not isHeld or REPEATABLE[name]) then
        -- 该键也可能产生 char 事件: 先按 key 处理, 并把 char 事件记成"要丢掉的重复"。
        -- 版本 A: CC 只发 key 事件 -> 字节已在这里发出, dupChar 不会被用到;
        -- 版本 B: CC 两条都发 -> 紧随的那个 char 事件被丢掉, 不会发两遍。
        rawPush(ctx, KEY_CHAR[name])
        ctx.dupChar = KEY_CHAR[name]
    end
end

--- 喂一个字符(可打印 / 换行 / 退格)。无回显(echo=false)时缓冲但不绘制。
--- 原始控制字符(如 ^C 的 \3)不入行缓冲(控制组合由 routeKey 处理)。
local function feedChar(ctx, ch)
    if ctx.raw then rawPush(ctx, ch) return end
    local b = string.byte(ch or "", 1)
    if b and b < 0x20 and b ~= 0x0A and b ~= 0x0D and b ~= 0x08 and b ~= 0x09 then
        return
    end
    if ch == "\n" or ch == "\r" then
        finalizeLine(ctx)
    elseif ch == "\b" then
        backspaceChar(ctx)
    else
        ctx.inputBuffer = ctx.inputBuffer .. ch
        if ctx.echo then echoChar(ctx, ch) end
    end
end

--- 喂一个按键(key 事件)。只处理按下(非按住), 针对 backspace/enter。
local function feedKey(ctx, keycode, isHeld)
    if isHeld and not REPEATABLE[keys.getName(keycode)] then return end
    local name = keys.getName(keycode)
    -- CC 可能对这个键**同时**发 key 与 char 事件(见 ctx.dupChar 的说明): 记下期望的字节,
    -- 让紧随其后那个重复的 char 事件被丢掉。
    if KEY_CHAR[name] then ctx.dupChar = KEY_CHAR[name] end
    if name == "backspace" then
        backspaceChar(ctx)
    elseif name == "enter" or name == "return" or name == "keypadenter" or name == "keypad_enter" then
        finalizeLine(ctx)
    end
    -- 其余按键(方向/Delete/Tab...)留给后续; 本版忽略。
end

-- 键盘组合: Ctrl+Alt+1..0 切换前台 tty(Linux tty 切换)。修饰键状态经 key_down/key_up 跟踪。
local ctrlDown, altDown = false, false
local DIGIT_KEYS = { one = 1, two = 2, three = 3, four = 4, five = 5,
                     six = 6, seven = 7, eight = 8, nine = 9, zero = 0 }
local function isCtrl(name) return name == "leftCtrl" or name == "rightCtrl" end
local function isAlt(name) return name == "leftAlt" or name == "rightAlt" end

--- 调度器路由 key/key_up: 跟踪修饰键, 识别 Ctrl+Alt+数字切换焦点, 其余按键喂前台 tty。
function tty.routeKey(event)
    local ev = event[1]
    local key = event[2]
    local name = keys.getName(key)
    if not name then return end
    if isCtrl(name) then
        ctrlDown = (ev == "key")
        return
    elseif isAlt(name) then
        altDown = (ev == "key")
        return
    end
    -- 释放的普通键不再处理
    if ev ~= "key" then return end
    if ctrlDown and altDown then
        local n = DIGIT_KEYS[name]
        if n then
            local target = "tty" .. tostring(n - 1)
            if devices[target] then tty.setFocus(target) end
            return
        end
    end
    -- 控制字符: ctrl + c/d/z (无 alt) -> 信号 / EOF / 停止。其余 ctrl+键忽略(不入行)。
    if ctrlDown and not altDown then
        local ctx = focus and devices[focus]
        if name == "c" then
            if ctx then tty.ctrlC(ctx) end
            return
        elseif name == "z" then
            if ctx then tty.ctrlZ(ctx) end
            return
        elseif ctx and ctx.raw then
            -- 原始模式(cbreak)下 ISIG 仍然开着(^C/^Z 照旧是信号, 见上), 但 ICANON 关了:
            -- ^D/^L/^U/^W 这些是**普通字节**, 不再由行规程解释。Ctrl+A..Z = \1..\26。
            local b = name:match("^%a$") and (string.byte(name:lower()) - 96) or nil
            if b then
                local byte = string.char(b)
                rawPush(ctx, byte)
                ctx.dupChar = byte -- CC 多半还会补一个 char 事件, 丢掉它
            end
            return
        elseif name == "d" then
            if ctx then tty.ctrlD(ctx) end
            return
        else
            return
        end
    end
    -- **原始模式必须走 rawFeedKey**(与 tty.feedInput 的 key 分支同一套): 真实按键的 key 事件
    -- 是调度器经 routeKey 送进来的(见 scheduler.routeEvent), 而规范模式的 feedKey 会把
    -- Enter 当成"整行入队 + 去重闩锁"处理 —— 于是原始模式的行编辑器**永远收不到那个 \n**
    -- (Tab/方向键同理: 关键字节被去重闩锁吃掉, 或者干脆不产生字节)。
    -- 实测症状(真机, desh 行编辑器): 敲回车毫无反应、Tab 补全与方向键全失效, 只有 ^C(走
    -- 上面的 ctrl 分支, 那条本来就是 raw 感知的)有反应。宿主测试台直接喂 tty.feedInput,
    -- 走的是 raw 感知的那条路, 所以这个 bug 在宿主上一直看不出来。
    local ctx = focus and devices[focus]
    if ctx then
        if ctx.raw then rawFeedKey(ctx, key, event[3] or false) else feedKey(ctx, key, event[3] or false) end
    end
end

--- 调度器把键盘事件路由给前台 tty(canonical 行规程 / 原始模式字节流)。
---@param event table CC 事件表 {name, ...}
function tty.feedInput(event)
    local ctx = focus and devices[focus]
    if not ctx then return end
    local ev = event[1]
    if ev == "char" then
        -- Ctrl(+Alt) 组合(如 ^C/^D/^Z/tty 切换)期间抑制字符落屏。
        -- 原始模式下 Ctrl 组合是普通字节, 已由 routeKey 送进 keyBuf(见那里), 这里同样抑制。
        if ctrlDown then return end
        local ch = tostring(event[2] or "")
        -- 同一按键的重复事件(key 已处理过): 丢掉它, 否则会"删两个字符/出两个空行"。
        if ctx.dupChar then
            local dup = ctx.dupChar
            ctx.dupChar = nil
            if ch == dup then return end
        end
        feedChar(ctx, ch)
    elseif ev == "key" then
        if ctx.raw then rawFeedKey(ctx, event[2], event[3]) else feedKey(ctx, event[2], event[3]) end
    elseif ev == "paste" then
        local text = tostring(event[2] or "")
        if ctx.raw then rawPush(ctx, text) else for i = 1, #text do feedChar(ctx, text:sub(i, i)) end end
    end
end

--- 发送一个终端信号给前台会话(经 boot 注入的 tty.onSignal; 无则忽略)。
function tty.raiseSignal(sig)
    if tty.onSignal then tty.onSignal(sig) end
end

--- ^C: 发送 SIGINT 给 tty 前台进程组 + 取消当前行 + 回显 "^C"。
function tty.ctrlC(ctx)
    if ctx.echo then writeStr(ctx, "^C\n") end
    abortLine(ctx)
    tty.raiseSignal(signal.SIGINT)
end

--- ^D: POSIX canonical。行首(缓冲区空)=EOF; 行中有字符=冲刷部分行。
function tty.ctrlD(ctx)
    if #ctx.inputBuffer > 0 then
        flushLine(ctx)
    else
        ctx.eof = true
    end
end

--- ^Z: 发送 SIGTSTP 给 tty 前台进程组 + 取消当前行 + 回显 "^Z"。
function tty.ctrlZ(ctx)
    if ctx.echo then writeStr(ctx, "^Z\n") end
    abortLine(ctx)
    tty.raiseSignal(signal.SIGTSTP)
end

--- 设置前台 tty(接收键盘输入)。"console" 别名 => 第一个已注册 tty。
function tty.setFocus(name)
    if name == "console" then
        focus = nil
        for n in pairs(devices) do if not focus then focus = n end end
    elseif devices[name] then
        focus = name
    end
    return focus
end

function tty.getFocus()
    return focus
end

--- 原始模式下的 read(2): 阻塞到**至少有一个字节**, 返回至多 n 字节(n 缺省 1)。
--- 与 Linux 一致: 被信号打断返回 (nil, "interrupted"); 后台进程组读控制终端前先投 SIGTTIN。
--- ctx.reading 的记账与 readLine 完全一致 —— ^C(tty.ctrlC -> abortLine)只打断"正在阻塞读"
--- 的 ctx; 原始模式不记账的话, 装了 SIGINT 处理器的行编辑器(desh)在 ^C 之后会一直阻塞到
--- 用户再按一个键才醒过来(信号处理器已经接管, 进程不会被默认动作杀掉)。
local function rawRead(ctx, n)
    n = tonumber(n) or 1
    if n <= 0 then n = 1 end
    ctx.reading = true
    local function done(v, err)
        ctx.reading = false
        return v, err
    end
    while true do
        if ctx.closed then return done(nil, "device closed") end
        if tty.readGuard and tty.readGuard(ctx.name) then
            lock.pause(os.pullEvent) -- 投递 SIGTTIN 后阻塞(与 readLine 同一套)
        elseif #ctx.keyBuf > 0 then
            local take = math.min(n, #ctx.keyBuf)
            local out = ctx.keyBuf:sub(1, take)
            ctx.keyBuf = ctx.keyBuf:sub(take + 1)
            return done(out)
        elseif ctx.intr then
            ctx.intr = false
            return done(nil, "interrupted")
        elseif ctx.eof then
            ctx.eof = false
            return done(nil)
        else
            lock.pause(os.pullEvent)
        end
    end
end

--- 原始模式下的 readLine: 一直读到换行(回车也收, 与 canonical 一样对 \r 与 \n 一视同仁)。
--- 无回显 —— 行编辑(退格等)由调用者自己负责。
local function rawReadLine(ctx)
    local buf = {}
    while true do
        local b, err = rawRead(ctx, 1)
        if b == nil then
            if err then return nil, err end
            if #buf == 0 then return nil end
            return table.concat(buf)
        end
        if b == "\n" or b == "\r" then return table.concat(buf) end
        buf[#buf + 1] = b
    end
end

--- 打开句柄(绑定共享 ctx)。
local function openHandle(ctx, mode)
    local handle = {
        isTTY = true,
        write = function(self, s)
            if ctx.closed then return nil, "device closed" end
            s = tostring(s or "")
            for i = 1, #s do feedByte(ctx, s:sub(i, i)) end
            flushDirty(ctx)
            return #s
        end,
        writeLine = function(self, s)
            if ctx.closed then return nil, "device closed" end
            self:write((s == nil or s == "") and "" or tostring(s))
            self:write("\n")
            return (s and #s or 0) + 1
        end,
        clear = function(self, color)
            if ctx.closed then return nil, "device closed" end
            ctx.bg = color or ctx.bg
            eraseScreen(ctx)
            ctx.cursorX, ctx.cursorY = 0, 0
            updateCursor(ctx)
            flushDirty(ctx) -- 清屏后立即在 (0,0) 显示光标
            return true
        end,
        setCursor = function(self, x, y)
            if ctx.closed then return nil, "device closed" end
            ctx.cursorX = math.max(0, math.min(ctx.cols - 1, math.floor(x or 0)))
            ctx.cursorY = math.max(0, math.min(ctx.rows - 1, math.floor(y or 0)))
            updateCursor(ctx)
            flushDirty(ctx) -- 光标跳到新位置
            return true
        end,
        setTextColor = function(self, c) ctx.fg = c; return true end,
        setBackgroundColor = function(self, c) ctx.bg = c; return true end,
        -- 回显开关: login 密码输入时置 false(不显示 + 回车仅换行)。
        setEcho = function(self, enable) ctx.echo = (enable ~= false); return true end,
        getCursor = function() return ctx.cursorX, ctx.cursorY end,
        getSize = function() return ctx.cols, ctx.rows end,
        getDeviceName = function() return ctx.name end,
        flush = function() flushDirty(ctx); return true end,
        -- 字符设备: 打开多个句柄共享同一 ctx, close 不真正关闭设备(可重开)。
        close = function() return true end,
    }

    --- 阻塞读取一整行。调度器把键盘事件喂进 ctx.lineQueue; 这里轮询队列。
    --- 也消费 ^D(EOF) 与 ^C/^Z(中断) 标志。
    --- **^C 返回 ("", "intr") 而不是单纯的 ""**: 空行与"被 ^C 取消的行"在交互式 shell 里
    --- 是两件事 —— 取消要把**整条输入**(含 PS2 续行里已经读进去的那些行)都作废, 空行只结束
    --- 当前这一行。第二个返回值就是给 shell 的判断依据(bash/dash/zsh 同此)。
    --- 后台进程组读控制终端: 经 readGuard 投 SIGTTIN 后阻塞(被 SIGCONT/`fg` 恢复后重查)。
    handle.readLine = function()
        if ctx.closed then return nil, "device closed" end
        if ctx.raw then return rawReadLine(ctx) end
        ctx.reading = true
        while true do
            if tty.readGuard and tty.readGuard(ctx.name) then
                lock.pause(os.pullEvent) -- 投递 SIGTTIN 后让出: 调度器会停止本进程直到 SIGCONT
            elseif ctx.eof then
                ctx.eof = false
                ctx.reading = false
                return nil
            elseif ctx.intr then
                ctx.intr = false
                ctx.inputBuffer = ""
                ctx.reading = false
                return "", "intr"
            elseif #ctx.lineQueue > 0 then
                local line = table.remove(ctx.lineQueue, 1)
                ctx.inputBuffer = ""
                ctx.reading = false
                return line
            else
                -- 阻塞进程直到有事件; feedInput 已处理缓冲+回显。忽略非键盘事件。
                -- **放锁再等**(lock.pause): 持着内核锁阻塞会把锁焊死 —— 所有进程(包括读键盘的
                -- 那个)都进不了内核。见 kernel/lock.lua 的文件头。
                lock.pause(os.pullEvent)
            end
        end
    end

    --- 通用 read: 默认给一整行。
    handle.read = function(self, n)
        if ctx.closed then return nil, "device closed" end
        if ctx.raw then return rawRead(ctx, n) end
        return handle.readLine()
    end

    --- 原始模式开关(Linux termios 的 ICANON|ECHO 位): 开 = 不回显、不缓冲成行,
    --- 读到的是一段**终端字节流**(特殊键是 ANSI 序列, 见 KEY_SEQ)。ISIG 保持打开,
    --- 因此 ^C/^Z 照旧变成信号。分页器(more/less)靠它做"按一下键就走一步"。
    handle.setRaw = function(self, enable)
        if ctx.closed then return nil, "device closed" end
        enable = (enable ~= false)
        if enable == ctx.raw then return true end
        if enable then
            ctx.rawEcho = ctx.echo
            ctx.raw = true
            ctx.echo = false
            ctx.inputBuffer = "" -- 行规程缓冲里那半截输入作废(不再有"整行"这个概念)
            ctx.keyBuf = ""
            ctx.dupChar = nil
        else
            ctx.raw = false
            ctx.echo = ctx.rawEcho
            ctx.keyBuf = ""
            ctx.dupChar = nil
        end
        return true
    end
    handle.isRaw = function() return ctx.raw end

    -- 句柄交给进程用: 每个方法都进内核临界区(抢占式调度, 见 kernel/lock.lua)。
    return lock.wrapTable(handle)
end

--- 注册一个 /dev/ttyN 设备。
---@param dev table ScreenDevice
---@return string ttyName, table vfsHandler
function tty.registerDevice(dev)
    local name = "tty" .. nextIndex
    nextIndex = nextIndex + 1
    local ctx = newCtx(dev)
    ctx.name = name
    devices[name] = ctx
    if not focus then focus = name end -- 第一个 tty 成为默认前台
    local handler = {
        writable = true,
        open = function(mode) return openHandle(ctx, mode) end,
        getCtx = function() return ctx end,
    }
    return name, handler
end

function tty.get(name)
    return devices[name]
end

--- 打开某个 tty 的句柄(供别名设备, 如 /dev/console -> 控制台 tty)。
---@param name string
---@param mode string|nil
---@return table|nil handle, string|nil err
function tty.open(name, mode)
    local ctx = devices[name]
    if not ctx then return nil, "no such tty: " .. tostring(name) end
    return openHandle(ctx, mode)
end

function tty.list()
    local out = {}
    for n in pairs(devices) do out[#out + 1] = n end
    table.sort(out)
    return out
end

--- 热重算: 设备尺寸改变后按新 getSize() 重建网格(保留重叠内容), 全部重画。
function tty.resize(name)
    local ctx = devices[name]
    if not ctx then return end
    local dev = ctx.dev
    local w, h = dev.getSize()
    local cols, rows
    if dev.mode == "term" then
        cols = math.floor(w)
        rows = math.floor(h)
    else
        local cw = dev.cellW
        local ch = dev.cellH
        cols = math.floor(w / cw)
        rows = math.floor(h / ch)
    end
    local oldCols, oldRows = ctx.cols, ctx.rows
    local newGrid = {}
    for i = 1, cols * rows do newGrid[i] = { ch = " ", fg = DEFAULT_FG, bg = DEFAULT_BG } end
    for r = 0, math.min(rows, oldRows) - 1 do
        for c = 0, math.min(cols, oldCols) - 1 do
            newGrid[r * cols + c + 1] = ctx.grid[r * oldCols + c + 1]
        end
    end
    ctx.grid = newGrid
    ctx.cols, ctx.rows = cols, rows
    if ctx.cursorX >= cols then ctx.cursorX = cols - 1 end
    if ctx.cursorY >= rows then ctx.cursorY = rows - 1 end
    -- 全部重画到新分辨率布局
    ctx.dirty = {}
    ctx.dirtyList = {}
    ctx.cursorRenderedIdx = nil
    updateCursor(ctx)
    for i = 1, cols * rows do markCell(ctx, i) end
    flushDirty(ctx)
    return true
end

--- 光标闪烁 tick: 翻转所有 tty 光标显隐并重画(由内核调度器周期驱动)。
function tty.blinkTick()
    for _, ctx in pairs(devices) do
        if not ctx.closed then
            ctx.cursorOn = not ctx.cursorOn
            updateCursor(ctx)
            flushDirty(ctx)
        end
    end
end

return tty
