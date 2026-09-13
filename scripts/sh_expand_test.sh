#!/bin/sh
# Delin sh 展开自检: 路径名展开(通配符 * ? [ ]) + 命令替换($( ) 与反引号) + 算术展开($(( )))。
# 输出 "ok <name>" / "ng <name>"; 全部 ok 退出码 0。
# 用法(宿主): lua5.1 tools/harness.lua /bin/sh < scripts/sh_expand_test.sh
# 用法(真机): sh /root/sh_expand_test.sh   (由 verify-sh.service 调用, 结果写 /var/log/sh_verify.log)
# 同一份脚本在宿主与真机各跑一次逐项比对 —— 参考实现是 POSIX 的 sh/bash 行为(本文件里
# 每条期望值都对着 bash/dash 核过; 只有下面标注 "Delin 特有" 的几项是 Delin 自己的取舍:
# 别名注入子 shell(bash 非交互默认不展开别名)、`( list )` 报语法错(Delin 没有子 shell 分组)、
# 子 shell 的 cwd 取内核继承值)。
# 注意: 不依赖 grep 的退出码, 用 "输出是否为空" 判定(与其他自检脚本同一约定)。

T=/tmp/shexpand
outcome=0
ok() { echo "ok $1"; }
ng() { echo "ng $1"; outcome=1; }
eq() { # eq <name> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else ng "$1"; echo "    expected [$2] got [$3]"; fi
}

rm -rf $T
mkdir -p $T/sub
cd $T
touch b.txt a.txt c.dat .hidden sub/inner.txt

# ---------------------------------------------------------------
# 1. 路径名展开(通配符)
# ---------------------------------------------------------------
set -- *.txt
eq  glob_star_count 2 "$#"
eq  glob_star_sorted "a.txt" "$1"
set -- *
eq  glob_all_count 4 "$#"          # a.txt b.txt c.dat sub (.hidden 不算)
eq  glob_all_first "a.txt" "$1"
set -- ?.dat
eq  glob_question 1 "$#"
eq  glob_question_name "c.dat" "$1"
set -- [ab].txt
eq  glob_class 2 "$#"
set -- [!a].txt
eq  glob_class_negate 1 "$#"
eq  glob_class_negate_name "b.txt" "$1"
set -- [a-c].*
eq  glob_class_range 3 "$#"
set -- "*.txt"
eq  glob_dquoted_literal 1 "$#"
eq  glob_dquoted_literal_name '*.txt' "$1"
set -- '*.txt'
eq  glob_squoted_literal '*.txt' "$1"
set -- \*.txt
eq  glob_escaped_literal '*.txt' "$1"
set -- nomatch*
eq  glob_nomatch_literal 'nomatch*' "$1"
set -- ./*
eq  glob_dot_slash_count 4 "$#"
eq  glob_dot_slash_first "./a.txt" "$1"
set -- */ 
eq  glob_trailing_slash 1 "$#"
eq  glob_trailing_slash_name "sub/" "$1"
set -- sub/*
eq  glob_subdir "sub/inner.txt" "$1"
set -- */*
eq  glob_two_levels "sub/inner.txt" "$1"
set -- $T/../shexpand/*.dat
eq  glob_dotdot "$T/../shexpand/c.dat" "$1"
set -- .[h]*
eq  glob_dotfile_explicit ".hidden" "$1"
eq  glob_dotfile_count 1 "$#"

# 混合引用: 引号里的 * 是字面量, 未引用的才是通配符
set -- a"*"
eq  glob_mixed_quoted 'a*' "$1"
set -- "a"*
eq  glob_mixed_unquoted_count 1 "$#"

# 前缀匹配: 存在 bin/ls 时 bin/ls* 必须匹配到它(`*` 可以匹配**空串**)。
# 这条是回归用例: 曾有报告说 /bin/ls* 匹配不到 /bin/ls(通配符与 POSIX 行为不一致)。
mkdir -p $T/bin
touch $T/bin/ls $T/bin/lsblk
set -- $T/bin/ls*
eq  glob_prefix_count 2 "$#"
eq  glob_prefix_first "$T/bin/ls" "$1"
eq  glob_prefix_second "$T/bin/lsblk" "$2"
set -- $T/bin/ls[bl]*
eq  glob_prefix_class "$T/bin/lsblk" "$1"
set -- $T/bin/ls*z*
eq  glob_prefix_nomatch "$T/bin/ls*z*" "$1"
cd $T/bin
set -- ls*
eq  glob_prefix_relative_count 2 "$#"
eq  glob_prefix_relative_first "ls" "$1"
cd $T
set -- $T/bin/l[st]*
eq  glob_prefix_class2_count 2 "$#"

# for 列表与重定向目标也做路径名展开
n=0
for f in *.txt; do n=$((n+1)); done
eq  glob_for_list 2 "$n"
echo hello > only.txt
eq  glob_redirect_target "hello" "$(cat only.txt)"
rm -f only.txt

# case 模式是**模式匹配**(不展开路径), ?/[ ] 都是通配符
case abc in ?bc) glob_case_question=yes;; *) glob_case_question=no;; esac
eq  glob_case_pat_question yes "$glob_case_question"
case xyz in [a-z]*) glob_case_class=yes;; *) glob_case_class=no;; esac
eq  glob_case_pat_class yes "$glob_case_class"
case xyz in [a-w]*) glob_case_range=yes;; *) glob_case_range=no;; esac
eq  glob_case_pat_range_bound no "$glob_case_range"
case 'a*c' in "a*c") glob_case_quoted=yes;; *) glob_case_quoted=no;; esac
eq  glob_case_pat_quoted yes "$glob_case_quoted"

# ---------------------------------------------------------------
# 2. 命令替换 $( ) 与反引号
# ---------------------------------------------------------------
eq  cmdsub_basic "hi" "$(echo hi)"
eq  cmdsub_backtick "hi" "`echo hi`"
eq  cmdsub_nested "deep" "$(echo $(echo deep))"
eq  cmdsub_no_output "" "$(echo -n)"
eq  cmdsub_strip_newlines "x" "$(printf 'x\n\n\n')"
eq  cmdsub_internal_newline "$(printf 'a\nb')" "$(printf 'a\nb')"
eq  cmdsub_pipeline "A" "$(echo a | tr a-z A-Z)"
eq  cmdsub_quoted_keeps_space "a b" "$(printf '%s' 'a b')"
eq  cmdsub_quoted_in_word "x$(echo y)z" "xyz"

# 未引用的结果按 IFS 分割成多个字段
set -- $(echo p q r)
eq  cmdsub_field_split 3 "$#"
eq  cmdsub_field_split_last "r" "$3"
set -- "$(echo 'a b')"
eq  cmdsub_quoted_no_split 1 "$#"
eq  cmdsub_quoted_no_split_val "a b" "$1"

# 子 shell 语义: 里面的 cd/赋值不影响父 shell
cd /
parent=$PWD
sub=$(cd $T; pwd)
eq  cmdsub_subshell_cd "$T" "$sub"
eq  cmdsub_subshell_no_leak "$parent" "$PWD"

# 退出码: 命令替换的退出码进 $?
x=$(false)
eq  cmdsub_exit_status 1 "$?"
xtrue=$(true)
eq  cmdsub_exit_status_true 0 "$?"
false
eq  cmdsub_keeps_dollar_q 1 "$?"

# 位置参数经命令替换继承给子 shell
set -- p1 p2
eq  cmdsub_posargs "p1" "$(echo $1)"
sh -c 'echo "$(echo $1)"' nm argone > $T/posarg.log
eq  cmdsub_posargs_sh "argone" "$(cat $T/posarg.log)"

# 结果是命令名: $(echo echo) hi
out=$(echo echo)
eq  cmdsub_as_command "hi" "$($out hi)"

# Delin 特有: 命令替换的子 shell 必须看见父 shell 的 cwd(内核继承的 cwd, 不是 $HOME)
cd $T/sub
subpwd=$(pwd)
eq  cmdsub_child_cwd "$T/sub" "$subpwd"
cd $T

# Delin 特有: 别名也要注入命令替换的子 shell(Delin 的别名是求值期替换, 子 shell 是新进程)
alias shexpand_say='echo aliased'
eq  cmdsub_alias "aliased" "$(shexpand_say)"
unalias shexpand_say

# Delin 特有: 不支持的 `( list )` 子 shell 分组必须报语法错(静默丢弃剩下的输入 = 假成功)
sh -c '(echo hi)' > $T/subshell.log
eq  syntax_subshell_status 2 "$?"

# 大输出(超过内核管道缓冲 16KB)不能死锁: 读端让出调度器, 写端才能继续写。
i=1
rm -f $T/big
while [ $i -le 400 ]; do echo "line $i of the big file used to exercise pipe flow control" >> $T/big; i=$((i+1)); done
eq  cmdsub_large_output 400 "$(cat $T/big | wc -l)"
rm -f $T/big
set --

# ---------------------------------------------------------------
# 3. 算术展开 $(( ))
# ---------------------------------------------------------------
eq  arith_add 3 "$((1+2))"
eq  arith_precedence 7 "$((1+2*3))"
eq  arith_parens 9 "$(((1+2)*3))"
eq  arith_parens_spaced 9 "$(( (1+2)*3 ))"
eq  arith_unary_minus "-1" "$((-(1)))"
eq  arith_div "-3" "$(( (0-7)/2 ))"
eq  arith_mod "-1" "$(( (0-7)%2 ))"
eq  arith_mod_positive 1 "$((7%3))"
eq  arith_compare 1 "$((2<3))"
eq  arith_compare_eq 1 "$((2<=2))"
eq  arith_compare_ne 1 "$((3!=4))"
eq  arith_logic_and 0 "$((1&&0))"
eq  arith_logic_or 1 "$((1||0))"
eq  arith_logic_not 1 "$((!0))"
eq  arith_ternary 2 "$((1?2:3))"
eq  arith_ternary_false 3 "$((0?2:3))"
eq  arith_shift_left 8 "$((1<<3))"
eq  arith_shift_right 4 "$((16>>2))"
eq  arith_bit_and 2 "$((6&3))"
eq  arith_bit_or 7 "$((6|3))"
eq  arith_bit_xor 5 "$((6^3))"
eq  arith_bit_not "-1" "$((~0))"
eq  arith_hex 31 "$((0x1f))"
eq  arith_octal 15 "$((017))"
eq  arith_comma 2 "$((1,2))"

a=5
eq  arith_var_read 10 "$((a*2))"
eq  arith_var_assign 8 "$((a+=3))"
eq  arith_var_write_back 8 "$a"
k=1+2
eq  arith_var_recursive 3 "$((k))"
i=0
eq  arith_post_increment 0 "$((i++))"
eq  arith_post_increment_after 1 "$i"
eq  arith_pre_increment 2 "$((++i))"
eq  arith_post_decrement 2 "$((i--))"
eq  arith_post_decrement_after 1 "$i"
eq  arith_nested_in_cmdsub 5 "$(($(echo 2)+3))"

# 出错必须 fail-fast(退出码 1), 不能静默当 0
echo $((1/0)) > $T/divzero.log
eq  arith_divzero_status 1 "$?"
echo $((1+)) > $T/badexpr.log
eq  arith_badexpr_status 1 "$?"
echo "after errors" > $T/after.log
eq  arith_continues_after_error "after errors" "$(cat $T/after.log)"

# ---------------------------------------------------------------
# 7. 波浪号展开(POSIX 2.6.1; 期望值对着 bash 实测核对)
# ---------------------------------------------------------------
# 判据: 只在**词首**、且 ~ 前缀整个落在未加引号的原文里才展开;
# ~nosuchuser / ~$USER / "~" / a~b 一律保持原样(bash 同此)。
eq  tilde_home "$HOME" "$(echo ~)"
eq  tilde_home_slash "$HOME/x" "$(echo ~/x)"
eq  tilde_user_root "/root" "$(echo ~root)"
eq  tilde_user_root_slash "/root/x" "$(echo ~root/x)"
eq  tilde_unknown_user "~nosuchuser/x" "$(echo ~nosuchuser/x)"
eq  tilde_quoted "~" "$(echo "~")"
eq  tilde_not_word_start "a~b" "$(echo a~b)"
eq  tilde_after_var "~$USER" "$(echo ~$USER)"
eq  tilde_in_assignment "$HOME/bin" "$(X=~/bin; echo $X)"
eq  tilde_mixed_quotes "$HOME/x" "$(echo ~/"x")"
# 展开结果按未加引号处理: 通配符照样生效
mkdir -p "$HOME/tildetest"
touch "$HOME/tildetest/a.txt" "$HOME/tildetest/b.txt"
eq  tilde_then_glob "$HOME/tildetest/a.txt $HOME/tildetest/b.txt" "$(echo ~/tildetest/*.txt)"

# ---------------------------------------------------------------
echo "== summary =="
echo "$outcome"
exit $outcome
