#!/bin/sh
# Delin 新命令批自检(awk/bc/date/env/timeout/seq/yes/rev/tac/nl/column/base64/tsort/
# uname/tty/logname/which 与分页器 more/less) —— 宿主与真机跑**同一份**。
#   宿主: 由 tools/build.lua --check 用测试台跑(harness /bin/sh < scripts/newtools_test.sh);
#   真机: posix_tools_verify.sh 调它(结果并入 /var/log/posix_verify.log)。
# 只用 Delin sh 支持的子集: 没有命令替换($()/反引号)、没有算术展开、没有 here-doc;
# 期望值一律"重定向到文件 + cmp", 对着宿主 GNU 核过(awk/bc 见各自源码头注释的覆盖范围)。
# 输出 "ok <名字>" / "ng <名字>", 任一 ng 就退出 1。
# 临时目录由调用方给(第一个参数); 没给就用 /tmp/newtools。
# 注意: Delin 的 sh **不支持** ${VAR:-default} 这种参数默认值展开, 所以这里写 if。
T=$1
if [ -z "$T" ]; then T=/tmp/newtools; fi
N=$T/new
mkdir -p "$N"
rm -rf "$N"/*
LIST=/dev/null
ng=0


# chk_eq <名字> <期望> <实际>
chk_eq() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "ng   $1 (want=$2 got=$3)"; ng=1
    fi
}
# file_eq <名字> <a> <b>
file_eq() {
    if cmp -s "$2" "$3"; then
        echo "ok   $1"
    else
        echo "ng   $1"; ng=1
        echo "     got :"; cat "$2"
        echo "     want:"; cat "$3"
    fi
}
# awk: 字段/求和/关联数组/printf/函数
printf 'a 1\nb 2\nc 3\n' > $N/in1
awk '{print $2}' $N/in1 > $N/got; printf '1\n2\n3\n' > $N/want
file_eq awk_field $N/got $N/want
awk -F: 'BEGIN{print "x"}' > $N/got; printf 'x\n' > $N/want
file_eq awk_begin $N/got $N/want
awk '{s+=$2} END{print s}' $N/in1 > $N/got; printf '6\n' > $N/want
file_eq awk_sum $N/got $N/want
awk '{a[$1]=$2} END{for (k in a) n++; print n}' $N/in1 > $N/got; printf '3\n' > $N/want
file_eq awk_array $N/got $N/want
awk 'BEGIN{printf "%03d|%s\n", 7, "x"}' > $N/got; printf '007|x\n' > $N/want
file_eq awk_printf $N/got $N/want
awk 'function f(x){return x*2} BEGIN{print f(21)}' > $N/got; printf '42\n' > $N/want
file_eq awk_function $N/got $N/want
awk '/b/{print NR}' $N/in1 > $N/got; printf '2\n' > $N/want
file_eq awk_regex $N/got $N/want
awk 'NR==1,NR==2{print $1}' $N/in1 > $N/got; printf 'a\nb\n' > $N/want
file_eq awk_range $N/got $N/want
printf 'banana\n' | awk '{n=gsub(/a/,"X"); print n, $0}' > $N/got; printf '3 bXnXnX\n' > $N/want
file_eq awk_gsub $N/got $N/want
printf 'x:1\ny:2\n' > $N/in2
awk -v OFS=- '{print $1, $2}' FS=: $N/in2 > $N/got; printf 'x-1\ny-2\n' > $N/want
file_eq awk_v_assign $N/got $N/want
printf 'x\ny\nz\n' > $N/gl.txt
awk -v f=$N/gl.txt 'BEGIN{while ((getline l < f) > 0) n++; print n}' > $N/got; printf '3\n' > $N/want
file_eq awk_getline_file $N/got $N/want
awk 'END{print NR}' $N/in1 > $N/got; printf '3\n' > $N/want
file_eq awk_end_nr $N/got $N/want
awk 'BEGIN{exit 3} END{print "end"}' > $N/got; printf 'end\n' > $N/want
file_eq awk_exit_end $N/got $N/want

# bc: 任意精度十进制 + 语言子集
printf '10/3\nscale=5\n10/3\n2^10\nsqrt(2)\nscale=10\nsqrt(2)\nobase=16\n255\n' > $N/bc1
bc -q $N/bc1 > $N/got
printf '3\n3.33333\n1024\n1.41421\n1.4142135623\nFF\n' > $N/want
file_eq bc_arith $N/got $N/want
printf 'define f(x){return x*x}\nf(7)\n' > $N/bc2
bc -q $N/bc2 > $N/got; printf '49\n' > $N/want
file_eq bc_function $N/got $N/want
printf 's(0)\nc(0)\ne(1)\nl(2)\na(1)*4\n' > $N/bc3
bc -q -l $N/bc3 > $N/got
printf '0.00000000000000000000\n1.00000000000000000000\n2.71828182845904523536\n0.69314718055994530941\n3.14159265358979323844\n' > $N/want
file_eq bc_mathlib $N/got $N/want
printf 'if (1<2) print "y"\n' > $N/bc4
bc -q $N/bc4 > $N/got; printf 'y\n' > $N/want
file_eq bc_if $N/got $N/want
printf '1/0\n' > $N/bc5
bc -q $N/bc5 > $N/got
grep -q "divide by zero" $N/got && echo "ok   bc_divzero" || { echo "ng   bc_divzero"; cat $N/got; ng=1; }

# 文本工具
printf 'abc\ndef\n' > $N/rev_in
rev $N/rev_in > $N/got; printf 'cba\nfed\n' > $N/want
file_eq rev_basic $N/got $N/want
printf 'a\nb\nc\n' > $N/tac_in
tac $N/tac_in > $N/got; printf 'c\nb\na\n' > $N/want
file_eq tac_basic $N/got $N/want
printf '1,2,3' > $N/tac_csv
tac -s, $N/tac_csv > $N/got; printf '32,1,' > $N/want
file_eq tac_sep $N/got $N/want
printf 'x\ny\n' > $N/nl_in
nl -ba $N/nl_in > $N/got
printf '     1\tx\n     2\ty\n' > $N/want
file_eq nl_basic $N/got $N/want
nl -ba -w2 -s: $N/nl_in > $N/got
printf ' 1:x\n 2:y\n' > $N/want
file_eq nl_opts $N/got $N/want
printf 'a,bb\nccc,d\n' > $N/col_in
column -t -s, $N/col_in > $N/got
printf 'a    bb\nccc  d\n' > $N/want
file_eq column_table $N/got $N/want
printf 'hello' > $N/b64_in
base64 $N/b64_in > $N/got; printf 'aGVsbG8=\n' > $N/want
file_eq base64_encode $N/got $N/want
base64 -d $N/got > $N/got2
file_eq base64_decode $N/got2 $N/b64_in
printf 'a b\nb c\n' > $N/tsort_in
tsort $N/tsort_in > $N/got; printf 'a\nb\nc\n' > $N/want
file_eq tsort_chain $N/got $N/want
printf 'a b\nb a\n' > $N/tsort_loop
tsort $N/tsort_loop > $N/got
grep -q "loop" $N/got && echo "ok   tsort_loop" || { echo "ng   tsort_loop"; cat $N/got; ng=1; }

# seq / yes / which / uname / tty / logname
seq 3 > $N/got; printf '1\n2\n3\n' > $N/want
file_eq seq_basic $N/got $N/want
seq -w 8 11 > $N/got; printf '08\n09\n10\n11\n' > $N/want
file_eq seq_width $N/got $N/want
seq -s, 1 3 > $N/got; printf '1,2,3\n' > $N/want
file_eq seq_sep $N/got $N/want
yes | head -n 2 > $N/got; printf 'y\ny\n' > $N/want
file_eq yes_head $N/got $N/want
which awk > $N/got; printf '/bin/awk\n' > $N/want
file_eq which_awk $N/got $N/want
which nosuchcommand > $N/got
[ -s $N/got ] && { echo "ng   which_missing"; ng=1; } || echo "ok   which_missing"
uname -s > $N/got; printf 'Delin\n' > $N/want
file_eq uname_sysname $N/got $N/want
uname -n > $N/got
grep -q . $N/got && echo "ok   uname_nodename" || { echo "ng   uname_nodename"; ng=1; }
which tty > /dev/null
tty > $N/got < /dev/null
grep -q "not a tty" $N/got && echo "ok   tty_notty" || { echo "ng   tty_notty"; ng=1; }
logname > $N/got
grep -q . $N/got && echo "ok   logname" || { echo "ng   logname"; ng=1; }

# date / env / timeout
date -u -d @0 +%Y-%m-%d > $N/got; printf '1970-01-01\n' > $N/want
file_eq date_epoch $N/got $N/want
date -u -d "2026-09-11 12:00:00" +%s > $N/got; printf '1789128000\n' > $N/want
file_eq date_parse $N/got $N/want
date -u -d "2026-09-11 1 day ago" +%F > $N/got; printf '2026-09-10\n' > $N/want
file_eq date_relative $N/got $N/want
date -s "2026-01-01" > $N/got
[ "$?" = "0" ] && { echo "ng   date_set_rejected"; ng=1; } || echo "ok   date_set_rejected"
env -i FOO=bar sh -c 'echo $FOO' > $N/got; printf 'bar\n' > $N/want
file_eq env_clean $N/got $N/want
env PATH=/bin echo env-ok > $N/got; printf 'env-ok\n' > $N/want
file_eq env_run $N/got $N/want
timeout 30 echo fast > $N/got; printf 'fast\n' > $N/want
file_eq timeout_ok $N/got $N/want


# 分页器: stdout 不是终端时与 cat 等价(交互行为见宿主 scripts/pager_test.sh)
more $N/in1 > $N/got
file_eq more_plain $N/got $N/in1
less $N/in1 > $N/got
file_eq less_plain $N/got $N/in1
more --no-such-option > $N/got
[ "$?" = "2" ] && echo "ok   more_bad_option" || { echo "ng   more_bad_option"; ng=1; }
less --no-such-option > $N/got
[ "$?" = "2" ] && echo "ok   less_bad_option" || { echo "ng   less_bad_option"; ng=1; }


echo "== newtools summary: ng=$ng =="
exit $ng
