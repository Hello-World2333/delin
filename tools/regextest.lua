--[[ Delin 标准正则引擎(src/kernel/regex.lua)的宿主自检。
     用法: lua5.1 tools/regextest.lua   (退出码 0 = 全过)

     两层验证:
       A. 与**宿主 GNU 工具**对照: 同一份模式/文本分别喂给引擎与宿主 grep/sed,
          逐项比对"是否匹配"(grep -q 退出码)、-o 的全部非空匹配、-w/-x/-i,
          以及 s/// 的替换结果(sed)。参考实现就是 POSIX 的实现, 不另写期望值。
          模式与文本一律走**文件**(-f), 免得 shell 引号/转义干扰对照。
       B. 引擎自身的语义用例(宿主 grep 表达不出来的): 捕获组内容、最左最长、
          匹配位置、空匹配、BRE/ERE 方言差异、非法模式 fail-fast。

     为什么不在 CC 上跑: 需要宿主 grep/sed 做参照; 真机侧由各工具自检覆盖
     (它们用的是同一份引擎, 见 for-ai.md)。 ]]

io.stdout:setvbuf("line")

local function repoRoot()
    local self = (arg and arg[0]) or "tools/regextest.lua"
    local dir = self:match("^(.*)/[^/]*$") or "."
    local root = dir:match("^(.*)/[^/]+$") or "."
    if root:sub(1, 1) ~= "/" then
        local p = io.popen("pwd")
        local cwd = p:read("*l"); p:close()
        root = (root == ".") and cwd or (cwd .. "/" .. root:gsub("^%./", ""))
    end
    return root
end
local REPO = os.getenv("DELIN_REPO") or repoRoot()
package.path = REPO .. "/src/?.lua;" .. package.path
local regex = require("kernel.regex")

local pass, fail = 0, 0
local function ok(cond, label, extra)
    if cond then
        pass = pass + 1
        io.write("ok   " .. label .. "\n")
    else
        fail = fail + 1
        io.write("FAIL " .. label .. (extra and ("  -- " .. tostring(extra)) or "") .. "\n")
    end
end
local function eq(got, want, label)
    ok(got == want, label, "got=" .. tostring(got) .. " want=" .. tostring(want))
end

local TPAT = "/tmp/delin-regextest.pat"
local TTXT = "/tmp/delin-regextest.txt"
local TSED = "/tmp/delin-regextest.sed"
local function writeFile(path, s)
    local f = assert(io.open(path, "wb"))
    f:write(s)
    f:close()
end

--- 宿主命令的 stdout(popen 的 close 在 lua5.1 上恒返回 true, 所以退出码走 os.execute)。
local function run(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    local out = p:read("*a")
    p:close()
    return out
end

--- 宿主命令的退出码(0 = 成功)。
local function status(cmd)
    local a, _, c = os.execute(cmd .. " >/dev/null 2>&1")
    if a == true then return 0 end
    if a == false then return c or 1 end
    if type(a) == "number" then return a == 0 and 0 or math.floor(a / 256) end
    return 1
end

--- 宿主 grep: 模式/文本都走文件。extra 里放 -i/-w/-x 之类。
local function gnu(pat, text, flag, extra)
    writeFile(TPAT, pat .. "\n")
    writeFile(TTXT, text .. "\n")
    return run(string.format("grep %s %s -f %s %s", flag or "", extra or "", TPAT, TTXT))
end

local function gnuMatches(pat, text, flag, extra)
    writeFile(TPAT, pat .. "\n")
    writeFile(TTXT, text .. "\n")
    return status(string.format("grep %s %s -q -f %s %s", flag or "", extra or "", TPAT, TTXT)) == 0
end

local function splitLines(out)
    local res = {}
    for line in out:gmatch("[^\n]*\n?") do
        if line ~= "" then res[#res + 1] = (line:gsub("\n$", "")) end
    end
    return res
end

--- 引擎的非空匹配列表(与 grep -o 同一口径: 空匹配不输出)。
local function ourOnly(re, text)
    local res = {}
    for _, m in ipairs(re:findall(text)) do
        if m.e >= m.s then res[#res + 1] = text:sub(m.s, m.e) end
    end
    return res
end

local function listStr(t) return "[" .. table.concat(t, "|") .. "]" end

-- ===============================================================
-- A. 与宿主 GNU grep 对照
-- ===============================================================
-- { 模式, flavor, 文本, grep 附加选项 }
local CASES = {
    { "abc", "ere", "xabcy", "" },
    { "a.c", "ere", "aXc", "" },
    { "a.c", "ere", "ac", "" },
    { "[abc]+", "ere", "xxabcxx", "" },
    { "[a-c]+", "ere", "xxabcdxx", "" },
    { "[^a-c]+", "ere", "abXYZcd", "" },
    { "[]a]", "ere", "a]", "" },
    { "[[:digit:]]+", "ere", "ab123cd", "" },
    { "[[:alpha:][:digit:]]+", "ere", "--a1b2--", "" },
    { "[-a]+", "ere", "x-a-x", "" },
    { "^abc", "ere", "abcd", "" },
    { "^abc", "ere", "xabc", "" },
    { "abc$", "ere", "xabc", "" },
    { "^abc$", "ere", "abc", "" },
    { "^$", "ere", "", "" },
    { "^a|b$", "ere", "b", "" },
    { "ab*c", "ere", "ac", "" },
    { "ab*c", "ere", "abbbc", "" },
    { "ab+c", "ere", "ac", "" },
    { "ab+c", "ere", "abbc", "" },
    { "ab?c", "ere", "ac", "" },
    { "a{2,3}", "ere", "aaaa", "" },
    { "a{2,}", "ere", "aaaa", "" },
    { "a{2}", "ere", "aa", "" },
    { "(ab)+", "ere", "ababab", "" },
    { "(a|bc)+d", "ere", "abcbcd", "" },
    { "a|ab", "ere", "ab", "" },
    { "(a|ab)(c|bcd)", "ere", "abcd", "" },
    { "x*", "ere", "abc", "" },
    { "a*", "ere", "aaab", "" },
    { "(|a)b", "ere", "b", "" },
    { "(ab)\\1", "ere", "abab", "" },
    { "(a)(b)\\2\\1", "ere", "abba", "" },
    { "\\(ab\\)\\1", "bre", "abab", "" },
    { "\\w+", "ere", "  foo_bar9 ", "" },
    { "\\W+", "ere", "ab  cd", "" },
    { "\\bfoo\\b", "ere", "a foo b", "" },
    { "\\<foo", "ere", "xfoo", "" },
    { "foo\\>", "ere", "foox", "" },
    { "\\Bar\\B", "ere", "barbar", "" },
    { "abc", "ere", "xABCy", "-i" },
    { "[a-c]+", "ere", "xABCy", "-i" },
    { "[^a-c]+", "ere", "xABCy", "-i" },
    { "foo", "ere", "foo foobar", "-w" },
    { "foo|bar", "ere", "a foo bar b", "-w" },
    { "foo", "ere", "foo", "-x" },
    { "foo", "ere", "foobar", "-x" },
    { "a.c", "bre", "abc", "" },
    { "a*b", "bre", "aaab", "" },
    { "a\\+b", "bre", "aab", "" },
    { "a\\?b", "bre", "ab", "" },
    { "a\\|b", "bre", "zzbzz", "" },
    { "a{2}", "bre", "a{2}", "" },
    { "a\\{2\\}", "bre", "aa", "" },
    { "^\\(ab\\)+$", "bre", "abab", "" },
    { "[[:space:]]+", "bre", "a \t b", "" },
    { "x\\{1,\\}", "bre", "xxx", "" },
}

io.write("== A. 与宿主 GNU grep 对照 ==\n")
for _, c in ipairs(CASES) do
    local pat, flavor, text, extra = c[1], c[2], c[3], c[4]
    local flag = (flavor == "ere") and "-E" or "-G"
    local label = string.format("%s %-2s %s %s / %q", flag, extra, string.format("%q", pat),
        (extra ~= "") and "" or "", text)
    local re, err = regex.compile(pat, flavor, {
        icase = extra:find("i", 1, true) ~= nil,
        word = extra:find("w", 1, true) ~= nil,
        line = extra:find("x", 1, true) ~= nil,
    })
    if not re then
        ok(false, label, "compile: " .. tostring(err))
    else
        local want = gnuMatches(pat, text, flag, extra)
        local got = re:find(text) ~= nil
        ok(got == want, "match " .. label, "engine=" .. tostring(got) .. " gnu=" .. tostring(want))
        if want then
            local g = splitLines(gnu(pat, text, flag, (extra .. " -o")))
            local o = ourOnly(re, text)
            ok(listStr(g) == listStr(o), "-o    " .. label, "engine=" .. listStr(o) .. " gnu=" .. listStr(g))
        end
    end
end

-- s/// 与宿主 sed 对照(分隔符动态挑一个模式里没有的)
io.write("== A2. 与宿主 GNU sed 对照 ==\n")
local SUBS = {
    { "b", "ere", "abc", "[&]", false },
    { "(a)(b)", "ere", "abc", "\\2\\1", false },
    { "(a+)(b+)", "ere", "xaabbbx", "<\\1|\\2>", false },
    { "a", "ere", "aaa", "X", true },
    { "[[:digit:]]", "ere", "a1b2", "N", true },
    { "x*", "ere", "abc", "-", true },
    { "^", "ere", "abc", ">", true },
    { "$", "ere", "abc", "<", true },
    { "a.c", "ere", "aXc aYc", "Z", true },
    { "\\bfoo\\b", "ere", "a foo b", "BAR", true },
    { "o", "ere", "foo", "\\n", true },
    { "abc", "ere", "xABCy", "Z", true },       -- 带 I 标志: 见下
    { "\\(a\\)\\(b\\)", "bre", "abc", "\\2\\1", false },
    { "a\\+", "bre", "aaa", "X", true },
}
for _, c in ipairs(SUBS) do
    local pat, flavor, text, repl, global = c[1], c[2], c[3], c[4], c[5]
    local icase = (pat == "abc" and text == "xABCy")
    local re = regex.compile(pat, flavor, { icase = icase })
    if not re then
        ok(false, "sub " .. pat, "compile failed")
    else
        local delim = "/"
        for _, d in ipairs({ "/", "|", "#", "%", "!", "@", ";", ":" }) do
            if not pat:find(d, 1, true) and not repl:find(d, 1, true) then delim = d; break end
        end
        local script = "s" .. delim .. pat .. delim .. repl .. delim .. (global and "g" or "")
            .. (icase and "I" or "")
        writeFile(TSED, script .. "\n")
        writeFile(TTXT, text .. "\n")
        local sflag = (flavor == "ere") and "-E" or ""
        local want = (run(string.format("sed %s -f %s %s", sflag, TSED, TTXT)))
        want = (want:gsub("\n$", ""))
        local got = re:sub(text, repl, global)
        eq(got, want, string.format("sed %-2s %-14s / %q -> %q", sflag, pat, text, repl))
    end
end

-- ===============================================================
-- B. 引擎自身语义(捕获组/位置/方言)
-- ===============================================================
io.write("== B. 引擎语义用例 ==\n")

local function m1(pat, flavor, opts)
    local re, err = regex.compile(pat, flavor, opts)
    if not re then return nil, err end
    return re
end

local function eqMatch(pat, flavor, text, ws, we, caps, label)
    local re, err = m1(pat, flavor)
    if not re then ok(false, label, tostring(err)); return end
    local m = re:find(text)
    if not m then ok(false, label .. " 位置", "no match"); return end
    eq(m.s .. "," .. m.e, ws .. "," .. we, label .. " 位置")
    if caps then
        local got = {}
        for i = 1, #caps do
            local c = m.caps[i]
            got[i] = c and text:sub(c.s, c.e) or "<none>"
        end
        eq(table.concat(got, "|"), table.concat(caps, "|"), label .. " 捕获组")
    end
end

eqMatch("abc", "ere", "xxabcxx", 3, 5, nil, "ere 字面量")
eqMatch("a(b)(c)d", "ere", "xabcdx", 2, 5, { "b", "c" }, "ere 捕获组")
eqMatch("a|ab", "ere", "ab", 1, 2, nil, "最左最长 a|ab")
eqMatch("(a|ab)(c|bcd)", "ere", "abcd", 1, 4, { "a", "bcd" }, "POSIX 子表达式")
eqMatch("(a+)(b+)", "ere", "aabbb", 1, 5, { "aa", "bbb" }, "贪婪重复")
eqMatch("a{2,3}", "ere", "aaaa", 1, 3, nil, "区间取最长")
eqMatch("\\(", "ere", "a(b", 2, 2, nil, "ERE 转义括号")
eqMatch("(", "bre", "a(b", 2, 2, nil, "BRE 里 ( 是字面量")
eqMatch("(a)", "bre", "(a)", 1, 3, nil, "BRE 里 ( ) 是字面量")
eqMatch("a\\|b", "bre", "zzb", 3, 3, nil, "BRE 的 \\| 分支")
eqMatch("(ab)\\1", "ere", "xababy", 2, 5, { "ab" }, "反向引用")
eqMatch("(x)?ab", "ere", "ab", 1, 2, { "<none>" }, "未参与的组")
eqMatch(".", "ere", "ab", 1, 1, nil, "点")

local re = assert(m1("b+", "ere"))
ok(re:match("aabb") == nil, "match 锚定(不该命中)")
ok(re:match("bbaa") ~= nil, "match 锚定命中")
eq(re:match("bbaa").e, 2, "match 锚定长度")

local re2 = assert(m1("a", "ere"))
eq(re2:find("aaa", 3).s, 3, "find 从 init 起")

local re3 = assert(m1("", "ere"))
ok(re3:find("abc") ~= nil, "空模式命中空串")
eq(re3:find("abc").s, 1, "空模式位置")

-- 替换细节(宿主 sed 无法直接对照的)
local function eqSub(pat, flavor, text, repl, global, want, label)
    local r, err = regex.compile(pat, flavor)
    if not r then ok(false, label, tostring(err)); return end
    local got = r:sub(text, repl, global)
    eq(got, want, label)
end
eqSub("a", "ere", "aaa", "X", false, "Xaa", "替换只替第一个")
eqSub("x*", "ere", "abc", "-", true, "-a-b-c-", "空匹配的替换")
eqSub("o", "ere", "foo", "\\&", true, "f&&", "\\& 是字面 &")
-- 只替第 n 次出现(sed 的 s///N)
eqSub("a", "ere", "aaaa", "X", 2, "aXaa", "替换第 2 次")
eqSub("a", "ere", "aaaa", "X", 5, "aaaa", "第 5 次不存在时原样")

-- -F: 字面串(元字符不生效)
local rf = assert(regex.compile("a.c", "ere", { fixed = true }))
ok(rf:find("xa.cx") ~= nil, "-F 里 . 是字面量")
ok(rf:find("xabcy") == nil, "-F 里 . 不匹配任意字符")
local rf2 = assert(regex.compile("[a]", "ere", { fixed = true }))
ok(rf2:find("x[a]x") ~= nil, "-F 里 [ ] 是字面量")
local rf3 = assert(regex.compile("a+b", "ere", { fixed = true, icase = true }))
ok(rf3:find("A+B") ~= nil, "-F 与 -i 合用")

-- 非法模式必须 fail-fast
local bad = { { "(", "ere" }, { "a{2,1}", "ere" }, { "[a", "ere" }, { "[[:foo:]]", "ere" },
              { "a)", "ere" }, { "\\1", "ere" }, { "\\(", "bre" }, { "a\\", "ere" } }
local allBad = true
for _, b in ipairs(bad) do
    local r = regex.compile(b[1], b[2])
    if r then io.write("  (非法模式被接受: " .. b[1] .. " [" .. b[2] .. "])\n") end
    allBad = allBad and (r == nil)
end
ok(allBad, "非法模式一律编译失败")
ok(regex.compile("a", "pcre") == nil, "未知方言被拒")
-- 合法边界情形(不能误报)
for _, goodpat in ipairs({ "a{2}", "a{2,}", "[]]", "[^]]", "a|", "|a", "()", "(|a)", "a**" }) do
    ok(regex.compile(goodpat, "ere") ~= nil, "合法模式: " .. goodpat)
end
local rb = regex.compile("a{b", "bre")
ok(rb ~= nil and rb:find("xa{by") ~= nil, "BRE 里 a{b 是字面量")
local rl = regex.compile("a{x}", "ere")
ok(rl ~= nil and rl:find("a{x}") ~= nil, "ERE 里 a{x} 是字面量")
local big = regex.compile("a{255}" .. string.rep("a{255}", 100), "ere")
ok(big == nil, "超长模式编译失败(fail-fast)")

io.write(string.format("\n== %d 项通过, %d 项失败 ==\n", pass, fail))
if fail > 0 then os.exit(1) end
