-- Delin sh: POSIX-ish shell (core subset).
-- 交互/脚本模式; 内建 cd pwd echo exit help jobs fg bg kill test [ true false :.
-- 支持: 变量与展开($x/${x}/$?/$#/$@/$*/$1..), 单/双引号, 命令替换($() 与反引号),
--       算术展开 $(( )), 路径名展开(通配符 * ? [ ]), if/elif/else, for/while/until,
--       case, 函数, [ ] 与 test, &&/||/;, 文件重定向(> >> <), 管道(|), 命令后台(& + 作业控制)。
-- 不支持: here-doc(<<)、`( list )` 子 shell 分组。case 的模式是**通配符**(POSIX 模式匹配),
--         不是正则; 正则交给 grep/sed/ed/expr(标准 POSIX BRE/ERE, 见 kernel/regex.lua)。
-- 输出走 io.stdout(父进程把它指向控制台 tty 或文件), 绝不 print(kprint 走日志+term)。

local msleep = os.msleep or function(ms) os.sleep(math.max(ms / 1000, 0.05)) end
-- 让出调度器: 时间片式(不按字节让出), 时间片见 _sliceMs(默认 50ms, 可用 DELIN_YIELD_MS 调)。
-- 让出时间片(ms)。**默认 50**: 实测电脑 #3 上一次让出 `os.msleep(0)` 要 ~75ms(不是文档里
-- 说的 2ms —— 那块 HSE 外设的 waitNextTick 实际按游戏刻返回), 让出太勤会把命令拖到 ~1 行/拍。
-- 真·HSE 快让出(每次 ~2ms)的机器可以用环境变量把时间片调小(如 DELIN_YIELD_MS=2):
-- 那是"低延迟换吞吐"的取舍, 由使用者定。见 for-ai.md「os.msleep 与 HSE」。
local _sliceMs = (type(env) == "table" and tonumber(env.DELIN_YIELD_MS)) or 50
-- 轮询间隔(等子进程/等条件): HSE 下 5ms, 否则 50ms —— os.sleep 的量化下限就是 50ms。
local _pollMs = (type(env) == "table" and tonumber(env.DELIN_POLL_MS)) or 50
local _sliceAt = os.epoch("utc")
-- ---------------------------------------------------------------
-- **为什么核心是整个一个函数 + 一张 F 表**(别改回"一堆顶层 local"):
--   CC 的 Lua(Cobalt)对局部变量的计数与宿主 Lua 不同: Parser.newLocal 拿
--   `activeVariableSize + 1` 与 LUAI_MAXVARS(200) 比, 而 activeVariableSize 是
--   **当前函数 + 所有祖先函数**的活动局部之和 —— 也就是"沿嵌套链累加"。
--   后果: 一段有 ~196 个顶层 local 的 chunk 本来侥幸能装载(宿主 lua5.1/5.4 每个函数
--   200 个名额各自独立, 永远看不出来), 但只要再加**一个** local(哪怕只是一个 helper
--   函数), 内层函数一多就在真机上炸:
--       load failed: function at line N has more than 200 local variables
--   而 shell 只显示成 "/bin/sh: nil" —— 实测踩过: 给 spawnChild 加一个 spawnErr helper
--   就把 /bin/sh 自己弄成装载失败, 于是 init 的每个服务都起不来(症状看着像内核坏了)。
--   修法就是这里的两条:
--     1) 整段核心包成一个函数(shCoreMain): chunk 只剩 3 个 local, 核心的局部变量落在
--        函数作用域里;
--     2) 核心的**函数**一律是 F 表的字段(`function F.foo`), 表字段不占局部变量名额 ——
--        这一步把最坏嵌套链从 246 降到 ~150(上限 200)。
--   构建期门禁 tools/minify.lua 的 checkLocalBudget + build.lua 的 localGate 会按同一套
--   算法拦住超限(src/bin + src/lib 都扫), 所以"宿主全绿、真机装载失败"不会再溜出去。
--   **新增 helper 请写进 F 表**(`function F.name(...)`), 别写 `local function name(...)`。
-- ---------------------------------------------------------------
local function shCoreMain(ui, S)
local F = {}

function F.schedYield()
    local now = os.epoch("utc")
    if now - _sliceAt >= _sliceMs then
        _sliceAt = now
        msleep(0)
    end
end

local stdin  = io.stdin()
local stdout = io.stdout()

-- shell 名(报错前缀与 PS1 的 \s): 由入口经 shCoreMain(ui, ...) 指定; 没人指定时是 "sh"。
local shName = (ui and ui.name) or "sh"

-- 前端钩子表(desh 的行编辑器/纠错)。sh 传 nil —— 于是核心的经典行为一行不变。
-- 只放"核心做不到、必须由前端提供"的东西; 补全/历史/着色全在前端自己那边。
local UI = ui

-- 当前用户(passwd 记录): $USER/$HOME/$SHELL 的缺省来源。
local uinfo = nil
if syscalls and syscalls["user.byUid"] then uinfo = syscalls["user.byUid"](uid) end
local uname = (uinfo and uinfo.name) or "root"
local lastExit = 0
local lastBgPid = nil -- $! : 最近一个后台作业的 pid

-- 起始工作目录 = **内核里这个进程的 cwd**(/proc/self/cwd, Linux 的 getcwd 等价物)。
-- 不能拿 $HOME 当 cwd: 子 shell(`&` 的作业、`$( )` 命令替换)是**新进程**, 内核已把父 shell 的
-- cwd 继承给它, 而按 HOME 初始化会让它跑到别处去 —— `cd /tmp; echo $(ls *.txt)` 会静默列出
-- /root 下的东西。读不到(/proc 未挂载等)才退回 HOME。
function F.initialCwd()
    local f = fs.open("/proc/self/cwd", "r")
    if f then
        local l = (f.readLine and f:readLine()) or ""
        f:close()
        l = l:gsub("%s+$", "")
        if l ~= "" and fs.isDir(l) then return l end
    end
    if uinfo and uinfo.home and fs.isDir(uinfo.home) then return uinfo.home end
    return "/"
end
local cwd = F.initialCwd()

-- 父进程导出的环境块(内核注入的全局 env 表)。startup 变量的优先级:
-- 继承的环境 > passwd/内核信息 > 内置缺省(与 login(1) 先设 USER/HOME/SHELL 再起 sh 一致)。
local inherited = (type(env) == "table") and env or {}
function F.initVar(name, default)
    local v = inherited[name]
    if v ~= nil then return tostring(v) end
    return default
end

-- 位置参数(顶层脚本 argv; 函数体用独立 pos 表)。
local posArgs, posArg0 = {}, "sh"
function F.setPos(argv)
    posArg0 = (argv and argv[0]) or shName
    posArgs = {}
    if argv then for i = 1, #argv do posArgs[i] = argv[i] end end
end

local vars = {
    IFS = " \t\n", -- IFS 是真正的 shell 变量(POSIX 默认空白; 置空则不分割)
    PATH = F.initVar("PATH", "/bin"),
    HOME = F.initVar("HOME", (uinfo and uinfo.home) or "/root"),
    USER = F.initVar("USER", uname),
    LOGNAME = F.initVar("LOGNAME", uname),
    SHELL = F.initVar("SHELL", (uinfo and uinfo.shell) or "/bin/sh"),
    PPID = tostring(ppid or 0), -- 内核给的父 pid(子 shell 也重新取, 不继承环境里的 PPID)
    PWD = cwd, -- shell 维护: cd 后同步(见 builtins.cd)
    TERM = F.initVar("TERM", "linux"), -- 终端类型: Delin tty 是 16 色 ANSI 终端(login 也设这个)
    PS1 = F.initVar("PS1", "\\u@\\h:\\w\\$ "),
    PS2 = F.initVar("PS2", "> "),
    PS3 = F.initVar("PS3", "#? "),
    PS4 = F.initVar("PS4", "+ "),
}
-- 导出标记(export): 名字 -> true。只有被标记的变量经内核环境块传给子进程。
local exported = {
    PATH = true, HOME = true, USER = true, LOGNAME = true, SHELL = true, PWD = true, PPID = true,
    TERM = true, -- $TERM 必须传给程序(终端能力协商), 与真实 shell 一致
}
-- POSIX: 继承来的环境变量一律成为**已导出的 shell 变量**(`env FOO=bar sh -c 'echo $FOO'` 必须
-- 打印 bar)。上面那张表只是"缺省值", 这里把父进程给的其余名字补进 vars —— 已经存在的名字
-- (IFS/PS1/PWD... 由本 shell 自己维护)不改, 免得环境里的同名值把 shell 的内部状态顶掉。
for name, v in pairs(inherited) do
    if vars[name] == nil then vars[name] = tostring(v) end
    exported[name] = true
end
-- 导出给子进程的环境块(内核 env 表): 只有 export 标记过且已赋值的变量。
function F.exportEnv()
    local out = {}
    for name in pairs(exported) do
        local v = vars[name]
        if v ~= nil then out[name] = v end
    end
    return out
end
-- shell 选项(set -e/-u/-v/-x)。定义在词法之前: $- 与 nounset 检查都要读它。
local opt = { errexit = false, nounset = false, verbose = false, xtrace = false }
function F.optString()
    local s = ""
    if opt.errexit then s = s .. "e" end
    if opt.nounset then s = s .. "u" end
    if opt.verbose then s = s .. "v" end
    if opt.xtrace then s = s .. "x" end
    return s
end
-- 求值期致命错误(set -u 未定义变量)由 nounsetCheck 在命令执行前发现并返回 "exit" 控制。
local funcSrcs = {} -- 函数名 -> 定义原文(后台子 shell 注入用)

-- 规范化绝对路径: 折叠 . / .. , 去掉多余斜杠(相对路径以 cwd 起)。
function F.resolve(p)
    p = p or ""
    if p == "" then return "/" end
    local base
    if p:sub(1, 1) == "/" then base = "" else base = (cwd == "/") and "" or cwd end
    local full = (base .. "/" .. p):gsub("/+", "/")
    local stack = {}
    for seg in full:gmatch("[^/]+") do
        if seg == "." then -- 跳过
        elseif seg == ".." then stack[#stack] = nil
        else stack[#stack + 1] = seg end
    end
    if #stack == 0 then return "/" end
    return "/" .. table.concat(stack, "/")
end

-- 脚本文件检测: `sh [args...] <script> [args...]`。shebang 解释器调用 sh 时 argv[1]=脚本路径,
-- 因此本分支兼作"以解释器运行脚本"的入口 —— 非交互读取该脚本文件。
-- `sh -c '命令' [name [args...]]`: 直接执行命令行(POSIX 2.5.3; 后台作业 `&` 的子 shell 走这里)。
local scriptPath, scriptArgs = nil, {}
local cmdString, cmdName, cmdArgs = nil, nil, {}
local argErr = nil
if argv and #argv >= 1 then
    local idx = 1
    while argv[idx] and argv[idx]:sub(1, 1) == "-" and argv[idx] ~= "-" and argv[idx] ~= "--" do
        if argv[idx] == "-c" then
            cmdString = argv[idx + 1]
            if not cmdString then argErr = shName .. ": -c: option requires an argument" end
            cmdName = argv[idx + 2]
            for i = idx + 3, #argv do cmdArgs[#cmdArgs + 1] = argv[i] end
            idx = #argv + 1
            break
        end
        idx = idx + 1
    end
    if not cmdString and not argErr then
        if argv[idx] == "--" then idx = idx + 1 end
        if argv[idx] then
            local cand = F.resolve(argv[idx])
            if fs.exists(cand) and fs.isFile(cand) then
                scriptPath = cand
                for i = idx + 1, #argv do scriptArgs[#scriptArgs + 1] = argv[i] end
            end
        end
    end
end
if scriptPath then
    posArg0 = scriptPath
    posArgs = scriptArgs
elseif cmdString then
    posArg0 = cmdName or shName
    posArgs = cmdArgs
elseif argv then
    F.setPos(argv)
end

local outH, inH = stdout, stdin
function F.outln(s)
    if outH and outH.write then outH:write(tostring(s or "") .. "\n") end
end
function F.errln(s)
    local e = io.stderr()
    if e and e.write then e:write(tostring(s or "") .. "\n") end
end
-- set -v(verbose): 回显命令原文到 stderr(POSIX)。Delin 一次性读入整段源码, 所以按"执行时回显"。
function F.outVerbose(s)
    local e = io.stderr()
    if e and e.write then
        e:write(tostring(s or ""))
        if tostring(s or ""):sub(-1) ~= "\n" then e:write("\n") end
    end
end
if argErr then F.errln(argErr); return 2 end

-- 运行脚本文件/命令行时不做交互(不读 tty): stdin 仍可能是终端(被父 sh 继承)。
local interactive = stdin and stdin.isTTY and not scriptPath and not cmdString

-- IFS 是真正的 shell 变量(未设置时默认空白); 未加引号的展开与 `read` 都按它分割。
function F.curIFS()
    local v = vars.IFS
    if v == nil then return " \t\n" end
    return v
end
function F.isIfs(c) return F.curIFS():find(c, 1, true) ~= nil end
function F.isIfsWs(c) return (c == " " or c == "\t" or c == "\n") and F.isIfs(c) end
function F.splitIfs(s)
    if not s or s == "" then return {} end
    local out, cur, started = {}, "", false
    for k = 1, #s do
        local c = s:sub(k, k)
        if F.isIfs(c) then if started then out[#out + 1] = cur; cur = ""; started = false end
        else cur = cur .. c; started = true end
    end
    if started then out[#out + 1] = cur end
    return out
end

function F.getVarVal(name)
    if name == "?" then return tostring(lastExit) end
    if name == "#" then return tostring(#posArgs) end
    if name == "$" then return tostring(pid) end
    if name == "!" then return lastBgPid and tostring(lastBgPid) or "" end
    if name == "0" then return posArg0 end
    if name == "-" then return F.optString() end
    if name == "*" then return table.concat(posArgs, " ") end
    if name == "@" then return table.concat(posArgs, " ") end
    local n = tonumber(name)
    if n then return posArgs[n] or "" end
    return vars[name] or ""
end
-- 变量是否已赋值(set -u 判定用)。特殊参数/位置参数按是否真的有值算。
function F.isVarSet(name)
    if name == "?" or name == "#" or name == "$" or name == "0" or name == "-" or name == "*" or name == "@" then
        return true
    end
    if name == "!" then return lastBgPid ~= nil end
    local n = tonumber(name)
    if n then return posArgs[n] ~= nil end
    return vars[name] ~= nil
end

-- ---------------------------------------------------------------
-- 词法
-- ---------------------------------------------------------------
local operatorChars = { ["&"]=true, [";"]=true, ["|"]=true, ["("]=true, [")"]=true, [">"]=true, ["<"]=true }
function F.readVarName(src, i)
    local c = src:sub(i, i)
    if c == "{" then
        local j, name = i + 1, ""
        while j <= #src and src:sub(j, j) ~= "}" do name = name .. src:sub(j, j); j = j + 1 end
        if j > #src then return nil, i end
        return name, j + 1
    end
    if c == "?" then return "?", i + 1 end
    if c == "-" then return "-", i + 1 end
    if c == "#" then return "#", i + 1 end
    if c == "!" then return "!", i + 1 end
    if c == "@" then return "@", i + 1 end
    if c == "*" then return "*", i + 1 end
    if c == "$" then return "$", i + 1 end
    if c:match("[%d]") then return c, i + 1 end
    if c:match("[%a_]") then
        local j, name = i, ""
        while j <= #src and src:sub(j, j):match("[%w_]") do name = name .. src:sub(j, j); j = j + 1 end
        return name, j
    end
    return nil, i
end

-- ---------------------------------------------------------------
-- 复合替换的原文扫描($( ) / ` ` / $(( )))
-- ---------------------------------------------------------------
-- 命令替换 $( ): i 指向 '(' 之后。返回 原文, 结束位置(闭括号之后); 未闭合返回 nil。
-- 需按引号/转义/嵌套括号扫描: `$(echo ')')` 里的 ')' 不是收尾。
function F.scanCmdSub(src, i)
    local depth, j, n = 1, i, #src
    while j <= n do
        local c = src:sub(j, j)
        if c == "\\" then j = j + 2
        elseif c == "'" then
            j = j + 1
            while j <= n and src:sub(j, j) ~= "'" do j = j + 1 end
            j = j + 1
        elseif c == '"' then
            j = j + 1
            while j <= n and src:sub(j, j) ~= '"' do
                if src:sub(j, j) == "\\" then j = j + 1 end
                j = j + 1
            end
            j = j + 1
        elseif c == "(" then depth = depth + 1; j = j + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then return src:sub(i, j - 1), j + 1 end
            j = j + 1
        else j = j + 1 end
    end
    return nil
end

-- 反引号命令替换: i 指向第一个 '`'。POSIX 2.6.3: `\``/`\\`/`\$` 去掉反斜杠,
-- 其它位置的反斜杠原样保留(与 $( ) 不同 —— 这是反引号的经典坑, 必须照抄)。
function F.scanBacktick(src, i)
    local j, n, out = i + 1, #src, {}
    while j <= n do
        local c = src:sub(j, j)
        if c == "\\" then
            local nx = src:sub(j + 1, j + 1)
            if nx == "`" or nx == "\\" or nx == "$" then out[#out + 1] = nx; j = j + 2
            else out[#out + 1] = "\\"; j = j + 1 end
        elseif c == "`" then return table.concat(out), j + 1
        else out[#out + 1] = c; j = j + 1 end
    end
    return nil
end

-- 算术展开 $(( )): i 指向 '$'。返回 表达式原文, 结束位置; 未闭合返回 nil;
-- 括号错位返回 nil, 消息(那是语法错, 不是"输入还没读完")。
-- 体内括号要配对(`$(( (1+2)*3 ))`), 深度归 0 的那个 ')' 是表达式的收尾,
-- 紧跟的第二个 ')' 才是 $(( 的收尾 —— 少一个就是语法错(bash/dash 也这么判:
-- `$((-7)%2)` 在两者里同样是语法错, `$(( (-7)%2 ))` 才对)。
function F.scanArith(src, i)
    local j, n, depth = i + 3, #src, 1
    while j <= n do
        local c = src:sub(j, j)
        if c == "'" then
            j = j + 1
            while j <= n and src:sub(j, j) ~= "'" do j = j + 1 end
            j = j + 1
        elseif c == '"' then
            j = j + 1
            while j <= n and src:sub(j, j) ~= '"' do
                if src:sub(j, j) == "\\" then j = j + 1 end
                j = j + 1
            end
            j = j + 1
        elseif c == "\\" then j = j + 2
        elseif c == "(" then depth = depth + 1; j = j + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then
                if src:sub(j + 1, j + 1) ~= ")" then return nil, "missing '))'" end
                return src:sub(i + 3, j - 1), j + 2
            end
            j = j + 1
        else j = j + 1 end
    end
    return nil
end

-- 词法: 返回 toks, inc。inc=true 表示输入在引号/行续接中结束 —— 即"输入不完整"
-- (交互式应继续读下一行, 非交互式到 EOF 则是语法错误)。
-- 每个 token 记 pos/fin(源文本起止下标): 后台作业 `&` 要按原文重新起子 shell 执行。
function F.lex(src)
    local toks, i, n = {}, 1, #src
    local inc = false
    local lexErr = nil -- 确定的语法错(与"输入没读完"区分开: 后者交互式要继续读行)
    while i <= n do
        local c = src:sub(i, i)
        if c == " " or c == "\t" or c == "\r" then
            i = i + 1
        elseif c == "\n" then
            toks[#toks + 1] = { t = "nl", pos = i, fin = i }; i = i + 1
        elseif c == "&" and src:sub(i + 1, i + 1) == "&" then
            toks[#toks + 1] = { t = "op", op = "&&", pos = i, fin = i + 1 }; i = i + 2
        elseif c == "|" and src:sub(i + 1, i + 1) == "|" then
            toks[#toks + 1] = { t = "op", op = "||", pos = i, fin = i + 1 }; i = i + 2
        elseif c == ">" and src:sub(i + 1, i + 1) == ">" then
            toks[#toks + 1] = { t = "op", op = ">>", pos = i, fin = i + 1 }; i = i + 2
        elseif c == ";" and src:sub(i + 1, i + 1) == ";" then
            toks[#toks + 1] = { t = "op", op = ";;", pos = i, fin = i + 1 }; i = i + 2
        elseif c == "#" then
            -- 行注释: 跳到行尾(保留换行交给下一轮)。
            while i <= n and src:sub(i, i) ~= "\n" do i = i + 1 end
        elseif operatorChars[c] then
            toks[#toks + 1] = { t = "op", op = c, pos = i, fin = i }; i = i + 1
        else
            local wordStart = i
            local segs, raw, rawbuf, qbuf = {}, "", "", ""
            -- qbuf 与 rawbuf 等长: 逐字符记"是否被引用"。POSIX 只有**未引用**的
            -- * ? [ 才是通配符, 而一个词可以是混合的(`a"*"*` 里前一个 * 是字面量),
            -- 所以引号状态必须逐字符带着走, 不能在词这一层用一个布尔量。
            function F.flushRaw()
                if rawbuf ~= "" then
                    local seg = { raw = rawbuf }
                    if qbuf:find("1", 1, true) then seg.qm = qbuf end
                    segs[#segs + 1] = seg
                    rawbuf, qbuf = "", ""
                end
            end
            function F.pushRaw(text, quoted)
                rawbuf = rawbuf .. text
                qbuf = qbuf .. string.rep(quoted and "1" or "0", #text)
            end
            while i <= n do
                local cc = src:sub(i, i)
                if cc == " " or cc == "\t" or cc == "\r" or cc == "\n" then break end
                if cc == "&" and src:sub(i + 1, i + 1) == "&" then break end
                if cc == "|" and src:sub(i + 1, i + 1) == "|" then break end
                if operatorChars[cc] then break end
                if cc == "\\" then
                    -- 行续接(POSIX 2.2.1): `\` + 换行 从输入中删除, 词不被打断。
                    local nx = src:sub(i + 1, i + 1)
                    if nx == "\n" then i = i + 2; if i > n then inc = true end -- 输入以续行结尾
                    elseif nx == "\r" and src:sub(i + 2, i + 2) == "\n" then
                        i = i + 3; if i > n then inc = true end
                    elseif nx == "" then inc = true; i = i + 1 -- 行尾反斜杠: 等续行
                    else
                        -- 引号移除(POSIX 2.2): `\c` 就是字面 c, 且算"被引用"(通配符不生效)。
                        F.pushRaw(nx, true)
                        raw = raw .. "\\" .. nx -- token.raw 保留原文: isKw/赋值识别要看它
                        i = i + 2
                    end
                elseif cc == "'" then
                    F.flushRaw()
                    local j = i + 1
                    while j <= n and src:sub(j, j) ~= "'" do j = j + 1 end
                    if j > n then inc = true end -- 引号未闭合: 跨行待续
                    segs[#segs + 1] = { sq = src:sub(i + 1, j - 1) }; raw = raw .. src:sub(i + 1, j - 1)
                    i = (j <= n) and (j + 1) or j
                elseif cc == '"' then
                    F.flushRaw()
                    local j, dqsegs, dbuf = i + 1, {}, ""
                    function F.flushDq()
                        if dbuf ~= "" then dqsegs[#dqsegs + 1] = { raw = dbuf }; dbuf = "" end
                    end
                    while j <= n and src:sub(j, j) ~= '"' do
                        local dc, nx = src:sub(j, j), src:sub(j + 1, j + 1)
                        -- POSIX: 双引号内反斜杠仅在 \$ \` \" \\ 和换行前有特殊含义(去掉反斜杠),
                        -- 其它位置原样保留(如 "\t" 就是反斜杠+t)。
                        if dc == "\\" and (nx == '"' or nx == "$" or nx == "\\" or nx == "`") then
                            dbuf = dbuf .. nx; raw = raw .. nx; j = j + 2
                        elseif dc == "\\" and nx == "\n" then
                            j = j + 2 -- 行续接: 双引号内 `\` + 换行 也被删除
                        elseif dc == "\\" and nx == "\r" and src:sub(j + 2, j + 2) == "\n" then
                            j = j + 3
                        elseif dc == "$" and src:sub(j + 1, j + 2) == "((" then
                            local body, ni, aerr = F.scanArith(src, j)
                            if aerr then lexErr = aerr; j = n + 1
                            elseif not body then j = n + 1 else
                                F.flushDq()
                                dqsegs[#dqsegs + 1] = { arith = body }
                                raw = raw .. src:sub(j, ni - 1)
                                j = ni
                            end
                        elseif dc == "$" and src:sub(j + 1, j + 1) == "(" then
                            local body, ni = F.scanCmdSub(src, j + 2)
                            if not body then j = n + 1 else
                                F.flushDq()
                                dqsegs[#dqsegs + 1] = { cmdsub = body }
                                raw = raw .. src:sub(j, ni - 1)
                                j = ni
                            end
                        elseif dc == "$" then
                            local name, ni = F.readVarName(src, j + 1)
                            if name then
                                F.flushDq()
                                dqsegs[#dqsegs + 1] = { var = name }; raw = raw .. tostring(F.getVarVal(name)); j = ni
                            else dbuf = dbuf .. "$"; raw = raw .. "$"; j = j + 1 end
                        elseif dc == "`" then
                            local body, ni = F.scanBacktick(src, j)
                            if not body then j = n + 1 else
                                F.flushDq()
                                dqsegs[#dqsegs + 1] = { cmdsub = body }
                                raw = raw .. src:sub(j, ni - 1)
                                j = ni
                            end
                        else
                            dbuf = dbuf .. dc; raw = raw .. dc; j = j + 1
                        end
                    end
                    if j > n then inc = true end -- 双引号未闭合(含行尾反斜杠): 跨行待续
                    F.flushDq()
                    segs[#segs + 1] = { dq = dqsegs }
                    i = (j <= n) and (j + 1) or j
                elseif cc == "$" and src:sub(i + 1, i + 2) == "((" then
                    local body, ni, aerr = F.scanArith(src, i)
                    if aerr then lexErr = aerr; i = n + 1
                    elseif not body then inc = true; i = n + 1 else
                        F.flushRaw()
                        segs[#segs + 1] = { arith = body }
                        raw = raw .. src:sub(i, ni - 1) -- 原文进 token.raw: 它不是关键字, 也不是赋值前缀
                        i = ni
                    end
                elseif cc == "$" and src:sub(i + 1, i + 1) == "(" then
                    local body, ni = F.scanCmdSub(src, i + 2)
                    if not body then inc = true; i = n + 1 else
                        F.flushRaw()
                        segs[#segs + 1] = { cmdsub = body }
                        raw = raw .. src:sub(i, ni - 1)
                        i = ni
                    end
                elseif cc == "`" then
                    local body, ni = F.scanBacktick(src, i)
                    if not body then inc = true; i = n + 1 else
                        F.flushRaw()
                        segs[#segs + 1] = { cmdsub = body }
                        raw = raw .. src:sub(i, ni - 1)
                        i = ni
                    end
                elseif cc == "$" then
                    F.flushRaw()
                    local name, ni = F.readVarName(src, i + 1)
                    if name then segs[#segs + 1] = { var = name }; raw = raw .. tostring(F.getVarVal(name)); i = ni
                    else F.pushRaw("$", false); raw = raw .. "$"; i = i + 1 end
                else
                    F.pushRaw(cc, false); raw = raw .. cc; i = i + 1
                end
            end
            F.flushRaw()
            -- 整词都是行续接时不产生空词(`echo \` + 换行 + `foo` 应为 2 个词)。
            if #segs > 0 or raw ~= "" then
                toks[#toks + 1] = { t = "word", segs = segs, raw = raw, pos = wordStart, fin = i - 1 }
            end
        end
    end
    return toks, inc, lexErr
end

-- ---------------------------------------------------------------
-- 展开: 参数 / 命令替换 / 算术 / 字段分割 / 路径名(通配符)
-- ---------------------------------------------------------------
-- 展开期的致命错误(算术表达式非法、除零、命令替换起不了子进程……): POSIX 要求这是
-- shell 错误而不是"展开成空串继续跑"。不能写成 error()+pcall: 展开里会 os.sleep(命令替换
-- 要等子进程, 会让出调度器), 而 Lua 5.1 不允许跨 pcall 让出("attempt to yield across
-- metamethod/C-call boundary")。所以用一个显式标志, 由调用方在动任何东西之前检查。
local expandFailed = nil
local substRan = false -- 本次命令展开里跑过命令替换吗(纯赋值的 $? 要用, 见 evalSimple)
function F.expandFail(msg)
    if not expandFailed then expandFailed = msg end
end
--- 取出并清空展开错误。返回错误消息或 nil。
function F.expandTakeError()
    local m = expandFailed
    expandFailed = nil
    return m
end
--- 展开期致命错误的统一处理(报错 + 退出码 1)。返回 true 表示当前命令必须中止:
--- 交互式丢弃这条命令继续, 非交互式退出 shell(与 set -u 的处理一致)。
function F.expandAbort()
    local m = F.expandTakeError()
    if not m then return false end
    F.errln(shName .. ": " .. m)
    lastExit = 1
    return true
end
-- cmdSubst/arithStr 的实现放在后面(它们要用之后才定义的 subshellPrologue/spawnChild)。

function F.zeroMask(n) return string.rep("0", n) end

--- 展开一个 dq(双引号)体: 里面的每个字符都算被引用(通配符不生效)。
function F.expandDqParts(parts)
    local s = ""
    for _, d in ipairs(parts) do
        if d.var then s = s .. F.getVarVal(d.var)
        elseif d.cmdsub then s = s .. cmdSubst(d.cmdsub)
        elseif d.arith then s = s .. F.arithStr(d.arith)
        else s = s .. d.raw end
    end
    return s
end

--- 展开成一个字符串(不做字段分割、不做通配): 赋值值、重定向目标、case 词用。
--- 返回 串, 引用掩码(逐字符 "0"/"1", 通配符判定要用)。
function F.expandGlueMask(segs)
    local s, qm = "", ""
    for _, seg in ipairs(segs) do
        if seg.raw then
            s = s .. seg.raw
            qm = qm .. (seg.qm or F.zeroMask(#seg.raw))
        elseif seg.sq then
            s = s .. seg.sq
            qm = qm .. string.rep("1", #seg.sq)
        elseif seg.dq then
            local ds = F.expandDqParts(seg.dq)
            s = s .. ds
            qm = qm .. string.rep("1", #ds)
        elseif seg.var then
            local v = F.getVarVal(seg.var)
            s = s .. v
            qm = qm .. F.zeroMask(#v)
        elseif seg.cmdsub then
            local v = cmdSubst(seg.cmdsub)
            s = s .. v
            qm = qm .. F.zeroMask(#v)
        elseif seg.arith then
            local v = F.arithStr(seg.arith)
            s = s .. v
            qm = qm .. F.zeroMask(#v)
        end
    end
    return s, qm
end
function F.expandGlue(segs) return (F.expandGlueMask(segs)) end

--- 追加一段文本到"词列表"里(未引用的片段按 IFS 分割, 引用的片段整体拼上)。
--- parts = 分割后的片段; quoted = 这些片段是否算被引用。
function F.appendParts(words, parts, quoted)
    if #parts == 0 then return end
    local new = {}
    local mask = quoted and "1" or "0"
    for _, w in ipairs(words) do
        for _, p in ipairs(parts) do
            new[#new + 1] = { s = w.s .. p, qm = w.qm .. string.rep(mask, #p), alive = true }
        end
    end
    words = new
    return words
end

function F.expandSegs(segs)
    local words = { { s = "", qm = "", alive = false } }
    for _, seg in ipairs(segs) do
        if seg.raw then
            for _, w in ipairs(words) do
                w.s = w.s .. seg.raw
                w.qm = w.qm .. (seg.qm or F.zeroMask(#seg.raw))
                w.alive = true
            end
        elseif seg.sq then
            for _, w in ipairs(words) do
                w.s = w.s .. seg.sq
                w.qm = w.qm .. string.rep("1", #seg.sq)
                w.alive = true
            end
        elseif seg.dq then
            -- "$@" 特殊: 每个位置参数作为一个词(常见于 "for x in \"$@\"" / 透传参数)。
            if #seg.dq == 1 and seg.dq[1].var == "@" then
                local parts = {}
                for k = 1, #posArgs do parts[k] = posArgs[k] end
                words = F.appendParts(words, parts, true) or words
            else
                local ds = F.expandDqParts(seg.dq)
                for _, w in ipairs(words) do
                    w.s = w.s .. ds
                    w.qm = w.qm .. string.rep("1", #ds)
                    w.alive = true
                end
            end
        elseif seg.var then
            local name = seg.var
            local parts
            if name == "@" then
                parts = {}
                for k = 1, #posArgs do parts[k] = posArgs[k] end
            else parts = F.splitIfs(F.getVarVal(name)) end
            words = F.appendParts(words, parts, false) or words
        elseif seg.cmdsub then
            -- 命令替换结果: 未加引号时同样按 IFS 分割并做通配(POSIX 2.6.3)。
            words = F.appendParts(words, F.splitIfs(cmdSubst(seg.cmdsub)), false) or words
        elseif seg.arith then
            local v = F.arithStr(seg.arith)
            if v ~= "" then words = F.appendParts(words, { v }, false) or words end
        end
    end
    local out = {}
    for _, w in ipairs(words) do
        if w.alive then out[#out + 1] = w end
    end
    return out
end

-- ---------------------------------------------------------------
-- 路径名展开(通配符 * ? [ ])
-- ---------------------------------------------------------------
--- 编码成"匹配用模式": 被引用的(以及展开得来的)通配符/反斜杠要变成字面量。
--- 与 POSIX 一致: 只有**展开前就在源码里、且未加引号**的 * ? [ 才是通配符。
function F.encodePattern(s, qm)
    local out = {}
    for k = 1, #s do
        local c = s:sub(k, k)
        if c == "\\" then out[#out + 1] = "\\\\"
        elseif qm:sub(k, k) == "1" and (c == "*" or c == "?" or c == "[" or c == "]" or c == "!") then
            out[#out + 1] = "\\" .. c
        else out[#out + 1] = c end
    end
    return table.concat(out)
end

--- 匹配一个 [] 字符组。i 指向 '[' 之后, ch 是待判字符。
--- 返回 (下一个位置, 是否命中); 未闭合的组返回 nil(整个匹配失败 -> 当作字面量)。
function F.globClassAt(pat, i, ch)
    local neg = false
    local c0 = pat:sub(i, i)
    if c0 == "!" or c0 == "^" then neg = true; i = i + 1 end
    local hit, first = false, true
    while i <= #pat do
        local c = pat:sub(i, i)
        if c == "]" and not first then return i + 1, (hit ~= neg) end
        first = false
        if c == "\\" and i < #pat then
            local lit = pat:sub(i + 1, i + 1)
            if ch == lit then hit = true end
            i = i + 2
        elseif pat:sub(i + 1, i + 1) == "-" and i + 2 <= #pat and pat:sub(i + 2, i + 2) ~= "]" then
            local lo, hi = c, pat:sub(i + 2, i + 2)
            if ch >= lo and ch <= hi then hit = true end
            i = i + 3
        else
            if ch == c then hit = true end
            i = i + 1
        end
    end
    return nil, false
end

--- shell 式通配匹配(与 find -name 同一套语义): `*` 任意(含空), `?` 一个字符,
--- [abc]/[a-z]/[!abc] 字符组, `\c` 转义。case 模式与路径名展开共用它。
function F.globMatch(pat, s)
    local function m(pi, si)
        while pi <= #pat do
            local c = pat:sub(pi, pi)
            if c == "*" then
                while pat:sub(pi, pi) == "*" do pi = pi + 1 end
                if pi > #pat then return true end
                for k = si, #s do if m(pi, k) then return true end end
                return false
            elseif c == "?" then
                if si > #s then return false end
                pi, si = pi + 1, si + 1
            elseif c == "[" then
                if si > #s then return false end
                local np, ok = F.globClassAt(pat, pi + 1, s:sub(si, si))
                if not np or not ok then return false end
                pi, si = np, si + 1
            elseif c == "\\" then
                if pi == #pat then return false end
                if s:sub(si, si) ~= pat:sub(pi + 1, pi + 1) then return false end
                pi, si = pi + 2, si + 1
            else
                if s:sub(si, si) ~= c then return false end
                pi, si = pi + 1, si + 1
            end
        end
        return si > #s
    end
    return m(1, 1)
end

--- 词里有没有"未加引号的"通配符(没有就不去碰文件系统)。
function F.hasUnquotedMeta(s, qm)
    for k = 1, #s do
        local c = s:sub(k, k)
        if qm:sub(k, k) == "0" and (c == "*" or c == "?" or c == "[") then return true end
    end
    return false
end

--- 路径名展开(POSIX 2.13.3): 按 '/' 逐段匹配, `*` 不跨 '/'。
--- 首字符为 '.' 的目录项只能被"模式里也显式写了 ."匹配(POSIX 的隐藏文件规则)。
--- 返回匹配到的路径表(原样风格, 相对就是相对); 无匹配返回 nil(调用方保留原词)。
function F.pathGlob(word, qm)
    local comps, cur, curm = {}, "", ""
    local absolute = word:sub(1, 1) == "/" and qm:sub(1, 1) == "0"
    local start = absolute and 2 or 1
    for k = start, #word do
        local c = word:sub(k, k)
        local q = qm:sub(k, k)
        if c == "/" and q == "0" then
            comps[#comps + 1] = { pat = cur, mask = curm }
            cur, curm = "", ""
        else
            cur = cur .. c
            curm = curm .. q
        end
    end
    comps[#comps + 1] = { pat = cur, mask = curm }
    -- out = 按用户写的样子拼回去的显示路径(相对词保持相对); dir = 用来列目录的绝对路径。
    local entries = { { out = absolute and "/" or "", dir = F.resolve(absolute and "/" or ".") } }
    function F.joinOut(prefix, name)
        if prefix == "" or prefix:sub(-1) == "/" then return prefix .. name end
        return prefix .. "/" .. name
    end
    for ci, comp in ipairs(comps) do
        local keep = {}
        if comp.pat == "" then
            -- "//" 或结尾 '/': 空段不匹配任何东西, 只要求它是目录(POSIX: 结尾 '/' 只匹配目录)。
            for _, e in ipairs(entries) do
                if fs.isDir(e.dir) then
                    local out = (ci == 1) and e.out or (e.out .. "/")
                    keep[#keep + 1] = { out = out, dir = e.dir }
                end
            end
        elseif comp.pat == "." or comp.pat == ".." then
            -- fs.list 不含 "." / ".."(CC 原生 fs 就没有这两个条目), 得自己走一级。
            for _, e in ipairs(entries) do
                local d = F.resolve(e.dir .. "/" .. comp.pat)
                if fs.isDir(d) then keep[#keep + 1] = { out = F.joinOut(e.out, comp.pat), dir = d } end
            end
        else
            local meta = F.hasUnquotedMeta(comp.pat, comp.mask)
            local pat = F.encodePattern(comp.pat, comp.mask)
            -- '.' 开头的项只在模式也以字面 '.' 开头时才匹配(POSIX 隐藏文件规则)。
            local dotOk = comp.pat:sub(1, 1) == "."
            for _, e in ipairs(entries) do
                local names = fs.list(e.dir)
                if names then
                    table.sort(names) -- POSIX: 结果按排序输出
                    for _, nm in ipairs(names) do
                        local hit = (not meta and nm == comp.pat) or (meta and F.globMatch(pat, nm))
                        if hit and (dotOk or nm:sub(1, 1) ~= ".") then
                            keep[#keep + 1] = { out = F.joinOut(e.out, nm), dir = e.dir .. "/" .. nm }
                        end
                    end
                end
            end
        end
        entries = keep
        if #entries == 0 then return nil end
    end
    local out = {}
    for _, e in ipairs(entries) do out[#out + 1] = e.out end
    return out
end

-- ---------------------------------------------------------------
-- 波浪号展开(POSIX 2.6.1): `~` -> $HOME, `~user` -> 该用户的家目录
-- ---------------------------------------------------------------
--- 只在**词首**、且 ~ 前缀整个落在第一段"未加引号的原文"里时展开 —— 判据对着 bash 实测:
---   ~/~x/~root/~root/x 展开;  ~nosuchuser/~$USER/~"x" 保持原样(a~b 也不展开, 不是词首)。
--- 展开结果按**未加引号**处理(继续参与通配符展开, `~/*` 照样 glob), 与 bash 一致。
---@param segs table 词段表
---@return table 新词段表(未展开时原样返回)
function F.tildeExpandSegs(segs)
    local first = segs[1]
    if not (first and first.raw) then return segs end
    if first.raw:sub(1, 1) ~= "~" then return segs end
    local qm = first.qm or ""
    if qm:sub(1, 1) == "1" then return segs end -- `\~` / 引号里的 ~ 不是波浪号展开
    local slash = first.raw:find("/", 2, true)
    local prefix, rest
    if slash then
        prefix, rest = first.raw:sub(1, slash - 1), first.raw:sub(slash)
    elseif #segs == 1 then
        prefix, rest = first.raw, ""
    else
        return segs -- `~$USER` / `~"x"`: ~ 后面还有别的段, bash 同样不展开
    end
    local home
    if prefix == "~" then
        home = vars.HOME
    else
        local name = prefix:sub(2)
        -- ~user 走 passwd(getpwnam 同义); 名字非法或查不到就原样保留
        if name == "" or name:find("[^%w_%-%.]") then return segs end
        local u = syscalls and syscalls["user.get"] and syscalls["user.get"](name)
        home = u and u.home
    end
    if not home or home == "" then return segs end
    local out = { { raw = home .. rest, qm = F.zeroMask(#home + #rest) } }
    for i = 2, #segs do out[#out + 1] = segs[i] end
    return out
end

--- 一个"词"的完整展开: 波浪号 -> 参数/命令/算术 -> 字段分割 -> 路径名展开。出错返回 nil。
function F.expandWordList(segs)
    segs = F.tildeExpandSegs(segs)
    local out = {}
    for _, w in ipairs(F.expandSegs(segs)) do
        if F.hasUnquotedMeta(w.s, w.qm) then
            local m = F.pathGlob(w.s, w.qm)
            if m then for _, p in ipairs(m) do out[#out + 1] = p end
            else out[#out + 1] = w.s end -- 无匹配: 保留原词(POSIX sh 默认)
        else
            out[#out + 1] = w.s
        end
    end
    if expandFailed then return nil end
    return out
end

function F.wordToStr(segs) return F.expandGlue(segs) end

-- ---------------------------------------------------------------
-- 解析器
-- ---------------------------------------------------------------
local kw = { ["if"]=true, ["then"]=true, ["elif"]=true, ["else"]=true, ["fi"]=true, ["for"]=true,
    ["in"]=true, ["do"]=true, ["done"]=true, ["while"]=true, ["until"]=true, ["case"]=true,
    ["esac"]=true, ["function"]=true, ["!"]=true }

local T, ti, curSrc
function F.peek() return T[ti] end
function F.adv() local t = T[ti]; ti = ti + 1; return t end
-- 一段 token 区间的源文本(后台作业 `&` 按原文起子 shell: 语义与 POSIX 子 shell 一致)。
function F.tokText(a, b)
    local first, last = T[a], T[b]
    if not first or not last or not curSrc then return nil end
    return curSrc:sub(first.pos, last.fin)
end
function F.isKw(t, w) return t and t.t == "word" and t.raw == w and #t.segs == 1 and t.segs[1].raw ~= nil end
function F.skipNl() while true do local t = T[ti]; if t and t.t == "nl" then ti = ti + 1 else return end end end
function F.skipSep() while true do local t = T[ti]; if t and (t.t == "nl" or (t.t == "op" and t.op == ";")) then ti = ti + 1 else return end end end
function F.isStop(t, stop)
    if not t or not stop then return false end
    -- 只认**未加引号的整词**: `"done"` 是命令名 done, 不是关键字(与 isKw 同一判据)。
    if t.t == "word" and stop[t.raw] and #t.segs == 1 and t.segs[1].raw ~= nil then return true end
    if t.t == "op" and stop[t.op] then return true end
    return false
end
-- 缺少关键字/操作数时的返回: 输入已到末尾 => 不完整(交互式继续读行 PS2), 否则语法错误。
function F.needMore(msg)
    if not T[ti] then return nil, nil, true end
    return nil, msg
end

local parseList, parseCommand, parseSimple, parseAndOr, parsePipeline, parseParse
parseSimple = function()
    local assigns, argvSegs, redirects = {}, {}, {}
    local onlyAssign = true
    while true do
        local t = T[ti]
        if not t then break end
        if t.t == "nl" then break end
        if t.t == "op" then
            if t.op == ">" or t.op == ">>" or t.op == "<" then
                ti = ti + 1
                local tgt = T[ti]
                if not tgt then return F.needMore("redirection target expected") end
                -- 重定向目标必须与操作符同行(POSIX): 换行/其他操作符即语法错误。
                if tgt.t ~= "word" then return nil, "redirection target expected" end
                ti = ti + 1
                redirects[#redirects + 1] = { fd = 0, op = t.op, target = tgt.segs }
            else break end
        else
            -- word: assignment or arg
            local nm
            if onlyAssign and t.raw and t.raw:match("^[%a_][%w_]*=") and t.segs[1] and t.segs[1].raw then
                nm = t.raw:match("^([%a_][%w_]*)=(.*)$")
            end
            if nm then
                -- 值 segs = 去掉 "name=" 前缀后的 t.segs
                local valsegs = {}
                local rest = t.segs[1].raw:sub(#nm + 2)
                if rest ~= "" then valsegs[#valsegs + 1] = { raw = rest } end
                for k = 2, #t.segs do valsegs[#valsegs + 1] = t.segs[k] end
                assigns[#assigns + 1] = { name = nm, value = valsegs }
                ti = ti + 1
            else
                onlyAssign = false
                argvSegs[#argvSegs + 1] = t.segs
                ti = ti + 1
            end
        end
    end
    return { kind = "simple", assigns = assigns, argv = argvSegs, redirects = redirects }
end

-- 函数定义检测: name () { ... } 或 function name { ... } (t 处为 name/function)
function F.tryFuncDef()
    -- 形式 "name ( ) {": 
    local startTok = ti
    local a, b, c = T[ti], T[ti + 1], T[ti + 2]
    if a and a.t == "word" and b and b.t == "op" and b.op == "(" and c and c.t == "op" and c.op == ")" then
        local fname = a.raw
        ti = ti + 3
        F.skipNl()
        local bt = T[ti]
        if not bt then return nil, nil, true end
        if not F.isKw(bt, "{") then return nil, "function body expected" end
        ti = ti + 1
        local body, err, inc = parseList({ ["}"] = true })
        if body == nil then return nil, err, inc end
        if not F.isKw(T[ti], "}") then return F.needMore("} expected") end
        ti = ti + 1
        return { kind = "funcdef", name = fname, body = body, src = F.tokText(startTok, ti - 1) }
    end
    return false
end

function F.parseFuncKeyword(startTok)
    -- 已看到 'function'(startTok 指向该关键字)
    local nameTok = T[ti]
    if not nameTok then return nil, nil, true end
    if nameTok.t ~= "word" then return nil, "function name expected" end
    ti = ti + 1
    if T[ti] and T[ti].t == "op" and T[ti].op == "(" then ti = ti + 1
        if T[ti] and T[ti].t == "op" and T[ti].op == ")" then ti = ti + 1 end end
    F.skipNl()
    if not F.isKw(T[ti], "{") then return F.needMore("function body expected") end
    ti = ti + 1
    local body, err, inc = parseList({ ["}"] = true })
    if body == nil then return nil, err, inc end
    if not F.isKw(T[ti], "}") then return F.needMore("} expected") end
    ti = ti + 1
    return { kind = "funcdef", name = nameTok.raw, body = body, src = F.tokText(startTok, ti - 1) }
end

parseCommand = function()
    local t = T[ti]
    if not t then return nil, nil, true end
    if F.isKw(t, "if") then
        ti = ti + 1
        local cond, err, inc = parseList({ ["then"] = true })
        if cond == nil then return nil, err, inc end
        F.skipNl()
        if not F.isKw(T[ti], "then") then return F.needMore("then expected") end
        ti = ti + 1
        local thenb, e2, i2 = parseList({ ["elif"] = true, ["else"] = true, ["fi"] = true })
        if thenb == nil then return nil, e2, i2 end
        local elifs = {}
        while F.isKw(T[ti], "elif") do
            ti = ti + 1
            local ec, e3, i3 = parseList({ ["then"] = true })
            if ec == nil then return nil, e3, i3 end
            F.skipNl()
            if not F.isKw(T[ti], "then") then return F.needMore("then expected") end
            ti = ti + 1
            local eb, e4, i4 = parseList({ ["elif"] = true, ["else"] = true, ["fi"] = true })
            if eb == nil then return nil, e4, i4 end
            elifs[#elifs + 1] = { cond = ec, body = eb }
        end
        local elseb
        if F.isKw(T[ti], "else") then ti = ti + 1; elseb = parseList({ ["fi"] = true }) end
        if not F.isKw(T[ti], "fi") then return F.needMore("fi expected") end
        ti = ti + 1
        return { kind = "if", cond = cond, thenb = thenb, elifs = elifs, elseb = elseb }
    elseif F.isKw(t, "for") then
        ti = ti + 1
        local v = T[ti]
        if not v then return nil, nil, true end
        if v.t ~= "word" then return nil, "for variable expected" end
        local var = v.raw; ti = ti + 1
        local items
        if F.isKw(T[ti], "in") then
            ti = ti + 1
            items = {}
            while true do
                local w = T[ti]
                if not w or w.t ~= "word" then break end
                if F.isKw(w, "do") then break end
                items[#items + 1] = w.segs; ti = ti + 1
            end
        end
        F.skipSep()
        if not F.isKw(T[ti], "do") then return F.needMore("do expected") end
        ti = ti + 1
        local body, err, inc = parseList({ ["done"] = true })
        if body == nil then return nil, err, inc end
        if not F.isKw(T[ti], "done") then return F.needMore("done expected") end
        ti = ti + 1
        return { kind = "for", var = var, items = items, body = body }
    elseif F.isKw(t, "while") or F.isKw(t, "until") then
        local isWhile = F.isKw(T[ti], "while"); ti = ti + 1
        local cond, err, inc = parseList({ ["do"] = true })
        if cond == nil then return nil, err, inc end
        F.skipSep()
        if not F.isKw(T[ti], "do") then return F.needMore("do expected") end
        ti = ti + 1
        local body, e2, i2 = parseList({ ["done"] = true })
        if body == nil then return nil, e2, i2 end
        if not F.isKw(T[ti], "done") then return F.needMore("done expected") end
        ti = ti + 1
        return { kind = isWhile and "while" or "until", cond = cond, body = body }
    elseif F.isKw(t, "case") then
        ti = ti + 1
        local w = T[ti]
        if not w then return nil, nil, true end
        if w.t ~= "word" then return nil, "case word expected" end
        local word = w.segs; ti = ti + 1
        F.skipNl()
        if not F.isKw(T[ti], "in") then return F.needMore("in expected") end
        ti = ti + 1
        local cases = {}
        while true do
            F.skipNl()
            if F.isKw(T[ti], "esac") then break end
            local pats, okPat = {}, false
            while true do
                local p = T[ti]
                if not p then break end
                if p.t == "op" and p.op == ")" then ti = ti + 1; okPat = true; break end
                if p.t == "op" and p.op == "|" then ti = ti + 1 -- pattern 分隔符, 继续
                elseif p.t == "op" then break
                elseif F.isKw(p, "esac") then break
                else pats[#pats + 1] = p.segs; ti = ti + 1 end
            end
            if not okPat then
                -- pattern 列表到末尾都没出现 ")": 待续(交互式 PS2); 否则是语法错误。
                if not T[ti] then return nil, nil, true end
                break
            end
            F.skipNl()
            local body, err, inc = parseList({ [";;"] = true, ["esac"] = true })
            if body == nil then return nil, err, inc end
            cases[#cases + 1] = { pats = pats, body = body }
            if T[ti] and T[ti].t == "op" and T[ti].op == ";;" then ti = ti + 1 end
        end
        if not F.isKw(T[ti], "esac") then return F.needMore("esac expected") end
        ti = ti + 1
        return { kind = "case", word = word, cases = cases }
    elseif F.isKw(t, "function") then
        local kwTok = ti
        ti = ti + 1
        return F.parseFuncKeyword(kwTok)
    elseif F.isKw(t, "{") then
        ti = ti + 1
        local body, err, inc = parseList({ ["}"] = true })
        if body == nil then return nil, err, inc end
        if not F.isKw(T[ti], "}") then return F.needMore("} expected") end
        ti = ti + 1
        return { kind = "brace", body = body }
    else
        local fd, ferr, finc = F.tryFuncDef()
        if fd == false then return parseSimple() end
        return fd, ferr, finc
    end
end

parsePipeline = function()
    -- `time` 是 POSIX 保留字(不是内建): `time [-p] pipeline` 只在**管道/命令的首词**位置识别。
    -- 写成变量赋值(`time=5`)、被引用(`echo time`)或在管道中段时都不是保留字。
    local isTime, timePosix = false, false
    if F.isKw(T[ti], "time") then
        ti = ti + 1
        isTime = true
        if F.isKw(T[ti], "-p") then timePosix = true; ti = ti + 1 end
    end
    local node, err, inc = parseCommand()
    if node == nil then return nil, err, inc end
    -- 管道: command ( | command )*, 优先级高于 &&/||。`|` 后允许换行(POSIX)。
    if T[ti] and T[ti].t == "op" and T[ti].op == "|" then
        local items = { node }
        while T[ti] and T[ti].t == "op" and T[ti].op == "|" do
            ti = ti + 1
            F.skipNl()
            local n2, e2, i2 = parseCommand()
            if n2 == nil then return nil, e2, i2 end
            items[#items + 1] = n2
        end
        node = { kind = "pipe", items = items }
    end
    if isTime then return { kind = "time", node = node, posix = timePosix } end
    return node
end

parseAndOr = function()
    local node, err, inc = parsePipeline()
    if node == nil then return nil, err, inc end
    -- 若后面紧跟 && 或 ||, 归成一个 chain(&&/|| 短路只在 chain 内生效, 不影响外层 ; 列表)。
    if T[ti] and T[ti].t == "op" and (T[ti].op == "&&" or T[ti].op == "||") then
        local items = { { node = node, op = "" } }
        while T[ti] and T[ti].t == "op" and (T[ti].op == "&&" or T[ti].op == "||") do
            local op = T[ti].op; ti = ti + 1
            F.skipNl() -- `&&`/`||` 后允许换行(POSIX)
            local n2, e2, i2 = parsePipeline()
            if n2 == nil then return nil, e2, i2 end
            items[#items + 1] = { node = n2, op = op }
        end
        return { kind = "chain", items = items }
    end
    return node
end

parseList = function(stop)
    local items = {}
    while true do
        F.skipNl()
        local t = T[ti]
        if not t then break end
        if F.isStop(t, stop) then break end
        if t.t == "op" then
            if t.op == ";" or t.op == "&" then ti = ti + 1 else break end
        end
        local startTok = ti
        local node, err, inc = parseAndOr()
        if node == nil then
            if inc then return nil, nil, true end
            return nil, err or "parse error"
        end
        local srcText = F.tokText(startTok, ti - 1) -- 先截取, 再吃掉分隔符(不含 `&` 本身)
        local op = ""
        local sep = T[ti]
        if sep and sep.t == "op" and (sep.op == ";" or sep.op == "&") then
            op = sep.op; ti = ti + 1
        end
        node.src = srcText -- 节点自带源文本(后台子 shell / 停止作业的显示名)
        items[#items + 1] = { node = node, op = op, src = srcText }
        if op == "" and (F.isStop(T[ti], stop) or not T[ti]) then break end
        if F.isStop(T[ti], stop) then break end
        if not T[ti] then break end
    end
    return items
end

-- ---------------------------------------------------------------
-- 求值
-- ---------------------------------------------------------------
-- POSIX 特殊内建: 赋值前缀在它们身上留在当前环境(不恢复)。
local specialBuiltins = { [":"] = true, ["exit"] = true, ["return"] = true, ["shift"] = true,
    ["break"] = true, ["continue"] = true, ["."] = true, ["set"] = true, ["export"] = true,
    ["unset"] = true }

local builtins = {}

--- 展开一串词(命令 argv / for-in 列表): 字段分割 + 路径名展开(通配符)。
--- 展开期发生致命错误时返回 nil(调用方必须先检查再动别的东西)。
function F.expandWords(words)
    local out = {}
    for _, w in ipairs(words) do
        local ws = F.expandWordList(w)
        if not ws then return nil end
        for _, s in ipairs(ws) do out[#out + 1] = s end
    end
    return out
end
--- 重定向目标: 通配符展开后必须是**恰好一个**词(bash 的 "ambiguous redirect" 语义)。
--- 失败时返回 nil(错误已记在 expandFailed 里)。
function F.expandRedirTarget(segs)
    local ws = F.expandWordList(segs)
    if not ws then return nil end
    if #ws == 0 then
        F.expandFail("ambiguous redirect")
        return nil
    elseif #ws > 1 then
        F.expandFail(table.concat(ws, " ") .. ": ambiguous redirect")
        return nil
    end
    return ws[1]
end
function F.tail(t) local r = {}; for i = 2, #t do r[#r + 1] = t[i] end return r end
-- set -u(nounset): 在命令真正执行前检查它要展开的变量是否都已定义。
-- 放在执行前(而非展开中)的原因: 未执行的分支(`if false; then echo $x; fi`)不该报错,
-- 而一旦要执行, 整条命令就必须中止(不能带着空值去跑 `rm -rf $UNDEF`)。
-- 交互式报错后只丢弃当前命令并继续(bash 行为); 非交互式返回 "exit" 让 shell 退出。
function F.unsetVarIn(segs)
    if not opt.nounset then return nil end
    for _, seg in ipairs(segs) do
        if seg.var then
            if not F.isVarSet(seg.var) then return seg.var end
        elseif seg.dq then
            for _, d in ipairs(seg.dq) do
                if d.var and not F.isVarSet(d.var) then return d.var end
            end
        end
    end
    return nil
end
-- words: 一串词(每个词是一串 segs)。返回 (abort, ctrl)。
function F.nounsetCheck(words)
    if not opt.nounset then return false end
    for _, w in ipairs(words) do
        local bad = F.unsetVarIn(w)
        if bad then
            F.errln(shName .. ": " .. bad .. ": parameter not set")
            lastExit = 1
            -- 非交互式: 让 shell 退出; 交互式: 只丢弃当前命令(bash 行为)。
            if interactive then return true end
            return true, "exit"
        end
    end
    return false
end
-- 一个 simple 节点的全部词(argv + 赋值值 + 重定向目标)。
function F.simpleWords(node)
    local words = {}
    for _, w in ipairs(node.argv) do words[#words + 1] = w end
    for _, a in ipairs(node.assigns) do words[#words + 1] = a.value end
    for _, r in ipairs(node.redirects) do words[#words + 1] = r.target end
    return words
end
-- 可重输入的赋值文本(POSIX `set`/`export -p` 输出用): 总是单引号, 内部 ' 转义为 '\''。
function F.quoteAssign(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
-- 可执行命令路径查找(POSIX PATH 语义):
--   - 含 "/" 的名字按 cwd 解析, 不查 PATH;
--   - 否则按 $PATH 逐目录查找(空条目 = 当前目录), PATH 未设置时用 /bin;
--   - needExec 为真(命令查找)时优先可执行文件; 若只找到不可执行的候选, 返回它,
--     由调用方给出 permission denied(与 bash 一致)。未找到返回 nil。
-- 命令路径缓存(POSIX `hash` 内建维护它, 见下文 builtins.hash)。
-- searchPath 每次都用它: 命中就不走 PATH 搜索。**PATH 一变整个缓存作废** —— 否则改了 PATH
-- 还用着老路径, 是真实 shell 里非常经典的坑。定义在这里是因为 searchPath 要用到它。
local hashCache = { path = nil, map = {} }
function F.hashSync()
    if hashCache.path ~= vars.PATH then
        hashCache.path = vars.PATH
        hashCache.map = {}
    end
end

--- 在**指定**的 PATH 串里查找(不读 $PATH)。`command -p` 用它走系统缺省路径。
function F.searchInPath(name, path, needExec)
    if name:find("/") then
        local p = F.resolve(name)
        if fs.exists(p) then return p end
        return nil
    end
    if path == nil or path == "" then return nil end
    local fallback = nil
    for dir in (path .. ":"):gmatch("([^:]*):") do
        local cand = (dir == "") and F.resolve(name) or F.resolve(dir .. "/" .. name)
        if fs.exists(cand) and not (fs.isDir and fs.isDir(cand)) then
            if not needExec or fs.canExecute(cand) then return cand end
            if not fallback then fallback = cand end
        end
    end
    return fallback
end

function F.searchPath(name, needExec)
    if name:find("/") then
        local p = F.resolve(name)
        if fs.exists(p) then return p end
        return nil
    end
    -- 先查 hash 缓存(POSIX hash 内建维护它)。PATH 变了缓存整体作废(见 hashSync)。
    F.hashSync()
    local hit = hashCache.map[name]
    if hit and fs.exists(hit) then return hit end
    hashCache.map[name] = nil
    local found = F.searchInPath(name, vars.PATH, needExec)
    if found then hashCache.map[name] = found end
    return found
end

builtins.pwd = function(args) F.outln(cwd) end

-- echo 的转义(bash/XSI 风格, -e 时生效)。\c 停止输出(不换行), 未知转义原样保留。
local ECHO_ESC = {
    a = "\a", b = "\b", e = "\27", E = "\27", f = "\f",
    n = "\n", r = "\r", t = "\t", v = "\v", ["\\"] = "\\",
}
--- 解释 -e 转义: 返回 (文本, 是否继续输出换行)。八进制 \0nnn / 十六进制 \xHH 按字节。
function F.echoEscapes(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c ~= "\\" then
            out[#out + 1] = c
            i = i + 1
        else
            local d = s:sub(i + 1, i + 1)
            if d == "" then
                out[#out + 1] = "\\"
                i = i + 1
            elseif d == "c" then
                return table.concat(out), false
            elseif d == "0" then
                local oct = s:match("^[0-7][0-7]?[0-7]?", i + 2) or ""
                out[#out + 1] = string.char((tonumber(oct, 8) or 0) % 256)
                i = i + 2 + #oct
            elseif d == "x" then
                local hex = s:match("^%x%x", i + 2)
                if hex then
                    out[#out + 1] = string.char(tonumber(hex, 16))
                    i = i + 4
                else
                    out[#out + 1] = "\\x"
                    i = i + 2
                end
            elseif ECHO_ESC[d] then
                out[#out + 1] = ECHO_ESC[d]
                i = i + 2
            else
                out[#out + 1] = "\\" .. d
                i = i + 2
            end
        end
    end
    return table.concat(out), true
end

--- echo: POSIX + 扩展 -n(不换行) / -e(解释转义), 可合并(-ne)。选项须在操作数之前; `--` 结束选项。
builtins.echo = function(args)
    local i, newline, escapes = 1, true, false
    while i <= #args do
        local a = args[i]
        if a == "--" then i = i + 1; break end
        if not a:match("^%-[neE]+$") then break end
        for k = 2, #a do
            local ch = a:sub(k, k)
            if ch == "n" then newline = false
            elseif ch == "e" then escapes = true
            elseif ch == "E" then escapes = false end  -- -E 关掉转义(与 /bin/echo 一致)
        end
        i = i + 1
    end
    local parts = {}
    for k = i, #args do parts[#parts + 1] = args[k] end
    local s = table.concat(parts, " ")
    if escapes then
        local cont
        s, cont = F.echoEscapes(s)
        newline = newline and cont -- \c 截断时不换行, 且不覆盖 -n
    end
    if outH and outH.write then
        -- POSIX echo: 写失败必须报错并给非 0 退出码。设备/属性文件(sysfs、/dev/lpN、管道)
        -- 的句柄失败时返回 nil, err; 真实文件句柄成功时也返回 nil(无 err), 故按 err 判定 ——
        -- 否则 `echo 15 > /sys/class/redstone/left/analog` 的失败会被静默吞掉。
        local okw, werr = outH:write(s .. (newline and "\n" or ""))
        if okw == nil and werr ~= nil then
            F.errln("echo: write error: " .. tostring(werr))
            lastExit = 1
        end
    end
end
builtins["true"] = function() end
builtins["false"] = function() lastExit = 1 end
builtins[":"] = function() end
-- cd [dir] / cd - / cd : POSIX —— 无参进 $HOME, `-` 回 $OLDPWD 并打印新目录。
-- PWD/OLDPWD 由 shell 维护(cd 后同步), 便于脚本与提示符使用。
builtins.cd = function(args)
    local arg = args[1]
    local target
    if arg == nil then
        local home = vars.HOME
        if not home or home == "" then F.errln("cd: HOME not set"); lastExit = 1; return end
        target = F.resolve(home)
    elseif arg == "-" then
        local old = vars.OLDPWD
        if not old or old == "" then F.errln("cd: OLDPWD not set"); lastExit = 1; return end
        target = F.resolve(old)
    else
        target = F.resolve(arg)
    end
    if not fs.isDir(target) then
        F.errln("cd: " .. (arg or "") .. ": No such directory"); lastExit = 1; return
    end
    vars.OLDPWD = cwd
    exported.OLDPWD = true -- bash 也导出 OLDPWD
    cwd = target
    vars.PWD = cwd
    if arg == "-" then F.outln(cwd) end
    lastExit = 0
end

function F.testEval(a)
    if #a == 0 then return false end
    if a[1] == "!" then return not F.testEval(F.tail(a)) end
    if #a == 1 then return a[1] ~= "" end
    if #a == 2 then
        local op = a[1]
        if op == "-n" then return a[2] ~= "" end
        if op == "-z" then return a[2] == "" end
        if fs.exists then
            if op == "-e" then return fs.exists(a[2]) end
            if op == "-f" then return fs.exists(a[2]) and fs.isFile and fs.isFile(a[2]) end
            if op == "-d" then return fs.isDir(a[2]) end
            if op == "-s" then return fs.exists(a[2]) and fs.getSize and fs.getSize(a[2]) > 0 end
            if op == "-x" then return (fs.canExecute and fs.canExecute(a[2])) or fs.exists(a[2]) end
            if op == "-r" then return fs.exists(a[2]) end
            if op == "-w" then return fs.exists(a[2]) end
        end
    end
    if #a == 3 then
        if a[2] == "=" then return a[1] == a[3] end
        if a[2] == "!=" then return a[1] ~= a[3] end
        local n1, n2 = tonumber(a[1]), tonumber(a[3])
        if n1 and n2 then
            if a[2] == "-eq" then return n1 == n2 end
            if a[2] == "-ne" then return n1 ~= n2 end
            if a[2] == "-lt" then return n1 < n2 end
            if a[2] == "-le" then return n1 <= n2 end
            if a[2] == "-gt" then return n1 > n2 end
            if a[2] == "-ge" then return n1 >= n2 end
        end
        if a[2] == "-a" then return F.testEval({ a[1] }) and F.testEval({ a[3] }) end
        if a[2] == "-o" then return F.testEval({ a[1] }) or F.testEval({ a[3] }) end
    end
    return false
end
builtins.test = function(args) lastExit = F.testEval(args) and 0 or 1 end
builtins["["] = function(args)
    if args[#args] == "]" then
        local t = {}
        for i = 1, #args - 1 do t[i] = args[i] end
        lastExit = F.testEval(t) and 0 or 1
    else
        lastExit = F.testEval(args) and 0 or 1
    end
end
builtins.exit = function(args) lastExit = tonumber(args[1]) or 0; return "exit" end
builtins["break"] = function(args) return "break" end
builtins.continue = function(args) return "continue" end
builtins["return"] = function(args) lastExit = tonumber(args[1]) or 0; return "return" end
builtins.shift = function(args)
    local n = tonumber(args[1]) or 1
    local np = {}
    for i = n + 1, #posArgs do np[#np + 1] = posArgs[i] end
    posArgs = np
end

-- ---------------------------------------------------------------
-- set / export / unset / . (POSIX 特殊内建)
-- ---------------------------------------------------------------
-- 选项短名 -> 长名(set -o 用长名)。
local optShort = { e = "errexit", u = "nounset", v = "verbose", x = "xtrace" }
local optLong = { errexit = "e", nounset = "u", verbose = "v", xtrace = "x" }
local optOrder = { "errexit", "nounset", "verbose", "xtrace" }

-- 列出全部 shell 变量(POSIX `set` 无参输出: 可重输入的 name='value', 按名排序)。
function F.listVars()
    local names = {}
    for name in pairs(vars) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do F.outln(name .. "=" .. F.quoteAssign(vars[name])) end
end
-- 列出导出变量(export / export -p)。
function F.listExported()
    local names = {}
    for name in pairs(exported) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do F.outln("export " .. name .. "=" .. F.quoteAssign(vars[name] or "")) end
end

-- set: 无参列变量; `set -- a b` 设位置参数; -e/-u/-v/-x 与 -o 选项(POSIX)。
-- 选项可合并(-ex); -/+ 分别开关; `set -o` 列选项状态, `set +o` 输出可重输入的 set 命令。
builtins.set = function(args)
    if #args == 0 then F.listVars(); lastExit = 0; return end
    local operands, sawPos = {}, false
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--" then
            sawPos = true
            for k = i + 1, #args do operands[#operands + 1] = args[k] end
            break
        elseif a == "-" then
            opt.xtrace, opt.verbose = false, false -- POSIX: `set -` 关闭 -v/-x
            i = i + 1
        elseif a == "-o" or a == "+o" then
            local on = (a == "-o")
            local name = args[i + 1]
            if name == nil then
                if on then
                    for _, n in ipairs(optOrder) do
                        F.outln(string.format("%-15s %s", n, opt[n] and "on" or "off"))
                    end
                else
                    for _, n in ipairs(optOrder) do F.outln("set " .. (opt[n] and "-" or "+") .. optLong[n]) end
                end
                lastExit = 0
                return
            end
            if not optLong[name] then F.errln("set: " .. name .. ": invalid option name"); lastExit = 2; return end
            opt[name] = on
            i = i + 2
        elseif a:match("^[%-%+][euvx]+$") then
            local on = a:sub(1, 1) == "-"
            for k = 2, #a do opt[optShort[a:sub(k, k)]] = on end
            i = i + 1
        elseif a:sub(1, 1) == "-" or a:sub(1, 1) == "+" then
            F.errln("set: " .. a .. ": invalid option"); lastExit = 2; return
        else
            operands[#operands + 1] = a
            sawPos = true
            i = i + 1
        end
    end
    -- 有位置参数操作数: 设位置参数(POSIX: `set a b` 等价于 `set -- a b`; `set --` 清空)。
    if sawPos then
        posArgs = operands
        lastExit = 0
    end
end

-- export [-p] [-n] [name[=value] ...]: 标记变量导出到子进程环境(内核环境块)。
builtins.export = function(args)
    local unexport, i = false, 1
    while i <= #args do
        local a = args[i]
        if a == "-p" then
            F.listExported(); lastExit = 0; return
        elseif a == "-n" then unexport = true; i = i + 1
        elseif a:match("^%-") and a ~= "-" then
            F.errln("export: " .. a .. ": invalid option"); lastExit = 2; return
        else
            local name, value = a:match("^([^=]+)=(.*)$")
            if not name then name = a end
            if not name:match("^[%a_][%w_]*$") then
                F.errln("export: " .. name .. ": not a valid identifier"); lastExit = 1; return
            end
            if value ~= nil then vars[name] = value end
            if unexport then
                exported[name] = nil
            else
                if vars[name] == nil then vars[name] = "" end -- POSIX: 未设置的变量按空值导出
                exported[name] = true
            end
            i = i + 1
        end
    end
    lastExit = 0
end

-- unset [-f] name...: 删除 shell 变量(默认)或函数(-f)。
builtins.unset = function(args)
    local func = false
    local names = {}
    for _, a in ipairs(args) do
        if a == "-f" then func = true
        elseif a == "-v" then func = false
        elseif a:match("^%-") and a ~= "-" then
            F.errln("unset: " .. a .. ": invalid option"); lastExit = 2; return
        else names[#names + 1] = a end
    end
    for _, name in ipairs(names) do
        if not name:match("^[%a_][%w_]*$") then
            F.errln("unset: " .. name .. ": not a valid identifier"); lastExit = 1; return
        end
        if func then
            if funcSrcs[name] then
                funcSrcs[name] = nil
                builtins[name] = nil
            end
        else
            vars[name] = nil
            exported[name] = nil
        end
    end
    lastExit = 0
end

-- . file [args...] (POSIX 特殊内建): 在当前环境执行文件里的命令 —— 变量/函数/cd 都作用于
-- 当前 shell(与 `sh file` 起子进程相对)。文件不必可执行, 只需可读; 名字不含 "/" 时查 $PATH。
-- 给了参数则临时替换位置参数(执行完恢复; bash/POSIX 语义), $0 不变。
builtins["."] = function(args)
    local file = args[1]
    if not file then F.errln(shName .. ": .: filename argument required"); lastExit = 2; return end
    local path = F.searchPath(file, false)
    if not path then F.errln(shName .. ": .: " .. file .. ": not found"); lastExit = 1; return end
    local h = fs.open(path, "r")
    if not h then F.errln(shName .. ": .: " .. path .. ": cannot open"); lastExit = 1; return end
    local src = (h.readAll and h:readAll()) or ""
    h:close()
    local saveArgs = posArgs
    if #args > 1 then
        local a = {}
        for k = 2, #args do a[#a + 1] = args[k] end
        posArgs = a
    end
    local ok, inc, perr, ctrl = F.evalProgram(src)
    posArgs = saveArgs
    if inc then
        F.errln(shName .. ": .: " .. path .. ": syntax error: unexpected end of file"); lastExit = 2; return
    end
    if not ok and perr then
        F.errln(shName .. ": .: " .. path .. ": " .. tostring(perr)); lastExit = 2; return
    end
    if ctrl then return ctrl end -- exit 等控制信号透传给当前 shell
    return nil -- lastExit 已由文件里最后一条命令设置
end
-- read [-r] var...: 从当前 stdin 读一整行, 按 IFS 分割后赋给变量(POSIX read)。
-- 无 -r 时反斜杠转义下一个字符(被转义的字符即使是 IFS 也不是分隔符), 行尾反斜杠为续行;
-- 多于变量的字段全部归最后一个变量(保留中间分隔符, 去掉尾部 IFS 空白)。EOF 时变量置空并返回 >0。
builtins.read = function(args)
    local raw = false
    local names = {}
    for _, a in ipairs(args) do
        if a == "-r" then raw = true
        elseif a:sub(1, 1) == "-" and a ~= "-" then
            F.errln("read: " .. a .. ": invalid option"); lastExit = 2; return
        else names[#names + 1] = a end
    end
    if #names == 0 then F.errln("read: variable name required"); lastExit = 2; return end
    for _, n in ipairs(names) do
        if not n:match("^[%a_][%w_]*$") then
            F.errln("read: " .. n .. ": not a valid variable name"); lastExit = 2; return
        end
    end
    if not (inH and inH.readLine) then F.errln("read: stdin is not readable"); lastExit = 1; return end

    -- 逐字符收集: chars 为字符, esc 标记该字符是否由反斜杠转义(转义的 IFS 不是分隔符)。
    local chars, esc = {}, {}
    function F.add(c, e)
        local k = #chars + 1
        chars[k] = c; esc[k] = e or false
    end
    local eof = false
    while true do
        local l = inH:readLine()
        if l == nil then eof = true; break end
        if raw then
            for k = 1, #l do F.add(l:sub(k, k), false) end
            break
        end
        local i, cont = 1, false
        while i <= #l do
            if l:sub(i, i) == "\\" then
                if i == #l then cont = true; break end -- 行尾反斜杠: 续行
                F.add(l:sub(i + 1, i + 1), true); i = i + 2
            else
                F.add(l:sub(i, i), false); i = i + 1
            end
        end
        if not cont then break end
    end

    local n = #chars
    function F.isDelim(i) return not esc[i] and F.isIfs(chars[i]) end
    function F.isWs(i) return not esc[i] and F.isIfsWs(chars[i]) end
    local fields = {}
    local i = 1
    while i <= n and F.isWs(i) do i = i + 1 end
    for fi = 1, #names - 1 do
        if i > n then break end
        local f = {}
        while i <= n and not F.isDelim(i) do f[#f + 1] = chars[i]; i = i + 1 end
        fields[fi] = table.concat(f)
        -- 吃掉分隔符: IFS 空白 + 至多一个非空白 IFS 字符 + 其后的 IFS 空白
        while i <= n and F.isWs(i) do i = i + 1 end
        if i <= n and F.isDelim(i) and not F.isWs(i) then i = i + 1 end
        while i <= n and F.isWs(i) do i = i + 1 end
    end
    -- 最后一个变量: 剩余字符(去掉尾部未转义的 IFS 空白)
    local last = n
    while last >= i and F.isWs(last) do last = last - 1 end
    local rest = {}
    for k = i, last do rest[#rest + 1] = chars[k] end
    fields[#names] = table.concat(rest)
    for idx, name in ipairs(names) do vars[name] = fields[idx] or "" end
    lastExit = eof and 1 or 0
end

-- ===============================================================
-- 别名 (POSIX alias/unalias)
-- ===============================================================
-- POSIX 的别名是在**解析期**做首词替换(词法阶段就换掉了), 因此别名体里可以写完整语法
-- (`alias ll='ls -l | more'`), 也能写 `alias e=echo` 后 `e$x`。
-- Delin 的解析器是手写递归下降, 在词法/语法层插钩子要改的面向很大, 所以改成**求值期**替换:
-- 认出首词是别名后, 把"别名体 + 其余已展开的词"重新解析执行(红由外层 evalSimple 已布好, 会
-- 一并继承)。对日常用法(别名带参数/管道/重定向/多条命令)与 POSIX 行为一致。
-- 已知偏离(写进 for-ai.md): 别名体里的位置参数($1 等)展开时机与 POSIX 不同; 别名不参与
-- "词内"替换(`alias e=echo; e$x` 这种在 POSIX 里能展开, 这里不能)。
local aliases = {}
local aliasExpanding = {} -- name -> true: 正在展开的别名(防 `alias ls='ls -a'` 这类自递归)

--- 把已展开的一个词重新引用成字面量(别名体重新解析时要保持"参数已经展开过"这个事实)。
function F.quoteAsLiteral(s)
    if s == "" then return "''" end
    if s:match("^[%w_%-%.%/:=@%%,%+%^]+$") then return s end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- 若 cmd 命中别名则接管执行; 返回 true 表示已处理。
function F.tryAlias(cmd, rest)
    local val = aliases[cmd]
    if not val or aliasExpanding[cmd] then return false end
    local parts = { val }
    for _, w in ipairs(rest) do parts[#parts + 1] = F.quoteAsLiteral(w) end
    aliasExpanding[cmd] = true
    local ok, inc, err, ctrl = F.evalProgram(table.concat(parts, " "))
    aliasExpanding[cmd] = nil
    if not ok then
        if inc then
            F.errln(shName .. ": alias '" .. cmd .. "': unexpected end of input")
        elseif err then
            F.errln(shName .. ": alias '" .. cmd .. "': " .. tostring(err))
        end
        lastExit = 2
        return true
    end
    if ctrl == "exit" then return true, "exit" end
    return true
end

builtins.alias = function(args)
    if #args == 0 then
        -- 无操作数: 按名排序列出全部别名, 形如 `alias name=value`(可直接重输入)。
        local names = {}
        for n in pairs(aliases) do names[#names + 1] = n end
        table.sort(names)
        for _, n in ipairs(names) do F.outln("alias " .. n .. "=" .. F.quoteAsLiteral(aliases[n])) end
        lastExit = 0
        return
    end
    local rc = 0
    for _, a in ipairs(args) do
        local n, v = a:match("^([^=]+)=(.*)$")
        if n then
            aliases[n] = v
        elseif aliases[a] then
            F.outln("alias " .. a .. "=" .. F.quoteAsLiteral(aliases[a]))
        else
            F.errln(shName .. ": alias: " .. a .. ": not found")
            rc = 1
        end
    end
    lastExit = rc
    return
end

builtins.unalias = function(args)
    if #args == 0 then
        F.errln(shName .. ": unalias: usage: unalias [-a] name [name ...]")
        lastExit = 2
        return
    end
    local rc = 0
    for _, a in ipairs(args) do
        if a == "-a" then
            aliases = {}
        elseif aliases[a] then
            aliases[a] = nil
        else
            F.errln(shName .. ": unalias: " .. a .. ": not found")
            rc = 1
        end
    end
    lastExit = rc
end

-- ===============================================================
-- 命令路径缓存 (POSIX hash)
-- ===============================================================
-- 缓存本体(hashCache/hashSync)定义在 searchPath 之前 —— 那里就要用它; 这里只是 `hash` 内建。

builtins.hash = function(args)
    if #args > 0 and args[1] == "-r" then
        table.remove(args, 1)
        hashCache.map = {}
        hashCache.path = vars.PATH
        if #args == 0 then lastExit = 0; return end
    end
    if #args == 0 then
        local names = {}
        for n in pairs(hashCache.map) do names[#names + 1] = n end
        table.sort(names)
        for _, n in ipairs(names) do F.outln(n .. "=" .. hashCache.map[n]) end
        lastExit = 0
        return
    end
    -- 带操作数: 重新定位这些命令并写入缓存(POSIX: 找不到则退出码非 0)。
    local rc = 0
    F.hashSync()
    for _, n in ipairs(args) do
        local p = F.searchPath(n, true)
        if p then hashCache.map[n] = p
        else F.errln(shName .. ": hash: " .. n .. ": not found"); rc = 1 end
    end
    lastExit = rc
    return
end

-- ===============================================================
-- umask (POSIX 特殊内建之一; 本内核把它当普通内建, 见下)
-- ===============================================================
function F.umaskBitSet(v, b) return math.floor(v / (2 ^ b)) % 2 == 1 end
function F.umaskSetBit(v, b, on)
    local bit = 2 ^ b
    if on then return F.umaskBitSet(v, b) and v or (v + bit) end
    return F.umaskBitSet(v, b) and (v - bit) or v
end

--- 把一个符号模式(如 u=rwx,g=rx,o=)在基准权限上求值, 返回权限位; 语法错返回 nil。
function F.parseSymbolicPerms(base, spec)
    local cur = base % 512
    for clause in spec:gmatch("[^,]+") do
        local who, op, perms = clause:match("^([ugoa]*)([-+=])([rwx]*)$")
        -- perms 允许为空: `o=` 是"清掉 o 的全部权限", 完全合法。
        if not who then return nil end
        if who == "" then who = "a" end
        local ops = {}
        for i = 1, #perms do
            local c = perms:sub(i, i)
            if c == "r" then ops[#ops + 1] = 2
            elseif c == "w" then ops[#ops + 1] = 1
            else ops[#ops + 1] = 0 end
        end
        local groups = {}
        if who:find("u") then groups[#groups + 1] = 6 end
        if who:find("g") then groups[#groups + 1] = 3 end
        if who:find("o") then groups[#groups + 1] = 0 end
        if #groups == 0 then return nil end
        for _, shift in ipairs(groups) do
            if op == "=" then
                for _, b in ipairs({ 2, 1, 0 }) do cur = F.umaskSetBit(cur, shift + b, false) end
            end
            for _, b in ipairs(ops) do cur = F.umaskSetBit(cur, shift + b, op ~= "-") end
        end
    end
    return cur
end

--- 权限位 -> 符号形式 u=rwx,g=rx,o=rx (umask -S 用)。
function F.permsToSymbolic(perms)
    function F.part(shift)
        local g = math.floor(perms / (2 ^ shift)) % 8
        return (g % 2 == 1 and "" or "") .. ((math.floor(g / 4) % 2 == 1) and "r" or "")
            .. ((math.floor(g / 2) % 2 == 1) and "w" or "") .. ((g % 2 == 1) and "x" or "")
    end
    return "u=" .. F.part(6) .. ",g=" .. F.part(3) .. ",o=" .. F.part(0)
end

function F.umaskGet()
    if syscalls and syscalls["umask.get"] then return syscalls["umask.get"]() end
    return tonumber("022", 8)
end

builtins.umask = function(args)
    local symbolic = false
    local operands = {}
    for _, a in ipairs(args) do
        if a == "-S" then symbolic = true else operands[#operands + 1] = a end
    end
    if #operands == 0 then
        local m = F.umaskGet()
        if symbolic then F.outln(F.permsToSymbolic(tonumber("777", 8) - m)) else F.outln(string.format("%04o", m)) end
        lastExit = 0
        return
    end
    if #operands > 1 then
        F.errln(shName .. ": umask: too many arguments")
        lastExit = 2
        return
    end
    local spec = operands[1]
    local mask
    if spec:match("^[0-7]+$") then
        mask = tonumber(spec, 8)
        if not mask or mask > tonumber("777", 8) then
            F.errln(shName .. ": umask: " .. spec .. ": octal number out of range")
            lastExit = 2
            return
        end
    else
        -- 符号模式: POSIX 规定按"允许的权限"给出, 再取补得到掩码。
        local perms = F.parseSymbolicPerms(tonumber("777", 8), spec)
        if not perms then
            F.errln(shName .. ": umask: " .. spec .. ": invalid symbolic mode")
            lastExit = 2
            return
        end
        mask = tonumber("777", 8) - perms
    end
    if not (syscalls and syscalls["umask.set"]) then
        F.errln(shName .. ": umask: kernel does not support umask.set")
        lastExit = 1
        return
    end
    local ok, err = syscalls["umask.set"](mask)
    if ok == nil then
        F.errln(shName .. ": umask: " .. tostring(err))
        lastExit = 1
        return
    end
    lastExit = 0
end

-- ===============================================================
-- getopts (POSIX 内建)
-- ===============================================================
-- 状态只有"当前参数内已消费到第几个字符", 以及它属于哪一个 OPTIND —— OPTIND 被脚本改动过
-- 就必须重新开始扫描该参数(POSIX 要求 OPTIND 可写且语义如此)。
local getoptsChar = 0
local getoptsOptind = nil

builtins.getopts = function(args)
    local optstring = args[1]
    local name = args[2]
    if not optstring or not name then
        F.errln(shName .. ": getopts: usage: getopts optstring name [arg...]")
        lastExit = 2
        return
    end
    local silent = false
    if optstring:sub(1, 1) == ":" then silent = true; optstring = optstring:sub(2) end
    local list
    if #args > 2 then
        list = {}
        for i = 3, #args do list[#list + 1] = args[i] end
    else
        list = posArgs
    end

    local optind = tonumber(vars.OPTIND or "1") or 1
    if getoptsOptind ~= optind then getoptsChar = 0; getoptsOptind = optind end

    function F.finish() getoptsOptind = optind; vars.OPTIND = tostring(optind) end

    while true do
        local arg = list[optind]
        if arg == nil then
            -- 选项结束(POSIX: 返回 >0, 并把 name 置为 "?")。
            vars[name] = "?"
            F.finish()
            lastExit = 1; return
        end
        if getoptsChar == 0 then
            if arg == "--" then
                optind = optind + 1
                vars[name] = "?"
                F.finish()
                lastExit = 1; return
            end
            -- 非选项(不以 "-" 开头, 或就是单独的 "-")即结束。
            if arg:sub(1, 1) ~= "-" or arg == "-" then
                vars[name] = "?"
                F.finish()
                lastExit = 1; return
            end
            getoptsChar = 2 -- 跳过前导 "-"
        end
        if getoptsChar > #arg then
            optind = optind + 1
            getoptsChar = 0
        else
            local ch = arg:sub(getoptsChar, getoptsChar)
            getoptsChar = getoptsChar + 1
            local pos = optstring:find(ch, 1, true)
            if not pos then
                -- 未知选项
                if getoptsChar > #arg then optind = optind + 1; getoptsChar = 0 end
                if silent then
                    vars.OPTARG = nil
                    vars[name] = "?"
                else
                    vars.OPTARG = nil
                    vars[name] = "?"
                    F.errln(shName .. ": illegal option -- " .. ch)
                end
                F.finish()
                lastExit = 0; return
            end
            if optstring:sub(pos + 1, pos + 1) == ":" then
                -- 需要参数: 粘连在同一个词里, 或取下一个词
                if getoptsChar <= #arg then
                    vars.OPTARG = arg:sub(getoptsChar)
                    optind = optind + 1
                    getoptsChar = 0
                    vars[name] = ch
                    F.finish()
                    lastExit = 0; return
                end
                optind = optind + 1
                getoptsChar = 0
                local nxt = list[optind]
                if nxt == nil then
                    if silent then
                        vars[name] = ":"
                        vars.OPTARG = ch
                    else
                        vars[name] = "?"
                        vars.OPTARG = nil
                        F.errln(shName .. ": option requires an argument -- " .. ch)
                    end
                    F.finish()
                    lastExit = 0; return
                end
                vars.OPTARG = nxt
                optind = optind + 1
                vars[name] = ch
                F.finish()
                lastExit = 0; return
            end
            -- 普通选项
            if getoptsChar > #arg then optind = optind + 1; getoptsChar = 0 end
            vars.OPTARG = nil
            vars[name] = ch
            F.finish()
            lastExit = 0; return
        end
    end
end

-- ===============================================================
-- command (POSIX: 绕过函数/别名直接执行; -v/-V 查询)
-- ===============================================================
--- 判断一个名字是不是"用户定义的 shell 函数"(funcSrcs 里登记的就是)。
function F.isFunction(n) return funcSrcs[n] ~= nil end
--- 判断一个名字是不是 shell 自己的内建(排除同名函数覆盖)。
function F.isShellBuiltin(n) return builtins[n] ~= nil and not F.isFunction(n) end

builtins.command = function(args)
    local useDefaultPath, verbose, describe = false, false, false
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--" then i = i + 1; break
        elseif a == "-p" then useDefaultPath = true
        elseif a == "-v" then verbose = true
        elseif a == "-V" then describe = true
        elseif a:sub(1, 1) == "-" and #a > 1 then
            F.errln(shName .. ": command: illegal option -- " .. a:sub(2, 2))
            lastExit = 2
            return
        else break end
        i = i + 1
    end
    local rest = {}
    for k = i, #args do rest[#rest + 1] = args[k] end

    if verbose or describe then
        if #rest == 0 then
            F.errln(shName .. ": command: usage: command [-pVv] command [arg ...]")
            lastExit = 2
            return
        end
        local rc = 0
        for _, n in ipairs(rest) do
            local how, detail
            if aliases[n] then
                how, detail = "alias", "an alias for " .. F.quoteAsLiteral(aliases[n])
            elseif F.isFunction(n) then
                how, detail = "function", "a shell function"
            elseif F.isShellBuiltin(n) then
                how, detail = "builtin", "a shell builtin"
            else
                local p = useDefaultPath and F.searchInPath(n, "/bin", true) or F.searchPath(n, true)
                if p then how, detail = "file", p end
            end
            if not how then
                F.errln(shName .. ": command: " .. n .. ": not found")
                rc = 1
            elseif describe then
                F.outln(n .. " is " .. detail)
            elseif how == "file" then
                F.outln(detail)
            else
                F.outln(n)
            end
        end
        lastExit = rc
        return
    end

    if #rest == 0 then
        F.errln(shName .. ": command: usage: command [-pVv] command [arg ...]")
        lastExit = 2
        return
    end
    local cmd = rest[1]
    local cargs = {}
    for k = 2, #rest do cargs[#cargs + 1] = rest[k] end
    -- 绕过函数: 函数登记在 builtins 里, 这里显式跳过它们(别名本来就在首词替换阶段绕过了,
    -- 因为 `command` 自己才是首词)。
    if builtins[cmd] and not F.isFunction(cmd) then
        local ctrl = builtins[cmd](cargs)
        if ctrl == "exit" then return "exit" end
        return
    end
    if F.isFunction(cmd) then
        -- 有同名函数时按 PATH 找外部命令执行。
        local p = useDefaultPath and F.searchInPath(cmd, "/bin", true) or F.searchPath(cmd, true)
        if not p then
            F.errln(shName .. ": command: " .. cmd .. ": not found")
            lastExit = 127
            return
        end
        F.runExternal(p, cargs, nil, cmd)
        return
    end
    F.runExternal(cmd, cargs, nil, cmd)
end

-- ===============================================================
-- setopt / unsetopt(zsh 风格)
-- ===============================================================
-- 管的是**所有真实存在的开关**: 核心那四个(与 `set -o` 同源, 改的就是同一份状态)与 desh 的
-- 三个开关(它们本来就是普通 shell 变量, 所以两边改的是同一处)。名字不区分大小写, 支持 zsh 的
-- `NO_` 前缀(setopt no_autosuggest == unsetopt autosuggest, 反向同理)。
-- 不认识的开关 **fail-fast 退出 2**(与仓库里其它"未知选项"同一约定): 静默收下会让脚本以为
-- 开关生效了 —— 那正是最危险的一种"看着跑过了"。
--- 变量形式的开关: 未设置视为开, "0"/""/"no"/"false" 视为关(与 desh 的 cfgOn 同一判据)。
function F.optVarOn(name)
    local v = vars[name]
    if v == nil then return true end
    return not (v == "0" or v == "" or v == "no" or v == "false")
end

local OPTS = {
    { name = "errexit",    desc = "exit on a failing command (set -e)",
      get = function() return opt.errexit end,   set = function(v) opt.errexit = v end },
    { name = "nounset",    desc = "error on unset variables (set -u)",
      get = function() return opt.nounset end,   set = function(v) opt.nounset = v end },
    { name = "verbose",    desc = "echo each command before running it (set -v)",
      get = function() return opt.verbose end,   set = function(v) opt.verbose = v end },
    { name = "xtrace",     desc = "trace expanded commands to stderr (set -x)",
      get = function() return opt.xtrace end,    set = function(v) opt.xtrace = v end },
    -- desh 的三个开关(前端每次用时现读这些变量, 见 src/bin/desh 的 cfgOn)
    { name = "autosuggest", desc = "grey inline history suggestion (desh)",
      get = function() return F.optVarOn("DESH_AUTOSUGGEST") end,
      set = function(v) vars.DESH_AUTOSUGGEST = v and "1" or "0" end },
    { name = "correct",    desc = "'did you mean' for unknown commands (desh)",
      get = function() return F.optVarOn("DESH_CORRECT") end,
      set = function(v) vars.DESH_CORRECT = v and "1" or "0" end },
    { name = "history",    desc = "keep the history file (desh)",
      get = function() return F.optVarOn("DESH_HISTORY") end,
      set = function(v) vars.DESH_HISTORY = v and "1" or "0" end },
}

--- 找选项(名字小写化; 支持 NO_ 前缀, 返回 opt, wantOn)。
local function findOpt(name)
    local n = tostring(name):lower():gsub("%-", "_")
    local want = true
    if n:sub(1, 3) == "no_" then want = false; n = n:sub(4) end
    for _, o in ipairs(OPTS) do
        if o.name == n then return o, want end
    end
    return nil
end

local function setOptBuiltin(args, on)
    local verb = on and "setopt" or "unsetopt"
    if #args == 0 then
        local names = {}
        for _, o in ipairs(OPTS) do
            if o.get() == on then names[#names + 1] = o.name end
        end
        table.sort(names)
        for _, n in ipairs(names) do F.outln(n) end
        lastExit = 0
        return
    end
    local rc = 0
    for _, a in ipairs(args) do
        if a == "--help" then
            F.outln("usage: " .. shName .. " " .. verb .. " [OPTION ...]"
                .. "   (no OPTION: list " .. (on and "enabled" or "disabled") .. " options)")
            for _, o in ipairs(OPTS) do
                F.outln(string.format("  %-12s %-4s %s", o.name, (o.get() and "on" or "off"), o.desc))
            end
            return
        end
        local o, want = findOpt(a)
        if not o then
            F.errln(shName .. ": " .. verb .. ": " .. a .. ": unknown option")
            rc = 2
        else
            -- setopt NAME / unsetopt NAME / setopt no_NAME / unsetopt no_NAME 四种组合:
            -- "这次是不是 setopt" 与 "名字有没有 NO_ 前缀" 相同就是开, 不同就是关。
            -- 别写成 `on and want or not want` —— want=false 时 Lua 的 and/or 会翻成 true。
            local value
            if on == want then value = true else value = false end
            o.set(value)
        end
    end
    lastExit = rc
end

builtins.setopt = function(args) return setOptBuiltin(args, true) end
builtins.unsetopt = function(args) return setOptBuiltin(args, false) end

builtins.help = function(args)
    F.outln("Delin " .. shName .. " (POSIX core subset)")
    F.outln("builtins : cd pwd echo read exit help jobs fg bg wait kill test [ true false :")
    F.outln("           . set export unset break continue return shift setopt unsetopt")
    F.outln("external : ls cat rm mkdir cp mv touch head tail wc grep sed ed chmod chown login clear")
    F.outln("usage    : " .. shName .. " [-c cmd [name [args...]]] [script] [args...]   (no script => interactive/stdin)")
    F.outln("options  : set -e(errexit) -u(nounset) -v(verbose) -x(xtrace) -o <name>; $- lists flags")
    F.outln("           setopt/unsetopt <name> (zsh style: errexit nounset verbose xtrace autosuggest correct history)")
    F.outln("vars     : PATH HOME PWD OLDPWD USER SHELL TERM PPID PS1 PS2 PS3 PS4 IFS (export to pass to children)")
    F.outln("terminal : $TERM=linux (16-color ANSI); echo -e '\\e[31mred' ; clear")
end

local ttyName = (stdin and stdin.getDeviceName) and stdin:getDeviceName() or nil
local shPg, jobs, nextJid, sigintPending = nil, {}, 0, false
-- 作业控制: 交互式 + 有控制终端 + 内核提供进程组 syscall。
-- 非交互 sh 也记账作业(`cmd &` + `wait`), 但不建进程组、不可 fg/bg —— POSIX 规定无作业控制
-- 时异步列表的 stdin 指向 /dev/null(否则后台作业会与前台抢键盘)。
local hasJobCtl = interactive and ttyName and syscalls and syscalls["job.setpgid"]
if hasJobCtl then
    syscalls["job.setpgid"](pid, 0)
    shPg = syscalls["job.group"]()
    syscalls["job.tcsetpgrp"](ttyName, shPg)
    syscalls["signal.install"](20, function() end)
    syscalls["signal.install"](2, function() sigintPending = true end)
end
-- POSIX $? : 正常退出为退出码, 信号死亡为 128+signo。
function F.exitStatus(reason, code)
    if reason ~= "exited" then return 1 end
    code = code or 0
    if code < 0 then return 128 - code end
    return code
end
function F.pollWait(pidIn)
    while true do
        local p = syscalls["proc.info"](pidIn)
        if not p then return "exited", -1 end
        if p.status == "dead" then return "exited", (p.termSig and -p.termSig) or (p.exitCode or 0)
        elseif p.status == "error" then return "error", p.error
        elseif p.status == "stopped" then return "stopped", p
        end
        -- ^C 中断: 杀子进程并返回。
        if sigintPending then
            sigintPending = false
            syscalls["signal.kill"](pidIn, 9) -- SIGKILL
            msleep(0) -- 等调度器处理退出
            return "exited", -2
        end
        -- 轮询子进程状态: HSE 下 5ms 一次(命令结束/退出码的可见延迟从 ~50ms 降到 ~5ms),
        -- 没有 HSE 时 5ms 的 msleep 会退化成 50ms 的 os.sleep, 所以直接按平台取间隔。
        msleep(_pollMs)
    end
end

-- 作业状态以内核进程表为准(外部信号可能已把它停止/继续)。
---@return string|nil  "Running"|"Stopped"|"Done"|nil(进程已消失)
function F.jobStatus(j)
    local p = syscalls["proc.info"](j.pid)
    if not p then return nil end
    if p.status == "dead" or p.status == "error" then return "Done" end
    if p.status == "stopped" then return "Stopped" end
    return "Running"
end
function F.removeJob(j)
    for i, x in ipairs(jobs) do if x == j then table.remove(jobs, i); return end end
end
-- 出队已结束的作业; verbose 时逐个报告(交互式在提示符前调用, 对齐 bash)。
function F.reapJobs(verbose)
    local keep = {}
    for _, j in ipairs(jobs) do
        local st = F.jobStatus(j)
        if st == nil or st == "Done" then
            if verbose then F.outln("[" .. j.jid .. "]+ Done  " .. j.cmd) end
        else
            j.status = st
            keep[#keep + 1] = j
        end
    end
    jobs = keep
end
-- 作业引用: 缺省/`%%`/`%+` = 当前作业, `%-` = 前一个作业, `%n` = 作业号, 数字 = pid。
function F.resolveJob(ref)
    if not ref or ref == "%%" or ref == "%+" then return jobs[#jobs] end
    if ref == "%-" then return jobs[#jobs - 1] end
    local n = tonumber(tostring(ref):match("^%%(%d+)$"))
    if n then for _, j in ipairs(jobs) do if j.jid == n then return j end end end
    if tonumber(ref) then local pn = tonumber(ref); for _, j in ipairs(jobs) do if j.pid == pn then return j end end end
end

-- 子 shell 前置注入: 变量赋值 + 函数定义原文 + 别名。Delin 无 fork, 子 shell 是新进程,
-- 不注入就会让 `echo $x &` 的 $x 展开成空串、`$(ll)` 变成 command not found —— 静默错, 比报错更糟。
function F.quoteShell(s)
    return "'" .. tostring(s):gsub("'", "'\"'\"'") .. "'"
end
function F.subshellPrologue()
    local parts = {}
    for name, val in pairs(vars) do
        -- PPID 不注入: 子 shell 用内核给的父 pid(否则 `sh -c 'echo $PPID'` 会报祖先进程)。
        if name ~= "PPID" and name:match("^[%a_][%w_]*$") then
            parts[#parts + 1] = name .. "=" .. F.quoteShell(val)
        end
    end
    table.sort(parts) -- 确定性输出(便于真机日志比对)
    -- 导出标记也要注入: 否则子 shell 里 export 过的变量对孙进程不可见。
    local exp = {}
    for name in pairs(exported) do exp[#exp + 1] = name end
    table.sort(exp)
    if #exp > 0 then parts[#parts + 1] = "export " .. table.concat(exp, " ") end
    for _, src in pairs(funcSrcs) do parts[#parts + 1] = src end
    -- 别名也要注入: Delin 的别名是**求值期**替换, 子 shell(`&` 的作业 / `$( )`)里没有它,
    -- `alias ll='ls -l'; echo $(ll)` 就变成 command not found。整条 `name=body` 加引号,
    -- 名字或别名体里有空格也不会把子 shell 的语法拆坏。
    local al = {}
    for name, body in pairs(aliases) do al[#al + 1] = F.quoteShell(name .. "=" .. body) end
    table.sort(al)
    if #al > 0 then parts[#parts + 1] = "alias " .. table.concat(al, " ") end
    return parts
end

-- ---------------------------------------------------------------
-- 命令替换 $( ) / ` `
-- ---------------------------------------------------------------
-- 在**子 shell**里跑 text 并捕获它的 stdout(POSIX 2.6.3):
--   - Delin 无 fork, 用 `sh -c <原文>` 起子进程(与 `&` 的作业同一套办法), 变量/函数/导出标记
--     经 subshellPrologue 注入; 因此子 shell 里的赋值/`cd` 不影响父 shell(POSIX 语义)。
--   - stdout 接内核 pipe, 子进程退出(内核 onExit 关掉写端)后 readAll 读到 EOF;
--     读端阻塞时让出调度器, 所以子进程能一直写到结束(与管道的流控同源)。
--   - 结果末尾的换行**全部**删除(POSIX); 子进程退出码进 $?(bash 同此)。
cmdSubst = function(text)
    local r, w = syscalls["pipe.create"]()
    if not r then F.expandFail("command substitution: pipe create failed"); return "" end
    local prologue = F.subshellPrologue()
    prologue[#prologue + 1] = text
    local cargv = { "-c", table.concat(prologue, "; "), posArg0 }
    for i = 1, #posArgs do cargv[#cargv + 1] = posArgs[i] end
    local child, cerr = F.spawnChild("sh", cargv, { input = inH, output = w })
    if not child then
        pcall(r.close); pcall(w.close)
        F.expandFail("command substitution: " .. tostring(cerr))
        return ""
    end
    -- 写端**不能**在父进程里关: 子进程的 stdio 与本进程共用同一个管道句柄对象
    -- (内核 spawn 不复制句柄), 父进程一关就等于把写端关了 —— 读端立刻 EOF, 子进程写不进去。
    -- 子进程退出时由内核 process.onExit 关掉它, 那时 writers 归零, readAll 才读到 EOF。
    local out = (r.readAll and r:readAll()) or ""
    pcall(r.close)
    local reason, code = F.pollWait(child)
    lastExit = F.exitStatus(reason, code)
    substRan = true
    return (out:gsub("\n+$", ""))
end

-- ---------------------------------------------------------------
-- 算术展开 $(( ))  (POSIX 2.6.4)
-- ---------------------------------------------------------------
-- C 风格整数运算: 一元 + - ! ~, 二元 * / % + - << >> < <= > >= == != & ^ |, && ||,
-- 三目 ?:, 赋值 = += -= *= /= %= <<= >>= &= ^= |=, 自增自减(前缀/后缀), 逗号。
-- 变量读写 shell 变量(POSIX: `i=0; echo $((i+=1))` 之后 $i 是 1); 变量的值若本身是
-- 表达式就**递归**求值(与 bash 一致: `x='1+2'; echo $((x))` 得 3, 未定义/空 = 0)。
-- CC 的 Lua 没有位运算: 按 32 位补码用纯算术实现(与 C 的 int 语义对齐)。

--- 算术表达式文本里的参数/命令替换展开(POSIX: $(( )) 求值前先做参数展开与命令替换)。
--- 只处理 $name/${name}/$( )/` ` 与引号移除; **裸标识符保持原样** —— 它们在算术里是变量名,
--- 由求值阶段当 shell 变量解析(`x=1; echo $((x+1))` 的 x 不能在这层被展开)。
function F.expandTextForArith(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "\\" and i < n then out[#out + 1] = s:sub(i + 1, i + 1); i = i + 2
        elseif c == "'" then
            local j = s:find("'", i + 1, true)
            if not j then error("unterminated quote", 0) end
            out[#out + 1] = s:sub(i + 1, j - 1); i = j + 1
        elseif c == '"' then
            local j = s:find('"', i + 1, true)
            if not j then error("unterminated quote", 0) end
            out[#out + 1] = F.expandTextForArith(s:sub(i + 1, j - 1)); i = j + 1
        elseif c == "$" and s:sub(i + 1, i + 2) == "((" then
            local body, ni = F.scanArith(s, i)
            if not body then error("unterminated arithmetic expansion", 0) end
            out[#out + 1] = F.arithStr(body); i = ni
        elseif c == "$" and s:sub(i + 1, i + 1) == "(" then
            local body, ni = F.scanCmdSub(s, i + 2)
            if not body then error("unterminated command substitution", 0) end
            out[#out + 1] = cmdSubst(body); i = ni
        elseif c == "$" then
            local name, ni = F.readVarName(s, i + 1)
            if name then out[#out + 1] = F.getVarVal(name); i = ni
            else out[#out + 1] = "$"; i = i + 1 end
        elseif c == "`" then
            local body, ni = F.scanBacktick(s, i)
            if not body then error("unterminated command substitution", 0) end
            out[#out + 1] = cmdSubst(body); i = ni
        else out[#out + 1] = c; i = i + 1 end
    end
    return table.concat(out)
end

local ARITH_MAXDEPTH = 24 -- 变量递归求值的深度上限(自引用要 fail-fast, 不能挂死)

function F.u32(v) return v % 4294967296 end
function F.s32(v)
    v = F.u32(v)
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end
function F.bitOp(a, b, f)
    a, b = F.u32(a), F.u32(b)
    local r, bit = 0, 1
    for _ = 1, 32 do
        local x, y = a % 2, b % 2
        if f(x, y) then r = r + bit end
        a, b, bit = (a - x) / 2, (b - y) / 2, bit * 2
    end
    return F.s32(r)
end
function F.shl(a, b)
    b = math.floor(b)
    if b < 0 then return F.shr(a, -b) end
    if b >= 32 then return 0 end
    return F.s32(F.u32(a) * 2 ^ b)
end
function F.shr(a, b)
    b = math.floor(b)
    if b < 0 then return F.shl(a, -b) end
    a = math.floor(a)
    if b >= 32 then return a < 0 and -1 or 0 end
    -- 算术右移(C 的 int 语义): 负数补 1。
    return math.floor(a / 2 ^ b)
end

-- 解析出的表达式树。求值阶段才读变量(两者分开是必须的: `?:`/`&&`/`||` 要短边求值,
-- 否则 `$(( x != 0 ? 1/x : 0 ))` 会在 x=0 时炸掉)。
arithParse = function(text)
    local toks, i, n = {}, 1, #text
    local OP2 = { ["<<"]=1, [">>"]=1, ["<="]=1, [">="]=1, ["=="]=1, ["!="]=1,
                  ["&&"]=1, ["||"]=1, ["++"]=1, ["--"]=1,
                  ["+="]=1, ["-="]=1, ["*="]=1, ["/="]=1, ["%="]=1,
                  ["&="]=1, ["^="]=1, ["|="]=1 }
    local OP3 = { ["<<="]=1, [">>="]=1 }
    local ASSIGN = { ["="]=1, ["+="]=1, ["-="]=1, ["*="]=1, ["/="]=1, ["%="]=1,
                     ["<<="]=1, [">>="]=1, ["&="]=1, ["^="]=1, ["|="]=1 }
    while i <= n do
        local c = text:sub(i, i)
        if c:match("%s") then i = i + 1
        elseif c:match("%d") then
            local num = text:match("^0[xX][%x]+", i) or text:match("^%d+", i)
            i = i + #num
            toks[#toks + 1] = { t = "num", v = num }
        elseif c:match("[%a_]") then
            local name = text:match("^[%a_][%w_]*", i)
            i = i + #name
            toks[#toks + 1] = { t = "id", v = name }
        else
            local three = text:sub(i, i + 2)
            local two = text:sub(i, i + 1)
            if OP3[three] then toks[#toks + 1] = { t = "op", v = three }; i = i + 3
            elseif OP2[two] then toks[#toks + 1] = { t = "op", v = two }; i = i + 2
            elseif c:match("[%+%-%*/%%<>=!~&%^|%?%:,%(%)]") then
                toks[#toks + 1] = { t = "op", v = c }; i = i + 1
            else error("invalid character '" .. c .. "'", 0) end
        end
    end
    local p = 1
    function F.peekOp() local tk = toks[p]; if tk and tk.t == "op" then return tk.v end end
    function F.eat(op)
        if F.peekOp() ~= op then return false end
        p = p + 1
        return true
    end
    function F.expect(op)
        if not F.eat(op) then error("'" .. op .. "' expected", 0) end
    end
    function F.number(tk)
        local s = tk.v
        if s:match("^0[xX]") then return tonumber(s:sub(3), 16) end
        if #s > 1 and s:sub(1, 1) == "0" then
            -- C 风格八进制; 出现 8/9 就是非法常量(fail-fast 而不是猜一个十进制值)。
            if s:match("[89]") then error("invalid octal constant " .. s, 0) end
            return tonumber(s, 8)
        end
        return tonumber(s, 10)
    end
    local parseExpr, parseAssign, parseCond, parseBinary, parseUnary, parsePrimary, parsePostfix
    local LEVELS = {
        { "||" }, { "&&" }, { "|" }, { "^" }, { "&" }, { "==", "!=" },
        { "<=", ">=", "<", ">" }, { "<<", ">>" }, { "+", "-" }, { "*", "/", "%" },
    }
    parseBinary = function(level)
        if level > #LEVELS then return parseUnary() end
        local node = parseBinary(level + 1)
        while true do
            local op = F.peekOp()
            local found = false
            for _, o in ipairs(LEVELS[level]) do if o == op then found = true end end
            if not found then return node end
            p = p + 1
            node = { k = "bin", op = op, l = node, r = parseBinary(level + 1) }
        end
    end
    parseCond = function()
        local c = parseBinary(1)
        if F.eat("?") then
            local a = parseAssign()
            F.expect(":")
            local b = parseCond()
            return { k = "cond", c = c, a = a, b = b }
        end
        return c
    end
    parseAssign = function()
        local tk = toks[p]
        if tk and tk.t == "id" then
            local nx = toks[p + 1]
            if nx and nx.t == "op" and ASSIGN[nx.v] then
                local name = tk.v
                p = p + 2
                return { k = "assign", op = nx.v, name = name, e = parseAssign() }
            end
        end
        return parseCond()
    end
    parseExpr = function()
        local node = parseAssign()
        while F.eat(",") do node = { k = "comma", l = node, r = parseAssign() } end
        return node
    end
    parseUnary = function()
        local op = F.peekOp()
        if op == "+" or op == "-" or op == "!" or op == "~" then
            p = p + 1
            return { k = "un", op = op, e = parseUnary() }
        end
        if op == "++" or op == "--" then
            p = p + 1
            local t = toks[p]
            if not (t and t.t == "id") then error("variable expected after " .. op, 0) end
            p = p + 1
            return { k = "pre", op = op, name = t.v }
        end
        return parsePostfix()
    end
    parsePostfix = function()
        local node = parsePrimary()
        while (F.peekOp() == "++" or F.peekOp() == "--") and node.k == "var" do
            node = { k = "post", op = F.peekOp(), name = node.name }
            p = p + 1
        end
        return node
    end
    parsePrimary = function()
        local tk = toks[p]
        if not tk then error("operand expected", 0) end
        if tk.t == "num" then p = p + 1; return { k = "num", v = F.number(tk) } end
        if tk.t == "id" then p = p + 1; return { k = "var", name = tk.v } end
        if tk.v == "(" then
            p = p + 1
            local node = parseExpr()
            F.expect(")")
            return node
        end
        error("unexpected '" .. tostring(tk.v) .. "'", 0)
    end
    local root = parseExpr()
    if p <= #toks then error("unexpected '" .. tostring(toks[p].v) .. "'", 0) end
    return root
end

F.arithGet = function(name, depth)
    depth = depth or 0
    if depth > ARITH_MAXDEPTH then error("expression recursion too deep", 0) end
    local v = vars[name]
    if v == nil or v == "" then return 0 end
    local num = tonumber(v)
    if num then return math.floor(num) end
    -- 值不是整数常量: 按算术表达式递归求值(POSIX; bash 同此, 'abc' 当未定义变量 -> 0)。
    return F.arithValue(arithParse(v), depth + 1)
end

--- C 的整数除法: 向**零**截断(Lua 的 math.floor 是向下取整, 负数会差 1: -7/2 应为 -3)。
function F.arithDiv(a, b)
    if b == 0 then error("division by zero", 0) end
    local q = a / b
    if q < 0 then return -math.floor(-q) end
    return math.floor(q)
end

F.arithEvalBin = function(op, a, b)
    if op == "+" then return a + b end
    if op == "-" then return a - b end
    if op == "*" then return a * b end
    if op == "/" then return F.arithDiv(a, b) end
    if op == "%" then
        if b == 0 then error("division by zero", 0) end
        return a - F.arithDiv(a, b) * b -- C 的 %: 结果符号跟被除数
    end
    if op == "<<" then return F.shl(a, b) end
    if op == ">>" then return F.shr(a, b) end
    if op == "<" then return a < b and 1 or 0 end
    if op == "<=" then return a <= b and 1 or 0 end
    if op == ">" then return a > b and 1 or 0 end
    if op == ">=" then return a >= b and 1 or 0 end
    if op == "==" then return a == b and 1 or 0 end
    if op == "!=" then return a ~= b and 1 or 0 end
    if op == "&" then return F.bitOp(a, b, function(x, y) return x == 1 and y == 1 end) end
    if op == "|" then return F.bitOp(a, b, function(x, y) return x == 1 or y == 1 end) end
    if op == "^" then return F.bitOp(a, b, function(x, y) return x ~= y end) end
    error("unsupported operator '" .. op .. "'", 0)
end

F.arithValue = function(node, depth)
    local k = node.k
    if k == "num" then return node.v end
    if k == "var" then return F.arithGet(node.name, depth) end
    if k == "comma" then F.arithValue(node.l, depth); return F.arithValue(node.r, depth) end
    if k == "un" then
        local v = F.arithValue(node.e, depth)
        if node.op == "+" then return v end
        if node.op == "-" then return -v end
        if node.op == "!" then return v == 0 and 1 or 0 end
        return F.s32(-v - 1) -- ~
    end
    if k == "pre" or k == "post" then
        local old = F.arithGet(node.name, depth)
        local nv = (node.op == "++") and old + 1 or old - 1
        vars[node.name] = tostring(nv)
        return (k == "pre") and nv or old
    end
    if k == "assign" then
        local old = (node.op == "=") and 0 or F.arithGet(node.name, depth)
        local rhs = F.arithValue(node.e, depth)
        local nv
        if node.op == "=" then nv = rhs else nv = F.arithEvalBin(node.op:sub(1, -2), old, rhs) end
        vars[node.name] = tostring(nv)
        return nv
    end
    if k == "bin" then
        local op = node.op
        if op == "&&" then
            if F.arithValue(node.l, depth) == 0 then return 0 end
            return F.arithValue(node.r, depth) ~= 0 and 1 or 0
        end
        if op == "||" then
            if F.arithValue(node.l, depth) ~= 0 then return 1 end
            return F.arithValue(node.r, depth) ~= 0 and 1 or 0
        end
        return F.arithEvalBin(op, F.arithValue(node.l, depth), F.arithValue(node.r, depth))
    end
    if k == "cond" then
        return F.arithValue(node.c, depth) ~= 0 and F.arithValue(node.a, depth) or F.arithValue(node.b, depth)
    end
    error("bad arithmetic node", 0)
end

--- $((expr)) 的求值入口: 表达式先做参数/命令替换(POSIX 顺序), 再解析求值。
--- 出错一律 fail-fast(记 expandFail, 让当前命令中止), 不静默当 0。
F.arithStr = function(text)
    local lhs = text:gsub("^%s+", ""):gsub("%s+$", "")
    if lhs == "" then
        F.expandFail("$(( " .. text .. " )): expression expected")
        return ""
    end
    -- 表达式里的 $var / $( ) / ` ` 先展开(POSIX: 算术展开前先做参数与命令替换)。
    -- **必须在 pcall 之前**: 命令替换会 os.sleep(让出调度器), 而 Lua 5.1 不允许跨 pcall 让出
    -- ("attempt to yield across metamethod/C-call boundary"); 解析/求值本身不 yield, 才敢包。
    local ex = F.expandTextForArith(lhs)
    if expandFailed then return "" end
    -- 注意: 实参在 pcall **之前**求值, 所以解析必须写在闭包体里, 否则语法错会逃出 pcall。
    local ok, v = pcall(function() return F.arithValue(arithParse(ex), 0) end)
    if not ok then
        F.expandFail("$(( " .. text .. " )): " .. tostring(v))
        return ""
    end
    v = math.floor(v)
    if v == 0 then return "0" end
    return string.format("%.0f", v)
end

-- 后台执行一个列表项(POSIX 异步列表)。Delin 无 fork: 用 `sh -c <原文>` 起一个子 shell,
-- 内置命令/管道/复合命令因此都在子进程里跑, 不污染父 shell 状态。
function F.startBackground(text)
    if not text then F.errln(shName .. ": &: empty command"); lastExit = 1; return end
    local input = inH
    if not hasJobCtl then
        input = fs.open("/dev/null", "r")
        if not input then F.errln(shName .. ": &: /dev/null unavailable"); lastExit = 1; return end
    end
    local prologue = F.subshellPrologue()
    prologue[#prologue + 1] = text
    local argv = { "-c", table.concat(prologue, "; "), posArg0 }
    for i = 1, #posArgs do argv[#argv + 1] = posArgs[i] end
    local child, cerr = F.spawnChild("sh", argv, { input = input, output = outH })
    if not child then
        F.errln(shName .. ": &: " .. tostring(cerr))
        lastExit = (cerr == "command not found") and 127 or 126
        return
    end
    -- 有作业控制时给作业一个自己的进程组: kill %n / fg / bg / ^C 都按组路由。
    local pgid = nil
    if hasJobCtl then
        local ok, e = syscalls["job.setpgid"](child, child)
        if not ok then F.errln(shName .. ": setpgid: " .. tostring(e)); lastExit = 1; return end
        pgid = child
    end
    nextJid = nextJid + 1
    jobs[#jobs + 1] = { jid = nextJid, pid = child, pgid = pgid, cmd = text, status = "Running" }
    lastBgPid = child
    if interactive then F.outln("[" .. nextJid .. "] " .. child) end
    lastExit = 0
end

builtins.jobs = function(args)
    local showPid, onlyPgid = false, false
    for _, a in ipairs(args) do
        if a == "-l" then showPid = true
        elseif a == "-p" then onlyPgid = true
        elseif a == "-lp" or a == "-pl" then showPid, onlyPgid = true, true
        else F.errln("jobs: " .. a .. ": invalid option"); lastExit = 2; return end
    end
    F.reapJobs(true) -- 已结束的作业先报告并出队(bash 行为)
    for i, j in ipairs(jobs) do
        local mark = (i == #jobs) and "+" or ((i == #jobs - 1) and "-" or " ")
        if onlyPgid then F.outln(j.pgid or j.pid)
        elseif showPid then F.outln(string.format("[%d]%s %d %-8s %s", j.jid, mark, j.pid, j.status, j.cmd))
        else F.outln(string.format("[%d]%s %-8s %s", j.jid, mark, j.status, j.cmd)) end
    end
    lastExit = 0
end
builtins.fg = function(args)
    if not hasJobCtl then F.errln("fg: no job control"); lastExit = 1; return end
    F.reapJobs(true)
    local j = F.resolveJob(args[1])
    if not j then F.errln("fg: no such job"); lastExit = 1; return end
    local st = F.jobStatus(j)
    if st == nil then F.removeJob(j); F.errln("fg: job has terminated"); lastExit = 1; return end
    local ok, e = syscalls["job.tcsetpgrp"](ttyName, j.pgid)
    if not ok then F.errln("fg: tcsetpgrp: " .. tostring(e)); lastExit = 1; return end
    if st == "Stopped" then
        syscalls["signal.killpg"](j.pgid, 18) -- SIGCONT
        j.status = "Running"
        -- 等调度器把 SIGCONT 投递下去: 否则 proc.info 仍报旧 stopped, 会把"上次停止"当成本次。
        local waited = 0
        while waited < 1000 do
            local p = syscalls["proc.info"](j.pid)
            if not p or p.status ~= "stopped" then break end
            msleep(_pollMs); waited = waited + _pollMs
        end
    end
    local reason, code = F.pollWait(j.pid)
    syscalls["job.tcsetpgrp"](ttyName, shPg)
    if reason == "stopped" then
        j.status = "Stopped"
        F.outln("[" .. j.jid .. "]+ Stopped  " .. j.cmd)
        lastExit = 148 -- 128 + SIGTSTP
        return
    end
    F.removeJob(j)
    lastExit = F.exitStatus(reason, code)
end
builtins.bg = function(args)
    if not hasJobCtl then F.errln("bg: no job control"); lastExit = 1; return end
    F.reapJobs(true)
    local j = F.resolveJob(args[1])
    if not j then F.errln("bg: no such job"); lastExit = 1; return end
    if F.jobStatus(j) == nil then F.removeJob(j); F.errln("bg: job has terminated"); lastExit = 1; return end
    local ok, e = syscalls["signal.killpg"](j.pgid, 18) -- SIGCONT
    if not ok then F.errln("bg: " .. tostring(e)); lastExit = 1; return end
    j.status = "Running"
    F.outln("[" .. j.jid .. "]+ " .. j.cmd .. " &")
    lastExit = 0
end
builtins.wait = function(args)
    if #args == 0 then
        -- 等全部运行中的后台作业(已停止的作业不会被等: 与 bash 一致, 先 fg/bg 处理它)。
        for _, j in ipairs(jobs) do
            if F.jobStatus(j) == "Running" then F.pollWait(j.pid) end
        end
        F.reapJobs(false)
        lastExit = 0
        return
    end
    local st = 0
    for _, ref in ipairs(args) do
        local j = F.resolveJob(ref)
        local target = j and j.pid or tonumber(ref)
        local p = target and syscalls["proc.info"](target)
        if not p then
            F.errln("wait: " .. tostring(ref) .. ": not a child of this shell")
            st = 127
        else
            local reason, code = F.pollWait(target)
            st = (reason == "stopped") and 148 or F.exitStatus(reason, code) -- 148 = 128 + SIGTSTP
            if j then F.removeJob(j) end
        end
    end
    lastExit = st
end
builtins.kill = function(args)
    local sig, targets = 15, {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-l" or a == "-L" then
            local nxt = args[i + 1]
            if nxt and nxt:match("^%-?%d+$") then
                F.outln(syscalls["signal.name"](tonumber((nxt:gsub("^%-", "")))) or "?")
            elseif nxt then
                local n = syscalls["signal.number"]((nxt:gsub("^%-", "")):gsub("^SIG", ""))
                F.outln(n and tostring(n) or "?")
                if not n then lastExit = 1 end
            else
                local nums = (syscalls and syscalls["signal.list"] and syscalls["signal.list"]()) or {}
                local t = {}
                for _, s in ipairs(nums) do t[#t + 1] = syscalls["signal.name"](s) end
                F.outln(table.concat(t, " "))
            end
            return
        elseif a == "-s" or a == "--signal" then
            i = i + 1
            local nm = args[i]
            if not nm then F.errln("kill: -s: option requires an argument"); lastExit = 1; return end
            local n = tonumber(nm) or syscalls["signal.number"](nm:gsub("^%-", ""):gsub("^SIG", ""))
            if not n then F.errln("kill: " .. nm .. ": invalid signal"); lastExit = 1; return end
            sig = n
        elseif a:match("^%-%d+$") then
            sig = tonumber(a:sub(2))
        elseif a:match("^%-%-?[%a]+$") then
            -- `-TSTP` / `-SIGTSTP` / `--TSTP`: 去前缀查名, 未知信号 fail-fast
            -- (旧实现直接把带 `-` 的原文交给 signal.number, 查不到就静默降级成 SIGTERM)。
            local n = syscalls["signal.number"](a:gsub("^%-%-?", ""):gsub("^SIG", ""))
            if not n then F.errln("kill: " .. a .. ": invalid signal"); lastExit = 1; return end
            sig = n
        else
            targets[#targets + 1] = a
        end
        i = i + 1
    end
    if #targets == 0 then F.errln("usage: kill [-SIG] pid|%job ..."); lastExit = 1; return end
    for _, tgt in ipairs(targets) do
        if tostring(tgt):match("^%%") then
            local j = F.resolveJob(tgt)
            if not j then F.errln("kill: no such job " .. tgt); lastExit = 1
            elseif j.pgid then -- 有作业控制: 整组投递
                local ok, e = syscalls["signal.killpg"](j.pgid, sig)
                if not ok then F.errln("kill: " .. tgt .. ": " .. tostring(e)); lastExit = 1 end
            else -- 无作业控制(非交互 sh): 作业没有独立进程组, 直接投给进程
                local ok, e = syscalls["signal.kill"](j.pid, sig)
                if not ok then F.errln("kill: " .. tgt .. ": " .. tostring(e)); lastExit = 1 end
            end
        else
            local ok, e = syscalls["signal.kill"](tonumber(tgt), sig)
            if not ok then F.errln("kill: " .. tostring(tgt) .. ": " .. tostring(e)); lastExit = 1 end
        end
    end
end

-- 解析命令为可执行路径(POSIX PATH 查找, 见 searchPath)。找不到返回 nil。
function F.commandPath(cmd)
    return F.searchPath(cmd, true)
end

-- 读首行(用于 shebang 检测)。
function F.firstLine(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local line = (f.readLine and f:readLine()) or ""
    f:close()
    return line
end

-- 解析 shebang 行: `#!interp [arg]` -> interp, arg|nil。
function F.parseShebang(line)
    if line and line:sub(1, 2) == "#!" then
        local rest = line:sub(3):gsub("^%s+", "")
        local interp, arg = rest:match("^(%S+)%s+(.-)%s*$")
        if interp then return interp, (arg and arg ~= "" and arg or nil) end
        if rest ~= "" then return rest, nil end
    end
    return nil, nil
end

-- spawn 失败时的错误文本。**内核与测试台把消息放在不同的位置**, 必须两个都看:
-- 内核 process.spawn 失败返回 (nil, nil, "load failed: ...") —— 消息在第 3 个返回值上,
-- 而宿主测试台的 spawn 桩返回 (nil, "load failed: ...")。以前只取第 2 个, 于是真机上
-- 装载失败时 shell 只打一句 `sh: <命令>: nil`, 真正的原因(装载错误)被吞掉了。
function F.spawnErr(e1, e2)
    return tostring(e1 or e2)
end

-- 定位并 spawn 一个外部程序/脚本(不等待)。返回 pid, err。
--   - 无 shebang: 视作 Delin Lua 程序(现有 /bin/* 行为)直接 spawn。
--   - 带 shebang: 以解释器跑脚本 —— 解释器路径(绝对或 PATH)解析; `env` 特判取下一程序名。
F.spawnChild = function(cmd, argv, stdio)
    local path = F.commandPath(cmd)
    if not path then return nil, "command not found" end
    if not fs.canExecute(path) then return nil, "permission denied" end
    -- 子进程环境块 = 本 shell 导出的变量(export); 内核负责与父环境合并。
    local sopts = { cwd = cwd, env = F.exportEnv() }
    if stdio then sopts.stdio = stdio end
    local interp, iarg = F.parseShebang(F.firstLine(path))
    local f, src, cargv
    if interp then
        local prog = interp
        if interp:match("[^/]+$") == "env" then
            prog = iarg
            if not prog then return nil, "shebang: env without a program" end
            iarg = nil
        end
        local interpPath = F.commandPath(prog)
        if not interpPath then return nil, "shebang interpreter not found: " .. prog end
        if not fs.canExecute(interpPath) then return nil, "shebang interpreter not executable: " .. prog end
        f = fs.open(interpPath, "r")
        if not f then return nil, "permission denied" end
        src = f:readAll(); f:close()
        cargv = { [0] = interpPath }
        local n = 1
        if iarg and iarg ~= "" then cargv[n] = iarg; n = n + 1 end
        cargv[n] = path; n = n + 1
        for i = 1, #argv do cargv[n] = argv[i]; n = n + 1 end
        local child, e1, e2 = spawn(src, interpPath, nil, nil, cargv, sopts)
        if not child then return nil, F.spawnErr(e1, e2) end
        return child
    end
    f = fs.open(path, "r")
    if not f then return nil, "permission denied" end
    src = f:readAll(); f:close()
    cargv = { [0] = path }
    for i = 1, #argv do cargv[i] = argv[i] end
    local child, e1, e2 = spawn(src, cmd, nil, nil, cargv, sopts)
    if not child then return nil, F.spawnErr(e1, e2) end
    return child
end

-- 前台作业: 有作业控制时给作业独立进程组并把它设为 tty 前台(^C/^Z 路由到它),
-- 运行结束把 tty 收回归 shell。作业被 ^Z 停止时入作业表, 之后可 fg/bg。
function F.fgGive(pgid)
    if not hasJobCtl then return end
    local ok, e = syscalls["job.tcsetpgrp"](ttyName, pgid)
    if not ok then F.errln(shName .. ": tcsetpgrp: " .. tostring(e)) end
end
function F.fgTakeBack()
    if not hasJobCtl then return end
    local ok, e = syscalls["job.tcsetpgrp"](ttyName, shPg)
    if not ok then F.errln(shName .. ": tcsetpgrp(back): " .. tostring(e)) end
end
function F.registerStopped(cmd, pid, pgid)
    nextJid = nextJid + 1
    jobs[#jobs + 1] = { jid = nextJid, pid = pid, pgid = pgid, cmd = cmd, status = "Stopped" }
    F.outln("[" .. nextJid .. "]+ Stopped  " .. cmd)
end
-- 给子进程建独立进程组(第一个成员即组长)。返回 pgid, err。
function F.newJobGroup(pid, pgid)
    local ok, e = syscalls["job.setpgid"](pid, pgid or pid)
    if not ok then return nil, e end
    return pgid or pid
end

F.runExternal = function(cmd, argv, stdio, text)
    local child, cerr = F.spawnChild(cmd, argv, stdio)
    if not child then
        F.errln(shName .. ": " .. cmd .. ": " .. tostring(cerr))
        lastExit = (cerr == "command not found") and 127 or 126
        -- 前端纠错钩子(desh 的 did-you-mean): 只打印建议, 退出码/后续流程不受影响。
        if UI and UI.commandNotFound then UI.commandNotFound(cmd) end
        return
    end
    local pgid = nil
    if hasJobCtl then
        local e
        pgid, e = F.newJobGroup(child)
        if not pgid then F.errln(shName .. ": setpgid: " .. tostring(e)); lastExit = 1; return end
        F.fgGive(pgid)
    end
    local reason, code = F.pollWait(child)
    if pgid then F.fgTakeBack() end
    if reason == "stopped" then
        F.registerStopped(text or cmd, child, pgid)
        lastExit = 148 -- 128 + SIGTSTP
        return
    end
    lastExit = F.exitStatus(reason, code)
end

F.restoreRedir = function(out, inp)
    if out then outH = stdout end
    if inp then inH = stdin end
end

-- 赋值前缀(命令作用域): 返回 restore 表, 或 nil 表示"留在当前环境"(特殊内建/函数/纯赋值)。
-- avals 是**已展开**的值(name -> 串): 命令替换有副作用, 一条命令里每个词只能展开一次,
-- 所以调用方先展开好再传进来(xtrace 也复用这份结果, 否则 `x=$(cmd)` 会跑两次)。
function F.expandAssignValues(node)
    local vals = {}
    for i, a in ipairs(node.assigns) do
        -- 赋值右侧: **不做字段分割/通配符**(POSIX), 但波浪号展开要(bash 的 `X=~/bin`)。
        vals[i] = F.expandGlue(F.tildeExpandSegs(a.value))
        if expandFailed then return nil end
    end
    return vals
end

function F.applyAssigns(node, avals)
    if #node.assigns == 0 then return nil end
    local restore
    if #node.argv > 0 then
        local w = node.argv[1]
        local nm = (w and #w == 1) and w[1].raw or nil
        if not (nm and (specialBuiltins[nm] or funcSrcs[nm])) then restore = {} end
    end
    for i, a in ipairs(node.assigns) do
        local v = avals[i]
        if restore then restore[a.name] = vars[a.name] end
        vars[a.name] = v
    end
    return restore
end
function F.undoAssigns(restore)
    if restore then for k, v in pairs(restore) do vars[k] = v end end
end

-- xtrace(-x): 每条命令展开后、执行前写一行到 stderr, 前缀是展开后的 PS4(bash 风格)。
-- 仅记单词显示用: 含特殊字符的词加单引号, 不保证可重输入。
function F.quoteTrace(w)
    if w == "" then return "''" end
    if w:match("^[%w%-%._/:=@%+,]+$") then return w end
    return "'" .. w:gsub("'", "'\\''") .. "'"
end
function F.xtraceLine(parts)
    if not opt.xtrace then return end
    local e = io.stderr()
    if e and e.write then e:write(F.promptExpand(vars.PS4 or "") .. table.concat(parts, " ") .. "\n") end
end
-- avals/rtargets: 调用方**已经展开好**的赋值值与重定向目标(不再展开第二遍)。
function F.xtraceCmd(node, argvs, avals, rtargets)
    if not opt.xtrace then return end
    local parts = {}
    for i, a in ipairs(node.assigns) do
        parts[#parts + 1] = a.name .. "=" .. F.quoteTrace(avals and avals[i] or "")
    end
    for _, w in ipairs(argvs) do parts[#parts + 1] = F.quoteTrace(w) end
    for i, r in ipairs(node.redirects) do
        parts[#parts + 1] = r.op
        parts[#parts + 1] = F.quoteTrace(rtargets and rtargets[i] or "")
    end
    F.xtraceLine(parts)
end

F.evalSimple = function(node)
    -- set -u: 先查本命令要用的变量, 再动任何东西(重定向/赋值/执行)。
    local abort, ctrl0 = F.nounsetCheck(F.simpleWords(node))
    if abort then return lastExit, ctrl0 end
    local needOut, needIn = false, false
    local openOut, openIn = {}, {}
    substRan = false
    -- 展开期致命错误(算术非法/除零/命令替换起不来)后的收尾: 关句柄、还原 fd、返回 1。
    function F.fail()
        if not F.expandAbort() then return false end
        for _, h in ipairs(openOut) do if h.close then pcall(h.close) end end
        for _, h in ipairs(openIn) do if h.close then pcall(h.close) end end
        F.restoreRedir(needOut, needIn)
        return true
    end
    -- 重定向目标先展开(通配符必须是恰好一个词), 打开顺序保持从左到右。
    local rtargets = {}
    for i, r in ipairs(node.redirects) do
        rtargets[i] = F.expandRedirTarget(r.target)
        if F.fail() then return lastExit end
        local abs = F.resolve(rtargets[i])
        if r.op == "<" then
            local h = fs.open(abs, "r")
            if not h then F.errln(shName .. ": " .. abs .. ": cannot open"); lastExit = 1; F.restoreRedir(needOut, needIn); return lastExit end
            inH = h; needIn = true; openIn[#openIn + 1] = h
        elseif r.op == ">" then
            local h = fs.open(abs, "w")
            if not h then F.errln(shName .. ": " .. abs .. ": cannot open"); lastExit = 1; F.restoreRedir(needOut, needIn); return lastExit end
            outH = h; needOut = true; openOut[#openOut + 1] = h
        elseif r.op == ">>" then
            local h = fs.open(abs, "a")
            if not h then F.errln(shName .. ": " .. abs .. ": cannot open"); lastExit = 1; F.restoreRedir(needOut, needIn); return lastExit end
            outH = h; needOut = true; openOut[#openOut + 1] = h
        end
    end
    local avals = F.expandAssignValues(node)
    if F.fail() then return lastExit end
    local restore = F.applyAssigns(node, avals)
    local ctrl
    if #node.argv == 0 then
        F.xtraceCmd(node, {}, avals, rtargets)
        -- POSIX: 没有命令词时, 退出码 = 最后一次命令替换的退出码(没有就是 0),
        -- 所以 `x=$(false)` 之后 $? 是 1(bash/dash 同此)。
        lastExit = substRan and lastExit or 0
    else
        -- 先展开 argv($? 等用上一条命令的退出码), 再为本命令重置 lastExit。
        local argvs = F.expandWords(node.argv)
        if not argvs then
            F.undoAssigns(restore)
            F.fail()
            return lastExit
        end
        lastExit = 0
        -- 展开成零个词(如无参数的 `"$@"`)是无操作(POSIX), 不是"找不到命令"。
        if #argvs > 0 then
            F.xtraceCmd(node, argvs, avals, rtargets)
            local cmd, rest = argvs[1], {}
            for i = 2, #argvs do rest[#rest + 1] = argvs[i] end
            -- 别名先于内建/外部命令(POSIX: 别名替换发生在查找内建之前)。
            local aliasCtrl
            local handled
            handled, aliasCtrl = F.tryAlias(cmd, rest)
            if handled then
                ctrl = aliasCtrl
            elseif builtins[cmd] then
                ctrl = builtins[cmd](rest)
            else
                local s = (needOut or needIn) and { input = inH, output = outH } or nil
                F.runExternal(cmd, rest, s, node.src)
            end
        end
    end
    F.undoAssigns(restore)
    -- 关闭重定向打开的句柄(真正落盘): CC 句柄写入可能缓冲, 需 flush/close 才提交。
    for _, h in ipairs(openOut) do if h.close then pcall(h.close) end end
    for _, h in ipairs(openIn) do if h.close then pcall(h.close) end end
    F.restoreRedir(needOut, needIn)
    return lastExit or 0, ctrl
end

-- 关闭某管道元素负责的管道端: i>1 关闭其输入读端, i<n 关闭其输出写端(让下游读到 EOF)。
function F.closePipeEl(i, n, pipes)
    if i > 1 then local r = pipes[i - 1].read; if r and r.close then pcall(r.close) end end
    if i < n then local w = pipes[i].write;  if w and w.close then pcall(w.close) end end
end

-- 求值一个管道 a|b|c:
--   - 每个元素是一个进程/内建; 元素 i 的 stdin=pipe[i-1].read, stdout=pipe[i].write
--     (两端元素分别用 sh 当前的 stdin/stdout)。
--   - 先 spawn 全部外部元素(并发跑, 使后续内置元素阻塞时调度器能驱动它们腾缓冲),
--     再运行内置元素(设其 inH/outH 后调用, 运行完关闭其管道端)。
--   - 退出码 = 最后一个元素; 管道建不起/某元素不可用时分段容错。
F.evalPipe = function(node)
    local items = node.items
    local n = #items
    if n <= 1 then return evalNode(items[1]) end
    -- set -u: 执行前先检查各 simple 元素要用的变量(复合元素的内部命令由 evalNode 自查)。
    for i = 1, n do
        if items[i].kind == "simple" then
            local abort, ctrl = F.nounsetCheck(F.simpleWords(items[i]))
            if abort then return lastExit, ctrl end
        end
    end
    local pipes = {}
    for i = 1, n - 1 do
        local r, w = syscalls["pipe.create"]()
        if not r then F.errln("pipe: create failed"); lastExit = 1; return 1 end
        pipes[i] = { read = r, write = w }
    end
    local savedOut, savedIn = outH, inH
    local info, spawned, codes, openedRedirs = {}, {}, {}, {}
    -- 展开期致命错误(算术/命令替换)的收尾: 释放管道端与已开的句柄, 整条管道以 1 中止。
    function F.pipeFail()
        if not F.expandAbort() then return false end
        for _, h in ipairs(openedRedirs) do if h.close then pcall(h.close) end end
        for k = 1, n - 1 do
            if pipes[k] then pcall(pipes[k].read.close); pcall(pipes[k].write.close) end
        end
        return true
    end
    -- Pass A: 展开每个元素 argv, 判定内置/外部, 计算各自 stdio 句柄。
    -- 元素自身重定向(> >> <)覆盖该元素 fd0/fd1; 被覆盖而作废的管道端立即 close(让对端读到 EOF)。
    for i = 1, n do
        local defIn  = (i == 1) and savedIn or pipes[i - 1].read
        local defOut = (i == n) and savedOut or pipes[i].write
        local inp, outp = defIn, defOut
        for _, r in ipairs(items[i].redirects or {}) do
            local tgt = F.expandRedirTarget(r.target)
            if F.pipeFail() then return lastExit end
            local abs = F.resolve(tgt)
            if r.op == "<" then
                local h = fs.open(abs, "r")
                if h then inp = h; openedRedirs[#openedRedirs + 1] = h
                else F.errln(shName .. ": " .. abs .. ": cannot open"); lastExit = 1 end
            elseif r.op == ">" then
                local h = fs.open(abs, "w")
                if h then outp = h; openedRedirs[#openedRedirs + 1] = h
                else F.errln(shName .. ": " .. abs .. ": cannot open"); lastExit = 1 end
            elseif r.op == ">>" then
                local h = fs.open(abs, "a")
                if h then outp = h; openedRedirs[#openedRedirs + 1] = h
                else F.errln(shName .. ": " .. abs .. ": cannot open"); lastExit = 1 end
            end
        end
        if defIn  and defIn.pipe  and defIn ~= inp   then pcall(defIn.close)   end
        if defOut and defOut.pipe and defOut ~= outp then pcall(defOut.close) end
        local node = items[i]
        if node.kind == "simple" then
            local argvs = F.expandWords(node.argv)
            if not argvs then
                if F.pipeFail() then return lastExit end
            end
            if #argvs == 0 then
                -- 展开成零个词: 无操作元素(只需让下游读到 EOF)。
                info[i] = { noop = true, inH = inp, outH = outp, kind = "simple" }
            else
                local cmd, rest = argvs[1], {}
                for k = 2, #argvs do rest[#rest + 1] = argvs[k] end
                -- 别名优先于内建(POSIX 语义); 命中的元素由 Pass C 用 tryAlias 跑。
                local isAlias = aliases[cmd] ~= nil
                info[i] = { cmd = cmd, rest = rest, inH = inp, outH = outp,
                            alias = isAlias, builtin = (not isAlias) and builtins[cmd] ~= nil,
                            kind = "simple" }
            end
        else
            -- 复合命令(if/for/while/case/funcdef/brace)作为管道元素: 内联运行, 经 inH/outH 连通管道。
            info[i] = { node = node, inH = inp, outH = outp, kind = "compound" }
        end
    end
    -- Pass B: spawn 全部外部元素(有作业控制时同属一个进程组, 整体作前台作业)。
    local pgid, leader = nil, nil
    for i = 1, n do
        local it = info[i]
        if it.cmd and not it.builtin and not it.alias then
            local pid, cerr = F.spawnChild(it.cmd, it.rest, { input = it.inH, output = it.outH })
            if pid then
                spawned[i] = pid
                leader = leader or pid
                if hasJobCtl then
                    local e
                    pgid, e = F.newJobGroup(pid, pgid)
                    if not pgid then F.errln(shName .. ": setpgid: " .. tostring(e)); lastExit = 1 end
                end
            else
                codes[i] = (cerr == "command not found") and 127 or 126
                F.errln(shName .. ": " .. it.cmd .. ": " .. tostring(cerr))
                F.closePipeEl(i, n, pipes) -- 元素未起进程, 必须自行释放其管道端让下游读到 EOF。
            end
        end
    end
    if pgid then F.fgGive(pgid) end
    -- Pass C: 运行内置/复合命令元素。
    for i = 1, n do
        local it = info[i]
        if it.noop then
            F.closePipeEl(i, n, pipes)
            codes[i] = 0
        elseif it.cmd and (it.builtin or it.alias) then
            inH, outH = it.inH, it.outH
            lastExit = 0
            local avals = F.expandAssignValues(items[i])
            if not avals then
                inH, outH = savedIn, savedOut
                F.pipeFail()
                return lastExit
            end
            local restore = F.applyAssigns(items[i], avals)
            local ctrl, handled
            if it.alias then handled, ctrl = F.tryAlias(it.cmd, it.rest) end
            if not handled and not it.alias then ctrl = builtins[it.cmd](it.rest) end
            F.undoAssigns(restore)
            inH, outH = savedIn, savedOut
            F.closePipeEl(i, n, pipes)
            if ctrl == "exit" then return lastExit, "exit" end
            codes[i] = lastExit
        elseif it.kind == "compound" then
            inH, outH = it.inH, it.outH
            local rt, ctrl = evalNode(it.node)
            inH, outH = savedIn, savedOut
            F.closePipeEl(i, n, pipes)
            if ctrl == "exit" then return rt, "exit" end
            codes[i] = rt or 0
        end
    end
    -- Pass D: 等待外部元素退出(被 ^Z 停止时立即返回, 交给作业表)。
    local stopped = false
    for i = 1, n do
        if spawned[i] and not stopped then
            local reason, code = F.pollWait(spawned[i])
            codes[i] = F.exitStatus(reason, code)
            if reason == "stopped" then stopped = true end
        end
    end
    if pgid then F.fgTakeBack() end
    if stopped then
        F.registerStopped(node.src or "pipeline", leader, pgid)
        return 148 -- 128 + SIGTSTP
    end
    -- 清理: 重定向打开的句柄(flush/close) + 剩余管道端(close 幂等)。
    for _, h in ipairs(openedRedirs) do if h.close then pcall(h.close) end end
    for i = 1, n - 1 do
        if pipes[i] then pcall(pipes[i].read.close); pcall(pipes[i].write.close) end
    end
    lastExit = codes[n] or 0
    return lastExit
end

-- 条件上下文深度: >0 时失败的命令不触发 set -e(if/while/until 的条件、&&/|| 的非末元素)。
local condCtx = 0

evalNode = function(node)
    if node.kind == "simple" then return F.evalSimple(node) end
    if node.kind == "pipe" then return F.evalPipe(node) end
    if node.kind == "time" then
        -- POSIX `time [-p] pipeline`: 计时并报告 real/user/sys。
        -- 报告走 stderr(POSIX 明文规定, 免得被 `time cmd > f` 混进命令输出)。
        -- Delin 只提供 os.clock()(CC: "本程序消耗的 CPU 时间"), 所以 user 由它取差,
        -- **sys 恒为 0**(没有内核/用户态分离的记账) —— 这是已知偏离, 写在 for-ai.md。
        local t0, c0 = os.epoch("utc"), os.clock()
        local rt, ctrl = evalNode(node.node)
        local real = (os.epoch("utc") - t0) / 1000
        local user = os.clock() - c0
        if real < 0 then real = 0 end
        if user < 0 then user = 0 end
        F.errln(string.format("real\t%dm%.3fs", math.floor(real / 60), real % 60))
        F.errln(string.format("user\t%dm%.3fs", math.floor(user / 60), user % 60))
        F.errln(string.format("sys\t%dm%.3fs", 0, 0))
        return rt, ctrl
    end
    if node.kind == "chain" then
        -- 连接符存于下一个 item 的 op: item[i].op 是 item[i-1] 与 item[i] 之间的 &&/||。
        -- 用布尔"最近一条已执行命令是否成功"做左结合短路:
        --   A && B : A 失败则跳过 B;  A || B : A 成功则跳过 B。
        -- 但短路只在当步生效, 不中断整条链, 使 `A && B || C` 在 A 失败时仍执行 C。
        -- set -e: 只有"最后一个 &&/|| 之后的命令"失败才退出; 短路造成的非零状态豁免。
        local lastst = 0
        local ok = nil -- nil=尚未执行任何命令
        local exempt = false
        local n = #node.items
        for idx, it in ipairs(node.items) do
            local run = true
            if ok ~= nil then
                if (it.op == "&&" and not ok) or (it.op == "||" and ok) then run = false end
            end
            local isLast = (idx == n)
            if run then
                -- 非末元素处于条件上下文: 它失败不触发 set -e(POSIX)。
                if not isLast then condCtx = condCtx + 1 end
                local rt, c, ex = evalNode(it.node)
                if not isLast then condCtx = condCtx - 1 end
                if c then return rt, c end
                lastExit = rt or 0; lastst = rt or 0
                ok = (lastExit == 0)
                exempt = (not isLast) or ex or false
            else
                -- 跳过的元素: 链的状态来自它而不是"末元素失败", set -e 豁免。
                -- 不能 break —— 左结合语义要求继续看后面的 || (A && B || C 时 C 仍要跑)。
                exempt = true
            end
        end
        return lastst, nil, exempt
    end
    if node.kind == "brace" then return F.evalList(node.body) end
    if node.kind == "if" then
        condCtx = condCtx + 1
        local c, cctrl = F.evalList(node.cond)
        condCtx = condCtx - 1
        if cctrl then return c, cctrl end
        if c == 0 then return F.evalList(node.thenb) end
        for _, e in ipairs(node.elifs) do
            condCtx = condCtx + 1
            local ec, ectrl = F.evalList(e.cond)
            condCtx = condCtx - 1
            if ectrl then return ec, ectrl end
            if ec == 0 then return F.evalList(e.body) end
        end
        if node.elseb then return F.evalList(node.elseb) end
        return 0 -- POSIX: 没有条件成立且无 else 时, if 的退出状态为 0
    end
    if node.kind == "for" then
        local items
        if node.items then
            local abort, ctrl = F.nounsetCheck(node.items)
            if abort then return lastExit, ctrl end
            items = F.expandWords(node.items)
            if not items and F.expandAbort() then
                if interactive then return lastExit end
                return lastExit, "exit"
            end
        else items = {}; for i = 1, #posArgs do items[i] = posArgs[i] end end
        local lastst = 0
        for _, it in ipairs(items) do
            vars[node.var] = it
            local rt, c = F.evalList(node.body)
            if c == "exit" then return rt, "exit" end
            if c == "return" then return rt, "return" end -- return 穿透循环(函数体里的 return)
            if c == "break" then break end
            lastst = rt  -- continue: 走到下一个迭代即可
            F.schedYield()
            if sigintPending then sigintPending = false; break end
        end
        return lastst
    end
    if node.kind == "while" or node.kind == "until" then
        local lastst = 0
        while true do
            condCtx = condCtx + 1
            local c, cctrl = F.evalList(node.cond)
            condCtx = condCtx - 1
            if cctrl then return c, cctrl end
            local take = (node.kind == "while") and (c == 0) or (node.kind == "until" and c ~= 0)
            if not take then break end
            local rt, cc = F.evalList(node.body)
            if cc == "exit" then return rt, "exit" end
            if cc == "return" then return rt, "return" end
            if cc == "break" then break end
            lastst = rt
            F.schedYield()
            if sigintPending then sigintPending = false; break end
        end
        return lastst
    end
    if node.kind == "case" then
        local abort, ctrl = F.nounsetCheck({ node.word })
        if abort then return lastExit, ctrl end
        -- case 词只做展开, **不做**字段分割与路径名展开(POSIX 2.9.4.3).
        local w = F.wordToStr(node.word)
        if expandFailed and F.expandAbort() then
            if interactive then return lastExit end
            return lastExit, "exit"
        end
        for _, cs in ipairs(node.cases) do
            for _, pat in ipairs(cs.pats) do
                local pabort, pctrl = F.nounsetCheck({ pat })
                if pabort then return lastExit, pctrl end
                -- 模式里的引号要去掉(引用的 * 是字面量), 所以按引用掩码编码后再匹配。
                local ps, pqm = F.expandGlueMask(pat)
                if expandFailed and F.expandAbort() then
                    if interactive then return lastExit end
                    return lastExit, "exit"
                end
                if F.globMatch(F.encodePattern(ps, pqm), w) then
                    local rt, c = F.evalList(cs.body)
                    if c then return rt, c end
                    return rt
                end
            end
        end
        return 0
    end
    if node.kind == "funcdef" then
        local fname, fbody = node.name, node.body
        funcSrcs[fname] = node.src -- 供后台子 shell 注入(见 subshellPrologue)
        builtins[fname] = function(args)
            local saveArgs, saveArg0 = posArgs, posArg0
            posArg0 = fname
            posArgs = {}
            for i = 1, #args do posArgs[i] = args[i] end
            local rt, c = F.evalList(fbody)
            posArgs, posArg0 = saveArgs, saveArg0
            lastExit = rt or 0
            if c == "exit" then return "exit" end
            -- c == "return" 或 nil: 函数正常返回, 已设置 lastExit
        end
        return 0
    end
    return 0
end

F.evalList = function(items)
    local lastst = 0
    for idx, it in ipairs(items) do
        if opt.verbose and it.src then F.outVerbose(it.src) end
        if it.op == "&" then
            -- 异步列表: 起子 shell 后立即继续, 不等待(POSIX: $? 置 0)。
            F.startBackground(it.src)
            lastExit = lastExit or 0
            lastst = lastExit
        else
            local rt, c, exempt = evalNode(it.node)
            if c == "exit" then lastExit = rt or lastExit; return rt or 0, "exit" end
            if c == "break" then return rt or 0, "break" end
            if c == "continue" then return rt or 0, "continue" end
            if c == "return" then lastExit = rt or lastExit; return rt or 0, "return" end
            lastExit = rt or 0
            lastst = rt or 0
            -- set -e: 非条件上下文里失败的命令让 shell 立即退出(POSIX)。
            if opt.errexit and not exempt and lastExit ~= 0 and condCtx == 0 then
                return lastExit, "exit"
            end
            local nxt = items[idx + 1]
            if nxt and it.op == "&&" and lastExit ~= 0 then return lastst end
            if nxt and it.op == "||" and lastExit == 0 then return lastst end
        end
    end
    return lastst
end

F.evalProgram = function(src)
    local toks, lexInc, lexErr = F.lex(src)
    if lexErr then return nil, false, lexErr end
    T = toks
    ti = 1
    curSrc = src -- 后台作业 `&` 按原文起子 shell: 解析时需回取源文本
    -- 引号/行续接未闭合: 输入不完整, 什么也不执行(交互式继续读行)。
    if lexInc then return nil, true end
    local items, err, inc = parseList(nil)
    if items == nil then
        if inc then return nil, true end
        return nil, false, err
    end
    if T[ti] then
        -- 解析器没吃完的记号 = 不支持的语法(典型: `( list )` 子 shell 分组, Delin 没有)。
        -- 这里必须报错: 静默丢掉剩下的输入会让 `(echo hi); echo after` 一条命令都不跑却报成功,
        -- 正是 fail-fast 要防的那种"看着跑过了, 其实什么都没做"。
        local t = T[ti]
        return nil, false, "syntax error: unexpected " ..
            (t.t == "op" and ("'" .. tostring(t.op) .. "'") or ("'" .. tostring(t.raw) .. "'"))
    end
    local rt, c = F.evalList(items)
    -- 把 "exit" 控制信号透传给顶层调用者(交互循环/`.` 内建靠它终止/退出当前 shell)。
    if c == "exit" then
        lastExit = rt or lastExit
        return true, nil, nil, "exit"
    end
    return true
end

-- ---------------------------------------------------------------
-- 提示符(PS1..PS4): bash 风格转义
-- ---------------------------------------------------------------
-- 主机名: /etc/hostname 首行; 缺失时用 "delin"。
local hostname = "delin"
do
    local f = fs.open("/etc/hostname", "r")
    if f then
        local l = (f.readLine and f:readLine()) or ""
        f:close()
        l = l:gsub("^%s+", ""):gsub("%s+$", "")
        if l ~= "" then hostname = l end
    end
end
local cmdCount = 0 -- \# / \! : 本次 shell 的第几条命令(无历史, 用命令序号近似 bash 的 \!)

-- 波浪号缩写: cwd 在 $HOME 之下时用 ~ 代替(bash 的 \w)。
function F.tildeDir(p)
    local home = vars.HOME
    if home and home ~= "/" and (p == home or p:sub(1, #home + 1) == home .. "/") then
        return "~" .. p:sub(#home + 1)
    end
    return p
end

-- 提示符展开(bash 风格): \u 用户 \h 主机(短) \H 主机(全) \w cwd(带 ~) \W 基名
-- \$ root 为 # 否则 $ \#/\! 命令序号 \s shell 名 \n 换行 \t 时间 \d 日期 \e ESC(ANSI 配色)
-- \\ 反斜杠; 未知转义原样保留(与 bash 一致)。
F.promptExpand = function(s)
    return (tostring(s or ""):gsub("\\(.)", function(c)
        if c == "u" then return uname
        elseif c == "h" then return (hostname:match("^[^%.]+")) or hostname
        elseif c == "H" then return hostname
        elseif c == "w" then return F.tildeDir(cwd)
        elseif c == "W" then return (F.tildeDir(cwd):match("[^/]+$")) or "/"
        elseif c == "$" then return (uid == 0) and "#" or "$"
        elseif c == "#" or c == "!" then return tostring(cmdCount)
        elseif c == "s" then return shName
        elseif c == "n" then return "\n"
        elseif c == "t" then return os.date("%H:%M:%S")
        elseif c == "d" then return os.date("%a %b %d")
        elseif c == "e" or c == "E" then return "\27"
        elseif c == "\\" then return "\\"
        else return "\\" .. c
        end
    end))
end

-- ---------------------------------------------------------------
-- 入口(交互循环 / 非交互)
--   ui = nil            -> 经典行为(src/bin/sh: tty 行规程读行, 报错前缀 "sh:")
--   ui = { ... }        -> 前端接管(src/bin/desh: 行编辑器/历史/补全/纠错)
-- 钩子:
--   ui.name                 shell 名(报错前缀、PS1 的 \s、用法文本); 缺省 "sh"
--   ui.readLine(prompt, cont) 交互式读一行(cont=true 表示这是续行); 返回 nil = EOF。
--                             前端在返回前必须把终端恢复成规范模式 —— 子进程要拿回正常的行输入。
--   ui.commandNotFound(cmd) 命令找不到时的额外提示(did-you-mean); 只打印, 不动退出码。
--   S(table|nil)            前端要用的核心接口(见下面的暴露点); sh 传 nil。
-- 返回退出码(POSIX: 最后一条命令的状态; 后台子 shell 的 wait 状态即由此而来)。
-- ---------------------------------------------------------------
    -- 前端接口表(desh 用它读变量表/建命令候选/跑 rc 文件)。**必须在这里填**: 上面那些
    -- 定义都已经就位(evalProgram/aliases/builtins 都是赋值式声明), 而交互循环马上就要用。
    -- 只暴露前端真正需要的东西 —— 它不再能直接看见核心的局部变量了(见文件头那段说明)。
    if S then
        S.name = shName
        S.vars, S.builtins, S.aliases = vars, builtins, aliases
        S.fs, S.resolve, S.evalProgram = fs, F.resolve, F.evalProgram
        S.errln, S.outln = F.errln, F.outln
        S.stdin, S.stdout = stdin, stdout
        S.interactive = interactive
        S.lastExit = function() return lastExit end
    end
    -- 前端就绪钩子: 接口表已经填满、命令还没开始跑。desh 在这里读 rc 文件、载入历史、
    -- 覆盖 help —— 都是"要看到核心的表和函数"才能做的事。返回 false 表示前端要求直接收摊
    -- (rc 里执行了 exit)。
    if UI and UI.setup then
        if UI.setup(S) == false then return lastExit end
    end
    if interactive then
        local buf = ""
        while true do
            F.reapJobs(true) -- 提示符前报告已结束的后台作业(`[1]+ Done cmd`)
            -- 缓冲区为空: PS1(默认 \u@\h:\w\$ ); 跨行未结束: PS2(默认 "> ")。
            if #buf == 0 then cmdCount = cmdCount + 1 end
            local p = (#buf == 0) and vars.PS1 or vars.PS2
            if p == nil then p = (#buf == 0) and "\\u@\\h:\\w\\$ " or "> " end
            local prompt = F.promptExpand(p)
            if stdout and stdout.write then stdout:write(prompt) end
            -- 前端(desh)自己画行/光标; 没有前端时就是 tty 行规程读一整行。
            local line
            if UI and UI.readLine then
                line = UI.readLine(prompt, #buf > 0)
            else
                line = stdin and stdin.readLine and stdin:readLine()
            end
            -- 提示符处的 ^C 只用来取消当前输入行: tty 行规程已经回显 "^C"、丢掉该行(返回空行),
            -- 并给前台进程组投了 SIGINT —— 那个 SIGINT 的目的**已经达成**, 必须在这里消费掉。
            -- 留着它的话, 下一条外部命令刚 spawn 就被 pollWait 当成"^C 中断"立刻 SIGKILL:
            -- 症状是"取消输入后的一条命令静默不执行(退出码 130), 再下一条才恢复"。
            sigintPending = false
            if line == nil then
                -- EOF 时缓冲区里还有未完成的命令 -> 语法错误(与 dash 的 unexpected EOF 同义)。
                if #buf > 0 then F.errln(shName .. ": syntax error: unexpected end of file") end
                break
            end
            buf = buf .. line .. "\n"
            local ok, inc, err, ctrl = F.evalProgram(buf)
            if ctrl == "exit" then break end
            if inc then
                -- 命令不完整: 保留缓冲区, 下一轮用 PS2 提示继续读。
            elseif ok then
                buf = ""
            else
                -- 语法错误: 丢弃这条命令继续(POSIX 交互式语义), $? 置 2(dash/bash 同此)。
                F.errln(shName .. ": " .. tostring(err)); buf = ""; lastExit = 2
            end
        end
    else
        -- 非交互: -c 命令行 > 脚本文件 > stdin(管道/重定向)。
        local src = ""
        if cmdString then
            src = cmdString
        elseif scriptPath then
            local f = fs.open(scriptPath, "r")
            if f then
                src = (f.readAll and f:readAll()) or ""
                f:close()
            else
                F.errln(shName .. ": " .. scriptPath .. ": cannot open")
                return 1
            end
        else
            while true do
                local line = stdin and stdin.readLine and stdin:readLine()
                if line == nil then break end
                src = src .. line .. "\n"
            end
        end
        if src ~= "" then
            -- 非交互下 exit 已使 evalList 提前终止后续命令; 这里无需再 break。
            -- 输入已到 EOF, 所以"不完整"在这里就是语法错误(不回退, 不猜测)。
            local ok, inc, err = F.evalProgram(src)
            -- 语法错误: POSIX 要求非交互 shell 以非 0 退出(dash/bash 用 2, `.` 内建也是 2)。
            if inc then
                F.errln(shName .. ": syntax error: unexpected end of file"); lastExit = 2
            elseif ok == nil and err then
                F.errln(shName .. ": " .. tostring(err)); lastExit = 2
            end
        end
    end
    return lastExit
end

