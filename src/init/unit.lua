--[[ Delin init unit file parser (systemd-style subset).
     Unit files are INI-style plain text:
       [Unit]     Description= After= Before= Requires= Wants= Conflicts=
       [Service]  Type=simple|oneshot  ExecStart=  Restart=  RestartSec=
                  TimeoutStartSec=  TimeoutStopSec=  RemainAfterExit=
       [Timer]    OnBootSec=  OnActiveSec=  OnUnitActiveSec=  Unit=
       [Mount]    What=  Where=  Type=  Options=
       [Install]  WantedBy=
     A value may hold several whitespace-separated unit names (After= a b); a key may repeat
     (equivalent to appending).
     %i / %I are the template instance name (getty@tty0.service instantiated from getty@.service).
     This module only parses/normalizes fields/substitutes templates; it holds no runtime state. ]]

local unit = {}

local KINDS = { service = true, target = true, timer = true, mount = true }

--- Unit name -> kind ("service"|"target"|"timer"|"mount"); nil when it is not a unit name.
---@param name string
---@return string|nil
function unit.kind(name)
    local suffix = name:match("%.([%a]+)$")
    if suffix and KINDS[suffix] then return suffix end
    return nil
end

--- Parse unit file text.
---@param text string
---@param name string unit name (used in error messages)
---@param instance string|nil template instance name (%i/%I)
---@return table|nil rec, string|nil err
function unit.parse(text, name, instance)
    if instance then
        -- %% -> sentinel, %i/%I -> instance, sentinel -> %
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

--- Last value of a key (single-valued keys).
---@return string|nil
function unit.get(rec, section, key)
    local sec = rec.sections[section]
    local vals = sec and sec[key]
    return vals and vals[#vals] or nil
end

--- All values of a key (whitespace-separated expansion; keys may repeat).
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

--- Raw string of a key (whitespace preserved, e.g. ExecStart).
function unit.raw(rec, section, key)
    return unit.get(rec, section, key)
end

--- Parse a systemd-style time: "10s" "5min" "1h" "2d" "500ms" or a plain number (seconds).
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

--- Parse an ExecStart-style command line (systemd subset: whitespace separated + single/double quotes).
---@param s string
---@return string[] argv  argv[1] is the program path
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
