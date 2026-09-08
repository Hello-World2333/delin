--[[ Delin /parts/manifest 解析器.
     纯文本, 一行一条, # 开头为注释:
       root /parts/root.img ext2      (角色 路径 文件系统)
       boot /boot/delin.lua           (引导目录内内核镜像路径, 可选) ]]

local manifest = {}

--- 解析 manifest 文本。
---@param content string
---@return table { partitions = { {role,path,fstype} }, boot = string|nil }
function manifest.parse(content)
    local parts, bootPath = {}, nil
    for line in content:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local role, path, fstype = line:match("^(%S+)%s+(%S+)%s*(%S*)%s*$")
            if role then
                if role == "boot" then
                    bootPath = path
                else
                    parts[#parts + 1] = { role = role, path = path, fstype = fstype or "" }
                end
            end
        end
    end
    return { partitions = parts, boot = bootPath }
end

--- 找 root 分区。
---@param m table
---@return table|nil partition
function manifest.findRoot(m)
    for _, p in ipairs(m.partitions) do
        if p.role == "root" then return p end
    end
    return nil
end

return manifest
