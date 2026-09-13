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
         另有一条源文件门禁: 扫"局部被读成全局"(初始化表达式里的闭包自引用), 见 shadowGate;
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
-- 产物门禁: 装到 CC 上的文件必须全 ASCII
-- ---------------------------------------------------------------

--- 找出一处非 ASCII 字节(返回 { line, text }; 全 ASCII 返回 nil)。
--- 逐字节扫, 不整读后 gsub —— 只需要**第一处**违规的位置, 报给人看。
local function findNonAscii(path)
    local data = readAll(path)
    local line = 1
    for i = 1, #data do
        local b = data:byte(i)
        if b == 10 then line = line + 1 end
        if b > 127 then
            local before = data:sub(1, i - 1):match("[^\n]*$") or ""
            local after = data:sub(i):match("^[^\n]*") or ""
            return { line = line, text = before .. after }
        end
    end
    return nil
end

--- 逐个产物查非 ASCII, 有一处就 fail-fast。
--- **为什么是硬门禁**: CC 终端没有中文字形(中文打出来是乱码), 而源码里的中文注释
--- 只要走到产物里就是安装件的一部分 —— 注释被压缩器丢掉的那些无所谓, 丢不掉的
--- (init 源码是原样嵌进 kernel.lua 的字符串、模块的 --@ 头、/etc 与 units 是原样拷贝)
--- 必须自己保持 ASCII。这条门禁把"哪些注释会被丢"这个知识从人脑挪到构建期。
---@param files string[] 相对路径
---@param base string 这些路径的根目录
---@param label string 报错时显示的路径前缀
local function assertAscii(files, base, label)
    local bad = {}
    for _, rel in ipairs(files) do
        local hit = findNonAscii(base .. "/" .. rel)
        if hit then
            bad[#bad + 1] = string.format("  %s/%s:%d: %s", label, rel, hit.line, hit.text)
        end
    end
    if #bad > 0 then
        error("产物出现非 ASCII 字节 —— 装到 CC 电脑上的文件必须全 ASCII:\n"
            .. table.concat(bad, "\n")
            .. "\n(dist/ 是构建产物: 陈旧发布树里的中文只能删掉重来 —— rm -rf dist)", 0)
    end
    return #files
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
    -- 先整棵清空: 发布树是"从零铺出来的安装源", 任何上一轮的残留都会**混进 manifest 与发布**。
    -- (踩过: BIOS 从 payload/ 挪到发布树根后, 旧的 payload/startup.lua 仍留着, 于是装 ext2 时
    --  又被铺进镜像根 —— 光删源码不干净, 产物树的残留也得清。)
    run("清空发布树", "rm -rf '" .. RELEASE_ROOT .. "'")
    bundle.mkdirp(RELEASE_ROOT)
    -- 安装布局: payload/ 下的相对路径 = **目标文件系统上的绝对路径**。
    -- BIOS(startup.lua)不在这一层: 它不是"目标文件系统上的文件", 而是**电脑自身存储**上的
    -- 引导文件(安装器单独从 <base>/startup.lua 取, 见 installer.lua 的 boot 配置步骤)。
    -- 以前把它塞进 payload/, 于是装 ext2 时被整棵铺进镜像根 —— 镜像根多出一个永远不用的
    -- /startup.lua(ext2 根是 Delin 的 /, 不是 CraftOS 的启动盘)。
    local mapping = {
        { DIST .. "/kernel.lua",       "boot/delin.lua" },
        { DIST .. "/dlub.lua",         "boot/dlub.lua" },
    }
    -- 安装器本体与 BIOS 放在发布树根:
    --   用户 `wget run <base>/install.lua`; 安装器再把 <base>/startup.lua 写到电脑自身存储。
    writeAll(RELEASE_ROOT .. "/install.lua", readAll(DIST .. "/install.lua"))
    writeAll(RELEASE_ROOT .. "/startup.lua", readAll(DIST .. "/bios/startup.lua"))

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
-- 门禁: 别把"局部变量读成全局"(Lua 作用域坑)
-- ---------------------------------------------------------------

--- `local backend = { ... function() ... backend.x ... end }`: 初始化表达式里的闭包读到的
--- backend 是**全局**(Lua 的 local 作用域从声明语句之后才开始), 运行期必然 nil。
--- 真机症状: `ls /proc/self` 报 "attempt to index global 'backend' (a nil value)"
--- (见 for-ai.md 的 procfs 一节) —— 这种错静态看不出来、单测也未必走到, 所以在构建期拦。
---@param files string[] 相对路径
---@param dir string 源目录
local function shadowGate(files, dir)
    local bad = {}
    for _, rel in ipairs(files) do
        local src = readAll(dir .. "/" .. rel)
        local hits, err = minify.checkShadowedGlobals(src)
        if not hits then
            bad[#bad + 1] = string.format("  %s: 解析失败: %s", rel, tostring(err))
        else
            for _, h in ipairs(hits) do
                bad[#bad + 1] = string.format("  %s:%d: '%s' 读的是**全局**(声明在 %d 行前)",
                    rel, h.line, h.name, h.declLine)
            end
        end
    end
    if #bad > 0 then
        error("局部变量被读成了全局 —— 初始化表达式里的闭包引用同名 local 会解析成全局(运行期 nil):\n"
            .. table.concat(bad, "\n")
            .. "\n修法: 声明与赋值分开(`local backend; backend = { ... }`), 或把判定抽成独立函数。", 0)
    end
    return #files
end

--- 门禁: 源文件里的"局部被读成全局"(在压缩之前拦, 报的是源码行号)。
local function runShadowGate()
    local n = 0
    for _, dir in ipairs({ "src/bin", "src/kernel", "src/init", "src/bios", "src/modules" }) do
        local list = {}
        for _, name in ipairs(listFiles(dir)) do
            if name:match("%.lua$") or name:match("%.ko$") or not name:match("%.") then
                list[#list + 1] = name
            end
        end
        if #list > 0 then n = n + shadowGate(list, dir) end
    end
    print(string.format("shadow gate: %d 个源文件没有'局部被读成全局'", n))
end

--- 门禁覆盖: dist/ 全部产物 + manifest + 整棵 dist/release(发布树就是安装源)。
local function asciiGate()
    local files = collectDist()
    files[#files + 1] = "manifest"
    local n = assertAscii(files, DIST, "dist")

    local p = io.popen("cd '" .. DIST .. "' && ls -d release/*/ 2>/dev/null")
    local trees = {}
    for line in p:lines() do trees[#trees + 1] = line:gsub("/$", "") end
    p:close()
    for _, tree in ipairs(trees) do
        local list = {}
        local q = io.popen("cd '" .. DIST .. "/" .. tree .. "' && find . -type f | sort")
        for line in q:lines() do list[#list + 1] = line:gsub("^%./", "") end
        q:close()
        n = n + assertAscii(list, DIST .. "/" .. tree, "dist/" .. tree)
    end

    print(string.format("ascii gate: %d 个产物全 ASCII%s", n,
        #trees > 0 and (" (含 " .. #trees .. " 棵发布树)") or ""))
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
    "posix_test.sh", "jobctl_test.sh", "proc_test.sh", "newtools_test.sh",
    "redstone_test.sh", "lua_test.sh", "sh_builtin_test.sh", "sh_expand_test.sh",
    "user_test.sh", "regex_test.sh",
}

local function check()
    local M = buildMirror()

    -- 1) 内核/init/模块: hosttest 全绿(压缩树上跑同一套 405 项)
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
    -- 2b) sh 交互式"提示符处 ^C": 宿主专用(测试台把 stdin 伪装成终端 + 注入中断键), 没有
    --     "压缩 vs 原始"差分一说 —— 直接跑, 只看退出码。
    print("-- check: sh 提示符 ^C(宿主) --")
    run("sh_intr_test", "sh scripts/sh_intr_test.sh > /tmp/delin-chk-intr.log 2>&1")
    print("   OK sh_intr_test.sh")
    -- 2c) 分页器 more/less: 同样宿主专用(真机取不到键盘) —— 测试台把 stdin/stdout 都伪装成
    --     终端并支持内核 tty 的原始模式(setRaw + 按键字节), 断言"分屏/翻页/搜索/行号"。
    print("-- check: 分页器(宿主) --")
    run("pager_test", "sh scripts/pager_test.sh > /tmp/delin-chk-pager.log 2>&1")
    print("   OK pager_test.sh")
    -- 3) bundle 装载自检: hosttest 与镜像树都走**真实 require**, 看不见 bundle 自己的模块清单,
    --    于是"新加内核模块但忘了进 profile"这类问题能一路全绿到真机(静态门禁在 bundle.lua 里,
    --    这里做一次动态装载兜底)。需要 Lua 5.2+ —— bundle 用 _ENV 做模块隔离, 5.1 测出来是假象;
    --    没有 5.2+ 就明确跳过, 不假装通过。
    print("-- check: bundle 装载自检 --")
    local has52 = false
    for _, interp in ipairs({ "lua5.4", "lua5.3", "lua5.2" }) do
        if os.execute("command -v " .. interp .. " > /dev/null 2>&1") == true or
           os.execute("command -v " .. interp .. " > /dev/null 2>&1") == 0 then
            run("bundlecheck", interp .. " tools/bundlecheck.lua > /tmp/delin-bundlecheck.log 2>&1")
            print("   OK " .. readAll("/tmp/delin-bundlecheck.log"):match("ok%s+%S+:.-\n") or "bundlecheck")
            has52 = true
            break
        end
    end
    if not has52 then
        print("   SKIP 没有 Lua 5.2+ 解释器(bundle 的 _ENV 隔离在 5.1 上测不出真问题)")
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
runShadowGate()
asciiGate()
if doCheck then check() end
print("build ok (Delin " .. VERSION .. ")")
