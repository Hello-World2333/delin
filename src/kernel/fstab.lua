--[[ Delin /etc/fstab 解析器 (fstab(5) 子集)。
       <file system> <mount point> <type> <options> <dump> <pass>
     # 起头为注释, 空行忽略; 字段以空白分隔, 后两列缺省为 0。
     语法错误一律 fail-fast 报 "<path>:<line>: ..."(内核不做静默回退)。
     options 识别: defaults(=空) / ro / rw / auto / noauto / nofail / user / users;
       未知选项直接报错(避免拼错的挂载选项被静默忽略)。
       noauto  -> 启动时不自动挂载(仍可用 mount <mountpoint> 手动挂);
       nofail  -> 挂载失败不使 local-fs.target 失败(fstab 语义)。
     本层只做解析; 实际挂载由 init 生成的 <mountpoint>.mount 单元调用 fs.mount 完成。 ]]

local fstab = {}

-- 已知选项。值为 true 表示本层理解其语义, 为 "ignored" 表示解析后忽略(不强制)。
local OPTIONS = {
    defaults = true,
    noauto   = true,   -- 不随启动挂载
    nofail   = true,   -- 失败不阻断 local-fs.target
    auto     = true,   -- 默认(可被 noauto 覆盖)
    ro       = "ignored", -- Delin 的 fstype 无只读模式, 解析但忽略
    rw       = "ignored",
    user     = "ignored",
    users    = "ignored",
}

--- 解析 fstab 文本。
---@param content string
---@param path string|nil 用于错误消息的文件名(默认 "/etc/fstab")
---@return table[]|nil entries, string|nil err
function fstab.parse(content, path)
    path = path or "/etc/fstab"
    local entries = {}
    local lineno = 0
    for raw in (content .. "\n"):gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        local line = raw:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local f = {}
            for tok in line:gmatch("%S+") do f[#f + 1] = tok end
            if #f < 3 then
                return nil, string.format("%s:%d: need at least <device> <mountpoint> <fstype>", path, lineno)
            end
            local optsRaw = f[4] or "defaults"
            local opts = {}
            for opt in (optsRaw .. ","):gmatch("([^,]*),") do
                opt = opt:gsub("^%s+", ""):gsub("%s+$", "")
                if opt ~= "" then
                    local known = OPTIONS[opt]
                    if not known then
                        return nil, string.format("%s:%d: unknown mount option '%s'", path, lineno, opt)
                    end
                    opts[opt] = true
                end
            end
            local function num(s, what)
                if s == nil then return 0 end
                local n = tonumber(s)
                if not n or n < 0 or n ~= math.floor(n) then
                    return nil, string.format("%s:%d: bad %s field '%s'", path, lineno, what, s)
                end
                return n
            end
            local dump, err = num(f[5], "dump")
            if not dump then return nil, err end
            local pass
            pass, err = num(f[6], "pass")
            if not pass then return nil, err end
            entries[#entries + 1] = {
                device = f[1],
                mountpoint = f[2],
                fstype = f[3],
                options = optsRaw,
                opts = opts,
                dump = dump,
                pass = pass,
                line = lineno,
            }
        end
    end
    return entries
end

--- 读并解析一个 fstab 文件(经 VFS fs 门面)。文件不存在 -> 空表(无条目)。
---@param fsapi table vfs_api.fs
---@param path string|nil
---@return table[]|nil entries, string|nil err
function fstab.read(fsapi, path)
    path = path or "/etc/fstab"
    if not fsapi.exists(path) then return {} end
    local f, oerr = fsapi.open(path, "r")
    if not f then return nil, path .. ": " .. tostring(oerr) end
    local content = f.readAll()
    f.close()
    local entries, err = fstab.parse(content, path)
    if not entries then return nil, err end
    for _, e in ipairs(entries) do
        local name, nerr = fstab.escapeMount(e.mountpoint)
        if not name then return nil, string.format("%s:%d: %s", path, e.line, nerr) end
        e.unit = name .. ".mount" -- init 用它生成 mount 单元(systemd 的命名规则)
    end
    return entries
end

--- 挂载点 -> systemd 风格单元名(mount unit naming)。
---   "/" -> "-"        "/mnt/data" -> "mnt-data"
---   仅接受 [A-Za-z0-9_.-] 字符, 其余报错(不做 \xNN 转义, 保持可读)。
---@param mountpoint string
---@return string|nil name, string|nil err
function fstab.escapeMount(mountpoint)
    if mountpoint == "/" then return "-" end
    local body = mountpoint:gsub("^/+", ""):gsub("/+$", "")
    if body == "" then return nil, "empty mount point" end
    body = body:gsub("/", "-") -- systemd: 目录分隔符 -> '-'
    if body:find("[^A-Za-z0-9_.%-]") then
        return nil, "mount point has characters not representable in a unit name: " .. mountpoint
    end
    return body
end

return fstab
