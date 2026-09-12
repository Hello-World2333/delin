#!/bin/sh
# Delin 真机验证: 跑 sh 自检(内建/变量 scripts/sh_builtin_test.sh + 展开 scripts/sh_expand_test.sh)
# 并把结果写 /var/log/sh_verify.log。由 verify-sh.service(oneshot)在启动时调用;
# 宿主机用 tools/realmachine.py 取回日志。Delin 的 stderr 与 stdout 同流, 所以只需要一个 >。
LOG=/var/log/sh_verify.log
echo "=== Delin sh builtin verify ===" > $LOG
sh /root/sh_builtin_test.sh >> $LOG
echo "=== Delin sh expansion verify (glob/cmdsub/arith) ===" >> $LOG
sh /root/sh_expand_test.sh >> $LOG
echo "=== sh verify done ===" >> $LOG
