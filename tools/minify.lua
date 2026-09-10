--[[ Delin Lua 压缩器 (去注释/去缩进/折叠空白 + 局部变量改名)。
     用法:
       lua5.1 tools/minify.lua [--keep-header] [--no-rename] [--stats] <in.lua> [out.lua]
       --keep-header  保留 .ko 的 --@ 元数据头(内核模块用; 其余注释一并丢掉)
       --no-rename    只去注释/空白, 不改名(诊断用)
     也可被 tools/build.lua 用 dofile 载入(返回 minify 表)。

     为什么需要**真正的语法分析**而不是正则/token 清洗:
     源码里到处是 `local args = args or {}` —— 右值 args 是**全局**(内核注入的 argv),
     左值是新局部。只按 token 改名会把它压成 `local a = a or {}`, 右值变成未定义全局
     (nil), 工具全崩。因此必须: 先解析初始化表达式, 再声明这个局部。

     做法(低风险):
       1. 词法分析 -> token 数组(注释保留在流里但带标记);
       2. 递归下降解析做**作用域分析**, 把每个名字 token 归类为
          "局部声明 / 局部引用 / 全局引用 / 字段名 / 标签", 并记录每个局部符号引用了哪些 token;
       3. 只给局部符号(参数/局部变量/for 变量/局部函数名)分配短名,
          然后**从 token 流输出**, 不重新打印语法树 —— 输出的 token 序列与输入逐项相同
          (注释除外, 改名处按映射比对), 由门禁 B 逐项验证。

     改名安全边界:
       - `_ENV`/`self`/`arg`/`__` 开头的名字不改(语义名);
       - 新名不得与**本 chunk 里出现的任何全局名**相同(否则遮蔽全局, 例: 把局部改名成 `fs`);
       - 新名不得与**祖先函数**已分配的新名相同(内层函数里外层变量是 upvalue);
       - 同一函数内不重名; 兄弟函数之间可以复用短名;
       - 单个函数内按 "原名字节数 × 出现次数" 从大到小分配, 最值得压的拿最短的名;
       - 字段名/标签/字符串不动(它们不在变量命名空间)。

     门禁(CLI 与 tools/build.lua 都会跑, 任何一条不过即 fail-fast):
       A. 产物能被宿主 lua5.1 解析(源码本身全部是 5.1 可解析的; 若源码用了 Lua 5.2 的
          goto/标签, 退回用宿主 luac5.4 -p 解析);
       B. 重新词法分析产物, 与原 token 序列逐项比对(这条门禁抓到过真 bug:
          长注释里的换行没计数 + `-- [x]` 被误判成长注释吞掉整段代码);
       C. 词法/语法遇到未知输入直接报错, 不猜不跳过。 ]]

local minify = {}

local loadchunk = loadstring or load

-- ===============================================================
-- 词法分析
-- ===============================================================

local KEYWORDS = {
    ["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true, ["elseif"]=true,
    ["end"]=true, ["false"]=true, ["for"]=true, ["function"]=true, ["goto"]=true,
    ["if"]=true, ["in"]=true, ["local"]=true, ["nil"]=true, ["not"]=true,
    ["or"]=true, ["repeat"]=true, ["return"]=true, ["then"]=true, ["true"]=true,
    ["until"]=true, ["while"]=true,
}

local function isDigit(c) return c >= "0" and c <= "9" end
local function isNameStart(c) return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" end
local function isNameChar(c) return isNameStart(c) or isDigit(c) end
local function isSpace(c) return c == " " or c == "\t" or c == "\n" or c == "\r" or c == "\v" or c == "\f" end
local function isHex(c) return isDigit(c) or (c >= "a" and c <= "f") or (c >= "A" and c <= "F") end

--- 读长括号 [==[ ... ]==]; i 必须**就是** `[` 的位置, 否则返回 nil。
--- 返回结束位置(指向末尾的 ]), 或 nil(不是长括号) / nil,err(未闭合)。
local function readLongBracket(src, i)
    if src:sub(i, i) ~= "[" then return nil end -- 必须真的是 `[`, 不能只看跳过 `=` 之后是不是 `[`
    local j = i + 1
    local level = 0
    while src:sub(j, j) == "=" do level = level + 1; j = j + 1 end
    if src:sub(j, j) ~= "[" then return nil end
    local close = "]" .. string.rep("=", level) .. "]"
    local e = src:find(close, j + 1, true)
    if not e then return nil, "unterminated long bracket" end
    return e + #close - 1
end

--- 词法分析。返回 { toks = {...} } 或 nil, err。
--- token: { t = "name"|"kw"|"number"|"string"|"op"|"comment"|"shebang", v = 原文, line = n, i = 序号 }
local function lex(src)
    local toks = {}
    local i, n = 1, #src
    local line = 1

    if src:sub(1, 1) == "#" then -- 首行 shebang(Lua 的 load 会跳过)
        local e = src:find("\n", 1, true) or (n + 1)
        toks[#toks + 1] = { t = "shebang", v = src:sub(1, e - 1), line = line }
        i = e
    end

    while i <= n do
        local c = src:sub(i, i)
        if c == "\n" then
            line = line + 1; i = i + 1
        elseif isSpace(c) then
            i = i + 1
        elseif c == "-" and src:sub(i + 1, i + 1) == "-" then
            local s = i
            local e = readLongBracket(src, i + 2)
            if e then
                i = e + 1
            else
                i = (src:find("\n", i, true) or (n + 1))
            end
            local raw = src:sub(s, i - 1)
            -- 跨行长注释里的换行必须计数, 否则后面所有报错行号一路错位
            line = line + select(2, raw:gsub("\n", ""))
            toks[#toks + 1] = { t = "comment", v = raw, line = line }
        elseif c == "[" and (src:sub(i + 1, i + 1) == "[" or src:sub(i + 1, i + 1) == "=") then
            local e, err = readLongBracket(src, i)
            if not e then return nil, err .. " at line " .. line end
            local raw = src:sub(i, e)
            toks[#toks + 1] = { t = "string", v = raw, line = line }
            line = line + select(2, raw:gsub("\n", ""))
            i = e + 1
        elseif c == '"' or c == "'" then
            local s = i
            i = i + 1
            while i <= n and src:sub(i, i) ~= c do
                if src:sub(i, i) == "\\" then
                    if src:sub(i + 1, i + 1) == "\n" then line = line + 1 end
                    i = i + 2
                else
                    i = i + 1
                end
            end
            if i > n then return nil, "unterminated string at line " .. line end
            i = i + 1
            toks[#toks + 1] = { t = "string", v = src:sub(s, i - 1), line = line }
        elseif isDigit(c) or (c == "." and isDigit(src:sub(i + 1, i + 1))) then
            local s = i
            if c == "0" and (src:sub(i + 1, i + 1) == "x" or src:sub(i + 1, i + 1) == "X") then
                i = i + 2
                while i <= n and (isHex(src:sub(i, i)) or src:sub(i, i) == ".") do i = i + 1 end
                local p = src:sub(i, i)
                if p == "p" or p == "P" then
                    i = i + 1
                    if src:sub(i, i) == "+" or src:sub(i, i) == "-" then i = i + 1 end
                    while i <= n and isDigit(src:sub(i, i)) do i = i + 1 end
                end
            else
                while i <= n and isDigit(src:sub(i, i)) do i = i + 1 end
                if src:sub(i, i) == "." then
                    i = i + 1
                    while i <= n and isDigit(src:sub(i, i)) do i = i + 1 end
                end
                local e = src:sub(i, i)
                if e == "e" or e == "E" then
                    local save = i
                    i = i + 1
                    if src:sub(i, i) == "+" or src:sub(i, i) == "-" then i = i + 1 end
                    if isDigit(src:sub(i, i)) then
                        while i <= n and isDigit(src:sub(i, i)) do i = i + 1 end
                    else
                        i = save
                    end
                end
            end
            toks[#toks + 1] = { t = "number", v = src:sub(s, i - 1), line = line }
        elseif isNameStart(c) then
            local s = i
            while i <= n and isNameChar(src:sub(i, i)) do i = i + 1 end
            local v = src:sub(s, i - 1)
            toks[#toks + 1] = { t = KEYWORDS[v] and "kw" or "name", v = v, line = line }
        else
            local three = src:sub(i, i + 2)
            local two = src:sub(i, i + 1)
            local op
            if three == "..." then op = three
            elseif two == ".." or two == "==" or two == "~=" or two == "<=" or two == ">="
                or two == "::" or two == "//" or two == "<<" or two == ">>" then op = two
            elseif c:match("[%+%-%*/%%%^#&~|<>=%(%){}%[%];:,%.]") then op = c
            else
                return nil, "unexpected character '" .. c .. "' at line " .. line
            end
            toks[#toks + 1] = { t = "op", v = op, line = line }
            i = i + #op
        end
    end

    for idx, tk in ipairs(toks) do tk.i = idx end
    return { toks = toks }
end

-- ===============================================================
-- 语法分析 + 作用域分析
-- ===============================================================

local function newFnScope(parent)
    local f = { parent = parent, symbols = {}, children = {}, n = 0 }
    if parent then parent.children[#parent.children + 1] = f end
    return f
end

local function newScope(parent, fn)
    return { syms = {}, parent = parent, fn = fn }
end

local parseExpr, parseExprList, parseTable, parseArgs, parseBlock, parseStatement, parseFunctionBody

local function parseError(p, msg)
    local tk = p.toks[p.pos] or { v = "<eof>", line = -1 }
    local ctx = {}
    for k = math.max(1, p.pos - 8), math.min(#p.toks, p.pos + 2) do
        ctx[#ctx + 1] = (k == p.pos) and ("<<" .. tostring(p.toks[k].v) .. ">>") or tostring(p.toks[k].v)
    end
    error(string.format("parse error at line %d near '%s': %s [附近: %s]",
        tk.line, tostring(tk.v), msg, table.concat(ctx, " ")), 0)
end

local function peek(p, k) return p.toks[p.pos + (k or 0)] end
local function cur(p) return p.toks[p.pos] end
local function isTok(p, t, v)
    local tk = cur(p)
    return tk ~= nil and tk.t == t and (v == nil or tk.v == v)
end
local function isOp(p, v) return isTok(p, "op", v) end
local function isKw(p, v) return isTok(p, "kw", v) end

local function advance(p)
    local tk = p.toks[p.pos]
    p.pos = p.pos + 1
    return tk
end

local function expectOp(p, v)
    if not isOp(p, v) then parseError(p, "expected '" .. v .. "'") end
    return advance(p)
end
local function expectKw(p, v)
    if not isKw(p, v) then parseError(p, "expected '" .. v .. "'") end
    return advance(p)
end
local function expectName(p)
    if not isTok(p, "name") then parseError(p, "expected a name") end
    return advance(p)
end

local function pushScope(p, fn)
    p.scope = newScope(p.scope, fn or (p.scope and p.scope.fn))
    return p.scope
end
local function popScope(p) p.scope = p.scope.parent end

local function declare(p, tk)
    local sym = { orig = tk.v, new = nil, tokens = { tk.i }, fn = p.scope.fn }
    p.scope.syms[tk.v] = sym
    p.symbols[#p.symbols + 1] = sym
    p.scope.fn.symbols[#p.scope.fn.symbols + 1] = sym
    return sym
end

local function reference(p, tk)
    local s = p.scope
    while s do
        local sym = s.syms[tk.v]
        if sym then
            sym.tokens[#sym.tokens + 1] = tk.i
            return sym
        end
        s = s.parent
    end
    p.globals[tk.v] = true
    return nil
end

local function markNonVar(p, tk) tk.field = true end

-- ---------------------------------------------------------------
-- 表达式
-- ---------------------------------------------------------------

local BINPRI = {
    ["or"]  = { 1, 1 }, ["and"] = { 2, 2 },
    ["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 }, [">="] = { 3, 3 },
    ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
    [".."] = { 5, 4 },  -- 右结合
    ["+"] = { 6, 6 }, ["-"] = { 6, 6 },
    ["*"] = { 7, 7 }, ["/"] = { 7, 7 }, ["%"] = { 7, 7 },
    ["^"] = { 10, 9 },  -- 右结合
}
local UNARY_PRI = 8

parseArgs = function(p)
    if isOp(p, "(") then
        advance(p)
        if not isOp(p, ")") then parseExprList(p) end
        expectOp(p, ")")
    elseif isOp(p, "{") then
        parseTable(p)
    elseif isTok(p, "string") then
        advance(p)
    else
        parseError(p, "expected arguments")
    end
end

local function parseSuffixedExpr(p)
    if isOp(p, "(") then
        advance(p)
        parseExpr(p, 0)
        expectOp(p, ")")
    elseif isTok(p, "name") then
        reference(p, advance(p))
    else
        parseError(p, "expected an expression")
    end
    while true do
        if isOp(p, ".") then
            advance(p)
            markNonVar(p, expectName(p))
        elseif isOp(p, "[") then
            advance(p)
            parseExpr(p, 0)
            expectOp(p, "]")
        elseif isOp(p, ":") then
            advance(p)
            markNonVar(p, expectName(p))
            parseArgs(p)
        elseif isOp(p, "(") or isOp(p, "{") or isTok(p, "string") then
            parseArgs(p)
        else
            return
        end
    end
end

parseTable = function(p)
    expectOp(p, "{")
    while not isOp(p, "}") do
        if isOp(p, "[") then
            advance(p)
            parseExpr(p, 0)
            expectOp(p, "]")
            expectOp(p, "=")
            parseExpr(p, 0)
        elseif isTok(p, "name") and peek(p, 1) and peek(p, 1).t == "op" and peek(p, 1).v == "=" then
            markNonVar(p, advance(p)) -- { name = exp } 的 name 是字段名, 不是变量
            advance(p)
            parseExpr(p, 0)
        else
            parseExpr(p, 0)
        end
        if isOp(p, ",") or isOp(p, ";") then advance(p) else break end
    end
    expectOp(p, "}")
end

parseFunctionBody = function(p, isMethod)
    local fn = newFnScope(p.scope.fn)
    p.scope = newScope(p.scope, fn)
    if isMethod then
        -- 方法隐式 self 参数: 不参与改名, 但要登记, 免得 self 被当成全局。
        p.scope.syms["self"] = { orig = "self", tokens = {}, fn = fn, implicit = true }
    end
    expectOp(p, "(")
    if not isOp(p, ")") then
        while true do
            if isTok(p, "name") then
                declare(p, advance(p))
            elseif isOp(p, "...") then
                advance(p)
                break
            else
                parseError(p, "expected a parameter name")
            end
            if isOp(p, ",") then advance(p) else break end
        end
    end
    expectOp(p, ")")
    parseBlock(p)
    expectKw(p, "end")
    p.scope = p.scope.parent
end

local function parseSimpleExpr(p)
    local tk = cur(p)
    if not tk then parseError(p, "unexpected end of input") end
    if tk.t == "number" or tk.t == "string" then
        advance(p)
    elseif tk.t == "kw" and (tk.v == "nil" or tk.v == "true" or tk.v == "false") then
        advance(p)
    elseif isOp(p, "...") then
        advance(p)
    elseif isKw(p, "function") then
        advance(p)
        parseFunctionBody(p, false)
    elseif isOp(p, "{") then
        parseTable(p)
    else
        parseSuffixedExpr(p)
    end
end

parseExpr = function(p, limit)
    local tk = cur(p)
    if tk and ((tk.t == "kw" and tk.v == "not") or (tk.t == "op" and (tk.v == "-" or tk.v == "#"))) then
        advance(p)
        parseExpr(p, UNARY_PRI)
    else
        parseSimpleExpr(p)
    end
    while true do
        local op = cur(p)
        if not op or (op.t ~= "op" and op.t ~= "kw") then break end
        local pri = BINPRI[op.v]
        if not pri or pri[1] <= limit then break end
        advance(p)
        parseExpr(p, pri[2])
    end
end

parseExprList = function(p)
    while true do
        parseExpr(p, 0)
        if isOp(p, ",") then advance(p) else break end
    end
end

-- ---------------------------------------------------------------
-- 语句
-- ---------------------------------------------------------------

local function parseFuncName(p)
    reference(p, expectName(p)) -- function a.b() 里的 a 是变量引用
    while isOp(p, ".") do
        advance(p)
        markNonVar(p, expectName(p))
    end
    if isOp(p, ":") then
        advance(p)
        markNonVar(p, expectName(p))
        return true
    end
    return false
end

local function atBlockEnd(p)
    local tk = cur(p)
    return tk ~= nil and tk.t == "kw"
        and (tk.v == "end" or tk.v == "else" or tk.v == "elseif" or tk.v == "until")
end

parseBlock = function(p)
    while true do
        local tk = cur(p)
        if not tk or atBlockEnd(p) then break end
        if isKw(p, "return") then
            advance(p)
            if not (atBlockEnd(p) or isOp(p, ";") or not cur(p)) then parseExprList(p) end
            if isOp(p, ";") then advance(p) end
            break
        end
        parseStatement(p)
    end
end

parseStatement = function(p)
    if isOp(p, ";") then
        advance(p)
    elseif isKw(p, "if") then
        advance(p)
        parseExpr(p, 0)
        expectKw(p, "then")
        pushScope(p); parseBlock(p); popScope(p)
        while isKw(p, "elseif") do
            advance(p)
            parseExpr(p, 0)
            expectKw(p, "then")
            pushScope(p); parseBlock(p); popScope(p)
        end
        if isKw(p, "else") then
            advance(p)
            pushScope(p); parseBlock(p); popScope(p)
        end
        expectKw(p, "end")
    elseif isKw(p, "while") then
        advance(p)
        parseExpr(p, 0)
        expectKw(p, "do")
        pushScope(p); parseBlock(p); popScope(p)
        expectKw(p, "end")
    elseif isKw(p, "do") then
        advance(p)
        pushScope(p); parseBlock(p); popScope(p)
        expectKw(p, "end")
    elseif isKw(p, "for") then
        advance(p)
        local first = expectName(p)
        if isOp(p, "=") then
            advance(p)
            parseExpr(p, 0); expectOp(p, ","); parseExpr(p, 0)
            if isOp(p, ",") then advance(p); parseExpr(p, 0) end
            expectKw(p, "do")
            pushScope(p)
            declare(p, first)
            parseBlock(p)
            popScope(p)
            expectKw(p, "end")
        else
            local names = { first }
            while isOp(p, ",") do advance(p); names[#names + 1] = expectName(p) end
            expectKw(p, "in")
            parseExprList(p)
            expectKw(p, "do")
            pushScope(p)
            for _, tk in ipairs(names) do declare(p, tk) end
            parseBlock(p)
            popScope(p)
            expectKw(p, "end")
        end
    elseif isKw(p, "repeat") then
        advance(p)
        pushScope(p)
        parseBlock(p)
        expectKw(p, "until")
        parseExpr(p, 0) -- until 的条件在块作用域内(能看到块里的局部)
        popScope(p)
    elseif isKw(p, "function") then
        advance(p)
        local isMethod = parseFuncName(p)
        parseFunctionBody(p, isMethod)
    elseif isKw(p, "local") then
        advance(p)
        if isKw(p, "function") then
            advance(p)
            declare(p, expectName(p)) -- 先声明, 函数体里可递归
            parseFunctionBody(p, false)
        else
            local names = { expectName(p) }
            while isOp(p, ",") do advance(p); names[#names + 1] = expectName(p) end
            if isOp(p, "=") then
                advance(p)
                parseExprList(p) -- 先解析右值: `local x = x` 的右值 x 是外层/全局
            end
            for _, tk in ipairs(names) do declare(p, tk) end
        end
    elseif isKw(p, "return") then
        advance(p)
        if not (atBlockEnd(p) or isOp(p, ";") or not cur(p)) then parseExprList(p) end
        if isOp(p, ";") then advance(p) end
    elseif isKw(p, "break") then
        advance(p)
    elseif isKw(p, "goto") then
        advance(p)
        markNonVar(p, expectName(p))
    elseif isOp(p, "::") then
        advance(p)
        markNonVar(p, expectName(p))
        expectOp(p, "::")
    else
        parseSuffixedExpr(p)
        if isOp(p, "=") or isOp(p, ",") then
            while isOp(p, ",") do advance(p); parseSuffixedExpr(p) end
            expectOp(p, "=")
            parseExprList(p)
        end
    end
end

-- ---------------------------------------------------------------
-- 改名
-- ---------------------------------------------------------------

local function renamable(sym)
    local n = sym.orig
    if sym.implicit then return false end
    if n == "_ENV" or n == "self" or n == "arg" then return false end
    if n:sub(1, 2) == "__" then return false end
    return true
end

--- 生成候选短名: a..z, a1..z1, a2.. (只保证在给定禁止集内不重名)
local function nextCandidate(state, forbidden)
    while true do
        local k = state.n
        state.n = state.n + 1
        local name
        if k < 26 then
            name = string.char(97 + k)
        else
            local m = k - 26
            name = string.char(97 + (m % 26)) .. tostring(math.floor(m / 26) + 1)
        end
        if not forbidden[name] then return name end
    end
end

--- 解析整个 chunk。
---@return table|nil plan { renames = {tokenIndex -> newName}, globals, symbols, rootFn }
local function analyze(toks)
    local p = { toks = toks, pos = 1, symbols = {}, globals = {}, fnState = {} }
    p.rootFn = newFnScope(nil)
    p.scope = newScope(nil, p.rootFn)
    parseBlock(p)
    if p.pos <= #toks then parseError(p, "unconsumed token: " .. tostring(p.toks[p.pos].v)) end

    -- 基础禁止集: 关键字 + 本 chunk 出现的全局名 + 语义名 + 不改名符号的原名
    local base = {}
    for k in pairs(KEYWORDS) do base[k] = true end
    for k in pairs(p.globals) do base[k] = true end
    base["_ENV"] = true; base["self"] = true; base["arg"] = true
    for _, sym in ipairs(p.symbols) do
        if not renamable(sym) then base[sym.orig] = true end
    end

    local renames = {}
    local function walk(fn, inherited)
        -- 同一函数内先按"原名字节数 × 出现次数"降序分配: 最值得压的拿最短的名
        local syms = {}
        for _, s in ipairs(fn.symbols) do
            if renamable(s) then syms[#syms + 1] = s end
        end
        table.sort(syms, function(a, b)
            local sa = #a.orig * #a.tokens
            local sb = #b.orig * #b.tokens
            if sa ~= sb then return sa > sb end
            return a.orig < b.orig
        end)
        local forb = {}
        for k in pairs(inherited) do forb[k] = true end
        local state = fn
        for _, sym in ipairs(syms) do
            local name = nextCandidate(state, forb)
            forb[name] = true
            sym.new = name
            for _, ti in ipairs(sym.tokens) do
                if ti > 0 then renames[ti] = name end
            end
        end
        -- 子函数: 继承 base + 本函数已占用的名字(内层里这些是 upvalue)
        for _, child in ipairs(fn.children) do
            local childForb = {}
            for k in pairs(base) do childForb[k] = true end
            for k in pairs(forb) do childForb[k] = true end
            walk(child, childForb)
        end
    end
    local rootForb = {}
    for k in pairs(base) do rootForb[k] = true end
    walk(p.rootFn, rootForb)

    return { renames = renames, globals = p.globals, symbols = p.symbols }
end

-- ===============================================================
-- 输出
-- ===============================================================

local function isWordChar(c) return c ~= nil and c ~= "" and isNameChar(c) end

--- 两个 token 直接相邻会不会改变词法(需要插一个空格)?
local function needSpace(a, b)
    local av, bv = a.v, b.v
    local alast = av:sub(-1)
    local bfirst = bv:sub(1, 1)
    if isWordChar(alast) and isWordChar(bfirst) then return true end            -- `1 and` / `local x`
    if a.t == "number" and bfirst == "." then return true end                  -- `1 .. 2` 不能拼成 `1..2`
    if alast == "-" and bfirst == "-" then return true end                     -- 会变注释
    if alast == "." and bfirst == "." then return true end                     -- 会变 `...`
    if alast == "[" and (bfirst == "[" or bfirst == "=") then return true end  -- 会变长括号
    if alast == ":" and bfirst == ":" then return true end                     -- 会变标签
    return false
end

--- 从 token 流生成压缩源码。from = 起始 token 序号(1 起, 用于跳过已被提取的头部注释)。
local function emit(toks, renames, opts)
    opts = opts or {}
    local out = {}
    local prev = nil
    for idx = opts.from or 1, #toks do
        local tk = toks[idx]
        if tk.t ~= "comment" and not (tk.t == "shebang" and not opts.keepShebang) then
            local text = renames[tk.i] or tk.v
            if prev and needSpace(prev, { v = text, t = tk.t }) then out[#out + 1] = " " end
            out[#out + 1] = text
            prev = { v = text, t = tk.t }
        end
    end
    return table.concat(out)
end

-- ===============================================================
-- 门禁
-- ===============================================================

--- 提取内核模块的元数据头。modules.lua 的 parseMeta 是**逐行静态解析**: 从第 1 行起跳过
--- 空行/注释行, 遇到第一个非注释行就停; 只认 `--@name/--@version/--@author/--@deps/--@description`。
--- 因此这里只保留开头连续的 `--@...` 注释行(其余描述性注释, 含跨行长注释, 全部丢掉) ——
--- 既保证元数据不变, 又不会把长注释切断。
--- 必须先用词法器识别注释 token: `.ko` 的头部常是多行 `--[[ ]]`, 按行切会切进注释内部。
---@return string|nil header, number bodyStart(1 起的 token 序号)
local function extractMetaHeader(toks)
    local header = {}
    local bodyStart = #toks + 1
    for idx, tk in ipairs(toks) do
        if tk.t == "comment" then
            if tk.v:match("^%-%-@") then header[#header + 1] = tk.v end
        else
            bodyStart = idx
            break
        end
    end
    if #header == 0 then return nil, 1 end
    return table.concat(header, "\n") .. "\n", bodyStart
end

--- 门禁 B: 重新词法分析产物, 与原 token 序列逐项比对。
local function checkTokens(toks, renames, from, outSrc)
    local re, lerr = lex(outSrc)
    if not re then return nil, "输出无法词法分析: " .. tostring(lerr) end
    local outToks = {}
    for _, tk in ipairs(re.toks) do
        if tk.t ~= "comment" and tk.t ~= "shebang" then outToks[#outToks + 1] = tk end
    end
    local k = 0
    for idx = from, #toks do
        local tk = toks[idx]
        if tk.t ~= "comment" and tk.t ~= "shebang" then
            k = k + 1
            local o = outToks[k]
            if not o then return nil, "输出 token 少于输入(第 " .. k .. " 个: " .. tk.v .. ")" end
            local want = renames[tk.i] or tk.v
            if o.t ~= tk.t or o.v ~= want then
                return nil, string.format("token %d 不一致: 期望 '%s'(%s) 实得 '%s'(%s)",
                    k, want, tk.t, o.v, o.t)
            end
        end
    end
    if #outToks ~= k then return nil, "输出 token 多于输入" end
    return true
end

--- 门禁 A: 产物语法。宿主进程是 lua5.1, 它不认识 goto/标签(5.2 语法) —— 遇到就改用
--- luac5.4 -p 做外部门禁。两条都做不到就 fail-fast, 不放行未经验证的产物。
local function syntaxOk(toks, src)
    if loadchunk(src, "@minify") then return true end
    local hasGoto = false
    for _, tk in ipairs(toks) do
        if (tk.t == "kw" and tk.v == "goto") or (tk.t == "op" and tk.v == "::") then hasGoto = true; break end
    end
    if not hasGoto then return false end
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb"); f:write(src); f:close()
    local rc = os.execute("luac5.4 -p " .. tmp .. " >/dev/null 2>&1")
    os.remove(tmp)
    return rc == true or rc == 0
end

--- 压缩一段源码(完整门禁)。
---@param src string 源码
---@param opts table|nil { keepHeader = bool, keepShebang = bool, noRename = bool }
---@return string|nil, string|nil, table|nil  (out, err, stats)
function minify.source(src, opts)
    opts = opts or {}

    local lx, lerr = lex(src)
    if not lx then return nil, "词法错误: " .. tostring(lerr) end

    local header, bodyStart = nil, 1
    if opts.keepHeader then
        header, bodyStart = extractMetaHeader(lx.toks)
        if not header then return nil, "模块源码没有 --@ 元数据头(name/version/deps), 拒绝压缩" end
    end

    -- 解析只看正文的非注释 token(注释在 emit 阶段才被丢掉; tk.i 仍指向完整流的序号)。
    local parseToks = {}
    for idx = bodyStart, #lx.toks do
        local tk = lx.toks[idx]
        if tk.t ~= "comment" then parseToks[#parseToks + 1] = tk end
    end
    local ok, plan = pcall(analyze, parseToks)
    if not ok then return nil, "分析错误: " .. tostring(plan) end
    if opts.noRename then plan.renames = {} end -- 诊断用: 只去注释/空白, 不改名

    local out = emit(lx.toks, plan.renames, { keepShebang = opts.keepShebang, from = bodyStart })
    local okTok, cerr = checkTokens(lx.toks, plan.renames, bodyStart, out)
    if not okTok then return nil, "自检失败: " .. tostring(cerr) end

    local full = (header or "") .. out
    if not syntaxOk(lx.toks, full) then
        return nil, "产物语法错误: " .. tostring(select(2, loadchunk(full, "@minify")))
    end

    local nRenamed, nGlobal = 0, 0
    for _ in pairs(plan.globals) do nGlobal = nGlobal + 1 end
    for _, sym in ipairs(plan.symbols) do if sym.new then nRenamed = nRenamed + 1 end end
    return full, nil, {
        inBytes = #src, outBytes = #full,
        symbols = #plan.symbols, renamed = nRenamed, globals = nGlobal,
    }
end

-- CLI ----------------------------------------------------------

local function readAll(path)
    local f = assert(io.open(path, "rb"), "cannot open " .. path)
    local c = f:read("*a"); f:close()
    return c
end

local function writeAll(path, s)
    local f = assert(io.open(path, "wb"))
    f:write(s); f:close()
end

function minify.main(argv)
    local keepHeader, statsOnly, noRename, files = false, false, false, {}
    for i = 1, #(argv or {}) do
        local a = argv[i]
        if a == "--keep-header" then keepHeader = true
        elseif a == "--stats" then statsOnly = true
        elseif a == "--no-rename" then noRename = true
        else files[#files + 1] = a end
    end
    local inPath = files[1]
    if not inPath then
        io.stderr:write("usage: lua5.1 tools/minify.lua [--keep-header] [--no-rename] [--stats] <in.lua> [out.lua]\n")
        os.exit(2)
    end
    local out, err, stats = minify.source(readAll(inPath), { keepHeader = keepHeader, noRename = noRename })
    if not out then
        io.stderr:write(inPath .. ": " .. tostring(err) .. "\n")
        os.exit(1)
    end
    if not statsOnly then writeAll(files[2] or (inPath .. ".min"), out) end
    io.stdout:write(string.format("%-44s %7d -> %7d (-%d%%)  symbols=%d renamed=%d globals=%d\n",
        inPath, stats.inBytes, stats.outBytes,
        math.floor(100 - 100 * stats.outBytes / stats.inBytes),
        stats.symbols, stats.renamed, stats.globals))
    os.exit(0)
end

if arg and arg[0] and arg[0]:match("minify%.lua$") then
    minify.main(arg)
end

-- 供测试/调试使用的内部入口(不改语义)。
minify.lex = lex
minify.emit = emit
minify.analyze = analyze
minify.extractMetaHeader = extractMetaHeader
minify.checkTokens = checkTokens

return minify
