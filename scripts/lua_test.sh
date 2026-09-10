#!/bin/sh
# Delin /bin/lua 自检: 脚本模式 / stdin 模式 / arg 与变参 / dofile+loadfile(走 VFS) /
#                    错误消息与退出码 / 内核进程环境白名单。
# 可移植 POSIX sh; 两处各跑一次并要求输出一致:
#   宿主: lua5.1 tools/harness.lua /bin/sh < scripts/lua_test.sh
#   真机: 由 realmachine_verify.sh 调用(sh /root/lua_test.sh >> $LOG)
# 交互式 REPL 要在真终端上敲键, 真机取不到键盘, 因此 REPL 由宿主侧的
#   scripts/lua_repl_test.sh(DELIN_HARNESS_TTY=1 把 stdin 伪装成终端)覆盖;
#   "^C 取消当前输入行" 一路需要真键盘, 不在自动测试范围内。
# 输出 "ok <name>" / "ng <name>", 全 ok 退出码 0。不打印 pid/地址等每次运行都变的值。

T=/tmp/luatest
outcome=0
rm -rf $T
mkdir -p $T

ok() { echo "ok $1"; }
ng() { echo "ng $1"; outcome=1; }
chk() { # chk <name> <cmd...>: 命令退出码 0 即通过
    _n="$1"; shift
    "$@"
    if [ "$?" = "0" ]; then ok "$_n"; else ng "$_n"; fi
}
chkrun() { # chkrun <name> <期望退出码> <输出文件> <cmd...>: 跑命令并收走输出
    _n="$1"; _want="$2"; _out="$3"; shift 3
    "$@" > $_out
    if [ "$?" = "$_want" ]; then ok "$_n"; else ng "$_n"; fi
}
chkfile() { if [ -s "$2" ]; then ok "$1"; else ng "$1"; fi }
chkempty() { if [ -s "$2" ]; then ng "$1"; else ok "$1"; fi }
chkcontain() { # chkcontain <name> <Lua pattern> <file>
    grep "$2" "$3" > $T/grepout
    if [ -s $T/grepout ]; then ok "$1"; else ng "$1"; fi
}

# ---------------------------------------------------------------
# 1. 脚本模式: lua <script> [args...]
# ---------------------------------------------------------------
echo 'print("hello from script")' > $T/hello.lua
chkrun lua_script_ok 0 $T/hello.out lua $T/hello.lua
chkcontain lua_script_print 'hello from script' $T/hello.out

# arg 表: arg[-1]=解释器, arg[0]=脚本, arg[1..]=参数; 脚本体收到变参 ...
echo -e 'print(arg[-1], arg[0], arg[1], arg[2])\nprint(select("#", ...), (...))' > $T/args.lua
chkrun lua_args_ok 0 $T/args.out lua $T/args.lua foo bar
chkcontain lua_arg_interp '/bin/lua' $T/args.out
chkcontain lua_arg_script "$T/args.lua" $T/args.out
chkcontain lua_arg_1      'foo' $T/args.out
chkcontain lua_arg_2      'bar' $T/args.out
chkcontain lua_arg_line   '/bin/lua%s.*%sfoo%sbar' $T/args.out
chkcontain lua_vararg_n   '^2%s' $T/args.out
chkcontain lua_vararg_val 'foo%sbar' $T/args.out

# print 无参数要输出空行(与 lua(1) 一致)
echo 'print("x1") print() print("x2")' > $T/blank.lua
chkrun lua_print_blank 0 $T/blank.out lua $T/blank.lua
chkcontain lua_print_blank_line '^$' $T/blank.out

# 顶层 return <数字> = 退出码(Delin 约定; CC 没有 os.exit)
echo 'print("before return") return 7' > $T/exit7.lua
chkrun lua_script_exitcode 7 $T/exit7.out lua $T/exit7.lua
chkcontain lua_script_ran_before_return 'before return' $T/exit7.out

# 没有 return 数字就是 0
echo 'print("plain end")' > $T/plain.lua
chkrun lua_script_exit0 0 $T/plain.out lua $T/plain.lua

# ---------------------------------------------------------------
# 2. stdin 模式: 无参数(非终端)与 `lua -`
# ---------------------------------------------------------------
echo 'print("from stdin pipe")' | lua > $T/pipe.out
if [ "$?" = "0" ]; then ok lua_pipe_exit0; else ng lua_pipe_exit0; fi
chkcontain lua_pipe_stdin 'from stdin pipe' $T/pipe.out

lua < $T/hello.lua > $T/redir.out
chkcontain lua_redirect_stdin 'hello from script' $T/redir.out

lua - < $T/hello.lua > $T/dash.out
chkcontain lua_dash_stdin 'hello from script' $T/dash.out
echo 'print("via dash pipe")' | lua - > $T/dash2.out
chkcontain lua_dash_pipe 'via dash pipe' $T/dash2.out

# stdin 的 chunk 也按 Delin 约定吃 return <数字>
echo 'return 5' | lua > $T/stdin5.out
if [ "$?" = "5" ]; then ok lua_stdin_exitcode; else ng lua_stdin_exitcode; fi

# ---------------------------------------------------------------
# 3. dofile / loadfile: 本解释器提供, 且读文件走 Delin VFS
# ---------------------------------------------------------------
echo 'return 41 + 1' > $T/inc.lua
echo -e 'print(dofile("'$T'/inc.lua"))\nlocal f = loadfile("'$T'/inc.lua")\nprint(f() + 1)' > $T/df.lua
chkrun lua_dofile_loadfile 0 $T/df.out lua $T/df.lua
chkcontain lua_dofile_result   '^42$' $T/df.out
chkcontain lua_loadfile_result '^43$' $T/df.out

# loadfile 失败返回 nil+err(不抛); dofile 失败抛错 -> 退出码 1
echo -e 'local f, e = loadfile("'$T'/nope.lua")\nprint(f == nil, e ~= nil)' > $T/lfmiss.lua
chkrun lua_loadfile_missing 0 $T/lfmiss.out lua $T/lfmiss.lua
chkcontain lua_loadfile_missing_nilerr 'true%strue' $T/lfmiss.out

echo 'dofile("'$T'/nope.lua")' > $T/dfmiss.lua
chkrun lua_dofile_missing 1 $T/dfmiss.out lua $T/dfmiss.lua
chkcontain lua_dofile_missing_msg '[Nn]o such file' $T/dfmiss.out

# 续行(REPL)靠"语法错误消息以 <eof> 结尾"判定: 这里直接问真机的 Lua, 两种写法都要成立
# (Lua 5.1/5.2 写成 '<eof>', 5.3+ 不带引号)。REPL 本身要键盘, 不在真机测试范围内。
echo 'local q = string.char(39)' > $T/eofmsg.lua
echo 'local f, e' >> $T/eofmsg.lua
echo 'if _VERSION == "Lua 5.1" then f, e = loadstring("if true then", "=p") else f, e = load("if true then", "=p", "t", {}) end' >> $T/eofmsg.lua
echo 'print(f == nil, e ~= nil, e:find("<eof>" .. q .. "?%s*$") ~= nil)' >> $T/eofmsg.lua
chkrun lua_incomplete_eof_msg 0 $T/eofmsg.out lua $T/eofmsg.lua
chkcontain lua_incomplete_eof_msg_val '^true%strue%strue$' $T/eofmsg.out

# ---------------------------------------------------------------
# 4. 错误消息与退出码
# ---------------------------------------------------------------
echo 'x =' > $T/syntax.lua
chkrun lua_syntax_error 1 $T/syntax.out lua $T/syntax.lua
chkcontain lua_syntax_msg    'unexpected symbol' $T/syntax.out
chkcontain lua_syntax_name   'syntax.lua:2' $T/syntax.out
chkcontain lua_syntax_prefix '^lua: ' $T/syntax.out

echo -e 'local function boom() error("kaboom") end\nboom()' > $T/runtime.lua
chkrun lua_runtime_error 1 $T/runtime.out lua $T/runtime.lua
chkcontain lua_runtime_msg   'kaboom' $T/runtime.out
chkcontain lua_runtime_trace 'stack traceback' $T/runtime.out

chkrun lua_missing_file 1 $T/miss.out lua $T/nope.lua
chkcontain lua_missing_msg 'cannot open' $T/miss.out

chkrun lua_bad_option 1 $T/opt.out lua -z
chkcontain lua_bad_option_msg   'unrecognized option' $T/opt.out
chkcontain lua_bad_option_usage 'usage: lua' $T/opt.out

# ---------------------------------------------------------------
# 5. shebang: #!/bin/lua 的脚本可以直接执行(内核按 shebang 起解释器)
# ---------------------------------------------------------------
echo -e '#!/bin/lua\nprint("shebang", arg[0], arg[1])' > $T/shebang.lua
chmod 755 $T/shebang.lua
chkrun lua_shebang_run 0 $T/shebang.out $T/shebang.lua hi
chkcontain lua_shebang_tag  'shebang' $T/shebang.out
chkcontain lua_shebang_path "$T/shebang.lua" $T/shebang.out
chkcontain lua_shebang_arg  '%shi$' $T/shebang.out

# ---------------------------------------------------------------
# 6. 内核进程环境白名单: 直接由 sh 执行的 Delin 程序(无 shebang)= 纯内核进程环境。
#    这里用 io.write 输出(print 在 Delin 程序里走 klog)。
# ---------------------------------------------------------------
echo 'local function chk(n, c) io.write(c and ("ok " .. n) or ("ng " .. n), "\n") end' > $T/envcheck.lua
for name in loadfile dofile require package settings shell commands multishell help disk peripheral pocket; do
    echo -e "chk(\"banned_$name\", _G[\"$name\"] == nil)" >> $T/envcheck.lua
done
for name in run pullEvent pullEventRaw queueEvent shutdown reboot loadAPI unloadAPI; do
    echo -e "chk(\"banned_os_$name\", os[\"$name\"] == nil)" >> $T/envcheck.lua
done
echo -e 'chk("banned_debug_getregistry", debug.getregistry == nil)' >> $T/envcheck.lua
echo -e 'chk("banned_debug_sethook", debug.sethook == nil)' >> $T/envcheck.lua
echo -e 'chk("keep_debug_traceback", debug.traceback ~= nil)' >> $T/envcheck.lua
for name in fs io syscalls print os string table math coroutine; do
    echo -e "chk(\"keep_$name\", _G[\"$name\"] ~= nil)" >> $T/envcheck.lua
done
for name in epoch sleep date time clock; do
    echo -e "chk(\"keep_os_$name\", os[\"$name\"] ~= nil)" >> $T/envcheck.lua
done
echo -e 'chk("keep_string_format", string.format ~= nil)' >> $T/envcheck.lua
echo -e 'chk("keep_table_concat", table.concat ~= nil)' >> $T/envcheck.lua
echo -e 'chk("keep_math_floor", math.floor ~= nil)' >> $T/envcheck.lua
echo -e 'chk("keep_coroutine_create", coroutine.create ~= nil)' >> $T/envcheck.lua
echo -e 'chk("keep_argv", argv ~= nil and arg0 ~= nil)' >> $T/envcheck.lua

chmod 755 $T/envcheck.lua
$T/envcheck.lua > $T/env.out
if [ "$?" = "0" ]; then ok env_sandbox_exit; else ng env_sandbox_exit; fi
chkfile env_sandbox_ran $T/env.out
cat $T/env.out                       # 明细也进日志, 便于和真机比对
grep '^ng ' $T/env.out > $T/env.ng
chkempty env_sandbox $T/env.ng

# 同一份检查经 /bin/lua 跑: 解释器额外提供走 VFS 的 loadfile/dofile
echo 'print(loadfile ~= nil, dofile ~= nil, os.run == nil, settings == nil, peripheral == nil)' > $T/luaenv.lua
chkrun lua_env_ok 0 $T/luaenv.out lua $T/luaenv.lua
chkcontain lua_env_provides '^true%strue%strue%strue%strue$' $T/luaenv.out

# ---------------------------------------------------------------
echo "lua_test: done (exit=$outcome)"
exit $outcome
