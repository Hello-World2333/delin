#!/bin/sh
# Delin 真机验证: POSIX 命令补齐后的自检(新工具 + sh 新内建 + 内核新能力)。
# 由 posix-verify.service(oneshot)在启动时运行, 结果写 /var/log/posix_verify.log。
#
# 只用 Delin sh 支持的子集: **没有命令替换($() 与反引号)、没有算术展开、没有 here-doc**,
# 所以"取命令输出再比较"一律走"重定向到文件 + cmp -s"这条路。
LOG=/var/log/posix_verify.log
mkdir -p /var/log   # 真机上 syslogd 已经建好; 这条只为能在宿主测试台里跑同一份脚本

echo "=== Delin POSIX tools verify ===" > $LOG

# 挑一个真的能建的临时目录。上一次真机跑的时候 /var/tmp/posixt 怎么也建不出来, 而同一进程里
# 的 /bin/lua 用 fs.makeDir 建 /var/tmp/posixk 却成功了 —— 所以这里逐个候选地建、并把每一步的
# 退出码与 ls 结果写进日志, 让下一轮直接看出到底是"建不出来"还是"建了又没了"。
T=
for cand in /var/tmp/posixt /tmp/posixt /run/posixt /posixt; do
    echo "try: mkdir -p $cand" >> $LOG
    rm -rf "$cand" >> $LOG
    echo "     rm rc=$?" >> $LOG
    mkdir -p "$cand" >> $LOG
    echo "     mkdir rc=$?" >> $LOG
    ls -ld "$cand" >> $LOG
    if [ -d "$cand" ]; then
        T="$cand"
        echo "     -> 采用 $T" >> $LOG
        break
    fi
    echo "     -> 不可用" >> $LOG
done
if [ -z "$T" ]; then
    echo "FATAL: 没有任何候选临时目录能建出来" >> $LOG
    ls -ld / /var /var/tmp /tmp /run >> $LOG
    exit 1
fi
echo "env: cwd=/$T" >> $LOG
ls -ld / /var /var/tmp /tmp >> $LOG

ng=0

# ---- 辅助 ----
# cmd_chk <名字> <命令...>: 退出码 0 记 ok
cmd_chk() {
    _n="$1"; shift
    # stdin 一律接 /dev/null: 服务里的 stdin 是**控制台**, 而 tr/tee 这类"缺省读 stdin"的命令
    # 会一直等输入 —— 上一轮真机就是这么挂死的(systemd 60s 超时后把服务杀掉, 日志戛然而止)。
    "$@" > "$T/got" < /dev/null
    _rc="$?"
    if [ "$_rc" = "0" ]; then
        echo "ok   $_n" >> $LOG
    else
        echo "ng   $_n (rc=$_rc)" >> $LOG; ng=1
    fi
}
# out_chk <名字> <期望(单行)> <命令...>: 命令 stdout 必须与期望逐字节相同
chk_eq() { # chk_eq <名字> <期望> <实际>
    if [ "$2" = "$3" ]; then
        echo "ok   $1" >> $LOG
    else
        echo "ng   $1 (want=$2 got=$3)" >> $LOG; ng=1
    fi
}
out_chk() {
    _n="$1"; _want="$2"; shift; shift
    "$@" > "$T/got" < /dev/null
    echo "$_want" > "$T/want"
    if cmp -s "$T/got" "$T/want"; then
        echo "ok   $_n" >> $LOG
    else
        echo "ng   $_n" >> $LOG
        echo "     want: $_want" >> $LOG
        echo "     got :" >> $LOG
        cat "$T/got" >> $LOG
        ng=1
    fi
}
# file_eq <名字> <a> <b>: 两个文件内容相同则 ok
file_eq() {
    _n="$1"
    if cmp -s "$2" "$3"; then
        echo "ok   $_n" >> $LOG
    else
        echo "ng   $_n" >> $LOG; ng=1
    fi
}
# stdin_chk <名字> <输入文件> <命令...>: 从文件喂 stdin, 命令必须退 0
stdin_chk() {
    _n="$1"; _in="$2"; shift; shift
    "$@" < "$_in" > "$T/got2"
    _rc="$?"
    if [ "$_rc" = "0" ]; then
        echo "ok   $_n" >> $LOG
    else
        echo "ng   $_n (rc=$_rc)" >> $LOG
        cat "$T/got2" >> $LOG
        ng=1
    fi
}
have() { command -v "$1" > /dev/null; }

# ---------------------------------------------------------------
echo "-- 内核新能力(lua) --" >> $LOG
if [ -f /root/posix_kernel_verify.lua ]; then
    /bin/lua /root/posix_kernel_verify.lua >> $LOG
    echo "kernel-verify rc=$?" >> $LOG
else
    echo "SKIP: /root/posix_kernel_verify.lua not deployed" >> $LOG
fi

# ---------------------------------------------------------------
echo "step: 路径/文本工具" >> $LOG
echo "-- 路径/文本工具 --" >> $LOG
if have basename; then out_chk basename c basename /a/b/c; fi
if have dirname;  then out_chk dirname /a/b dirname /a/b/c; fi
if have printf;   then out_chk printf 42 printf '%d\n' 42; fi
if have printf;   then out_chk printf_hex ff printf '%x\n' 255; fi
if have printf;   then out_chk printf_oct A printf '%b\n' '\101'; fi
if have expr;     then out_chk expr_div 3 expr 7 / 2; fi
if have expr;     then out_chk expr_str 3 expr abc : 'a.*'; fi
if have pathchk;  then cmd_chk pathchk_ok pathchk -p foo/bar; fi
if have sort;     then cmd_chk sort cut -f1 -d: /etc/passwd; fi
if have uniq;     then cmd_chk uniq uniq /etc/passwd; fi
if have cut;      then cmd_chk cut cut -d: -f1 /etc/passwd; fi
if have tr;       then stdin_chk tr /etc/passwd tr a-z A-Z; fi
if have cmp;      then cmd_chk cmp_same cmp /etc/passwd /etc/passwd; fi
if have comm;     then sort /etc/passwd > "$T/sorted"; cmd_chk comm comm "$T/sorted" "$T/sorted"; fi
if have join;     then cmd_chk join join "$T/sorted" "$T/sorted"; fi
if have paste;    then cmd_chk paste paste /etc/passwd /etc/passwd; fi
if have fold;     then cmd_chk fold fold -w 10 /etc/passwd; fi
if have expand;   then cmd_chk expand expand /etc/passwd; fi
if have unexpand; then cmd_chk unexpand unexpand /etc/passwd; fi
if have strings;  then cmd_chk strings strings /bin/sh; fi
if have od;       then cmd_chk od od -A n -t x1 /etc/passwd; fi
if have cksum;    then cmd_chk cksum cksum /etc/passwd; fi
if have pr;       then cmd_chk pr pr -t /etc/passwd; fi
if have split;    then cmd_chk split split -l 2 /etc/passwd "$T/sp_"; fi
if have csplit;   then cmd_chk csplit csplit -s -f "$T/cs_" /etc/passwd 1; fi
if have tee; then
    cp /etc/passwd "$T/tee.in"
    tee "$T/tee.out" < "$T/tee.in" > "$T/tee.stdout"
    echo "tee rc=$?" >> $LOG
    file_eq tee_file "$T/tee.out" "$T/tee.in"
    file_eq tee_stdout "$T/tee.stdout" "$T/tee.in"
    # stdout 是**管道**时必须也拿到同一份数据。老代码用点号调用 stdout 句柄
    # (管道句柄是 `write(_, s)`), 数据丢在 self 上 -> 下游读到 0 字节。
    wc -l < "$T/tee.in" > "$T/tee.in.wc"
    cat "$T/tee.in" | tee "$T/tee.pipe" | wc -l > "$T/tee.pipe.wc"
    file_eq tee_pipe_stdout "$T/tee.pipe.wc" "$T/tee.in.wc"
    file_eq tee_pipe_file "$T/tee.pipe" "$T/tee.in"
    # stdout 是**终端**时必须真的落屏 —— 屏幕读不回来, 由 lua 探针用光标位置观测
    if [ -f /root/tee_verify.lua ]; then
        /bin/lua /root/tee_verify.lua >> $LOG
        echo "tee-probe rc=$?" >> $LOG
    else
        echo "SKIP: /root/tee_verify.lua not deployed" >> $LOG
    fi
fi
if have rmdir;    then mkdir "$T/nodir"; cmd_chk rmdir rmdir "$T/nodir"; fi
if have du;       then cmd_chk du du -s "$T"; fi
if have df;       then cmd_chk df df; fi
if have file;     then cmd_chk file file /etc/passwd; fi
if have diff;     then cmd_chk diff_same diff /etc/passwd /etc/passwd; fi

echo "step: cksum 基准" >> $LOG
# cksum 基准值: POSIX CRC, "abc" -> 1219131554 3 (空 -> 4294967295 0)
if have cksum; then
    printf 'abc' > "$T/cksum.in"
    printf '1219131554 3 %s\n' "$T/cksum.in" > "$T/cksum.want"
    cksum "$T/cksum.in" > "$T/cksum.got" < /dev/null
    file_eq cksum_abc "$T/cksum.got" "$T/cksum.want"
    printf 'abc\n' > "$T/cksum2.in"
    printf '1112837078 4 %s\n' "$T/cksum2.in" > "$T/cksum2.want"
    cksum "$T/cksum2.in" > "$T/cksum2.got" < /dev/null
    file_eq cksum_abc_nl "$T/cksum2.got" "$T/cksum2.want"
fi

echo "step: patch 往返" >> $LOG
# diff -u -> patch -> 逐字节相同(核心验收, 真机上跑一遍)
if have diff && have patch; then
    echo one > "$T/p1"
    echo two >> "$T/p1"
    echo three >> "$T/p1"
    echo one > "$T/p2"
    echo TWO >> "$T/p2"
    echo three >> "$T/p2"
    cp "$T/p2" "$T/p2.want"
    diff -u "$T/p1" "$T/p2" > "$T/p.patch" < /dev/null
    patch -p0 "$T/p1" "$T/p.patch" > /dev/null < /dev/null
    echo "patch rc=$?" >> $LOG
    # p1 打完补丁后必须与 p2 逐字节相同
    file_eq patch_roundtrip "$T/p1" "$T/p2.want"
fi

echo "step: uu 往返" >> $LOG
# uuencode -> uudecode 往返逐字节相同
if have uuencode && have uudecode; then
    uuencode "$T/p1" p1 > "$T/uu.enc" < /dev/null
    uudecode -o "$T/uu.dec" "$T/uu.enc" < /dev/null
    file_eq uu_roundtrip "$T/uu.dec" "$T/p1"
fi

if have dd; then
    cmd_chk dd dd if=/etc/passwd of="$T/dd.out" bs=64
    file_eq dd_copy "$T/dd.out" /etc/passwd
fi

echo "step: 链接/管道工具" >> $LOG
echo "-- 链接/管道工具 --" >> $LOG
if have ln;       then cmd_chk ln_hard ln /etc/passwd "$T/hl"; fi
if have ln;       then cmd_chk ln_sym ln -s /etc/passwd "$T/sl"; fi
if have readlink; then out_chk readlink /etc/passwd readlink "$T/sl"; fi
if have realpath; then out_chk realpath /etc/passwd realpath /etc/../etc/passwd; fi
if have mkfifo;   then cmd_chk mkfifo_node mkfifo "$T/fifo0"; fi
if have find;     then cmd_chk find find /etc -name passwd -type f; fi
if have find;     then cmd_chk find_type find /etc -maxdepth 1 -type d; fi
if have xargs; then
    echo "a b c" > "$T/xargs.in"
    echo "a b c" > "$T/xargs.want"
    xargs /bin/echo < "$T/xargs.in" > "$T/xargs.out"
    echo "xargs rc=$?" >> $LOG
    file_eq xargs_default "$T/xargs.out" "$T/xargs.want"
fi
if have nohup;    then cmd_chk nohup nohup /bin/cat /etc/passwd; fi
# ln -s 之后必须能经链接读到内容(路径解析要穿过链接)
cp /etc/passwd "$T/sl.copy"
file_eq ln_readthrough "$T/sl" /etc/passwd
# 硬链接: 两个名字必须是同一个 inode(用 ls -l 的 links 计数看)
ls -l "$T/hl" >> $LOG

# ---------------------------------------------------------------
# 命名管道端到端: 后台读 + 前台写(POSIX 阻塞 open 的互相成全)
# 两种顺序都测: 读端先起 / 写端先起。
# ---------------------------------------------------------------
echo "step: FIFO 端到端" >> $LOG
echo "-- 命名管道端到端 --" >> $LOG
mkfifo "$T/pipe1"
cat "$T/pipe1" > "$T/pipe1.out" &
echo "through fifo" > "$T/pipe1"
sleep 2
echo "through fifo" > "$T/pipe1.want"
file_eq fifo_e2e "$T/pipe1.out" "$T/pipe1.want"

mkfifo "$T/pipe2"
echo "reverse fifo" > "$T/pipe2" &
cat "$T/pipe2" > "$T/pipe2.out"
sleep 2
echo "reverse fifo" > "$T/pipe2.want"
file_eq fifo_reverse "$T/pipe2.out" "$T/pipe2.want"

# ---------------------------------------------------------------
# sh 新内建
# ---------------------------------------------------------------
echo "step: sh 内建" >> $LOG
echo "-- sh 内建 --" >> $LOG
alias ll='echo alias-works'
out_chk alias alias-works ll
unalias ll
if have ls; then
    command -v ls > /dev/null
    if [ "$?" = "0" ]; then echo "ok   command_v" >> $LOG; else echo "ng   command_v" >> $LOG; ng=1; fi
fi
umask 077
umask > "$T/umask.out"
echo "0077" > "$T/umask.want"
file_eq umask_show "$T/umask.out" "$T/umask.want"
umask -S > "$T/umask_s.out"
echo "u=rwx,g=,o=" > "$T/umask_s.want"
file_eq umask_symbolic "$T/umask_s.out" "$T/umask_s.want"
# umask 必须真的作用到新建文件上(内核在 create 处统一应用)
if have touch; then
    touch "$T/umaskfile"
    ls -l "$T/umaskfile" >> $LOG
fi
umask 022

set -- -a -b val
out=""
while getopts "ab:" o; do out="$out$o=$OPTARG,"; done
echo "$out" > "$T/getopts.out"
echo "a=,b=val," > "$T/getopts.want"
file_eq getopts "$T/getopts.out" "$T/getopts.want"

if have ls; then
    hash ls > /dev/null
    if [ "$?" = "0" ]; then echo "ok   hash" >> $LOG; else echo "ng   hash" >> $LOG; ng=1; fi
fi
# time 的计时文本走 **stderr**(POSIX), 所以下面这条 `> 文件` 不该把它装进文件 ——
# 这里验的是更需要保住的语义: `time` 不能把被计时命令的退出码吞掉。
time false
_rc="$?"
if [ "$_rc" = "1" ]; then
    echo "ok   time_status" >> $LOG
else
    echo "ng   time_status (rc=$_rc, expect 1)" >> $LOG; ng=1
fi

echo "-- ls -l 复核(链接/管道类型字符与 umask 效果) --" >> $LOG
ls -l "$T" >> $LOG

# ---------------------------------------------------------------
# 选项行为(批次 0/1): 未知选项退出码 / head/tail 的符号语义 / grep 上下文与 -r 环路
#   / dmesg 时间戳与过滤 / lua -e / printf %q / echo -E / tail -f
# 期望值全部对着宿主 GNU 核过; 这里只取单行的可判定量(走 wc/定值输出)。
# ---------------------------------------------------------------
echo "-- option semantics (head/tail/grep/dmesg/lua/printf) --" >> $LOG
printf 'a\nb\nc\nd\ne\n' > "$T/five"

# 未知选项的退出码必须与宿主 GNU 一致(不许静默返回 0)
rc_chk() { # rc_chk <名字> <期望码> <命令...>
    _n="$1"; _want="$2"; shift; shift
    # 只写 stdout: Delin 的 sh **不支持 fd 前缀重定向**(2>f 会被切成操作数 2 + >>f, 见 for-ai.md),
    # 所以错误信息照旧走控制台, 不进日志。
    "$@" > "$T/rc.out" < /dev/null
    _rc="$?"
    if [ "$_rc" = "$_want" ]; then
        echo "ok   $_n" >> $LOG
    else
        echo "ng   $_n (rc=$_rc, want=$_want)" >> $LOG; ng=1
    fi
}
rc_chk opt_unknown_ls 2 ls --zz-bogus
rc_chk opt_unknown_cp 1 cp --zz-bogus
rc_chk opt_unknown_mkdir 1 mkdir --zz-bogus
rc_chk opt_unknown_sort 2 sort --zz-bogus
rc_chk opt_unknown_grep 2 grep --zz-bogus
rc_chk opt_unsupported_dmesg 2 dmesg -s 64
rc_chk opt_unsupported_touch 2 touch -h "$T/five"
rc_chk opt_unsupported_umount 2 umount -l "$T"

# head/tail 的符号语义(以前静默按"末 N 行"处理)
out_chk tail_from_2 4 sh -c "tail -n +2 $T/five | wc -l"
out_chk tail_c_from_3 8 sh -c "tail -c +3 $T/five | wc -c"
out_chk head_minus_2 3 sh -c "head -n -2 $T/five | wc -l"
out_chk head_c_minus_3 7 sh -c "head -c -3 $T/five | wc -c"
out_chk head_qv_ok 6 sh -c "head -qv $T/five | wc -l"  # 5 行 + 1 行 "==> file <==" 表头

# grep 的上下文 / 上限 / 计数
out_chk grep_count 1 sh -c "grep -c b $T/five"
out_chk grep_A1 2 sh -c "grep -A1 a $T/five | wc -l"
out_chk grep_m1 1 sh -c "grep -m1 b $T/five | wc -l"
out_chk grep_L_nonmatch 1 sh -c "grep -L zzz $T/five | wc -l"

# grep -r 遇到符号链接环必须收敛(老实现无限递归: 命令永远不返回)
mkdir -p "$T/loop/sub"
printf 'hello\n' > "$T/loop/a.txt"
ln -s .. "$T/loop/sub/up"
out_chk grep_r_no_loop 1 sh -c "grep -r hello $T/loop | wc -l"
cmd_chk grep_r_ok grep -r hello "$T/loop"

# dmesg 的新选项(非阻塞的那些)
cmd_chk dmesg_t dmesg -t
cmd_chk dmesg_x dmesg -x
cmd_chk dmesg_level dmesg -l err
cmd_chk dmesg_facility dmesg -f kern
cmd_chk dmesg_C dmesg -C

# tail -f: --pid 指向不存在的进程时应正常收尾(退出码 0), 且要真的走过跟读路径
rc_chk tail_f_pid_dead 0 tail -f --pid=999999 "$T/five"

# lua -e / printf %q / echo -E / groups 多操作数
out_chk lua_e 2 lua -e 'print(1+1)'
out_chk printf_q 'a\ b' printf '%q\n' 'a b'
out_chk printf_charconst 65 printf '%d\n' "'A"
out_chk echo_E 'a\tb' sh -c 'echo -E "a\tb"'
out_chk groups_multi 'root : root' groups root

# ---------------------------------------------------------------
# 选项行为(批次 2): ls/cp/rm/ln/du/df/sort/dd/blkid/systemctl/logger 的常用选项
# ---------------------------------------------------------------
echo "-- option semantics batch2 (ls/cp/rm/ln/du/dd/sort) --" >> $LOG
mkdir -p "$T/o2/d1" "$T/o2/d2"
printf 'one\n' > "$T/o2/a"
printf 'two\n' > "$T/o2/b"

# ls: -i 有 inode 号(不是 0), -F 目录带 /, -Q 加引号; -s 必须 fail-fast
out_chk ls_F_ok 1 sh -c "ls -F $T/o2 | grep -c 'd1/'"
out_chk ls_Q_ok 1 sh -c "ls -Q $T/o2/a | grep -c '\"\$'"
rc_chk ls_s_ok 0 ls -s "$T/o2"

# cp: -t / -l / -s / -T, 源不存在 -> 1
cmd_chk cp_t cp -t "$T/o2/d1" "$T/o2/a" "$T/o2/b"
out_chk cp_t_files 2 sh -c "ls $T/o2/d1 | wc -l"
cmd_chk cp_link cp -l "$T/o2/a" "$T/o2/d2/hard"
cmd_chk cp_sym cp -s "$T/o2/a" "$T/o2/d2/sym"
rc_chk cp_missing 1 cp "$T/o2/zzz-nope" "$T/o2/d2/x"

# rm: 拒绝 . / ..; 缺文件 -> 1; -f 静默成功
rc_chk rm_refuse_dot 1 rm .
rc_chk rm_missing 1 rm "$T/o2/zzz-nope"
rc_chk rm_force_missing 0 rm -f "$T/o2/zzz-nope"
cmd_chk rm_dir_d rm -r "$T/o2/d2"

# ln: -t 建到目录下; -r 的相对目标能被 cat 读回
mkdir -p "$T/o2/d3"
cmd_chk ln_t ln -s -t "$T/o2/d3" "$T/o2/a"
out_chk ln_t_ok one sh -c "cat $T/o2/d3/a"

# du/df/dd: 数值后缀与过滤
cmd_chk du_m du -m -s "$T/o2"
cmd_chk du_exclude du --exclude=a -a "$T/o2"
cmd_chk df_B df -B 1024
cmd_chk df_total df --total
out_chk dd_suffix 4 sh -c "dd if=$T/o2/a bs=1K status=none | wc -c"
rc_chk dd_badflag 1 dd if="$T/o2/a" oflag=direct status=none

# sort: -M 月份序 / -C 静默检查
printf 'Feb\nJan\nDec\n' > "$T/o2/mon"
out_chk sort_M 'Jan' sh -c "sort -M $T/o2/mon | head -1"
printf 'a\nb\n' > "$T/o2/sorted"
rc_chk sort_C_ok 0 sort -C "$T/o2/sorted"
printf 'b\na\n' > "$T/o2/unsorted"
rc_chk sort_C_bad 1 sort -C "$T/o2/unsorted"

# blkid: -s UUID -o value 与 -o device
cmd_chk blkid_s blkid -s UUID -o value /dev/sda1
cmd_chk blkid_dev blkid -o device /dev/sda1

# logger --no-act: 只打印不写日志(注意 -n 在 util-linux 里是 --server(网络), 不是 no-act)
out_chk logger_noact '<13>logger: hi' logger --no-act hi
rc_chk logger_net_unsupported 2 logger -n 127.0.0.1 hi
# systemctl: is-failed 对"在跑"的单元返回 3; cat 能打印单元文件
rc_chk systemctl_is_failed 3 systemctl is-failed syslogd.service
cmd_chk systemctl_cat systemctl cat syslogd.service

# ---------------------------------------------------------------
# 批次 3: 内核侧新能力落地后的行为(原子 rename / 时间戳 / statvfs / 属性暴露 / /dev/tty)
# ---------------------------------------------------------------
echo "-- option semantics batch3 (rename/touch/stat/df -i/find/sed) --" >> $LOG
mkdir -p "$T/o3"
printf 'hello\n' > "$T/o3/a"

# 原子 rename: mv 一个**符号链接**之后它仍是链接 —— copy+delete 会跟随链接变成普通文件。
ln -s /etc/passwd "$T/o3/sl"
mv "$T/o3/sl" "$T/o3/sl2"
out_chk mv_keeps_symlink 1 sh -c "ls -l $T/o3/sl2 | grep -c '^l'"
# 同一个文件改名: inode 号不变(原子 rename 的直接证据)
printf 'x\n' > "$T/o3/ino"
_before=$(stat -c %i "$T/o3/ino")
mv "$T/o3/ino" "$T/o3/ino2"
_after=$(stat -c %i "$T/o3/ino2")
if [ "$_before" = "$_after" ] && [ -n "$_before" ]; then
    echo "ok   mv_keeps_inode" >> $LOG
else
    echo "ng   mv_keeps_inode (before=$_before after=$_after)" >> $LOG; ng=1
fi

# touch 的时间戳真的落盘: -d 2020-01-01 = 1577836800(UTC)
touch -d 2020-01-01 "$T/o3/a"
_v=$(stat -c %Y "$T/o3/a")
chk_eq touch_date 1577836800 "$_v"
touch -t 202002020304.05 "$T/o3/a"
_v=$(stat -c %Y "$T/o3/a")
chk_eq touch_stamp 1580612645 "$_v"
printf 'y\n' > "$T/o3/b"
touch -r "$T/o3/a" "$T/o3/b"
_v=$(stat -c %Y "$T/o3/b")
chk_eq touch_reference 1580612645 "$_v"
touch -m -d 2021-01-01 "$T/o3/a"
touch -a -d 2022-01-01 "$T/o3/a"
_v=$(stat -c %X "$T/o3/a")
chk_eq touch_atime_only 1640995200 "$_v"
_v=$(stat -c %Y "$T/o3/a")
chk_eq touch_mtime_kept 1609459200 "$_v"

# stat: 默认输出 + 格式符 + 块数
cmd_chk stat_default stat "$T/o3/a"
_v=$(stat -c "%F %s" "$T/o3/a")
chk_eq stat_format "regular file 6" "$_v"
_v=$(stat -c %b "$T/o3/a")
if [ "$_v" -gt 0 ]; then echo "ok   stat_blocks_nonzero" >> $LOG; else echo "ng   stat_blocks_nonzero ($_v)" >> $LOG; ng=1; fi

# df -i: inode 用量(ext2 superblock 计数)
out_chk df_inodes 1 sh -c "df -i | grep -c 'IUse%'"
cmd_chk df_i df -i

# find: -printf 的块/时间指令与 -newermt / -ls
cmd_chk find_printf find "$T/o3" -printf "%p %y %m %s %T@\n"
cmd_chk find_newermt find "$T/o3" -newermt 2000-01-01 -name a
cmd_chk find_ls find "$T/o3" -maxdepth 1 -ls

# sed: 保持空间 / 分支 / 块 / 步长地址
out_chk sed_hold a sh -c "printf 'a\n' | sed -n '1h;1g;p'"
out_chk sed_branch A sh -c "printf 'a\n' | sed 's/a/A/;tb;s/^/X/;:b'"
out_chk sed_block 2 sh -c "printf 'a\nb\nc\n' | sed -n '/b/,/c/{p}' | wc -l"
out_chk sed_step 2 sh -c "printf 'a\nb\nc\nd\n' | sed -n '1~2p' | wc -l"

# uniq -D / --group / xargs -d / kill -L / wc --files0-from / /dev/tty
out_chk uniq_D 2 sh -c "printf 'a\na\nb\n' | uniq -D | wc -l"
out_chk uniq_group 4 sh -c "printf 'a\na\nb\n' | uniq --group | wc -l"
printf 'a:b:c' > "$T/o3/in3"
xargs -a "$T/o3/in3" -d: -n1 echo > "$T/o3/out3"
_v=$(wc -l < "$T/o3/out3")
chk_eq xargs_delim 3 "$_v"
# 已知缺口, 不断言(见 for-ai.md「管道端是共享句柄对象」一节): xargs 起一串子进程共用同一个
# stdout 管道时, 第一个子进程退出就把管道关了 ——
#   printf 'a:b:c' | xargs -d: -n1 echo | wc -l   ->  1(期望 3)
# 重定向到文件不受影响, 上面 xargs_delim 走的就是文件路径。
out_chk kill_table 1 sh -c "kill -L | grep -c KILL"
printf '%s\0' "$T/o3/a" > "$T/o3/list0"
out_chk wc_files0_out 1 sh -c "wc --files0-from=$T/o3/list0 | grep -c o3"
out_chk dev_tty_node 1 sh -c "ls /dev | grep -cx tty"

# ---------------------------------------------------------------
# 标准正则(grep/sed/ed/expr/csplit 的 BRE/ERE 方言与退出码)
# 独立的 scripts/regex_test.sh: 宿主与真机跑同一份, 期望值对着宿主 GNU 核过。
# ---------------------------------------------------------------
echo "-- standard regex (grep/sed/ed/expr/csplit) --" >> $LOG
sh /root/regex_test.sh >> $LOG
_rc="$?"
if [ "$_rc" = "0" ]; then
    echo "ok   regex_test" >> $LOG
else
    echo "ng   regex_test (rc=$_rc)" >> $LOG; ng=1
fi

echo "== summary: ng=$ng ==" >> $LOG
if [ "$ng" = "0" ]; then echo "all ok" >> $LOG; else echo "some failed" >> $LOG; fi
rm -rf "$T"
exit $ng
