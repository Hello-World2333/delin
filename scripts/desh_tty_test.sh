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
# grey_after <名字> <已打的字> <灰字>: 屏幕上出现过"这几个字 + 灰字 + 复位"的一帧
grey_after() { if grep -aqF -- "$2${GREY}$3${RESET}" $T/out; then ok "$1"; else ng "$1"; echo "    missing frame [$2 <grey>$3<reset>]"; fi; }
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

# ---------- 7. 灰字内联提示: **与 Tab 补全同源**(补的是命令/目录/变量名, 不是历史命令) ----------
run_desh 'echo one\nech'
has  suggest-grey "$GREY"
# Tab 在 `ech` 上补的是 `echo` -> 灰字提示的就是剩下的那一截 "o"
grey_after suggest-same-as-tab 'ech' 'o'
# 从前的实现提示的是历史里那条 `echo one` 的尾巴("o one"), 那正是被去掉的行为
lacks suggest-not-history "ech${GREY}o one"
run_desh 'cat /pu'
grey_after suggest-path 'cat /pu' 'b'   # 唯一候选 public(Tab 也补它)
run_desh 'echo $HO'
grey_after suggest-var 'echo $HO' 'ME'  # 唯一候选 $HOME

# ---------- 8. → 接受提示(= 补上 Tab 第一次会补的那一截) ----------
run_desh 'basen\033[C /a/b\n'
has_line suggest-accept 'b'   # basen -> basename, 执行后输出 b

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

# ---------- 11b. ^C 在 PS2 续行下取消**整条**输入(真实 bash/dash/zsh 同此) ----------
# 曾经的 bug: ^C 只丢当前这一行, 于是 `echo "abc` 之后按 ^C 又出一个 PS2 退不出去,
# 而之后打的每一行都被并进那条没闭合的引号里(最后报 unexpected end of file)。
run_desh 'echo "abc\n\003echo AFTER\n'
has_line  ps2-ctrl-c-next-runs 'AFTER'
lacks     ps2-ctrl-c-not-merged 'syntax error'

# ---------- 12. ^U 清行 ----------
run_desh 'junk line\025echo ok\n'
has_line  ctrl-u-clears 'ok'
lacks_line ctrl-u-no-junk 'junk line'

# ---------- 13. 长行的横向开窗(两端用 < > 标) ----------
run_desh 'echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
has  long-line-window '<'

# ---------- 14. 纠错: zsh 的 `correct 'x' to 'y' [nyae]?` 提问 ----------
# y = 按更正后的命令执行(zsh 同此), n = 不更正(照常报 command not found)
run_desh 'sl\ny\n'
has  correct-prompt "desh: correct 'sl' to 'ls' [nyae]? "
has  correct-y-runs 'bin'          # ls / 的输出
lacks correct-y-no-error 'command not found'
run_desh 'echp hi\nn\n'
has  correct-n-echp "desh: correct 'echp' to 'echo' [nyae]? "
has  correct-n-error 'desh: echp: command not found'
# a = 放弃整条命令行(本行剩下的命令也不跑), $? 为 1
run_desh 'sl; echo SECOND\na\necho rc=$?\n'
has   correct-a-no-error-later 'rc=1'
lacks_line correct-a-rest-not-run 'SECOND'  # 只算"真的跑出来的输出", 编辑器回显的那行挂提示符
# e = 把更正后的命令行摆回行编辑器(回车即执行)
run_desh 'echp hi\ne\n\n'
has   correct-e-prefix 'correct '\''echp'\'' to '\''echo'\'' [nyae]? e'
has_line correct-e-runs 'hi'
# 不存在的命令没有候选 -> 连提问都不该出现
run_desh 'nosuch123cmd\n'
lacks correct-none 'correct '

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

# ---------- 19. deshrc: 关掉灰字提示 ----------
seed2=$T/seed2
mkdir -p $seed2/root
printf 'DESH_AUTOSUGGEST=0\n' > $seed2/root/.deshrc
run_desh 'echo one\nech' "$seed2"
lacks deshrc-suggest-off "$GREY"

# ---------- 20. deshrc: 关掉纠错提问 ----------
seed3=$T/seed3
mkdir -p $seed3/root
printf 'DESH_CORRECT=0\n' > $seed3/root/.deshrc
run_desh 'sl\ny\n' "$seed3"
lacks deshrc-correct-off 'correct '
has   deshrc-correct-off-err 'desh: sl: command not found'

# ---------- 21. deshrc 里的别名/函数在交互式下可用 ----------
seed4=$T/seed4
mkdir -p $seed4/root
printf 'alias hi="echo aliased"\n' > $seed4/root/.deshrc
run_desh 'hi\n' "$seed4"
has  deshrc-alias 'aliased'

echo "desh_tty_test done (outcome=$outcome)"
exit $outcome
