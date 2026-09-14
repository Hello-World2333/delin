#!/bin/sh
# Delin desh 自检(非交互部分): desh 与 sh 共用同一份核心, 所以"脚本/`-c` 的行为"必须逐项一致。
# 输出 "ok <name>" / "ng <name>"; 全部 ok 退出码 0。
# 用法(宿主): lua5.1 tools/harness.lua /bin/sh < scripts/desh_test.sh
# 用法(真机): sh /root/desh_test.sh
# 交互式那部分(按键 -> 屏幕)在宿主上用假终端测: scripts/desh_tty_test.sh。
# 注意: 不依赖 grep 的退出码, 用"输出里有没有这段文本"判定(与其他自检脚本同一约定)。

T=/tmp/desh_test
outcome=0
ok() { echo "ok $1"; }
ng() { echo "ng $1"; outcome=1; }

rm -rf $T
mkdir -p $T

# has <名字> <期望子串> <实际文本>
has() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) ng "$1"; echo "    expected to contain [$2] got [$3]" ;;
    esac
}
# lacks <名字> <不该出现的子串> <实际文本>
lacks() {
    case "$3" in
        *"$2"*) ng "$1"; echo "    expected NOT to contain [$2] got [$3]" ;;
        *) ok "$1" ;;
    esac
}
# eq <名字> <期望> <实际>
eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else ng "$1"; echo "    expected [$2] got [$3]"; fi
}

# ---------------------------------------------------------------
# 0. 装载探测: desh 起不来的话, 先让**装载错误**现形。
#    内核 process.spawn 失败时把消息放在第 3 个返回值上, 而 shell 早期版本只取第 2 个,
#    真机上只看得到 `sh: desh: nil`(真正的原因被吞掉)。这里用 /bin/lua 直接 loadfile 一次,
#    与内核同一条装载路径 —— 语法/编译器层面的问题会在这里现形而不是"沉默的 nil"。
# ---------------------------------------------------------------
printf 'local f, e = loadfile("/bin/desh")\nprint(f and "desh-load-ok" or ("desh-load-err: " .. tostring(e)))\n' > $T/loadprobe.lua
probe=$(lua $T/loadprobe.lua)
has  load_probe "desh-load-ok" "$probe"

# ---------------------------------------------------------------
# 1. -c 的行为与 sh 一致(核心共用)
# ---------------------------------------------------------------
eq  c_echo "hi" "$(desh -c 'echo hi')"
eq  c_arith "15" "$(desh -c 'x=5; echo $((x*3))')"
eq  c_loop "a
b" "$(desh -c 'for i in a b; do echo "$i"; done')"
eq  c_pipe "A" "$(desh -c 'echo a | tr a-z A-Z')"
eq  c_fn "fn-ok" "$(desh -c 'f() { echo fn-ok; }; f')"
eq  c_name "myname" "$(desh -c 'echo $0' myname)"
eq  c_arg "arg1" "$(desh -c 'echo $1' myname arg1)"
eq  c_cd "/tmp" "$(desh -c 'cd /tmp && pwd')"
mkdir -p $T/glob
touch $T/glob/a.txt $T/glob/b.txt
cd $T/glob
eq  c_glob "a.txt b.txt" "$(desh -c 'echo *.txt')"
cd /

# 退出码: 与 sh 同一套(dash/bash 的约定)
desh -c 'exit 7'
eq  rc_exit7 "7" "$?"
desh -c 'true'
eq  rc_true "0" "$?"
desh -c 'false'
eq  rc_false "1" "$?"

# 命令找不到: 127 + 前缀是 desh(而不是 sh) + **非交互下不给纠错建议**
out=$(desh -c 'nosuchcmd123')
has   notfound_msg "desh: nosuchcmd123: command not found" "$out"
lacks notfound_suggest "did you mean" "$out"
desh -c 'nosuchcmd123' > /dev/null
eq  notfound_rc "127" "$?"

# 纠错: 交互式是 zsh 的 `correct 'x' to 'y' [nyae]?` 提问; **非交互不提问**(读不到键盘),
# 只回一句 did-you-mean, 而且排在 command not found **之后**(顺序与从前一致)。
out=$(desh -c 'echp hi')
has notfound_hint_err  "desh: echp: command not found" "$out"
has notfound_hint_line "desh: did you mean 'echo'?" "$out"
lacks notfound_hint_prompt "correct '" "$out"

# 语法错误: 非交互 shell 以 2 退出
out=$(desh -c 'if true; then')
eq  syntax_rc "2" "$?"
has syntax_msg "syntax error" "$out"

# ---------------------------------------------------------------
# 2. 脚本模式(与 sh 相同: 位置参数/shebang)
# ---------------------------------------------------------------
printf 'echo zero=$0 one=$1\n' > $T/s.sh
eq  script_args "zero=$T/s.sh one=foo" "$(desh $T/s.sh foo)"

printf '#!/bin/sh\necho shebang-ran\n' > $T/h.sh
chmod 755 $T/h.sh
out=$($T/h.sh)
eq  script_shebang "shebang-ran" "$out"

# 从 stdin 读脚本(管道输入 = 非交互)
eq  stdin_script "from-stdin" "$(echo 'echo from-stdin' | desh)"

# ---------------------------------------------------------------
# 3. desh 自己的东西: help 说明交互层能力
# ---------------------------------------------------------------
out=$(desh -c 'help')
has help_title "Delin desh" "$out"
has help_tab "Tab completes" "$out"
has help_hist "^R incremental search" "$out"

# ---------------------------------------------------------------
# 4. 非交互不该碰终端/历史文件
# ---------------------------------------------------------------
hist="${HOME:-/root}/.desh_history"
rm -f "$hist"
desh -c 'echo quiet' > /dev/null
if [ -e "$hist" ]; then ng hist_not_written; else ok hist_not_written; fi

# ---------------------------------------------------------------
# 5. 交互式判定: stdin 不是终端时 desh 不进入行编辑器(走的是核心的经典路径)
#    —— 由上面第 2 节的 stdin_script 覆盖(它在管道里跑脚本而不是开编辑器)。
# ---------------------------------------------------------------

echo "desh_test done (outcome=$outcome)"
exit $outcome
