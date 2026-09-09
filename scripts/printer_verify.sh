#!/bin/sh
# Delin 真机验证: ccprinter 内核模块(/dev/lp0 + /sys/class/printer/lp0)
#              + 内核 stdio 关闭语义(进程退出只关管道端, 不关父进程共享的重定向句柄)。
# 由 printer-verify.service(oneshot)在启动时运行, 结果写 /var/log/printer_verify.log;
# 宿主机用 tools/realmachine.py --printer 取回日志。
# 注意: 会实际打印页面 —— 正常路径 4 页(lp 1 + 重定向 1 + 跨页 2),
#       打印机出纸盘只有 6 格, 验证前请先取出盘里的纸。
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

echo "Delin printer test" > /root/print.txt
echo "line two" >> /root/print.txt
echo "line three" >> /root/print.txt

logger -t pv "A: lp -t file"
echo "-- A: lp -t title file (1 页) --" >> $LOG
lp -t "Delin Test" /root/print.txt >> $LOG
echo "rc=$?" >> $LOG
echo "-- size --" >> $LOG
cat /sys/class/printer/lp0/size >> $LOG
echo "-- title --" >> $LOG
cat /sys/class/printer/lp0/title >> $LOG
logger -t pv "A done"

logger -t pv "B: cat redirect"
echo "-- B: cat > /dev/lp0 (1 页) --" >> $LOG
cat /root/print.txt > /dev/lp0
echo "rc=$?" >> $LOG
logger -t pv "B done"

logger -t pv "C: 22 lines (2 页)"
echo "-- C: 22 行跨页 (21 行/页, 2 页) --" >> $LOG
rm -f /root/many.txt
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do
    echo "row $n" >> /root/many.txt
done
lp -t "Many" /root/many.txt
echo "rc=$?" >> $LOG
logger -t pv "C done"

echo "-- 错误路径: 非法选项应 rc=1 --" >> $LOG
lp -Z /root/print.txt >> $LOG
echo "rc=$?" >> $LOG
echo "-- 错误路径: 写只读属性应失败 --" >> $LOG
echo x > /sys/class/printer/lp0/paper
echo "rc=$?" >> $LOG

echo "-- paper after (应少 4) --" >> $LOG
cat /sys/class/printer/lp0/paper >> $LOG
echo "-- ink after (应少 4) --" >> $LOG
cat /sys/class/printer/lp0/ink >> $LOG

logger -t pv "D: pipes"
echo "-- D: 管道语义 (进程退出只关管道端) --" >> $LOG
cat /etc/passwd | wc -l >> $LOG
echo "pipe rc=$?" >> $LOG
cat /etc/passwd | wc -l | wc -l >> $LOG
echo "pipe2 rc=$?" >> $LOG
echo "-- D: posix_test --" >> $LOG
sh /root/posix_test.sh >> $LOG
echo "-- D: jobctl_test --" >> $LOG
sh /root/jobctl_test.sh >> $LOG
logger -t pv "D done"

echo "-- dmesg --" >> $LOG
dmesg >> $LOG
logger -t pv "ALL DONE"
echo "=== printer verify done ===" >> $LOG
