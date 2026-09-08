--[[ Delin init 单元文件解析 (systemd 风格子集)。
     单元文件是 INI 风格纯文本:
       [Unit]     Description= After= Before= Requires= Wants= Conflicts=
       [Service]  Type=simple|oneshot  ExecStart=  Restart=  RestartSec=
                  TimeoutStartSec=  TimeoutStopSec=  RemainAfterExit=
       [Timer]    OnBootSec=  OnActiveSec=  OnUnitActiveSec=  Unit=
       [Mount]    What=  Where=  Type=  Options=
       [Install]  WantedBy=
     值里可以出现多个空白分隔的单元名(After= a b); 同一个键可重复(等价于追加)。
     %i / %I 为模板实例名(getty@tty0.service 从 getty@.service 实例化)。
     本模块只做解析/字段归一化/模板替换, 不含任何运行状态。 ]]

local unit = {}

local KINDS = { service = true, target = true, timer = true, mount = true }

--- 单元名 -> 类型("service"|"target"|"timer"|"mount"), 非单元名返回 nil。
---@param name string
---@return string|nil
function unit.kind(name)
    local suffix = name:match("%.([%a]+)$")
    if suffix and KINDS[suffix] then return suffix end
    return nil
end

--- 解析单元文件文本。
---@param text string
---@param name string 单元名(用于错误消息)
---@param instance string|nil 模板实例名(%i/%I)
---@return table|nil rec, string|nil err
function unit.parse(text, name, instance)
    if instance then
        -- %% -> 哨兵, %i/%I -> 实例, 哨兵 -> %
        text = text:gsub("%%%%", "\1"):gsub("%%i", instance):gsub("%%I", instance):gsub("\1", "%%")
    end
    local rec = { name = name, sections = {} }
    local section = nil
    local lineno = 0
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        local line = raw:gsub("[;#].*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local sec = line:match("^%[([^%]]+)%]$")
            if sec then
                section = sec
                rec.sections[section] = rec.sections[section] or {}
            elseif not section then
                return nil, string.format("%s:%d: key outside any section", name, lineno)
            else
                local k, v = line:match("^([%w_%-]+)%s*=%s*(.*)$")
                if not k then
                    return nil, string.format("%s:%d: not a Key=Value line: %s", name, lineno, line)
                end
                local secTab = rec.sections[section]
                secTab[k] = secTab[k] or {}
                secTab[k][#secTab[k] + 1] = v
            end
        end
    end
    return rec
end

--- 取某键的最后一个值(单值键)。
---@return string|nil
function unit.get(rec, section, key)
    local sec = rec.sections[section]
    local vals = sec and sec[key]
    return vals and vals[#vals] or nil
end

--- 取某键的全部值(空白分隔展开; 键可重复)。
---@return string[]
function unit.list(rec, section, key)
    local out = {}
    local sec = rec.sections[section]
    if sec and sec[key] then
        for _, v in ipairs(sec[key]) do
            for w in v:gmatch("%S+") do out[#out + 1] = w end
        end
    end
    return out
end

--- 取某键的原始字符串(保留空格, 如 ExecStart)。
function unit.raw(rec, section, key)
    return unit.get(rec, section, key)
end

--- 解析 systemd 风格时间: "10s" "5min" "1h" "2d" "500ms" 或纯数字(秒)。
---@param s string|nil
---@return number|nil seconds
function unit.time(s)
    if not s then return nil end
    s = s:gsub("%s+", "")
    local num, suffix = s:match("^([%d%.]+)(%a*)$")
    if not num then return nil end
    local n = tonumber(num)
    if not n then return nil end
    if suffix == "" or suffix == "s" or suffix == "sec" or suffix == "secs" or suffix == "second" or suffix == "seconds" then
        return n
    elseif suffix == "ms" or suffix == "msec" then
        return n / 1000
    elseif suffix == "min" or suffix == "mins" or suffix == "minute" or suffix == "minutes" then
        return n * 60
    elseif suffix == "h" or suffix == "hr" or suffix == "hour" or suffix == "hours" then
        return n * 3600
    elseif suffix == "d" or suffix == "day" or suffix == "days" then
        return n * 86400
    end
    return nil
end

--- 解析 ExecStart 风格命令行(systemd 子集: 空白分隔 + 单/双引号)。
---@param s string
---@return string[] argv  argv[1] 为程序路径
function unit.splitArgs(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c:match("%s") then
            i = i + 1
        else
            local buf = {}
            while i <= n do
                c = s:sub(i, i)
                if c == '"' then
                    i = i + 1
                    local close = s:find('"', i, true)
                    if not close then break end
                    buf[#buf + 1] = s:sub(i, close - 1)
                    i = close + 1
                elseif c == "'" then
                    i = i + 1
                    local close = s:find("'", i, true)
                    if not close then break end
                    buf[#buf + 1] = s:sub(i, close - 1)
                    i = close + 1
                elseif c == "\\" and i < n then
                    buf[#buf + 1] = s:sub(i + 1, i + 1)
                    i = i + 2
                elseif c:match("%s") then
                    break
                else
                    buf[#buf + 1] = c
                    i = i + 1
                end
            end
            out[#out + 1] = table.concat(buf)
        end
    end
    return out
end

return unit
