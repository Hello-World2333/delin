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
| `/bin/` | 用户工具：`cat ls mkdir rm cp mv touch head tail wc grep sed kill login sh` |
| `/dev/` | 设备文件：`/dev/ttyN`（字符终端）、`/dev/fbN`（像素帧缓冲）、`/dev/sdX`（磁盘，见下）、`/dev/null`（读 EOF/写丢弃） |
| `/etc/` | 用户/组配置：`passwd` `shadow` `group` |
| `/proc/` | 虚拟进程/系统信息 fs（由模块提供） |
| `/sys/` | sysfs 挂载点（虚拟）；`/sys/class/display/` 下每设备一个目录，`name/type/size` 只读，分辨率/位置/旋转/缩放 可读写 |
| `/lib/modules/<version>/` | 内核模块目录：`.ko` 模块 + 纯文本 `manifest` + `modules.alias` |
| `/mnt/` | 挂载点（`mount /dev/sdXN /mnt` 显式挂载；启动时不自动挂载任何磁盘） |
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
`wc (-l|-w|-c)`、`grep (-n|-i|-v)`、`sed`（GNU 子集：`s/y/d/p/q/a/i/c/=`、行号/`$`/正则地址与区间、
`!` 取反、`-n -s -e -f -i`）、`ed`（POSIX 子集：`a/i/c/d/p/n/l/s/t/m/r/w/q/u/g/v/=`、地址 `.` `$` n `/re/` `+n` `-n`、输入模式以 `.` 结束）、`kill`、`login`、
`chmod`（八进制 + 符号模式 `[ugoa]*[+-=][rwx]*` + `-R` 递归）、`chown`（`[OWNER][:[GROUP]]` + `-R`）、
`mount`（挂载 `/dev/sdX`、`UUID=<uuid>` 或镜像路径；无 `-t` 时按设备类型；无参列出挂载）、`umount`、
`blkid`（列出设备 UUID/TYPE/LABEL）、`lsblk`（树状列出设备/大小/类型/挂载点）、
`sh`。
各工具支持 POSIX 的 **`--` 结束选项** 标记：`rm -- --help`、`touch -- -file`、`ls -- --ff` 等，用于操作以
`-`/`--` 开头的文件名；单独的 `-` 视为普通操作数。

**sh（POSIX 核心子集）**：变量与展开（`$x`/`${x}`/`$?`/`$#`/`$@`/`$*`/`$!`/`$1..`）；单/双引号；
`if/elif/else`、`for`、`while`、`case`、函数（位置参数）、`[ ]`/`test`（`=` `!=` `-n` `-z` `-eq/-ne/-lt/-le/-gt/-ge`
`-e/-f/-d/-s/-x/-r/-w`、`!`）；`&&`/`||`/`;`；文件重定向（`>` `>>` `<`）；管道（`|`，每元素一个进程/内建，
经内核 pipe 缓冲传递，`$?`=末元素退出码，生产端写满/消费端读空时让出调度器，broken pipe 中止写端）；内建
`cd pwd echo exit help jobs fg bg wait kill test [ true false : break continue return shift`。
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
但 `$?` 在子 shell 里从 0 开始（不继承父 shell 的最后状态），`read` 内建尚未实现。
因 CC 5.2 无位运算，`/etc/shadow` 哈希用盐+密码的 32 位滚动哈希（djb2）替代传统 `crypt`。

## 当前状态

v0.0.1 的协程调度内核 + 进程树之后，已扩展为具备 VFS、块设备、EXT2 读写、显示抽象、模块系统与
用户/权限的迷你系统。所有子系统自持事件循环，由内核调度器驱动；进程跑在隔离 `_ENV` 里，经注入的
内核上下文（`spawn`/`pid`/`ppid`/`uid`/`gid`/`syscalls`）访问内核能力，其余原始 CC API 直用。

`src/bin/sh` 已升级为 POSIX 核心子集（变量/引号/if/for/while/case/函数/test/[ ]/&&/|| /文件重定向/管道
`|`，无命令替换 `$()`、算术 `$(( ))`），支持脚本执行（`sh script.sh` / `./script.sh`，`#!` shebang）、
`rm`/`mkdir` 补了 GNU `-r/-f`/`-p`；新增 `chmod`（八进制 + 符号模式 + `-R`）、`chown`（`owner:group` + `-R`）、
`mount`（挂载 `/dev/sdX`、`UUID=` 或镜像路径 / 无参列出）/ `umount` / `blkid` / `lsblk`；磁盘驱动器
经 `devdisk` 抽象为 `/dev/sda`（整盘 ccdisk）与 `/dev/sdaN`（manifest 分区 ext2）设备节点，UUID 用磁盘 ID
模拟，启动时不再自动挂载磁盘。作业控制落地：`&` 后台作业 + `jobs`/`fg`/`bg`/`wait`/`kill %job`/`$!`、
前台作业进程组与 `^C`/`^Z` 路由、后台进程组读 tty 的 `SIGTTIN`、`/dev/null`、`sh -c`。
`scripts/posix_test.sh`（97 项）与 `scripts/jobctl_test.sh` 在宿主
与 Delin 上各跑一次逐项比对，`scripts/sysinfo.sh` 演示实用用法。可经
`tools/harness.lua`（宿主）或 `tools/deploy.py`（真机）验证；真机自检在 `src/init/ext2_init.lua`
（非交互作业控制、假 tty 会话下的交互作业控制、真 tty0 的 `^Z`/`^C` 前台路由与 `SIGTTIN`）。

### 引导

代码经 `tools/bundle.lua` 打包成自包含 Lua 文件部署。两条引导路径：

- **CC-fs 引导**（默认）：`kernel.lua` 直接跑 `boot.boot()`——`setupVfs` 挂根 hdd 到 `/` →
  `setupDevices` 扫描磁盘驱动器注册 `/dev/sdX` 节点（不自动挂载）→ `registerConsole` 把电脑自身
  `term` 注册为 `/dev/ttyN` 控制台 → `setupModules`
  从 `/lib/modules/<version>/` 装模块（`loadAll` + `loadAliases` + 按外设 autoload 驱动，
  modprobe 风格 `modules.use`）→ `sysfs.mount` 挂 `/sys` → `launch` 出 PID 1（init）。
- **EXT2 根引导**（GRUB 风格，DLUB 独立文件）：先由 `dlub.lua` 读**电脑自身 FS** 的 `/dlub.cfg`
  （`bootdisk <外设名>`，如 `bootdisk left`）锁定引导盘——多磁盘时 `peripheral.getNames()` 顺序
  不可靠（数据盘可能先被枚举到），因此**不扫描、不回退**：配置缺失/语法错误/该外设不是磁盘驱动/
  盘上无 `/parts/manifest` 一律 fail-fast 报错。再读该盘 `/parts/manifest`，按清单把 root 分区开成
  块设备、挂 ext2、读内核镜像并设 `_G.__boot_info`；`boot.boot()` 检测到
  `__boot_info` 即走 `bootExt2`——挂 ext2 根为 `/`（挂载表里显示为对应的 `/dev/sdXN`），读
  `/etc/passwd` 建用户库，模块只从 ext2 根镜像
  自带的 `/lib/modules/<version>/` 装载（自包含，fail-fast，绝不回退到引导盘/CC fs 的 `/lib`）。

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
- **print 覆盖**：内核自供 `print`（写日志 + 终端），因 CC 自带 `print` 不走 `io.stdout`。
- **stdio 按进程隔离**：每个进程有自己的 `stdin/stdout`；spawn 时从父进程继承（或 boot 默认终端），
  `stdio.set` 只改当前进程；`io.write/read` 经 `vfs_api.setStdio` 兜底到终端。
- **tty 焦点切换**：只有前台 tty 接收键盘。`Ctrl+Alt+1..0` 切换前台 tty，多 tty 共用一把键盘；
  行缓冲 + 回显（canonical 行规程），焦点 tty 收到 `^C`/`^Z` 时把信号投给其前台进程组。
- **getty/login**：init 在每个 `/dev/ttyN` 上起 `login`；login 验证后按用户 `uid/gid` 起 `sh`
  （同 tty stdio），`sh` 退出后回到 login 循环。
- **设备与文件系统分层**：`devdisk` 只负责「有哪些设备」（枚举磁盘 → `/dev/sdX` + UUID 解析 + 挂载表），
  文件系统实现由模块用 `kapi.registerFstype(name, fn)` 注册（`ext2.ko` → `ext2`，`ccdisk.ko` → `ccdisk`）；
  `mount -t <type>` 找不到处理器即报错（fail-fast，无回退）。

## 构建

```bash
lua5.1 tools/bundle.lua kernel   # 生成 dist/kernel.lua（内核 bundle）
lua5.1 tools/bundle.lua dlub     # 生成 dist/dlub.lua（DLUB 引导装载器，独立文件）
```

内核 bundle 复制到引导盘 `bootPath`（manifest 的 `boot` 行，默认 `/boot/delin.lua`）；DLUB 复制到
引导盘的引导脚本入口。DLUB 还需在**电脑自身 FS** 写 `/dlub.cfg` 指定引导盘外设名（如 `bootdisk left`），
缺失或非法时 DLUB 直接报错、不猜测。产物均以 Lua 5.2+ `_ENV` 技巧打包，每个模块包一层 `__require`
到内部 shim。

## 约定

- 源码用 **EmmyLua** 注解仅为人类维护 / IDE 提示，不作为任何门禁；其警告与报错忽略。
- git 提交使用本仓库 local config。

## 目录

```
src/kernel/scheduler.lua   协程调度器(事件循环) + resume 前信号投递
src/kernel/process.lua     进程表/进程树/spawn/隔离 env + cwd + argv + 会话/进程组/信号/作业控制
src/kernel/signal.lua      POSIX 信号编号/默认动作/可捕获表/名字表
src/kernel/vfs.lua         虚拟文件系统: 挂载表 + resolve + real/virtual 后端
src/kernel/vfs_api.lua     VFS 门面(fs/io) + /dev 设备注册表 + stdio
src/kernel/modules.lua     内核模块系统: .ko 解析(注释头)/依赖拓扑/装载/alias(use) + fstype 注册
src/kernel/blockdev.lua    块设备层: 文件块设备(/parts/*.img, seek+read/write)
src/kernel/devdisk.lua     磁盘设备抽象: CC 磁盘 -> /dev/sdX 节点 + UUID(磁盘 ID 模拟) + fstype 挂载/卸载
src/kernel/ext2.lua        EXT2 读写: 超级块/inode(uid/gid/mode/硬链接/符号链接)/间接块/多块组
src/kernel/user.lua        用户库: /etc/passwd|shadow|group, salt+hash, chmod/chown 权限
src/kernel/display.lua     显示设备注册表: 统一 ScreenDevice -> /dev/ttyN + /dev/fbN
src/kernel/tty.lua         字符终端(/dev/ttyN): 行规程+回显+光标+滚动+焦点切换
src/kernel/fb.lua          软件帧缓冲(/dev/fbN): 32 位 ARGB 像素缓冲+脏矩形 flush
src/kernel/sysfs.lua       /sys 虚拟配置 fs(sysfs 风格, class/display 子树, 读=查/写=设)
src/kernel/manifest.lua    /parts/manifest 解析器(root/boot 行 + 分区表)
src/kernel/dlubcfg.lua     /dlub.cfg 解析器(bootdisk 行; 语法/未知键/重复键 fail-fast)
src/kernel/dlub.lua        DLUB 引导装载器(GRUB 风格): /dlub.cfg 锁盘->清单->开区->挂 ext2->载内核
src/kernel/boot.lua        入口: 日志->kprint->setupVfs/setupDevices/registerConsole->装模块->sysfs->launch init
src/init/init.lua          CC-fs 引导的 PID 1(init)
src/init/ext2_init.lua     EXT2 根引导的最小 PID 1(权限/显示/键盘/shell 自检)
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
src/bin/mount              挂载 /dev/sdX、UUID=<uuid> 或镜像路径 (无 -t 按设备类型; 无参列出挂载)
src/bin/umount             卸载文件系统 (umount <dir>|<-device>)
src/bin/blkid              列出块设备的 UUID/TYPE/LABEL (util-linux blkid 子集)
src/bin/lsblk              树状列出块设备: NAME/SIZE/TYPE/MOUNTPOINT (util-linux lsblk 子集)
src/bin/login              getty/login: 登录提示->验证->启动 sh->循环
src/bin/sh                 交互/脚本 shell(POSIX 核心子集: 变量/引号/if/for/while/case/函数/test/[ ]/&&/|| /重定向, 支持 shebang 脚本执行)
src/modules/*.ko           内核模块: ccdisk(ccdisk fstype) ccmonitor(CC 显示器驱动) cc_hse(HSE 时钟拉模式
                           os.msleep) demo(演示) ext2(ext2 fstype) tom(Tom GPU 驱动) void(Void 全息驱动)
src/modules/modules.alias  驱动别名(modprobe 风格): tm_gpu->tom hologram->void monitor->ccmonitor
src/modules/manifest       默认装载模块清单: demo ext2 ccdisk
scripts/posix_test.sh      可移植 POSIX 自检(host 与 Delin 各跑一次比对, 97 项全过)
scripts/jobctl_test.sh     作业控制自检(& / $! / jobs / fg / bg / wait / kill %job, host 与真机各跑一次)
scripts/sysinfo.sh         实用小工具: 系统信息(变量/函数/for/case/if/重定向/工具)
tools/bundle.lua           打包 src/ -> dist/kernel.lua 或 dist/dlub.lua
tools/harness.lua          host 测试台: 用真实 Delin 工具源码在宿主跑(fs/io/syscalls/spawn 桩,
                           含信号/进程组语义: kill/killpg/SIGCONT/stopped, 供 sh 作业控制验证)
tools/deploy.py            重建干净 ext2 根镜像并部署到 disk(基镜像+更新后的内核/bin/脚本/自检)
dist/                      生成物(不提交)
```
