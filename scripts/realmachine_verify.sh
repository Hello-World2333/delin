#!/bin/sh
# Delin 真机验证脚本 —— 由 verify.service(oneshot)在启动时运行, 结果写 /var/log/verify.log。
# 覆盖: systemd-like init 的服务/依赖序、systemctl 控制、fstab 自动挂载、mount -a/noauto、
#       syslogd 规则落盘、logger、dmesg、logrotate 轮转 + SIGHUP 重开、
#       sysfs 属性读取(cat 必须单行, 曾经的 bug: 无 EOF 导致无限重复)。
# 用法(仅测试用): 部署时把本脚本放进 /root/, 并启用 verify.service; 宿主机读回 /var/log/verify.log。
LOG=/var/log/verify.log
echo "=== Delin real-machine verify ===" > $LOG
echo "-- sysfs /sys/class/display --" >> $LOG
ls /sys/class/display >> $LOG
# cat 一个属性文件必须只输出一行(曾经的 bug: 属性句柄无 EOF, 无限重复当前值)。
cat /sys/class/display/back/name >> $LOG
cat /sys/class/display/back/type >> $LOG
cat /sys/class/display/back/size >> $LOG
cat /sys/class/display/right/name >> $LOG
cat /sys/class/display/right/size >> $LOG
cat /sys/class/display/term/name >> $LOG
echo "sysfs: done" >> $LOG
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
echo "-- ANSI 终端能力: TERM / echo -e / clear --" >> $LOG
echo "TERM=$TERM" >> $LOG
sh -c 'echo "TERM_child=$TERM"' >> $LOG
echo -e 'a\eb' > /tmp/ansi_esc
wc -c < /tmp/ansi_esc >> $LOG
grep '%c' /tmp/ansi_esc > /tmp/ansi_hit
if [ -s /tmp/ansi_hit ]; then echo "echo_e_esc=ok" >> $LOG; else echo "echo_e_esc=ng" >> $LOG; fi
clear > /tmp/clear_out
wc -c < /tmp/clear_out >> $LOG
grep '%c' /tmp/clear_out > /tmp/clear_hit
if [ -s /tmp/clear_hit ]; then echo "clear_esc=ok" >> $LOG; else echo "clear_esc=ng" >> $LOG; fi
echo "-- procfs /proc --" >> $LOG
ls /proc >> $LOG
cat /proc/version >> $LOG
cat /proc/uptime >> $LOG
cat /proc/mounts >> $LOG
cat /proc/1/stat >> $LOG
cat /proc/1/status >> $LOG
cat /proc/self/comm >> $LOG
echo "-- ps --" >> $LOG
ps -e >> $LOG
ps -ef >> $LOG
ps aux >> $LOG
ps -e -o pid,ppid,user,group,stat,tty,comm,cmd >> $LOG
echo "-- proc_test.sh (/proc + ps/pgrep/pkill/killall 自检) --" >> $LOG
sh /root/proc_test.sh >> $LOG
echo "-- redstone_test.sh (/sys/class/redstone 读写/校验自检) --" >> $LOG
sh /root/redstone_test.sh >> $LOG
echo "-- lua_test.sh (/bin/lua 脚本/stdin/arg/dofile/退出码 + 进程环境白名单自检) --" >> $LOG
sh /root/lua_test.sh >> $LOG
# chmod 的符号模式与执行位(根映像只有 256 个 inode, 这里只用 3 个文件, 不能整跑 posix_test.sh)
echo "-- chmod 模式(-x/-R -x) 与执行位(root 也要 x 位) --" >> $LOG
CD=/tmp/chmodchk
rm -rf $CD
mkdir -p $CD/d
echo '#!/bin/sh' > $CD/x.sh
echo 'echo SHOK' >> $CD/x.sh
echo 'echo INNER' >> $CD/d/f.sh
chmod 755 $CD/x.sh $CD/d/f.sh
$CD/x.sh >> $LOG
echo "chmod755_run_exit=$?" >> $LOG
chmod -x $CD/x.sh
ls -l $CD/x.sh >> $LOG
$CD/x.sh > /dev/null
if [ "$?" = "126" ]; then echo "ok chmod_noexec_126" >> $LOG; else echo "ng chmod_noexec_126" >> $LOG; fi
chmod +x $CD/x.sh
$CD/x.sh >> $LOG
echo "chmod_plus_x_run_exit=$?" >> $LOG
chmod 755 $CD/d/f.sh
chmod -R -x $CD/d
ls -l $CD/d/f.sh >> $LOG
chmod -x -w $CD/x.sh
ls -l $CD/x.sh >> $LOG
rm -rf $CD
echo "-- user_test.sh (用户管理: passwd/useradd/usermod/group*/id 自检) --" >> $LOG
sh /root/user_test.sh >> $LOG
echo "-- redstone_verify.lua (sysfs 与 CC 原始 redstone API 交叉核对) --" >> $LOG
/root/redstone_verify.lua
cat /var/log/redstone_verify.log >> $LOG
echo "=== verify done ===" >> $LOG
