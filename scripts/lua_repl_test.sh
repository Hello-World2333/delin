#!/bin/sh
# Delin /bin/lua 交互式 REPL 自检 —— 宿主专用(在仓库根目录运行: sh scripts/lua_repl_test.sh)。
# REPL 只在 stdin 是终端时进入, 而真机取不到键盘(无法向电脑注入按键), 所以用测试台的
# DELIN_HARNESS_TTY=1 把 stdin 伪装成终端(与 sh 的提示符测试同一招), 在宿主上验证。
# "^C 取消当前输入行" 那一路需要真键盘中断 readLine, 测试台喂不出(输入是预先读好的行),
# 因此不在自动测试范围内 —— 代码里那一段只有一处判断, 见 src/bin/lua 的 repl()。
# 覆盖: 横幅/提示符, 表达式自动打印, =expr 简写, 字段/多值, 多行续行(>> ), 字符串,
#       运行期报错带栈且不当场退出, SIGINT 不会杀死解释器(装了 handler), _PROMPT 覆盖, EOF 退出码。
# 输出 "ok <name>" / "ng <name>", 全 ok 退出码 0。

cd "$(dirname "$0")/.." || exit 1
T=/tmp/delin-lua-repl
rm -rf $T
mkdir -p $T

outcome=0
ok() { echo "ok $1"; }
ng() { echo "ng $1"; outcome=1; }
chkcontain() { # chkcontain <name> <pattern> <file>
    if grep -q "$2" "$3"; then ok "$1"; else ng "$1"; fi
}
chkempty() { # chkempty <name> <pattern> <file>
    if grep -q "$2" "$3"; then ng "$1"; else ok "$1"; fi
}

# REPL 会话: 每个用例前后各插一句 print 作分隔 —— 提示符不带换行, 不分隔的话
# 前一句的提示符会和后一句的结果挤在同一行上, 断言就没法写死。
cat > $T/in.lua <<'EOF'
print("start")
1+1
print("m1")
print("hi")
print("m2")
= 1+2
print("m3")
t = {}
t.x
print("m4")
if true then
print("multi")
end
print("m5")
"str"
print("m6")
a, b
print("m7")
syscalls["signal.kill"](pid, 2)
print("alive")
print("m8")
bad syntax here(
print("still here")
print("m9")
error("kaboom")
print("still alive")
_PROMPT = "delin> "
2 + 3
print("m10")
EOF

DELIN_HARNESS_TTY=1 lua5.1 tools/harness.lua /bin/lua < $T/in.lua > $T/out 2>&1
_rc=$?

# ---------------------------------------------------------------
# 会话结果
# ---------------------------------------------------------------
chkcontain repl_banner         '^Lua ' $T/out
chkcontain repl_expr_number    '^> 2$' $T/out          # 裸表达式 1+1 自动按 return 求值
chkcontain repl_print_result   '^> hi$' $T/out         # print 写 stdout(不是 klog)
chkcontain repl_eq_shorthand   '^> 3$' $T/out          # = expr 简写
chkcontain repl_field_is_nil   '^> > nil$' $T/out      # t.x (Lua 5.1/5.2 上也给 5.3+ 的手感)
chkcontain repl_multiline      '>> >> multi$' $T/out   # 未完成语句续行
chkcontain repl_string_value   '^> str$' $T/out
chkcontain repl_two_values     '^> nil[[:space:]]nil$' $T/out # 多值按制表符分隔
chkcontain repl_sigint_alive   '^> > alive$' $T/out    # SIGINT 不杀解释器(handler 生效)
chkcontain repl_after_error    '^> still here$' $T/out # 语法错误后 REPL 继续
chkcontain repl_prompt_custom  'delin> 5$' $T/out      # _PROMPT 覆盖提示符
chkcontain repl_runtime_error  'kaboom' $T/out         # 运行期错误只报告, 不退出
chkcontain repl_runtime_trace  'stack traceback' $T/out
chkcontain repl_alive_after_rt '^> still alive$' $T/out
chkempty   repl_no_lua_prefix  '^lua: ' $T/out         # REPL 的报错不带 "lua: " 前缀(官方同)

if [ "$_rc" = "0" ]; then ok repl_eof_exit0; else ng repl_eof_exit0; fi

echo "lua_repl_test: done (exit=$outcome)"
exit $outcome
