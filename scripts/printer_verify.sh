#!/bin/sh
# Delin 真机验证: ccprinter 内核模块(/dev/lp0 + /sys/class/printer/lp0)
#              + 内核 stdio 关闭语义(进程退出只关管道端, 不关父进程共享的重定向句柄)。
# 由 printer-verify.service(oneshot)在启动时运行, 结果写 /var/log/printer_verify.log;
# 宿主机用 tools/realmachine.py --printer 取回日志。
# 注意: 会实际打印页面 —— 正常路径 1 页; 打印内容专门覆盖排版: 每行都从第 1 列开始、
#       恰好占满页宽(25 列)的行后不跳行、超宽行折行。打印机出纸盘只有 6 格。
# logger 标记同时进 /var/log/messages, 便于在脚本卡住时定位卡在哪一步。
LOG=/var/log/printer_verify.log
echo "=== Delin printer verify ===" > $LOG
logger -t pv "START"

echo "-- /dev (应有 lp0) --" >> $LOG
ls /dev >> $LOG
echo "-- /sys/class --" >> $LOG
ls /sys/class >> $LOG
echo "-- /sys/class/printer --" >> $LOG
ls /sys/class/printer >> $LOG
echo "-- name/type/paper/ink --" >> $LOG
cat /sys/class/printer/lp0/name >> $LOG
cat /sys/class/printer/lp0/type >> $LOG
cat /sys/class/printer/lp0/paper >> $LOG
cat /sys/class/printer/lp0/ink >> $LOG

# 打印内容: 短行 / 恰好 25 列 / 25 列后紧跟一行 / 30 列折行 / 尾行
echo "Delin printer test" > /root/print.txt
echo "line two" >> /root/print.txt
echo "line three" >> /root/print.txt
echo "0123456789012345678901234" >> /root/print.txt
echo "after25" >> /root/print.txt
echo "0123456789012345678901234567890" >> /root/print.txt
echo "tail" >> /root/print.txt

logger -t pv "A: lp -t file (1 页)"
echo "-- A: lp -t title file (1 页, 检查排版) --" >> $LOG
lp -t "Delin Test" /root/print.txt >> $LOG
echo "rc=$?" >> $LOG
echo "-- size --" >> $LOG
cat /sys/class/printer/lp0/size >> $LOG
echo "-- title --" >> $LOG
cat /sys/class/printer/lp0/title >> $LOG
logger -t pv "A done"

echo "-- 错误路径: 非法选项应 rc=1 --" >> $LOG
lp -Z /root/print.txt >> $LOG
echo "rc=$?" >> $LOG
echo "-- 错误路径: 写只读属性应失败 --" >> $LOG
echo x > /sys/class/printer/lp0/paper
echo "rc=$?" >> $LOG

echo "-- paper after (应少 1) --" >> $LOG
cat /sys/class/printer/lp0/paper >> $LOG
echo "-- ink after (应少 1) --" >> $LOG
cat /sys/class/printer/lp0/ink >> $LOG

logger -t pv "B: pipes"
echo "-- B: 管道语义 (进程退出只关管道端) --" >> $LOG
cat /etc/passwd | wc -l >> $LOG
echo "pipe rc=$?" >> $LOG
cat /etc/passwd | wc -l | wc -l >> $LOG
echo "pipe2 rc=$?" >> $LOG
echo "-- B: posix_test --" >> $LOG
sh /root/posix_test.sh >> $LOG
echo "-- B: jobctl_test --" >> $LOG
sh /root/jobctl_test.sh >> $LOG
logger -t pv "B done"

echo "-- dmesg --" >> $LOG
dmesg >> $LOG
logger -t pv "ALL DONE"
echo "=== printer verify done ===" >> $LOG
