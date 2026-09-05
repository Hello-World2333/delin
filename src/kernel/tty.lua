--[[ Delin 字符终端设备(/dev/ttyN)。
     内建文本缓冲(字符×前景/背景色) + 光标 + 换行 + 滚动 + 清屏。
     write(s) 在当前光标处绘制并推进; flush() 把脏单元格推到 ScreenDevice。
     term 型设备(CC monitor)按原生单元格绘制; pixel 型设备(Tom/Void)按
     像素字格(cellW×cellH)绘制, 颜色码(0-15)先换算成 ARGB 再下发。

     键盘输入: 每个 tty 维护前台焦点(focus)。调度器把 CC 的 char/key/paste
     事件经 tty.feedInput 路由给焦点 tty, 由它做行缓冲 + 回显(经典 canonical
     行规程); 句柄的 readLine()/read() 阻塞调用进程直到拿到一整行。 ]]

local tty = {}

local nextIndex = 0
local devices = {} -- "ttyN" -> console ctx
local focus = nil  -- 前台 tty 名(接收键盘输入)

-- CC 终端 16 色 -> ARGB(0xAARRGGBB)。索引为 blit 十六进制码 0-f。
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

local DEFAULT_FG, DEFAULT_BG = 0xf, 0x0

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
    return ctx
end

--- 标记单元格(flat index)为脏。
local function markCell(ctx, idx)
    if not ctx.dirty[idx] then
        ctx.dirty[idx] = true
        ctx.dirtyList[#ctx.dirtyList + 1] = idx
    end
end

local function scroll(ctx)
    -- 所有行上移一格, 末行清空, 全部重画
    for row = 0, ctx.rows - 2 do
        for col = 0, ctx.cols - 1 do
            ctx.grid[row * ctx.cols + col + 1] = ctx.grid[(row + 1) * ctx.cols + col + 1]
        end
    end
    for col = 0, ctx.cols - 1 do
        ctx.grid[(ctx.rows - 1) * ctx.cols + col + 1] = { ch = " ", fg = ctx.fg, bg = ctx.bg }
    end
    for i = 1, ctx.rows * ctx.cols do markCell(ctx, i) end
end

local function putChar(ctx, ch)
    if ch == "\n" then
        ctx.cursorY = ctx.cursorY + 1
        ctx.cursorX = 0
    elseif ch == "\r" then
        ctx.cursorX = 0
        return
    elseif ch == "\b" then
        if ctx.cursorX > 0 then ctx.cursorX = ctx.cursorX - 1 end
        return
    elseif ch == "\t" then
        -- 前进到下一 tab 停靠点(8)
        ctx.cursorX = math.floor(ctx.cursorX / 8 + 1) * 8
    else
        local idx = ctx.cursorY * ctx.cols + ctx.cursorX + 1
        if idx <= ctx.rows * ctx.cols then
            ctx.grid[idx] = { ch = ch, fg = ctx.fg, bg = ctx.bg }
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
end

--- 绘制脏单元格到设备。
local function flushDirty(ctx)
    local dev = ctx.dev
    for _, idx in ipairs(ctx.dirtyList) do
        local cell = ctx.grid[idx]
        local col = (idx - 1) % ctx.cols
        local row = math.floor((idx - 1) / ctx.cols)
        if ctx.mode == "term" then
            dev.text(col, row, cell.ch, cell.fg, cell.bg)
        else
            -- pixel 型: 字符在自己的字格里水平居中(字体是比例字体, 左对齐会窄字贴边/字距怪异)
            local x = col * ctx.cellW
            if dev.getTextWidth then
                local cw = dev.getTextWidth(cell.ch)
                local off = math.floor((ctx.cellW - cw) / 2)
                if off > 0 then x = x + off end
            end
            dev.text(x, row * ctx.cellH, cell.ch,
                PALETTE[cell.fg], PALETTE[cell.bg])
        end
    end
    ctx.dirty = {}
    ctx.dirtyList = {}
    dev.flush()
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

--- 喂一个字符(可打印 / 换行 / 退格)。无回显(echo=false)时缓冲但不绘制。
local function feedChar(ctx, ch)
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
    if isHeld then return end
    local name = keys.getName(keycode)
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
    local ctx = focus and devices[focus]
    if ctx then feedKey(ctx, key, event[3] or false) end
end

--- 调度器把键盘事件路由给前台 tty(canonical 行规程)。
---@param event table CC 事件表 {name, ...}
function tty.feedInput(event)
    local ctx = focus and devices[focus]
    if not ctx then return end
    local ev = event[1]
    if ev == "char" then
        -- Ctrl+Alt 组合(如 tty 切换)期间抑制字符落屏
        if ctrlDown and altDown then return end
        feedChar(ctx, tostring(event[2] or ""))
    elseif ev == "key" then
        feedKey(ctx, event[2], event[3])
    elseif ev == "paste" then
        local text = tostring(event[2] or "")
        for i = 1, #text do feedChar(ctx, text:sub(i, i)) end
    end
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

--- 打开句柄(绑定共享 ctx)。
local function openHandle(ctx, mode)
    local handle = {
        isTTY = true,
        write = function(self, s)
            if ctx.closed then return nil, "device closed" end
            s = tostring(s or "")
            for i = 1, #s do putChar(ctx, s:sub(i, i)) end
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
            for i = 1, ctx.rows * ctx.cols do
                ctx.grid[i] = { ch = " ", fg = DEFAULT_FG, bg = ctx.bg }
            end
            -- 用设备填充整屏背景, 避免逐格重画(慢)
            if ctx.mode == "term" then
                ctx.dev.fill(ctx.bg)
            else
                ctx.dev.fill(PALETTE[ctx.bg])
            end
            ctx.dev.flush()
            ctx.cursorX, ctx.cursorY = 0, 0
            ctx.dirty = {}
            ctx.dirtyList = {}
            return true
        end,
        setCursor = function(self, x, y)
            if ctx.closed then return nil, "device closed" end
            ctx.cursorX = math.max(0, math.min(ctx.cols - 1, math.floor(x or 0)))
            ctx.cursorY = math.max(0, math.min(ctx.rows - 1, math.floor(y or 0)))
            return true
        end,
        setTextColor = function(self, c) ctx.fg = c; return true end,
        setBackgroundColor = function(self, c) ctx.bg = c; return true end,
        -- 回显开关: login 密码输入时置 false(不显示 + 回车仅换行)。
        setEcho = function(self, enable) ctx.echo = (enable ~= false); return true end,
        getCursor = function() return ctx.cursorX, ctx.cursorY end,
        getSize = function() return ctx.cols, ctx.rows end,
        flush = function() flushDirty(ctx); return true end,
        -- 字符设备: 打开多个句柄共享同一 ctx, close 不真正关闭设备(可重开)。
        close = function() return true end,
    }

    --- 阻塞读取一整行。调度器把键盘事件喂进 ctx.lineQueue; 这里轮询队列。
    handle.readLine = function()
        if ctx.closed then return nil, "device closed" end
        while true do
            if #ctx.lineQueue > 0 then
                local line = table.remove(ctx.lineQueue, 1)
                ctx.inputBuffer = ""
                return line
            end
            -- 阻塞进程直到有事件; feedInput 已处理缓冲+回显。忽略非键盘事件。
            os.pullEvent()
        end
    end

    --- 通用 read: 默认给一整行。
    handle.read = function()
        if ctx.closed then return nil, "device closed" end
        return handle.readLine()
    end

    return handle
end

--- 注册一个 /dev/ttyN 设备。
---@param dev table ScreenDevice
---@return string ttyName, table vfsHandler
function tty.registerDevice(dev)
    local name = "tty" .. nextIndex
    nextIndex = nextIndex + 1
    local ctx = newCtx(dev)
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

function tty.list()
    local out = {}
    for n in pairs(devices) do out[#out + 1] = n end
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
    for i = 1, cols * rows do markCell(ctx, i) end
    flushDirty(ctx)
    return true
end

return tty
