--[[ Delin DLUB 引导配置 /dlub.cfg 解析器(在电脑自身 FS 上, 引导盘挂载前即可读).
     纯文本, 一行一条, # 开头为注释:
         bootdisk left          (引导盘外设名/侧面, 如 left right top bottom front back) —— 根 = 该盘
                                /parts/manifest 里 root 行指向的 ext2 分区
         rootfs /parts/root.img (根 = 电脑自带存储上的一个 ext2 镜像文件)
         ccdisk left            (根 = 该磁盘的 CC 原生文件系统, 即"把 CCFS 装在磁盘上";
                                内核从该盘 /boot/delin.lua 读)
     三者互斥, 必须且只能指定一个。
     fail-fast: 语法错误 / 未知键 / 重复键 / 缺键 / 多个根来源 一律返回 nil + 原因。 ]]

local dlubcfg = {}

local KEYS = { bootdisk = true, rootfs = true, ccdisk = true }

--- 解析 /dlub.cfg 文本。
---@param content string
---@return table|nil cfg, string|nil err  cfg = { bootdisk = string } | { rootfs = string } | { ccdisk = string }
function dlubcfg.parse(content)
    local cfg = {}
    local n = 0
    for line in content:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, value = line:match("^(%S+)%s+(%S+)$")
            if not key then return nil, "malformed line: " .. line end
            if not KEYS[key] then return nil, "unknown key: " .. key end
            if cfg[key] then return nil, "duplicate key: " .. key end
            cfg[key] = value
            n = n + 1
        end
    end
    if n == 0 then return nil, "missing key: bootdisk / rootfs / ccdisk" end
    if n > 1 then
        return nil, "conflicting keys: exactly one of bootdisk / rootfs / ccdisk is allowed"
    end
    return cfg
end

return dlubcfg
