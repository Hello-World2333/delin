#!/bin/sh
# Delin redstone.ko 自检: /sys/class/redstone/<side>/{digital,analog,bundled} —— 每个面三个属性,
# 一个红石量一个文件, 读 = 该面输入, 写 = 该面输出。
# 可移植 POSIX sh; 两处各跑一次并要求输出一致:
#   宿主: lua5.1 tools/harness.lua /bin/sh < scripts/redstone_test.sh
#   真机: 由 realmachine_verify.sh 调用(sh /root/redstone_test.sh >> $LOG)
# 输出 "ok <name>" / "ng <name>", 全 ok 退出码 0。
# 注意: 真机的红石输入随世界变化, 因此读只断言格式/范围, 不断言数值。
#       写是否生效不能靠 cat 读回(读的是输入, 不是自己驱动的输出), 改由 CC 原始 redstone API
#       读回确认 —— 宿主 harness 的桩 API 与真机真 API 语义一致, 故两边输出仍然相同。
#       不打印任何每次运行都不同的值。
#       非法写入的错误消息走 stderr(与 stdout 同一流), 故用 > $T/err 收走, 免得污染比对输出。

T=/tmp/redstonetest
outcome=0
rm -rf $T
mkdir -p $T

ok() { echo "ok $1"; }
ng() { echo "ng $1"; outcome=1; }
chk() { # 命令退出码 0 即通过
    _n="$1"; shift
    "$@"
    if [ "$?" = "0" ]; then ok "$_n"; else ng "$_n"; fi
}
chkneg() { # 命令退出码非 0 即通过
    _n="$1"; shift
    "$@"
    if [ "$?" != "0" ]; then ok "$_n"; else ng "$_n"; fi
}
chknegw() { # 同上, 但把命令输出(错误消息)收进 $T/err
    _n="$1"; shift
    "$@" > $T/err
    if [ "$?" != "0" ]; then ok "$_n"; else ng "$_n"; fi
}
chkcontain() { # chkcontain <name> <pattern> <file>
    grep "$2" "$3" > $T/grepout
    if [ -s $T/grepout ]; then ok "$1"; else ng "$1"; fi
}
chkeq() { # chkeq <name> <expected> <file>: 文件内容整行等于期望值
    grep "^$2\$" "$3" > $T/grepout
    if [ -s $T/grepout ]; then ok "$1"; else ng "$1"; fi
}
inrange() { # inrange <name> <file> <min> <max>: 文件内容(十进制整数)在闭区间内(非数字即 ng)
    _n="$1"; read _v < "$2"
    if [ "$_v" -ge "$3" ] && [ "$_v" -le "$4" ]; then ok "$_n"; else ng "$_n"; fi
}
apiget() { # apiget <lua 表达式>: 经 CC 原始 redstone API 读回(结果进 $T/api)
    # 不写 2>: Delin sh 的 stderr 重定向与 stdout 同一流(lua 出错时错误消息落在 $T/api 里,
    # 据此判定 ng —— 见本文件顶部说明)。
    echo "print($1)" > $T/probe.lua
    lua $T/probe.lua > $T/api
}
apichk() { # apichk <name> <lua 表达式> <期望值>
    apiget "$2"
    chkeq "$1" "$3" $T/api
}
apieqfile() { # apieqfile <name> <lua 表达式> <file>: API 值 == 属性文件内容(证明读的是输入)
    apiget "$2"
    read _a < $T/api
    read _b < "$3"
    if [ "$_a" = "$_b" ]; then ok "$1"; else ng "$1"; fi
}
R=/sys/class/redstone

# ---------------------------------------------------------------
# 1. 目录结构: 六个面, 每个面三个属性
# ---------------------------------------------------------------
chk redstone_is_dir [ -d $R ]
ls $R > $T/sides
wc -l < $T/sides > $T/n
chkcontain six_sides '^6$' $T/n
ls /sys/class > $T/classes
chkcontain class_has_redstone '^redstone/$' $T/classes
for s in back bottom front left right top; do
    chk "side_${s}_dir" [ -d $R/$s ]
done
for a in digital analog bundled; do
    chk "attr_${a}_file" [ -f $R/back/$a ]
done
ls $R/back > $T/attrs
wc -l < $T/attrs > $T/n
chkcontain three_attrs_per_side '^3$' $T/n
# 旧的 input/output 变体已删除
chkneg old_attr_input_gone [ -e $R/back/input ]
chkneg old_attr_output_gone [ -e $R/back/output ]
chkneg old_attr_analog_input_gone [ -e $R/back/analog_input ]
chkneg old_attr_bundled_output_gone [ -e $R/back/bundled_output ]

# ---------------------------------------------------------------
# 2. 读 = 输入: 六个面的 digital 是 0|1, analog 是 0..15, bundled 是 0..65535
# ---------------------------------------------------------------
for s in back bottom front left right top; do
    cat $R/$s/digital > $T/in
    chkcontain "read_digital_$s" '^[01]$' $T/in
done
for s in back bottom front left right top; do
    cat $R/$s/analog > $T/ai
    inrange "read_analog_$s" $T/ai 0 15
    cat $R/$s/bundled > $T/bi
    inrange "read_bundled_$s" $T/bi 0 65535
done
# 读的值就是 API 的 *Input(不是本机自己的输出)
cat $R/back/digital > $T/f
apieqfile read_digital_is_input "redstone.getInput('back') and 1 or 0" $T/f
cat $R/back/analog > $T/f
apieqfile read_analog_is_input "redstone.getAnalogInput('back')" $T/f
cat $R/back/bundled > $T/f
apieqfile read_bundled_is_input "redstone.getBundledInput('back')" $T/f

# ---------------------------------------------------------------
# 3. 写 = 输出: 三个属性都可写, 写后由 CC API 读回确认(文件读的是输入, 读不回输出)
# ---------------------------------------------------------------
chk write_digital_1 sh -c "echo 1 > $R/back/digital"
apichk write_digital_1_api "redstone.getOutput('back')" true
apichk write_digital_1_analog "redstone.getAnalogOutput('back')" 15

chk write_digital_0 sh -c "echo 0 > $R/back/digital"
apichk write_digital_0_api "redstone.getOutput('back')" false
apichk write_digital_0_analog "redstone.getAnalogOutput('back')" 0

chk write_analog_7 sh -c "echo 7 > $R/back/analog"
apichk write_analog_7_api "redstone.getAnalogOutput('back')" 7
apichk analog_7_output_on "redstone.getOutput('back')" true

chk write_analog_15 sh -c "echo 15 > $R/back/analog"
apichk write_analog_15_api "redstone.getAnalogOutput('back')" 15

chk write_analog_0 sh -c "echo 0 > $R/back/analog"
apichk analog_0_output_off "redstone.getOutput('back')" false

chk write_bundled_black sh -c "echo 32768 > $R/back/bundled"
apichk write_bundled_black_api "redstone.getBundledOutput('back')" 32768

chk write_bundled_white sh -c "echo 1 > $R/back/bundled"
apichk write_bundled_white_api "redstone.getBundledOutput('back')" 1
chk write_bundled_0 sh -c "echo 0 > $R/back/bundled"
apichk write_bundled_0_api "redstone.getBundledOutput('back')" 0

# 写数字端面: 别的面不受影响
chk write_left_digital sh -c "echo 1 > $R/left/digital"
apichk write_left_digital_api "redstone.getOutput('left')" true
apichk back_untouched_by_left "redstone.getOutput('back')" false
sh -c "echo 0 > $R/left/digital"

# ---------------------------------------------------------------
# 4. 非法写入: fail-fast(非 0 退出码), 且不改动已有输出状态
# ---------------------------------------------------------------
chknegw reject_analog_16     sh -c "echo 16 > $R/back/analog"
chknegw reject_analog_abc    sh -c "echo abc > $R/back/analog"
chknegw reject_analog_hex    sh -c "echo 0x10 > $R/back/analog"
chknegw reject_analog_float  sh -c "echo 1.5 > $R/back/analog"
chknegw reject_digital_2     sh -c "echo 2 > $R/back/digital"
chknegw reject_digital_neg   sh -c "echo -1 > $R/back/digital"
chknegw reject_bundled_65536 sh -c "echo 65536 > $R/back/bundled"
chknegw reject_nosuch_attr   sh -c "echo 1 > $R/back/nosuch"

echo 5 > $R/back/analog
sh -c "echo 16 > $R/back/analog" > $T/err
apichk invalid_write_keeps_state "redstone.getAnalogOutput('back')" 5
chkcontain invalid_msg 'invalid' $T/err

# ---------------------------------------------------------------
# 5. 不存在的面/属性; 收尾复位
# ---------------------------------------------------------------
chkneg no_side_middle [ -e $R/middle ]
chkneg no_attr_nosuch [ -e $R/back/nosuch ]
chknegw no_write_nosuch_side sh -c "echo 1 > $R/middle/digital"

echo 0 > $R/back/analog
echo 0 > $R/back/bundled
apichk cleanup_analog "redstone.getAnalogOutput('back')" 0
apichk cleanup_bundled "redstone.getBundledOutput('back')" 0

rm -rf $T
if [ "$outcome" = "0" ]; then echo "=== redstone test: all ok ==="; else echo "=== redstone test: FAILED ==="; fi
exit $outcome
