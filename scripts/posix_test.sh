#!/bin/sh
# Delin POSIX self-test (portable).
# 可移植 POSIX sh; 既能在宿主( dash/bash )跑, 也能在 Delin sh 跑。
# 只用 Delin 支持的子集: 无管道(|)、无命令替换($()/``)、无算术 $(( ))。
# 每个检查输出一行 "ok <name>" 或 "ng <name>"; 全部 ok 退出码 0。
# 用途: 在 host 与 Delin 各跑一次, 比对输出(应一致)。

T=/tmp/posix_self
outcome=0

chk() {
    # chk <name> <cmd...> : 运行命令, 以其退出码判定(0=ok)。
    _n="$1"; shift
    "$@"
    if [ "$?" = "0" ]; then echo "ok $_n"; else echo "ng $_n"; outcome=1; fi
}
chkneg() {
    # chkneg <name> <cmd...> : 期望命令返回非 0(如 grep 无匹配)。
    _n="$1"; shift
    "$@"
    if [ "$?" != "0" ]; then echo "ok $_n"; else echo "ng $_n"; outcome=1; fi
}

# ---------------------------------------------------------------
# 1. 变量与展开
# ---------------------------------------------------------------
x=5
chk var_assign [ "$x" = "5" ]
chk brace_expand [ "${x}" = "5" ]
y="hello world"
chk quoted_space [ "$y" = "hello world" ]
n=abc
chk plain_var [ "$n" = "abc" ]
chk last_exit_dollar [ "$?" = "0" ]

# 单词切分: 未加引号的展开按 IFS 分成多个词(应产生 3 次迭代)
z="a b c"
for w in $z; do
    chk split_iter true
done

# ---------------------------------------------------------------
# 2. test / [ ] 与字符串 / 数值 / 文件
# ---------------------------------------------------------------
chk str_eq [ "abc" = "abc" ]
chk str_ne [ "abc" != "xyz" ]
chk str_n [ -n "hello" ]
chk str_z [ -z "" ]
chk num_eq [ 5 -eq 5 ]
chk num_lt [ 3 -lt 5 ]
chk num_gt [ 5 -gt 3 ]
chk file_d [ -d /etc ]
chk file_f [ -f /etc/passwd ]
chk file_e [ -e /etc/passwd ]
chk not_neg [ ! -d /nonexistent ]

# ---------------------------------------------------------------
# 3. 流程控制
# ---------------------------------------------------------------
n=7
if [ "$n" -eq 7 ]; then chk if_then true; else chk if_then false; fi
if [ "$n" -eq 999 ]; then chk else_branch false; else chk else_branch true; fi
if [ "$n" -eq 999 ]; then chk elif_branch false
elif [ "$n" -eq 8 ]; then chk elif_branch false
elif [ "$n" -eq 7 ]; then chk elif_branch true
else chk elif_branch false
fi

s=""
for i in 1 2 3; do s="$s$i"; done
chk for_loop [ "$s" = "123" ]

# && / || 短路
[ "$n" = "7" ] && chk and_short true || chk and_short false
[ "$n" = "999" ] || chk or_short true
[ "$n" = "7" ] && [ -d /etc ] && chk and_chain true
# `A && B || C` 左结合: A 失败时 C 仍应执行 (曾误作 A && (B || C) 导致 C 不跑)。
[ "$n" = "999" ] && chk andor_false_then_c true || chk andor_c_runs true
[ "$n" = "7" ] && chk andor_true_then_b true || chk andor_skip false

c=go
while [ "$c" = "go" ]; do
    chk while_body true
    c=stop
done
chk while_terminated [ "$c" = "stop" ]

k=foo
case "$k" in
    foo) chk case_match true ;;
    bar) chk case_match false ;;
    *)   chk case_match false ;;
esac
k=baz
case "$k" in
    b*) chk case_glob true ;;
    *)  chk case_glob false ;;
esac
k=bar
case "$k" in
    foo|bar) chk case_alt true ;;
    *)       chk case_alt false ;;
esac

# ---------------------------------------------------------------
# 4. 函数(位置参数)
# ---------------------------------------------------------------
t_fn() {
    if [ "$#" = "2" ] && [ "$1" = "one" ] && [ "$2" = "two" ]; then
        chk func_posargs true
    else
        chk func_posargs false
    fi
}
t_fn one two

# ---------------------------------------------------------------
# 5. 文件系统工具 + 重定向 (不捕获命令输出, 改为落盘后 grep)
# ---------------------------------------------------------------
mkdir -p "$T"
chk mkdir [ -d "$T" ]

echo "alpha" > "$T/a.txt"
chk redirect_write [ -f "$T/a.txt" ]
echo "beta" > "$T/b.txt"
echo "gamma" > "$T/c.txt"
echo "more" >> "$T/a.txt"
chk redirect_append [ -f "$T/a.txt" ]

# cat（读 b.txt）
cat "$T/b.txt" > "$T/catout.txt"
grep "^beta$" "$T/catout.txt" > "$T/c1.txt"
chk tool_cat [ -s "$T/c1.txt" ]

# head / tail（读 b.txt）
head -n 1 "$T/b.txt" > "$T/headout.txt"
grep "^beta$" "$T/headout.txt" > "$T/h1.txt"
chk tool_head [ -s "$T/h1.txt" ]
tail -n 1 "$T/b.txt" > "$T/tailout.txt"
grep "^beta$" "$T/tailout.txt" > "$T/t1.txt"
chk tool_tail [ -s "$T/t1.txt" ]

# 追加（>> 应保留原有内容并加上新行）
echo "more" >> "$T/b.txt"
grep "^more$" "$T/b.txt" > "$T/app.txt"
chk redirect_append_content [ -s "$T/app.txt" ]
grep "^beta$" "$T/b.txt" > "$T/app2.txt"
chk redirect_append_preserves [ -s "$T/app2.txt" ]

# wc -l / -c (把 wc 输出落盘, 再检查首列计数)
wc -l "$T/c.txt" > "$T/wcl.txt"
grep "^1 " "$T/wcl.txt" > "$T/w1.txt"
chk tool_wc_l [ -s "$T/w1.txt" ]
wc -c "$T/c.txt" > "$T/wcc.txt"
grep "^6 " "$T/wcc.txt" > "$T/w2.txt"
chk tool_wc_c [ -s "$T/w2.txt" ]

# grep(内容匹配: 匹配 -> 输出文件非空; 不匹配 -> 空)
grep "beta" "$T/b.txt" > "$T/g1.txt"
chk tool_grep_match [ -s "$T/g1.txt" ]
grep "NOPE" "$T/b.txt" > "$T/g2.txt"
chk tool_grep_nomatch [ ! -s "$T/g2.txt" ]

# sed 替换 -> 落盘
sed 's/beta/BETA/' "$T/b.txt" > "$T/b2.txt"
grep "^BETA$" "$T/b2.txt" > "$T/s1.txt"
chk tool_sed [ -s "$T/s1.txt" ]

# cp / mv / rm
cp "$T/b.txt" "$T/bb.txt"
chk tool_cp [ -f "$T/bb.txt" ]
mv "$T/bb.txt" "$T/bc.txt"
chk tool_mv [ -f "$T/bc.txt" ]
chk tool_mv_removed [ ! -f "$T/bb.txt" ]
rm -f "$T/bc.txt"
chk tool_rm [ ! -e "$T/bc.txt" ]

# ls 列出目录
ls "$T" > "$T/lsout.txt"
grep "a.txt" "$T/lsout.txt" > "$T/l1.txt"
chk tool_ls [ -s "$T/l1.txt" ]

# ---------------------------------------------------------------
# 5c. GNU 选项扩展 (host 与 Delin 输出一致才纳入检查)
#     放在独立目录 $G, 避免撑大 $T 而让 5b 的 ls 输出过大(真机 ls 重定向刷盘有量级的脆弱性)。
# ---------------------------------------------------------------
G=/tmp/gnu_self
rm -rf "$G"
mkdir -p "$G"

# cat -n: 给第一行编号 "1"
echo "beta" > "$G/n.txt"
cat -n "$G/n.txt" > "$G/cn.txt"
grep "^[ ]*1" "$G/cn.txt" > "$G/cn1.txt"
chk gnu_cat_n [ -s "$G/cn1.txt" ]

# cat -b: 非空行编号; 空行不编号
echo "x" > "$G/nb0.txt"
echo "" >> "$G/nb0.txt"
echo "y" >> "$G/nb0.txt"
cat -b "$G/nb0.txt" > "$G/cnb.txt"
grep "^[ ]*1" "$G/cnb.txt" > "$G/cnb1.txt"
grep "^[ ]*2" "$G/cnb.txt" > "$G/cnb2.txt"
chk gnu_cat_b [ -s "$G/cnb1.txt" ]
chk gnu_cat_b2 [ -s "$G/cnb2.txt" ]

# wc -m: 字符数 (ASCII 下 == 字节数)
wc -m "$G/n.txt" > "$G/wcm.txt"
grep "^5 " "$G/wcm.txt" > "$G/wcm1.txt"
chk gnu_wc_m [ -s "$G/wcm1.txt" ]

# wc -L: 最长行长度
wc -L "$G/n.txt" > "$G/wclen.txt"
grep "^4 " "$G/wclen.txt" > "$G/wclen1.txt"
chk gnu_wc_L [ -s "$G/wclen1.txt" ]

# head -c 3: 只取前 3 字节
head -c 3 "$G/n.txt" > "$G/hc.txt"
wc -c "$G/hc.txt" > "$G/hcw.txt"
grep "^3 " "$G/hcw.txt" > "$G/hcw1.txt"
chk gnu_head_c [ -s "$G/hcw1.txt" ]

# tail -c 3: 只取末尾 3 字节
tail -c 3 "$G/n.txt" > "$G/tc.txt"
wc -c "$G/tc.txt" > "$G/tcw.txt"
grep "^3 " "$G/tcw.txt" > "$G/tcw1.txt"
chk gnu_tail_c [ -s "$G/tcw1.txt" ]

# grep -c: 计数 (单文件只输出数字)
grep -c beta "$G/n.txt" > "$G/gc.txt"
grep "^1$" "$G/gc.txt" > "$G/gc1.txt"
chk gnu_grep_c [ -s "$G/gc1.txt" ]

# grep -l: 只输出文件名
grep -l beta "$G/n.txt" > "$G/gl.txt"
grep "n.txt" "$G/gl.txt" > "$G/gl1.txt"
chk gnu_grep_l [ -s "$G/gl1.txt" ]

# grep -x: 整行匹配
grep -x beta "$G/n.txt" > "$G/gx.txt"
chk gnu_grep_x [ -s "$G/gx.txt" ]

# touch -c: 不创建不存在的文件
touch -c "$G/does_not_exist.txt"
chk gnu_touch_c [ ! -e "$G/does_not_exist.txt" ]

# mkdir -v: 打印创建信息 (语言无关: 有输出即表示 -v 被接受且打印)
mkdir -v "$G/vd" > "$G/mkv.txt"
chk gnu_mkdir_v [ -s "$G/mkv.txt" ]

# cp -v: 打印源 -> 目标
cp -v "$G/n.txt" "$G/cpv.txt" > "$G/cpvout.txt"
chk gnu_cp_v [ -s "$G/cpvout.txt" ]

# rm -v: 打印 "removed" (语言无关: 有输出即表示 -v 被接受且打印)
rm -v "$G/cpv.txt" > "$G/rmv.txt"
chk gnu_rm_v [ -s "$G/rmv.txt" ]

# ls -a: 显示隐藏文件
echo "h" > "$G/.hidden"
ls -a "$G" > "$G/lsa.txt"
grep "^[.]hidden$" "$G/lsa.txt" > "$G/lsa1.txt"
chk gnu_ls_a [ -s "$G/lsa1.txt" ]

# ls -l: 长格式有权限列
ls -l "$G/n.txt" > "$G/lsl.txt"
grep "^[dl-]" "$G/lsl.txt" > "$G/lsl1.txt"
chk gnu_ls_l [ -s "$G/lsl1.txt" ]

rm -rf "$G"

rm -rf "$G"

# ---------------------------------------------------------------
# 5b. `--` 结束选项: 处理以 - / -- 开头的文件名 (POSIX Guideline 10)。
#      host 与 Delin 都应支持 touch -- --name / rm -- --name 等。
#      注: grep 用 Lua pattern(`-` 是量词), 这里用不含连字符的模式。
# ---------------------------------------------------------------
touch -- "$T/--dash.txt"
chk dash_touch [ -f "$T/--dash.txt" ]
echo "dash-line" > "$T/--dash.txt"
cat -- "$T/--dash.txt" > "$T/dc.txt"
grep "dash" "$T/dc.txt" > "$T/dc1.txt"
chk dash_cat [ -s "$T/dc1.txt" ]
wc -- "$T/--dash.txt" > "$T/dw.txt"
grep "dash" "$T/dw.txt" > "$T/dw1.txt"
chk dash_wc [ -s "$T/dw1.txt" ]
grep -- "dash" "$T/--dash.txt" > "$T/dg.txt"
chk dash_grep [ -s "$T/dg.txt" ]
ls -- "$T" > "$T/dl.txt"
grep "dash" "$T/dl.txt" > "$T/dl1.txt"
chk dash_ls [ -s "$T/dl1.txt" ]
cp -- "$T/--dash.txt" "$T/dash_copy.txt"
chk dash_cp [ -f "$T/dash_copy.txt" ]
mv -- "$T/dash_copy.txt" "$T/dash_moved.txt"
chk dash_mv [ -f "$T/dash_moved.txt" ]
rm -- "$T/dash_moved.txt"
chk dash_rm [ ! -e "$T/dash_moved.txt" ]
rm -- "$T/--dash.txt"
chk dash_rm_cleanup [ ! -e "$T/--dash.txt" ]

# 清理
rm -rf "$T"
chk cleanup [ ! -e "$T" ]

# ---------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------
echo "== summary =="
exit "$outcome"
