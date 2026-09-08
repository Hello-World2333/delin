# Delin OS

适用于 **CC: Tweaked (ComputerCraft)** 的操作系统。

## 设计目标

项目设计目标：**目录结构尽可能符合 Unix 标准；系统接口与 shell 工具尽可能符合 POSIX 标准 + GNU 扩展。**
目的是让一个习惯 Linux 的人来到 Delin 不会遇到很明显的阻碍——看到一个 `/dev`、一个 `/proc`、一个
`/etc/passwd`、一个 `kill -l`、一个 `sed -i` 就能直接上手，而不用先学一套新的约定。

实现细节一律对照真实 Linux 的 man 手册与命令行为来定，可在本机 `man(1)` / `man(5)` / `man(7)` 核对。

### 目录约定（FHS 风格）

| 路径 | 作用 |
|---|---|
| `/bin/` | 用户工具：`cat ls mkdir rm cp mv touch head tail wc grep sed kill login sh sleep systemctl syslogd logrotate logger dmesg mount umount` |
| `/dev/` | 设备文件：`/dev/ttyN`（字符终端）、`/dev/fbN`（像素帧缓冲）、`/dev/sdX`（磁盘，见下）、`/dev/null`（读 EOF/写丢弃）、`/dev/console`（系统控制台 = 控制台 tty）、`/dev/kmsg`（内核 ring buffer 只读流）、`/dev/log`（用户态 syslog 输入） |
| `/etc/` | 系统配置：`passwd` `shadow` `group`、`fstab`、`syslog.conf`、`logrotate.conf`、`systemd/system/`（管理员单元与 enable 标记） |
| `/proc/` | 虚拟进程/系统信息 fs（由模块提供） |
| `/sys/` | sysfs 挂载点（虚拟）；`/sys/class/display/` 下每设备一个目录，`name/type/size` 只读，分辨率/位置/旋转/缩放 可读写 |
| `/lib/modules/<version>/` | 内核模块目录：`.ko` 模块 + 纯文本 `manifest` + `modules.alias` |
| `/lib/systemd/system/` | 厂商单元文件（`.service` `.target` `.timer` `.mount`） |
| `/run/` | 运行时状态（真实目录，非 tmpfs —— Delin 无 tmpfs）：pid 文件等 |
| `/var/log/` | 系统日志（由 syslogd 写入，logrotate 轮转） |
| `/mnt/` | 挂载点（`/etc/fstab` 中的条目由 init 生成 mount 单元自动挂载；其余用 `mount` 显式挂载） |
| `/parts/` | 引导盘分区清单 `manifest`（`<role> <path> <fstype>`，`#` 为注释） |
| `/boot/` | 内核镜像 |
| `/dlub.cfg` | DLUB 引导配置（电脑自身 FS）：`bootdisk <外设名>` 显式指定引导盘 |

### 磁盘设备（`/dev/sdX`）

CC 没有裸块 API：磁盘驱动器只提供「盘上的 CC 原生文件系统」和「盘上的 `/parts/*.img` 文件」两样东西。
内核把它们抽象成 Linux 风格的设备节点，**磁盘不自动挂载**，一律由 `mount` 显式挂载：

| 节点 | 含义 | fstype |
|---|---|---|
| `/dev/sda`、`/dev/sdb` … | 整盘：该驱动器的 CC 原生文件系统 | `ccdisk` |
| `/dev/sda1` … `/dev/sdaN` | 分区：该盘 `/parts/manifest` 第 N 个分区行指向的镜像 | `ext2` |
| `/dev/ccdisk0`、`/dev/ccdisk1` … | 整盘 CC 原生 fs 的别名节点（N 从 0 起，同 `sda`、`sdb`） | `ccdisk` |

- **命名**：磁盘按 `disk.getID()` 升序编成 `sda`、`sdb`、…（与 `peripheral.getNames()` 顺序、槽位无关，
  重启后同一块盘仍是同一个字母）；分区号取该盘 `/parts/manifest` 分区行的序号（1 起，`root` 行在前）。
- **UUID**：CC 没有文件系统 UUID，用**磁盘 ID 模拟**——整盘为 `<磁盘ID>`，分区为 `<磁盘ID>-<分区号>`
  （如磁盘 ID 1 的第一个分区是 `1-1`）；无 ID 的介质（电脑盘/海龟盘）没有 UUID，不能用 `UUID=` 挂载。
- **挂载**：`mount /dev/sda1 /mnt`（无 `-t` 时按节点自带类型）、`mount -t ccdisk /dev/sda /mnt`、
  `mount UUID=1-1 /mnt`；`umount` 接受挂载点或设备节点。`mount` 无参列出挂载（含设备节点与 uuid），
  `blkid` 列出设备的 UUID/TYPE/LABEL，`lsblk` 以树状列出设备与挂载点。
- **原始字节**：分区节点可当字节设备打开（`fs.open("/dev/sda1","r")` 读镜像原始字节）；整盘是 CC 原生
  文件系统（目录树，不是字节流），打开会被拒绝，只能挂载。
- 磁盘插入/弹出（CC `disk` / `disk_eject` 事件）时内核重新扫描并刷新 `/dev` 节点。

### 接口与工具（POSIX + GNU 子集）

**进程模型**：`pid/ppid/uid/gid`；`argv`（`[0]`=程序名，`[1..]`=位置参数）；会话（`sid`）与进程组
（`pgrp`）；`tcgetpgrp` 前台进程组；作业控制（`&` `jobs` `fg` `bg` `wait` `kill %job`）。
进程的退出码 = 协程返回值（数字），`proc.wait`/`$?` 由此得到；信号死亡记为 `128+signo`。

**信号**：POSIX 信号编号（`SIGHUP..SIGTTOU`，取 Linux x86-64 编号与默认动作/可捕获表）；
`kill [-SIG] pid|-pgid`、`kill -l`；终端 `^C`（`SIGINT`）/`^Z`（`SIGTSTP`）路由到前台进程组，
后台进程组读控制终端按 POSIX 投 `SIGTTIN` 并停止（`jobs` 显示 `Stopped`，`fg`/`bg` 可恢复）。

**文件系统**：进程所见 `fs/io` 走内核 VFS（真实磁盘 + 虚拟 `/dev` `/proc` `/sys` 同一命名空间）；
权限用 `mode`（八进制）+ `uid/gid`，`chmod`/`chown`，启动外部程序强制检查执行（`x`）位。

**用户**：`/etc/passwd` `name:x:uid:gid:fullname:home:shell`、`/etc/shadow` `name:salt$hash`、
`/etc/group`；`login` 提示用户名/密码（隐藏回显），验证通过后按该用户 `uid/gid` 起 `sh`。

**显示抽象**：进程面向设备文件而非库接口——`/dev/ttyN`（控制台）、`/dev/fbN`（帧缓冲）。

**工具**：`ls`、`cat`、`mkdir (-p)`、`rm (-r|-f)`、`cp (-r)`、`mv`、`touch`、`head (-n)`、`tail (-n)`、
`sleep`（GNU 风格：小数秒 + `s/m/h/d` 后缀 + 多操作数求和；50ms 分片睡眠，信号可及时打断）、
`wc (-l|-w|-c)`、`grep (-n|-i|-v)`、`sed`（GNU 子集：`s/y/d/p/q/a/i/c/=`、行号/`$`/正则地址与区间、
`!` 取反、`-n -s -e -f -i`）、`ed`（POSIX 子集：`a/i/c/d/p/n/l/s/t/m/r/w/q/u/g/v/=`、地址 `.` `$` n `/re/` `+n` `-n`、输入模式以 `.` 结束）、`kill`、`login`、
`chmod`（八进制 + 符号模式 `[ugoa]*[+-=][rwx]*` + `-R` 递归）、`chown`（`[OWNER][:[GROUP]]` + `-R`）、
`mount`（挂载 `/dev/sdX`、`UUID=<uuid>` 或镜像路径；无 `-t` 时按设备类型；无参列出挂载）、`umount`、
`blkid`（列出设备 UUID/TYPE/LABEL）、`lsblk`（树状列出设备/大小/类型/挂载点）、
`systemctl`（init 控制）、`syslogd`/`logger`/`dmesg`/`logrotate`（日志）、`sh`。
各工具支持 POSIX 的 **`--` 结束选项** 标记：`rm -- --help`、`touch -- -file`、`ls -- --ff` 等，用于操作以
`-`/`--` 开头的文件名；单独的 `-` 视为普通操作数。

**sh（POSIX 核心子集）**：变量与展开（`$x`/`${x}`/`$?`/`$#`/`$@`/`$*`/`$!`/`$1..`）；单/双引号；
`if/elif/else`、`for`、`while`、`case`、函数（位置参数）、`[ ]`/`test`（`=` `!=` `-n` `-z` `-eq/-ne/-lt/-le/-gt/-ge`
`-e/-f/-d/-s/-x/-r/-w`、`!`）；`&&`/`||`/`;`；文件重定向（`>` `>>` `<`）；管道（`|`，每元素一个进程/内建，
经内核 pipe 缓冲传递，`$?`=末元素退出码，生产端写满/消费端读空时让出调度器，broken pipe 中止写端）；内建
`cd pwd echo read exit help jobs fg bg wait kill test [ true false : break continue return shift`。
**`read [-r] var...`**（POSIX）：从当前 stdin 读一行, 按 `IFS` 分割后赋值（多余字段全部归最后一个
变量、去尾部 IFS 空白）；无 `-r` 时反斜杠转义下一字符、行尾反斜杠续行；EOF 时变量置空并返回 1。
`IFS` 是真正的 shell 变量（默认空白；置空则不分割），`IFS=: read a b` 的赋值是命令作用域（不污染后续）。
**作业控制**：`cmd &` 后台执行（POSIX 异步列表），交互式下打印 `[jid] pid`、`$!` 为最近后台 pid、
命令结束时报告 `[jid]+ Done  cmd`；`jobs`（`-l` 带 pid、`-p` 只列进程组，`%+`/`%-` 标当前/前一作业）、
`fg [%job]`、`bg [%job]`、`wait [%job|pid]`、`kill [-SIG] %job`；作业引用 `%n`/`%+`/`%-`/pid。
交互式前台命令也各占一个进程组并接管 tty，`^Z` 停下的前台命令自动进作业表（`fg`/`bg` 可继续）。
Delin 无 fork：`&` 的作业用 `sh -c <命令原文>` 起子 shell（内置/管道/复合命令都在子进程里跑），
父 shell 的变量与函数定义以赋值/定义语句前置注入；无作业控制（非交互 sh）时后台命令 stdin 指向
`/dev/null`（POSIX 规定）。
命令行执行：`sh -c '命令' [name [args...]]`（POSIX 2.5.3，`$0`=name）。
**多行命令**：`\` + 换行 行续接（POSIX 2.2.1，从输入中删除；词内部与双引号内同样生效，单引号内是字面反斜杠）；
`|` / `&&` / `||` 之后允许换行；交互式下跨行结构（`if`/`for`/`while`/`case`/函数体、未闭合引号、续行）用
PS2 提示 `> ` 继续读行；脚本/管道输入到 EOF 仍不完整则报 `syntax error: unexpected end of file`。
脚本执行：`sh script.sh [args...]` 或 `./script.sh [args...]`（需 `+x`，经 `#!` shebang），
shebang 支持 `#!/bin/sh` / `#!/usr/bin/env sh` 等形式，env 特殊解释为查找后续程序名。
无 shebang 的文件按 Delin Lua 程序直接 spawn（兼容 `/bin/*` 工具源码）。
`>>`/`>` 写文件在命令结束后 `close` 提交到 ext2（handle 写入可能缓冲，需关闭才落盘）。

**已知偏离**：`grep`/`sed` 的正则用 **Lua pattern**（`%` 为转义符、`()` 为捕获）而非 POSIX ERE/BRE；
替换区用 `&`=整串匹配、`\1..\9`=捕获组、`\n/\t`，不支持 BRE 风格 `\(...\)` 与模式内逆引用。
注意 Lua pattern 里 `-` 是量词（非贪婪），要匹配字面连字符需 `%-`，与 GNU grep 的 `-`（字面）不同。
不支持**命令替换 `$()`/反引号**、**算术 `$(( ))`**、**here-doc `<<`**（暂未实现，遇到即语法错误）。
`&` 的子 shell 是重新执行的进程（无 fork）：父 shell 的变量与函数定义经赋值/定义语句注入，
但 `$?` 在子 shell 里从 0 开始（不继承父 shell 的最后状态）。`VAR=value cmd` 的赋值在命令词
展开**之前**生效（POSIX/bash 是展开之后，故 `x=0; x=1 echo $x` 在 Delin 打印 1、在 bash 打印 0）；
外部命令拿不到环境变量（Delin 无环境块）；`read` 无法区分“末行无换行”（句柄 API 限制，按成功计）。
因 CC 5.2 无位运算，`/etc/shadow` 哈希用盐+密码的 32 位滚动哈希（djb2）替代传统 `crypt`。

### init（systemd 风格服务管理器）

PID 1 是用户态程序（`src/init/` 三个文件打包成一个自包含 chunk，内部 `__require`），不再是写死的
启动脚本。它装载**单元文件**、按依赖图启动、监督服务、响应 `systemctl`：

- **单元目录**：`/lib/systemd/system/`（厂商）+ `/etc/systemd/system/`（管理员，同名覆盖）。
  类型后缀 `.service` `.target` `.timer` `.mount`。INI 风格段：
  `[Unit]` `Description= After= Before= Requires= Wants= Conflicts=`、
  `[Service]` `Type=simple|oneshot ExecStart= Restart=no|always|on-failure|on-abnormal
  RestartSec= TimeoutStartSec= TimeoutStopSec= RemainAfterExit= StartLimitBurst=
  StartLimitIntervalSec=`、`[Timer]` `OnBootSec= OnActiveSec= OnUnitActiveSec= Unit=`、
  `[Mount]` `What= Where= Type= Options=`、`[Install]` `WantedBy=`。
- **依赖**：`Requires=`（硬依赖，失败则本单元不启动）/`Wants=`（软依赖）/`After=`/`Before=`（仅排序）。
  启动 = 从目标单元收集 `Requires`+`Wants` 闭包，按 `After`/`Before` 做拓扑排序（有环即 fail-fast 报出环上单元），
  然后依序启动；`target` 的 `Wants`/`Requires` 自动补 `After=`（systemd.target(5) 语义，target 只有在它拉起的
  单元都起来后才算 active）。
- **服务监督**：init 注册内核子进程退出钩子（`proc.onExit`）；服务异常退出按 `Restart=` 排定重启，
  重启风暴超过 `StartLimitBurst`/`StartLimitIntervalSec` 即放弃并标 `failed`（systemd 的 start limit）。
  `Type=oneshot` 会等它跑完（`TimeoutStartSec` 超时则 SIGKILL），`stop` 先 SIGTERM、超时 SIGKILL。
- **启动目标**：`default.target` → `multi-user.target` → `local-fs.target` + `getty.target` + `timers.target`
  + 已 enable 的服务（`syslogd.service`）。init 还会为每个 `/dev/ttyN` 实例化 `getty@ttyN.service`
  （模板单元 `getty@.service` 的 `%i`/`%I` 替换），并在启动失败/无单元时进入 **rescue**：每个 tty 起 `login`。
- **enable/disable**：systemd 用 symlink，Delin 的 CC 原生 fs 没有 symlink，因此用**同名空标记文件**
  `/etc/systemd/system/<target>.wants/<unit>`（`systemctl enable` 按 `[Install] WantedBy=` 创建，disable 删除）。
- **`/bin/systemctl`**：`list-units` `list-unit-files` `status` `start` `stop` `restart` `enable` `disable`
  `is-active`（非 active 退出码 3）`is-enabled`（未启用退出码 1）`daemon-reload` `shutdown`。
  Delin 无 Unix socket/D-Bus，`systemctl` 经**共享 syscall 表**调用 init 注册的 `init.*` 接口
  （等价的 private socket）；单元名省略后缀时按 `.service → .target → .timer → .mount` 补全。

### 日志（klog / syslogd / logrotate）

与 Linux 同构的两级：内核 ring buffer + 用户态守护进程。

- **`/dev/kmsg`**：内核日志 ring buffer（默认 16KB，满了丢最旧）的只读流，每行 `pri,seq,usec,-;text`。
  读者从缓冲区**最旧一条**开始，读尽后阻塞等待新消息 —— 因此 syslogd 启动前产生的引导日志不会丢。
- **`/dev/log`**：用户态 syslog 输入（等价的 `/dev/log` socket），生产者写 `<PRI>tag: message`，
  syslogd 独占读取；无读者时缓冲有界（8KB），满了丢最旧并计数。
- **`pri` = facility×8 + severity**，facility/severity 名表由内核 `kernel.klog` 持有（唯一真源），
  经 `syslog.*` syscall 暴露给 `logger`/`syslogd`/`dmesg`。
- 内核 `kprint` 走 **kern.info**，进程 `print` 走 **user.info**（Delin 的 `print` 是内核控制台，
  不是进程 stdout —— 后者是 `io.write`）。
- **`/bin/syslogd`**（`syslogd.service`，`Restart=always`）：读 `/dev/kmsg` + `/dev/log`，按
  `/etc/syslog.conf` 规则（`selector action`，`facility[.severity]`、`,`/`;` 组合、`*`/`none`）
  写 `/var/log/messages`、`/var/log/secure`、`/var/log/kern.log` 等；SIGHUP 重开输出文件。
- **`/bin/logrotate`**（`logrotate.service`，oneshot，由 `logrotate.timer` 触发）：
  `/etc/logrotate.conf` 子集（`size`/`daily|weekly|monthly`/`rotate`/`create`/`notifempty`/`missingok`），
  轮转后向 `/run/syslogd.pid` 发 SIGHUP 让 syslogd 重开文件。未支持的指令（`compress`/`postrotate`/
  `dateext`…）一律 fail-fast 报错。
- **`/bin/logger`**（util-linux 子集）、**`/bin/dmesg`**（打印 `/dev/kmsg`）。
- ext2 的追加句柄现在是**增量落盘**（`ext2.appendFile` + `flush`），日志守护进程无需重写整个文件即可提交。

### fstab

`/etc/fstab`（fstab(5) 子集：`<device> <mountpoint> <fstype> <options> <dump> <pass>`）由 init 在启动时
读入，**生成 mount 单元**（systemd 命名：`/mnt/data` → `mnt-data.mount`，`/` → `-.mount`），
并作为 `Requires=`/`After=` 注入 `local-fs.target` —— 与 systemd 的 fstab generator 等价。
选项识别 `defaults ro rw auto noauto nofail user users`（`ro/rw/user/users` 解析但 Delin 不强制；
未知选项 fail-fast）。`noauto` 不随启动挂载，`nofail` 使挂载失败只记 Wants 软依赖；
fstab 语法错误会让 `local-fs.target` 失败 → `multi-user.target` 失败 → init 进入 rescue。
`mount -a` 复用同一解析器（跳过 `noauto` 与已挂载的挂载点），`mount -t` 可过滤类型。

**init / 日志的已知偏离**：`enable` 用 `.wants/` 空标记文件而非 symlink（CC 原生 fs 无符号链接）；
`systemctl` 经共享 syscall 表调用 init（Delin 无 Unix socket/D-Bus），`stop`/`restart` 只排队并立即返回
（不等服务退出），启动按依赖拓扑**串行**而非 systemd 的并行 job 队列；`/run` 是根 fs 上的真实目录
（无 tmpfs），因此跨引导残留的 `/run/syslogd.kmsg` 游标靠"引导标识"字段作废；timer 只支持
`OnBootSec`/`OnActiveSec`/`OnUnitActiveSec`（无 `OnCalendar`）；`fstab` 的 `ro/rw/user/users` 解析但不强制
（fstype 无只读模式）；`syslogd` 的 `/dev/kmsg` 是非破坏性 ring buffer，首次启动会把缓冲区里的引导日志
一并落盘（Linux 的 `/proc/kmsg` 是破坏性读取，行为相近但 Delin 不会丢消息）。

## 当前状态

v0.0.1 的协程调度内核 + 进程树之后，已扩展为具备 VFS、块设备、EXT2 读写、显示抽象、模块系统、
用户/权限、**systemd 风格 init**、**rsyslog 风格日志服务**与 **fstab** 的迷你系统。所有子系统自持
事件循环，由内核调度器驱动；进程跑在隔离 `_ENV` 里，经注入的内核上下文
（`spawn`/`pid`/`ppid`/`uid`/`gid`/`syscalls`）访问内核能力，其余原始 CC API 直用。

PID 1 现在是**用户态服务管理器**（`src/init/unit.lua` 单元解析 + `service.lua` 引擎 + `init.lua` 主程序，
经打包器拼成一个自包含 chunk）：单元文件（`/lib/systemd/system` + `/etc/systemd/system`）、
`Requires`/`Wants`/`After`/`Before` 依赖图与拓扑排序（有环 fail-fast）、`simple`/`oneshot` 服务、
`Restart=`/`StartLimitBurst` 重启策略、`target`、`timer`、`mount` 单元、`systemctl`
（start/stop/restart/enable/disable/status/list-units/is-active/daemon-reload/shutdown）、
无单元或启动失败时进入 rescue（每个 tty 起 login）。日志服务：内核 ring buffer + `/dev/kmsg`、
用户态 `/dev/log`、`syslogd` 按 `/etc/syslog.conf` 写 `/var/log/*`（SIGHUP 重开、游标续读不重放）、
`logrotate` + `logrotate.timer` 轮转、`logger`/`dmesg`。`/etc/fstab` 由 init 生成 mount 单元
（`local-fs.target`），`mount -a` 复用同一解析器。init 里的自检代码已全部删除，验证改为
宿主测试台 `tools/hosttest.lua`（113 项）与真机脚本 `tools/realmachine.py` +
`scripts/realmachine_verify.sh`。

`src/bin/sh` 已升级为 POSIX 核心子集（变量/引号/if/for/while/case/函数/test/[ ]/&&/|| /文件重定向/管道
`|`，无命令替换 `$()`、算术 `$(( ))`），支持脚本执行（`sh script.sh` / `./script.sh`，`#!` shebang）、
`rm`/`mkdir` 补了 GNU `-r/-f`/`-p`；新增 `chmod`（八进制 + 符号模式 + `-R`）、`chown`（`owner:group` + `-R`）、
`mount`（挂载 `/dev/sdX`、`UUID=` 或镜像路径 / `-a` 按 fstab 挂载 / 无参列出）/ `umount` / `blkid` / `lsblk`；
磁盘驱动器经 `devdisk` 抽象为 `/dev/sda`（整盘 ccdisk）与 `/dev/sdaN`（manifest 分区 ext2）设备节点，
UUID 用磁盘 ID 模拟，磁盘不随启动自动挂载（改由 `/etc/fstab` 声明）。作业控制落地：
`&` 后台作业 + `jobs`/`fg`/`bg`/`wait`/`kill %job`/`$!`、
前台作业进程组与 `^C`/`^Z` 路由、后台进程组读 tty 的 `SIGTTIN`、`/dev/null`、`sh -c`；
新增 `read` 内建（POSIX，跟随 `IFS` 变量）与 `/bin/sleep`（GNU 风格，分片睡眠便于信号打断）。
`scripts/posix_test.sh`（111 项）与 `scripts/jobctl_test.sh` 在宿主与 Delin 上各跑一次逐项比对，
`scripts/sysinfo.sh` 演示实用用法。

### 引导

代码经 `tools/bundle.lua` 打包成自包含 Lua 文件部署。两条引导路径：

- **CC-fs 引导**（默认）：`kernel.lua` 直接跑 `boot.boot()`——`setupVfs` 挂根 hdd 到 `/` +
  `mountDev` + `klog.register`（`/dev/kmsg`、`/dev/log`）→ `setupDevices` 扫描磁盘驱动器注册
  `/dev/sdX` 节点（不自动挂载）→ `registerConsole` 把电脑自身 `term` 注册为 `/dev/ttyN` 控制台
  （并派生 `/dev/console`）→ `setupModules`
  从 `/lib/modules/<version>/` 装模块（`loadAll` + `loadAliases` + 按外设 autoload 驱动，
  modprobe 风格 `modules.use`）→ `sysfs.mount` 挂 `/sys` → `launch` 出 PID 1（用户态 init）。
- **EXT2 根引导**（GRUB 风格，DLUB 独立文件）：先由 `dlub.lua` 读**电脑自身 FS** 的 `/dlub.cfg`
  （`bootdisk <外设名>`，如 `bootdisk left`）锁定引导盘——多磁盘时 `peripheral.getNames()` 顺序
  不可靠（数据盘可能先被枚举到），因此**不扫描、不回退**：配置缺失/语法错误/该外设不是磁盘驱动/
  盘上无 `/parts/manifest` 一律 fail-fast 报错。再读该盘 `/parts/manifest`，按清单把 root 分区开成
  块设备、挂 ext2、读内核镜像并设 `_G.__boot_info`；`boot.boot()` 检测到
  `__boot_info` 即走 `bootExt2`——挂 ext2 根为 `/`（挂载表里显示为对应的 `/dev/sdXN`），读
  `/etc/passwd` 建用户库，模块只从 ext2 根镜像
  自带的 `/lib/modules/<version>/` 装载（自包含，fail-fast，绝不回退到引导盘/CC fs 的 `/lib`）。
  两条路径最后都 spawn 同一份 init 源码，随后由 init 启动 `default.target`。

真机流程：`tools/realmachine.py`（打包 → `tools/deploy.py` 重建 ext2 根镜像 → 注入第二个 ext2 分区
供 fstab 测试 + `verify.service` → 写 DLUB 到电脑 FS 的引导入口 → RCON 重启电脑 #3 → 用 `debugfs`
从镜像取回 `/var/log/*`）；`scripts/realmachine_verify.sh` 是它在真机上跑的验证脚本。

### 设计要点

- **并发**：内核自持 `os.pullEventRaw` 循环，`coroutine.create/resume` + 按协程 yield 的 filter
  分发事件；进程经原始 API（`os.sleep`/`os.pullEvent`/`fs`……）yield，调度器驱动。
- **时钟与让出**：`cc_hse` 时钟走**拉模式**（`setPushEvents(false)` + 按需 `waitNextTick`）。
  推送模式 @2kHz 会在 ~128ms 内塞满电脑事件队列（上限 256），CC 对满队列静默丢弃 —— 长命令
  输出期间的按键（字符/切 tty/`^C`）就是这样被丢掉的。`os.msleep(0)` 是一次按需 tick 让出
  （≥2ms，`ms>=50` 走 CC 定时器），工具与 `sh` 只在 ~50ms 时间片边界让出；内核另有 0.05s 调度
  心跳，保证裸让出（`filter=nil`，如 `tty.readLine`）的进程在空闲期也能推进。
- **隔离环境**：每个进程有自己的 `_ENV`（`load(src, name, "t", env)`），注入内核上下文
  `spawn`/`pid`/`ppid`/`uid`/`gid`/`syscalls`，`__index = _G` 兜底原始 API。
- **`spawn` 只收源码字符串**：`spawn(src, name?, uid?, gid?, argv?, opts?)` 在隔离 `_ENV` 里建子进程；
  读文件由程序自己做；`argv`（`[0]`=程序名）与 `arg0`/`args`/`argc` 直接注入子进程环境。
- **进程树 + 会话/进程组**：`{ pid, ppid, status, children, pgrp, sid, sig }`；父死子并入 init；
  信号经调度器在 resume 前投递（`setSignalCheck`）。
- **print 覆盖**：内核自供 `print`（写 klog + 引导日志 + 终端），因 CC 自带 `print` 不走 `io.stdout`；
  进程 `print` 记 user.info，内核消息记 kern.info。
- **stdio 按进程隔离**：每个进程有自己的 `stdin/stdout`；spawn 时从父进程继承（或 boot 默认终端），
  `stdio.set` 只改当前进程；`io.write/read` 经 `vfs_api.setStdio` 兜底到终端。
- **tty 焦点切换**：只有前台 tty 接收键盘。`Ctrl+Alt+1..0` 切换前台 tty，多 tty 共用一把键盘；
  行缓冲 + 回显（canonical 行规程），焦点 tty 收到 `^C`/`^Z` 时把信号投给其前台进程组。
- **getty/login**：init 为每个 `/dev/ttyN` 实例化 `getty@ttyN.service`（`ExecStart=/bin/login %I`）；
  login 验证后按用户 `uid/gid` 起 `sh`（同 tty stdio），`sh` 退出后回到 login 循环；
  getty 退出由 init 按 `Restart=always` 重新拉起。
- **服务是 init 的孩子**：`proc.spawnFile` 支持 `opts.ppid`，服务统一挂在 PID 1 名下（与 systemd 一致）；
  子进程退出经内核 `proc.onExit` 钩子同步通知 init（不轮询）。
- **设备与文件系统分层**：`devdisk` 只负责「有哪些设备」（枚举磁盘 → `/dev/sdX` + UUID 解析 + 挂载表），
  文件系统实现由模块用 `kapi.registerFstype(name, fn)` 注册（`ext2.ko` → `ext2`，`ccdisk.ko` → `ccdisk`）；
  `mount -t <type>` 找不到处理器即报错（fail-fast，无回退）。

## 构建

```bash
lua5.1 tools/bundle.lua kernel   # 生成 dist/kernel.lua（内核 bundle）
lua5.1 tools/bundle.lua dlub     # 生成 dist/dlub.lua（DLUB 引导装载器，独立文件）
```

内核 bundle 复制到引导盘 `bootPath`（manifest 的 `boot` 行，默认 `/boot/delin.lua`）；DLUB 复制到
**电脑自身 FS** 的引导脚本入口（`/.boot` 指向的 `/main.lua`）。DLUB 还需在**电脑自身 FS** 写
`/dlub.cfg` 指定引导盘外设名（如 `bootdisk left`），缺失或非法时 DLUB 直接报错、不猜测。
产物均以 Lua 5.2+ `_ENV` 技巧打包，每个模块包一层 `__require` 到内部 shim；init 的多个源文件
（`unit.lua` + `service.lua` + `init.lua`）拼成**一个** chunk（前两者为内部模块，最后一个是顶层主程序）。

验证：

```bash
lua5.1 tools/hosttest.lua        # 宿主测试: init 引擎/fstab/syslogd/logrotate/systemctl (113 项)
lua5.1 tools/harness.lua /bin/sh # 宿主上跑真实工具源码(sh/作业控制/管道)
python3 tools/realmachine.py     # 真机: 打包->部署->重启电脑 #3->取回 /var/log/*
```

## 约定

- 源码用 **EmmyLua** 注解仅为人类维护 / IDE 提示，不作为任何门禁；其警告与报错忽略。
- git 提交使用本仓库 local config。

## 目录

```
src/kernel/scheduler.lua   协程调度器(事件循环) + resume 前信号投递
src/kernel/process.lua     进程表/进程树/spawn/隔离 env + cwd + argv + 会话/进程组/信号/作业控制
                            + 子进程退出钩子(init 服务监督) + opts.ppid
src/kernel/signal.lua      POSIX 信号编号/默认动作/可捕获表/名字表
src/kernel/vfs.lua         虚拟文件系统: 挂载表 + resolve + real/virtual 后端
src/kernel/vfs_api.lua     VFS 门面(fs/io) + /dev 设备注册表 + stdio
src/kernel/klog.lua        内核日志: ring buffer + /dev/kmsg(带 cursor/seek) + /dev/log + syslog 优先级名表
src/kernel/fstab.lua       /etc/fstab 解析(fstab(5) 子集) + systemd 风格 mount 单元命名
src/kernel/modules.lua     内核模块系统: .ko 解析(注释头)/依赖拓扑/装载/alias(use) + fstype 注册
src/kernel/blockdev.lua    块设备层: 文件块设备(/parts/*.img, seek+read/write)
src/kernel/devdisk.lua     磁盘设备抽象: CC 磁盘 -> /dev/sdX 节点 + UUID(磁盘 ID 模拟) + fstype 挂载/卸载
src/kernel/ext2.lua        EXT2 读写: 超级块/inode(uid/gid/mode/硬链接/符号链接)/间接块/多块组
                            + 追加写增量落盘(appendFile/flush)
src/kernel/user.lua        用户库: /etc/passwd|shadow|group, salt+hash, chmod/chown 权限
src/kernel/display.lua     显示设备注册表: 统一 ScreenDevice -> /dev/ttyN + /dev/fbN
src/kernel/tty.lua         字符终端(/dev/ttyN): 行规程+回显+光标+滚动+焦点切换 + 按名打开(别名设备)
src/kernel/fb.lua          软件帧缓冲(/dev/fbN): 32 位 ARGB 像素缓冲+脏矩形 flush
src/kernel/sysfs.lua       /sys 虚拟配置 fs(sysfs 风格, class/display 子树, 读=查/写=设)
src/kernel/manifest.lua    /parts/manifest 解析器(root/boot 行 + 分区表)
src/kernel/dlubcfg.lua     /dlub.cfg 解析器(bootdisk 行; 语法/未知键/重复键 fail-fast)
src/kernel/dlub.lua        DLUB 引导装载器(GRUB 风格): /dlub.cfg 锁盘->清单->开区->挂 ext2->载内核
src/kernel/boot.lua        入口: 引导日志->kprint->setupVfs/设备/模块->sysfs->launch 用户态 init
src/init/unit.lua          init 内部模块: 单元文件解析/模板 %i 替换/字段归一化
src/init/service.lua       init 内部模块: 依赖图+拓扑排序/服务启停/重启策略/timer/mount 单元
src/init/init.lua          PID 1 主程序: fstab->mount 单元, getty 实例化, init.* 控制接口, rescue, 主循环
src/bin/cat                连接文件到 stdout
src/bin/ls                 列目录
src/bin/mkdir              建目录 (-p 递归建父)
src/bin/rm                 删文件/目录 (-r|-R 递归, -f 忽略不存在)
src/bin/cp                 复制文件/目录(-r 递归)
src/bin/mv                 移动/重命名(复制后删源)
src/bin/touch              创建空文件
src/bin/head               打印前 N 行 (-n N|-N)
src/bin/tail               打印后 N 行 (-n N|-N)
src/bin/wc                 统计行/词/字节 (-l|-w|-c)
src/bin/grep               按 Lua 模式查找行 (-n|-i|-v)
src/bin/sed                流式文本编辑器 (GNU 子集: s/y/d/p/q/a/i/c/=, 地址区间, -n -s -e -f -i)
src/bin/ed                 行编辑器 (POSIX 子集: a/i/c/d/p/n/l/s/t/m/r/w/q/u/g/v/=, 正则地址与替换, 交互逐行读)
src/bin/kill               发送信号到进程/进程组 (kill [-SIG] pid|-pgid; kill -l)
src/bin/chmod              修改文件权限 (八进制+符号模式 [ugoa]*[+-=][rwx]*, -R 递归)
src/bin/chown              修改文件属主/属组 ([OWNER][:[GROUP]], -R 递归)
src/bin/mount              挂载 /dev/sdX、UUID=<uuid> 或镜像路径 (-a 按 fstab; 无 -t 按设备类型; 无参列出)
src/bin/umount             卸载文件系统 (umount <dir>|<-device>)
src/bin/blkid              列出块设备的 UUID/TYPE/LABEL (util-linux blkid 子集)
src/bin/lsblk              树状列出块设备: NAME/SIZE/TYPE/MOUNTPOINT (util-linux lsblk 子集)
src/bin/login              getty/login: 登录提示->验证->启动 sh->循环
src/bin/sleep              暂停指定时间 (GNU 风格: 小数秒 + s/m/h/d 后缀 + 多操作数求和)
src/bin/systemctl          控制 init: list-units/status/start/stop/restart/enable/disable/is-active/daemon-reload
src/bin/syslogd            系统日志守护进程: /dev/kmsg+/dev/log -> /etc/syslog.conf 规则 -> /var/log/*
src/bin/logrotate          日志轮转 (logrotate(8) 子集: size/daily/rotate/create/notifempty/missingok)
src/bin/logger             写一条消息到 /dev/log (util-linux logger 子集)
src/bin/dmesg              打印内核 ring buffer (/dev/kmsg)
src/bin/sh                 交互/脚本 shell(POSIX 核心子集: 变量/IFS/引号/if/for/while/case/函数/test/[ ]/&&/||
                           /重定向/管道/作业控制(& jobs fg bg wait kill %job)/read, 支持 -c 与 shebang 脚本)
src/units/*                厂商单元文件 -> /lib/systemd/system/ (default/multi-user/local-fs/getty/timers
                           target, syslogd.service, getty@.service, logrotate.service/.timer)
src/etc/{fstab,syslog.conf,logrotate.conf}  系统配置 -> /etc/
src/modules/*.ko           内核模块: ccdisk(ccdisk fstype) ccmonitor(CC 显示器驱动) cc_hse(HSE 时钟拉模式
                           os.msleep) demo(演示) ext2(ext2 fstype) tom(Tom GPU 驱动) void(Void 全息驱动)
src/modules/modules.alias  驱动别名(modprobe 风格): tm_gpu->tom hologram->void monitor->ccmonitor
src/modules/manifest       默认装载模块清单: demo ext2 ccdisk
scripts/posix_test.sh      可移植 POSIX 自检(host 与 Delin 各跑一次比对, 111 项全过)
scripts/jobctl_test.sh     作业控制自检(& / $! / jobs / fg / bg / wait / kill %job, host 与真机各跑一次)
scripts/sysinfo.sh         实用小工具: 系统信息(变量/函数/for/case/if/重定向/工具)
scripts/realmachine_verify.sh  真机验证脚本(由 verify.service 以 oneshot 运行, 结果写 /var/log/verify.log)
tools/bundle.lua           打包 src/ -> dist/kernel.lua 或 dist/dlub.lua(init 多文件拼成一个 chunk)
tools/harness.lua          host 测试台: 用真实 Delin 工具源码在宿主跑(fs/io/syscalls/spawn 桩,
                           含信号/进程组语义: kill/killpg/SIGCONT/stopped, 供 sh 作业控制验证)
tools/hosttest.lua         宿主测试: init 单元引擎/fstab 生成/syslogd 规则/logrotate 轮转/systemctl(113 项)
tools/deploy.py            重建干净 ext2 根镜像(基镜像+内核/bin/单元/配置/标记)并部署到 disk
tools/realmachine.py       真机流程: 打包->部署->注入第二分区与 verify.service->重启 #3->debugfs 取回日志
dist/                      生成物(不提交)
```
