#!/bin/sh
# Delin 真机验证: 跑 sh 自检(内建/变量 scripts/sh_builtin_test.sh + 展开 scripts/sh_expand_test.sh)
# 以及 desh 自检(scripts/desh_test.sh: 与 sh 共用核心, 非交互行为必须逐项一致)。
# 结果写 /var/log/sh_verify.log。由 verify-sh.service(oneshot)在启动时调用;
# 宿主机用 tools/realmachine.py 取回日志。Delin 的 stderr 与 stdout 同流, 所以只需要一个 >。
#
# 注意: desh 的**交互**部分(按键 -> 屏幕)在真机上测不了 —— 那部分由宿主专用自检
# scripts/desh_tty_test.sh(假终端喂按键字节)覆盖, 真机上只需要确认非交互路径起得来。
LOG=/var/log/sh_verify.log
echo "=== Delin sh builtin verify ===" > $LOG
sh /root/sh_builtin_test.sh >> $LOG
echo "=== Delin sh expansion verify (glob/cmdsub/arith) ===" >> $LOG
sh /root/sh_expand_test.sh >> $LOG
echo "=== Delin desh verify (same core as sh: -c / script / exit codes / error prefix) ===" >> $LOG
sh /root/desh_test.sh >> $LOG
echo "=== sh/desh verify done ===" >> $LOG
