#!/bin/sh
# Delin 分页器自检(more / less) —— 宿主专用(在仓库根目录运行: sh scripts/pager_test.sh)。
#
# 为什么要在宿主上测: 真机取不到键盘(注入按键要走 CC 事件队列, 见 scripts/intr_test.ko 那套),
# 而分页器的全部行为都是"按键 -> 屏幕"的交互。测试台用 DELIN_HARNESS_TTY=1 把 stdin/stdout
# 都伪装成终端(内核 tty 的 isTTY/getSize/setRaw 的等价物), 按键直接从 stdin 里喂字节,
# 特殊键就是 ANSI 序列(与内核 tty 的原始模式**同一套字节契约**: 见 src/kernel/tty.lua 的 KEY_SEQ)。
#
# 断言方式: 只看"屏幕字节流里出现过什么"(分页器写的是转义序列, 逐字节比对没有意义):
#   - 第一屏必须恰好是 18 行(测试台假终端 51x19, 末行留给提示符)且带 --More--;
#   - 按键之后出现的行号必须跟着变(说明真的翻页了, 而不是一次把文件打完);
#   - stdout 不是终端时必须与 cat 等价。
# 输出 "ok <name>" / "ng <name>", 全 ok 退出码 0。

cd "$(dirname "$0")/.." || exit 1
T=/tmp/delin-pager
rm -rf $T
mkdir -p $T

outcome=0
ok() { echo "ok $1"; }
ng() { echo "ng $1"; outcome=1; }

# run_pager <工具> <按键(可含 \n 等转义)> <参数...> -> $T/out, 退出码写 $T/rc
run_pager() {
    _tool="$1"; _keys="$2"; shift 2
    printf '%b' "$_keys" | DELIN_HARNESS_TTY=1 lua5.1 tools/harness.lua "$_tool" "$@" > "$T/out" 2>&1
    echo $? > "$T/rc"
}
# count_line <行文本> <文件>: 该行在文件里出现的次数
# 行首可能挂着提示符的清行转义(\r\033[K), 所以只锚行尾。
count_line() { grep -c "$1\$" "$2" 2>/dev/null | tr -d ' '; }
# count_ge <行文本> <文件> <下限>: 出现次数是否 >= 下限(回翻/搜索会让同一行再次出现在屏幕上)
count_ge() {
    _n=$(count_line "$1" "$2")
    [ -n "$_n" ] && [ "$_n" -ge "$3" ]
}

# ---------- more ----------
run_pager /bin/more 'q' /long
[ "$(cat $T/rc)" = "0" ] && ok "more-quit-rc0" || ng "more-quit-rc0"
[ "$(count_line 'line 18' $T/out)" = "1" ] && ok "more-first-screen-18-lines" || ng "more-first-screen-18-lines"
[ "$(count_line 'line 19' $T/out)" = "0" ] && ok "more-stops-at-18" || ng "more-stops-at-18"
grep -q -- '--More--' $T/out && ok "more-prompt" || ng "more-prompt"

run_pager /bin/more ' q' /long
[ "$(count_line 'line 19' $T/out)" = "1" ] && ok "more-space-next-screen" || ng "more-space-next-screen"
[ "$(count_line 'line 36' $T/out)" = "1" ] && ok "more-second-screen-18" || ng "more-second-screen-18"
[ "$(count_line 'line 37' $T/out)" = "0" ] && ok "more-second-screen-stops" || ng "more-second-screen-stops"

run_pager /bin/more ' bq' /long
# 第一屏 1-18, 空格到 19-36, b 回到 1-18 -> "line 01" 出现两次
[ "$(count_line 'line 01' $T/out)" = "2" ] && ok "more-back-to-first" || ng "more-back-to-first"

run_pager /bin/more '/needle\nq' /long
# 命中行在第一屏里也有, 搜索会把屏幕重新滚到它 -> 至少出现两次
count_ge 'line 12 needle' $T/out 2 && ok "more-search" || ng "more-search"

run_pager /bin/more 'dqq' /long
# 半屏 = 9 行: 第一屏 1-18, 按 d 后从 10 开始 -> 10..27
[ "$(count_line 'line 27' $T/out)" = "1" ] && ok "more-half-screen" || ng "more-half-screen"

# stdout 不是终端 -> 与 cat 等价(全部 40 行, 无提示符)。
# 注意: 这里**不能**换 DELIN_HARNESS_ROOT —— 测试台会重建根目录, /long 就没了。
lua5.1 tools/harness.lua /bin/more /long > $T/plain 2>&1
[ "$(count_line 'line 40' $T/plain)" = "1" ] && ok "more-plain-when-not-tty" || ng "more-plain-when-not-tty"
grep -q -- '--More--' $T/plain && ng "more-plain-no-prompt" || ok "more-plain-no-prompt"

# ---------- less ----------
run_pager /bin/less 'q' /long
[ "$(cat $T/rc)" = "0" ] && ok "less-quit-rc0" || ng "less-quit-rc0"
[ "$(count_line 'line 18' $T/out)" = "1" ] && ok "less-first-screen" || ng "less-first-screen"
[ "$(count_line 'line 19' $T/out)" = "0" ] && ok "less-first-screen-stops" || ng "less-first-screen-stops"
grep -q -- '\[K:' $T/out && ok "less-prompt" || ng "less-prompt"

run_pager /bin/less ' q' /long
[ "$(count_line 'line 19' $T/out)" = "1" ] && ok "less-space-next" || ng "less-space-next"

run_pager /bin/less 'Gq' /long
[ "$(count_line 'line 40' $T/out)" = "1" ] && ok "less-G-end" || ng "less-G-end"
# G 之后最后一屏从 23 开始(40 - 18 + 1), 所以 22 只可能出现在更早的屏里
[ "$(count_line 'line 23' $T/out)" = "1" ] && ok "less-G-screen-start" || ng "less-G-screen-start"

run_pager /bin/less 'Ggq' /long
# G 到末尾, g 回到开头 -> "line 01" 出现两次(首屏一次, g 之后一次)
[ "$(count_line 'line 01' $T/out)" = "2" ] && ok "less-g-start" || ng "less-g-start"

run_pager /bin/less '/needle\nq' /long
count_ge 'line 12 needle' $T/out 2 && ok "less-search" || ng "less-search"

run_pager /bin/less '-Nq' /long
grep -q '^ *12 line 12 needle' $T/out && ok "less-N-numbers" || ng "less-N-numbers"

run_pager /bin/less 'dq' /long
[ "$(count_line 'line 27' $T/out)" = "1" ] && ok "less-half-screen" || ng "less-half-screen"

# stdout 不是终端 -> 与 cat 等价
lua5.1 tools/harness.lua /bin/less /long > $T/plain2 2>&1
[ "$(count_line 'line 40' $T/plain2)" = "1" ] && ok "less-plain-when-not-tty" || ng "less-plain-when-not-tty"

# 未实现的选项必须 fail-fast(不静默当文件名/静默忽略)
lua5.1 tools/harness.lua /bin/less -o /tmp/x /long > $T/bad 2>&1
grep -q 'not supported' $T/bad && ok "less-unsupported-fails" || ng "less-unsupported-fails"
lua5.1 tools/harness.lua /bin/less --bogus /long > $T/bad2 2>&1
grep -q 'unrecognized option' $T/bad2 && ok "less-bad-long-option" || ng "less-bad-long-option"

if [ $outcome -eq 0 ]; then echo "pager_test: all ok"; else echo "pager_test: FAILED"; fi
exit $outcome
