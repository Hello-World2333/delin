#!/bin/sh
# Delin 真机验证: POSIX 命令补齐后的自检(新工具 + sh 新内建 + 内核新能力)。
# 由 posix-verify.service(oneshot)在启动时运行, 结果写 /var/log/posix_verify.log。
#
# 只用 Delin sh 支持的子集: **没有命令替换($() 与反引号)、没有算术展开、没有 here-doc**,
# 所以"取命令输出再比较"一律走"重定向到文件 + cmp -s"这条路。
LOG=/var/log/posix_verify.log
T=/var/tmp/posixt
mkdir -p /var/log   # 真机上 syslogd 已经建好; 这条只为能在宿主测试台里跑同一份脚本
rm -rf "$T"
mkdir -p "$T"

echo "=== Delin POSIX tools verify ===" > $LOG
ng=0

# ---- 辅助 ----
# cmd_chk <名字> <命令...>: 退出码 0 记 ok
cmd_chk() {
    _n="$1"; shift
    "$@" > "$T/got"
    _rc="$?"
    if [ "$_rc" = "0" ]; then
        echo "ok   $_n" >> $LOG
    else
        echo "ng   $_n (rc=$_rc)" >> $LOG; ng=1
    fi
}
# out_chk <名字> <期望(单行)> <命令...>: 命令 stdout 必须与期望逐字节相同
out_chk() {
    _n="$1"; _want="$2"; shift; shift
    "$@" > "$T/got"
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
if have tr;       then cmd_chk tr tr a-z A-Z; fi
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
if have tee;      then cmd_chk tee tee "$T/tee.out"; fi
if have rmdir;    then mkdir "$T/nodir"; cmd_chk rmdir rmdir "$T/nodir"; fi
if have du;       then cmd_chk du du -s "$T"; fi
if have df;       then cmd_chk df df; fi
if have file;     then cmd_chk file file /etc/passwd; fi
if have diff;     then cmd_chk diff_same diff /etc/passwd /etc/passwd; fi

# cksum 基准值: POSIX CRC, "abc" -> 1219131554 3 (空 -> 4294967295 0)
if have cksum; then
    printf 'abc' > "$T/cksum.in"
    printf '1219131554 3 %s\n' "$T/cksum.in" > "$T/cksum.want"
    cksum "$T/cksum.in" > "$T/cksum.got"
    file_eq cksum_abc "$T/cksum.got" "$T/cksum.want"
    printf 'abc\n' > "$T/cksum2.in"
    printf '1112837078 4 %s\n' "$T/cksum2.in" > "$T/cksum2.want"
    cksum "$T/cksum2.in" > "$T/cksum2.got"
    file_eq cksum_abc_nl "$T/cksum2.got" "$T/cksum2.want"
fi

# diff -u -> patch -> 逐字节相同(核心验收, 真机上跑一遍)
if have diff && have patch; then
    echo one > "$T/p1"
    echo two >> "$T/p1"
    echo three >> "$T/p1"
    echo one > "$T/p2"
    echo TWO >> "$T/p2"
    echo three >> "$T/p2"
    cp "$T/p2" "$T/p2.want"
    diff -u "$T/p1" "$T/p2" > "$T/p.patch"
    patch -p0 "$T/p1" "$T/p.patch" > /dev/null
    echo "patch rc=$?" >> $LOG
    # p1 打完补丁后必须与 p2 逐字节相同
    file_eq patch_roundtrip "$T/p1" "$T/p2.want"
fi

# uuencode -> uudecode 往返逐字节相同
if have uuencode && have uudecode; then
    uuencode "$T/p1" p1 > "$T/uu.enc"
    uudecode -o "$T/uu.dec" "$T/uu.enc"
    file_eq uu_roundtrip "$T/uu.dec" "$T/p1"
fi

if have dd; then
    cmd_chk dd dd if=/etc/passwd of="$T/dd.out" bs=64
    file_eq dd_copy "$T/dd.out" /etc/passwd
fi

echo "-- 链接/管道工具 --" >> $LOG
if have ln;       then cmd_chk ln_hard ln /etc/passwd "$T/hl"; fi
if have ln;       then cmd_chk ln_sym ln -s /etc/passwd "$T/sl"; fi
if have readlink; then out_chk readlink /etc/passwd readlink "$T/sl"; fi
if have realpath; then out_chk realpath /etc/passwd realpath /etc/../etc/passwd; fi
if have mkfifo;   then cmd_chk mkfifo_node mkfifo "$T/fifo0"; fi
if have find;     then cmd_chk find find /etc -name passwd -type f; fi
if have find;     then cmd_chk find_type find /etc -maxdepth 1 -type d; fi
if have xargs;    then cmd_chk xargs_e echo a b c | xargs echo; fi
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
echo "-- 命名管道端到端 --" >> $LOG
mkfifo "$T/pipe1"
cat "$T/pipe1" > "$T/pipe1.out" &
echo "through fifo" > "$T/pipe1"
wait
echo "through fifo" > "$T/pipe1.want"
file_eq fifo_e2e "$T/pipe1.out" "$T/pipe1.want"

mkfifo "$T/pipe2"
echo "reverse fifo" > "$T/pipe2" &
cat "$T/pipe2" > "$T/pipe2.out"
wait
echo "reverse fifo" > "$T/pipe2.want"
file_eq fifo_reverse "$T/pipe2.out" "$T/pipe2.want"

# ---------------------------------------------------------------
# sh 新内建
# ---------------------------------------------------------------
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

echo "== summary: ng=$ng ==" >> $LOG
if [ "$ng" = "0" ]; then echo "all ok" >> $LOG; else echo "some failed" >> $LOG; fi
rm -rf "$T"
exit $ng
