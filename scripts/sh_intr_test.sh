#!/bin/sh
# Delin sh 交互式"提示符处 ^C"自检 —— 宿主专用(在仓库根目录运行: sh scripts/sh_intr_test.sh)。
# 真机取不到键盘(注入按键要走 CC 事件队列, 见 scripts/installer_interactive_test.lua 那套),
# 所以用测试台的 DELIN_HARNESS_TTY=1 把 stdin 伪装成终端 + `\3` 行模拟"打了一半按 ^C"
# (两件事一起模拟: 行规程丢掉当前行 + 给前台进程组投 SIGINT, 见 tools/harness.lua)。
#
# 锁的是这个 bug: 提示符处 ^C 投出的 SIGINT 没人消费, 留到下一轮被 pollWait 当成
# "^C 中断" —— 下一条**外部**命令刚 spawn 就被 SIGKILL, 屏幕上什么都不输出(退出码 130),
# 再下一条才恢复。所以断言用的是外部命令(basename), 内建命令(echo)掩盖不了它。
# 输出 "ok <name>" / "ng <name>", 全 ok 退出码 0。

cd "$(dirname "$0")/.." || exit 1
T=/tmp/delin-sh-intr
rm -rf $T
mkdir -p $T

outcome=0
ok() { echo "ok $1"; }
ng() { echo "ng $1"; outcome=1; }
# chkcontain <name> <pattern> <file>: 期望**有**
chkcontain() {
    if grep -q "$2" "$3"; then ok "$1"; else ng "$1"; fi
}
# chkempty <name> <pattern> <file>: 期望**没有**
chkempty() {
    if grep -q "$2" "$3"; then ng "$1"; else ok "$1"; fi
}

# 会话: MARK1 之前一切正常 -> 打了一半按 ^C(那半截作废) -> 紧跟 ^C 的两条外部命令
# (回归点: 都必须跑出结果) -> MARK2 之后再来一次空行 ^C -> 收尾。
# \3 是真正的 0x03 字节(printf 生成), 不是两个字面字符。
printf 'echo MARK1\nbasename /a/one\nbasename /a/two\3\nbasename /a/three\nbasename /a/four\necho MARK2\n\3\necho MARK3\n' > $T/in.sh

DELIN_HARNESS_TTY=1 lua5.1 tools/harness.lua /bin/sh < $T/in.sh > $T/out 2>&1
rc=$?
sed -n '1,40p' $T/out

eq_rc() { if [ "$2" = "$3" ]; then ok "$1"; else ng "$1 (got $2)"; fi }
eq_rc "exit-code" "$rc" "0"
chkcontain "before-intr-runs"      "one"   $T/out
chkcontain "intr-cancels-line"      "MARK2" $T/out
chkempty   "cancelled-line-not-run" "two"   $T/out
# 回归: ^C 之后的第一条外部命令必须真的执行(曾经被残留的 SIGINT 杀掉, 什么都不输出)
chkcontain "cmd-after-intr-runs"    "three" $T/out
chkcontain "cmd-after-that-runs"    "four"  $T/out
chkcontain "after-intr-still-alive" "MARK3" $T/out

# 提示符计数: 每读一行一次(readLine 返回空行也算), 末尾 EOF 前还有一次。
# 输入 8 行 + EOF 前那一次 -> 9 个提示符; 少一个就说明有行没被消费(或被多消费)。
n=$(grep -o 'root@delin-host:/#' $T/out | wc -l)
eq_rc "prompt-count" "$n" "9"

# ---------------------------------------------------------------
# 第二段: PS2 续行下按 ^C 必须取消**整条**输入(真实 bash/dash/zsh 同此)。
# 曾经的 bug: ^C 只丢掉当前这一行, 于是 `echo "abc` 之后按 ^C 又出一个 PS2(退不出去),
# 而之后打的每一行都被并进那条没闭合的引号里, 直到 EOF 才报 unexpected end of file。
# ---------------------------------------------------------------
printf 'echo "abc\n\003\necho PS2OK\n' > $T/in2.sh
DELIN_HARNESS_TTY=1 lua5.1 tools/harness.lua /bin/sh < $T/in2.sh > $T/out2 2>&1
rc2=$?
sed -n '1,20p' $T/out2
eq_rc      "ps2-intr-exit-code"    "$rc2" "0"
chkcontain "ps2-intr-next-runs"    "PS2OK" $T/out2
chkempty   "ps2-intr-no-syntaxerr" "syntax error" $T/out2
# 取消后回 PS1(只有一个 PS2 提示符: 第一行不完整那一次)
n2=$(grep -o '> ' $T/out2 | wc -l)
eq_rc      "ps2-intr-one-continuation" "$n2" "1"

if [ $outcome -eq 0 ]; then echo "sh_intr_test: all ok"; else echo "sh_intr_test: FAILED"; fi
exit $outcome
