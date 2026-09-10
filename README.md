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
| `/bin/` | 用户工具：`cat ls mkdir rm cp mv touch head tail wc grep sed ed kill ps pgrep pkill killall login sh lua clear sleep systemctl syslogd logrotate logger dmesg mount umount lp` |
| `/dev/` | 设备文件：`/dev/ttyN`（字符终端）、`/dev/fbN`（像素帧缓冲）、`/dev/sdX`（磁盘，见下）、`/dev/lpN`（打印机字符设备，只写，见下）、`/dev/null`（读 EOF/写丢弃）、`/dev/console`（系统控制台 = 控制台 tty）、`/dev/kmsg`（内核 ring buffer 只读流）、`/dev/log`（用户态 syslog 输入） |
| `/etc/` | 系统配置：`passwd` `shadow` `group`、`fstab`、`syslog.conf`、`logrotate.conf`、`systemd/system/`（管理员单元与 enable 标记） |
| `/proc/` | 虚拟进程/系统信息 fs（procfs，内核提供，见下）：`/proc/<pid>/{cmdline,comm,cwd,stat,status}`、`/proc/self`、`/proc/{mounts,uptime,version}` |
| `/sys/` | sysfs 挂载点（虚拟）：`/sys/class/<class>/<条目>/<属性>`，class 由内核/模块注册 —— `display`（每显示设备一项，`name/type/size` 只读，分辨率/位置/旋转/缩放 可读写）、`printer`（每打印设备一项，见下）与 `redstone`（每个红石面一项，见下）；属性文件是单行值，读一次即 EOF |
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
  `mount UUID=1-1 /mnt`；`umount` 接受挂载点或设备节点。`mount` 无参列出挂载
  （设备节点/挂载点/类型/`ro|rw`/uuid，与 `/proc/mounts` 同一来源），
  `blkid` 列出设备的 UUID/TYPE/LABEL，`lsblk` 以树状列出设备与挂载点。
- **原始字节**：分区节点可当字节设备打开（`fs.open("/dev/sda1","r")` 读镜像原始字节）；整盘是 CC 原生
  文件系统（目录树，不是字节流），打开会被拒绝，只能挂载。
- 磁盘插入/弹出（CC `disk` / `disk_eject` 事件）时内核重新扫描并刷新 `/dev` 节点。

### 打印机设备（`/dev/lpN`）

CC 打印机的原始 API 是「页」式的（`newPage`/`write`/`setCursorPos`/`endPage`），内核把它抽象成
Linux `lp(4)` 风格的**字符设备**：写入的字节流 = 交给打印机打印的文本。

| 节点 | 含义 |
|---|---|
| `/dev/lp0`、`/dev/lp1` … | 打印机字符设备（只写）；`cat f > /dev/lp0` 或 `lp f` 即打印 |

- **写语义**：内核按页宽（真机实测 25 列）折行、写满一页（21 行）立即 `endPage` 打印并开新页，
  `close` 时把当前未满的页也打印出来 —— 因此一次 `cat`/`lp` 就是一次完整打印，不会留下悬挂的
  「进行中页面」（CC 的进行中页无法取消，且随方块状态跨重启残留；真机上 `newPage` 会先把旧页打出来，
  所以上次崩溃留下的悬挂页会在下次打印时自动补打）。
- **状态与控制**：`/sys/class/printer/<节点>/` 下 `name`（外设名）、`type`、`size`（页尺寸 `WxH`，
  首次开页后才可知，之前为空）、`paper`、`ink` 只读；`title` 可写（页标题，对已开始的页立即生效，
  否则用于下一页）。
- **fail-fast**：纸/墨不足或出纸盘满时 `newPage`/`endPage` 返回 false，驱动直接报错，不静默丢数据。
  注意 CC 打印机的**出纸盘只有 6 格**，满了之后 `endPage` 会失败（页出不来），必须先取出打印页；
  此时留下的「进行中页」会在下次开页时自动补打，不需要额外恢复。
- **`/bin/lp`**：POSIX lp(1) 子集 —— `lp [-d dest] [-t title] [file...]`，`-d` 默认 `/dev/lp0`
  （也接受 `lp0`），无文件或 `-` 读 stdin，多个文件连接成一个打印流；`^C` 时停止喂数据并关闭设备
  （已写入内容仍成页打印，不留悬挂页），退出码 130。
- 真机实测的打印机原始语义（`write` 不折行、`\n` 是普通字符、开页即扣 1 纸 + 1 墨、`endPage` 出纸盘满即失败）
  记录在 `scripts/printer_probe.lua` 的输出里。

### 红石（`redstone.ko`）

CC 的红石 API 是函数式的（`redstone.getInput(side)` / `redstone.setAnalogOutput(side, v)`），
`redstone.ko` 把它摊成 Linux gpio 风格的 **sysfs 属性文件**（对应 `/sys/class/gpio/gpioN/{direction,value}`），
于是 shell 里 `cat` / `echo` 就能直接和红石打交道，不需要写 Lua 也不需要任何工具：

| 路径 | 含义 |
|---|---|
| `/sys/class/redstone/<side>/input` | 该面输入，读 `0`/`1`（`getInput`） |
| `/sys/class/redstone/<side>/analog_input` | 该面模拟输入，读 `0..15`（`getAnalogInput`） |
| `/sys/class/redstone/<side>/bundled_input` | 该面集束输入，读 `0..65535` 位掩码（`getBundledInput`） |
| `/sys/class/redstone/<side>/output` | 该面输出，读写 `0`/`1`（`getOutput`/`setOutput`） |
| `/sys/class/redstone/<side>/analog_output` | 该面模拟输出，读写 `0..15`（`getAnalogOutput`/`setAnalogOutput`） |
| `/sys/class/redstone/<side>/bundled_output` | 该面集束输出，读写 `0..65535` 位掩码（`getBundledOutput`/`setBundledOutput`） |

`<side>` 是 CC 的六个面 `top bottom left right front back` —— 六个面恒定存在（CC 电脑六面都能收发红石），
因此没有 Linux gpio 的 `export`/`unexport`。

- **用法**：`cat /sys/class/redstone/left/analog_input`、`echo 15 > /sys/class/redstone/left/analog_output`、
  `echo 32768 > /sys/class/redstone/back/bundled_output`（`black` = 32768，与 `colors.black` 一致；
  读也输出十进制掩码，与 `colors.combine`/`colors.subtract` 是同一套位掩码）。
- **输出语义与 CC 一致**：`output` 与 `analog_output` 是同一份输出状态 —— 写 `output=1` 后读
  `analog_output` 得 `15`，写 `analog_output=0` 后读 `output` 得 `0`。
- **写校验 fail-fast**：值必须是十进制整数且在范围内（`0x10`/`1e2`/负数/小数一律拒绝），
  非法写返回错误且**不改动**输出状态；`sh` 的 `echo` 把它报成 `echo: write error: invalid ...`
  并置退出码 1（见下文 `echo`），不会被静默吞掉。
- **事件**：不提供阻塞读（没有 `/dev/kmsg` 那种语义），要等红石变化就轮询；
  事件驱动的程序直接用 CC 的 `redstone` API（`os.pullEvent("redstone")`）。

### procfs（`/proc`）与进程管理

内核提供的进程/系统信息虚拟 fs（`src/kernel/procfs.lua`，boot 挂载；与 `/sys` 同层，**不由模块提供**）。
全部只读，文件内容是打开时的快照，读尽即 EOF（与 sysfs 属性句柄同一语义）。

| 路径 | 内容 |
|---|---|
| `/proc/<pid>/{cmdline,comm,cwd,stat,status}` | 单个进程的信息；进程退出后该目录立即消失 |
| `/proc/self/...` | 调用者自身 pid 的别名（Linux 是符号链接，Delin 无 symlink，当目录解析） |
| `/proc/mounts` | 挂载表：`<device> <mountpoint> <fstype> <options> 0 0` |
| `/proc/uptime` | 自引导起的秒数（Linux 还有第二个 idle 字段，Delin 不统计 idle，不提供） |
| `/proc/version` | `Delin OS <版本> (CraftOS <os.version>, Lua <_VERSION>)` |

- `stat` = Linux 字段 **1..8**：`pid (comm) state ppid pgrp session tty tpgid`。
  `state` 是 `R`（当前正在跑的那个进程）/`S`（存活但阻塞在事件上——Delin 无真正并发）/`T`（停止）；
  `tty` 是 tty 名（如 `tty0`）或 `0`（无控制终端；Linux 这里是 dev_t 编码）。
- `status` = Linux 的 `Name/State/Tgid/Pid/PPid/Pgrp/Session/Uid/Gid` 行；Delin 只有一个 uid/gid，
  因此 `Uid`/`Gid` 行只有一列（Linux 是 real/effective/saved/fs 四列）。
- `cmdline` = argv 以 NUL 分隔 + 结尾 NUL（Linux 语义）；`cwd` 是普通只读文件（Linux 是符号链接），
  仅属主或 root 可读。
- **不提供** `meminfo`/`cpuinfo`/`loadavg`/`fd` 等 —— Delin 没有对应数据源，不造假；
  `ps` 因此也没有 `TIME`/`%CPU`/`%MEM`/`VSZ`/`RSS`/`STIME` 列。
- **无 zombie 语义**：进程退出后其 `/proc/<pid>` 立即消失（Linux 保留 zombie 直到父进程 `wait`）。

**进程管理工具**：`ps`（POSIX ps + procps/GNU/BSD 常用子集，纯 `/proc` 消费者）、`pgrep`/`pkill`
（procps：按进程名/命令行查找、发信号）、`killall`（psmisc：按进程名发信号），加上已有的 `kill`。
`ps` 默认列出**本控制终端上属于本用户的进程**（POSIX 选择规则）；`-e`/`-A`/`ax` 全部，`-a` 带终端的
全部（不含会话首进程），`-x` 本用户全部，`-f`/`-l`/`u`(aux) 选格式，`-p PID`/`-t TTY`/`-u USER` 选择，
`-o FIELD,...` 自定义列（`pid ppid pgrp pgid sess uid user gid group stat state tty comm cmd args cwd`），
`--no-headers` 去表头；未知选项/未知列名 fail-fast（退出码 2）。默认输出 `PID TTY STAT COMMAND`，
`-f` 是 `UID PID PPID STAT TTY COMMAND`，`-l` 是 `STAT UID PID PPID PGRP SESS TTY COMMAND`，
`u`/`aux` 是 `USER PID PPID STAT TTY COMMAND`（无 TIME/%CPU/%MEM/VSZ/RSS/STIME 列）。
`pgrep`/`pkill` 的模式用 **Lua pattern**（与 grep/sed 同一约定，不是 POSIX ERE），`-x` 锚定整串、
`-f` 匹配完整命令行、`-n`/`-o` 取最新/最老（Delin 无启动时间，按 pid 大小）、`-u USER` 过滤用户，
两者都不匹配自己（Linux 语义）；`pkill` 默认 `SIGTERM`，`killall` 要求进程名完全相同（不杀自己）。

### 接口与工具（POSIX + GNU 子集）

**进程模型**：`pid/ppid/uid/gid`；`argv`（`[0]`=程序名，`[1..]`=位置参数）；会话（`sid`）与进程组
（`pgrp`）；`tcgetpgrp` 前台进程组；作业控制（`&` `jobs` `fg` `bg` `wait` `kill %job`）。
进程的退出码 = 协程返回值（数字），`proc.wait`/`$?` 由此得到；信号死亡记为 `128+signo`。

**信号**：POSIX 信号编号（`SIGHUP..SIGTTOU`，取 Linux x86-64 编号与默认动作/可捕获表）；
`kill [-SIG] pid|-pgid`、`kill -l`；终端 `^C`（`SIGINT`）/`^Z`（`SIGTSTP`）路由到前台进程组，
后台进程组读控制终端按 POSIX 投 `SIGTTIN` 并停止（`jobs` 显示 `Stopped`，`fg`/`bg` 可恢复）。

**文件系统**：进程所见 `fs/io` 走内核 VFS（真实磁盘 + 虚拟 `/dev` `/proc` `/sys` 同一命名空间）；
权限用 `mode`（八进制）+ `uid/gid`，`chmod`/`chown`，启动外部程序强制检查执行（`x`）位 ——
**root 也要文件至少有一个 `x` 位**（POSIX：root 绕过的是 `r`/`w` 检查，不绕过 `x`），否则 644 的
脚本 `./script` 也能跑起来。CC 原生文件系统（`ccdisk`）没有权限位，其文件一律视为可执行。

**用户**：`/etc/passwd` `name:x:uid:gid:fullname:home:shell`、`/etc/shadow` `name:salt$hash`、
`/etc/group`；`login` 提示用户名/密码（隐藏回显），验证通过后按该用户 `uid/gid` 起 `sh`。

**显示抽象**：进程面向设备文件而非库接口——`/dev/ttyN`（控制台）、`/dev/fbN`（帧缓冲）。

**终端（ANSI / `$TERM=linux`）**：每个 `/dev/ttyN` 都是 16 色 ANSI 字符终端，`write` 里的转义序列由
内核 tty 层解释（跨多次 `write` 保持状态；**未知/不支持的序列按真实终端惯例静默忽略**）：

| 能力 | 序列 |
|---|---|
| 颜色/属性 | `SGR(m)`：`0` 复位、`1` 粗体、`7`/`27` 反显、`22` 关粗体、`30-37`/`90-97` 前景、`40-47`/`100-107` 背景、`39`/`49` 回默认 |
| 清屏 | `ED(J)` `0` 光标到屏尾 / `1` 屏首到光标 / `2` 整屏（不移动光标）；`EL(K)` 同理按行 |
| 定位 | `CUP(H/f)` `行;列`（1 起，越界裁剪）、`CUU/CUD/CUF/CUB(A/B/C/D)`、`CHA(G)`、`VPA(d)`、`CNL(E)`、`CPL(F)` |
| 光标 | `?25h`/`?25l` 显示/隐藏、`ESC 7`/`ESC 8` 与 `CSI s`/`CSI u` 保存/恢复（位置+属性）、`ESC c` 复位（RIS） |

颜色按 VGA 风格 16 色映射到 CC 的 16 色：`30-37` → 黑/红/绿/棕/蓝/紫/青/浅灰，
`90-97` → 灰/粉/亮绿/黄/浅蓝/品红/青/白（CC 无亮红/亮青，取色相最近的粉/青）；
粗体（`1`）因 CC 无粗体字形而渲染成亮色。`$TERM` 固定为 `linux`（login 设置并随环境导出），
`login` 每次显示登录提示前写 `ESC[0m ESC[2J ESC[H` 清屏（agetty 语义）。

**工具**：`ls`、`cat`、`mkdir (-p)`、`rm (-r|-f)`、`cp (-r)`、`mv`、`touch`、`head (-n)`、`tail (-n)`、
`sleep`（GNU 风格：小数秒 + `s/m/h/d` 后缀 + 多操作数求和；50ms 分片睡眠，信号可及时打断）、
`wc (-l|-w|-c)`、`grep (-n|-i|-v)`、`sed`（GNU 子集：`s/y/d/p/q/a/i/c/=`、行号/`$`/正则地址与区间、
`!` 取反、`-n -s -e -f -i`）、`ed`（POSIX 子集：`a/i/c/d/p/n/l/s/t/m/r/w/q/u/g/v/=`、地址 `.` `$` n `/re/` `+n` `-n`、输入模式以 `.` 结束）、`kill`、
`ps`/`pgrep`/`pkill`/`killall`（进程管理，见上文「procfs 与进程管理」）、`login`、
`chmod`（八进制 + 符号模式 `[ugoa]*[+-=][rwx]*` + `-R` 递归）、`chown`（`[OWNER][:[GROUP]]` + `-R`）、
`mount`（挂载 `/dev/sdX`、`UUID=<uuid>` 或镜像路径；无 `-t` 时按设备类型；无参列出挂载含 `ro|rw`）、`umount`、
`blkid`（列出设备 UUID/TYPE/LABEL）、`lsblk`（树状列出设备/大小/类型/挂载点）、
`systemctl`（init 控制）、`syslogd`/`logger`/`dmesg`/`logrotate`（日志）、
`lp`（打印文件到 `/dev/lpN`）、`clear`（清屏：写 ANSI 复位+清屏+归位）、`sh`。
各工具支持 POSIX 的 **`--` 结束选项** 标记：`rm -- --help`、`touch -- -file`、`ls -- --ff` 等，用于操作以
`-`/`--` 开头的文件名；单独的 `-` 视为普通操作数。

**sh（POSIX 核心子集）**：变量与展开（`$x`/`${x}`/`$?`/`$#`/`$@`/`$*`/`$!`/`$-`/`$1..`）；单/双引号；
`if/elif/else`、`for`、`while`、`case`、函数（位置参数）、`[ ]`/`test`（`=` `!=` `-n` `-z` `-eq/-ne/-lt/-le/-gt/-ge`
`-e/-f/-d/-s/-x/-r/-w`、`!`）；`&&`/`||`/`;`；文件重定向（`>` `>>` `<`）；管道（`|`，每元素一个进程/内建，
经内核 pipe 缓冲传递，`$?`=末元素退出码，生产端写满/消费端读空时让出调度器，broken pipe 中止写端）；内建
`cd pwd echo read exit help jobs fg bg wait kill test [ true false : . set export unset break continue return shift`。
**启动变量**（可在 shell 里读写，`export` 后才传给子进程）：`PATH`（默认 `/bin`，命令查找用）、
`HOME`、`USER`、`LOGNAME`、`SHELL`（后两者取自 `/etc/passwd`）、`TERM`（默认 `linux`，随环境导出）、
`PPID`（内核给的父 pid）、
`PWD`（由 shell 维护，`cd` 后同步）、`IFS`；优先级为**继承的环境 > passwd/内核信息 > 内置缺省**
（`login` 先设 `USER`/`HOME`/`SHELL`/`PATH`/`TERM` 再起 `sh`，与 login(1) 一致）。
**提示符**：`PS1`（默认 `\u@\h:\w\$ `）、`PS2`（默认 `> `，续行）、`PS3`（默认 `#? `，保留）、
`PS4`（默认 `+ `，`set -x` 前缀）；展开 bash 风格转义 `\u \h \H \w \W \$ \# \! \s \n \t \d \e \\`，
未知转义原样保留，`\h` 取 `/etc/hostname`（缺失为 `delin`），`\w` 把 `$HOME` 缩成 `~`。
**`echo`**：POSIX + 扩展 `-n`（不换行）/ `-e`（解释转义 `\a \b \c \e \f \n \r \t \v \\ \0nnn \xHH`，
`\c` 截断且不换行，未知转义原样保留），例如 `echo -e '\e[31mred\e[0m'`；写失败（设备/属性文件/管道
句柄返回 `nil, err`）报 `echo: write error: ...` 并置退出码 1（POSIX），
因此 `echo 15 > /sys/class/redstone/left/analog_output` 的失败不会被静默吞掉。
**`cd`**：无参进 `$HOME`，`cd -` 回 `$OLDPWD` 并打印新目录，`PWD`/`OLDPWD` 随 `cd` 更新。
**`set`**（POSIX 特殊内建）：无参按名排序列出全部变量（`name='value'`，可重输入）；
`set -- a b`（或 `set a b`）设位置参数，`set --` 清空；选项 `-e`（errexit）/`-u`（nounset）/
`-v`（verbose，执行前回显命令原文）/`-x`（xtrace，执行前写 `PS4`+命令到 stderr），可合并（`set -ex`）、
`+` 关闭、`set -` 清 `-v/-x`；`set -o` 列选项状态、`set +o` 输出可重输入的 `set` 命令、
`set -o errexit` 按长名开关。`$-` 给出当前选项字母。
**`export`**（特殊内建）：`export NAME=value` 赋值并标记导出、`export NAME` 标记已存在变量、
`export -n NAME` 取消标记、`export`/`export -p` 列出（`export NAME='value'`）；导出的变量经内核
环境块传给子进程（外部程序用 `env.NAME` / `getenv("NAME")` 读），`&` 子 shell 也会被重新标记导出。
**`unset [-f] name...`**：删变量（默认）或函数（`-f`）。
**`. file [args...]`**（特殊内建）：在当前环境执行文件（变量/函数/`cd` 都作用于当前 shell，与 `sh file`
起子进程相对）；文件名不含 `/` 时查 `$PATH`；文件只需可读、不必可执行；给了参数则**临时**替换位置参数
（执行完恢复，`$0` 不变）；文件不存在/不可读/语法错误返回非 0。
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
PS2 提示继续读行；脚本/管道输入到 EOF 仍不完整则报 `syntax error: unexpected end of file`。
**命令查找**：含 `/` 的名字按 cwd 解析；否则按 `$PATH` 逐目录查（空条目 = 当前目录，`$PATH` 未设置时
用 `/bin`，置空则查不到）；找到但无可执行位报 `permission denied`，找不到报 `command not found`（127）。
脚本执行：`sh script.sh [args...]` 或 `./script.sh [args...]`（需 `+x`，经 `#!` shebang），
shebang 支持 `#!/bin/sh` / `#!/usr/bin/env sh` 等形式，env 特殊解释为查找后续程序名。
无 shebang 的文件按 Delin Lua 程序直接 spawn（兼容 `/bin/*` 工具源码）。
`>>`/`>` 写文件在命令结束后 `close` 提交到 ext2（handle 写入可能缓冲，需关闭才落盘）。
自检脚本：`scripts/posix_test.sh`（POSIX 可移植子集，宿主与真机各跑一次比对）、
`scripts/sh_builtin_test.sh`（内建/变量/选项自检，宿主用 harness 跑，真机由
`scripts/sh_verify.sh` + `verify-sh.service` 跑并写 `/var/log/sh_verify.log`）。

**已知偏离**：`grep`/`sed` 的正则用 **Lua pattern**（`%` 为转义符、`()` 为捕获）而非 POSIX ERE/BRE；
替换区用 `&`=整串匹配、`\1..\9`=捕获组、`\n/\t`，不支持 BRE 风格 `\(...\)` 与模式内逆引用。
注意 Lua pattern 里 `-` 是量词（非贪婪），要匹配字面连字符需 `%-`，与 GNU grep 的 `-`（字面）不同。
不支持**命令替换 `$()`/反引号**、**算术 `$(( ))`**、**here-doc `<<`**（暂未实现，遇到即语法错误）。
`&` 的子 shell 是重新执行的进程（无 fork）：父 shell 的变量与函数定义经赋值/定义语句注入，
但 `$?` 在子 shell 里从 0 开始（不继承父 shell 的最后状态）。`VAR=value cmd` 的赋值在命令词
展开**之前**生效（POSIX/bash 是展开之后，故 `x=0; x=1 echo $x` 在 Delin 打印 1、在 bash 打印 0）；
`read` 无法区分“末行无换行”（句柄 API 限制，按成功计）。
`set -x` 只跟踪**简单命令**（含赋值/重定向），不打印 `for`/`if` 这类复合关键字行；
`set -u` 的检查发生在命令执行前（未执行的分支不报错），交互式只丢弃当前命令、非交互式退出；
子 shell 的 `$PPID` 取内核给的父 pid（不继承环境里的 `PPID`）；`.` 的参数按 bash 语义临时替换位置参数
（dash 忽略它们）；未实现 `export -f`（函数导出）、`readonly`、`$()`/反引号命令替换。
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
宿主测试台 `tools/hosttest.lua`（361 项）与真机脚本 `tools/realmachine.py` +
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
终端侧：tty 层解释 ANSI 转义（SGR 16 色/ED-EL 清屏/CUP 定位/光标显隐与保存恢复，见上文
「终端（ANSI / `$TERM=linux`）」），`$TERM=linux` 随环境导出，`echo` 支持 `-n`/`-e`，新增 `/bin/clear`，
`login` 每次提示前清屏。
`scripts/posix_test.sh`（122 项）与 `scripts/jobctl_test.sh` 在宿主与 Delin 上各跑一次逐项比对，
`scripts/sysinfo.sh` 演示实用用法。

打印机经 `ccprinter` 模块抽象成 `/dev/lpN` 字符设备（`cat f > /dev/lp0` / `lp f` 即打印，折行与
满页翻页由内核负责）+ `/sys/class/printer/<lpN>` 状态与页标题，`/bin/lp` 是 POSIX lp(1) 子集。
sysfs 也从 display 专用泛化成 class 注册表（模块用 `kapi.registerSysfsClass` 注册自己的类）。

进程可见性落地：内核 `procfs`（`/proc/<pid>/{cmdline,comm,cwd,stat,status}` + `/proc/self` +
`/proc/{mounts,uptime,version}`，boot 挂载，只读、读尽即 EOF），配套 `ps`（默认/`-e`/`-f`/`-l`/`aux`/
`-p`/`-t`/`-u`/`-o`/`--no-headers`）、`pgrep`/`pkill`（`-f`/`-x`/`-v`/`-n`/`-o`/`-u` + 信号）、
`killall`（`-e`/`-q`/`-u`/`-l`）—— 全部是 `/proc` 的消费者，不额外开 syscall。
`scripts/proc_test.sh`（41 项）在宿主 harness 与真机上各跑一次逐项比对。

红石经 `redstone` 模块摊成 sysfs 属性文件 `/sys/class/redstone/<side>/{input,output,analog_input,
analog_output,bundled_input,bundled_output}`（六个面恒定存在），`cat`/`echo` 即读写；
写值严格校验（十进制整数 + 范围），非法写 fail-fast 且不改动输出状态。
`scripts/redstone_test.sh`（50 项）在宿主 harness 与真机上各跑一次逐项比对，
`scripts/redstone_verify.lua` 在真机上以 CC 原始 `redstone` API 为真值逐项交叉核对。

### 引导

代码经 `tools/bundle.lua` 打包成自包含 Lua 文件部署。**引导契约**：CraftOS 开机执行电脑自身 FS 的
`/startup.lua`；Delin BIOS（`src/bios/startup.lua`，装到 `/startup.lua`）会扫描所有设备找 `/.boot`，
读出里面的路径并 `loadfile` 执行——`/.boot` 的内容就是引导设备上那个"内核入口"文件的路径
（如 `/boot/delin.lua`）。BIOS 启动前有 0.1s 窗口，按 `DELETE` 进 BIOS 设置（`C` 进 CraftOS shell），
无 `/.boot` 的设备不会被选为引导设备。

两条引导路径：

- **CC-fs 引导**（默认）：`kernel.lua` 直接跑 `boot.boot()`——`setupVfs` 挂根 hdd 到 `/` +
  `mountDev` + `klog.register`（`/dev/kmsg`、`/dev/log`）+ `procfs.mount` 挂 `/proc` →
  `setupDevices` 扫描磁盘驱动器注册
  `/dev/sdX` 节点（不自动挂载）→ `registerConsole` 把电脑自身 `term` 注册为 `/dev/ttyN` 控制台
  （并派生 `/dev/console`）→ `setupUsers` 从**根的** `/etc/{passwd,shadow,group}` 建用户库并注册
  `user.*` syscalls → `setupModules` 从**根的** `/lib/modules/<version>/` 装模块
  （`loadAll` + `loadAliases` + 按外设 autoload 驱动，modprobe 风格 `modules.use`）→
  `sysfs.mount` 挂 `/sys` → `launch` 出 PID 1（用户态 init）。
  根是电脑自身 FS，因此用户库与模块都**只**来自电脑自身 FS，不扫描磁盘（fail-fast）。
- **EXT2 根引导**（GRUB 风格，DLUB 独立文件）：先由 `dlub.lua` 读**电脑自身 FS** 的 `/dlub.cfg`
  配置文件，支持两种启动模式：
  1. **外部磁盘启动**（`bootdisk <外设名>`，如 `bootdisk left`）：锁定引导盘——多磁盘时
     `peripheral.getNames()` 顺序不可靠（数据盘可能先被枚举到），因此**不扫描、不回退**：
     配置缺失/语法错误/该外设不是磁盘驱动/盘上无 `/parts/manifest` 一律 fail-fast 报错。
  2. **电脑自带存储启动**（`rootfs <路径>`，如 `rootfs /parts/root.img`）：从电脑自带存储的
     ext2 镜像启动，适用于需要从本地存储启动的场景。

  两种模式都会读取 ext2 分区，挂载根文件系统，读内核镜像并设 `_G.__boot_info`；`boot.boot()`
  检测到 `__boot_info` 即走 `bootExt2`——挂 ext2 根为 `/`，`setupUsers` 从根的 `/etc/passwd`
  建用户库，模块只从 ext2 根镜像自带的 `/lib/modules/<version>/` 装载（自包含，fail-fast，
  绝不回退到引导盘/CC fs 的 `/lib`）。两条路径最后都 spawn 同一份 init 源码，随后由 init 启动
  `default.target`。

  两条路径的**用户库与模块装载是同一段代码**（`setupUsers`）：少一处就会出现
  "login 拿不到 `user.verify` → 立刻退出 → getty 重启风暴" 这种只在真机上看得见的故障。
  根上没有 `/etc/passwd` 一律 fail-fast 报错（没有用户库等于登录不了，不静默降级）。

真机流程：`tools/realmachine.py`（**先关机** → 打包 → `tools/deploy.py` 重建 ext2 根镜像 → 注入第二个 ext2 分区
供 fstab 测试 + `verify.service` → `e2fsck -fn` 门禁 → 装盘并按 md5 校验 → 开机 → 用 `debugfs`
从镜像取回 `/var/log/*` → 再停机 fsck 一次）；`scripts/realmachine_verify.sh` 是它在真机上跑的验证脚本。

部署到电脑4：`tools/deploy_to_computer4.py`（支持两种启动模式）：
- `python3 tools/deploy_to_computer4.py --mode rootfs --rootfs /parts/root.img`（从电脑自带存储启动）
- `python3 tools/deploy_to_computer4.py --mode bootdisk --bootdisk left`（从外部磁盘启动）

**部署的两条硬约束**（踩过的事故，别改回去）：

- **机器必须先停**。读基镜像（live `/parts/root.img`）和写盘都在停机状态下进行：曾经先覆盖 `root.img`
  再关机，机器还在跑 ext2 测试并写同一张盘，两边写入交错，盘上的镜像变成"新镜像数据块 + 旧镜像
  inode 表"的混合体，`/lib`、`/home` 整个目录读不出来。装盘后还会逐文件按 md5 回读校验。
- **属主以基镜像为准**。`rdump` 以非 root 运行时无法恢复 uid/gid，`debugfs mkdir/write` 一律建成
  root:root，所以 `deploy.py` 会先用 `debugfs ls -l -p` 把基镜像的 `path -> (uid,gid)` 读出来，
  逐条 `set_inode_field uid/gid` 写回；基镜像里没有的路径默认 root:root。因此**基镜像的属主就是
  权威来源**，现在用 `/mnt/bak/root.base.img`（干净的 rootfs，`/home/alice` 已是 1000:1000）。
  基镜像损坏时 deploy 直接失败（debugfs 遇到坏目录只打印错误、退出码仍是 0，会静默漏掉整个目录，
  历史上就是这样丢掉 `/lib` 的）。

### 设计要点

- **并发**：内核自持 `os.pullEventRaw` 循环，`coroutine.create/resume` + 按协程 yield 的 filter
  分发事件；进程经原始 API（`os.sleep`/`os.pullEvent`/`fs`……）yield，调度器驱动。
- **时钟与让出**：`cc_hse` 时钟走**拉模式**（`setPushEvents(false)` + 按需 `waitNextTick`）。
  推送模式 @2kHz 会在 ~128ms 内塞满电脑事件队列（上限 256），CC 对满队列静默丢弃 —— 长命令
  输出期间的按键（字符/切 tty/`^C`）就是这样被丢掉的。`os.msleep(0)` 是一次按需 tick 让出
  （≥2ms，`ms>=50` 走 CC 定时器），工具与 `sh` 只在 ~50ms 时间片边界让出；内核另有 0.05s 调度
  心跳，保证裸让出（`filter=nil`，如 `tty.readLine`）的进程在空闲期也能推进。
- **隔离环境（白名单）**：每个进程有自己的 `_ENV`（`load(src, name, "t", env)`），注入内核上下文
  `spawn`/`pid`/`ppid`/`uid`/`gid`/`syscalls`。环境**没有 `__index = _G` 兜底** —— 只给
  `src/kernel/procenv.lua` 列出的名字：Lua 标准库（`string/table/math/coroutine/os` 子集，且都是
  进程私有副本，进程改副本影响不到内核与其它进程）、`fs`/`io`（VFS 门面）、`syscalls`、`print`
  与一批"不绕过 Delin 接口"的 CC API（`term`/`write`/`read` ≈ 直连控制台、`colors`/`keys`/
  `vector`/`textutils`/`parallel`/`window`/`paintutils`、`redstone`、`rednet`/`gps`/`http`）。
  需要**在内核层**一次关掉的逃逸渠道（它们绕过 VFS/设备文件/内核，只在用户层打补丁既漏又散）：
  `loadfile`/`dofile`/`os.run`（读电脑自身 FS 执行）、`require`/`package`/`os.loadAPI`（原生模块）、
  `settings`（原生 FS 配置）、`shell`/`commands`/`multishell`/`help`（CC ROM 程序，直接在电脑自身
  FS 上增删文件）、`disk`（`getMountPath` 绕过 `/dev/sdX` 与 `mount`）、`peripheral`/`pocket`
  （裸外设，绕过 `/dev` 与 `/sys`）、`os.pullEvent`/`pullEventRaw`/`queueEvent`（偷/伪造内核事件，
  可窃取键盘事件或向别的 tty 注入按键）、`os.shutdown`/`os.reboot`（电源）、`debug`（只留
  `debug.traceback`，整个 debug 可经 registry 逃出沙箱）。用到就是 `nil`（fail-fast，报错落在调用点）。
- **环境块（`export` 的落点）**：进程环境里注入 `env`（`name -> string` 的表）与 `getenv(name)`；
  spawn 时从父进程**继承**，`opts.env` 覆盖/追加（值为 `nil` 即删除）。`sh` 的 `export` 变量、
  `login` 设置的 `USER`/`HOME`/`SHELL`/`PATH` 都走这里，外部程序用 `env.PATH` / `getenv("PATH")` 读。
- **`spawn` 只收源码字符串**：`spawn(src, name?, uid?, gid?, argv?, opts?)` 在隔离 `_ENV` 里建子进程；
  读文件由程序自己做；`argv`（`[0]`=程序名）与 `arg0`/`args`/`argc` 直接注入子进程环境，
  `opts = { cwd=, stdio={input=,output=}, env={NAME=value} }`。
- **进程树 + 会话/进程组**：`{ pid, ppid, status, children, pgrp, sid, sig }`；父死子并入 init；
  信号经调度器在 resume 前投递（`setSignalCheck`）。
- **print 覆盖**：内核自供 `print`（写 klog + 引导日志 + 终端），因 CC 自带 `print` 不走 `io.stdout`；
  进程 `print` 记 user.info，内核消息记 kern.info。
- **stdio 按进程隔离**：每个进程有自己的 `stdin/stdout`；spawn 时从父进程继承（或 boot 默认终端），
  `stdio.set` 只改当前进程；`io.write/read` 经 `vfs_api.setStdio` 兜底到终端。
  进程退出时内核**只关带 `.pipe` 标记的管道端**（递减 writer/reader 计数，让对端读到 EOF）——
  重定向的文件/设备句柄是父进程打开后共享给子进程的，子进程退出只让引用消失，由打开者自己关
  （POSIX fd 语义；`cat f > /dev/lp0` 的 `endPage` 因此由 sh 在进程上下文里触发，
  而不是内核的退出清理——CC 的 mainThread 外设方法在内核上下文里调用会挂住机器）。
- **tty 焦点切换**：只有前台 tty 接收键盘。`Ctrl+Alt+1..0` 切换前台 tty，多 tty 共用一把键盘；
  行缓冲 + 回显（canonical 行规程），焦点 tty 收到 `^C`/`^Z` 时把信号投给其前台进程组。
- **getty/login**：init 为每个 `/dev/ttyN` 实例化 `getty@ttyN.service`（`ExecStart=/bin/login %I`）；
  login 每次显示登录提示前用 ANSI 清屏（`ESC[0m ESC[2J ESC[H`，agetty 语义），验证后按用户
  `uid/gid` 起 `sh`（同 tty stdio，环境含 `TERM=linux`），`sh` 退出后回到 login 循环；
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
lua5.1 tools/hosttest.lua        # 宿主测试: init 引擎/fstab/syslogd/logrotate/systemctl/sysfs/ccprinter/procfs/tty-ANSI/redstone (361 项)
lua5.1 tools/harness.lua /bin/sh # 宿主上跑真实工具源码(sh/作业控制/管道; /sys 走真实 sysfs 后端, /proc 走真实 procfs 后端)
lua5.1 tools/harness.lua /bin/sh < scripts/proc_test.sh   # /proc + ps/pgrep/pkill/killall 自检(与真机比对)
lua5.1 tools/harness.lua /bin/sh < scripts/redstone_test.sh   # /sys/class/redstone 读写/校验自检(与真机比对)
lua5.1 tools/harness.lua /bin/sh < scripts/lua_test.sh   # /bin/lua 脚本/stdin/arg/dofile/退出码 + 进程环境白名单(与真机比对)
sh scripts/lua_repl_test.sh        # /bin/lua 交互式 REPL(宿主专用: DELIN_HARNESS_TTY=1 伪装终端)
lua5.1 tools/ext2test.lua        # ext2 驱动宿主回归: 真实镜像上跑目录增删, 再用宿主 e2fsck -fn 判定
python3 tools/realmachine.py --base /mnt/bak/root.base.img   # 真机: 先关机->打包->部署->重启 #3->取回 /var/log/*
python3 tools/realmachine.py --printer   # 真机 + 打印机(会实际打印页面): 探测 printer API + 验证 /dev/lp0
```

`realmachine.py` 最后会停机再对安装到磁盘的 `root.img` 跑一次 `e2fsck -fn`：**跑一轮后 fsck 必须干净**，
不干净就整体失败（这是"Delin 自己把文件系统写坏了"的判据）。

## 约定

- 源码用 **EmmyLua** 注解仅为人类维护 / IDE 提示，不作为任何门禁；其警告与报错忽略。
- **终端输出一律只用 ASCII**：CC 终端打印中文会乱码，因此 `sh`/工具/内核面向终端或 stderr 的
  字符串（错误消息、`help`、提示符、日志）不得含中文；注释、README、测试日志可以中文。
- git 提交使用本仓库 local config。

## 目录

```
src/kernel/version.lua     版本号唯一真源(`return "x.y.z"`, 同时是 /lib/modules/<version>/ 的目录名)
src/bios/startup.lua       Delin BIOS(装到电脑自身 FS 的 /startup.lua): 扫描设备的 /.boot -> loadfile
                           引导入口; DELETE 进设置 TUI, C 进 CraftOS shell
src/kernel/scheduler.lua   协程调度器(事件循环) + resume 前信号投递
src/kernel/process.lua     进程表/进程树/spawn/隔离 env + cwd + argv + 会话/进程组/信号/作业控制
                            + 子进程退出钩子(init 服务监督) + opts.ppid
src/kernel/procenv.lua     进程环境白名单: 只把列出的 CC/Lua 全局给进程(无 __index=_G 兜底),
                           在内核层封掉 loadfile/dofile/os.run/require/settings/shell/disk/peripheral
                           /os.pullEvent/queueEvent/shutdown 等绕过 Delin 接口的渠道
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
                            + ANSI 转义(SGR 颜色/ED-EL 清屏/CUP 定位/光标显隐与保存恢复)
src/kernel/fb.lua          软件帧缓冲(/dev/fbN): 32 位 ARGB 像素缓冲+脏矩形 flush
src/kernel/sysfs.lua       /sys 虚拟配置 fs(sysfs 风格, class/display 子树, 读=查/写=设)
src/kernel/procfs.lua      /proc 虚拟进程/系统信息 fs: <pid>/{cmdline,comm,cwd,stat,status} + self
                           + {mounts,uptime,version}, 只读, 读尽即 EOF(ps/pgrep/pkill/killall 的数据源)
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
src/bin/ps                 报告进程状态, 数据源 /proc (POSIX ps + procps/GNU/BSD 常用子集:
                           默认/-e/-A/-a/-x/-f/-l/u(aux)/-p/-t/-u/-o/--no-headers; 无 TIME/%CPU/%MEM 列)
src/bin/pgrep              按进程名/命令行查找进程 (procps pgrep 子集: -f -x -v -l -a -n -o -u; Lua pattern)
src/bin/pkill              按进程名/命令行发信号 (procps pkill 子集: -SIG/-s/--signal + pgrep 的选择项)
src/bin/killall            按进程名给所有同名进程发信号 (psmisc killall 子集: -SIG/-s/-l/-e/-q/-u)
src/bin/chmod              修改文件权限 (八进制+符号模式 [ugoa]*[+-=][rwx]*; 以 - 开头的符号模式
                           也成立: chmod -x/-wx/-r 与 GNU 一致, 递归只有 -R)
src/bin/chown              修改文件属主/属组 ([OWNER][:[GROUP]], -R 递归)
src/bin/mount              挂载 /dev/sdX、UUID=<uuid> 或镜像路径 (-a 按 fstab; 无 -t 按设备类型; 无参列出)
src/bin/umount             卸载文件系统 (umount <dir>|<-device>)
src/bin/blkid              列出块设备的 UUID/TYPE/LABEL (util-linux blkid 子集)
src/bin/lsblk              树状列出块设备: NAME/SIZE/TYPE/MOUNTPOINT (util-linux lsblk 子集)
src/bin/login              getty/login: 清屏+登录提示->验证->启动 sh->循环
src/bin/clear              清屏 (POSIX clear(1): 写 ANSI 复位+ED 2+CUP 归位)
src/bin/sleep              暂停指定时间 (GNU 风格: 小数秒 + s/m/h/d 后缀 + 多操作数求和)
src/bin/systemctl          控制 init: list-units/status/start/stop/restart/enable/disable/is-active/daemon-reload
src/bin/syslogd            系统日志守护进程: /dev/kmsg+/dev/log -> /etc/syslog.conf 规则 -> /var/log/*
src/bin/logrotate          日志轮转 (logrotate(8) 子集: size/daily/rotate/create/notifempty/missingok)
src/bin/logger             写一条消息到 /dev/log (util-linux logger 子集)
src/bin/dmesg              打印内核 ring buffer (/dev/kmsg)
src/bin/lp                 打印文件 (POSIX lp(1) 子集: -d 设备 -t 标题, 无文件读 stdin)
src/bin/lua                Lua 解释器: 无参进交互式 REPL(> / >> 提示符, =expr, 裸表达式按 return
                           求值并打印, 未完成语句续行, ^D 退出, ^C 取消输入行), 否则运行脚本
                           (lua [script [args...]], `-` 读 stdin; arg[-1]/arg[0]/arg[1..] 与变参 ...
                           同 lua(1); 顶层 return 数字 = 退出码; dofile/loadfile 走 Delin VFS;
                           print 在本环境里改写 stdout; stdin 非终端时整个 stdin 当一个 chunk)
src/bin/sh                 交互/脚本 shell(POSIX 核心子集: 变量/IFS/引号/if/for/while/case/函数/test/[ ]/&&/||
                           /重定向/管道/作业控制(& jobs fg bg wait kill %job)/read, 支持 -c 与 shebang 脚本)
src/units/*                厂商单元文件 -> /lib/systemd/system/ (default/multi-user/local-fs/getty/timers
                           target, syslogd.service, getty@.service, logrotate.service/.timer)
src/etc/{fstab,syslog.conf,logrotate.conf}  系统配置 -> /etc/
src/etc/{passwd,shadow,group}  初始用户库 -> /etc/ (root + alice:1000)。全新安装必须自带,
                           否则装完没有任何用户能登录 (boot 会 fail-fast 报 /etc/passwd not found)
src/modules/*.ko           内核模块: ccdisk(ccdisk fstype) ccmonitor(CC 显示器驱动) ccprinter(CC 打印机 ->
                           /dev/lpN + sysfs printer 类) cc_hse(HSE 时钟拉模式 os.msleep) demo(演示)
                           ext2(ext2 fstype) redstone(CC 红石 -> sysfs redstone 类) tom(Tom GPU 驱动)
                           void(Void 全息驱动)
src/modules/modules.alias  驱动别名(modprobe 风格): tm_gpu->tom hologram->void monitor->ccmonitor printer->ccprinter
src/modules/manifest       默认装载模块清单: demo ext2 ccdisk redstone
scripts/posix_test.sh      可移植 POSIX 自检(host 与 Delin 各跑一次比对, 122 项全过)
scripts/jobctl_test.sh     作业控制自检(& / $! / jobs / fg / bg / wait / kill %job, host 与真机各跑一次)
scripts/sysinfo.sh         实用小工具: 系统信息(变量/函数/for/case/if/重定向/工具)
scripts/proc_test.sh       /proc + ps/pgrep/pkill/killall 自检(host harness 与真机各跑一次比对, 41 项)
scripts/redstone_test.sh   /sys/class/redstone 读写/校验自检(host harness 与真机各跑一次比对, 50 项)
scripts/lua_test.sh        /bin/lua 自检(host harness 与真机各跑一次比对, 107 项): 脚本/stdin/arg/变参/
                           dofile+loadfile/错误消息与退出码/shebang/进程环境白名单
scripts/lua_repl_test.sh   /bin/lua 交互式 REPL 自检(宿主专用: 测试台把 stdin 伪装成终端,
                           覆盖提示符/表达式自动打印/续行/报错/SIGINT/_PROMPT/EOF 退出码, 16 项)
scripts/redstone_verify.lua  真机交叉核对: /sys/class/redstone/* 与 CC 原始 redstone API 逐项一致
                           (写 /var/log/redstone_verify.log; 由 realmachine_verify.sh 调用)
scripts/realmachine_verify.sh  真机验证脚本(由 verify.service 以 oneshot 运行, 结果写 /var/log/verify.log)
scripts/printer_probe.lua  真机探测 CC printer 原始 API 语义(页尺寸/写不折行/开页扣纸墨), 写 /var/log/printer_probe.log
scripts/printer_verify.sh  真机验证 ccprinter 模块(/dev/lp0 + /sys/class/printer, 会实际打印), 写 /var/log/printer_verify.log
tools/bundle.lua           打包 src/ -> dist/kernel.lua 或 dist/dlub.lua(init 多文件拼成一个 chunk)
tools/harness.lua          host 测试台: 用真实 Delin 工具源码在宿主跑(fs/io/syscalls/spawn 桩,
                           含信号/进程组语义: kill/killpg/SIGCONT/stopped, 供 sh 作业控制验证;
                           /sys 与 /proc 走真实 kernel.sysfs/kernel.procfs 后端 + 桩显示设备
                           + 桩 printer(/dev/lp0) + 桩 redstone API(加载真实 redstone.ko)
                           + 桩进程表(ps/pgrep/pkill/killall);
                           进程环境用内核同一份白名单(src/kernel/procenv.lua), 不放宽)
tools/hosttest.lua         宿主测试: init 单元引擎/fstab 生成/syslogd 规则/logrotate 轮转/systemctl/sysfs/ccprinter/procfs/tty-ANSI/redstone(361 项)
tools/ext2test.lua         宿主 ext2 回归: 真实镜像上跑目录增删(空洞/links/回收), 宿主 e2fsck -fn 判定
tools/deploy.py            重建干净 ext2 根镜像(基镜像+内核/bin/单元/配置/标记), 属主按基镜像逐条写回;
                           基镜像损坏/rdump 漏文件/构建后 fsck 不过一律 fail-fast
tools/realmachine.py       真机流程: 先关机->打包->部署->注入第二分区与 verify.service->fsck 门禁->
                           装盘并 md5 校验->开机->debugfs 取回日志->停机后再 fsck
                           (--printer 额外注入打印机探测/验证服务)
dist/                      生成物(不提交)
```
