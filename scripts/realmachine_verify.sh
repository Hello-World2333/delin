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
echo "-- lsblk (sda 必须是电脑自带存储, 磁盘驱动器从 sdb 起) --" >> $LOG
lsblk >> $LOG
echo "-- blkid --" >> $LOG
blkid >> $LOG
echo "-- 电脑自带存储是块设备: mount -t ccdisk /dev/sda /mnt/hdd 要能看到电脑自身 FS --" >> $LOG
mkdir -p /mnt/hdd
mount -t ccdisk /dev/sda /mnt/hdd >> $LOG
ls /mnt/hdd >> $LOG
if ls /mnt/hdd | grep -q '^main.lua$'; then echo "ok own_storage_is_block_device" >> $LOG; else echo "ng own_storage_is_block_device" >> $LOG; fi
grep /mnt/hdd /proc/mounts >> $LOG
umount /mnt/hdd >> $LOG
echo "-- /etc/fstab --" >> $LOG
cat /etc/fstab >> $LOG
echo "-- /mnt/data (fstab 自动挂载) --" >> $LOG
ls /mnt/data >> $LOG
cat /mnt/data/hello.txt >> $LOG
echo "-- mount -a (noauto 不应挂载 /mnt/rootcopy) --" >> $LOG
mount -a >> $LOG
mount >> $LOG
echo "-- 手动挂载 noauto 条目 --" >> $LOG
mount /dev/sdb1 /mnt/rootcopy >> $LOG
ls /mnt/rootcopy >> $LOG
umount /mnt/rootcopy >> $LOG
echo "-- 按 UUID 挂载(命名空间前缀: 磁盘 d<磁盘ID>, 自带存储 c<电脑ID>) --" >> $LOG
mount UUID=d0-1 /mnt/rootcopy >> $LOG
grep /mnt/rootcopy /proc/mounts >> $LOG
umount /mnt/rootcopy >> $LOG
echo "-- 裸数字 UUID 必须被拒(磁盘 ID 与电脑 ID 会撞号) --" >> $LOG
mount UUID=0 /mnt/rootcopy >> $LOG
if [ "$?" != "0" ]; then echo "ok bare_number_uuid_rejected" >> $LOG; else echo "ng bare_number_uuid_rejected" >> $LOG; fi
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
echo "-- 随机数设备: /dev/zero /dev/urandom /dev/random --" >> $LOG
ls /dev >> $LOG
echo -n "zero8=" >> $LOG
dd status=none if=/dev/zero bs=8 count=1 | od -An -v -tx1 >> $LOG
echo -n "urandom16=" >> $LOG
dd status=none if=/dev/urandom bs=16 count=1 | od -An -v -tx1 >> $LOG
dd status=none if=/dev/urandom bs=32 count=1 of=/tmp/rnd1
dd status=none if=/dev/urandom bs=32 count=1 of=/tmp/rnd2
if [ "$(wc -c < /tmp/rnd1)" = "32" ]; then echo "ok urandom_read_32_bytes" >> $LOG; else echo "ng urandom_read_32_bytes" >> $LOG; fi
if cmp -s /tmp/rnd1 /tmp/rnd2; then echo "ng urandom_two_reads_differ" >> $LOG; else echo "ok urandom_two_reads_differ" >> $LOG; fi
echo "-- /dev/random: CRNG 就绪后直接可读(未就绪时会阻塞, 见 init 日志的 crng 那行) --" >> $LOG
dd status=none if=/dev/random bs=16 count=1 of=/tmp/rndr
if [ "$(wc -c < /tmp/rndr)" = "16" ]; then echo "ok devrandom_read_16_bytes" >> $LOG; else echo "ng devrandom_read_16_bytes" >> $LOG; fi
echo "-- /proc/sys/kernel/random --" >> $LOG
cat /proc/sys/kernel/random/poolsize >> $LOG
cat /proc/sys/kernel/random/entropy_avail >> $LOG
cat /proc/sys/kernel/random/uuid >> $LOG
cat /proc/sys/kernel/random/uuid > /tmp/u1
cat /proc/sys/kernel/random/uuid > /tmp/u2
if cmp -s /tmp/u1 /tmp/u2; then echo "ng uuid_each_read_differs" >> $LOG; else echo "ok uuid_each_read_differs" >> $LOG; fi
grep '%x%x%x%x%x%x%x%x%-%x%x%x%x%-4' /tmp/u1 > /tmp/uuidhit
if [ -s /tmp/uuidhit ]; then echo "ok uuid_v4_format" >> $LOG; else echo "ng uuid_v4_format" >> $LOG; fi
# 内核那句 "random: crng init done" 要经 syslogd 落到 /var/log/kern.log。
# 注意本脚本前面的 logrotate 段已经把 kern.log 轮转过一次(所以也查 .1)。
grep 'crng init done' /var/log/kern.log /var/log/kern.log.1 > /tmp/crnghit
if [ -s /tmp/crnghit ]; then echo "ok crng_init_done_logged" >> $LOG; else echo "ng crng_init_done_logged" >> $LOG; fi
echo "-- 块设备节点当字节流读: cat 必须逐字节输出镜像 --" >> $LOG
# 曾经的 bug: `cat /dev/sdbN` 报 "bad argument #1 (boolean expected, got table)" —— 内核
# devdisk 的句柄包装把**句柄自己**当成 withTrailing 传给了 CC 的 handle.readLine
# (CC 的 readLine 第一个参数是 boolean)。
# /dev/sdb2 = 磁盘 0 的 data 分区(/parts/data.img): 本机只读它, 不会改写, 所以宿主在取回
# 日志后对同一个文件跑 POSIX cksum, 必须与下面这行逐字节一致(门禁在 tools/realmachine.py)。
echo -n "cat_dev2_cksum=" >> $LOG
cat /dev/sdb2 | cksum >> $LOG
cat /dev/sdb1 > /dev/null
if [ "$?" = "0" ]; then echo "ok cat_blockdev_root_part" >> $LOG; else echo "ng cat_blockdev_root_part" >> $LOG; fi
# cat 默认模式按**字节**拷贝: 含 \r、末行没有换行时必须逐字节相同
# (曾经一律走 readLine: \r 被丢掉、末行被补一个 \n —— 对块设备/二进制就是数据损坏)。
printf 'A\r\nB' > /tmp/catbin
cat /tmp/catbin > /tmp/catbin.out
if cmp -s /tmp/catbin /tmp/catbin.out; then echo "ok cat_binary_exact" >> $LOG; else echo "ng cat_binary_exact" >> $LOG; fi
echo -n "cat_bin_A_output=" >> $LOG
cat -A /tmp/catbin >> $LOG
echo "-- dd 能被 SIGINT(^C) 中断: 拷贝循环必须让出调度器 --" >> $LOG
# 不让出的话信号永远投不进来(信号只在 resume 前投递) —— 真机上表现为 ^C 完全无效(本次修的 bug)。
# 注意: Delin 的 `&` 是"起一个子 shell 跑这条命令"(无 fork), 所以 $! 是那个**子 shell** 的 pid,
# 朝它发 SIGINT 只会杀掉子 shell、dd 变成孤儿继续跑; 而真机 ^C 是 tty 把 SIGINT 投给**前台
# 进程组**(dd 自己在内)。所以这里按进程名直接给 dd 发信号 —— 与 ^C 打中的是同一个进程。
# dd 退出码经子 shell 传出来(status 会等于 130)。
dd status=none if=/dev/zero of=/dev/null bs=512 &
ddjob=$!
sleep 1
pkill -INT -x dd
sleep 1
pgrep -x dd > /tmp/ddstills
if [ -s /tmp/ddstills ]; then echo "ng dd_sigint_interrupt" >> $LOG; pkill -KILL -x dd; else echo "ok dd_sigint_interrupt" >> $LOG; fi
wait $ddjob
echo "dd_sigint_rc=$?" >> $LOG
pkill -KILL -x dd > /dev/null
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
