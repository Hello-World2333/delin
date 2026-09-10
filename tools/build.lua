--[[ Delin 构建入口。
     用法:
       lua5.1 tools/build.lua                构建 dist/(压缩内核 + 模块 + 工具 + BIOS + 配置)
       lua5.1 tools/build.lua --check        构建 + 跑压缩等价性门禁(hosttest + harness 差分)
       lua5.1 tools/build.lua --release      构建 + 生成 dist/release/<版本>/ 发布树(供 http 托管)
       lua5.1 tools/build.lua --check --release   全都要(发布前的完整门禁)

     产物(dist/):
       kernel.lua              压缩后的内核 bundle          -> 引导盘 <boot> 行(默认 /boot/delin.lua)
       dlub.lua                压缩后的 DLUB 引导装载器     -> 电脑自身 FS 的 /boot/dlub.lua
       bios/startup.lua        Delin BIOS                   -> 电脑自身 FS 的 /startup.lua
       bin/<tool>              /bin 工具(压缩)
       modules/<版本>/*.ko     内核模块(压缩, 保留 --@ 元数据头)
       units/*                 厂商单元 -> /lib/systemd/system/
       etc/*                   系统配置 -> /etc/
       manifest                版本 + 每个产物的 size/crc32(安装器校验用)

     设计要点:
       - **自动建 dist/**: 以前 tools/bundle.lua 直接 assert(io.open(...)), 干净 checkout 上
         没有 dist/(它在 .gitignore 里)就直接报错。
       - **发布树与开发产物分离**: release 带 install 布局的 payload/, 不含任何测试脚本。
       - 压缩器的三重门禁在 minify.source 内部(解析 / 重词法逐 token 比对 / 不遮蔽全局名);
         --check 再跑一遍"压缩树 vs 原始树"的行为等价性(那才是真正的保险)。 ]]

package.path = "./tools/?.lua;" .. package.path

local REPO = io.popen("pwd"):read("*l") -- 绝对路径: 镜像树里的符号链接要用

local function readAll(p)
    local f = assert(io.open(p, "rb"), "cannot open " .. p)
    local c = f:read("*a"); f:close()
    return c
end

local function writeAll(p, s)
    local f = assert(io.open(p, "wb"), "cannot write " .. p)
    f:write(s); f:close()
end

local function exists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

local function cmd(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end

--- 跑一条宿主命令, 失败即 fail-fast。
local function run(what, c)
    local ok = os.execute(c)
    if ok ~= true and ok ~= 0 then
        error(what .. " 失败: " .. c, 0)
    end
end

local bundle = dofile("tools/bundle.lua")
local minify = dofile("tools/minify.lua")
local crc32  = dofile("tools/crc32.lua")

local VERSION = readAll("src/kernel/version.lua"):match('return%s+"([^"]+)"')
assert(VERSION, "无法从 src/kernel/version.lua 读出版本号")

local DIST = REPO .. "/dist"
local RELEASE_ROOT = DIST .. "/release/" .. VERSION

-- ---------------------------------------------------------------
-- 收集要产出的文件
-- ---------------------------------------------------------------

--- 目录下的普通文件(排序, 保证可复现)。
local function listFiles(dir)
    local names = {}
    local p = io.popen("ls -A '" .. dir .. "' 2>/dev/null")
    if p then
        for n in p:lines() do names[#names + 1] = n end
        p:close()
    end
    table.sort(names)
    return names
end

-- ---------------------------------------------------------------
-- 构建
-- ---------------------------------------------------------------

--- 压缩一个文件并写出; 返回 { out, inBytes, outBytes }。
local function minifyTo(srcPath, outPath, opts)
    local out, err, stats = minify.source(readAll(srcPath), opts or {})
    if not out then error(srcPath .. ": " .. tostring(err), 0) end
    bundle.mkdirp(outPath:match("^(.*)/[^/]+$") or ".")
    writeAll(outPath, out)
    return stats
end

local function build()
    bundle.mkdirp(DIST)
    local total = { inBytes = 0, outBytes = 0, files = 0 }
    local function acc(st)
        total.inBytes = total.inBytes + st.inBytes
        total.outBytes = total.outBytes + st.outBytes
        total.files = total.files + 1
    end

    -- 1) 内核 / DLUB: 先拼装成 bundle, 再整体压缩(整体压缩才能跨模块一致地改名)
    local function bundleMinified(target, outPath)
        local src = bundle.source(target)
        local out, err = minify.source(src, {})
        if not out then error(target .. " bundle: " .. tostring(err), 0) end
        writeAll(outPath, out)
        acc({ inBytes = #src, outBytes = #out })
        return #src, #out
    end
    local kin, kout = bundleMinified("kernel", DIST .. "/kernel.lua")
    local din, dout = bundleMinified("dlub", DIST .. "/dlub.lua")
    local iin, iout = bundleMinified("installer", DIST .. "/install.lua")
    print(string.format("install.lua  %d -> %d", iin, iout))

    -- 2) BIOS
    acc(minifyTo("src/bios/startup.lua", DIST .. "/bios/startup.lua", {}))
    -- 3) /bin 工具
    for _, name in ipairs(listFiles("src/bin")) do
        acc(minifyTo("src/bin/" .. name, DIST .. "/bin/" .. name, {}))
    end
    -- 4) 内核模块(保留 --@ 元数据头) + 纯文本清单
    local modDir = DIST .. "/modules/" .. VERSION
    for _, name in ipairs(listFiles("src/modules")) do
        local p = "src/modules/" .. name
        if name:match("%.ko$") then
            acc(minifyTo(p, modDir .. "/" .. name, { keepHeader = true }))
        else
            bundle.mkdirp(modDir)
            writeAll(modDir .. "/" .. name, readAll(p)) -- manifest / modules.alias 是纯文本
        end
    end
    -- 5) 单元与配置(纯文本, 原样)
    for _, name in ipairs(listFiles("src/units")) do
        bundle.mkdirp(DIST .. "/units")
        writeAll(DIST .. "/units/" .. name, readAll("src/units/" .. name))
    end
    for _, name in ipairs(listFiles("src/etc")) do
        bundle.mkdirp(DIST .. "/etc")
        writeAll(DIST .. "/etc/" .. name, readAll("src/etc/" .. name))
    end

    print(string.format("kernel.lua %d -> %d  dlub.lua %d -> %d", kin, kout, din, dout))
    print(string.format("共 %d 个 Lua 源压缩: %d -> %d 字节 (-%d%%)",
        total.files, total.inBytes, total.outBytes,
        math.floor(100 - 100 * total.outBytes / math.max(total.inBytes, 1))))
    return total
end

-- ---------------------------------------------------------------
-- dist/manifest: 版本 + 每个产物的 size/crc32
-- ---------------------------------------------------------------

--- 递归收集 dist 下的产物(排除 manifest 自身与 release/)。
local function collectDist()
    local out = {}
    local p = io.popen("cd '" .. DIST .. "' && find . -type f ! -path './manifest' ! -path './release/*' ! -path './mirror/*' | sort")
    for line in p:lines() do
        local rel = line:gsub("^%./", "")
        out[#out + 1] = rel
    end
    p:close()
    table.sort(out)
    return out
end

local function writeManifest(path, files, baseDir)
    local lines = { "version " .. VERSION, "files " .. #files }
    for _, rel in ipairs(files) do
        local data = readAll(baseDir .. "/" .. rel)
        lines[#lines + 1] = string.format("%s %d %s", rel, #data, crc32.hex(crc32.of(data)))
    end
    writeAll(path, table.concat(lines, "\n") .. "\n")
    return #files
end

local function buildManifest()
    local files = collectDist()
    local n = writeManifest(DIST .. "/manifest", files, DIST)
    print("manifest: " .. n .. " 个产物")
end

-- ---------------------------------------------------------------
-- dist/release/<版本>/ : 安装布局的 payload + 清单
-- ---------------------------------------------------------------

local function buildRelease()
    bundle.mkdirp(RELEASE_ROOT)
    -- 安装布局: payload/ 下的相对路径 = 目标文件系统上的绝对路径
    local mapping = {
        { DIST .. "/bios/startup.lua", "startup.lua" },
        { DIST .. "/kernel.lua",       "boot/delin.lua" },
        { DIST .. "/dlub.lua",         "boot/dlub.lua" },
    }
    -- 安装器本体放在发布树根: 用户 `wget run <base>/install.lua`
    writeAll(RELEASE_ROOT .. "/install.lua", readAll(DIST .. "/install.lua"))

    local function copyTo(src, rel)
        local dst = RELEASE_ROOT .. "/payload/" .. rel
        bundle.mkdirp(dst:match("^(.*)/[^/]+$") or ".")
        writeAll(dst, readAll(src))
    end
    for _, m in ipairs(mapping) do copyTo(m[1], m[2]) end
    for _, name in ipairs(listFiles(DIST .. "/bin")) do
        copyTo(DIST .. "/bin/" .. name, "bin/" .. name)
    end
    for _, name in ipairs(listFiles(DIST .. "/modules/" .. VERSION)) do
        copyTo(DIST .. "/modules/" .. VERSION .. "/" .. name, "lib/modules/" .. VERSION .. "/" .. name)
    end
    for _, name in ipairs(listFiles(DIST .. "/units")) do
        copyTo(DIST .. "/units/" .. name, "lib/systemd/system/" .. name)
    end
    for _, name in ipairs(listFiles(DIST .. "/etc")) do
        copyTo(DIST .. "/etc/" .. name, "etc/" .. name)
    end

    local files = {}
    local p = io.popen("cd '" .. RELEASE_ROOT .. "/payload' && find . -type f | sort")
    for line in p:lines() do files[#files + 1] = line:gsub("^%./", "") end
    p:close()
    table.sort(files)
    local n = writeManifest(RELEASE_ROOT .. "/manifest", files, RELEASE_ROOT .. "/payload")

    local bytes = 0
    for _, rel in ipairs(files) do bytes = bytes + #readAll(RELEASE_ROOT .. "/payload/" .. rel) end
    print(string.format("release: %s  (%d 个文件, %d 字节)", RELEASE_ROOT, n, bytes))
end

-- ---------------------------------------------------------------
-- --check: 压缩树 vs 原始树的行为等价性
-- ---------------------------------------------------------------

--- 建一棵"压缩后的镜像树"(与 src/ 同构), 用于在宿主上跑同一套测试。
local function buildMirror()
    local M = DIST .. "/mirror"
    run("清理 mirror", "rm -rf '" .. M .. "'")
    bundle.mkdirp(M .. "/src/bin"); bundle.mkdirp(M .. "/src/kernel")
    bundle.mkdirp(M .. "/src/init"); bundle.mkdirp(M .. "/src/modules")
    bundle.mkdirp(M .. "/src/bios")
    run("软链 scripts", "ln -s '" .. REPO .. "/scripts' '" .. M .. "/scripts'")
    run("软链 tools",   "ln -s '" .. REPO .. "/tools' '" .. M .. "/tools'")
    run("软链 etc",     "ln -s '" .. REPO .. "/src/etc' '" .. M .. "/src/etc'")
    run("软链 units",   "ln -s '" .. REPO .. "/src/units' '" .. M .. "/src/units'")
    run("软链 dist",    "ln -s '" .. REPO .. "/dist' '" .. M .. "/dist'")
    for _, name in ipairs(listFiles("src/bin")) do
        minifyTo("src/bin/" .. name, M .. "/src/bin/" .. name, {})
    end
    for _, d in ipairs({ "kernel", "init", "bios" }) do
        for _, name in ipairs(listFiles("src/" .. d)) do
            if name:match("%.lua$") then minifyTo("src/" .. d .. "/" .. name, M .. "/src/" .. d .. "/" .. name, {}) end
        end
    end
    for _, name in ipairs(listFiles("src/modules")) do
        if name:match("%.ko$") then
            minifyTo("src/modules/" .. name, M .. "/src/modules/" .. name, { keepHeader = true })
        else
            writeAll(M .. "/src/modules/" .. name, readAll("src/modules/" .. name))
        end
    end
    return M
end

local CHECK_SCRIPTS = {
    "posix_test.sh", "jobctl_test.sh", "proc_test.sh",
    "redstone_test.sh", "lua_test.sh", "sh_builtin_test.sh",
}

local function check()
    local M = buildMirror()

    -- 1) 内核/init/模块: hosttest 全绿(压缩树上跑同一套 361 项)
    print("-- check: hosttest(压缩树) --")
    run("hosttest(压缩树)", "DELIN_REPO='" .. M .. "' lua5.1 tools/hosttest.lua > /tmp/delin-check-hosttest.log 2>&1")
    local log = readAll("/tmp/delin-check-hosttest.log")
    local passed, failed = log:match("(%d+) passed, (%d+) failed")
    assert(passed and tonumber(failed) == 0, "hosttest(压缩树) 未全过:\n" .. log:sub(-2000))
    print("   OK " .. passed .. " 项")

    -- 2) /bin 工具: 压缩树与原始树逐字节差分
    print("-- check: harness 差分(压缩 vs 原始) --")
    for _, script in ipairs(CHECK_SCRIPTS) do
        run("harness 原始", "lua5.1 tools/harness.lua /bin/sh < scripts/" .. script .. " > /tmp/delin-chk-a.log 2>&1")
        run("harness 压缩", "DELIN_REPO='" .. M .. "' lua5.1 tools/harness.lua /bin/sh < scripts/" .. script .. " > /tmp/delin-chk-b.log 2>&1")
        local a, b = readAll("/tmp/delin-chk-a.log"), readAll("/tmp/delin-chk-b.log")
        if a ~= b then
            error("harness 差分不一致: " .. script .. "\n(原始/压缩输出见 /tmp/delin-chk-a.log 与 /tmp/delin-chk-b.log)", 0)
        end
        print("   OK " .. script)
    end
    print("-- check: 全部通过 --")
end

-- ---------------------------------------------------------------
-- CLI
-- ---------------------------------------------------------------

local doCheck, doRelease = false, false
for i = 1, #(arg or {}) do
    local a = arg[i]
    if a == "--check" then doCheck = true
    elseif a == "--release" then doRelease = true
    else error("unknown arg: " .. a, 0) end
end

build()
buildManifest()
if doRelease then buildRelease() end
if doCheck then check() end
print("build ok (Delin " .. VERSION .. ")")
