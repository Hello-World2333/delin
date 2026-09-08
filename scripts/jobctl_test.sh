# Delin 作业控制自检(POSIX 子集: & / jobs / fg / bg / wait / kill %job / $!)
# 同一份脚本在宿主(tools/harness.lua)与真机(ext2_init 自检)各跑一次, 输出逐项比对。
# 交互式作业控制(fg/bg/进程组/tty)需要真机 tty, 这里只覆盖非交互部分。

echo "== 1. 后台执行与 dollar-bang =="
sh -c 'echo bg-ran' &
echo "bgpid=$!"
test -n "$!" && echo "dollar-bang-ok"
echo "amp-status=$?"

echo "== 2. 后台不阻塞前台 =="
sh -c 'echo one' &
echo "foreground"
wait
echo "after-wait"

echo "== 3. wait 取退出码 =="
sh -c 'exit 3' &
wait $!
echo "wait-code=$?"

sh -c 'exit 0' &
wait %+
echo "wait-jobspec=$?"

echo "== 4. 变量/函数注入后台子 shell =="
greeting=hello
show() { echo "func-says $1"; }
echo "var=$greeting" &
wait
show world &
wait

echo "== 5. 管道后台 =="
cat /etc/passwd | grep root &
wait
echo "pipe-bg-done"

echo "== 6. jobs 列表 =="
sh -c 'echo job-a' &
sh -c 'echo job-b' &
jobs
jobs -p
wait
jobs
echo "jobs-after-wait=$?"

echo "== 7. kill 当前作业 =="
sh -c 'while true; do :; done' &
bgpid=$!
kill -9 %+
wait $bgpid
echo "killed-status=$?"
jobs
echo "jobs-empty=$?"

echo "== 8. 后台 stdin 为 /dev/null =="
sh -c 'cat; echo cat-eof' &
wait
echo "bg-stdin-eof"

echo "== 9. 后台重定向 =="
sh -c 'echo redirected > /tmp/jobctl.txt' &
wait
cat /tmp/jobctl.txt
rm -f /tmp/jobctl.txt

echo "== 10. 无作业控制时 fg/bg 报错 =="
fg
echo "fg-status=$?"
bg
echo "bg-status=$?"

echo "== 11. kill 信号名解析(-SIG / -s / -l) =="
kill -l TSTP
kill -l 20
kill -BOGUS 1
echo "kill-bogus=$?"
kill -s TSTP 999999
echo "kill-s-name=$?"

echo "== done =="
