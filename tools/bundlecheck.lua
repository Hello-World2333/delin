--[[ Delin bundle 装载自检: 用**真实生成的 bundle** 把每个模块 __require 一遍。
     为什么单独需要它: tools/hosttest.lua 与 `--check` 的镜像树都是拿**真实 require** 从磁盘上
     找模块的 —— 它们走的是 src/kernel/*.lua 文件本身, 于是 bundle 的第二份模块清单(profile.modules)
     漏了一项也照样全绿。实际事故: 新增 kernel/fifo.lua 而没往 profile 里加, 三台机器全部静默起不来
     (DLUB 打完 "kernel=... (N bytes)" 就没有下文了)。

     两条防线:
       1. tools/bundle.lua 的 assertDepsComplete 在**构建期**静态扫描依赖(不依赖解释器版本);
       2. 本脚本做**动态**装载 —— 它能抓住静态扫描看不出的东西(名字对但加载期就报错的模块)。
     注意必须用 Lua 5.2+ 跑: bundle 靠 `local _ENV = setmetatable({require=__require}, ...)`
     做模块隔离, 而 Lua 5.1 **没有 `_ENV`**, 于是 require 会漏到真实 require 上, 测出来是假象
     (CC 是 5.2 语义)。lua5.1 跑本脚本会直接报错退出, 不会给出错误的绿灯。

     用法: lua5.4 tools/bundlecheck.lua     (或任何 5.2+)
]]

if _VERSION == "Lua 5.1" then
    io.stderr:write("bundlecheck: 需要 Lua 5.2+(bundle 用 _ENV 做模块隔离, 5.1 测不出真问题)\n")
    os.exit(2)
end

package.path = "./tools/?.lua;" .. package.path
local bundle = dofile("tools/bundle.lua")

-- 这些模块在**加载期**就要用 CraftOS 的全局(fs 等), 宿主上没有 —— 那是运行环境差异, 不是
-- 模块解析问题, 所以只做"能取到模块"的判定, 不把这类错误算失败。
local NEEDS_CRAFTOS = {
    ["kernel.boot"] = true, ["kernel.devdisk"] = true, ["kernel.display"] = true,
    ["kernel.klog"] = true, ["kernel.modules"] = true, ["kernel.process"] = true,
    ["kernel.procfs"] = true, ["kernel.sysfs"] = true, ["kernel.user"] = true,
    ["kernel.vfs_api"] = true,
}

local targets = { "kernel", "dlub", "installer" }
local failed = 0
for _, target in ipairs(targets) do
    local entry = [[
local names = {}
for k in pairs(__chunks) do names[#names + 1] = k end
table.sort(names)
for _, n in ipairs(names) do
    if not n:match("_src$") then
        local ok, err = pcall(__require, n)
        io.write(string.format("%s\t%s\t%s\n", n, ok and "ok" or "fail", ok and "" or tostring(err)))
    end
end
]]
    local src = bundle.source(target, { entry = entry })
    local chunk, lerr = load(src, "@bundle-" .. target)
    if not chunk then
        io.write(string.format("FAIL  %s: 生成物无法编译: %s\n", target, tostring(lerr)))
        failed = failed + 1
    else
        local out = {}
        local realWrite = io.write
        io.write = function(s) out[#out + 1] = s end
        local ok, err = pcall(chunk)
        io.write = realWrite
        if not ok then
            io.write(string.format("FAIL  %s: 装载入口失败: %s\n", target, tostring(err)))
            failed = failed + 1
        else
            local n = 0
            for line in table.concat(out):gmatch("[^\n]+") do
                local name, status, msg = line:match("^([^\t]+)\t([^\t]+)\t(.*)$")
                n = n + 1
                if status == "fail" then
                    -- 只把"模块取不到"当失败; 需要 CraftOS 全局的模块加载期报错不算(见上)。
                    local isResolve = msg:find("module not found", 1, true) ~= nil
                    if isResolve or not NEEDS_CRAFTOS[name] then
                        io.write(string.format("FAIL  %s/%s: %s\n", target, name, msg))
                        failed = failed + 1
                    end
                end
            end
            io.write(string.format("ok    %s: %d 个模块\n", target, n))
        end
    end
end

if failed > 0 then
    io.write(string.format("\nbundlecheck: %d 项失败\n", failed))
    os.exit(1)
end
io.write("\nbundlecheck: 全部通过\n")
