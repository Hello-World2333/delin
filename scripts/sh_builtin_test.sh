#!/bin/sh
# Delin sh 内建/变量自检: `. set export unset` + PATH/$PSx/$PPID/$USER/$SHELL/$PWD + -e/-u/-x。
# 输出 "ok <name>" / "ng <name>"; 全部 ok 退出码 0。
# 用法(宿主): lua5.1 tools/harness.lua /bin/sh < scripts/sh_builtin_test.sh
# 用法(真机): sh /root/sh_builtin_test.sh   (由 verify-sh.service 调用, 结果写 /var/log/sh_verify.log)
# 注意: 不依赖 grep 的退出码(Delin grep 目前恒返回 0), 用 "grep 输出是否为空" 判定。

T=/tmp/shbuiltin
outcome=0
ok() { echo "ok $1"; }
ng() { echo "ng $1"; outcome=1; }
chk() { # chk <name> <cmd...>: 命令退出码 0 即通过
    _n="$1"; shift
    "$@"
    if [ "$?" = "0" ]; then ok "$_n"; else ng "$_n"; fi
}
chkneg() { # 命令退出码非 0 即通过
    _n="$1"; shift
    "$@"
    if [ "$?" != "0" ]; then ok "$_n"; else ng "$_n"; fi
}
chkcase() { if [ "$2" = "1" ]; then ok "$1"; else ng "$1"; fi }
chkcontain() { # chkcontain <name> <pattern> <file>
    grep "$2" "$3" > $T/grepout
    if [ -s $T/grepout ]; then ok "$1"; else ng "$1"; fi
}
chknocontain() {
    grep "$2" "$3" > $T/grepout
    if [ -s $T/grepout ]; then ng "$1"; else ok "$1"; fi
}

rm -rf $T
mkdir -p $T/d1

# ---------------------------------------------------------------
# 1. 启动变量
# ---------------------------------------------------------------
SAVED0="$0"
chk var_path    [ -n "$PATH" ]
chk var_user    [ -n "$USER" ]
chk var_shell   [ -n "$SHELL" ]
chk var_home    [ -n "$HOME" ]
chk var_ppid    sh -c 'test "$PPID" -gt 0'
chk var_ps1     [ -n "$PS1" ]
chk var_ps2     [ -n "$PS2" ]
chk var_ps3     [ -n "$PS3" ]
chk var_ps4     [ -n "$PS4" ]
chk var_logname [ -n "$LOGNAME" ]

# ---------------------------------------------------------------
# 2. PWD / OLDPWD / cd
# ---------------------------------------------------------------
cd /tmp
chk cd_pwd [ "$PWD" = "/tmp" ]
cd $T/d1
chk cd_pwd2 [ "$PWD" = "$T/d1" ]
chk cd_oldpwd [ "$OLDPWD" = "/tmp" ]
cd - > $T/cdminus
chk cd_minus_back [ "$PWD" = "/tmp" ]
chk cd_minus_prints [ -s $T/cdminus ]
cd $T/d1
cd
chk cd_home [ "$PWD" = "$HOME" ]
chkneg cd_bad cd /nonexistent-xyz
cd /tmp

# ---------------------------------------------------------------
# 3. `.` source
# ---------------------------------------------------------------
echo 'SV=fromsrc' > $T/lib.sh
echo 'sf() { echo "sf:$1"; }' >> $T/lib.sh
echo 'echo "args:$1:$2"' >> $T/lib.sh
NARGS="$#"
. $T/lib.sh a b > $T/src_out
chk dot_var [ "$SV" = "fromsrc" ]
chk dot_posargs [ "$#" = "$NARGS" ]
chk dot_arg0 [ "$0" = "$SAVED0" ]
sf hi > $T/sf_out
chkcontain dot_func "sf:hi" $T/sf_out
chkcontain dot_args "args:a:b" $T/src_out
chkneg dot_missing . $T/nope.sh
echo 'if true' > $T/bad.sh
chkneg dot_syntax . $T/bad.sh
SAVED_PATH="$PATH"
PATH="$T:$PATH"
. lib.sh z > $T/src_path
chkcontain dot_path "args:z:" $T/src_path
PATH="$SAVED_PATH"

# ---------------------------------------------------------------
# 4. set
# ---------------------------------------------------------------
set > $T/set_out
chkcontain set_lists_path "PATH=" $T/set_out
chkcontain set_quotes "PWD='" $T/set_out
set -- x y
chk set_pos1 [ "$1" = "x" ]
chk set_pos2 [ "$2" = "y" ]
chk set_count [ "$#" = "2" ]
set --
chk set_clear [ "$#" = "0" ]
set -e
case "$-" in *e*) chkcase set_e 1 ;; *) chkcase set_e 0 ;; esac
set -o > $T/seto
chkcontain set_o_list "errexit" $T/seto
set +o > $T/setpo
chkcontain set_plus_o "set [-]e" $T/setpo
set +e
case "$-" in *e*) chkcase set_plus_e 0 ;; *) chkcase set_plus_e 1 ;; esac
set -u
case "$-" in *u*) chkcase set_u 1 ;; *) chkcase set_u 0 ;; esac
set +u
case "$-" in *u*) chkcase set_plus_u 0 ;; *) chkcase set_plus_u 1 ;; esac

# ---------------------------------------------------------------
# 5. set -e 语义(在子 shell 里验证, 避免自检脚本自己被终止)
# ---------------------------------------------------------------
sh -c 'set -e; true && false; echo SURVIVED' > $T/ee1
chknocontain errexit_last_and SURVIVED $T/ee1
sh -c 'set -e; false && true; echo SURVIVED' > $T/ee2
chkcontain errexit_and_exempt SURVIVED $T/ee2
sh -c 'set -e; if false; then :; fi; echo SURVIVED' > $T/ee3
chkcontain errexit_if_cond SURVIVED $T/ee3
sh -c 'set -e; f() { false; echo SURVIVED_IN_F; }; if f; then :; fi; echo after' > $T/ee4
chkcontain errexit_func_in_cond SURVIVED_IN_F $T/ee4
sh -c 'set -e; f() { false; echo SURVIVED; }; f' > $T/ee5
chknocontain errexit_func_body SURVIVED $T/ee5
sh -c 'for i in 1 2; do exit 5; done; echo SURVIVED' > $T/ee6
chknocontain exit_in_for SURVIVED $T/ee6
sh -c 'while true; do exit 6; done; echo SURVIVED' > $T/ee7
chknocontain exit_in_while SURVIVED $T/ee7
sh -c 'exit 7'
chk exit_status [ "$?" = "7" ]
sh -c 'set --; "$@"; echo SURVIVED' > $T/empty_argv
chkcontain empty_argv_noop SURVIVED $T/empty_argv
sh -c 'f() { for i in 1 2; do return 5; done; echo SURVIVED; }; f; echo "rc=$?"' > $T/retloop
chkcontain return_in_for "rc=5" $T/retloop
chknocontain return_in_for_no_echo SURVIVED $T/retloop

# ---------------------------------------------------------------
# 6. set -u 语义
# ---------------------------------------------------------------
sh -c 'set -u; echo $NOPE_XYZ; echo SURVIVED' > $T/nu1
chknocontain nounset_aborts SURVIVED $T/nu1
chkcontain nounset_message "parameter not set" $T/nu1
sh -c 'set -u; if false; then echo $NOPE_XYZ; fi; echo SURVIVED' > $T/nu2
chkcontain nounset_branch SURVIVED $T/nu2
sh -c 'set -u; echo $1' > $T/nu3
chkcontain nounset_positional "parameter not set" $T/nu3

# ---------------------------------------------------------------
# 7. export / unset / 子进程环境
# ---------------------------------------------------------------
echo 'io.stdout():write("FOO=" .. tostring(getenv("FOO")) .. " PATH=" .. tostring(env.PATH) .. "\n")' > $T/showenv
chmod 755 $T/showenv
export FOO=bar
$T/showenv > $T/env1
chkcontain export_child "FOO=bar" $T/env1
chkcontain export_path "PATH=" $T/env1
export -p > $T/exp_p
chkcontain export_p "export FOO='bar'" $T/exp_p
export -n FOO
$T/showenv > $T/env2
chknocontain export_n "FOO=bar" $T/env2
x=1
unset x
chk unset_var [ -z "$x" ]
uf() { echo uf; }
unset -f uf
chkneg unset_func uf

# ---------------------------------------------------------------
# 8. PATH 命令查找
# ---------------------------------------------------------------
echo '#!/bin/sh' > $T/tool
echo 'echo "tool ran: $1"' >> $T/tool
chmod 755 $T/tool
SAVED_PATH="$PATH"
PATH="$T:/bin"
tool hello > $T/tool_out
chkcontain path_command "tool ran: hello" $T/tool_out
PATH="$SAVED_PATH"
chkneg path_not_found tool hello

# ---------------------------------------------------------------
# 9. set -x (PS4 前缀; Delin 的 stderr 与 stdout 同流, 子进程输出可重定向捕获)
# ---------------------------------------------------------------
sh -c 'PS4="TRACE> "; set -x; echo traced' > $T/xtrace_out
chkcontain xtrace_prefix "TRACE> echo traced" $T/xtrace_out
sh -c 'echo before; set -v; echo VERBOSE_MARK; set +v' > $T/verbose_out
chkcontain verbose_echo "echo VERBOSE_MARK" $T/verbose_out

# ---------------------------------------------------------------
# 10. 终端输出必须是 ASCII(CC 终端打印中文会乱码): help 输出里不允许出现非 ASCII 字节
# ---------------------------------------------------------------
help > $T/help_out
grep -v "^[ -~]*$" $T/help_out > $T/help_nonascii
chk ascii_help [ ! -s $T/help_nonascii ]

echo "== summary =="
if [ "$outcome" = "0" ]; then echo "all ok"; else echo "FAILURES"; fi
exit $outcome
