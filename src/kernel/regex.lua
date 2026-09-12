--[==[ Delin 标准正则引擎: POSIX BRE / ERE(IEEE Std 1003.1) + 常用 GNU 扩展。

     为什么放在内核里: 进程环境是白名单(kernel/procenv.lua), require/dofile 一律不给 ——
     用户态没有"共享库"这一层。与 user.*/init.* 同一模式: 引擎是内核里的**唯一真源**,
     /bin 工具经 syscalls["regex.*"] 使用, `lua` 里也能直接用(syscalls["regex.compile"](...))。

     方言(flavor):
       "ere"  扩展正则: . [ ] ^ $ * + ? {m,n} ( ) | 与 \ 转义;
       "bre"  基本正则: 只有 . [ ] ^ $ * 与反向引用 \( \) \{m,n\} \1..\9 是特殊的,
              其余 (( ) { } + ? |) 一律字面量; GNU 扩展 \+ \? \| 也收(与 GNU grep/sed 一致)。
     两方言共有:
       - 反向引用 \1..\9;
       - GNU 扩展: \w \W \s \S \< \> \b \B, 以及 \n \t \r \f \v \a \e 转义;
       - 字符组里的 POSIX 类 [[:alpha:]] [[:digit:]] ...(另收 GNU 的 [[:word:]]);
       - 空模式(匹配空串), 空分支(a| 里的空串)。

     匹配语义: **最左最长**(POSIX)。一次扫描同时推进所有起点(每向前一格新开一个起点线程),
     命中后不再开新起点 —— 于是第一个命中的起点必是最左的, 之后再取最靠右的终点。
     子表达式捕获按"分支优先 + 贪婪"(POSIX 的子表达式规则在退化情形下有更细的规定,
     这里按 RE2 的做法近似 —— 见 for-ai.md「已知偏离」)。

     已知偏离:
       - 不支持 [[=x=]] 等价类与 [[.x.]] 排序元素(单字节字符集里没有意义);
       - 不支持 GNU 的 \` \' 锚点(定义在"整个文件"上, 与按行匹配的 grep/sed 无关);
       - 文本按**字节**处理(Delin 的文本是 ASCII; 非 ASCII 字节当普通字节)。 ]==]

local regex = {}

-- ===============================================================
-- 字节判定与字符组
-- ===============================================================

local function isDigitByte(b) return b ~= nil and b >= 48 and b <= 57 end
local function isUpperByte(b) return b ~= nil and b >= 65 and b <= 90 end
local function isLowerByte(b) return b ~= nil and b >= 97 and b <= 122 end
local function isAlphaByte(b) return isUpperByte(b) or isLowerByte(b) end
local function isWordByte(b) return isAlphaByte(b) or isDigitByte(b) or b == 95 end

--- POSIX 字符类名 -> 判定函数(另收 GNU 的 word)。
local POSIX_CLASS = {
    alnum  = function(b) return isAlphaByte(b) or isDigitByte(b) end,
    alpha  = isAlphaByte,
    blank  = function(b) return b == 32 or b == 9 end,
    cntrl  = function(b) return b ~= nil and (b < 32 or b == 127) end,
    digit  = isDigitByte,
    graph  = function(b) return b ~= nil and b > 32 and b < 127 end,
    lower  = isLowerByte,
    print  = function(b) return b ~= nil and b >= 32 and b < 127 end,
    punct  = function(b) return b ~= nil and b > 32 and b < 127 and not isAlphaByte(b) and not isDigitByte(b) end,
    space  = function(b) return b == 32 or (b ~= nil and b >= 9 and b <= 13) end,
    upper  = isUpperByte,
    xdigit = function(b)
        return isDigitByte(b) or (b ~= nil and b >= 65 and b <= 70) or (b ~= nil and b >= 97 and b <= 102)
    end,
    word   = isWordByte,
}

--- 大小写折叠表: 字节 -> 小写字节(-i / s///I 用)。
local FOLD = {}
for b = 0, 255 do FOLD[b] = b end
for b = 65, 90 do FOLD[b] = b + 32 end

local function newClassMap() local m = {} for b = 0, 255 do m[b] = 0 end return m end

--- 把字节加进字符组表; icase 时把大小写两种都加进去(编译期展开, 运行期不必再折叠)。
local function classAdd(map, b, icase)
    map[b] = 1
    if icase then
        map[FOLD[b]] = 1
        if isLowerByte(b) then map[b - 32] = 1 end
    end
end

--- 字符组表 -> 256 字节的查找表(字符串): 第 b+1 个字节非 0 表示命中。
local function mapToString(map)
    local out = {}
    for b = 0, 255 do out[b + 1] = map[b] == 1 and "\1" or "\0" end
    return table.concat(out)
end

-- ===============================================================
-- 语法分析 -> AST
-- ===============================================================
-- AST 节点:
--   { t = "empty" }                          空
--   { t = "char", c = string }               单字节字面量
--   { t = "any" }                            .
--   { t = "class", map = string }            [...] (已编译成查找表)
--   { t = "assert", kind = "bol"|"eol"|"wb"|"nwb"|"wstart"|"wend" }
--   { t = "cat", list = {...} }              连接
--   { t = "alt", list = {...} }              分支(左优先)
--   { t = "rep", node = , min = , max = }    重复(max = nil 表示无上限)
--   { t = "group", idx = n, node = }         捕获组
--   { t = "backref", idx = n }               反向引用

local parseAlt, parseConcat, parseAtom

--- 取下一个模式字符(不消费)。
local function peekCh(p) return p.s:sub(p.i, p.i) end

--- 从当前位置起第 k 个字符(k 从 0 起)。
local function at(p, k) return p.s:sub(p.i + k, p.i + k) end

local function perr(p, msg)
    p.err = p.err or msg
    return nil
end

local function classNode(p, pred)
    local map = newClassMap()
    for b = 0, 255 do
        if pred(b) then classAdd(map, b, p.icase) end
    end
    return { t = "class", map = mapToString(map) }
end

local function charNode(p, c)
    if not p.icase then return { t = "char", c = c } end
    local map = newClassMap()
    classAdd(map, c:byte(1), true)
    return { t = "class", map = mapToString(map) }
end

--- 转义序列 -> 节点; i 指向 '\'。BRE 的 \( \{ \+ \? \| 由调用方先拦下。
local function parseEscape(p)
    local c = at(p, 1)
    if c == "" then return perr(p, "trailing backslash") end
    p.i = p.i + 2
    if c >= "1" and c <= "9" then
        local n = tonumber(c)
        if n > p.ngroups then return perr(p, "invalid back reference \\" .. c) end
        return { t = "backref", idx = n }
    end
    if c == "w" then return classNode(p, isWordByte) end
    if c == "W" then return classNode(p, function(b) return not isWordByte(b) end) end
    if c == "s" then return classNode(p, function(b) return b == 32 or (b >= 9 and b <= 13) end) end
    if c == "S" then return classNode(p, function(b) return not (b == 32 or (b >= 9 and b <= 13)) end) end
    if c == "<" then return { t = "assert", kind = "wstart" } end
    if c == ">" then return { t = "assert", kind = "wend" } end
    if c == "b" then return { t = "assert", kind = "wb" } end
    if c == "B" then return { t = "assert", kind = "nwb" } end
    if c == "n" then return { t = "char", c = "\n" } end
    if c == "t" then return { t = "char", c = "\t" } end
    if c == "r" then return { t = "char", c = "\r" } end
    if c == "f" then return { t = "char", c = "\f" } end
    if c == "v" then return { t = "char", c = "\v" } end
    if c == "a" then return { t = "char", c = "\a" } end
    if c == "e" then return { t = "char", c = "\27" } end
    -- 其余: 转义后的字符当字面量(\., \* 之类)
    return charNode(p, c)
end

--- 解析 [...] 字符组。i 指向 '['。
local function parseClass(p)
    p.i = p.i + 1
    local neg = false
    if peekCh(p) == "^" then neg = true; p.i = p.i + 1 end
    local map = newClassMap()
    local first = true
    while true do
        local c = peekCh(p)
        if c == "" then return perr(p, "unterminated [") end
        if c == "]" and not first then break end
        first = false
        if c == "[" and at(p, 1) == ":" then
            local close = p.s:find(":]", p.i + 2, true)
            if not close then return perr(p, "unterminated [::]") end
            local name = p.s:sub(p.i + 2, close - 1)
            local pred = POSIX_CLASS[name]
            if not pred then return perr(p, "invalid character class [:" .. name .. ":]") end
            for b = 0, 255 do if pred(b) then classAdd(map, b, p.icase) end end
            p.i = close + 2
        else
            -- 字符组里的 '\' 是字面量(POSIX 与 GNU 一致)
            local lo = c:byte(1)
            p.i = p.i + 1
            if peekCh(p) == "-" and at(p, 1) ~= "]" and at(p, 1) ~= "" then
                local hi = at(p, 1):byte(1)
                if hi < lo then return perr(p, "invalid range end") end
                for b = lo, hi do classAdd(map, b, p.icase) end
                p.i = p.i + 2
            else
                classAdd(map, lo, p.icase)
            end
        end
    end
    p.i = p.i + 1
    if neg then
        for b = 0, 255 do map[b] = (map[b] == 1) and 0 or 1 end
    end
    return { t = "class", map = mapToString(map) }
end

--- 解析 {m,n} 区间; i 指向 '{'(BRE 的 \{ 也一样, 调用方已跳过反斜杠)。
--- 不是合法区间写法时回退(返回 nil, 位置不动, 调用方按字面量处理);
--- 写法合法但 m > n 时是**语法错**(与 GNU grep/sed 一致)。
local function parseInterval(p, bre)
    local save = p.i
    p.i = p.i + 1
    local m = ""
    while true do
        local c = peekCh(p)
        if c < "0" or c > "9" then break end
        m = m .. c; p.i = p.i + 1
    end
    local n
    if peekCh(p) == "," then
        p.i = p.i + 1
        local d = ""
        while true do
            local c = peekCh(p)
            if c < "0" or c > "9" then break end
            d = d .. c; p.i = p.i + 1
        end
        n = (d ~= "") and tonumber(d) or nil
    else
        n = tonumber(m)
    end
    local closed = bre and (p.s:sub(p.i, p.i + 1) == "\\}") or (not bre and peekCh(p) == "}")
    if m == "" or not closed then p.i = save; return nil end
    p.i = p.i + (bre and 2 or 1)
    m = tonumber(m)
    if n and n < m then return perr(p, "invalid interval: n < m") end
    if m > 255 or (n and n > 255) then return perr(p, "invalid repetition count") end
    return m, n
end

--- 解析一个原子。
parseAtom = function(p)
    local c = peekCh(p)
    if c == "" then return nil end
    local ere = (p.flavor == "ere")
    if ere and c == "(" then
        p.i = p.i + 1
        p.atStart = true
        local node = parseAlt(p, true)
        if not node then return nil end
        if peekCh(p) ~= ")" then return perr(p, "unmatched (") end
        p.i = p.i + 1
        p.ngroups = p.ngroups + 1
        return { t = "group", idx = p.ngroups, node = node }
    end
    if (not ere) and c == "\\" and at(p, 1) == "(" then
        p.i = p.i + 2
        p.atStart = true
        local node = parseAlt(p, true)
        if not node then return nil end
        if p.s:sub(p.i, p.i + 1) ~= "\\)" then return perr(p, "unmatched \\(") end
        p.i = p.i + 2
        p.ngroups = p.ngroups + 1
        return { t = "group", idx = p.ngroups, node = node }
    end
    if c == "." then p.i = p.i + 1; return { t = "any" } end
    if c == "[" then return parseClass(p) end
    if c == "^" and p.atStart then
        -- 锚点只在 RE / 分组 / 分支的开头有意义, 别处是字面量(POSIX)
        p.i = p.i + 1
        return { t = "assert", kind = "bol" }
    end
    if c == "$" then
        local nxt = at(p, 1)
        local isEnd = (nxt == "")
            or (ere and (nxt == ")" or nxt == "|"))
            or ((not ere) and nxt == "\\" and (at(p, 2) == ")" or at(p, 2) == "|"))
        if isEnd then
            p.i = p.i + 1
            return { t = "assert", kind = "eol" }
        end
    end
    if c == "\\" then return parseEscape(p) end
    p.i = p.i + 1
    return charNode(p, c)
end

--- 解析重复后缀。
local function parseRepeat(p)
    local node = parseAtom(p)
    if not node then return nil end
    local ere = (p.flavor == "ere")
    while true do
        local c = peekCh(p)
        if c == "*" then
            p.i = p.i + 1
            node = { t = "rep", node = node, min = 0, max = nil }
        elseif ere and c == "+" then
            p.i = p.i + 1
            node = { t = "rep", node = node, min = 1, max = nil }
        elseif ere and c == "?" then
            p.i = p.i + 1
            node = { t = "rep", node = node, min = 0, max = 1 }
        elseif ere and c == "{" then
            local m, n = parseInterval(p, false)
            if not m then
                if p.err then return nil end
                break
            end
            node = { t = "rep", node = node, min = m, max = n }
        elseif (not ere) and c == "\\" then
            local n = at(p, 1)
            if n == "*" then
                p.i = p.i + 2
                node = { t = "rep", node = node, min = 0, max = nil }
            elseif n == "+" then
                p.i = p.i + 2
                node = { t = "rep", node = node, min = 1, max = nil }
            elseif n == "?" then
                p.i = p.i + 2
                node = { t = "rep", node = node, min = 0, max = 1 }
            elseif n == "{" then
                local save = p.i
                p.i = p.i + 1
                local m, nn = parseInterval(p, true)
                if not m then
                    if p.err then return nil end
                    p.i = save
                    break
                end
                node = { t = "rep", node = node, min = m, max = nn }
            else
                break
            end
        else
            break
        end
    end
    return node
end

--- 解析连接(一串原子)。分支分隔符与分组结束符处停下。
parseConcat = function(p)
    local list = {}
    p.atStart = true
    local ere = (p.flavor == "ere")
    while true do
        local c = peekCh(p)
        if c == "" then break end
        if ere then
            if c == "|" or c == ")" then break end
        else
            if c == "\\" and (at(p, 1) == "|" or at(p, 1) == ")") then break end
        end
        -- 没有原子时的重复算符: GNU 当字面量
        if c == "*" or (ere and (c == "+" or c == "?")) then
            p.i = p.i + 1
            list[#list + 1] = charNode(p, c)
            p.atStart = false
        else
            local node = parseRepeat(p)
            if not node then
                if p.err then return nil end
                break
            end
            list[#list + 1] = node
            p.atStart = false
        end
    end
    if #list == 1 then return list[1] end
    return { t = "cat", list = list }
end

--- 解析分支。isGroup 为真时表示正在解析 (...) 内部。
parseAlt = function(p, isGroup)
    local ere = (p.flavor == "ere")
    local branches = {}
    while true do
        local node = parseConcat(p)
        if not node then return nil end
        branches[#branches + 1] = node
        local c = peekCh(p)
        if ere and c == "|" then
            p.i = p.i + 1
        elseif (not ere) and c == "\\" and at(p, 1) == "|" then
            p.i = p.i + 2
        else
            break
        end
    end
    if #branches == 1 then return branches[1] end
    return { t = "alt", list = branches }
end

-- ===============================================================
-- 编译 -> 指令序列
-- ===============================================================
-- 指令(数组形式, 数字下标):
--   {"char", c, next}           精确匹配一个字节(c 已按 icase 展开成字符组)
--   {"any", next}               .
--   {"class", map, next}        map 是 256 字节查找表
--   {"bol", next} {"eol", next} {"wb", next} {"nwb", next} {"wstart", next} {"wend", next}
--   {"split", a, b}             优先 a(贪婪)
--   {"jmp", a}
--   {"save", n, next}           把当前位置记到第 n 个槽
--   {"backref", idx, next}      匹配第 idx 组捕获的文本
--   {"match"}

local MAX_PROG = 20000

local function emit(prog, inst)
    if #prog >= MAX_PROG then return nil end
    prog[#prog + 1] = inst
    return #prog
end

local compileNode

--- 重复 -> 指令。min/max 展开成必需的拷贝 + 可选拷贝(或尾随 star)。
local function compileRep(n, next, prog)
    local node, min, max = n.node, n.min, n.max
    if max == 0 then return next end
    if min == 0 and max == nil then
        local L = emit(prog, { "split", 0, next })
        if not L then return nil end
        local body = compileNode(node, L, prog)
        if not body then return nil end
        prog[L][2] = body
        return L
    end
    if min == 1 and max == nil then
        local L = emit(prog, { "split", 0, next })
        if not L then return nil end
        local body = compileNode(node, L, prog)
        if not body then return nil end
        prog[L][2] = body
        return body
    end
    if min == 0 and max == 1 then
        local body = compileNode(node, next, prog)
        if not body then return nil end
        return emit(prog, { "split", body, next })
    end
    local tail = next
    if max == nil then
        local L = emit(prog, { "split", 0, next })
        if not L then return nil end
        local body = compileNode(node, L, prog)
        if not body then return nil end
        prog[L][2] = body
        tail = body
        for _ = 2, min do
            tail = compileNode(node, tail, prog)
            if not tail then return nil end
        end
        return tail
    end
    for _ = max, min + 1, -1 do
        local body = compileNode(node, tail, prog)
        if not body then return nil end
        tail = emit(prog, { "split", body, tail })
        if not tail then return nil end
    end
    for _ = min, 1, -1 do
        tail = compileNode(node, tail, prog)
        if not tail then return nil end
    end
    return tail
end

compileNode = function(n, next, prog)
    local t = n.t
    if t == "empty" then return next end
    if t == "char" then return emit(prog, { "char", n.c, next }) end
    if t == "any" then return emit(prog, { "any", next }) end
    if t == "class" then return emit(prog, { "class", n.map, next }) end
    if t == "assert" then return emit(prog, { n.kind, next }) end
    if t == "backref" then return emit(prog, { "backref", n.idx, next }) end
    if t == "group" then
        local e = emit(prog, { "save", n.idx * 2 + 2, next })
        if not e then return nil end
        local b = compileNode(n.node, e, prog)
        if not b then return nil end
        return emit(prog, { "save", n.idx * 2 + 1, b })
    end
    if t == "cat" then
        local e = next
        for i = #n.list, 1, -1 do
            e = compileNode(n.list[i], e, prog)
            if not e then return nil end
        end
        return e
    end
    if t == "alt" then
        local e = nil
        for i = #n.list, 1, -1 do
            local ei = compileNode(n.list[i], next, prog)
            if not ei then return nil end
            if e == nil then e = ei else e = emit(prog, { "split", ei, e }) end
            if not e then return nil end
        end
        return e
    end
    if t == "rep" then return compileRep(n, next, prog) end
    return nil
end

--- 编译模式串 -> 指令序列。
---@return table|nil prog, string|nil err, integer ngroups
local function compile(pat, flavor, opts)
    local p = {
        s = pat, i = 1, flavor = flavor, ngroups = 0, err = nil,
        icase = opts.icase and true or false, atStart = true,
    }
    local ast
    if opts.fixed then
        -- -F/--fixed-strings: 模式是**字面**串(元字符全部当普通字符)
        local list = {}
        for k = 1, #pat do list[#list + 1] = charNode(p, pat:sub(k, k)) end
        ast = { t = "cat", list = list }
    else
        ast = parseAlt(p, false)
        if not ast then return nil, p.err or "parse error", 0 end
        if p.i <= #pat then return nil, "unmatched ) near: " .. pat:sub(p.i, p.i), 0 end
    end
    -- -w: 整体匹配两端都要是词边界; -x: 整行匹配。都靠零宽断言包住(回溯时会自然绕开)。
    if opts.word then
        ast = { t = "cat", list = { { t = "assert", kind = "wstart" }, ast, { t = "assert", kind = "wend" } } }
    end
    if opts.line then
        ast = { t = "cat", list = { { t = "assert", kind = "bol" }, ast, { t = "assert", kind = "eol" } } }
    end
    local prog = {}
    local entry = compileNode(ast, emit(prog, { "match" }), prog)
    if not entry then
        if #prog >= MAX_PROG then return nil, "regular expression too large", 0 end
        return nil, "compile error", 0
    end
    prog.entry = entry   -- 程序入口(match 指令先发射, 所以入口不是 1)
    return prog, nil, p.ngroups
end

-- ===============================================================
-- 虚拟机: 最左最长 + 子表达式捕获
-- ===============================================================

--- 从 init 起找最左最长匹配; anchored 为真时只在 init 处起步(POSIX 的 "match")。
---@return table|nil { s, e, caps }
local function exec(prog, s, init, anchored, nslots)
    local n = #s
    -- 线程表按**扁平数组**存: 每个线程占 3 格(pc, caps, startpos)。
    -- 每格一次表分配在这里太贵(CC 上的正则要跑在每一行上), 扁平化省掉线程对象本身。
    local lists, seen = {}, {}
    local best, bestS, bestE, bestCaps = nil, nil, nil, nil

    local function addThread(pos, pc, caps, startpos)
        local sk = seen[pos]
        if not sk then sk = {}; seen[pos] = sk end
        while true do
            if sk[pc] then return end
            local inst = prog[pc]
            local op = inst[1]
            if op == "jmp" then
                pc = inst[2]
            elseif op == "split" then
                addThread(pos, inst[2], caps, startpos)
                pc = inst[3]
            elseif op == "save" then
                local nc = {}
                for i = 1, nslots do nc[i] = caps[i] end
                nc[inst[2]] = pos
                caps = nc
                pc = inst[3]
            elseif op == "bol" then
                if pos ~= 1 then return end
                pc = inst[2]
            elseif op == "eol" then
                if pos ~= n + 1 then return end
                pc = inst[2]
            elseif op == "wstart" then
                if isWordByte(s:byte(pos)) and not isWordByte(s:byte(pos - 1)) then pc = inst[2] else return end
            elseif op == "wend" then
                if isWordByte(s:byte(pos - 1)) and not isWordByte(s:byte(pos)) then pc = inst[2] else return end
            elseif op == "wb" then
                if isWordByte(s:byte(pos)) ~= isWordByte(s:byte(pos - 1)) then pc = inst[2] else return end
            elseif op == "nwb" then
                if isWordByte(s:byte(pos)) == isWordByte(s:byte(pos - 1)) then pc = inst[2] else return end
            else
                sk[pc] = true
                local l = lists[pos]
                if not l then l = {}; lists[pos] = l end
                local k = #l
                l[k + 1], l[k + 2], l[k + 3] = pc, caps, startpos
                return
            end
        end
    end

    local start0 = init or 1
    if start0 < 1 then start0 = 1 end
    for pos = start0, n + 1 do
        -- 每向前一格开一个新起点线程; 一旦命中(拿到最左起点)就不再开
        if not best and pos <= n + 1 and (not anchored or pos == start0) then
            addThread(pos, prog.entry, {}, pos)
        end
        local list = lists[pos]
        if list then
            local total = #list
            for i = 1, total, 3 do
                if prog[list[i]][1] == "match" then
                    -- 最左最长: 起点更小者优先, 同起点取更靠右的终点
                    local st = list[i + 2]
                    local e = pos - 1
                    if not best or st < bestS or (st == bestS and e > bestE) then
                        best, bestS, bestE, bestCaps = true, st, e, list[i + 1]
                    end
                end
            end
            if pos <= n then
                local b = s:byte(pos)
                for i = 1, total, 3 do
                    local pc = list[i]
                    local caps = list[i + 1]
                    local st = list[i + 2]
                    local inst = prog[pc]
                    local op = inst[1]
                    if op == "char" then
                        if b == inst[2]:byte(1) then addThread(pos + 1, inst[3], caps, st) end
                    elseif op == "class" then
                        if inst[2]:byte(b + 1) ~= 0 then addThread(pos + 1, inst[3], caps, st) end
                    elseif op == "any" then
                        addThread(pos + 1, inst[2], caps, st)
                    elseif op == "backref" then
                        local cs, ce = caps[inst[2] * 2 + 1], caps[inst[2] * 2 + 2]
                        if cs and ce then
                            local len = ce - cs
                            if len == 0 then
                                addThread(pos, inst[3], caps, st)
                            elseif s:sub(cs, ce - 1) == s:sub(pos, pos + len - 1) then
                                addThread(pos + len, inst[3], caps, st)
                            end
                        else
                            -- 未参与匹配的组当空串(GNU 语义)
                            addThread(pos, inst[3], caps, st)
                        end
                    end
                end
            end
        end
    end
    if not best then return nil end
    return { s = bestS, e = bestE, caps = bestCaps }
end

-- ===============================================================
-- 对外接口
-- ===============================================================

--- 捕获槽 -> 对外结果: caps[i] = { s, e } | false(该组未参与匹配)。
local function packMatch(m, ngroups)
    local caps = {}
    for i = 1, ngroups do
        local cs, ce = m.caps[i * 2 + 1], m.caps[i * 2 + 2]
        if cs and ce then caps[i] = { s = cs, e = ce - 1 } else caps[i] = false end
    end
    return { s = m.s, e = m.e, caps = caps }
end

--- 解析替换串(sed/ed 的 s///): & = 整串, \1..\9 = 捕获组, \\ \& \n \t \r 转义。
local function parseRepl(repl)
    local parts, lit = {}, {}
    local function flush()
        if #lit > 0 then parts[#parts + 1] = { lit = table.concat(lit) }; lit = {} end
    end
    local i = 1
    while i <= #repl do
        local c = repl:sub(i, i)
        if c == "&" then
            flush(); parts[#parts + 1] = { whole = true }; i = i + 1
        elseif c == "\\" then
            local n = repl:sub(i + 1, i + 1)
            if n == "" then
                lit[#lit + 1] = "\\"; i = i + 1
            elseif n >= "0" and n <= "9" then
                flush(); parts[#parts + 1] = { ref = tonumber(n) }; i = i + 2
            elseif n == "n" then lit[#lit + 1] = "\n"; i = i + 2
            elseif n == "t" then lit[#lit + 1] = "\t"; i = i + 2
            elseif n == "r" then lit[#lit + 1] = "\r"; i = i + 2
            elseif n == "\\" then lit[#lit + 1] = "\\"; i = i + 2
            elseif n == "&" then lit[#lit + 1] = "&"; i = i + 2
            else lit[#lit + 1] = n; i = i + 2 end
        else
            lit[#lit + 1] = c; i = i + 1
        end
    end
    flush()
    return parts
end

local Match = {}
Match.__index = Match

--- 找最左最长匹配(从 init 起, 1 起算)。返回 { s, e, caps } 或 nil。
function Match:find(s, init)
    local m = exec(self.prog, s, init or 1, false, self.nslots)
    if not m then return nil end
    return packMatch(m, self.ngroups)
end

--- 锚定在字符串开头的匹配(POSIX 的 "match"; expr 的 : 与 match 用它)。
function Match:match(s)
    local m = exec(self.prog, s, 1, true, self.nslots)
    if not m then return nil end
    return packMatch(m, self.ngroups)
end

--- 全部不重叠匹配(空匹配前进一格, 与 GNU grep -o 一致)。
function Match:findall(s)
    local out = {}
    local pos = 1
    while pos <= #s + 1 do
        local m = self:find(s, pos)
        if not m then break end
        out[#out + 1] = m
        pos = (m.e >= m.s) and (m.e + 1) or (m.s + 1)
    end
    return out
end

--- 替换。mode 决定替几处: true = 全部, nil/false = 只替第一个, 数字 = 只替第 n 次出现
--- (sed 的 s///g 与 s///N)。返回新串与替换次数。
function Match:sub(s, repl, mode)
    local parts = parseRepl(repl)
    local nth = (type(mode) == "number") and mode or nil
    local global = (mode == true)
    local out = {}
    local pos = 1
    local count = 0
    local idx = 0
    while true do
        local m = self:find(s, pos)
        if not m then break end
        idx = idx + 1
        local replace = (not nth) or (idx == nth)
        if replace then
            out[#out + 1] = s:sub(pos, m.s - 1)
            for _, pt in ipairs(parts) do
                if pt.lit then out[#out + 1] = pt.lit
                elseif pt.whole then out[#out + 1] = s:sub(m.s, m.e)
                elseif pt.ref == 0 then out[#out + 1] = s:sub(m.s, m.e)
                else
                    local c = m.caps[pt.ref]
                    out[#out + 1] = c and s:sub(c.s, c.e) or ""
                end
            end
            count = count + 1
        end
        if m.e >= m.s then
            if not replace then out[#out + 1] = s:sub(pos, m.e) end
            pos = m.e + 1
        else
            -- 空匹配: 替换时空位处插一次, 不替换时原样带过一个字符(与 sed s///g 一致)
            if replace then
                if m.s <= #s then out[#out + 1] = s:sub(m.s, m.s) end
            else
                out[#out + 1] = s:sub(pos, m.s)
            end
            pos = m.s + 1
        end
        if nth then
            if idx >= nth then break end
        elseif not global then break end
    end
    if pos <= #s then out[#out + 1] = s:sub(pos) end
    return table.concat(out), count
end

--- 编译一个模式。
---@param pat string 模式
---@param flavor string|nil "ere"(默认) | "bre"
---@param opts table|nil { icase = bool, word = bool, line = bool }
---@return table|nil matcher, string|nil err
function regex.compile(pat, flavor, opts)
    flavor = flavor or "ere"
    if flavor ~= "ere" and flavor ~= "bre" then
        return nil, "unknown regex flavor: " .. tostring(flavor)
    end
    opts = opts or {}
    local prog, err, ngroups = compile(pat, flavor, opts)
    if not prog then return nil, err end
    return setmetatable({
        prog = prog, ngroups = ngroups, nslots = ngroups * 2 + 2,
        pattern = pat, flavor = flavor,
    }, Match)
end

--- 注册 syscalls。用法:
---   local re, err = syscalls["regex.compile"](pattern, "ere"|"bre", { icase=, word=, line= })
---   re:find(text[, init]) / re:match(text) / re:findall(text) / re:sub(text, repl[, global])
function regex.registerSyscalls()
    local modules = require("kernel.modules")
    local s = modules.syscalls()
    s["regex.compile"] = function(pat, flavor, opts) return regex.compile(pat, flavor, opts) end
end

return regex
