#!/bin/sh
# Delin /proc + 进程管理工具自检 (ps / pgrep / pkill / killall)。
# 可移植 POSIX sh; 既能在宿主( lua5.1 tools/harness.lua /bin/sh < scripts/proc_test.sh )
# 跑, 也能在真机跑(由 realmachine_verify.sh 调用)。输出 "ok <name>" / "ng <name>",
# 全部 ok 退出码 0 —— 两边的输出应当一致。
# 注意: 不依赖 grep 的退出码(Delin grep 目前恒返回 0), 用 "输出文件是否非空" 判定;
#       不打印 pid 等每次运行都不同的值。

T=/tmp/proctest
outcome=0
rm -rf $T
mkdir -p $T

ok() { echo "ok $1"; }
ng() { echo "ng $1"; outcome=1; }
chk() { # chk <name> <cmd...>: 命令退出码 0 即通过
    _n="$1"; shift
    "$@"
    if [ "$?" = "0" ]; then ok "$_n"; else ng "$_n"; fi
}
chkneg() { # 命令退出码非 0 即通过
    _n="$1"; shift
    "$@"
    if [ "$?" != "0" ]; then ok "$_n"; else ng "$_n"; fi
}
chkfile() { # 文件存在且非空
    if [ -s "$2" ]; then ok "$1"; else ng "$1"; fi
}
chkempty() {
    if [ -s "$2" ]; then ng "$1"; else ok "$1"; fi
}
chkcontain() { # chkcontain <name> <pattern> <file>
    grep "$2" "$3" > $T/grepout
    if [ -s $T/grepout ]; then ok "$1"; else ng "$1"; fi
}

# ---------------------------------------------------------------
# 1. /proc 目录结构
# ---------------------------------------------------------------
chk proc_is_dir       [ -d /proc ]
chk proc_self_dir     [ -d /proc/self ]
chk proc_self_stat    [ -f /proc/self/stat ]
chk proc_self_status  [ -f /proc/self/status ]
chk proc_self_comm    [ -f /proc/self/comm ]
chk proc_self_cmdline [ -f /proc/self/cmdline ]
chk proc_self_cwd     [ -f /proc/self/cwd ]
chk proc_uptime_file  [ -f /proc/uptime ]
chk proc_version_file [ -f /proc/version ]
chk proc_mounts_file  [ -f /proc/mounts ]
chkneg proc_no_dead   [ -e /proc/99999/stat ]

# ---------------------------------------------------------------
# 2. 进程信息文件
# ---------------------------------------------------------------
cat /proc/self/comm > $T/comm
chkcontain self_comm_is_cat '^cat$' $T/comm

cat /proc/self/status > $T/status
chkcontain status_name  '^Name:' $T/status
chkcontain status_state '^State:' $T/status
chkcontain status_pid   '^Pid:' $T/status
chkcontain status_ppid  '^PPid:' $T/status
chkcontain status_uid   '^Uid:' $T/status

cat /proc/self/stat > $T/stat
chkcontain stat_pid_comm 'cat)' $T/stat

cat /proc/self/cmdline > $T/cmdline
chkfile cmdline_nonempty $T/cmdline
cat /proc/self/cwd > $T/cwd
chkfile cwd_nonempty $T/cwd

# 只读: 写打开必须失败
chkneg proc_readonly sh -c 'echo x > /proc/self/comm'

# ---------------------------------------------------------------
# 3. 系统信息文件
# ---------------------------------------------------------------
cat /proc/version > $T/version
chkcontain version_delin 'Delin OS' $T/version
cat /proc/uptime > $T/uptime
chkfile uptime_nonempty $T/uptime
cat /proc/mounts > $T/mounts
chkcontain mounts_has_proc 'proc /proc proc' $T/mounts
chkcontain mounts_has_sysfs 'sysfs /sys' $T/mounts

# ---------------------------------------------------------------
# 4. ps
# ---------------------------------------------------------------
ps -e --no-headers -o pid,comm > $T/ps_e
chkfile ps_e_nonempty $T/ps_e
chkcontain ps_e_has_sh 'sh' $T/ps_e

ps -e -o pid,ppid,user,stat,tty,comm,cmd > $T/ps_o
chkcontain ps_o_header '^PID' $T/ps_o

ps > $T/ps_default
chkfile ps_default_nonempty $T/ps_default
ps -ef > $T/ps_ef
chkfile ps_ef_nonempty $T/ps_ef
ps aux > $T/ps_aux
chkfile ps_aux_nonempty $T/ps_aux

chkneg ps_bad_option ps -Z
chkneg ps_bad_field  ps -o nosuchfield

# ---------------------------------------------------------------
# 5. pgrep / pkill / killall
# ---------------------------------------------------------------
sleep 30 &
pgrep -x sleep > $T/pgrep_x
chkfile pgrep_sleep $T/pgrep_x
pgrep -l sleep > $T/pgrep_l
chkcontain pgrep_l_sleep 'sleep' $T/pgrep_l
pgrep -f sleep > $T/pgrep_f
chkfile pgrep_f_sleep $T/pgrep_f
chkneg pgrep_nomatch pgrep -x nosuchprocessname

pkill -TERM -x sleep
sleep 1
pgrep -x sleep > $T/pgrep_after
chkempty pkill_sleep $T/pgrep_after

sleep 30 &
killall -e sleep > $T/killall_out
chkcontain killall_echo 'killed' $T/killall_out
sleep 1
pgrep -x sleep > $T/pgrep_after2
chkempty killall_sleep $T/pgrep_after2
chkneg killall_nomatch killall -q nosuchprocessname

rm -rf $T
if [ "$outcome" = "0" ]; then echo "=== proc test: all ok ==="; else echo "=== proc test: FAILED ==="; fi
exit $outcome
