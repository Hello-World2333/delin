--[[ Delin DLUB 引导配置 /dlub.cfg 解析器(在电脑自身 FS 上, 引导盘挂载前即可读).
     纯文本, 一行一条, # 开头为注释:
        bootdisk left          (引导盘外设名/侧面, 如 left right top bottom front back)
     fail-fast: 语法错误 / 未知键 / 重复键 / 缺键 一律返回 nil + 原因。 ]]

local dlubcfg = {}

--- 解析 /dlub.cfg 文本。
---@param content string
---@return table|nil cfg, string|nil err  cfg = { bootdisk = string }
function dlubcfg.parse(content)
    local cfg = {}
    for line in content:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, value = line:match("^(%S+)%s+(%S+)$")
            if not key then return nil, "malformed line: " .. line end
            if key ~= "bootdisk" then return nil, "unknown key: " .. key end
            if cfg.bootdisk then return nil, "duplicate key: " .. key end
            cfg.bootdisk = value
        end
    end
    if not cfg.bootdisk then return nil, "missing key: bootdisk" end
    return cfg
end

return dlubcfg
