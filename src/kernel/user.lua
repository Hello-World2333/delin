--[[ Delin 用户库.  Linux 风格:
     /etc/passwd  name:x:uid:gid:fullname:home:shell
     /etc/shadow  name:salt$hash        (盐+哈希; 前置 '!' = 锁定)
     /etc/group   name:x:gid:member1,member2
     哈希 = 盐+密码 的 32 位滚动哈希(CC 5.2 无位运算, 用乘加).

     **唯一真源**: boot 时(两条引导路径都经 boot.setupUsers)把 /etc 三张表解析进内存 db,
     之后所有改动只走 user.* 写 syscall —— syscall 先按 POSIX 授权(见各函数的注释), 再改
     内存 db, 最后把**变化过的**那张表特权写回 /etc(等价 setuid passwd 的 euid 0)。
     工具(passwd/useradd/... )只是这套 syscall 的 CLI 外壳: 直接编辑 /etc 文件的改法在
     运行中的系统里看不见(login/ps/chown/ls 读的都是这份内存 db), 所以没有第二条路径。 ]]

local user = {}

local modules = require("kernel.modules")

-- 权限判定与特权写都要当前进程凭据; 不在内核 bundle 里(宿主测试台/DLUB)时视为 root。
local process = nil
pcall(function() process = require("kernel.process") end)
local function cred() if not process then return { uid = 0, gid = 0 } end return process.current() end

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

--- 名字会原样写进以 ':' 分隔的表里, 所以严格校验 —— 冒号/换行/空格会让文件结构破掉。
--- 与 Linux useradd 的 NAME_REGEX 一致: 字母或 '_' 开头, 其后字母/数字/'_'/'-'/'.'。
local function validName(n)
    return type(n) == "string" and n:match("^[%a_][%w_%-%.]*$") ~= nil
end

local function validId(v)
    return type(v) == "number" and v >= 0 and v == math.floor(v) and v <= 0xFFFFFFFF
end

--- 组的成员串 <-> 名单(成员按名排序, 保证写回的 /etc/group 稳定可复现)。
local function membersOf(g)
    local out = {}
    for m in (g.members or ""):gmatch("[^,]+") do
        m = trim(m)
        if m ~= "" then out[#out + 1] = m end
    end
    return out
end

local function setMembers(g, list)
    local seen, keep = {}, {}
    for _, m in ipairs(list) do
        if m ~= "" and not seen[m] then seen[m] = true; keep[#keep + 1] = m end
    end
    table.sort(keep)
    g.members = table.concat(keep, ",")
end

local function isMember(g, name)
    return ("," .. (g.members or "") .. ","):find("," .. name .. ",", 1, true) ~= nil
end

--- 解析 passwd/shadow/group 文本。
---@param passwd string
---@param shadow string
---@param group string
---@return table db { users = { [name]={name,uid,gid,full,home,shell,salt,hash,locked} },
---                    groups={ [name]={name,gid,members} },
---                    userOrder/groupOrder = 文件里的顺序(写回时保持原样),
---                    raw = { passwd=,shadow=,group= } 装载时的原文(只写变化过的表) }
function user.parse(passwd, shadow, group)
    local db = { users = {}, groups = {}, userOrder = {}, groupOrder = {},
                 raw = { passwd = passwd or "", shadow = shadow or "", group = group or "" } }

    for line in (passwd or ""):gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local name, x, uid, gid, full, home, shell = line:match("^([^:]+):([^:]*):([^:]+):([^:]+):([^:]*):([^:]*):([^:]*)$")
            if name then
                db.users[name] = { name = name, uid = tonumber(uid), gid = tonumber(gid), full = full or "",
                                   home = home or ("/home/" .. name), shell = shell }
                db.userOrder[#db.userOrder + 1] = name
            end
        end
    end

    for line in (shadow or ""):gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local name, rest = line:match("^([^:]+):(.*)$")
            local u = name and db.users[name]
            if u then
                -- 前置的 '!' 是 Linux 的锁定标记(passwd -l); 剥掉它再解析哈希。
                local bang, body = rest:match("^(!*)(.*)$")
                u.locked = bang ~= ""
                if body == "" then
                    -- 空密码字段 = 无密码登录(passwd -d)。必须与"shadow 里根本没这个人"
                    -- 区分开: 后者绝不能变成"空密码即可登录"(丢一个 shadow 文件就等于全放行)。
                    u.salt, u.hash, u.nopass = nil, nil, true
                else
                    local salt, h = body:match("^([^$]+)%$(%x+)$")
                    if salt then u.salt, u.hash = salt, h end
                end
            end
        end
    end

    for line in (group or ""):gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local gname, x, gid, members = line:match("^([^:]+):([^:]*):([^:]+):(.*)$")
            if gname then
                db.groups[gname] = { name = gname, gid = tonumber(gid), members = trim(members or "") }
                db.groupOrder[#db.groupOrder + 1] = gname
            end
        end
    end

    return db
end

--- 序列化回三张表的文本(Linux 格式, 与 user.parse 往返一致)。
---@return string passwd, string shadow, string group
function user.serialize(db)
    local pw, sh = {}, {}
    for _, n in ipairs(db.userOrder) do
        local u = db.users[n]
        if u then
            pw[#pw + 1] = string.format("%s:x:%d:%d:%s:%s:%s",
                n, u.uid, u.gid, u.full or "", u.home or "", u.shell or "")
            local secret = (u.salt and u.hash) and (u.salt .. "$" .. u.hash) or ""
            if u.locked then secret = "!" .. secret end
            sh[#sh + 1] = n .. ":" .. secret
        end
    end
    local gr = {}
    for _, n in ipairs(db.groupOrder) do
        local g = db.groups[n]
        if g then gr[#gr + 1] = string.format("%s:x:%d:%s", n, g.gid, g.members or "") end
    end
    return table.concat(pw, "\n") .. "\n", table.concat(sh, "\n") .. "\n", table.concat(gr, "\n") .. "\n"
end

--- 校验密码(锁定或无密码字段按 Linux 语义处理)。
function user.verify(db, name, password)
    local u = db.users[name]
    if not u or u.locked then return false end
    if u.nopass then return (password or "") == "" end -- passwd -d: 显式的空密码
    if not u.hash then return false end -- shadow 里没有这个人 -> 一律拒绝(不放行空密码)
    return user.hash(u.salt, password or "") == u.hash
end

--- 对外暴露的用户记录(不含盐/哈希: 哈希只在 verify/setPassword 内核侧使用, 不给任何进程读)。
local function publicUser(u)
    if not u then return nil end
    return { name = u.name, uid = u.uid, gid = u.gid, full = u.full or "",
             home = u.home, shell = u.shell, locked = u.locked or false }
end

function user.get(db, name) return publicUser(db.users[name]) end

function user.byUid(db, uid)
    for _, u in pairs(db.users) do if u.uid == uid then return publicUser(u) end end
    return nil
end

function user.groupByName(db, name)
    local g = db.groups and db.groups[name]
    if not g then return nil end
    return { name = g.name, gid = g.gid, members = g.members }
end

function user.groupByGid(db, gid)
    for _, g in pairs(db.groups or {}) do
        if g.gid == gid then return { name = g.name, gid = g.gid, members = g.members } end
    end
    return nil
end

--- 全部用户(按 uid 升序, 不含哈希)。
function user.list(db)
    local out = {}
    for _, n in ipairs(db.userOrder) do
        if db.users[n] then out[#out + 1] = publicUser(db.users[n]) end
    end
    table.sort(out, function(a, b) if a.uid == b.uid then return a.name < b.name end return a.uid < b.uid end)
    return out
end

--- 全部组(按 gid 升序)。
function user.groups(db)
    local out = {}
    for _, n in ipairs(db.groupOrder) do
        if db.groups[n] then out[#out + 1] = { name = n, gid = db.groups[n].gid, members = db.groups[n].members } end
    end
    table.sort(out, function(a, b) if a.gid == b.gid then return a.name < b.name end return a.gid < b.gid end)
    return out
end

--- 某用户所属的全部组名: 主组在前, 其余按 gid 升序(与 groups(1)/id(1) 的次序一致)。
function user.groupsOf(db, name)
    local u = db.users[name]
    if not u then return nil end
    local out = {}
    local primary = user.groupByGid(db, u.gid)
    if primary then out[#out + 1] = primary.name end
    local rest = {}
    for _, g in ipairs(user.groups(db)) do
        if (not primary or g.name ~= primary.name) and isMember(db.groups[g.name], name) then
            rest[#rest + 1] = g.name
        end
    end
    for _, n in ipairs(rest) do out[#out + 1] = n end
    return out
end

--- 密码状态: P = 可用, L = 已锁定, NP = 无密码(空密码登录)。
function user.passwordStatus(db, name)
    local u = db.users[name]
    if not u then return nil end
    if u.locked then return "L" end
    if u.nopass then return "NP" end -- 空密码字段(passwd -d) = 无密码登录
    if not u.hash then return "L" end -- shadow 里没有记录 = 登不进去, 与 locked 归一类
    return "P"
end

-- ---------------------------------------------------------------
-- 写接口(全部只经 syscall 调用; 授权在此判定, 落盘见 user.save)
-- ---------------------------------------------------------------

--- 授权辅助: 要求调用者是 root(uid 0)。
--- 错误文本不带工具名前缀 —— 前缀由工具自己加(passwd/useradd/...), 免得出现 "useradd: useradd:"。
local function rootOnly()
    if cred().uid ~= 0 then return nil, "permission denied" end
    return true
end

--- 某个 id 是否已被占用(uid 或 gid)。
local function idTaken(db, kind, id)
    if kind == "uid" then
        for _, u in pairs(db.users) do if u.uid == id then return u.name end end
    else
        for _, g in pairs(db.groups) do if g.gid == id then return g.name end end
    end
    return nil
end

--- 分配第一个空闲 id(从 1000 起, 与 Linux UID_MIN/GID_MIN 一致)。
local function nextId(db, kind)
    local id = 1000
    while idTaken(db, kind, id) do id = id + 1 end
    return id
end

--- 组名 -> gid(不存在则该组无效)。
local function gidOf(db, name)
    local g = db.groups[name]
    if not g then return nil end
    return g.gid
end

--- 改密码: root 可改任何人(忽略 oldpw); 本人必须给出正确的旧密码(POSIX passwd 语义)。
--- newpw == nil 表示删除密码(passwd -d, 空密码登录)—— 仅 root(shadow-utils 同)。
function user.setPassword(db, name, oldpw, newpw)
    local u = db.users[name]
    if not u then return nil, "user '" .. tostring(name) .. "' does not exist" end
    local c = cred()
    if newpw == nil then
        local ok, err = rootOnly(); if not ok then return nil, err end
    elseif c.uid ~= 0 then
        local me = user.byUid(db, c.uid)
        if not me or me.name ~= name then return nil, "permission denied" end
        if not user.verify(db, name, oldpw or "") then return nil, "incorrect old password" end
    end
    if newpw == nil then
        u.salt, u.hash, u.locked, u.nopass = nil, nil, false, true -- passwd -d: 空密码
    else
        u.salt = user.makeSalt()
        u.hash = user.hash(u.salt, newpw)
        u.locked, u.nopass = false, nil
    end
    return true
end

--- 锁定/解锁密码(passwd -l/-u; 仅 root: shadow-utils 同此)。
function user.setLocked(db, name, locked)
    local u = db.users[name]
    if not u then return nil, "user '" .. tostring(name) .. "' does not exist" end
    local ok, err = rootOnly(); if not ok then return nil, err end
    u.locked = locked and true or false
    return true
end

--- 建用户(useradd)。spec = { name, uid?, gid?, home?, shell?, full?, password?, groups? }:
---   uid 省略则取第一个空闲 uid(>=1000); gid 省略则用同名组(Linux USERGROUPS_ENAB:
---   组不存在就一并建出来); groups 是附加组名(必须都已存在); 不给 password 即锁定账号
---   (Linux useradd 建的账号在设密码前无法登录)。
--- 仅 root。
function user.addUser(db, spec)
    local ok, err = rootOnly(); if not ok then return nil, err end
    local name = spec.name
    if not validName(name) then return nil, "invalid user name '" .. tostring(name) .. "'" end
    if db.users[name] then return nil, "user '" .. name .. "' already exists" end

    local uid = spec.uid
    if uid ~= nil then
        if not validId(uid) then return nil, "invalid uid '" .. tostring(uid) .. "'" end
        local owner = idTaken(db, "uid", uid)
        if owner then return nil, "uid " .. uid .. " is already in use by '" .. owner .. "'" end
    else
        uid = nextId(db, "uid")
    end

    -- 先全部校验、再动 db: 中途失败时不能留下"建了一半"的组/用户/成员关系。
    for _, gname in ipairs(spec.groups or {}) do
        if not db.groups[gname] then return nil, "group '" .. gname .. "' does not exist" end
    end

    local gid = spec.gid
    if gid ~= nil then
        if not validId(gid) then return nil, "invalid gid '" .. tostring(gid) .. "'" end
        if not user.groupByGid(db, gid) then return nil, "group with gid " .. gid .. " does not exist" end
    elseif db.groups[name] then
        gid = db.groups[name].gid
    else
        gid = nextId(db, "gid")
    end
    if not spec.gid and not db.groups[name] then
        -- 同名私有组不存在 -> 建出来(Linux USERGROUPS_ENAB)
        db.groups[name] = { name = name, gid = gid, members = "" }
        db.groupOrder[#db.groupOrder + 1] = name
    end

    local u = { name = name, uid = uid, gid = gid, full = spec.full or "",
                home = spec.home or ("/home/" .. name), shell = spec.shell or "/bin/sh" }
    if spec.password then
        u.salt = user.makeSalt()
        u.hash = user.hash(u.salt, spec.password)
    else
        u.locked = true -- 建账号时不设密码 = 锁定(Linux useradd 同此)
    end
    db.users[name] = u
    db.userOrder[#db.userOrder + 1] = name

    for _, gname in ipairs(spec.groups or {}) do
        local g = db.groups[gname]
        local list = membersOf(g)
        list[#list + 1] = name
        setMembers(g, list)
    end
    return publicUser(u)
end

--- 删用户(userdel): 从 passwd/shadow 摘掉, 并从所有组的成员表里移除(与 Linux 一致)。
--- 返回被删的记录(工具拿它的 home 去删家目录)。仅 root。
function user.delUser(db, name)
    local u = db.users[name]
    if not u then return nil, "user '" .. tostring(name) .. "' does not exist" end
    local ok, err = rootOnly(); if not ok then return nil, err end
    local rec = publicUser(u)
    db.users[name] = nil
    for i, n in ipairs(db.userOrder) do
        if n == name then table.remove(db.userOrder, i) break end
    end
    -- 同名的用户私有组(addUser 建的那种)一并删掉, Linux userdel 亦如此。
    local g = db.groups[name]
    if g and g.gid == u.gid then
        db.groups[name] = nil
        for i, n in ipairs(db.groupOrder) do
            if n == name then table.remove(db.groupOrder, i) break end
        end
    end
    for _, gg in pairs(db.groups) do
        local list = membersOf(gg)
        local kept = {}
        for _, m in ipairs(list) do if m ~= name then kept[#kept + 1] = m end end
        if #kept ~= #list then setMembers(gg, kept) end
    end
    return rec
end

--- 改用户(usermod)。changes 里的字段给了才改:
---   name(改名) uid gid(主组) home shell full groups(附加组全量) groupsAdd groupsDel
---   locked(锁定/解锁)。仅 root。
function user.modUser(db, name, changes)
    local u = db.users[name]
    if not u then return nil, "user '" .. tostring(name) .. "' does not exist" end
    local ok, err = rootOnly(); if not ok then return nil, err end

    if changes.name ~= nil and changes.name ~= name then
        local new = changes.name
        if not validName(new) then return nil, "invalid user name '" .. tostring(new) .. "'" end
        if db.users[new] then return nil, "user '" .. new .. "' already exists" end
        db.users[new] = u
        db.users[name] = nil -- 旧名要摘掉, 否则改名后两个名字都能查到同一个用户
        u.name = new
        for i, n in ipairs(db.userOrder) do if n == name then db.userOrder[i] = new break end end
        -- 原名的用户私有组跟着改名(Linux usermod -l 不改组名, 但组的成员名要跟着换)。
        for _, gg in pairs(db.groups) do
            local list = membersOf(gg)
            local hit = false
            for i, m in ipairs(list) do if m == name then list[i] = new; hit = true end end
            if hit then setMembers(gg, list) end
        end
        name = new
    end

    if changes.uid ~= nil then
        if not validId(changes.uid) then return nil, "invalid uid '" .. tostring(changes.uid) .. "'" end
        local owner = idTaken(db, "uid", changes.uid)
        if owner and owner ~= name then return nil, "uid " .. changes.uid .. " is already in use by '" .. owner .. "'" end
        u.uid = changes.uid
    end
    if changes.gid ~= nil then
        if not validId(changes.gid) then return nil, "invalid gid '" .. tostring(changes.gid) .. "'" end
        if not user.groupByGid(db, changes.gid) then return nil, "group with gid " .. changes.gid .. " does not exist" end
        u.gid = changes.gid
    end
    if changes.home ~= nil then u.home = changes.home end
    if changes.shell ~= nil then u.shell = changes.shell end
    if changes.full ~= nil then u.full = changes.full end
    if changes.locked ~= nil then u.locked = changes.locked and true or false end

    local function checkGroups(list)
        for _, gname in ipairs(list or {}) do
            if not db.groups[gname] then return nil, "group '" .. gname .. "' does not exist" end
        end
        return true
    end
    local gok, gerr = checkGroups(changes.groups); if not gok then return nil, gerr end
    gok, gerr = checkGroups(changes.groupsAdd); if not gok then return nil, gerr end

    if changes.groups then
        -- 全量设置附加组(usermod -G): 先把该用户从所有组里摘掉, 再加回去。
        for _, gg in pairs(db.groups) do
            local list, kept = membersOf(gg), {}
            for _, m in ipairs(list) do if m ~= name then kept[#kept + 1] = m end end
            if #kept ~= #list then setMembers(gg, kept) end
        end
        for _, gname in ipairs(changes.groups) do
            local g = db.groups[gname]
            local list = membersOf(g); list[#list + 1] = name; setMembers(g, list)
        end
    end
    for _, gname in ipairs(changes.groupsAdd or {}) do
        local g = db.groups[gname]
        local list = membersOf(g); list[#list + 1] = name; setMembers(g, list)
    end
    for _, gname in ipairs(changes.groupsDel or {}) do
        local g = db.groups[gname]
        local list, kept = membersOf(g), {}
        for _, m in ipairs(list) do if m ~= name then kept[#kept + 1] = m end end
        setMembers(g, kept)
    end
    return publicUser(u)
end

--- 建组(groupadd): gid 省略则取第一个空闲 gid(>=1000)。仅 root。
function user.addGroup(db, name, gid)
    local ok, err = rootOnly(); if not ok then return nil, err end
    if not validName(name) then return nil, "invalid group name '" .. tostring(name) .. "'" end
    if db.groups[name] then return nil, "group '" .. name .. "' already exists" end
    if gid ~= nil then
        if not validId(gid) then return nil, "invalid gid '" .. tostring(gid) .. "'" end
        local owner = idTaken(db, "gid", gid)
        if owner then return nil, "gid " .. gid .. " is already in use by '" .. owner .. "'" end
    else
        gid = nextId(db, "gid")
    end
    db.groups[name] = { name = name, gid = gid, members = "" }
    db.groupOrder[#db.groupOrder + 1] = name
    return { name = name, gid = gid, members = "" }
end

--- 删组(groupdel)。仅 root。GNU groupdel 语义: 任一用户以它为主组就拒绝删除。
function user.delGroup(db, name)
    local g = db.groups[name]
    if not g then return nil, "group '" .. tostring(name) .. "' does not exist" end
    local ok, err = rootOnly(); if not ok then return nil, err end
    for _, u in pairs(db.users) do
        if u.gid == g.gid then
            return nil, "cannot remove the primary group of user '" .. u.name .. "'"
        end
    end
    db.groups[name] = nil
    for i, n in ipairs(db.groupOrder) do
        if n == name then table.remove(db.groupOrder, i) break end
    end
    return { name = name, gid = g.gid, members = g.members }
end

--- 把内存 db 里**变化过**的表写回 /etc。
--- 特权写: 授权已在各写接口里判过, 这里以 root 凭据落盘 —— 等价 setuid passwd(非 root
--- 用户改自己的密码也要能写 /etc/shadow, 而它的权限位是 0600 root:root)。
--- 没变的表不写: 免得非 root 的一次 passwd 顺手重写 /etc/passwd。
function user.save(db, fsapi)
    local passwd, shadow, group = user.serialize(db)
    local function write(path, text, raw)
        if text == raw then return true end
        local function doWrite()
            local h, err = fsapi.open(path, "w")
            if not h then return nil, path .. ": " .. tostring(err) end
            h:write(text)
            -- close 的约定不一: Delin 句柄返回 true/ nil,err, CC 原生句柄返回 nil —— 只有
            -- 带回错误的那种才算失败(ext2 的 commit 失败会给出 err)。
            local _, cerr = h:close()
            if cerr ~= nil then return nil, path .. ": " .. tostring(cerr) end
            return true
        end
        if process and process.asRoot then return process.asRoot(doWrite) end
        return doWrite()
    end
    local ok, err = write("/etc/passwd", passwd, db.raw.passwd); if not ok then return nil, err end
    ok, err = write("/etc/shadow", shadow, db.raw.shadow); if not ok then return nil, err end
    ok, err = write("/etc/group", group, db.raw.group); if not ok then return nil, err end
    db.raw.passwd, db.raw.shadow, db.raw.group = passwd, shadow, group
    return true
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

--- 注册 user.* syscalls(供进程调用)。写接口 = 授权 -> 改内存 db -> 特权写回 /etc;
--- 任一步失败即返回 nil, err(fail-fast, 不静默降级)。
function user.registerSyscalls(db, fsapi)
    local s = modules.syscalls()
    local function commit(fn)
        return function(...)
            local a, b = fn(...)
            if a == nil then return nil, b end
            local ok, err = user.save(db, fsapi)
            if not ok then return nil, err end
            return a, b
        end
    end

    s["user.verify"] = function(name, pw) return user.verify(db, name, pw) end
    s["user.get"] = function(name) return user.get(db, name) end
    s["user.list"] = function() return user.list(db) end
    s["user.groups"] = function() return user.groups(db) end
    s["user.groupsOf"] = function(name) return user.groupsOf(db, name) end
    s["user.passwordStatus"] = function(name) return user.passwordStatus(db, name) end
    s["user.byUid"] = function(uid) return user.byUid(db, uid) end
    s["user.groupByName"] = function(name) return user.groupByName(db, name) end
    s["user.groupByGid"] = function(gid) return user.groupByGid(db, gid) end

    s["user.setPassword"] = commit(function(name, oldpw, newpw) return user.setPassword(db, name, oldpw, newpw) end)
    s["user.setLocked"] = commit(function(name, locked) return user.setLocked(db, name, locked) end)
    s["user.addUser"] = commit(function(spec) return user.addUser(db, spec) end)
    s["user.delUser"] = commit(function(name) return user.delUser(db, name) end)
    s["user.modUser"] = commit(function(name, changes) return user.modUser(db, name, changes) end)
    s["user.addGroup"] = commit(function(name, gid) return user.addGroup(db, name, gid) end)
    s["user.delGroup"] = commit(function(name) return user.delGroup(db, name) end)
end

return user
