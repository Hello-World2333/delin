#!/bin/sh
# Delin 真机验证脚本 —— 由 verify.service(oneshot)在启动时运行, 结果写 /var/log/verify.log。
# 覆盖: systemd-like init 的服务/依赖序、systemctl 控制、fstab 自动挂载、mount -a/noauto、
#       syslogd 规则落盘、logger、dmesg、logrotate 轮转 + SIGHUP 重开。
# 用法(仅测试用): 部署时把本脚本放进 /root/, 并启用 verify.service; 宿主机读回 /var/log/verify.log。
LOG=/var/log/verify.log
echo "=== Delin real-machine verify ===" > $LOG
echo "-- systemctl list-units --" >> $LOG
systemctl list-units >> $LOG
echo "-- systemctl status syslogd.service --" >> $LOG
systemctl status syslogd.service >> $LOG
echo "-- is-active syslogd/getty@tty0 --" >> $LOG
systemctl is-active syslogd.service >> $LOG
systemctl is-active getty@tty0.service >> $LOG
echo "-- mount --" >> $LOG
mount >> $LOG
echo "-- lsblk --" >> $LOG
lsblk >> $LOG
echo "-- /etc/fstab --" >> $LOG
cat /etc/fstab >> $LOG
echo "-- /mnt/data (fstab 自动挂载) --" >> $LOG
ls /mnt/data >> $LOG
cat /mnt/data/hello.txt >> $LOG
echo "-- mount -a (noauto 不应挂载 /mnt/rootcopy) --" >> $LOG
mount -a >> $LOG
mount >> $LOG
echo "-- 手动挂载 noauto 条目 --" >> $LOG
mount /dev/sda1 /mnt/rootcopy >> $LOG
ls /mnt/rootcopy >> $LOG
umount /mnt/rootcopy >> $LOG
echo "-- logger -> /dev/log -> syslogd --" >> $LOG
logger -t verify -p daemon.notice "verify daemon message"
logger -t verify -p authpriv.warning "verify authpriv message"
echo "-- dmesg --" >> $LOG
dmesg >> $LOG
echo "-- logrotate: 先写满 /var/log/messages, 再轮转 --" >> $LOG
for x in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 do
    cat /etc/passwd >> /var/log/messages
done
logrotate -v /etc/logrotate.conf >> $LOG
echo "-- /var/log 内容(应有 messages.1) --" >> $LOG
ls /var/log >> $LOG
logger -t verify -p daemon.notice "after rotation"
echo "-- systemctl disable/enable --" >> $LOG
systemctl disable logrotate.timer >> $LOG
systemctl is-enabled logrotate.timer >> $LOG
systemctl enable logrotate.timer >> $LOG
systemctl is-enabled logrotate.timer >> $LOG
echo "-- systemctl restart syslogd --" >> $LOG
systemctl restart syslogd.service >> $LOG
sleep 2
systemctl is-active syslogd.service >> $LOG
echo "=== verify done ===" >> $LOG
