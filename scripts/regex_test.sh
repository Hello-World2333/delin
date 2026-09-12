#!/bin/sh
# Delin 标准正则自检(POSIX + GNU 子集): grep / sed 的方言(-E/-G/-F)、字符类、锚点、
# 最左最长、-o/-w/-x/-i、以及 POSIX 退出码(0 选中 / 1 没选中 / 2 出错)。
# 输出 "ok <name>" / "ng <name>"; 全部 ok 退出码 0。
# 用法(宿主, 期望值由宿主 GNU 工具校验): sh scripts/regex_test.sh
# 用法(宿主 harness): lua5.1 tools/harness.lua /bin/sh < scripts/regex_test.sh
# 用法(真机): sh /root/regex_test.sh
# 同一份脚本在宿主与真机各跑一次逐项比对 —— 每条期望值都对着宿主 GNU grep/sed 核过;
# 引擎本身的语义(捕获组内容/位置/非法模式)另见 tools/regextest.lua(与宿主 GNU 差分对照)。
# 注意: 只用 Delin sh 支持的子集(无 $()、无 $(())、无 here-doc、无 2>&1)。

T=/tmp/regex_self
outcome=0
ok() { echo "ok $1"; }
ng() { echo "ng $1"; outcome=1; }
eq() { # eq <name> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else ng "$1"; echo "    expected [$2] got [$3]"; fi
}
rc() { # rc <name> <expected-code> <code>
    if [ "$2" = "$3" ]; then ok "$1"; else ng "$1"; echo "    expected rc $2 got $3"; fi
}

rm -rf $T
mkdir -p $T
cd $T
printf 'abc\nac\nabbbc\na+b\naab\naabbb\nabab\nfoo bar\nFOO\nx1y\n' > in.txt

# ---------------------------------------------------------------
# 1. grep: BRE 默认(= GNU grep 的默认方言)
# ---------------------------------------------------------------
grep 'a.c' in.txt > o1.txt
eq  grep_bre_dot_any  1 "$(wc -l < o1.txt)"
grep -c 'a.c' in.txt > c1.txt
eq  grep_bre_dot_count 1 "$(cat c1.txt)"
# BRE 里 + 是字面量: 'a+b' 只匹配真的 a+b 那一行
grep -c 'a+b' in.txt > c2.txt
eq  grep_bre_plus_literal 1 "$(cat c2.txt)"
# GNU 扩展 \+ 才是量词
grep -c 'a\+b' in.txt > c3.txt
eq  grep_bre_plus_ext 5 "$(cat c3.txt)"
# BRE 分组/反向引用
grep -c '\(ab\)\1' in.txt > c4.txt
eq  grep_bre_backref 1 "$(cat c4.txt)"
# BRE 区间 \{m,n\}
grep -c 'ab\{2\}' in.txt > c5.txt
eq  grep_bre_interval 2 "$(cat c5.txt)"
# BRE 的 \{ \} 不写反斜杠时是字面量
grep -c 'ab{2}' in.txt > c6.txt
eq  grep_bre_brace_literal 0 "$(cat c6.txt)"

# ---------------------------------------------------------------
# 2. grep -E(ERE)
# ---------------------------------------------------------------
grep -E -c 'a+b' in.txt > c7.txt
eq  grep_ere_plus 5 "$(cat c7.txt)"
grep -E -c 'a{2,3}' in.txt > c8.txt
eq  grep_ere_interval 2 "$(cat c8.txt)"
grep -E -c 'a.c|FOO' in.txt > c9.txt
eq  grep_ere_alt 2 "$(cat c9.txt)"
grep -E -c '^(foo|FOO)' in.txt > c10.txt
eq  grep_ere_group 2 "$(cat c10.txt)"
grep -E -c 'ab?c' in.txt > c11.txt
eq  grep_ere_question 2 "$(cat c11.txt)"
grep -E -c 'ab+c' in.txt > c12.txt
eq  grep_ere_plus_c 2 "$(cat c12.txt)"

# ---------------------------------------------------------------
# 3. 最左最长(POSIX 语义)
# ---------------------------------------------------------------
printf 'ab\n' > one.txt
grep -o -E 'a|ab' one.txt > o2.txt
eq  grep_leftmost_longest "ab" "$(cat o2.txt)"
grep -o -E '(a|ab)(c|bcd)' one.txt > o3.txt
eq  grep_leftmost_longest_sub "" "$(cat o3.txt)"
printf 'abcd\n' > one2.txt
grep -o -E '(a|ab)(c|bcd)' one2.txt > o4.txt
eq  grep_submatch_longest "abcd" "$(cat o4.txt)"

# ---------------------------------------------------------------
# 4. grep: -i / -w / -x / -v / -o / -F / 字符类 / 锚点
# ---------------------------------------------------------------
grep -c -i foo in.txt > c13.txt
eq  grep_i 2 "$(cat c13.txt)"
grep -c -w foo in.txt > c14.txt
eq  grep_w 1 "$(cat c14.txt)"
grep -c -x 'foo bar' in.txt > c15.txt
eq  grep_x 1 "$(cat c15.txt)"
grep -c -v FOO in.txt > c16.txt
eq  grep_v 9 "$(cat c16.txt)"
grep -o -E '[[:alpha:]]+' one.txt > o5.txt
eq  grep_o_posix_class "ab" "$(cat o5.txt)"
grep -o -E '[[:digit:]]' in.txt > o6.txt
eq  grep_o_digit "1" "$(cat o6.txt)"
grep -c '^a' in.txt > c17.txt
eq  grep_anchor_bol 7 "$(cat c17.txt)"
grep -c 'b$' in.txt > c18.txt
eq  grep_anchor_eol 4 "$(cat c18.txt)"
# -F: 元字符按字面
grep -c -F 'a.c' in.txt > c19.txt
eq  grep_F_literal 0 "$(cat c19.txt)"
grep -c -F 'a+b' in.txt > c20.txt
eq  grep_F_plus 1 "$(cat c20.txt)"
# -G 显式 BRE 与默认一致
grep -G -c 'a\+b' in.txt > c21.txt
eq  grep_G_explicit 5 "$(cat c21.txt)"

# ---------------------------------------------------------------
# 5. grep 退出码(POSIX: 0 选中 / 1 没选中 / 2 出错)
# ---------------------------------------------------------------
grep -q foo in.txt;                 rc grep_rc_match 0 "$?"
grep -q zzzznope in.txt;            rc grep_rc_nomatch 1 "$?"
grep -q -E '(' in.txt;              rc grep_rc_badpattern 2 "$?"
grep -q --bad-option foo in.txt;    rc grep_rc_badoption 2 "$?"
grep zzzznope in.txt > /dev/null;   rc grep_rc_nomatch2 1 "$?"

# ---------------------------------------------------------------
# 6. sed: BRE 默认 / -E / 替换 / 地址
# ---------------------------------------------------------------
printf 'hello world\n' > s.txt
sed 's/world/there/' s.txt > s1.txt
eq  sed_basic "hello there" "$(cat s1.txt)"
# BRE 分组与反向引用(替换里 \1 \2)
printf 'abcdef\n' > s2.txt
sed 's/\(a\)\(bc\)/\2\1/' s2.txt > s3.txt
eq  sed_bre_group "bcadef" "$(cat s3.txt)"
# & = 整串
printf 'abc\n' > s4.txt
sed 's/b/[&]/' s4.txt > s5.txt
eq  sed_amp "a[b]c" "$(cat s5.txt)"
# -E: 不写反斜杠的括号与 |
printf 'aaaXXX\n' > s6.txt
sed -E 's/(a+)(X+)/[\2\1]/' s6.txt > s7.txt
eq  sed_ere_group "[XXXaaa]" "$(cat s7.txt)"
printf 'cat\n' > s8.txt
sed -E 's/cat|dog/PET/' s8.txt > s9.txt
eq  sed_ere_alt "PET" "$(cat s9.txt)"
# 全局与第 N 次
printf 'aaa\n' > s10.txt
sed 's/a/X/g' s10.txt > s11.txt
eq  sed_global "XXX" "$(cat s11.txt)"
sed 's/a/X/2' s10.txt > s12.txt
eq  sed_nth "aXa" "$(cat s12.txt)"
# 替换里的 \n 与 POSIX 字符类
printf 'a1b\n' > s13.txt
sed -E 's/[[:digit:]]/N/' s13.txt > s14.txt
eq  sed_posix_class "aNb" "$(cat s14.txt)"
# 地址: /re/
printf 'one\ntwo\nthree\n' > s15.txt
sed -n '/t/p' s15.txt > s16.txt
eq  sed_addr_regex "two
three" "$(cat s16.txt)"
sed -n '2,3p' s15.txt > s17.txt
eq  sed_addr_range "two
three" "$(cat s17.txt)"
# sed -E 的 | 地址
sed -n -E '/^(one|three)$/p' s15.txt > s18.txt
eq  sed_addr_ere "one
three" "$(cat s18.txt)"
# -i 就地修改
printf 'xyz\n' > s19.txt
sed -i 's/y/Y/' s19.txt
eq  sed_inplace "xYz" "$(cat s19.txt)"

# ---------------------------------------------------------------
# 7. expr: POSIX 的模式是 BRE, 且匹配锚定在串首
# ---------------------------------------------------------------
eq  expr_match_len     3  "$(expr match abcdef 'abc')"
eq  expr_match_dot     3  "$(expr match abcdef 'a.c')"
eq  expr_match_group   b  "$(expr match abcdef 'a\(b\)c')"
eq  expr_colon_group   ab "$(expr abcdef : '\(ab\)')"
eq  expr_match_class   6  "$(expr match abcdef '[[:alpha:]]*')"
expr match abcdef 'zzz' > /dev/null;  rc expr_rc_nomatch 1 "$?"
expr match abcdef 'c' > /dev/null;    rc expr_rc_unanchored 1 "$?"

# ---------------------------------------------------------------
# 8. ed: POSIX 的模式是 BRE(宿主没装 GNU ed 就跳过 —— 真机/harness 上照跑)
# ---------------------------------------------------------------
if command -v ed > /dev/null; then
printf 'one\ntwo\nthree\n' > e.txt
printf '2s/two/TWO/\n,n\nw\n' | ed -s e.txt > e1.txt
# 写完盘后 ed 不再打印 "?"; 只比对 ,n 的三行
grep -c 'TWO' e1.txt > e2.txt
eq  ed_subst_bre 1 "$(cat e2.txt)"
printf 'aaa\n' > e3.txt
printf 's/a/X/g\n,n\nw\n' | ed -s e3.txt > e4.txt
grep -c 'XXX' e4.txt > e5.txt
eq  ed_global 1 "$(cat e5.txt)"
printf 'aaab\n' > e6.txt
printf 's/a\\+/Z/\n,n\nw\n' | ed -s e6.txt > e7.txt
grep -c 'Zb' e7.txt > e8.txt
eq  ed_bre_plus_ext 1 "$(cat e8.txt)"
printf 'x1y\n' > e9.txt
printf 's/[[:digit:]]/N/\n,n\nw\n' | ed -s e9.txt > e10.txt
grep -c 'xNy' e10.txt > e11.txt
eq  ed_posix_class 1 "$(cat e11.txt)"
else
echo "skip ed: host has no GNU ed"
fi

# ---------------------------------------------------------------
# 9. csplit: POSIX 的模式是 BRE
# ---------------------------------------------------------------
printf '5\n10\n15\n' > c.txt
csplit -s -f cs c.txt '/^1[05]$/' > /dev/null
eq  csplit_bre_anchor "5" "$(cat cs00)"
printf 'aaa\nbbb\nccc\n' > c2.txt
csplit -s -f cs2 c2.txt '/b\{3\}/' > /dev/null
eq  csplit_bre_interval "aaa" "$(cat cs200)"


echo "== regex_test done (outcome=$outcome) =="
exit $outcome
