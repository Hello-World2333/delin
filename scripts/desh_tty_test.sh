#!/bin/sh
# Delin desh 交互式自检(按键 -> 屏幕) —— 宿主专用。
#
# 为什么只能在宿主上跑: 真机拿不到键盘(注入按键要走 CC 事件队列, 见 scripts/intr_test.ko 那套),
# 而 desh 的全部交互行为都是"按键 -> 屏幕字节流"。测试台用 DELIN_HARNESS_TTY=1 把 stdin/stdout
# 都伪装成终端(内核 tty 的 isTTY/getSize/setRaw 的等价物), 按键直接从 stdin 喂字节, 特殊键就是
# ANSI 序列(与内核 tty 原始模式**同一套字节契约**: 见 src/kernel/tty.lua 的 KEY_SEQ)。
# 真机上的交互由人按 docs 的清单过一遍(见 for-ai.md 的 desh 一节)。
#
# 断言方式: 只看"屏幕字节流里出现过什么"(编辑器写的是转义序列, 逐字节比对没有意义)。
# 输出 "ok <name>" / "ng <name>", 全 ok 退出码 0。

cd "$(dirname "$0")/.." || exit 1
T=/tmp/delin-desh
rm -rf $T
mkdir -p $T

outcome=0
ok() { echo "ok $1"; }
ng() { echo "ng $1"; outcome=1; }

ESC=$(printf '\033')
GREY=$(printf '\033[90m')

# run_desh <按键(printf %b 转义)> [seed 目录] -> $T/out(屏幕字节流) $T/rc(退出码)
run_desh() {
    _keys="$1"; _seed="${2:-}"
    if [ -n "$_seed" ]; then
        printf '%b' "$_keys" | DELIN_HARNESS_TTY=1 DELIN_HARNESS_ROOT=$T/root DELIN_HARNESS_SEED="$_seed" \
            lua5.1 tools/harness.lua /bin/desh > $T/out 2>&1
    else
        printf '%b' "$_keys" | DELIN_HARNESS_TTY=1 DELIN_HARNESS_ROOT=$T/root \
            lua5.1 tools/harness.lua /bin/desh > $T/out 2>&1
    fi
    echo $? > $T/rc
}

# has <名字> <子串>: 屏幕流里出现过这段文本(固定串, 不按正则解释)
has() { if grep -aqF -- "$2" $T/out; then ok "$1"; else ng "$1"; echo "    missing [$2]"; fi; }
lacks() { if grep -aqF -- "$2" $T/out; then ng "$1"; echo "    unexpected [$2]"; else ok "$1"; fi; }
# has_line <名字> <整行文本>: 屏幕流里出现过**恰好这一行**(编辑器画的行前面挂着提示符, 不算)
has_line() { if grep -aq "^$2\$" $T/out; then ok "$1"; else ng "$1"; echo "    missing line [$2]"; fi; }
lacks_line() { if grep -aq "^$2\$" $T/out; then ng "$1"; echo "    unexpected line [$2]"; else ok "$1"; fi; }
# eqrc <名字> <期望退出码>
eqrc() { if [ "$(cat $T/rc)" = "$2" ]; then ok "$1"; else ng "$1"; echo "    rc=$(cat $T/rc) expected $2"; fi; }

# ---------- 1. 打字 + 回车执行 ----------
run_desh 'echo typed-ok\n'
has  typed-executes 'typed-ok'
eqrc typed-rc0 0

# ---------- 2. Tab: 命令补全(PATH/内建) ----------
run_desh 'ech\thi\n'
has_line tab-command-runs 'hi'
has  tab-command-completed 'echo hi'

# ---------- 3. Tab: 路径补全(唯一候选 -> 补全并补空格) ----------
run_desh 'cat /pub\t\n'
has  tab-path-unique 'public data'

# ---------- 4. Tab: 多候选 -> 列菜单 ----------
run_desh 'cat /p\t\n'
has  tab-path-menu 'proc'

# ---------- 5. Tab: 候选过多时先问一句(bash 同义) ----------
run_desh '\tn\n'
has  tab-many-asks 'possibilities?'

# ---------- 6. 变量补全 ----------
run_desh 'echo $HO\t\n'
has  tab-var-complete '$HOME'

# ---------- 7. 灰字智能提示(历史内联建议) ----------
run_desh 'echo one\nech'
has  suggest-grey "$GREY"
has  suggest-suffix 'one'

# ---------- 8. → 接受建议(回车只执行真实输入) ----------
run_desh 'echo one\nech\033[C\n'
n=$(grep -acF -- 'one' $T/out)
if [ "$n" -ge 3 ]; then ok suggest-accept; else ng suggest-accept; echo "    one lines=$n"; fi

# ---------- 9. 上箭头翻历史 ----------
run_desh 'echo two\n\033[A\n'
n=$(grep -acF -- 'two' $T/out)
if [ "$n" -ge 3 ]; then ok history-up; else ng history-up; echo "    two lines=$n"; fi

# ---------- 10. ^R 增量搜索 ----------
run_desh 'echo beta\n\022beta\n'
has  history-ctrl-r 'beta'

# ---------- 11. ^C 取消当前行, 下一条命令照常执行 ----------
run_desh 'echo abc\003echo after\n'
has_line  ctrl-c-next-runs 'after'
lacks_line ctrl-c-cancelled 'abc'

# ---------- 12. ^U 清行 ----------
run_desh 'junk line\025echo ok\n'
has_line  ctrl-u-clears 'ok'
lacks_line ctrl-u-no-junk 'junk line'

# ---------- 13. 长行的横向开窗(两端用 < > 标) ----------
run_desh 'echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
has  long-line-window '<'

# ---------- 14. 错误更正: command not found 的 did-you-mean ----------
run_desh 'sl\nexit\n'
has  correct-sl "did you mean 'ls'"
run_desh 'echp hi\nexit\n'
has  correct-echp "did you mean 'echo'"

# ---------- 15. ^D 空行 = EOF, 干净退出 ----------
run_desh 'echo bye\n\004'
has  eof-after-command 'bye'
eqrc eof-rc0 0

# ---------- 16. 历史落盘 ($HISTFILE 缺省 ~/.desh_history) ----------
run_desh 'echo histline\n'
if grep -qF -- 'echo histline' $T/root/root/.desh_history 2>/dev/null; then
    ok history-file
else
    ng history-file; echo "    ~/.desh_history missing or without the line"
fi

# ---------- 17. 行首空格的命令不进历史(bash 的 HISTCONTROL=ignorespace) ----------
run_desh 'echo visible\n echo secret\n'
if grep -qF -- 'echo secret' $T/root/root/.desh_history 2>/dev/null; then
    ng history-ignorespace
else
    ok history-ignorespace
fi

# ---------- 18. deshrc: PS1 / HISTFILE / 开关都由它说了算 ----------
seed=$T/seed
mkdir -p $seed/root $seed/tmp
printf 'PS1="rc-prompt# "\nHISTFILE=/tmp/desh_hist\nHISTSIZE=50\n' > $seed/root/.deshrc
run_desh 'echo rc-run\n' "$seed"
has  deshrc-ps1 'rc-prompt# '
if grep -qF -- 'echo rc-run' $T/root/tmp/desh_hist 2>/dev/null; then
    ok deshrc-histfile
else
    ng deshrc-histfile; echo "    HISTFILE from deshrc not honored"
fi

# ---------- 19. deshrc: 关掉智能提示 ----------
seed2=$T/seed2
mkdir -p $seed2/root
printf 'DESH_AUTOSUGGEST=0\n' > $seed2/root/.deshrc
run_desh 'echo one\nech' "$seed2"
lacks deshrc-suggest-off "$GREY"

# ---------- 20. deshrc: 关掉纠错建议 ----------
seed3=$T/seed3
mkdir -p $seed3/root
printf 'DESH_CORRECT=0\n' > $seed3/root/.deshrc
run_desh 'sl\nexit\n' "$seed3"
lacks deshrc-correct-off 'did you mean'

# ---------- 21. deshrc 里的别名/函数在交互式下可用 ----------
seed4=$T/seed4
mkdir -p $seed4/root
printf 'alias hi="echo aliased"\n' > $seed4/root/.deshrc
run_desh 'hi\n' "$seed4"
has  deshrc-alias 'aliased'

echo "desh_tty_test done (outcome=$outcome)"
exit $outcome
