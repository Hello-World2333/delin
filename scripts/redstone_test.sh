#!/bin/sh
# Delin redstone.ko 自检: /sys/class/redstone/<side>/{input,output,analog_input,analog_output,
# bundled_input,bundled_output} 的读写与校验语义。
# 可移植 POSIX sh; 两处各跑一次并要求输出一致:
#   宿主: lua5.1 tools/harness.lua /bin/sh < scripts/redstone_test.sh
#   真机: 由 realmachine_verify.sh 调用(sh /root/redstone_test.sh >> $LOG)
# 输出 "ok <name>" / "ng <name>", 全 ok 退出码 0。
# 注意: 真机的红石输入随世界变化, 因此输入属性只断言格式(0|1 / 0..15 / 掩码), 不断言数值;
#       输出属性由本机自己写, 读回值确定。不打印任何每次运行都不同的值。
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
R=/sys/class/redstone

# ---------------------------------------------------------------
# 1. 目录结构: 六个面, 每个面六个属性
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
for a in input output analog_input analog_output bundled_input bundled_output; do
    chk "attr_${a}_file" [ -f $R/back/$a ]
done

# ---------------------------------------------------------------
# 2. 读: 六个面的 input 都是 0|1(真机随世界变化, 只查格式)
# ---------------------------------------------------------------
for s in back bottom front left right top; do
    cat $R/$s/input > $T/in
    chkcontain "read_input_$s" '^[01]$' $T/in
done
cat $R/back/analog_input > $T/ai
chkcontain read_analog_input '^[0-9][0-9]*$' $T/ai
cat $R/back/bundled_input > $T/bi
chkcontain read_bundled_input '^[0-9][0-9]*$' $T/bi
cat $R/back/output > $T/out0
chkcontain read_output '^[01]$' $T/out0

# ---------------------------------------------------------------
# 3. 写 output / analog_output / bundled_output 并读回
# ---------------------------------------------------------------
echo 1 > $R/back/output
cat $R/back/output > $T/o
chkeq write_output_1 1 $T/o
cat $R/back/analog_output > $T/ao
chkeq write_output_1_analog 15 $T/ao

echo 0 > $R/back/output
cat $R/back/output > $T/o
chkeq write_output_0 0 $T/o
cat $R/back/analog_output > $T/ao
chkeq write_output_0_analog 0 $T/ao

echo 7 > $R/back/analog_output
cat $R/back/analog_output > $T/ao
chkeq write_analog_7 7 $T/ao
cat $R/back/output > $T/o
chkeq analog_7_output_on 1 $T/o

echo 15 > $R/back/analog_output
cat $R/back/analog_output > $T/ao
chkeq write_analog_15 15 $T/ao

echo 0 > $R/back/analog_output
cat $R/back/output > $T/o
chkeq analog_0_output_off 0 $T/o

echo 32768 > $R/back/bundled_output
cat $R/back/bundled_output > $T/bo
chkeq write_bundled_black 32768 $T/bo
echo 1 > $R/back/bundled_output
cat $R/back/bundled_output > $T/bo
chkeq write_bundled_white 1 $T/bo
echo 0 > $R/back/bundled_output
cat $R/back/bundled_output > $T/bo
chkeq write_bundled_0 0 $T/bo

# ---------------------------------------------------------------
# 4. 非法写入: fail-fast(非 0 退出码), 且不改动已有输出状态
# ---------------------------------------------------------------
chknegw reject_analog_16     sh -c "echo 16 > $R/back/analog_output"
chknegw reject_analog_abc    sh -c "echo abc > $R/back/analog_output"
chknegw reject_analog_hex    sh -c "echo 0x10 > $R/back/analog_output"
chknegw reject_analog_float  sh -c "echo 1.5 > $R/back/analog_output"
chknegw reject_output_2      sh -c "echo 2 > $R/back/output"
chknegw reject_output_neg    sh -c "echo -1 > $R/back/output"
chknegw reject_bundled_65536 sh -c "echo 65536 > $R/back/bundled_output"
chknegw reject_input_write   sh -c "echo 1 > $R/back/input"
chknegw reject_nosuch_attr   sh -c "echo 1 > $R/back/nosuch"

echo 5 > $R/back/analog_output
sh -c "echo 16 > $R/back/analog_output" > $T/err
cat $R/back/analog_output > $T/ao
chkeq invalid_write_keeps_state 5 $T/ao
chkcontain invalid_msg 'invalid' $T/err

# ---------------------------------------------------------------
# 5. 不存在的面/属性; 收尾复位
# ---------------------------------------------------------------
chkneg no_side_middle [ -e $R/middle ]
chkneg no_attr_nosuch [ -e $R/back/nosuch ]
chknegw no_write_nosuch_side sh -c "echo 1 > $R/middle/output"

echo 0 > $R/back/analog_output
echo 0 > $R/back/bundled_output
cat $R/back/analog_output > $T/ao
chkeq cleanup_analog 0 $T/ao
cat $R/back/bundled_output > $T/bo
chkeq cleanup_bundled 0 $T/bo

rm -rf $T
if [ "$outcome" = "0" ]; then echo "=== redstone test: all ok ==="; else echo "=== redstone test: FAILED ==="; fi
exit $outcome
