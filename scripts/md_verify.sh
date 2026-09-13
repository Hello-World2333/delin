#!/bin/sh
# Delin software RAID real-machine verification -- computer #6 (desktop CEECC, 10MB own storage).
#
# Run by mdtest.service (oneshot, TimeoutStartSec=600) on every boot. Two phases, chosen by the
# marker file /root/md-phase1.done:
#
#   phase 1 (first boot): build arrays over image files on the computer's own storage, format one
#     with mkfs.ext2, mount it, write a file, fail/remove/add a device, wait for the rebuild,
#     stop and re-assemble the array, and finally write /etc/mdadm.conf so the next boot can
#     assemble it automatically.
#   phase 2 (after the reboot): assert the arrays are ALREADY up at boot (assembled by
#     mdadm.service before local-fs.target), that the file written in phase 1 still reads back
#     with the same cksum, and that the superblocks are intact.
#
# The host side (tools/md_realmachine.py) reads /var/log/md.log back and checks every
# "ok <name>" / "ng <name>" line plus a few KEY=VALUE facts.
#
# NOTE: this file is installed on the CC computer, so it must stay pure ASCII.

LOG=/var/log/md.log
# RUNTOKEN 由宿主 tools/md_realmachine.py 在装机时替换成一个唯一串: 日志里带这行才说明读到的是
# **本轮**的结果(NFS 的属性/内容缓存会让宿主读到上一轮的日志, 只比 mtime 靠不住)。
RUNTOKEN=dev
MARK=/root/md-phase1.done
CKSUM=/root/md-cksum.txt
HELLO=/mnt/md/hello.txt
MNT=/mnt/md
A=a.img
B=b.img
C=c.img
D=d.img
E=e.img
F=f.img

# Record one check: ok/ng + name, so the host can count them without parsing prose.
check() {
    if [ "$1" = "0" ]; then echo "ok  $2" >> $LOG; else echo "ng  $2 (rc=$1)" >> $LOG; fi
}

if [ ! -f $MARK ]; then

echo "run-token=$RUNTOKEN" >> $LOG
echo "=== Delin md verify (phase 1: create/use/degrade/rebuild/assemble) ===" >> $LOG
mdadm --version >> $LOG
echo "-- /proc/mdstat before any array --" >> $LOG
cat /proc/mdstat >> $LOG
mkdir -p $MNT

echo "-- create member images on the computer's own storage --" >> $LOG
# 每个成员 256KB。先用 cp 建出文件再 dd 覆盖: 这是为 CCFS 根留的余量(cp 走 exists+open w),
# dd 的 of= 指向不存在的文件时依赖 fs.attributes 返回 nil —— 那条路在 CCFS 上曾经抛错,
# 内核里已经修好(vfs.real 的 attributes 现在统一成 nil), 这里只是不把测试押在一个刚修的地方。
mkimg() {
    cp /etc/passwd $1
    dd status=none if=/dev/zero of=$1 bs=1024 count=256
    check $? mkimg_$2
}
mkimg /parts/$A a
mkimg /parts/$B b
mkimg /parts/$C c
mkimg /parts/$D d
mkimg /parts/$E e
ls -l /parts >> $LOG

echo "-- mdadm --create /dev/md0 (raid5 over 3 members) --" >> $LOG
mdadm --create /dev/md0 --level=5 --raid-devices=3 --chunk=32 \
    /parts/$A /parts/$B /parts/$C >> $LOG
check $? create_raid5

echo "-- mdadm --create /dev/md1 (raid1 over 2 members) --" >> $LOG
mdadm --create /dev/md1 --level=1 --raid-devices=2 /parts/$D /parts/$E >> $LOG
check $? create_raid1

echo "-- /proc/mdstat (both arrays active) --" >> $LOG
cat /proc/mdstat >> $LOG
grep -q "^md0 : active raid5" /proc/mdstat; check $? mdstat_md0_raid5
grep -q "^md1 : active raid1" /proc/mdstat; check $? mdstat_md1_raid1
grep -q "\[3/3\] \[UUU\]" /proc/mdstat; check $? mdstat_md0_all_in_sync

echo "-- device nodes --" >> $LOG
ls -l /dev/md0 /dev/md1 >> $LOG
# 注意: Delin 的 ls 对不存在的路径**退出码是 0**(只有错误消息), 所以节点存在性不能靠 ls 的
# 退出码判 —— 用 blkid 的输出(它必须能按设备名反查到 UUID)。
# Delin 的 sh 只支持 > >> <(没有 fd 复制), 但进程的 stderr 与 stdout 本来就是同一个流
# (见 kernel/vfs_api.lua 的 io.stderr), 所以工具的错误消息照样会进日志。
blkid /dev/md0 > /tmp/md-blkid.txt
cat /tmp/md-blkid.txt >> $LOG
grep -q "UUID=" /tmp/md-blkid.txt; check $? dev_nodes
lsblk >> $LOG
grep -q "md0" /proc/mounts; if [ "$?" = "1" ]; then echo "ok  not_mounted_yet" >> $LOG; else echo "ng  not_mounted_yet" >> $LOG; fi

echo "-- mkfs.ext2 on the array, mount it, write a file --" >> $LOG
mkfs.ext2 -L MDTEST /dev/md0 >> $LOG
check $? mkfs_on_array
fsck.ext2 -n /dev/md0 >> $LOG
check $? fsck_clean
mount /dev/md0 $MNT >> $LOG
check $? mount_array
echo hello-from-raid5 > $HELLO
cksum $HELLO > $CKSUM
cat $HELLO >> $LOG
cat $CKSUM >> $LOG
umount $MNT
check $? umount_array

echo "-- degrade: fail + remove one member, data must still read --" >> $LOG
mdadm /dev/md0 --fail /parts/$B >> $LOG
check $? fail_member
mdadm /dev/md0 --remove /parts/$B >> $LOG
check $? remove_member
cat /proc/mdstat >> $LOG
grep -q "\[3/2\] \[U_U\]" /proc/mdstat; check $? mdstat_degraded
mount /dev/md0 $MNT >> $LOG
check $? mount_degraded
cksum $HELLO > /tmp/md-now.txt
cmp /tmp/md-now.txt $CKSUM; check $? read_degraded
umount $MNT

echo "-- rebuild: add a fresh device and wait for recovery --" >> $LOG
cp /etc/passwd /parts/$F
dd status=none if=/dev/zero of=/parts/$F bs=1024 count=256
mdadm /dev/md0 --add /parts/$F >> $LOG
check $? add_replacement
mdadm --wait /dev/md0 >> $LOG
check $? wait_recovery
cat /proc/mdstat >> $LOG
grep -q "\[3/3\] \[UUU\]" /proc/mdstat; check $? mdstat_recovered
mdadm --detail /dev/md0 >> $LOG

echo "-- data after the rebuild --" >> $LOG
mount /dev/md0 $MNT >> $LOG
check $? mount_after_rebuild
cksum $HELLO > /tmp/md-now.txt
cmp /tmp/md-now.txt $CKSUM; check $? read_after_rebuild
umount $MNT

echo "-- examine a member superblock --" >> $LOG
mdadm --examine /parts/$A >> $LOG
check $? examine_member
mdadm --examine /parts/$A > /tmp/md-ex.txt
grep -q "Magic : a92b4efc" /tmp/md-ex.txt; check $? examine_magic
grep -q "Checksum : .* correct" /tmp/md-ex.txt; check $? examine_checksum
mdadm --examine /parts/$F > /tmp/md-ex2.txt
grep -q "Active device 1" /tmp/md-ex2.txt; check $? examine_replacement_role

echo "-- stop, then assemble again from the devices --" >> $LOG
mdadm --stop /dev/md0 >> $LOG
check $? stop_array
mount /dev/md0 $MNT >> $LOG
if [ "$?" != "0" ]; then echo "ok  stopped_array_not_mountable" >> $LOG; else echo "ng  stopped_array_not_mountable" >> $LOG; umount $MNT; fi
mdadm --assemble /dev/md0 /parts/$A /parts/$C /parts/$F >> $LOG
check $? assemble_explicit
mount /dev/md0 $MNT >> $LOG
check $? mount_reassembled
cksum $HELLO > /tmp/md-now.txt
cmp /tmp/md-now.txt $CKSUM; check $? read_reassembled
umount $MNT

echo "-- write /etc/mdadm.conf for the next boot --" >> $LOG
mdadm --detail --scan >> /etc/mdadm.conf
check $? write_mdadm_conf
cat /etc/mdadm.conf >> $LOG
grep -q "^ARRAY /dev/md0 " /etc/mdadm.conf; check $? conf_has_md0
grep -q "^ARRAY /dev/md1 " /etc/mdadm.conf; check $? conf_has_md1

echo "-- stop both arrays so the next boot has to assemble them --" >> $LOG
mdadm --stop /dev/md0 >> $LOG
mdadm --stop /dev/md1 >> $LOG
cat /proc/mdstat >> $LOG
grep -q "^md0 :" /proc/mdstat; if [ "$?" = "1" ]; then echo "ok  all_arrays_stopped" >> $LOG; else echo "ng  all_arrays_stopped" >> $LOG; fi

echo "=== phase 1 done ===" >> $LOG
echo done > $MARK

else

echo "run-token=$RUNTOKEN" >> $LOG
echo "=== Delin md verify (phase 2: boot-time assembly) ===" >> $LOG
echo "-- systemctl status mdadm.service (assembled before local-fs.target) --" >> $LOG
systemctl status mdadm.service >> $LOG
systemctl is-active mdadm.service > /tmp/md-svc.txt
cat /tmp/md-svc.txt >> $LOG
grep -q "^active" /tmp/md-svc.txt; check $? mdadm_service_active

echo "-- /proc/mdstat right after boot --" >> $LOG
cat /proc/mdstat >> $LOG
grep -q "^md0 : active raid5" /proc/mdstat; check $? boot_md0_assembled
grep -q "^md1 : active raid1" /proc/mdstat; check $? boot_md1_assembled
grep -q "\[3/3\] \[UUU\]" /proc/mdstat; check $? boot_md0_all_in_sync

echo "-- the file written before the reboot must still read back --" >> $LOG
mount /dev/md0 $MNT >> $LOG
check $? boot_mount_array
cksum $HELLO > /tmp/md-now.txt
cmp /tmp/md-now.txt $CKSUM; check $? boot_read_survived
cat $HELLO >> $LOG
umount $MNT

echo "-- members still carry valid 1.2 superblocks --" >> $LOG
mdadm --examine /parts/$A > /tmp/md-ex.txt
grep -q "Checksum : .* correct" /tmp/md-ex.txt; check $? boot_superblock_intact
mdadm --detail --scan >> $LOG

echo "=== md verify done ===" >> $LOG
fi
