--[[ Delin 软件帧缓冲设备(/dev/fbN)。
     统一 32 位 ARGB(0xAARRGGBB)像素缓冲; write() 写字节流(4 字节/像素),
     read() 读回, clear() 填充, setPixel() 点写, flush() 把脏矩形推到
     ScreenDevice 的像素层。像素格式跨设备统一, 由驱动负责 ARGB->设备原生色。 ]]

local fb = {}

local nextIndex = 0
local devices = {} -- "fbN" -> ctx (每显示设备一份, 多开共享)

local DEFAULT_BG = 0x000000 -- 透明/黑

--- 组装字节(小端像素: A R G B -> 0xAARRGGBB) -> ARGB 数。
local function bytesToArgb(a, r, g, b)
    return a * 16777216 + r * 65536 + g * 256 + b
end

--- ARGB 数 -> 4 个字节(A R G B)。
local function argbToBytes(c)
    local a = math.floor(c / 16777216) % 256
    local r = math.floor(c / 65536) % 256
    local g = math.floor(c / 256) % 256
    local b = c % 256
    return string.char(a, r, g, b)
end

local function setDirty(ctx, x, y)
    if not ctx.hasDirty then
        ctx.dirtyX0, ctx.dirtyY0, ctx.dirtyX1, ctx.dirtyY1 = x, y, x, y
        ctx.hasDirty = true
    else
        if x < ctx.dirtyX0 then ctx.dirtyX0 = x end
        if y < ctx.dirtyY0 then ctx.dirtyY0 = y end
        if x > ctx.dirtyX1 then ctx.dirtyX1 = x end
        if y > ctx.dirtyY1 then ctx.dirtyY1 = y end
    end
end

--- 构造一个帧缓冲上下文。
---@param dev table ScreenDevice (getSize 返回像素宽高; 有 setPixel/fill/rect/flush)
local function newCtx(dev)
    local w, h = dev.getSize()
    w = math.floor(w)
    h = math.floor(h)
    local n = w * h
    local px = {}
    for i = 1, n do px[i] = DEFAULT_BG end
    local ctx = {
        dev = dev, w = w, h = h, px = px,
        pos = 0,          -- 字节写游标
        hasDirty = false,
        dirtyX0, dirtyY0, dirtyX1, dirtyY1 = 0, 0, 0, 0,
        closed = false,
    }
    return ctx
end

--- 把脏矩形推到 ScreenDevice 像素层(供句柄 flush 与 resize 复用)。
local function doFlush(ctx)
    if ctx.closed or not ctx.hasDirty then return true end
    local x0, y0 = ctx.dirtyX0, ctx.dirtyY0
    local x1, y1 = ctx.dirtyX1, ctx.dirtyY1
    ctx.hasDirty = false
    -- 脏矩形重画(像素逐个写; 量小即可, 避免整屏刷屏)
    for y = y0, y1 do
        for x = x0, x1 do
            local c = ctx.px[y * ctx.w + x + 1]
            if c ~= DEFAULT_BG then
                ctx.dev.setPixel(x, y, c)
            end
        end
    end
    ctx.dev.flush()
    return true
end

--- 打开一个句柄(绑定到共享 ctx)。pos 为像素游标(0..w*h-1), write/read 以 4 字节像素为单位。
local function openHandle(ctx, mode)
    return {
        write = function(self, data)
            if ctx.closed then return nil, "device closed" end
            if type(data) ~= "string" then return nil, "expected string" end
            local i = 1
            local count = math.floor(#data / 4)
            for p = 0, count - 1 do
                local a, r, g, b = data:byte(i, i + 3)
                local x = ctx.pos % ctx.w
                local y = math.floor(ctx.pos / ctx.w)
                if y < ctx.h then
                    ctx.px[y * ctx.w + x + 1] = bytesToArgb(a, r, g, b)
                    setDirty(ctx, x, y)
                end
                ctx.pos = (ctx.pos + 1) % (ctx.w * ctx.h)
                i = i + 4
            end
            return #data
        end,
        read = function(self, n)
            if ctx.closed then return nil, "device closed" end
            n = n or (ctx.w * ctx.h * 4)
            local pixels = math.floor(n / 4)
            local out = {}
            for k = 0, pixels - 1 do
                local p = (ctx.pos + k) % (ctx.w * ctx.h)
                local x = p % ctx.w
                local y = math.floor(p / ctx.w)
                out[#out + 1] = argbToBytes(ctx.px[y * ctx.w + x + 1])
            end
            ctx.pos = (ctx.pos + pixels) % (ctx.w * ctx.h)
            return table.concat(out)
        end,
        seek = function(self, offset)
            local bytes = offset or 0
            ctx.pos = math.floor(bytes / 4) % (ctx.w * ctx.h)
            return ctx.pos
        end,
        clear = function(self, color)
            if ctx.closed then return nil, "device closed" end
            for x = 0, ctx.w - 1 do for y = 0, ctx.h - 1 do ctx.px[y * ctx.w + x + 1] = color end end
            ctx.hasDirty = true
            ctx.dirtyX0, ctx.dirtyY0, ctx.dirtyX1, ctx.dirtyY1 = 0, 0, ctx.w - 1, ctx.h - 1
            return true
        end,
        setPixel = function(self, x, y, color)
            if ctx.closed then return nil, "device closed" end
            x, y = math.floor(x or 0), math.floor(y or 0)
            if x < 0 or y < 0 or x >= ctx.w or y >= ctx.h then return nil, "out of range" end
            ctx.px[y * ctx.w + x + 1] = color
            setDirty(ctx, x, y)
            return true
        end,
        getSize = function() return ctx.w, ctx.h end,
        getBpp  = function() return 32 end, -- ARGB
        getPixel = function(self, x, y)
            if x < 0 or y < 0 or x >= ctx.w or y >= ctx.h then return nil end
            return ctx.px[y * ctx.w + x + 1]
        end,
        flush = function(self)
            if ctx.closed then return nil, "device closed" end
            return doFlush(ctx)
        end,
        close = function(self)
            ctx.closed = true
            return true
        end,
    }
end

--- 注册一个 /dev/fbN 设备并把句柄生产器放入 vfs 设备表。
---@param dev table ScreenDevice
---@return string fbName, table vfsHandler
function fb.registerDevice(dev)
    local name = "fb" .. nextIndex
    nextIndex = nextIndex + 1
    local ctx = newCtx(dev)
    devices[name] = ctx
    local handler = {
        writable = true,
        open = function(mode) return openHandle(ctx, mode) end,
        -- 供内核/调试查询
        getCtx = function() return ctx end,
    }
    return name, handler
end

--- 取一个 fb 上下文(内核/驱动用)。
function fb.get(name)
    return devices[name]
end

--- 列出 fb 设备名。
function fb.list()
    local out = {}
    for n in pairs(devices) do out[#out + 1] = n end
    return out
end

--- 热重算: 设备尺寸改变后按新 getSize() 重建像素缓冲(保留重叠像素), 标记全脏等待下次 flush。
function fb.resize(name)
    local ctx = devices[name]
    if not ctx then return end
    local w, h = ctx.dev.getSize()
    w = math.floor(w)
    h = math.floor(h)
    local oldW, oldH = ctx.w, ctx.h
    local newPx = {}
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            if x < oldW and y < oldH then
                newPx[y * w + x + 1] = ctx.px[y * oldW + x + 1]
            else
                newPx[y * w + x + 1] = DEFAULT_BG
            end
        end
    end
    ctx.px = newPx
    ctx.w, ctx.h = w, h
    ctx.pos = 0
    ctx.hasDirty = true
    ctx.dirtyX0, ctx.dirtyY0, ctx.dirtyX1, ctx.dirtyY1 = 0, 0, w - 1, h - 1
    return true
end

return fb
