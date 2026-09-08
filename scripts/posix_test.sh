#!/bin/sh
# Delin POSIX self-test (portable).
# 可移植 POSIX sh; 既能在宿主( dash/bash )跑, 也能在 Delin sh 跑。
# 只用 Delin 支持的子集: 无命令替换($()/``)、无算术 $(( ))。支持管道(|)。
# 每个检查输出一行 "ok <name>" 或 "ng <name>"; 全部 ok 退出码 0。
# 用途: 在 host 与 Delin 各跑一次, 比对输出(应一致)。

T=/tmp/posix_self
outcome=0
SAVED_IFS="$IFS"

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

# ---------------------------------------------------------------
# 5c. 管道 | (host bash/dash 与 Delin sh 均支持)
# ---------------------------------------------------------------
echo "alpha" > "$T/p1.txt"
echo "beta" >> "$T/p1.txt"
# 单段管道: 左端输出喂给右端
cat "$T/p1.txt" | wc -l > "$T/pl.txt"
grep "^2$" "$T/pl.txt" > "$T/pl1.txt"
chk pipe_wc_l [ -s "$T/pl1.txt" ]
# 内容经管道喂给右端匹配
echo "beta" | grep "^beta$" > "$T/pp.txt"
chk pipe_grep [ -s "$T/pp.txt" ]
# 三段管道: cat | grep | wc -l
cat "$T/p1.txt" | grep beta | wc -l > "$T/p3.txt"
grep "^1$" "$T/p3.txt" > "$T/p31.txt"
chk pipe_3stage [ -s "$T/p31.txt" ]

# ---------------------------------------------------------------
# 5d. 多行命令: 行续接(`\` + 换行) 与跨行结构
# ---------------------------------------------------------------
# 行续接把两行拼成一条命令(参数可写在续行上)
echo ML1 \
     ML2 > "$T/ml1.txt"
grep -F "ML1 ML2" "$T/ml1.txt" > "$T/ml1g.txt"
chk multiline_cont_args [ -s "$T/ml1g.txt" ]

# 行续接发生在词内部: foo\<换行>bar 是同一个词 "foobar"
echo foo\
bar > "$T/ml2.txt"
grep -F "foobar" "$T/ml2.txt" > "$T/ml2g.txt"
chk multiline_cont_in_word [ -s "$T/ml2g.txt" ]

# 双引号内 `\` + 换行 也被删除(POSIX); 单引号内则是字面反斜杠 + 换行
echo "dq\
cont" > "$T/ml3.txt"
grep -F "dqcont" "$T/ml3.txt" > "$T/ml3g.txt"
chk multiline_cont_dquote [ -s "$T/ml3g.txt" ]

# 管道连接符 `|` 之后可以换行(换行不算命令结束)
echo pipe |
    wc -l > "$T/ml4.txt"
grep "^1" "$T/ml4.txt" > "$T/ml4g.txt"
chk multiline_cont_pipe [ -s "$T/ml4g.txt" ]

# `&&` 之后可以换行
[ 1 = 1 ] &&
    chk multiline_cont_and true

# 清理
rm -rf "$T"
chk cleanup [ ! -e "$T" ]

# ---------------------------------------------------------------
# 6. chmod / chown / 脚本执行 + shebang / mount 列表
# ---------------------------------------------------------------
S=/tmp/delin_new
rm -rf "$S"
mkdir -p "$S"

# chmod 八进制: 755 -> -rwxr-xr-x
echo "perm" > "$S/perm.txt"
chmod 755 "$S/perm.txt"
ls -l "$S/perm.txt" > "$S/lsperm.txt"
grep -F "rwxr-xr-x" "$S/lsperm.txt" > "$S/p1.txt"
chk chmod_octal [ -s "$S/p1.txt" ]

# chmod 符号: 755 上 u-w -> -r-xr-xr-x (555)
chmod u-w "$S/perm.txt"
ls -l "$S/perm.txt" > "$S/lsperm2.txt"
grep -F "r-xr-xr-x" "$S/lsperm2.txt" > "$S/p2.txt"
chk chmod_symbolic [ -s "$S/p2.txt" ]

# chmod 644 -> -rw-r--r--
chmod 644 "$S/perm.txt"
ls -l "$S/perm.txt" > "$S/lsperm3.txt"
grep -F "rw-r--r--" "$S/lsperm3.txt" > "$S/p3.txt"
chk chmod_644 [ -s "$S/p3.txt" ]

# chmod 递归: -R 应用到子目录内的文件
mkdir -p "$S/sub"
echo "x" > "$S/sub/f"
chmod -R 700 "$S/sub"
ls -l "$S/sub/f" > "$S/lsrec.txt"
grep -F "rwx------" "$S/lsrec.txt" > "$S/p4.txt"
chk chmod_recursive [ -s "$S/p4.txt" ]

# chown: 数字/名字(宿主对改属主受限, 但命令应无错且解析正确)
chown 1000:1000 "$S/perm.txt"
chk chown_numeric [ -e "$S/perm.txt" ]
chown alice "$S/perm.txt"
chk chown_name [ -e "$S/perm.txt" ]

# 脚本执行 + shebang: 直接以可执行文件跑(经解释器), 或以 sh <script> 跑。
echo '#!/bin/sh' > "$S/my.sh"
echo 'echo "SHEBANG_OK arg1=$1"' >> "$S/my.sh"
chmod 755 "$S/my.sh"
"$S/my.sh" hello > "$S/out1.txt"
grep -F "SHEBANG_OK arg1=hello" "$S/out1.txt" > "$S/s1.txt"
chk run_shebang_exec [ -s "$S/s1.txt" ]
sh "$S/my.sh" world > "$S/out2.txt"
grep -F "SHEBANG_OK arg1=world" "$S/out2.txt" > "$S/s2.txt"
chk run_sh_script [ -s "$S/s2.txt" ]

# 无 shebang 的 Lua 程序(./script 直接跑): 以 Lua 源码执行, 输出走 io.write(print 被内核接管)。
echo 'io.write("LUAOK")' > "$S/prog.lua"
chmod 755 "$S/prog.lua"
"$S/prog.lua" > "$S/o3.txt"
grep "LUAOK" "$S/o3.txt" > "$S/s3.txt"
chk run_lua_exec [ -s "$S/s3.txt" ]

# mount 无参应列出挂载(宿主/Delin 均至少有输出, 内容不必一致)。
mount > "$S/mnt.txt"
chk mount_list [ -s "$S/mnt.txt" ]

rm -rf "$S"
chk new_cleanup [ ! -e "$S" ]

# ---------------------------------------------------------------
# 12. read 内建 / sleep
# ---------------------------------------------------------------
# 管道里的内建在 POSIX 里跑在子 shell 中(变量不外泄), 所以用 { ... } 把 read 与判定放一起,
# 这样宿主 bash/dash 与 Delin 的结论一致。
rd_two() { echo "a b c" | { read rx ry; [ "$rx" = "a" ] && [ "$ry" = "b c" ]; }; }
chk read_two_fields rd_two

rd_ifs() { echo "p:q:r" | { IFS=: read ra rb rc; [ "$ra" = "p" ] && [ "$rb" = "q" ] && [ "$rc" = "r" ]; }; }
chk read_ifs_colon rd_ifs

rd_ifs_scope() { IFS=: read _z < /dev/null; [ "$IFS" = "$SAVED_IFS" ]; }
chk read_ifs_scoped rd_ifs_scope

rd_fewer() { echo "one" | { read ro1 ro2; [ "$ro1" = "one" ] && [ "$ro2" = "" ]; }; }
chk read_fewer_fields rd_fewer

rd_bslash() { echo 'back\ slash' | { read rb1; [ "$rb1" = "back slash" ]; }; }
chk read_backslash rd_bslash

rd_raw() { echo 'back\ slash' | { read -r rb2; [ "$rb2" = 'back\ slash' ]; }; }
chk read_raw rd_raw

# 被反斜杠转义的 IFS 字符不是分隔符(转义在分割时生效, 不是先还原再分割)
rd_esc_delim() { echo 'back\ slash here' | { read rx2 ry2; [ "$rx2" = "back slash" ] && [ "$ry2" = "here" ]; }; }
chk read_escaped_delim rd_esc_delim

RT=/tmp/posix_read
rm -rf "$RT"
mkdir -p "$RT"
echo "l1 l2" > "$RT/read_in"
rd_file() { read u v < "$RT/read_in"; [ "$u" = "l1" ] && [ "$v" = "l2" ]; }
chk read_from_file rd_file

rd_eof_empty() { read re < /dev/null; [ "$re" = "" ]; }
chk read_eof_empty rd_eof_empty

rd_eof_status() { read re2 < /dev/null; [ "$?" != "0" ]; }
chk read_eof_status rd_eof_status

chk sleep_zero sleep 0
chk sleep_frac sleep 0.05
chk sleep_sum sleep 0 0.05
sleep_bg() { sleep 0.05 & wait $!; [ "$?" = "0" ]; }
chk sleep_background sleep_bg
rm -rf "$RT"

# ---------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------
echo "== summary =="
exit "$outcome"
