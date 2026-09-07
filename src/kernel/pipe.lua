--[[ Delin 内核管道 (POSIX pipe): 在两个进程间缓冲传递字节。
     每端是一个句柄(read 端 / write 端), 绑定同一个有界缓冲区。
     协作式阻塞: read/write 在缓冲空/满时经 os.sleep 让出进程(调度器驱动恢复),
     避免忙等也避免死锁——写满则让出(等读者腾空间), 读空则让出(等写者补数据)。
     EOF: write 端全部 close(或写端进程退出)后, read 端读完剩余数据返回 nil。
     broken pipe: 所有 read 端关闭后, write 返错, 防止生产端无限挂起。 ]]

local pipe = {}

local CAP = 16384 -- 管道缓冲上限(字节)

local function newBuf()
    return { data = "", writers = 0, readers = 0 }
end

--- 构造 write 端句柄(每创建一个句柄, writers+1)。
local function makeWriteEnd(buf)
    buf.writers = buf.writers + 1
    local closed = false
    local h = {
        pipe = true,
        write = function(_, s)
            if closed then return nil, "pipe closed" end
            s = tostring(s or "")
            local i, n = 1, #s
            while i <= n do
                -- 所有读端已关 => 写端得到 SIGPIPE(此处返错, 让写进程退出)。
                if buf.readers == 0 then return nil, "broken pipe" end
                local space = CAP - #buf.data
                if space <= 0 then
                    os.sleep(0.05) -- 缓冲已满: 让出, 等读者腾空间。
                else
                    local chunk = s:sub(i, i + space - 1)
                    buf.data = buf.data .. chunk
                    i = i + #chunk
                end
            end
            return n
        end,
        flush = function() return true end,
        close = function()
            if not closed then closed = true; buf.writers = buf.writers - 1 end
            return true
        end,
    }
    return h
end

--- 构造 read 端句柄(每创建一个句柄, readers+1)。
local function makeReadEnd(buf)
    buf.readers = buf.readers + 1
    local closed = false
    local h -- 先声明, 使表内各函数能作为 upvalue 捕获自身(否则 h 在初始化期未入作用域, 会当作全局)。
    h = {
        pipe = true,
        readLine = function()
            if closed then return nil end
            while true do
                local nl = buf.data:find("\n", 1, true)
                if nl then
                    local line = buf.data:sub(1, nl - 1)
                    buf.data = buf.data:sub(nl + 1)
                    return line
                end
                if buf.writers == 0 then
                    -- EOF: 缓冲剩余部分作为最后一行返回(可能无换行)。
                    if #buf.data > 0 then local rest = buf.data; buf.data = ""; return rest end
                    return nil
                end
                os.sleep(0.05) -- 缓冲无新行且写端仍开: 让出, 等更多数据或 EOF。
            end
        end,
        read = function(_, fmt)
            if closed then return nil end
            if fmt == nil or fmt == "*l" then return h.readLine() end
            if fmt == "a" then return h.readAll() end
            local n = tonumber(fmt) or 0
            if n <= 0 then return "" end
            while #buf.data == 0 do
                if buf.writers == 0 then return nil end
                os.sleep(0.05)
            end
            local chunk = buf.data:sub(1, n)
            buf.data = buf.data:sub(n + 1)
            return chunk
        end,
        readAll = function()
            if closed then return nil end
            local acc = {}
            while true do
                if #buf.data > 0 then acc[#acc + 1] = buf.data; buf.data = "" end
                if buf.writers == 0 then break end
                os.sleep(0.05)
            end
            local all = table.concat(acc)
            return all ~= "" and all or nil
        end,
        close = function()
            if not closed then closed = true; buf.readers = buf.readers - 1 end
            return true
        end,
    }
    return h
end

--- 创建一个管道, 返回 read 端与 write 端。
---@return table readEnd, table writeEnd
function pipe.create()
    local buf = newBuf()
    return makeReadEnd(buf), makeWriteEnd(buf)
end

return pipe
