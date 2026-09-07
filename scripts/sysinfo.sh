#!/bin/sh
# Delin sysinfo — 可移植 POSIX sh; 在 host 与 Delin sh 上都能安全运行。
# 只用 Delin 支持的子集: 无管道(|)、无命令替换($()/``)、无算术 $(( ))。
# 演示变量、函数、for/case/if、重定向与核心工具。

sec() { echo; echo "== $1 =="; }

# 身份与当前目录
sec "identity"
echo "pid: $$"
echo "current dir:"
pwd

# 用户(文件存在则展示)
sec "users"
if [ -e /etc/passwd ]; then
    cat /etc/passwd
else
    echo "(no /etc/passwd)"
fi

# 目录树: 遍历顶级目录
sec "root tree"
for d in /bin /dev /etc /proc /sys /mnt /home /root; do
    if [ -d "$d" ]; then
        echo "$d/  (dir)"
    else
        echo "$d/  (absent)"
    fi
done

# 设备文件
sec "devices (/dev)"
if [ -d /dev ]; then
    ls /dev > /tmp/sysinfo_dev.txt
    cat /tmp/sysinfo_dev.txt
else
    echo "(no /dev)"
fi

# tty 焦点与显示设备抽象
sec "tty / display"
echo "console tty:"
echo "  tty0"
echo "display devices /sys/class/display:"
if [ -d /sys/class/display ]; then
    ls /sys/class/display > /tmp/sysinfo_disp.txt
    cat /tmp/sysinfo_disp.txt
else
    echo "  (none)"
fi

# 用 case 分类一个单词
sec "word classification"
kind=foo
case "$kind" in
    foo) echo "  kind=foo -> a foo" ;;
    bar) echo "  kind=bar -> a bar" ;;
    *)   echo "  kind=$kind -> other" ;;
esac
kind=baz
case "$kind" in
    b*) echo "  kind=baz -> starts with b" ;;
    *)  echo "  kind=baz -> other" ;;
esac

# 函数
desk() {
    if [ -d "$1" ]; then
        echo "  $1 exists"
    else
        echo "  $1 missing"
    fi
}
sec "existence probe"
desk /bin
desk /etc
desk /tmp
desk /no/such/dir

# 文件规模(用 wc + 重定向, 不捕获命令输出)
sec "etc sizes"
for f in /etc/passwd /etc/group /etc/shadow; do
    if [ -e "$f" ]; then
        echo "$f:"
        wc -c "$f"
    fi
done

# 文本处理(用 sed 落盘再 cat)
sec "sed demo"
echo "aaa bbb ccc" > /tmp/sysinfo_in.txt
sed 's/bbb/BBB/' /tmp/sysinfo_in.txt > /tmp/sysinfo_out.txt
echo "original:"
cat /tmp/sysinfo_in.txt
echo "after sed s/bbb/BBB/:"
cat /tmp/sysinfo_out.txt

# 清理
rm -f /tmp/sysinfo_dev.txt /tmp/sysinfo_disp.txt /tmp/sysinfo_in.txt /tmp/sysinfo_out.txt

echo
echo "== sysinfo done =="
exit 0
