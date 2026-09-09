-- Delin 真机探测: CC printer 外设原始 API 语义(供 ccprinter 驱动对照)。
-- 由 tools/realmachine.py --printer 注入为 oneshot 服务运行, 结果写 /var/log/printer_probe.log。
-- 只消耗一张纸: 全程在同一页上探测, 最后一次 endPage 打印并解锁打印机。
local lines = {}
local function say(s) lines[#lines + 1] = tostring(s) end

local function finish()
    local f = fs.open("/var/log/printer_probe.log", "w")
    for i = 1, #lines do f:writeLine(lines[i]) end
    f:close()
end

local function probe()
    -- 1) 找到 printer 外设
    local names = peripheral.getNames()
    say("peripherals=" .. table.concat(names, ","))
    local side
    for _, n in ipairs(names) do
        if peripheral.getType(n) == "printer" then side = n; break end
    end
    say("printer side=" .. tostring(side))
    if not side then return end

    local p = peripheral.wrap(side)

    -- 2) 方法清单(表本身 + 元表 __index)
    local seen, keys = {}, {}
    local function collect(t, tag)
        if type(t) ~= "table" then return end
        for k, v in pairs(t) do
            if type(k) == "string" and not seen[k] then
                seen[k] = true
                keys[#keys + 1] = k .. ":" .. type(v) .. "(" .. tag .. ")"
            end
        end
    end
    collect(p, "self")
    collect(getmetatable(p) and getmetatable(p).__index, "meta")
    table.sort(keys)
    say("methods=" .. table.concat(keys, ","))

    -- 3) 只读状态
    local function call(label, fn, ...)
        local r = { pcall(fn, ...) }
        local okv = table.remove(r, 1)
        local parts = {}
        for i = 1, #r do parts[i] = tostring(r[i]) end
        say(label .. " = " .. (okv and "ok" or "ERR") .. ": " .. table.concat(parts, " | "))
        return okv, r
    end

    call("paper", p.getPaperLevel)
    call("ink", p.getInkLevel)
    call("getPageSize(before)", p.getPageSize)
    call("getCursorPos(before)", p.getCursorPos)

    -- 4) 开一页
    local okNew, rNew = call("newPage", p.newPage)
    if not okNew or rNew[1] ~= true then
        say("ABORT: cannot start a page")
        return
    end
    local _, rSize = call("getPageSize(page)", p.getPageSize)
    local w, h = tonumber(rSize[1]), tonumber(rSize[2])
    call("getCursorPos(page)", p.getCursorPos)
    call("setPageTitle", p.setPageTitle, "Delin probe")

    -- 5) write 语义
    call("write('AB')", p.write, "AB")
    call("getCursorPos(after AB)", p.getCursorPos)
    call("setCursorPos(1,1)", p.setCursorPos, 1, 1)
    call("write('A\\nB')", p.write, "A\nB")
    call("getCursorPos(after A\\nB)", p.getCursorPos)
    call("setCursorPos(1,1)", p.setCursorPos, 1, 1)
    call("write(w)", p.write, string.rep("X", w))
    call("getCursorPos(after w)", p.getCursorPos)
    call("setCursorPos(1,1)", p.setCursorPos, 1, 1)
    call("write(w+3)", p.write, string.rep("X", w + 3))
    call("getCursorPos(after w+3)", p.getCursorPos)
    call("setCursorPos(1,h)", p.setCursorPos, 1, h)
    call("write(w)@last", p.write, string.rep("Y", w))
    call("getCursorPos(after last row)", p.getCursorPos)
    call("setCursorPos(1,h+1)", p.setCursorPos, 1, h + 1)

    -- 6) 页内再 newPage
    call("newPage(while busy)", p.newPage)

    -- 7) 收尾
    call("endPage", p.endPage)
    call("getCursorPos(after endPage)", p.getCursorPos)
    call("getPageSize(after endPage)", p.getPageSize)
    call("paper(after)", p.getPaperLevel)
    call("ink(after)", p.getInkLevel)
end

local okAll, errAll = pcall(probe)
if not okAll then say("FATAL: " .. tostring(errAll)) end
finish()
return 0
