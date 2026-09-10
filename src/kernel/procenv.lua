--[[ Delin 进程环境白名单.
     进程 env 是**白名单**: 不设 __index=_G, 凡是没有被这里列出的全局一律是 nil。
     理由: CC 自带一大批原生全局(fs/io/loadfile/dofile/os.run/require/settings/shell/disk/
     peripheral/term/os.pullEvent ...), 它们直接操作电脑自身 FS、CC ROM 程序、事件队列与外设,
     完全绕过 Delin 的 VFS/设备文件/权限 —— 只在用户层(每个工具)挨个打补丁既漏又散,
     所以由内核统一"不把这些名字给出去"(fail-fast: 用到就是 nil, 报错落在调用点)。
     其中 fs/io 不是删掉而是**换掉**: 内核注入 VFS 门面(vfs_api.installForEnv)。

     白名单刻意宽松: 不绕过 Delin 接口的 CC API 照给 —— term/write/read(相当于 Linux 的
     /dev/tty 直连控制台)、redstone(与 /sys/class/redstone 同能力)、http/rednet/gps(网络)、
     turtle/window/paintutils/textutils/parallel 等。以后要收紧(比如禁网络), 在这里删一行即可。

     关闭的渠道(名字与理由):
       loadfile dofile        读文件执行 —— 走 CC 原生 fs, 绕过 VFS
       os.run                 同上
       os.loadAPI unloadAPI   从 CC 原生 fs 载入 API, 绕过 VFS
       require package        从 CC ROM/原生 fs 载模块, 绕过 VFS
       settings               直接读写电脑自身 FS 上的配置文件
       shell commands multishell help
                              CC ROM 程序(在电脑自身 FS 上增删文件/起 CC 自己的 shell)
       disk                   disk.getMountPath -> 绕过 /dev/sdX 与 mount
       peripheral pocket      裸外设(驱动器/显示器/打印机 ...), 绕过 /dev 与 /sys
       os.pullEvent os.pullEventRaw
                              偷内核事件队列(键盘/磁盘事件被用户进程拿走, 其他 tty 收不到)
       os.queueEvent          伪造事件(可向任意 tty 注入按键)
       os.shutdown os.reboot  电源(内核特权)
       debug                  只给 debug.traceback(整个 debug 可经 registry 逃逸出沙箱)
     其它标准库(string/table/math/coroutine)与 CC 的表一律**浅拷贝**给进程: 进程改了副本
     不会影响内核与其它进程。 ]]

local procenv = {}

-- 允许暴露的 CC 全局(宽松部分): 常量表、纯计算、控制台直连、网络、外设类库里不出逃的。
local ALLOW_CC = {
    -- 常量/纯计算
    "colors", "colours", "keys", "vector", "textutils", "parallel",
    -- 控制台直连(≈ /dev/tty), 与 term 配套的基础函数
    "term", "write", "read", "printError", "sleep", "window", "paintutils",
    -- CC 的原生能力: 与 sysfs/设备文件同层, 保留(见文件头说明)
    "redstone", "rednet", "gps", "http", "turtle",
    -- CC 提供的常量
    "_HOST", "_CC_DEFAULT_SETTINGS",
}

-- 允许的基础函数。5.2 没有 loadstring/setfenv/getfenv/unpack(rawlen 亦为 5.2 才有),
-- 缺的名字直接跳过 —— 于是同一份名单在 CC(Lua 5.2)与宿主测试台(Lua 5.1)上都能用。
local ALLOW_BASE = {
    "assert", "collectgarbage", "error", "getmetatable", "ipairs", "load", "loadstring",
    "next", "pairs", "pcall", "rawequal", "rawget", "rawlen", "rawset", "select",
    "setfenv", "getfenv", "setmetatable", "tonumber", "tostring", "type", "unpack",
    "xpcall", "_VERSION",
}

-- 允许的 Lua 标准库(整表浅拷贝)。
local ALLOW_LIB = { "string", "table", "math", "coroutine" }

-- os 表里必须关掉的条目(理由见文件头)。CC 的 os 是裁剪过的; 这里额外列上宿主 Lua 才有的
-- os.exit/remove/rename/tmpname/getenv, 免得工具在测试台上依赖真机没有的东西。
local OS_DENY = {
    loadAPI = true, unloadAPI = true, run = true,
    pullEvent = true, pullEventRaw = true, queueEvent = true,
    shutdown = true, reboot = true,
    exit = true, remove = true, rename = true, tmpname = true, getenv = true,
}

--- 浅拷贝一张表(元表照抄: CC 的库表靠元表做终端重定向等): 进程拿到自己的副本, 改副本
--- 不影响内核与其它进程。getmetatable 在被保护时返回的是 __metatable(不一定是表), 那种不设。
---@param t table
---@return table
local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    local mt = getmetatable(t)
    if type(mt) == "table" then setmetatable(out, mt) end
    return out
end

--- 把白名单里的全局装进进程 env(已存在的键不覆盖, 由调用方决定 Delin 接口的优先级)。
---@param env table 进程环境
function procenv.apply(env)
    for _, name in ipairs(ALLOW_BASE) do
        local v = _G[name]
        if v ~= nil then env[name] = v end
    end
    for _, name in ipairs(ALLOW_LIB) do
        local v = _G[name]
        if v ~= nil then env[name] = copy(v) end
    end
    local os = {}
    for k, v in pairs(_G.os) do
        if not OS_DENY[k] then os[k] = v end
    end
    env.os = os
    for _, name in ipairs(ALLOW_CC) do
        local v = _G[name]
        if type(v) == "table" then env[name] = copy(v)
        elseif v ~= nil then env[name] = v end
    end
    -- 只给 traceback: 别的 debug 一律不给(debug 是逃出沙箱的经典通道: 经 registry 就能摸到
    -- 内核自己的表和 CC 原生 API)。
    env.debug = { traceback = _G.debug.traceback }
end

return procenv
