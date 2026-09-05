--[[ Delin 字符终端设备(/dev/ttyN)。
     内建文本缓冲(字符×前景/背景色) + 光标 + 换行 + 滚动 + 清屏。
     write(s) 在当前光标处绘制并推进; flush() 把脏单元格推到 ScreenDevice。
     term 型设备(CC monitor)按原生单元格绘制; pixel 型设备(Tom/Void)按
     像素字格(cellW×cellH)绘制, 颜色码(0-15)先换算成 ARGB 再下发。 ]]

local tty = {}

local nextIndex = 0
local devices = {} -- "ttyN" -> console ctx

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
        ctx = { dev = dev, mode = "term", cols = math.max(1, math.floor(w or 1)), rows = math.max(1, math.floor(h or 1)), cellW = 1, cellH = 1 }
    else
        local cw = dev.cellW or 6
        local ch = dev.cellH or 8
        ctx = {
            dev = dev, mode = "pixel",
            cols = math.max(1, math.floor((w or 1) / cw)),
            rows = math.max(1, math.floor((h or 1) / ch)),
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
            pcall(dev.text, col, row, cell.ch, cell.fg, cell.bg)
        else
            pcall(dev.text, col * ctx.cellW, row * ctx.cellH, cell.ch,
                PALETTE[cell.fg] or 0xFFFFFF, PALETTE[cell.bg] or 0x000000)
        end
    end
    ctx.dirty = {}
    ctx.dirtyList = {}
    if dev.flush then pcall(dev.flush) end
end

--- 打开句柄(绑定共享 ctx)。
local function openHandle(ctx, mode)
    return {
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
                if ctx.dev.fill then pcall(ctx.dev.fill, ctx.bg) end
            else
                if ctx.dev.fill then pcall(ctx.dev.fill, PALETTE[ctx.bg] or 0x000000) end
            end
            if ctx.dev.flush then pcall(ctx.dev.flush) end
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
        setTextColor = function(self, c) ctx.fg = c or ctx.fg; return true end,
        setBackgroundColor = function(self, c) ctx.bg = c or ctx.bg; return true end,
        getCursor = function() return ctx.cursorX, ctx.cursorY end,
        getSize = function() return ctx.cols, ctx.rows end,
        flush = function() flushDirty(ctx); return true end,
        close = function() ctx.closed = true; return true end,
    }
end

--- 注册一个 /dev/ttyN 设备。
---@param dev table ScreenDevice
---@return string ttyName, table vfsHandler
function tty.registerDevice(dev)
    local name = "tty" .. nextIndex
    nextIndex = nextIndex + 1
    local ctx = newCtx(dev)
    devices[name] = ctx
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

return tty
