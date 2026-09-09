--[[ Delin DLUB 引导配置 /dlub.cfg 解析器(在电脑自身 FS 上, 引导盘挂载前即可读).
     纯文本, 一行一条, # 开头为注释:
        bootdisk left          (引导盘外设名/侧面, 如 left right top bottom front back)
        rootfs /parts/root.img (从电脑自带存储启动, 指定 ext2 根镜像路径)
     fail-fast: 语法错误 / 未知键 / 重复键 / 缺键(除非有 rootfs) 一律返回 nil + 原因。 ]]

local dlubcfg = {}

--- 解析 /dlub.cfg 文本。
---@param content string
---@return table|nil cfg, string|nil err  cfg = { bootdisk = string, rootfs = string }
function dlubcfg.parse(content)
    local cfg = {}
    for line in content:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, value = line:match("^(%S+)%s+(%S+)$")
            if not key then return nil, "malformed line: " .. line end
            if key ~= "bootdisk" and key ~= "rootfs" then return nil, "unknown key: " .. key end
            if cfg[key] then return nil, "duplicate key: " .. key end
            cfg[key] = value
        end
    end
    -- bootdisk 或 rootfs 至少指定一个
    if not cfg.bootdisk and not cfg.rootfs then
        return nil, "missing key: bootdisk or rootfs"
    end
    return cfg
end

return dlubcfg
