--[[ Delin 用户库.  Linux 风格:
     /etc/passwd  name:x:uid:gid:fullname:home:shell
     /etc/shadow  name:salt$hash        (盐+哈希)
     /etc/group   name:x:gid:member1,member2
     哈希 = 盐+密码 的 32 位滚动哈希(CC 5.2 无位运算, 用乘加). ]]

local user = {}

local modules = require("kernel.modules")

local function trim(v) return (v:match("^%s*(.-)%s*$")) end

-- 盐 + 密码 -> 哈希(hex)。用 djb2(乘数 33, 乘积 < 2^53, 在双精度下确定)。
function user.hash(salt, pw)
    local s = salt .. pw
    local h = 5381
    for i = 1, #s do
        h = ((h * 33) + s:byte(i)) % 0x100000000
    end
    return string.format("%x", h)
end

function user.makeSalt(len)
    len = len or 8
    local c = "abcdefghijklmnopqrstuvwxyz0123456789"
    local out = {}
    for i = 1, len do
        local r = math.random(#c)
        out[i] = c:sub(r, r)
    end
    return table.concat(out)
end

--- 解析 passwd/shadow/group 文本。
---@param passwd string
---@param shadow string
---@param group string
---@return table db { users = { [name]={name,uid,gid,home,shell,salt,hash} }, groups={ [name]={gid,members} } }
function user.parse(passwd, shadow, group)
    local db = { users = {}, groups = {} }

    for line in (passwd or ""):gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local name, x, uid, gid, full, home, shell = line:match("^([^:]+):([^:]*):([^:]+):([^:]+):([^:]*):([^:]*):([^:]*)$")
            if name then
                db.users[name] = { name = name, uid = tonumber(uid), gid = tonumber(gid), home = home or "/home/" .. name, shell = shell }
            end
        end
    end

    for line in (shadow or ""):gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local name, rest = line:match("^([^:]+):(.*)$")
            local u = name and db.users[name]
            if u then
                local salt, h = rest:match("^([^$]+)%$(%x+)$")
                if salt then u.salt = salt; u.hash = h end
            end
        end
    end

    for line in (group or ""):gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local gname, x, gid, members = line:match("^([^:]+):([^:]*):([^:]+):(.*)$")
            if gname then db.groups[gname] = { gid = tonumber(gid), members = trim(members or "") } end
        end
    end

    return db
end

--- 校验密码。
function user.verify(db, name, password)
    local u = db.users[name]
    if not u or not u.hash then return false end
    return user.hash(u.salt, password) == u.hash
end

function user.get(db, name) return db.users and db.users[name] end

function user.byUid(db, uid)
    for _, u in pairs(db.users) do if u.uid == uid then return u end end
    return nil
end

function user.groupByName(db, name)
    return db.groups and db.groups[name]
end

function user.list(db)
    local out = {}
    for name, u in pairs(db.users) do out[#out + 1] = name .. ":" .. u.uid end
    return out
end

--- 从 VFS 根读取 /etc/passwd,/etc/shadow,/etc/group 并解析。
function user.init(fsapi)
    local function read(p)
        local h = fsapi.open(p, "r")
        if not h then return "" end
        local c = h.readAll(); h.close()
        return c
    end
    return user.parse(read("/etc/passwd"), read("/etc/shadow"), read("/etc/group"))
end

--- 注册 user.* syscalls(供进程调用)。
function user.registerSyscalls(db)
    local s = modules.syscalls()
    s["user.verify"] = function(name, pw) return user.verify(db, name, pw) end
    s["user.get"] = function(name) return user.get(db, name) end
    s["user.list"] = function() return user.list(db) end
    s["user.byUid"] = function(uid) return user.byUid(db, uid) end
    s["user.groupByName"] = function(name) return user.groupByName(db, name) end
end

return user
