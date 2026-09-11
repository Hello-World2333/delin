--[[ Delin 打包器。 运行: lua5.1 tools/bundle.lua [kernel|dlub] [out.lua]
     注意: 日常用 tools/build.lua(它会压缩产物、生成发布树并跑门禁); 本文件只负责"拼装"。
     kernel: 打包 src/kernel 内核模块 -> 单文件内核 bundle。
     dlub:   打包 DLUB 引导装载器(独立于内核) -> 单文件引导 bundle。
     产物用 Lua 5.2+ _ENV 技巧(CC 5.2+), 每个模块包一个 require 到内部 __require shim。
     init 不是内核模块: 它是一段用户态源码, 由多个文件拼成一个自包含 chunk(内部 __require),
     内核只把它当字符串 spawn。
     也可被 tools/build.lua 用 dofile 载入(返回 bundle 表)。 ]]

local bundle = {}

local function readAll(p)
    local f = assert(io.open(p, "rb"), "cannot open " .. p)
    local c = f:read("*a")
    f:close()
    return c
end

local function longBracket(s)
    for level = 0, 10 do
        local close = "]" .. string.rep("=", level) .. "]"
        if not s:find(close, 1, true) then
            return "[" .. string.rep("=", level) .. "[" .. s .. close
        end
    end
    error("cannot find free long-bracket level for asset")
end

--- 目录不存在就建(Lua 没有建目录原语; 失败即报错, 不静默)。
function bundle.mkdirp(path)
    local rc = os.execute("mkdir -p '" .. path .. "'")
    -- Lua 5.1: 返回退出码; 5.2+: 返回 true / nil, "exit", code
    if rc ~= true and rc ~= 0 then
        error("cannot create directory: " .. path)
    end
end

-- 两个 profile 的模块与资产
local profiles = {
    kernel = {
        modules = {
            ["kernel.version"]   = "src/kernel/version.lua",
            ["kernel.scheduler"] = "src/kernel/scheduler.lua",
            ["kernel.process"]   = "src/kernel/process.lua",
            ["kernel.procenv"]   = "src/kernel/procenv.lua",
            ["kernel.signal"]    = "src/kernel/signal.lua",
            ["kernel.boot"]      = "src/kernel/boot.lua",
            ["kernel.vfs"]       = "src/kernel/vfs.lua",
            ["kernel.vfs_api"]   = "src/kernel/vfs_api.lua",
            ["kernel.pipe"]      = "src/kernel/pipe.lua",
            ["kernel.fifo"]      = "src/kernel/fifo.lua",
            ["kernel.modules"]   = "src/kernel/modules.lua",
            ["kernel.blockdev"]  = "src/kernel/blockdev.lua",
            ["kernel.devdisk"]   = "src/kernel/devdisk.lua",
            ["kernel.manifest"]  = "src/kernel/manifest.lua",
            ["kernel.fstab"]     = "src/kernel/fstab.lua",
            ["kernel.klog"]      = "src/kernel/klog.lua",
            ["kernel.ext2"]      = "src/kernel/ext2.lua",
            ["kernel.user"]      = "src/kernel/user.lua",
            ["kernel.display"]   = "src/kernel/display.lua",
            ["kernel.tty"]       = "src/kernel/tty.lua",
            ["kernel.fb"]        = "src/kernel/fb.lua",
            ["kernel.sysfs"]     = "src/kernel/sysfs.lua",
            ["kernel.procfs"]    = "src/kernel/procfs.lua",
        },
        assets = {},
        -- PID 1 用户态源码: 顺序敏感(unit -> service -> main), 内部 __require。
        init = {
            { "unit",    "src/init/unit.lua" },
            { "service", "src/init/service.lua" },
            { "init",    "src/init/init.lua" },
        },
        entry = "__require('kernel.boot').boot()",
    },
    dlub = {
        modules = {
            ["kernel.version"]  = "src/kernel/version.lua",
            ["kernel.blockdev"] = "src/kernel/blockdev.lua",
            ["kernel.ext2"]     = "src/kernel/ext2.lua",
            ["kernel.fifo"]     = "src/kernel/fifo.lua",
            ["kernel.pipe"]     = "src/kernel/pipe.lua",
            ["kernel.manifest"] = "src/kernel/manifest.lua",
            ["kernel.dlubcfg"]  = "src/kernel/dlubcfg.lua",
            ["kernel.dlub"]     = "src/kernel/dlub.lua",
        },
        assets = {},
        entry = "__require('kernel.dlub').master()",
    },
    -- 游戏内安装器(CraftOS 程序): 自带 ext2 驱动与 mkfs, 所以安装完全不需要外部工具。
    installer = {
        modules = {
            ["kernel.version"]  = "src/kernel/version.lua", -- 默认安装源的版本路径 = 版本号唯一真源
            ["kernel.blockdev"] = "src/kernel/blockdev.lua",
            ["kernel.ext2"]     = "src/kernel/ext2.lua",
            ["kernel.fifo"]     = "src/kernel/fifo.lua",
            ["kernel.pipe"]     = "src/kernel/pipe.lua",
            ["installer.crc32"] = "tools/crc32.lua",
            ["installer.main"]  = "tools/installer.lua",
        },
        assets = {},
        entry = "__require('installer.main').run()",
    },
}

--- 把 src/init/*.lua 拼成一个自包含的用户态 init chunk。
--- 约定: 最后一个 spec 是主程序, 顶层执行; 前面的都包成 __require 可取的模块。
local function buildInitSource(specs)
    local out = {}
    out[#out + 1] = "-- init bundle: 前 N-1 个为内部模块, 最后一个为顶层主程序"
    out[#out + 1] = "local __initMods, __initLoaded = {}, {}"
    out[#out + 1] = "local function __require(name)"
    out[#out + 1] = "    if __initLoaded[name] ~= nil then return __initLoaded[name] end"
    out[#out + 1] = "    local chunk = __initMods[name]"
    out[#out + 1] = "    if not chunk then error('init: module not found: ' .. tostring(name)) end"
    out[#out + 1] = "    local mod = chunk()"
    out[#out + 1] = "    __initLoaded[name] = mod"
    out[#out + 1] = "    return mod"
    out[#out + 1] = "end"
    for i = 1, #specs - 1 do
        out[#out + 1] = string.format("__initMods[%q] = function()", specs[i][1])
        out[#out + 1] = readAll(specs[i][2])
        out[#out + 1] = "end"
    end
    out[#out + 1] = readAll(specs[#specs][2]) -- 主程序(可见上面的 local __require)
    return table.concat(out, "\n")
end

--- 生成 bundle 源码字符串。
---@param target string "kernel"|"dlub"
---@param opts table|nil { entry = string 覆盖入口(测试用) }
---@return string
--- 构建期门禁: bundle 的模块白名单是**第二份真源**(第一份是 src/kernel/ 下的文件本身)。
--- 新加一个内核模块却忘了往 profile 里加, **宿主测试全绿也发现不了** —— 因为 hosttest 与
--- `--check` 的镜像树都是用真实 `require` 从磁盘找模块的, 只有 bundle 才会 "module not found"。
--- 真机上的表现是: DLUB 打印完 "kernel=... (N bytes)" 之后**一行日志都没有**, 整台机器静默起不来
--- (实际事故: 加了 kernel/fifo.lua, ext2.lua 顶层 require 它, 于是三台机器的引导全挂)。
--- 所以这里主动扫一遍每个被打包模块的**非 pcall** 依赖, 缺了就构建期直接失败。
---@param target string
---@param profile table
local function assertDepsComplete(target, profile)
    -- "已知名字" = 打包的模块 + bundle 自己合成的 chunk(init 源码、assets)。
    -- init 是由 profile.init 现场拼出来的 `kernel.init_src`, 不是磁盘上的模块, 别把它当缺失。
    local known = {}
    for name in pairs(profile.modules) do known[name] = true end
    if profile.init then known["kernel.init_src"] = true end
    for name in pairs(profile.assets or {}) do known["kernel." .. name .. "_src"] = true end
    local missing = {}
    for name, path in pairs(profile.modules) do
        local f = io.open(path, "rb")
        if not f then error("bundle: cannot read " .. path, 0) end
        local code = f:read("*a"); f:close()
        for line in code:gmatch("[^\n]+") do
            -- pcall 包起来的是**可选**依赖(如 ext2 对 kernel.process: DLUB 目标里没有它), 跳过。
            if not line:find("pcall(", 1, true) then
                for dep in line:gmatch("require%s*%(%s*[\"']([%w_%.]+)[\"']%s*%)") do
                    if dep:match("^kernel%.") and not known[dep] then
                        missing[#missing + 1] = string.format("  %s  (被 %s 依赖)", dep, name)
                    end
                end
            end
        end
    end
    if #missing > 0 then
        error(string.format(
            "bundle(%s): 模块清单缺 %d 项 —— 它们在 profile.modules 里不存在, 但被已打包的模块 "
            .. "require 了。真机会静默起不来(错误只看得到终端上), 所以在这里拦住:\n%s",
            target, #missing, table.concat(missing, "\n")), 0)
    end
end

function bundle.source(target, opts)
    opts = opts or {}
    local profile = assert(profiles[target], "unknown target: " .. tostring(target))
    assertDepsComplete(target, profile)

    local out = {}
    out[#out + 1] = "-- Delin OS " .. target .. " bundle (generated by tools/bundle.lua) -- do not edit"
    out[#out + 1] = "local __chunks = {}"
    out[#out + 1] = "local __loaded = {}"
    out[#out + 1] = "local function __require(name)"
    out[#out + 1] = "    if __loaded[name] then return __loaded[name] end"
    out[#out + 1] = "    local chunk = assert(__chunks[name], 'module not found: ' .. name)"
    out[#out + 1] = "    local mod = chunk()"
    out[#out + 1] = "    __loaded[name] = mod"
    out[#out + 1] = "    return mod"
    out[#out + 1] = "end"

    -- 模块顺序必须确定(bundle 内容要与构建产物逐字节可复现)。
    local names = {}
    for name in pairs(profile.modules) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local code = readAll(profile.modules[name])
        out[#out + 1] = string.format("__chunks[%q] = function()", name)
        out[#out + 1] = "    local _ENV = setmetatable({ require = __require }, { __index = _G })"
        out[#out + 1] = code
        out[#out + 1] = "end"
    end

    local assetNames = {}
    for name in pairs(profile.assets or {}) do assetNames[#assetNames + 1] = name end
    table.sort(assetNames)
    for _, name in ipairs(assetNames) do
        local code = readAll(profile.assets[name])
        out[#out + 1] = string.format("__chunks[%q] = function()", "kernel." .. name .. "_src")
        out[#out + 1] = "    return " .. longBracket(code)
        out[#out + 1] = "end"
    end

    if profile.init then
        out[#out + 1] = string.format("__chunks[%q] = function()", "kernel.init_src")
        out[#out + 1] = "    return " .. longBracket(buildInitSource(profile.init))
        out[#out + 1] = "end"
    end

    out[#out + 1] = opts.entry or profile.entry
    return table.concat(out, "\n")
end

--- 写出 bundle 文件(自动建父目录)。返回字节数。
function bundle.build(target, outPath, opts)
    local body = bundle.source(target, opts)
    local dir = outPath:match("^(.*)/[^/]+$")
    if dir then bundle.mkdirp(dir) end
    local f = assert(io.open(outPath, "w"), "cannot write " .. outPath)
    f:write(body)
    f:close()
    return #body
end

if arg and arg[0] and arg[0]:match("bundle%.lua$") then
    local target = arg[1] or "kernel"
    local outPath = arg[2] or (target == "kernel" and "dist/kernel.lua" or "dist/dlub.lua")
    print("wrote " .. outPath .. " (" .. bundle.build(target, outPath) .. " bytes)")
end

return bundle
