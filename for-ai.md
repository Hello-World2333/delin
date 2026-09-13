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
| `/bin/` | 用户工具（POSIX 强制命令已补齐，见「POSIX 命令覆盖」一节）：`awk base64 basename bc cat chgrp chmod chown cksum clear cmp column comm cp csplit cut date dd df diff dirname du echo ed env expand expr file find fold grep head id join kill killall less ln logname ls mkdir mkfifo more mount mv nl nohup od passwd paste patch pathchk pr printf ps readlink realpath rev rm rmdir sed seq sh sleep sort split strings tac tail tee timeout touch tr tsort tty umount uname unexpand uniq uudecode uuencode wc which whoami xargs yes`（分页器 `less more`、任意精度计算器 `bc`、文本处理语言 `awk` 等 19 个是「批次 3」补齐的，见下文）；系统/服务类：`blkid desh dmesg fsck.ext2 logger login logrotate lp lsblk lua mdadm mkfs.ext2 pgrep pkill syslogd systemctl`（`desh` = 交互式增强 shell：补全/历史/智能提示/纠错，与 `sh` 共用同一份核心，见「`desh`」一节）；用户管理：`groupadd groupdel groups useradd userdel usermod` |
| `/dev/` | 设备文件：`/dev/ttyN`（字符终端）、`/dev/fbN`（像素帧缓冲）、`/dev/sdX`（磁盘，见下）、`/dev/lpN`（打印机字符设备，只写，见下）、`/dev/null`（读 EOF/写丢弃）、`/dev/zero`（读 = 无限 NUL）、`/dev/random`、`/dev/urandom`（随机字节，见下）、`/dev/console`（系统控制台 = 控制台 tty）、`/dev/kmsg`（内核 ring buffer 只读流）、`/dev/log`（用户态 syslog 输入）、`/dev/mdN`（软RAID 阵列的块设备，见下） |
| `/etc/` | 系统配置：`passwd` `shadow`（0600 root:root）`group`、`fstab`、`mdadm.conf`（软RAID 阵列清单，开机自动组装，见下）、`syslog.conf`、`logrotate.conf`、`systemd/system/`（管理员单元与 enable 标记） |
| `/proc/` | 虚拟进程/系统信息 fs（procfs，内核提供，见下）：`/proc/<pid>/{cmdline,comm,cwd,stat,status}`、`/proc/self`、`/proc/{mounts,mdstat,uptime,version}`、`/proc/sys/kernel/random/{entropy_avail,poolsize,uuid}` |
| `/sys/` | sysfs 挂载点（虚拟）：`/sys/class/<class>/<条目>/<属性>`，class 由内核/模块注册 —— `display`（每显示设备一项，`name/type/size` 只读，分辨率/位置/旋转/缩放 可读写）、`printer`（每打印设备一项，见下）与 `redstone`（每个红石面一项，见下）、`power`（CEE:CC 的电力，见「CEE:CC 平台」）、`pin`（CEE:CC 的信号引脚与端口，见同节）；属性文件是单行值，读一次即 EOF |
| `/lib/modules/<version>/` | 内核模块目录：`.ko` 模块 + 纯文本 `manifest` + `modules.alias` |
| `/lib/systemd/system/` | 厂商单元文件（`.service` `.target` `.timer` `.mount`） |
| `/run/` | 运行时状态（真实目录，非 tmpfs —— Delin 无 tmpfs）：pid 文件等 |
| `/var/log/` | 系统日志（由 syslogd 写入，logrotate 轮转） |
| `/mnt/` | 挂载点（`/etc/fstab` 中的条目由 init 生成 mount 单元自动挂载；其余用 `mount` 显式挂载） |
| `/parts/` | 引导盘分区清单 `manifest`（`<role> <path> <fstype>`，`#` 为注释） |
| `/boot/` | 内核镜像 |
| `/dlub.cfg` | DLUB 引导配置（电脑自身 FS）：三种根来源**互斥**，必须指定一个 —— `rootfs <路径>`（电脑自带存储上的 ext2 镜像）、`bootdisk <外设名>`（磁盘上 manifest 的 root 分区）、`ccdisk <外设名>`（该磁盘的 CC 原生文件系统本身） |

### 存储设备（`/dev/sdX`）

CC 没有裸块 API：一块存储（**电脑自带存储**，或磁盘驱动器里的盘）只提供「它上面的 CC 原生文件系统」和
「它上面的 `/parts/*.img` 文件」两样东西。内核把它们抽象成 Linux 风格的设备节点，**不自动挂载**，
一律由 `mount` 显式挂载：

| 节点 | 含义 | fstype |
|---|---|---|
| `/dev/sda`、`/dev/sdb` … | 整盘：该存储的 CC 原生文件系统（`sda` 恒为电脑自带存储） | `ccdisk` |
| `/dev/sda1` … `/dev/sdaN` | 分区：该存储 `/parts/manifest` 第 N 个分区行指向的镜像 | `ext2` |
| `/dev/ccdisk0`、`/dev/ccdisk1` … | 整盘 CC 原生 fs 的别名节点（N 从 0 起，同 `sda`、`sdb`） | `ccdisk` |

- **命名**：**电脑自带存储恒为 `sda`**（它不是外设，`peripheral.getNames()` 里根本没有它，
  曾经的 bug 就是只枚举磁盘驱动器，于是自带存储与其上的分区永远不是设备）；磁盘驱动器接在其后按
  `disk.getID()` 升序编成 `sdb`、`sdc`、…（与 `peripheral.getNames()` 顺序、槽位无关，重启后同一块盘
  仍是同一个字母）；无 ID 的介质（放进驱动器里的电脑/海龟）排最后。分区号取该存储 `/parts/manifest`
  分区行的序号（1 起，`root` 行在前）。
- **UUID**：CC 没有文件系统 UUID，用 ID 模拟，**并且必须带前缀**——磁盘 ID 与电脑 ID 是两套各自递增的
  数字，会撞号（磁盘 0 与电脑 0 无法区分）：磁盘 `d<磁盘ID>`／`d<磁盘ID>-<分区号>`，
  电脑自带存储 `c<电脑ID>`／`c<电脑ID>-<分区号>`（如 `UUID=d0-1`、`UUID=c3-1`）。
  **裸数字不再匹配任何设备**。CC 对自带存储、以及放进驱动器的电脑/海龟**根本不给 ID**
  （`disk.getID` 只认软盘），这类无 ID 介质没有 UUID，不能用 `UUID=` 挂载。
- **挂载**：`mount /dev/sda1 /mnt`（无 `-t` 时按节点自带类型）、`mount -t ccdisk /dev/sda /mnt`、
  `mount UUID=d0-1 /mnt`；`umount` 接受挂载点或设备节点。`mount` 无参列出挂载
  （设备节点/挂载点/类型/`ro|rw`/uuid，与 `/proc/mounts` 同一来源），
  `blkid` 列出设备的 UUID/TYPE/LABEL，`lsblk` 以树状列出设备与挂载点。
  **根挂载也对上设备节点**：根 = 自带存储本身（CC-fs 引导）时是 `/dev/sda`，根 = 镜像文件
  （`rootfs`/`bootdisk`）时是其所在存储的 `/dev/sdXN`——只有镜像没写进该存储的 `/parts/manifest`
  时才退回虚拟设备名 `rootfs`（并打日志）。
- **原始字节**：分区节点可当字节设备打开（`fs.open("/dev/sda1","r")` 读镜像原始字节，`cat /dev/sda1`、
  `dd if=/dev/sda1` 读出的就是镜像逐字节内容，与宿主 `cksum` 该 `.img` 的结果一致——真机锁在
  `scripts/realmachine_verify.sh` 里）；整盘是 CC 原生文件系统（目录树，不是字节流），打开会被拒绝，只能挂载。
  `devdisk` 的字节句柄**点号与冒号都收**（点号是 CC 原生句柄的写法、冒号是 Delin 句柄的写法），
  判据是"第一个实参是不是句柄自己"——**不能**写成 `(type(a) == "table") and b or a`：冒号调用
  `h:readLine()` 时 `b` 是 nil，`true and nil or a` 会把**句柄自己**当参数传给 CC，而 CC 的
  `handle.readLine` 第一个参数是 boolean（`Optional<Boolean>`），于是真机上 `cat /dev/sdb1` 报
  `bad argument #1 (boolean expected, got table)`（曾经的 bug，`hosttest` 里锁着）。
- 磁盘插入/弹出（CC `disk` / `disk_eject` 事件）时内核重新扫描并刷新 `/dev` 节点。
  自带存储的 LABEL 取 `os.getComputerLabel()`。

#### mkfs.ext2 与 fsck.ext2

两个 e2fsprogs 风格的工具，逻辑都在内核里、`/bin` 只是薄壳（与 `user.*`/`init.*` 同一模式）：
`kernel/ext2.lua` 的 `ext2.mkfs`/`ext2.fsck` 是真源，`devdisk.mkfs`/`devdisk.fsck` 负责
「把设备规格解析成镜像路径、拒绝挂载中的文件系统」，boot 注册 `blkdev.mkfs`/`blkdev.fsck` syscall。

| 命令 | 覆盖 |
|---|---|
| `mkfs.ext2 [-b 块大小] [-N inode 数] [-L 卷标] [-m 保留%] [-n] [-q] [-F] [-v] 设备 [块数]` | 建 ext2（`-t ext2` 也收，其它类型 fail-fast） |
| `fsck.ext2 [-a\|-p\|-n\|-y] [-f] [-v] 设备` | 检查/修复（退出码与 e2fsck 一致：0/1/4/8/16） |

- **设备**两种规格都收（与 `mount` 一致）：`/dev/sdXN`、`UUID=<uuid>`（节点规格，由 `devdisk.find`
  解析）或**真实后端上的镜像路径**。省略块数时按设备/镜像现有大小算；0 字节的空镜像必须显式给块数。
- **布局**（单块组，与宿主 `mkfs.ext2` 的单块组产物同构）：块大小 1024/2048/4096；
  块大小 1024 时 block0 是引导块、block1 超级块、block2 块组描述符、block3/4 位图、block5.. inode 表；
  块大小 >1024 时超级块在 block0 内偏移 1024 处，GDT 起自 block1。块数上限 `8*块大小`
  （1024 时 8192 块 = 8MB，4096 时 32768 块 = 128MB）—— **只做单块组**，超了直接报错。
- **`-N`** 向上取整到「每块 inode 数」的整数倍（inode 表恰好占整数个块，不留半块）；**`-m`** 写
  `s_r_blocks_count`，驱动分配块时到保留线就停；**`-L`** 落进超级块的 16 字节卷标区（`blkid` 读得回）。
- **`-F` 不是装饰**：目标上已经有（能被挂载的）ext2 又不给 `-F` 一律拒绝 —— 与 mke2fs 那句
  "proceed anyway?" 同义，只是这里不交互；**挂载中的文件系统永远拒绝格式化/检查**（会把运行中的
  系统写坏），判定在内核里（`devdisk.mountedAt`）。
- **fsck 五趟**（与 e2fsck 同构，`mode` = `check` 只看不写 / `ask` 逐项问 / `fix` 全修，
  **检查与修复是同一套代码**，`check` 模式一个字节都不落）：
  ①inode/块（模式合法性、块指针范围、多重占用**克隆**、`i_blocks`、目录 size）；
  ②目录结构（条目长度/名字/类型、指向空闲 inode 的条目、重复条目、`.`与`..`）；
  ③连通性（孤儿 inode **重连到 `/lost+found`**，名字 `#<ino>`，没有 `/lost+found` 就建一个）；
  ④引用计数（`links` 与实际引用对数）；⑤位图与块组计数（含尾部填充位、`bg_used_dirs_count`）。
- **`inode 1..10` 是保留段**（坏块 inode、root、resize inode、journal inode…）：与 e2fsck 一样
  **不查**它们的块/链接/孤儿 —— 宿主 mkfs 造的盘上 resize inode 的 `i_block` 本来就指着预留 GDT 块
  （那是它的正常形态，不是"文件占了元数据"）。块组元数据、备份超级块与预留 GDT 块按
  `s_reserved_gdt_blocks` + `3/5/7 的幂`规则算成元数据。**多块组镜像照样能查**（宿主
  `mkfs.ext2` 造 20MB/3 块组的盘, 我们的 fsck 与 e2fsck 的文件数/块数逐项一致）。
- **目录块修复用"重打包"**而不是逐条算 `rec_len`：解析出一个块里的活条目后整块重写（空闲空间归到块尾）。
  这样"空闲条目夹在活条目之间""条目长度损坏""`.`/`..` 放错位置"都是同一条路径，也不会留下
  e2fsck 判 `directory corrupted` 的形态。
- **让出调度器**：fsck 每 50ms CPU 时间 `os.msleep(0)` 一次（与 `cat`/`dd` 同一套），否则长循环里
  收不到 `^C`、整个系统也跟着卡住。
- **已知偏离**：不支持三间接块（驱动也没有写路径，遇到只如实记录）；不校验/不搬移超级块校验和、
  特性位与 `bg_used_dirs_count` 以外的记账；`-c`（坏块扫描）、`-b 备用超级块`、`-j`（journal）
  等开关没有实现；交互式询问从 **stdin** 读（e2fsck 从 `/dev/tty` 读，管道一律当"不修"）；
  **不做 root 检查** —— devtmpfs 与 `dd`/`mount` 都不检查设备权限（Linux 上 mkfs 靠的是
  `/dev/sdX` 的属主/权限，Delin 的 `/dev` 目前没有这一层）。

### 软RAID（`/dev/mdN`，`mdadm`）

Linux md 的移植：内核 `src/kernel/md.lua`（超级块/条带映射/降级/重建）+ 模块 `src/modules/md.ko`
（注册 `md.*` syscall 与调度器心跳钩子）+ 工具 `/bin/mdadm`（mdadm(8) 子集，与 `mkfs.ext2` 对
`blkdev.*` 的关系一样：工具只解析选项，判定全在内核里）。

| 命令 | 覆盖 |
|---|---|
| `mdadm --create <设备> --level=<l> [--raid-devices=<n>] [--chunk=<n>] [--layout=<l>] [--name=<名>] [--uuid=<u>] [--force] <成员...>` | 建阵列（`-C -l -n -c -p -N -u -f` 短选项、`--level=0/1/5/6/10/raid0..raid10` 都收；成员可写 `missing` 占位） |
| `mdadm --assemble <设备> <成员...>` / `--assemble --scan [--config=<文件>]` | 组装（显式成员，或按 `/etc/mdadm.conf` 逐条组装；`--run` 允许起"不干净的降级阵列"） |
| `mdadm --detail <设备>` / `--detail --scan` | 阵列详情 / 输出 mdadm.conf 的 `ARRAY` 行 |
| `mdadm --examine <设备>` / `--query <设备>` | 读成员的 1.2 超级块（magic/校验和/角色/Array State） |
| `mdadm <设备> --add/--remove/--fail/--wait <成员>` | 加盘（自动顶到缺员槽位并开始重建）、移除、标故障、等重建结束 |
| `mdadm --stop <设备>` / `--stop --scan` / `--zero-superblock <设备>` | 停阵列（挂载中的拒绝停）、抹超级块 |
| `mdadm --version` / `--help` | —— |

- **设备模型**：成员是**块设备**，与 `mount`/`mkfs.ext2` 收的是同一套规格（`/dev/sdXN`、
  `UUID=..`、或真实后端上的镜像路径如 `/parts/a.img`），由 `devdisk.target` 统一解析；阵列本身
  经 `devdisk.registerNode` 注册成 `/dev/mdN`，于是 `mount /dev/md0 /mnt`、`mkfs.ext2 /dev/md0`、
  `fsck.ext2 /dev/md0`、`blkid`（`UUID=<数组 uuid>`）、`lsblk`（TYPE 显示 `raid5` 这类级别名）
  **一行都不用改**就能用。阵列节点的 fstype 记 `ext2`（Delin 只有这一种块文件系统，与 `/dev/sdXN`
  分区同义），`mount UUID=<数组 uuid>` 也能挂。
- **元数据（mdadm 1.2）**：成员设备**开头 4K 处**放 4096 字节超级块（`struct mdp_superblock_1`
  的字段偏移、magic `0xa92b4efc`、major_version 1、`sb_csum` 是"32 位小端字累加折回"而**不是**
  CRC —— 都照 mdadm 的 `super1.c` 写）。数据区从 `data_offset` 起：raid1 是 16 扇区(8K)，
  条带级别向上对齐到 chunk 边界。`dev_roles[]` 按 `dev_number` 索引（`0..n-1` = 数据槽位，
  `0xffff` 备用，`0xfffe` 故障）；`events` 计数器是**新鲜度** —— 组装只认最大的那一批，
  被 `--remove` 掉的老盘因此自动过期（下次组装只能当备用），不需要额外的"已移除"标记。
  中途被打断的重建把进度留在 `recovery_offset` 里，重启后接着建。
- **级别与布局**：raid0（original layout：逻辑 chunk `c` 落在设备 `c % n`）、raid1、
  raid5/6（P[, Q]，`left-symmetric` 默认，另收 la/ra/rs/parity-first/parity-last 与
  raid6 的 `*-6` 变体）、raid10（`n2` 默认，`f2`/`o2` 收，near/far/offset 的换算与
  `raid10.c` 的 `__raid10_find_phys`/`raid10_find_virt` 对应）。RAID6 的 Q 用 GF(2^8)
  （生成多项式 `0x11d`）+ Linux 的系数顺序（从 Q 那块盘之后环行）。
- **校验写一律 reconstruct-write**：写一个数据块时读齐同一条纹同一偏移上的其它数据块，重算 P/Q
  再写回 —— 于是"新建阵列先做一次全盘 resync 生成校验"这一步**不需要**，校验永远与新数据一致
  （代价是每次写校验级别的盘要多读几块；CC 的盘很小，这个取舍划算）。raid1/raid10 的初次同步
  则是"每块数据取第一份副本为真值拷到其余副本"。
- **重建（recovery）**：`--add` 一块盘后，内核后台按扇区分片重建（`md.tick` 由**调度器心跳**
  `scheduler.setTickHook` 每 0.05s 驱动一次，所以钩子里绝不能让出），进度回写该成员的超级块。
  重建期间写会**同时**写进正在重建的成员、读一律绕开它（它的数据在进度之前还是旧的）。
- **`/proc/mdstat`**：Linux 形状（`Personalities : [raid0] [raid1] ...`、`md0 : active raid5 sdb1[0] ...`、
  `      1024 blocks super 1.2 [2/2] [UU]`、重建时一行 `[=>...]  recovery = ...`、
  `unused devices: <none>`）。阵列没有名字时也恒定存在（空表）。
- **开机自动组装**：init 把 `/lib/systemd/system/mdadm.service`（oneshot：
  `/bin/mdadm --assemble --scan`）挂到 **`local-fs-pre.target`**（`Wants`，不是 `Requires`：
  没有这个单元的老安装照样能启动），而所有 fstab 生成的 mount 单元都是
  `After=local-fs-pre.target` —— 于是 `/etc/mdadm.conf` 里列出的阵列**一定在挂载之前**组装好。
  `/etc/mdadm.conf` 只认 `ARRAY` 行（`uuid=` `name=` `level=` `num-devices=` `spares=` `devices=`，
  键大小写不敏感；`metadata=`/`bitmap=`/`container=`/`member=`/`super-minor=` 认下不用），
  发布时只有注释、没有生效的 ARRAY 行，所以默认开机**什么都不组装**。
- **Delin 的不同（`--detail --scan` 会写 `devices=`）**：成员可以是**镜像路径**（`/parts/*.img`），
  这类成员**扫描不出来**（它们不是 `/dev/sdXN` 设备节点），所以 `--scan` 的输出把 `devices=` 一并
  写出来，`--detail --scan >> /etc/mdadm.conf` 之后开机就能自动组装。`devices=` 本来就是
  mdadm.conf(5) 认的键，对 mdadm 也合法。
- **降级起停规则**（与 mdadm 的 "cannot start dirty degraded array" 同义）：缺员数超过级别能容的
  上限（raid0 0、raid1 n-1、raid5 1、raid6 2、raid10 副本数-1）一律拒绝起；容得下但元数据说
  "不干净"（`resync_offset != MaxSector`，例如上次是降级写的或重建中途停机）时要显式 `--run`。
  `--stop` 拒绝停挂载中的阵列；`--remove` 只允许移除已 `--fail` 的成员（除非 `--force`）。
- **已知偏离**：没有 write-intent bitmap（**写不原子**，掉电可能留下不一致的校验块）；
  没有 reshape/`--grow`、没有 DDF/PPL/journal、没有 0.90/1.0/1.1 元数据；`--monitor`/`--incremental`
  没有实现（未知选项一律 fail-fast 退出 2）；数组 UUID 是自造的 128 bit（`random.bytes(16)`），
  **与宿主 mdadm 的产物互不通用** —— CC 上根本没有能被 Linux 内核认出来的块设备，互操作无从谈起，
  所以这里只保证**自身闭环**：字段布局与算法逐条对照 mdadm/内核源码，但宿主上没有 mdadm 可以
  交叉复判（`mdadm --examine` 那套真机验证只能在 Delin 上做）。
- **验证**：宿主回归 `tools/mdtest.lua`（128 项：五个级别 + 三种非默认布局的读写往返、
  **独立的布局模型**（测试文件里按手册重写一份放置公式，直接从成员镜像取数据拼逻辑阵列）、
  RAID6 的 Q 用**独立的逐位 GF 乘法**重算、降级读/重建/组装/拒绝规则，最后把
  `mkfs.ext2 /dev/mdN` 造出来的 ext2 用独立模型抽成普通镜像交给宿主 **e2fsck** 当裁判）；
  真机在**电脑 #6**：`tools/md_realmachine.py` + `scripts/md_verify.sh`（两阶段：第一次开机建
  阵列/格式化/降级/重建/组装/写 `/etc/mdadm.conf`，重启后断言阵列**在启动时就已被 mdadm.service
  组装好**且数据仍在；41 项 ok，0 ng）。

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

### 随机数（`/dev/zero`、`/dev/random`、`/dev/urandom`）

| 节点 | 语义 |
|---|---|
| `/dev/zero` | 读 = 无限 NUL 字节（`read(n)` 给 n 个），写丢弃（POSIX/Linux） |
| `/dev/urandom` | 读 = ChaCha20 CRNG 输出，**永不阻塞** |
| `/dev/random` | 同 urandom，但**只在 CRNG 未初始化时阻塞**（Linux 5.6+ 语义） |

内核 `src/kernel/random.lua` 是熵池 + CRNG，`src/kernel/chacha20.lua` 是密码学核心（纯 Lua 的
ChaCha20，RFC 8439 的 IETF 变体：32 位计数器 + 96 位 nonce）。结构对齐 Linux 的两层
（输入池 + CRNG）；ChaCha20 核心对着 **OpenSSL 生成的向量**核对过（`hosttest` 里锁着，
向量与生成命令都写在用例注释里）。

- **熵源 = 所有系统事件**：`scheduler` 拿到事件（`os.pullEventRaw`，唯一的事件入口）就调用
  `random.feedEvent`，样本 = 事件名 + 参数（`char`/`paste` 的输入内容、外设名、红石面、
  `modem_message` 的消息、`timer` 的 id…）+ 到达时刻 + 与上一个事件的间隔 + 事件序号；
  间隔用**两种时基**各算一次（毫秒 `os.epoch` 与 CPU 微秒 `os.clock`）。真正不可预测的是
  **事件参数**（人按键、别的电脑发消息），间隔抖动是其次。
  钩子由 boot 用 `scheduler.setEventHook(random.feedEvent)` 注入 —— 与 `setDiskHook` 同一做法，
  调度器因此**不依赖** random（宿主测试台能单独装载它）。
- **输入池**：512 字节 = 4096 bit，混合用 Linux primary pool 的**同一个多项式**
  `x^128 + x^103 + x^76 + x^51 + x^25 + x + 1`（逐字节、池子反向滚动、每掺一字节多转 7 bit、
  池首那一次多转 7 bit），即 `_mix_pool_bytes` 的移植。引导时的初始混合（时刻 / CPU 时间 /
  电脑 ID / CraftOS 版本 / 几个表地址）**不记账** —— 与 Linux 一样只是"先搅进池子"。
- **熵估计**：`add_timer_randomness` 那一档 —— 间隔的二阶/三阶差分取绝对值后取最小，
  `min == 1` 记 1 bit，否则记 `ilog2(min)`；`min == 0`（间隔完全可预测）记 0 bit，上限 4096 bit。
  攒到 128 bit 就**重新播种** CRNG（提取消耗掉这部分记账，与 Linux 提取熵的语义一致）。
- **CRNG**：ChaCha20，密钥从池子提取（自造的键控吸收 hash）；每次输出后**立即换钥** ——
  Linux 的 fast key erasure：计数/nonce 全零，每块 64 字节的**头 32 字节**当即成为下一次的
  密钥，其余才是给出去的随机数据（因此泄一次输出推不出更早的输出）。
  初始化判据 = Linux 的 fast-load 偏置（未就绪时事件样本按**每字节 1 bit** 记账，满 128 bit
  算完成），完成时内核日志打 Linux 那句 `random: crng init done`，之后 `/dev/random` 不再阻塞。
  **为什么不学 5.6 之前"按熵估计阻塞"**：CC 的事件间隔被服务器 tick 量化（20Hz 心跳），
  毫秒时基的估计涨不上去，`cat /dev/random` 会长时间挂住 —— 那不是现在的 Linux 行为。
- **`/proc/sys/kernel/random/`**（procfs，见下）：`entropy_avail`（bit）、`poolsize`（4096）、
  `uuid`（每次读一个新 RFC 4122 v4，Linux 同此）。
- **用法**：`dd status=none if=/dev/urandom bs=16 count=1 | od -An -tx1`、
  `cat /proc/sys/kernel/random/entropy_avail`。
- **已知偏离**：池子提取用 ChaCha20 自造的键控 hash（Linux 用 BLAKE2s）；熵估计只做
  `delta3/ilog2` 这一档，没有它的分组采样/中断合并策略；`/dev/random`、`/dev/urandom`
  **只读**（Linux 允许写入并把写入内容当熵来源），写打开按只读设备报错；
  字节流设备没有"行"，`readLine` 一律等价于一次 `read(4096)`，所以 `cat /dev/zero`
  与 Linux 一样是无限输出（要收尾用 `dd count=` / `^C`）。
- **`/etc/shadow` 的盐也走这里**：`user.makeSalt` 取 `random.hex`（从前是 `math.random` ——
  CC 进程里没播种，序列可预测，等于没有盐）。

### 红石（`redstone.ko`）

CC 的红石 API 是函数式的（`redstone.getInput(side)` / `redstone.setAnalogOutput(side, v)` 成对），
`redstone.ko` 把它摊成 Linux gpio 风格的 **sysfs 属性文件**（对应 `/sys/class/gpio/gpioN/{direction,value}`），
于是 shell 里 `cat` / `echo` 就能直接和红石打交道，不需要写 Lua 也不需要任何工具。
**一个面的一种红石量就是一个文件**（不设 `input`/`output` 变体）：读 = 该面输入，写 = 该面输出 ——
和真实红石口一样，口本身没有第二个文件。

| 路径 | 读 | 写 |
|---|---|---|
| `/sys/class/redstone/<side>/digital` | `0`/`1`（`getInput`） | `0`/`1`（`setOutput`） |
| `/sys/class/redstone/<side>/analog` | `0..15`（`getAnalogInput`） | `0..15`（`setAnalogOutput`） |
| `/sys/class/redstone/<side>/bundled` | `0..65535` 位掩码（`getBundledInput`） | `0..65535` 位掩码（`setBundledOutput`） |

`<side>` 是 CC 的六个面 `top bottom left right front back` —— 六个面恒定存在（CC 电脑六面都能收发红石），
因此没有 Linux gpio 的 `export`/`unexport`，也没有只读属性（三个都能写）。

- **用法**：`cat /sys/class/redstone/left/analog`、`echo 15 > /sys/class/redstone/left/analog`、
  `echo 32768 > /sys/class/redstone/back/bundled`（`black` = 32768，与 `colors.black` 一致；
  读写都是十进制掩码，与 `colors.combine`/`colors.subtract` 是同一套位掩码）。
- **读的是输入**：`getOutput`/`getAnalogOutput`/`getBundledOutput`（本机自己驱动了什么）没有对应文件 ——
  口上是什么就读到什么，`echo 15 > analog` 之后 `cat analog` 读到的是**对面/线**的值，不是刚写的 15
  （真机上若该面接着一段自己的红石线，CC 的 `getInput` 也会把这段线的 15 读回来，但这不是文件接口的保证）。
  要在脚本里读回自己的输出状态就用 CC 的 `redstone` API（用户态进程白名单里有 `redstone`，
  如 `lua` 里 `print(redstone.getAnalogOutput("left"))`）。
- **输出语义与 CC 一致**：`digital` 与 `analog` 的**输出**侧是同一份状态 —— 写 `digital=1` 等价于
  `setOutput(true)`，也等价于 `setAnalogOutput(15)`；写 `analog=0` 后 `getOutput` 为 `false`。
- **写校验 fail-fast**：值必须是十进制整数且在范围内（`0x10`/`1e2`/负数/小数一律拒绝），
  非法写返回错误且**不改动**输出状态；`sh` 的 `echo` 把它报成 `echo: write error: invalid ...`
  并置退出码 1（见下文 `echo`），不会被静默吞掉。
- **事件**：不提供阻塞读（没有 `/dev/kmsg` 那种语义），要等红石变化就轮询；
  事件驱动的程序直接用 CC 的 `redstone` API（`os.pullEvent("redstone")`）。

### CEE:CC 平台（CEECC 台式机，`cee.ko`）

CEE:CC（下称 CEECC）是服务器上的一个模组：它的电脑把整套 API 挂在**全局 `cee` 表**上（不是外设），
在 CC 的三个平面（侧面外设 / `redstone` / 文件系统）之外多出**信号引脚**与**电力**两块。
判据只有一条：`_G.cee` 存在且带 `getSignalCount` —— 见 `kernel/platform.lua`（`kind = "cc" | "cee"`）。

CEECC 有两种机器：**机架式**（模块插在机架里，自带存储 4096 字节）与**台式**（自带存储与普通电脑同级）。
机架式装不下 Delin（内核 208KB + 模块），**不在支持范围**：`platform.lua` 不为它做任何分支，
BIOS/安装器也不拦 —— 容量不够时自然 fail-fast（`Out of space`）。

真机实测（台式 CEECC，电脑 #6，`tools/ceecc_realmachine.py` 时读回）：

| 项 | 实测 | 结论 |
|---|---|---|
| 平台 | `_G.cee`（71 个函数）；`peripheral`/`redstone`/`disk`/`rednet`/`http`/`gps` 全在 | 台式 CEECC ≈ 普通 CC 电脑 + 引脚 + 电力，**侧面平面照常工作** |
| 自带存储 | `fs.getCapacity("/")` = **10,000,000**（普通电脑 1,000,000，机架式 4096） | CC-fs 根引导直接可用；`sda` 9.5M |
| 侧面外设 | `back`=有线 modem（枢纽，下挂 27 个远端磁盘 `drive_0..26`）、`right`=drive、`left`=无线 modem | 现有 `peripheral.getNames()` / devdisk / 驱动**零改动**可用 |
| 引脚 | **9 个**（机架式 3 个）；1 起编号；`pin8` 有端口：`isDataPin=true`、`getPortCount=1`、`isPortPowered=true`、类型 `modem` | 引脚数随机型，`getSignalCount()` 才是真源 |
| 引脚外设 = 侧面外设 | 在 `wrap("back")` 上 `open(43)` 后 `cee.getPeripheral(8).isOpen(43)` 为真（反向亦然） | 同一个物理外设两种视图：**设备枚举仍走侧面平面**，引脚只做状态与端口 |
| 无端口引脚 | `getAnalog`=0、`getInput`=false **不报错**；`getAnalogOutput`/`getOutput` 报 `no signal port on pin N` | 「有没有端口」只能看 `getPortCount>0`；没端口就不该有那三个属性文件 |
| 数据引脚 | `setSignalVoltage(8,30)` 被拒（`cut the cable`），但 `setAnalog(8,7)` 可用 | 端口的红石 I/O 面与引脚的模拟信号线是两回事 |
| 电力 | `hasPower`=1、电压≈300V、`getMaxPower`=**500W**、`headroom`=500、`state="ok"` | 台式自持馈电；`busInfo()`=nil、`isBusPowered()`=false |
| 机架专用 API | `listHubs()`/`fabricPeers()` **直接报错**（`not a server module`），不是返回空表 | 机架总线 / Data Hub / fabric 一律不调 |
| 性能 | 自检里 sysfs 段（约 130 次读写 + 每行 flush）在这台机器上要 **~60s** | 真机自检必须给够超时（见下） |

`cee.ko`（manifest 常驻；非 CEECC 上 init 直接 no-op，不注册任何类）摊出两个 sysfs 类：

| 路径 | 读 | 写 |
|---|---|---|
| `/sys/class/power/supply/present` | `0`/`1`（`hasPower`） | — |
| `/sys/class/power/supply/voltage` `current` `power` `max_power` `headroom` `state` | `getPowerVoltage` / `getSupplyCurrent` / `getDeliveredPower` / `getMaxPower` / `getPowerHeadroom` / `getSupplyState` | — |
| `/sys/class/power/supply/reset` | 只写属性（读不到内容） | `1` → `resetSupply`（清除跳闸） |
| `/sys/class/pin/pinN/data` `ports` `powered` `peripheral` `peripheral_type` | `isDataPin` / `getPortCount` / `isPortPowered` / `hasPeripheral` / `getPeripheralType`（无外设时为空） | — |
| `/sys/class/pin/pinN/analog_in` | `getAnalog`（端口 I/O 面的红石输入） | — |
| `/sys/class/pin/pinN/analog_out` `digital_out` | `getAnalogOutput` / `getOutput` | `setAnalog`（0..15）/ `setOutput`（0\|1） |

- **后三个属性只在有端口的引脚上存在**（`attrs(entry)` 按 `getPortCount>0` 决定）——真机上无端口引脚
  调 `getAnalogOutput`/`getOutput` 会报 `no signal port on pin N`，属性文件因此也不该出现。
- **写校验 fail-fast**：只收十进制整数且在范围内（`16`/`0x3`/`abc` 一律拒绝且不改状态），
  `reset` 只收 `1`；越界引脚（`pin999`）与越界条目名都不存在。
- **存储补漏**：`devdisk` 在侧面驱动器之外再捡一次**引脚上的 `drive`**（`platform.pinDrives()`），
  按 CC 挂载路径去重（台式机上引脚外设通常也在侧面上，重复枚举会给同一块盘造两个设备节点），
  并且 `fs.getCapacity(挂载路径)` 取不到就不造节点 —— 「能不能挂」就是设备节点的判据。
- **`cee` 不进进程环境**：`kernel/procenv.lua` 的白名单里没有它，用户态一律走 sysfs / `/dev/sdX`。

**电缆/枢纽设备是异步出现的**：`scheduler.setDiskHook` 原来只挂在 `disk`/`disk_eject` 上，
而 modem 网络把远端外设挂进本机名字空间是**晚一拍**的（实测同一份装机两次冷启动，一次引导时看见
28 个磁盘、另一次只看见本机那一个）。现在 `peripheral` / `peripheral_detach` 也接进同一个重扫钩子。

#### 真机验证（电脑 #6）

电脑 #3 留给普通 CC（`tools/realmachine.py`），CEECC 用**电脑 #6**：`tools/ceecc_realmachine.py`
（先关机 → 打包 → 在自带存储上做一次干净的 CCFS 根安装 + 注入 `ceecc.service` → 开机 →
引导门禁 → 读回 `/var/log/ceecc.log` → 逐项断言）。

```bash
python3 tools/ceecc_realmachine.py            # 装机 + 开机 + 验证(36 项)
python3 tools/ceecc_realmachine.py --no-reboot
```

- **自检脚本是单进程 Lua**（`scripts/ceecc_verify.lua`，经 `/bin/lua` 跑），不是 `sh`：这个自检要读写
  sysfs 上百次，`sh` 的每一次 `$(...)` 都是一次 spawn + 管道读，真机上跑不动（曾按 90 来个
  子进程的量级被 60s 超时杀掉）。Lua 版**逐行 flush** 落盘，卡在哪一行看得见。
- **`TimeoutStartSec=600` 不是装饰**：init 的默认 oneshot 超时是 60s，而这台机器上光 sysfs 那一段
  就要 ~60s（`stage:` 行带 `t=...ms` 打点）——用默认值会把"跑得慢"报成"起不来"。
- 装机时铺的是 **`dist/` 而不是 `dist/release/*/payload`**：后者只在 `--release` 时重建，
  拿它装机第一次就把**上一轮的内核**装上去了（引导日志里没有 `platform=` 行才发现）。
- 排障小抄：`ls` 对不存在的路径**退出码是 0**（只有错误消息），判断存在性要用 `cat`/`fs.open`。
- **软RAID 也在这台机器上验**（它的自带存储有 10MB，装得下成员镜像 + 根文件系统）：
  `tools/md_realmachine.py` + `scripts/md_verify.sh` 是**两阶段**的 —— 第一次开机走完整生命周期
  （建阵列/`mkfs.ext2`/挂载/降级读/加盘重建/停机重组/写 `/etc/mdadm.conf`），**重启**后第二次开机
  断言阵列在启动时就已经被 `mdadm.service` 组装好、且数据仍在（41 项 ok/0 ng）。
  注入脚本时会把 `RUNTOKEN` 换成唯一串并要求日志里出现它 —— NFS 会缓存属性与内容，
  只比 `mtime` 会把**上一轮**的日志当成这一轮的（踩过一次）。
  验证脚本是 `sh`（要跑 `mdadm`/`mkfs.ext2`/`mount` 这些真家伙），但注意 Delin 的 sh 只支持
  `> >> <`：**`2>&1` 是语法错误**（进程的 stderr 与 stdout 本来就是同一个流，所以工具的错误消息
  照样进日志）。

### 用户管理（`passwd` / `useradd` / …）

内核 `src/kernel/user.lua` 是**唯一真源**：boot（两条引导路径的 `setupUsers`）把 `/etc/{passwd,shadow,group}`
解析进内存 db，之后所有改动只走 `user.*` 写 syscall —— syscall 先按 POSIX 授权，再改内存 db，
最后把**变化过的**那张表特权写回 `/etc`（`process.asRoot` 包一层 uid 0，等价 setuid passwd 的 euid 0）。
`/bin` 工具只是这套 syscall 的 CLI 外壳：直接编辑 `/etc` 文件在运行中的系统里**看不见**
（`login`/`ps -u`/`chown`/`ls -l` 读的都是这份内存 db），所以不设第二条路径。

| syscall | 语义 |
|---|---|
| `user.verify`/`get`/`list`/`byUid`/`groups`/`groupsOf`/`passwordStatus`/`groupByName`/`groupByGid` | 只读查询 |
| `user.setPassword(name, oldpw, newpw)` | root 可改任何人（忽略 oldpw）；本人须给对 oldpw；`newpw == nil` = 删密码（`passwd -d`），仅 root |
| `user.setLocked(name, bool)` | `passwd -l`/`-u`、`usermod -L`/`-U`，仅 root |
| `user.addUser/delUser/modUser/addGroup/delGroup` | 仅 root；任何一步校验失败即整体拒绝 |

- **授权在核心里**，不在工具里：工具绕不过去（`user_test.sh` 用 `spawn` 起 uid 1000 的进程逐条验证被拒）。
- **`!` 前缀 = 锁定**（`passwd -l`，Linux shadow 同格式）；**空密码字段 = 空密码登录**（`passwd -d`）。
  这两者与「shadow 里根本没有这个人」严格区分：后者一律拒绝登录（丢一个 `/etc/shadow` 不能变成
  “所有人空密码可登”），`passwd -S` 报 `L`。
- **只有哈希进 shadow**：`user.get` 只返回 uid/gid/home/shell/full/locked，**不返回盐与哈希**
  （普通进程拿不到哈希，与 `/etc/shadow` 0600 是同一条防线）；`user.verify` 才是判定入口。
- 失败**不留半成品**：`addUser` 先校验完（uid/gid/附加组/名字合法性）才动 db —— 失败的
  `useradd` 不会留下一个同名私有组。
- 名字严格校验（`[A-Za-z_][A-Za-z0-9_.-]*`）：名字会原样写进以 `:` 分隔的表，冒号/换行会让文件结构破掉。
- 新账号**锁定**（无密码字段 + `!`），与 Linux `useradd` 一样要先 `passwd` 设密码才能登录；
  `-m` 才建家目录（默认不建，与 useradd 一致），建完 `chown` 给新用户。
- `usermod -l` 改名**不改组名**（Linux 同此），但组的成员名跟着改；`-G` 不带 `-a` 是**全量替换**
  附加组，`-aG` 才追加；`groupdel` 拒绝删仍是某用户主组的组（GNU 语义）。
- **`/etc/shadow` 是 0600 root:root**：git 只记录可执行位、存不了 0600，所以权限位由安装侧显式设
  （`tools/deploy.py` 的 `os.chmod(..., 0o600)` 与 `tools/installer.lua` 的 `FILE_MODES`）。
  ext2 驱动按调用者 uid 检查 r/w（`hasPerm`，root 绕过），因此普通用户**读不到**哈希、
  也写不了 `/etc/shadow` —— `passwd` 能改成，靠的是内核 syscall 那次特权写。

| 命令 | 覆盖 |
|---|---|
| `passwd [-d] [-l] [-u] [-S] [name]` | 改密码 / 删密码 / 锁定 / 解锁 / 打印状态 |
| `useradd [-u UID] [-g GROUP] [-G LIST] [-d HOME] [-s SHELL] [-c COMMENT] [-m] name` | 建用户（`-m` 建家目录） |
| `userdel [-r] name` | 删用户（`-r` 连家目录） |
| `usermod [-u] [-g] [-G [-a]] [-d] [-s] [-c] [-l NAME] [-L\|-U] name` | 改用户 |
| `groupadd [-g GID] name` / `groupdel name` | 建/删组 |
| `id [-u\|-g\|-G] [-n] [-r] [USER]` / `whoami` / `groups [USER]` | 查询 |

**用户管理的已知偏离**：`passwd` 无 aging 字段（`/etc/shadow` 只有 `name:salt$hash`），
因此 `passwd -S` 只打印 `name P|L|NP` 一列（Linux 还打印最后修改日期与 min/max/warn/inactive）；
密码从 **stdin** 读（是终端时关回显），所以 `passwd < pwfile` 可脚本化 —— shadow-utils 从 `/dev/tty` 读、
管道一律失败，这里牺牲的是“密码不进管道”；
uid/gid 从 1000 起分配（无 `login.defs`，`UID_MIN` 写死在 `user.lua`）；
**没有 `su`/setuid 位**（delin 无 euid 概念，身份切换只能靠 `login`）；
`usermod -m`（搬移家目录）未实现，给了就 fail-fast 报错；
`useradd` 不支持 `-r`（系统账号）/`-o`（uid 可重复）等 GNU 开关，未知选项一律退出码 2。

自检：`scripts/user_test.sh`（125 项）在宿主测试台与真机各跑一次并逐项比对，
需要普通用户身份的分支由 `scripts/user_helper.lua` 用内核 `spawn(uid)` 起进程
（没有 su/setuid，这是唯一能拿到非 root 进程的办法）。

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
| `/proc/sys/kernel/random/{entropy_avail,poolsize,uuid}` | 随机数子系统状态（见「随机数」一节；`uuid` 每次读取新值） |

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
- **目录判定必须与 `exists` 一致**：`ls /proc/self` 会对每个条目调 `attributes`，
  所以 `pidfile` 的存在判定抽成了独立的 `pidFileExists(pid, name)` —— 不能在
  `local backend = { ... }` 的表构造里写 `backend.exists(...)`：Lua 的 local 作用域从**声明语句之后**
  才开始，初始化表达式里的同名引用解析成**全局**（`nil`），真机症状是
  `[proc N ls] ERROR: ... attempt to index global 'backend' (a nil value)`
  （`hosttest`/`regextest` 抓不到这种错 —— 只有真机跑 `ls /proc/self` 才炸）。

**进程管理工具**：`ps`（POSIX ps + procps/GNU/BSD 常用子集，纯 `/proc` 消费者）、`pgrep`/`pkill`
（procps：按进程名/命令行查找、发信号）、`killall`（psmisc：按进程名发信号），加上已有的 `kill`。
`ps` 默认列出**本控制终端上属于本用户的进程**（POSIX 选择规则）；`-e`/`-A`/`ax` 全部，`-a` 带终端的
全部（不含会话首进程），`-x` 本用户全部，`-f`/`-l`/`u`(aux) 选格式，`-p PID`/`-t TTY`/`-u USER` 选择，
`-o FIELD,...` 自定义列（`pid ppid pgrp pgid sess uid user gid group stat state tty comm cmd args cwd`），
`--no-headers` 去表头；未知选项/未知列名 fail-fast（退出码 2）。默认输出 `PID TTY STAT COMMAND`，
`-f` 是 `UID PID PPID STAT TTY COMMAND`，`-l` 是 `STAT UID PID PPID PGRP SESS TTY COMMAND`，
`u`/`aux` 是 `USER PID PPID STAT TTY COMMAND`（无 TIME/%CPU/%MEM/VSZ/RSS/STIME 列）。
`pgrep`/`pkill` 的模式用 **标准正则**（procps 同款：**ERE**，见「标准正则」一节），`-x` 锚定整串、
`-f` 匹配完整命令行、`-n`/`-o` 取最新/最老（Delin 无启动时间，按 pid 大小）、`-u USER` 过滤用户，
两者都不匹配自己（Linux 语义）；`pkill` 默认 `SIGTERM`，`killall` 要求进程名完全相同（不杀自己）。

### 接口与工具（POSIX + GNU 子集）

**进程模型**：`pid/ppid/uid/gid`；`argv`（`[0]`=程序名，`[1..]`=位置参数）；会话（`sid`）与进程组
（`pgrp`）；`tcgetpgrp` 前台进程组；作业控制（`&` `jobs` `fg` `bg` `wait` `kill %job`）。
进程的退出码 = 协程返回值（数字），`proc.wait`/`$?` 由此得到；信号死亡记为 `128+signo`。

**信号**：POSIX 信号编号（`SIGHUP..SIGTTOU`，取 Linux x86-64 编号与默认动作/可捕获表）；
`kill [-SIG] pid|-pgid`、`kill -l`；终端 `^C`（`SIGINT`）/`^Z`（`SIGTSTP`）路由到前台进程组，
后台进程组读控制终端按 POSIX 投 `SIGTTIN` 并停止（`jobs` 显示 `Stopped`，`fg`/`bg` 可恢复）。

**路径语义**：`resolve` 统一做字典序规范化 —— `.` 丢掉、`..` 弹一层、**到根就停**
（POSIX：`/..` 就是 `/`），挂载点上的 `..` 回到挂载点的父目录（Linux：`/mnt/disk/..` = `/mnt`）。
这条不是洁癖：CC 原生 fs（CCFS）对"逃出根的 `..`"是**抛错**（`/..: Invalid Path`）而不是返回 nil，
而 `ls -la /` 自己就会拼出 `/..` —— 不在这一层吃掉，`ls -a /`、`cat /../etc/passwd`、
脚本里的 `$PWD/..` 全都会炸。已知偏离：经**符号链接目录**的 `..` 在 Linux 里按链接目标解析，
Delin 一律按字典序解析。

**文件系统**：进程所见 `fs/io` 走内核 VFS（真实磁盘 + 虚拟 `/dev` `/proc` `/sys` 同一命名空间）；
权限用 `mode`（八进制）+ `uid/gid`，`chmod`/`chown`，启动外部程序强制检查执行（`x`）位 ——
**root 也要文件至少有一个 `x` 位**（POSIX：root 绕过的是 `r`/`w` 检查，不绕过 `x`），否则 644 的
脚本 `./script` 也能跑起来。CC 原生文件系统（`ccdisk`）没有权限位，其文件一律视为可执行。

#### 符号链接、硬链接与命名管道（ext2）

CC 原生文件系统没有这些概念、`ext2` 驱动里有 inode 类型却没出口，补齐 POSIX 命令时一起做了：

- **符号链接**：`fs.symlink(target, linkpath)`（target **原样保存、不解析**）、`fs.readlink(path)`。
  ext2 的"快速符号链接"把 ≤60 字节的目标**内联在 inode 的 i_block 区**、更长才占数据块 ——
  创建侧(`ext2.setSymlink`)与读取侧(`readSymlink`)以同一个 60 字节为界（不一致会把目标字节当块号）。
  **符号链接的权限恒为 0777 且不受 umask 影响**（Linux 语义；内核从不拿它做权限判定）。
- **硬链接**：`fs.link(old, new)`（不跟随 `old` 最后一段，同 Linux `link(2)`；不允许指向目录）。
- **路径解析穿链接**：展开在 **VFS 这一层**做（`vfs.resolve` → `expandLinks`），后端看到的永远是
  "不含符号链接的平坦路径"，所以 `ext2.lookup` 根本不需要知道链接这回事。语义对齐 Linux：
  中间段与最后一段都跟随、相对目标按**链接所在目录**解析、上限 40 跳后 ELOOP。
  `vfs.resolveNoFollow`（= 不跟随最后一段）供 `lstat`/`readlink`/`unlink`/`symlink`/`link`/`mkdir`/`rename` 用
  —— 用错会把 `rm link` 变成"删掉链接指向的文件"。
  **已知偏离**：展开是纯字典序的，因此经符号链接目录的 `..` 与 Linux 不同（与 `normalize` 那条偏离同源）。
- **`lstat` / `lchown`**：`fs.attributes` **跟随**（= `stat`）、`fs.lstat` **不跟随**（= `lstat`，
  对链接本身返回 `kind="symlink"`）；`fs.lchown` 同理（`chown -h`/`chgrp -h`/递归遍历里的链接必须用它）。
  `ls -l` 用 `fs.lstat`，所以能看到 `l` 类型字符与 `name@`。
- **命名管道（FIFO）**：`fs.mkfifo(path[, mode])` + `src/kernel/fifo.lua`，与匿名管道（`kernel/pipe.lua`）
  共用缓冲与协作式阻塞语义，区别是挂在 inode 上、可被**反复打开**（`cat fifo` 与 `echo x > fifo` 各自独立开合）。
  `open` 按 POSIX **阻塞**：读端等到有写端、写端等到有读端。
  **等待条件同时用三样东西，缺一样都会死锁或丢唤醒**（真机/测试台各踩过一次）：
  ① 已挂上的对端；② **正在 open 的对端**（`pending*` —— 双方都只在等对方时必须有一个人先走）；
  ③ 对端"挂上次数"的闩锁（`*Epoch`，进函数时记下 —— 防止"对端挂上、写完、关掉，自己才被调度到"的丢唤醒）。
  配套地，`pipe.lua` 的 EOF/`broken pipe` 判据也把 `pending*` 算作"对端在场"（否则读端会在对端刚开始
  open 时就读到 EOF）。FIFO 端句柄带 `.pipe` 标记，写进 stdio 时由 `process.onExit` 统一关闭。
  **已知限制**：进程不 close 就被杀，端计数不回落（与匿名管道同一限制）。
- **`/dev` 节点的 `kind`**：devtmpfs 的 `attributes` 必须给 `kind="device"` —— 工具靠它区分"文件"与
  "设备节点"，漏了会让 `dd of=/dev/sda1` 走普通文件分支把整个分区镜像读进内存。

#### umask

内核持有**进程属性** `umask`（缺省 `0022`，随 spawn 继承），在**唯一的创建点**
（`ext2.create` → `applyUmask`）统一应用到新建节点上，而不是让每个工具自己收窄：漏一个就多出几个
"世界可写"的文件，而且工具往往先收窄一遍、内核再来一遍 —— 那就是叠了两次。
`syscalls["umask.get"]/["umask.set"]` 供 shell 的 `umask` 内建读写；`-m` 显式指定权限的工具
（`mkfifo -m`）按 GNU 的做法**先建、再 chmod**，使显式 mode 不受 umask 影响。
**符号链接例外**（恒 0777，见上）。

#### ext2 句柄的 seek

读句柄本来是"整文件读进内存 + pos"，写句柄是"整表缓冲、close 时全量重写"。`dd` 需要 `skip`/`seek`，
所以：读句柄实现精确的 `set`/`cur`/`end`；写句柄只能**向前** seek（用 0 填充缓冲区，逻辑内容与稀疏
文件一致），**向后 seek 明确报错而不是假装成功** —— 静默返回 0 会让 `dd` 悄悄写错位置。

#### 删非空目录必须失败（POSIX rmdir / ENOTEMPTY）

`fs.delete` 只删**空**目录/文件：`ext2.delete` 先看目标目录里有没有非 `.`/`..` 的条目，有就返回
`directory not empty`。曾经的 bug: 不检查就直接把目录条目合并掉 —— 子 inode 仍被占用却没有任何
目录项指向它们，真机跑完 `e2fsck` 报 `Unconnected directory inode` + `Unattached inode`(数据静默
丢失)。宿主用真实 ext2 驱动即可复现(`tools/ext2test.lua` 里锁住了这条)。
**用户态不要靠"自己先判空"兜底**: 直接调 `fs.delete` 的地方(真机自检脚本就是)照样会弄坏盘 ——
`rmdir` 保留自己的判空只是为了给出 POSIX 那套措辞; `rm -r` 是递归删干净再删目录(正常路径)。

#### 跨块目录的"块首条目"也能删（曾经的 rm -rf 陷阱）

`ext2.removeDirEntry` 删条目时把被删条目的 `rec_len` **并入前一条**（条目直接从块里消失，不留
`ino=0` 的空洞）。**块首条目没有前一条**：老代码在这里直接 `return nil, "cannot remove first dir
entry"` —— 于是目录一旦跨块（>1KB 后每块第一条各中一次），那些条目就永远删不掉：真机 `rm -rf`
一个大目录报这个错、目录删不干净（`scripts/regex_test.sh` 的自检把它试出来了）。
修法：块首条目置 **`ino=0` 标空闲**，`rec_len`/`name_len` **原样留着**（`addDirEntry` 扫到
`ino==0` 的条目会整条复用；缩 `rec_len` 或清 `name_len` 反而会留下 e2fsck 判
`directory corrupted` 的空洞）。`tools/ext2test.lua` 里锁着这条（200 个文件的跨块目录逐条删完 +
宿主 `e2fsck` 判干净）。

**用户**：`/etc/passwd` `name:x:uid:gid:fullname:home:shell`、`/etc/shadow` `name:salt$hash`、
`/etc/group`；`login` 提示用户名/密码（隐藏回显），验证通过后按该用户 `uid/gid` 起 `sh`。
用户管理命令（`passwd`/`useradd`/…）与内核 `user.*` 写 syscall 见下文「用户管理」。

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

**终端的原始模式（`setRaw`）与按键字节流**：句柄上有 `setRaw(enable)`（Linux termios 的
`ICANON|ECHO` 位）：开了之后不回显、不按行缓冲，`read(n)` 拿到的是**终端字节流**，特殊键是
ANSI 序列 —— 与 Linux 上 raw 终端 + `read(2)` 的契约完全一致，`more`/`less` 就建立在这条契约上。

| CC 按键 | 发出的字节 |
|---|---|
| 方向键 | `ESC [ A/B/C/D` |
| `Home`/`End` | `ESC [ H` / `ESC [ F` |
| `PgUp`/`PgDn` | `ESC [ 5~` / `ESC [ 6~` |
| `Insert`/`Delete` | `ESC [ 2~` / `ESC [ 3~` |
| `F1..F4` | `ESC O P/Q/R/S` |
| `F5..F12` | `ESC [ 15~ 17~ 18~ 19~ 20~ 21~ 23~ 24~` |
| 能产生字符的键 | 走 `char` 事件的字节（`Enter`→`\r`→`\n`、`Backspace`→`\b`、`Tab`→`\t`） |
| `Ctrl+A..Z` | `\1..\26`（`^C`/`^Z` **例外**：ISIG 保持打开，仍然是信号） |

- **ISIG 保持打开**（与 Linux 的 cbreak 一致）：`^C`/`^Z` 照旧变成 SIGINT/SIGTSTP，
  所以分页器里 `^C` 是被信号杀掉的（退出码 130）、`^Z` 能挂起；而 `^D`/`^L`/`^U`/`^W`
  在原始模式下是**普通字节**（行规程不再解释它们）。
- **按键去重闩锁（`ctx.dupChar`）**：CC 对 `Enter`/`Backspace`/`Tab` 与 `Ctrl+字母`可能
  **同时**发 `key` 与 `char` 两个事件（GLFW 的 char 回调）。两种都处理就会"按一次删两个字符/
  出一个空行"，所以 key 事件处理完会把期望的字节记在 `ctx.dupChar` 上，紧随其后、值相同的
  那个 char 事件被丢掉。canonical 模式同样吃这条（否则真机上按一次回车会空两行）。
- 真机验证：`scripts/rawtty_test.ko`（内核态注入按键）+ `scripts/rawtty_verify.lua`
  （在 `/dev/tty0` 上 `setRaw` 并读回字节），由 `tools/realmachine.py` 断言
  `/tmp/rawtty.hex` 恰好是 `78201b5b41370a04`（`x`、空格、↑、`7`、只出现一次的 enter、`^D`）。

**工具**：`ls`、`cat`（默认按字节拷贝，见「设计要点」；`-n/-b/-s/-E/-T/-v/-A` 才按行）、
`mkdir (-p)`、`rm (-r|-f)`、`cp (-r)`、`mv`、`touch`、`head (-n)`、`tail (-n)`、
`sleep`（GNU 风格：小数秒 + `s/m/h/d` 后缀 + 多操作数求和；50ms 分片睡眠，信号可及时打断）、
`dd`（POSIX 子集；拷贝循环 50ms 让出，`^C` 打完统计后退出 130，见「设计要点」的信号那一节）、
`wc (-l|-w|-c)`、`grep`（POSIX + GNU：`-E`/`-G`/`-F` 方言、`-n -i -v -w -x -c -l -q -o -r -s -H -h -e`，
退出码 0/1/2 同 GNU）、`sed`（GNU 子集：`s/y/d/p/q/a/i/c/=`、行号/`$`/正则地址与区间、`-E`/`-r`、
`!` 取反、`-n -s -e -f -i`）、`ed`（POSIX 子集：`a/i/c/d/p/n/l/s/t/m/r/w/q/u/g/v/=`、地址 `.` `$` n `/re/` `+n` `-n`、输入模式以 `.` 结束）、`kill`、
`ps`/`pgrep`/`pkill`/`killall`（进程管理，见上文「procfs 与进程管理」）、`login`、
`chmod`（八进制 + 符号模式 `[ugoa]*[+-=][rwx]*` + `-R` 递归）、`chown`（`[OWNER][:[GROUP]]` + `-R`）、
`mount`（挂载 `/dev/sdX`、`UUID=d<磁盘ID>[-N]`/`c<电脑ID>[-N]` 或镜像路径；无 `-t` 时按设备类型；
无参列出挂载含 `ro|rw`）、`umount`、
`blkid`（列出设备 UUID/TYPE/LABEL）、`lsblk`（树状列出设备/大小/类型/挂载点）、
`systemctl`（init 控制）、`syslogd`/`logger`/`dmesg`/`logrotate`（日志）、
`passwd`/`useradd`/`userdel`/`usermod`/`groupadd`/`groupdel`/`id`/`whoami`/`groups`（用户管理，见下文）、
`lp`（打印文件到 `/dev/lpN`）、`clear`（清屏：写 ANSI 复位+清屏+归位）、`sh`。
各工具支持 POSIX 的 **`--` 结束选项** 标记：`rm -- --help`、`touch -- -file`、`ls -- --ff` 等，用于操作以
`-`/`--` 开头的文件名；单独的 `-` 视为普通操作数。

**sh（POSIX 核心子集）**：变量与展开（`$x`/`${x}`/`$?`/`$#`/`$@`/`$*`/`$!`/`$-`/`$1..`）；单/双引号；
**命令替换**（`$( )` 与反引号）、**算术展开**（`$(( ))`）、**路径名展开**（通配符 `*` `?` `[ ]`）—— 见下文
「词展开：命令替换 / 算术 / 通配符」；
`if/elif/else`、`for`、`while`、`case`、函数（位置参数）、`[ ]`/`test`（`=` `!=` `-n` `-z` `-eq/-ne/-lt/-le/-gt/-ge`
`-e/-f/-d/-s/-x/-r/-w`、`!`）；`&&`/`||`/`;`；文件重定向（`>` `>>` `<`）；管道（`|`，每元素一个进程/内建，
经内核 pipe 缓冲传递，`$?`=末元素退出码，生产端写满/消费端读空时让出调度器，broken pipe 中止写端）；内建
`cd pwd echo read exit help jobs fg bg wait kill test [ true false : . set export unset break continue return shift alias unalias command getopts hash umask`；
`time` 是 POSIX **保留字**（不是内建），只在管道首词位置识别（`time [-p] pipeline`），计时文本走 stderr，
`real` 由 `os.epoch("utc")` 取差、`user` 由 `os.clock()` 取差、**`sys` 恒为 0**（无内核/用户态记账）。
**别名**（`alias`）：POSIX 是在**解析期**做首词替换，Delin 改成**求值期**替换（认出首词是别名后把
"别名体 + 其余已展开的词"重新解析执行）—— 日常用法（别名带参数/管道/重定向）一致，**已知偏离**：
别名体里的位置参数展开时机不同，且不参与"词内"替换（`alias e=echo; e$x` 在 POSIX 里能展开，这里不能）。
**`hash`** 维护命令路径缓存（`searchPath` 命中即不再走 PATH；**PATH 一变缓存整体作废**）。
**波浪号展开**（POSIX 2.6.1，期望值逐条对着 bash 核过）：`~` → `$HOME`，`~user` → 该用户的家目录
（走 passwd，`syscalls["user.get"]`），`~/x`、`~root/x` 照常；**只在词首**且 `~` 前缀整个落在
**未加引号的原文**里才展开 —— `~nosuchuser`、`~$USER`、`~"x"`、`a~b` 一律原样保留（bash 同此），
`"~"` 也不展开。展开结果按**未加引号**处理，所以 `~/dir/*.txt` 照样做路径名展开。赋值右侧
（`X=~/bin`）也展开（bash 同此），但不做字段分割与通配符（POSIX）。**已知偏离**：赋值右侧里
`:` 之后的波浪号（`PATH=~/a:~/b`）不展开，bash 会展开。

**`setopt` / `unsetopt`**（zsh 风格）：管的是**所有真实存在的开关** —— 核心四个与 `set -o` 同源
（`errexit` `nounset` `verbose` `xtrace`），另加 desh 的三个（`autosuggest` `correct` `history`，
它们本来就只是 `DESH_*` 变量，所以两边改的是同一处状态）。名字大小写不敏感、`-` 当 `_`，
支持 zsh 的 `NO_` 前缀（`setopt no_history` == `unsetopt history`，反向同理）；无参时列出
"已开/已关"的选项，`--help` 给出全部选项与说明。**不认识的开关 fail-fast 退出 2**（与仓库里
其它"未知选项"同一约定）—— 静默收下会让脚本以为开关生效了。

**`umask`** 读写进程的创建掩码（缺省 `0022`，随 spawn 继承给子进程），实际收窄由**内核在创建点**统一
应用（见「umask」一节）。**`command`** 绕过函数/别名直接执行，`-v`/`-V` 查询，`-p` 用系统缺省 PATH。
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
因此 `echo 15 > /sys/class/redstone/left/analog` 的失败不会被静默吞掉。
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
`scripts/sh_verify.sh` + `verify-sh.service` 跑并写 `/var/log/sh_verify.log`）、
`scripts/sh_expand_test.sh`（展开自检 95 项：通配符/命令替换/算术，宿主 harness 与真机各跑一次，
期望值逐条对着 bash/dash 核过）、`scripts/sh_intr_test.sh`（宿主专用：提示符处 `^C`）。
**提示符处的 `^C`**：tty 行规程做两件事（`kernel/tty.lua` 的 `tty.ctrlC`）—— 回显 `^C`、丢掉当前行
（读到的是一整行空行），同时把 SIGINT 投给 tty 前台进程组。**交互式 sh 必须在读完这一行之后立刻
消费掉那个 SIGINT**（`src/bin/sh` 交互循环里的 `sigintPending = false`）：它的目的（取消输入行）已经
达成，留到下一轮就会被 `pollWait` 当成"^C 中断" —— 症状是"提示符处按过 ^C 之后的那条**外部**命令
静默不执行（退出码 130），再下一条才恢复"（历史 bug；内建命令不走 pollWait，所以只有外部命令看得出来）。
`/bin/lua` 的 REPL 用自己那份 `interrupted` 标志做同一件事（读之前清零、读之后消费）。

#### 词展开：命令替换 / 算术 / 通配符

三者都按 POSIX 2.6 的**展开顺序**走：参数/命令/算术展开 → 字段分割（未加引号时按 `IFS`）→ 路径名展开
（通配符）→ 引号移除。实现落在 `src/bin/sh` 的 `lex`（切词的引用掩码 `qm`）与展开层
（`expandGlue`/`expandSegs`/`expandWordList`）。

**命令替换 `$( )` 与反引号**：Delin 无 fork，用 `sh -c <原文>` 起**子 shell**（与 `&` 作业同一套：
`subshellPrologue` 把当前变量、`export` 标记、函数定义与别名注入子进程），stdout 接内核 pipe 读回。
因此语义与 POSIX 一致：子 shell 里的 `cd`/赋值不影响父 shell、位置参数继承、结果末尾换行**全部删除**、
**退出码进 `$?`**（纯赋值 `x=$(false)` 之后 `$?` 也是 1），未加引号的结果按 `IFS` 分割后再做通配符展开，
加引号则整体一个词。反引号按 POSIX 处理 `\``/`\\`/`\$`（其余反斜杠原样保留），可嵌套 `$( )` 与反引号。
输出大于内核管道缓冲（16KB）也不会死锁：读端阻塞时让出调度器，子进程继续写（自检里用 400 行长文本锁着）。

**算术展开 `$(( ))`**：完整 POSIX 运算符集 —— 一元 `+ - ! ~`、`* / % + -`、`<< >>`、比较
（`< <= > >= == !=`）、`& ^ |`、`&& ||`、三目 `?:`、赋值（`= += -= *= /= %= <<= >>= &= ^= |=`）、
自增自减（前缀/后缀）、逗号。变量**读写 shell 变量**（`i=0; echo $((i+=1))` 之后 `$i` 是 1），
变量的值若本身是表达式就递归求值（`x='1+2'` → 3；未定义/空 → 0，与 bash 一致），深度上限 24 层防自引用。
表达式求值**前**先做参数/命令替换（`$(( $(echo 2)+3 ))` 是 5）。`CC` 的 Lua 没有位运算，
`& | ^ ~ << >>` 按 **32 位补码**用纯算术实现；`/` 与 `%` 是 C 语义（**向零截断**，`-7/2 = -3`、`-7%2 = -1`，
`math.floor` 的向下取整会差 1）。**出错一律 fail-fast**（除零/非法记号/缺操作数 → 报错 + 退出码 1，
当前命令中止但不退出 shell），不当 0 静默混过去。`$((` 的收尾判定与 bash/dash 一致：深度归零的 `)` 后面
必须紧跟另一个 `)`，所以 `$((-7)%2)` 是语法错、`$(( (-7)%2 ))` 才对。

**路径名展开（通配符）**：`*`（任意，含空）、`?`（一个字符）、`[abc]`/`[a-z]`/`[!abc]`（字符组，`^` 也当取反）、
`\c` 转义。规则对着 POSIX 2.13.3 与 bash/dash：**只有展开前就在源码里、且未加引号**的
`* ? [` 才是通配符（切词时逐字符记引号掩码 `qm`，所以 `a"*"*` 只有后一个 `*` 生效）；按 `/` **逐段**匹配
（`*` 不跨 `/`，`$(...)`/变量的结果里的 `/` 是普通字符）；`.` 开头的目录项只能被模式里也写了 `.` 的匹配
（`*` 不含隐藏文件）；结果**按排序**输出；`*/` 只匹配目录；**没有匹配就保留原词字面**（POSIX 默认，
`echo *.nope` 打印 `*.nope`）；只对同时含通配符的分量列目录，无通配符的分量走精确比对（路径不存在即无匹配）。
**已知偏离**：`.*` 不会列出 `.` 与 `..`（真实 shell 会）—— Delin 的 `fs.list` 根本不含这两个条目；
不支持 bash 的 `**`(globstar) 与花括号展开 `{a,b}`（非 POSIX，遇到按字面处理）。

**通配符作用的位置**（POSIX 标准位置）：命令词与参数、`for ... in` 列表、**重定向目标**；
**赋值右侧不展开**（`X=*.txt` 存的是字面 `*.txt`），`case` 的**模式**走的是模式匹配而不是路径展开
（`case` 词本身只做参数/命令替换，不做字段分割与通配符）。重定向目标展开后必须是**恰好一个词**，
否则 fail-fast 报 `<words>: ambiguous redirect` 并置退出码 1（bash 同此，不静默挑一个）。

**子 shell 的起始 cwd**：`sh` 启动时从 `/proc/self/cwd` 取内核里这个进程的 cwd（而不是按 `$HOME` 猜）。
这不是洁癖：`&` 的作业与 `$( )` 都是**新进程**，内核已把父 shell 的 cwd 继承给它，按 `$HOME` 初始化会让
`cd /tmp; echo $(ls *.txt)` 静默列出 `/root` 下的东西。配套地 `login` 现在按 login(1) 语义用
`cwd = <家目录>` spawn 用户 shell（登录 shell 的起始目录是家目录）。

#### `desh`：交互式增强 shell（与 `sh` 共用核心）

`/bin/desh` 是"zsh 那一档"的交互层：**词法/解析/展开/内建/作业控制全部与 `sh` 是同一份代码**，
它自己只做"键盘到屏幕"这件事。于是脚本语义不会漂：`desh -c '...'` 与 `desh script.sh` 的行为与
`sh` **逐字节一致**（`scripts/desh_test.sh` 在宿主差分里锁着），差别只在"stdin 是终端且没有脚本
参数"时的读行方式。

**共享方式（构建期拼接 + 显式接口表）**：实现放在 `src/lib/shcore.lua`，`src/bin/sh` 与
`src/bin/desh` 各自用 `--#include src/lib/shcore.lua` 把它拼进来（见「构建」一节的 `#include`）。
为什么不做运行时 `require`：目标机的进程环境是白名单（`kernel/procenv.lua`），`/bin` 工具**没有**
`require/dofile/loadfile`，只能构建期拼成自包含单文件。入口是 **`shCoreMain(ui, S)`**（核心里的
**函数**而不是顶层代码 —— 拼接后两个入口共享同一段 chunk，顶层 `return` 会把产物截断，
`tools/include.lua` 在构建期就拦；另外见「local gate」：chunk 级 local 也要不得）：

| 参数 | 作用 |
|---|---|
| `ui = nil` | 经典行为（`/bin/sh`：tty 行规程读行，报错前缀 `sh:`） |
| `ui.name` | shell 名（报错前缀、PS1 的 `\s`、用法文本） |
| `ui.readLine(prompt, cont)` | 交互式读一行（`cont` = 续行）；返回 `nil` = EOF、`""` = 取消（^C）。**返回前必须把终端恢复成规范模式**（子进程要拿回正常的行输入） |
| `ui.commandNotFound(cmd)` | 命令找不到时的额外提示（did-you-mean）；只打印，不动退出码 |
| `ui.setup(S)` | 接口表填满后、命令开跑前调一次；返回 `false` 表示直接收摊（desh 用它读 rc/载历史/覆盖 `help`） |
| `ui.onExit()` | `shCoreMain` 返回前调用（desh 用它落盘历史） |
| `S`（表，`sh` 传 nil） | 前端**唯一**能看到核心的地方：`name/vars/builtins/aliases/fs/resolve/evalProgram/errln/outln/stdin/stdout/interactive/lastExit()`。desh 不再能直接看见核心的局部变量——这是把两边各自关进函数之后的必然结果，也顺带成了一条**显式接口** |

**能力与缺省值**（都是普通 shell 变量，`deshrc` 里改）：

| 能力 | 行为 |
|---|---|
| 行编辑 | 方向键/Home/End/Delete/PageUp/Down 不绑定；`^A ^E ^B ^F ^K(杀到行尾) ^U(杀到行首) ^W(删词) ^Y(粘回) ^L(清屏)`；`^D` 空行=EOF、行中=删一字符 |
| 历史 | 上/下、`^P`/`^N`（`PS2` 续行下不翻历史）、`^R` 增量搜索（`^R` 再往前、回车直接执行、ESC/方向键回到编辑、`^G` 取消）；文件 `$HISTFILE`（缺省 `~/.desh_history`，条数 `$HISTSIZE` 缺省 200）；**行首空格的命令不入历史**（bash 的 `HISTCONTROL=ignorespace`）、连续重复只记一次；每条追加写、退出时按 `HISTSIZE` 整体重写一次 |
| Tab 补全 | 命令（`$PATH` 里可执行的普通文件 + 内建 + shell 函数 + 别名）、文件/目录、`$变量`（含 `$? $# $@ $* $$ $! $-`）；唯一候选直接补齐（目录补 `/`、其余补一个空格）；多候选先补公共前缀，再 Tab 列候选（**超过 50 个先问 `display all N possibilities?`**，bash 同义），第三次起每按一次 Tab 依次代入（menu-complete）；词边界与 bash 的 `COMP_WORDBREAKS` 同义（含引号），命令位置包括行首/`\| && \|\| ;` 之后/`then do else elif time !` 之后 |
| 智能提示 | 历史里**最近一条以当前输入开头**的命令的后半截，用 `\e[90m`（亮黑=灰）画在光标之后；`→` 或 `End` 接受，回车**只执行真实输入**；只在光标处于行尾、视图未被截断时画 |
| 错误更正 | `command not found` 时打一行 `desh: did you mean 'ls'?` / `did you mean one of: ...`；距离用 **OSA（相邻换位算 1 步）**，阈值 1（名字 ≤3 字节）或 2，长度差也要在阈值内；同距离时"同一组字母的重排"优先且只报这一档（`sl` → 只报 `ls`，不会把 `nl sh` 一起列出来）；**只建议不擅自改命令**（不自动纠正执行） |
| 配置 | `/etc/deshrc`（系统）→ `$DESHRC` 或 `~/.deshrc`（用户），**都是普通 shell 脚本**（用同一个 `evalProgram` 跑，别名/函数/变量都能定义）；开关 `DESH_AUTOSUGGEST` `DESH_CORRECT` `DESH_HISTORY`（`0`/空/`no`/`false` 为关）、`DESH_SUGGEST_COLOR`（SGR 参数，缺省 `90`） |
| 内置 `help` | desh 覆盖了核心那份 `help`，打的是交互层的能力与开关（`desh -c 'help'` 也走这条） |

**设计要点（都是踩过或想过坑的地方）**：

- **原始模式只在"读键盘"时开**：`editLine` 进入时 `stdin:setRaw(true)`，把行交给核心**之前**一定
  `setRaw(false)` —— 子进程（`read` 内建、分页器、`ed`）需要拿回规范模式的行输入，与 Linux 上的
  shell 一致。副作用：`setRaw(false)` 会清掉内核 tty 的 `keyBuf`，快速连打的下一个键可能丢
  （与"type-ahead 被冲刷"同义，可接受）。
- **`^C` 要能把阻塞中的 `read` 叫醒**：原始模式下 `^C` 由内核 tty 处理（回显 `^C`、丢当前行、
  给前台进程组投 SIGINT）。但行编辑器装了 SIGINT 处理器（作业控制那套），进程不会被默认动作杀
  掉 —— 于是 `kernel/tty.lua` 的 `rawRead` 也和 `readLine` 一样记账 `ctx.reading`，
  `abortLine` 才能置 `ctx.intr`，`read` 返回 `nil,"interrupted"`（Linux 的 EINTR 语义）。
  没有这一步，`^C` 之后编辑器会一直阻塞到用户再按一个键才醒。分页器不受影响（它们被默认动作
  杀掉）。宿主测试台照抄了这一条（`DELIN_HARNESS_TTY=1` 下管道里的 `\3` = EINTR + 投 SIGINT）。
- **长行横向开窗而不是折行**：CC 屏只有 51 列，折行重画在滚动边界上极易画花；`paint()` 把窗口
  两端用 `<`/`>` 标出来，并保证**最后一个字符不落在最后一列**（CC 终端会自动换行，会把光标甩走）。
  已知偏离：没有"多行折行显示"。
- **光标列宽要按"可见宽度"算**：`PS1` 里可以有 `\e[31m` 这类序列，`visWidth()` 去掉 ANSI 再数。
- **候选菜单的分行**：列候选前先换行，列完停在行首，再重画输入行（`askListAll` 与 `listCandidates`
  的契约就是"返回时光标在新行行首"）。
- **`desh` 这一层也整个包在一个函数里**（`deshMain`），只把接口表 `S` 当 upvalue：CC 的 Lua
  沿嵌套链累加局部变量（见「local gate」），两边各自在函数里才不会互相挤。
- **`^Z` 在提示符处不挂起 shell**：核心在作业控制开启时就给 SIGTSTP 装了空处理器，于是它只让
  `abortLine` 置 intr —— desh 把它当成"取消当前行"（与 `^C` 同路）。

自检：`scripts/desh_test.sh`（非交互 24 项，宿主与真机各跑一次，进 `--check` 的差分清单）、
`scripts/desh_tty_test.sh`（宿主专用 33 项按键自检：补全/历史/`^R`/建议/纠错/`^C`/`^U`/长行开窗/
历史落盘/deshrc 五组开关）。

#### 选项约定：未知选项与"未实现"的选项一律 fail-fast

工具的选项解析必须**分清三种情况**，不许把任何一种静默吞掉（判据都对着宿主 GNU 实测过）：

| 情况 | 行为 | 退出码 |
|---|---|---|
| **未知选项**（GNU 也没有，如 `ls --zz-bogus`、`cp -%`） | 报 `invalid option`/`unrecognized option` | **与宿主 GNU 逐工具一致**：coreutils 文本/文件类（`cat cp mv rm mkdir touch chmod chown ln du df head tail wc uniq od cut tr sed find xargs cksum comm csplit expand unexpand fold join paste pr split strings tee basename dirname readlink realpath pathchk file dd dmesg logger systemctl mount umount lsblk ps kill`）是 **1**；`ls`/`sort`/`grep`/`cmp`/`printf`/`diff`/`patch`/`pgrep`/`pkill` 是 **2**（实测：`ls --zz` 给 2，`cat --zz` 给 1） |
| **GNU 有、Delin 故意不实现**（如 `dmesg -s`、`touch -d`、`umount -l`） | 报 `option 'X' is not supported` | **2**（这是 Delin 自己的约定，GNU 没有对应行为） |
| **缺选项参数**（`-n` 后面没有值） | 报 `option requires an argument` | 与上表同工具的未知选项码 |

历史教训：一批工具在 `stderr(...)` 后面写**裸 `return`**（内核把 nil 当退出码 0），于是
`ls --nope`、`cp --nope`、`mkdir -%`、`mount -%` 都"报了错却退出 0" —— 脚本据此判断会走错分支；
`chmod`/`mkdir`/`touch`/`mount` 的站点已逐个改成显式码，`ls`/`cp`/`mv`/`wc` 还补上了
缺失的长选项分支（以前 `--nope` 会掉进短选项循环，报成 `invalid option -- '-'`）。

**"接受但什么都不做"比缺选项更危险**，因为脚本会据此认为副作用发生了。已清除的几处：

- `touch -a/-m/-d/-r/-t/-h`：以前**接受却完全 no-op**（连 mtime 都不碰，而 ext2 明明持久化 mtime）。
  现在一律 fail-fast 退出 2；真正实现要等 ext2 的 `setTimes`（见「已知缺口」）。
- `mount -f/--fake`：GNU 是 **dry-run（只检查不挂）**，Delin 以前照样真挂上去。现在 `-f` 是
  dry-run（`-v` 时打印 `would mount ...`），**不调用 `fs.mount`**。
- `umount -l/-f`：GNU 是惰性脱离/强制卸载，Delin 的 VFS 没有引用计数 —— 以前"声称成功却什么都没变"，
  现在退出 2；`-v` 才是真的开了详细输出。
- `dmesg -n/-D/-E`：真的改内核控制台级别（见下），不是收下就完事。

**`dmesg` / `/dev/kmsg` 的跟读**：`-w` 先冲掉现有缓冲再持续等新消息，`-W` 先用
`h:seek(stats.next)` 跳过历史；两者都靠**轮询 `readAvailable()` + `os.msleep(50)`**（句柄的
`readLine` 只在 `close()` 后才返回，不能拿来跟读），`^C` 由 SIGINT handler 置标志收尾、退出码 130。
`/dev/kmsg` 的每个读者各有自己的游标，所以跟读的 `dmesg` 不会把 syslogd 的消息抢走。
时间戳格式与 util-linux 逐项对齐：缺省 `[%5d.%06d]`、`-d` 是 `[绝对 < 间隔>]`、`-e` 是 `[  +间隔]`、
`-T` 是 ctime、`--time-format=iso` 带 `,微秒`。`-x` 的前缀是 GNU 的 `kern  :info  : `（不是 `kern.info: `）。
内核侧新增 `klog.clear()`（`dmesg -c/-C`）与**控制台日志级别**（`klog.setConsoleLevel`，由
`boot.emit` 用 `klog.consoleWants(pri)` 判定是否上终端 —— ring buffer 照收，与 Linux 一样）。

**`tail -f` / `-F` 的跟读**：Delin 没有 inotify，按 poll 语义做 —— 每次醒来**重开文件**
（ext2 的 `open` 会把整份内容快照进内存，老句柄永远看不到追加）、`seek(set, off)` 再按块读；
文件变小 = 截断/轮转，打一条 `file truncated` 并从 0 重读（GNU 同此）；`--pid=PID` 靠
`fs.exists("/proc/<pid>")` 判活；`-s` 是轮询间隔（缺省 1.0s）。

**`head`/`tail` 的符号**：`tail -n +N`（从第 N 行起）与 `head -n -N`（除末尾 N 行）以前**把符号丢掉**，
于是"打印末 N 行"，是**静默输出错行**而不是报错；现在按 GNU 语义实现（`-c +N`/`-c -N` 同理）。
组合短选项（`-qv`、`-n5v`）与长选项的空格形式（`--lines 5`）也补齐了；`-q`/`-v` 是**后者覆盖前者**
（`head -vq` 无表头，GNU 同）。

**`grep` 的 `-r` 与 `-R`**：以前两者同一条路径，且用 `fs.isDir`（跟随符号链接）递归 ——
树里放一个 `ln -s .. loop` 就**无限递归**（真机症状：命令永远不返回）。现在 `-r` 不下降遍历中遇到的
符号链接（命令行上显式给的仍跟随），`-R` 全部跟随，两者都用"符号链接链解开后的规范路径"做
**已访问集合**，环被挡住。新增 `-A/-B/-C/-NUM`、`--group-separator/--no-group-separator`、`-m`、
`-f`、`-L`、`-I`、`-a`、`-b`、`-z`、`--include/--exclude/--exclude-dir/--exclude-from`、
`--color[=WHEN]`（认 `GREP_COLORS`，`auto` 看 stdout 的 `isTTY`）、`--label`。组分隔符（`--`）
只在真的带上下文时出现（GNU 同）。

#### 真机四处坑（都是"宿主全绿、真机才露头"）

0. **原始模式里 `routeKey` 把 key 事件交给了规范模式的 `feedKey`**（`kernel/tty.lua`）：
   真实按键的 `key` 事件是**调度器经 `tty.routeKey` 送进来的**（见 `scheduler.lua` 的
   `routeEvent`：`char/paste` → `feedInput`，`key/key_up` → `routeKey`），而 `routeKey` 尾巴上
   无条件调 `feedKey`（规范模式那套）—— 于是原始模式的行编辑器**永远收不到** Enter 的 `\n`
   （被当成"整行入队 + 去重闩锁"），Tab/方向键同理。症状：真机上 `desh` 的行编辑器敲回车
   毫无反应、补全/方向键全失效，只有 `^C`（走上面那条 **raw 感知的** ctrl 分支）有反应。
   修法：`routeKey` 尾巴也按 `ctx.raw` 分派到 `rawFeedKey`（与 `feedInput` 的 key 分支一致）。
   **为什么宿主测不出来**：`scripts/rawtty_test.ko`（以及所有测试台路径）直接喂 `tty.feedInput`，
   走的是 raw 感知的那条路 —— 载荷现在改成**照抄调度器的路由**（key → `routeKey`），门禁才有意义。

#### 真机三处坑（都是"宿主全绿、真机才露头"）

1. **Cobalt 的局部变量上限**：见「构建期门禁（local gate）」。给 sh 核心加一个 helper 就把
   `/bin/sh` 弄成装载失败，`init` 的每个服务都报 `FAILED: /bin/sh: nil`。
2. **`spawn` 失败的错误消息在两边放在不同位置**：内核 `process.spawn` 失败返回
   `(nil, nil, "load failed: …")`（消息在**第 3 个**返回值），而宿主测试台的 spawn 桩返回
   `(nil, "load failed: …")`（第 2 个）。`sh` 的 `spawnChild` 以前只取第 2 个，于是真机上
   装载失败只显示 `sh: desh: nil`，原因被吞掉。现在有 `spawnErr(e1, e2)` 两个都看。
   —— 这条本身也是"报错吞掉原因"的典型，写新代码时注意 X 个返回值都要接住。
3. **两个真机按键注入载荷会互相拆台**（`scripts/intr_test.ko` 与 `scripts/rawtty_test.ko`）：
   两者都包 `os.pullEventRaw` 并在收工时 `os.pullEventRaw = pull`。谁**先**收工都会把**后包上去**
   的那层从链条里抹掉（应该 LIFO），于是另一个载荷从此不再被调用 —— 症状是它那条门禁
   **无声地**失败（实测：`intrtest` 先收工，`rawtty` 的包装被拿掉，`/tmp/rawtty.hex` 永远不出现）。
   修法：各自记住自己的包装函数，**只在自己还是当前那一层时**才还原。
   另外 `tools/realmachine.py` 追加模块清单时曾经缓存住"读到的清单"，两个注入点（intrtest /
   rawtty）互相覆盖 —— 后写的把前一个刚加的名字抹掉，机器的模块清单里没有它，载荷静默不跑
   （"正对照缺失"就是这个）。现在统一走 `add_module()`，每次都重新读一遍镜像里的 manifest。

#### 真机验证的三种节奏（别每次都跑全量）

`tools/realmachine.py` 默认那条路（关机 → 重建镜像 → 注入 → 开机 → 等 verify.log → 重启电脑 4
→ 等自检跑完 → dump 全部日志 + 逐条门禁）一轮 **6 分钟起**，它是"发布前的全量门禁"。
改一行就想看一眼真机时用另外两个模式：

| 模式 | 用途 | 一轮耗时 |
|---|---|---|
| （默认） | 全量门禁：所有自检 + ^C / rawtty / dd-siSIGINT 等真机门禁 | ~6 分钟 |
| `--fast --wait-file <镜像内路径> --grep <tag>` | 只重启 #3、等某个 marker 文件出现、只 dump klog 里带 tag 的行；跳过宿主 ext2 回归与电脑 4 | **~40-90 秒** |
| `--clean` | 只装干净镜像（只有 dist 产物，不注入任何验证载荷）并开机，交给人手工用 | ~1 分钟 |
| `--desh-probe` | 注入 `scripts/desh_probe.ko`（交互式诊断载荷：自动登录 → 起 desh → 敲命令 → 把 tty 状态与**每个真实按键事件**写进 klog/文件），并**自动禁用会抢 tty0 的 intrtest/rawtty** | 陪 `--fast` 用 |

**排查交互式问题时值得先想到它**：`desh_probe.ko` 的按键注入**照抄调度器的路由**
（可打印字符 → `feedInput`，回车 → `routeKey` + 随后那个 char 事件），所以它能复现真实键盘的
行为 —— 上面第 0 条坑就是这么定出来的（只用 `feedInput` 的话永远复现不出来）。
`--desh-probe` 与 intrtest/rawtty 会互相打架（三个载荷都在同一个 tty0 会话上打字），所以
它一开就自动把那两个载荷关掉。

#### 真机验证（`tools/realmachine.py`）为什么要快就得这么写

一轮真机验证的开销分三块，优化前后差 3 倍（~8-10 分钟 → 2-3 分钟）：

| 环节 | 以前 | 现在 |
|---|---|---|
| 重建根镜像 | 每次 `deploy.py` + 40 来次 `debugfs` 注入 | **payload 指纹**（`dist/` + `scripts/` 内容哈希）命中就复用上一轮注入好的 `root.img`；`--rebuild` 强制重建 |
| 等开机 | `sleep(75)` + `sleep(30)` **盲等 105s** | 轮询**镜像里**的 `/var/log/verify.log` 是否变了（实测 60-70s 即可继续），最长 `WAIT+30s` |
| 等服务跑完 | 固定等，或收上半截日志 | 先等 `verify.log` 出现 `=== verify done ===`；**日志 60s 不再增长就判定服务已死**并立刻报错（真机上偶发服务在 mkfs/fsck 段停住，以前要白等满 6 分钟）；再等 `posix_verify.log` 的 `== summary:`（它是**另一个**服务，不等就会收到半截日志，看起来像"改动没生效"——踩过） |

两个反直觉的坑，写在代码注释里：

- **别用 `/mnt/disk/0/delin.log` 判"起来了没有"**：那是 NFS 看到的游戏侧文件，开机 100 秒后
  内容还是旧的（知识库「电脑文件（NFS 挂载，不稳定）」记着这条），拿它当条件会白等一整轮；
  判据要用镜像里的 `verify.log`（`debugfs -R cat`）。
- 电脑 #4 那份 `/delin.log` 同理，只等固定 15s。

#### 管道端是"共享句柄对象"：谁关谁 EOF（以及由此而来的一条已知缺口）

内核的匿名管道端（`kernel/pipe.lua`）是**共享的句柄对象**：`close()` 直接把对象标成 closed 并把
`writers`/`readers` 减一，句柄对象本身没有"每个进程一份引用"的概念。`sh` 的管道与命令替换
**依赖**这一点：

- 命令替换里父进程**不能**关写端（`src/bin/sh` 的注释写得很明白）：一关就等于替子进程关了，
  读端立刻 EOF；
- 管道元素被重定向覆盖时，`sh` 会主动 `close()` 那些用不上的端，让对端读到 EOF。

**已知缺口**：因此 `xargs` / `find -exec` 这类"起**一串**子进程、共用同一个 stdout"的工具，
第一个子进程退出就把管道关了，后面几个的输出全丢：

```
printf 'a:b:c' | xargs -d: -n1 echo | wc -l     # 期望 3, 实际 1
find . -exec echo {} \; | wc -l                 # 同理
```

重定向到**文件**不受影响（文件句柄没有 `.pipe` 标记，子进程退出不关它），所以
`xargs ... > out`、`find -exec ... > out` 都正常。

正确的修法是 POSIX 那套："每进程一份引用 + 父进程 spawn 之后关掉自己那份"。`kernel/pipe.lua`
已经留了 `h:ref()`（复制一份独立引用、共享同一个缓冲区）。**本轮试过两条路都不通，已回退**：

1. 在 `process.spawn` / `proc.exec` 里统一 `ref()` —— 把命令替换与 `tee_verify.lua` 探针的
   EOF 语义弄坏了（父进程那份引用永远不关，读端等不到 EOF，真机上直接**挂住**服务）；
2. 只在 `xargs`/`find` 里 `ref()` 并在子进程退出后关掉 —— 判据写成 `h ~= io.stdout()` 是错的
   （内核里 `io.stdout()` 可能每次返回新的包装对象），于是把**进程自己的 stdout** 关掉了，
   真机症状是 `xargs` 退出码 1、输出文件全空。

要接着做的话：把 `sh` 的管道/命令替换改成"spawn 后关自己那份"，再在 `proc.exec` 统一 `ref()`，
并给 `pipe.ref()` 补一条宿主/真机回归（多子进程共写管道 + 命令替换 + tee 探针三条一起验）。

#### `os.msleep` 与 HSE：让出 ≠ 延迟

装了 `cc_hse.ko`（HSE 时钟，`hse.setFrequency` 默认 2000Hz = 每拍 0.5ms）之后 `os.msleep` 的语义是：

| 参数 | 行为 | 实际时长 |
|---|---|---|
| `ms <= 0` | 拉模式等 **4 个 tick**（一次让出） | ≈2ms（**不是** 50ms） |
| `0 < ms < 50` | 逐拍等够（每拍一个唤醒事件） | ≈ms |
| `ms >= 50` | 一次 **CC 定时器** `os.sleep(ms/1000)` | ≥ms（CC 睡眠按服务器刻量化） |

两条推论，写工具时必须照着办：

1. **"让出"用 `os.msleep(0)`，判据是"累计了多少 CPU 时间"而不是次数**，项目的统一写法是
   `yieldCheck` + 一个可配时间片：

   ```lua
   -- 默认 50ms; 真·HSE 快让出(一次 ~2ms)的机器可用 DELIN_YIELD_MS=2 换低延迟
   local _sliceMs = (type(env) == "table" and tonumber(env.DELIN_YIELD_MS)) or 50
   local _sliceAt = os.epoch("utc")
   local function yieldCheck() if os.epoch("utc") - _sliceAt >= _sliceMs then _sliceAt = ...; _msleep(0) end end
   ```

   **默认为什么是 50ms（实测，不是保守起见）**：电脑 #3 上量过（探针在普通进程里跑）：

   | 测的东西 | 结果 |
   |---|---|
   | `busy(2000)`（纯忙等，不让出） | 7 ms / 50 次 |
   | `busy(2000) + os.msleep(0)` | 2285 ms / 50 次 → **一次让出 ~46ms** |
   | `os.msleep(0)` 单独 | 919~1156 ms / 20 次 → ~46-58ms |
   | `os.msleep(1)` / `msleep(10)` / `msleep(60)` | ~44 / ~35 / ~46 ms 一次 |

   也就是说：**从一个进程里调用 `os.msleep(ms)`，不管 ms 多小都要 ~50ms（≈ 一个游戏刻）**。
   于是时间片压到 2ms = 进程几乎 100% 的时间在让出 → 命令慢到 ~1 行/游戏刻（真机实测反馈：
   滚动/`ls` 全部拖死）。**HSE 的"2ms 让出"在进程侧拿不到**，把时间片调小只会更慢。
   等子进程/等条件的**轮询间隔**同理：`_pollMs = ... DELIN_POLL_MS ... or 50`。
   反过来，按"每 N 字节让出一次"写的循环同样不可取 —— 让出是本项目里最贵的操作。

   **为什么"HSE 让出只要 2ms"这句话在多进程下不成立，以及它现在的修法**（都是真机实测）：

   `waitNextTick()` 返回的是「**距上一次调用**过了多少拍」——那个计数器是**以外设为单位**记的、
   读后即清，天然假设"只有一个调用者"。而且实测它还**会让出电脑**（泵在外设调用里被挂起的这段时间，
   别的协程会跑起来），所以"同时有两个等待者"是真会发生的。后果（电脑 #3，干净镜像，同一轮对照）：

   | 场景 | 每次 `os.msleep(0)` |
   |---|---|
   | 单进程独自等待（开机后第一个用它的人） | **7.6 ms**（排空后 6.3 ms） |
   | 三个进程同时各调 20 次 | 49.5 / 49.4 / 49.4 ms，排空后 51.5 ms |
   | 并发**都结束之后**，再单进程量 | **49.2 ms**（排空后 52.9）——**粘性退化**，回不到 6ms |
   | 对照：3 个进程纯忙等（不 sleep） | 每迭代 1.4–1.9 ms（不变）→ 慢的是等待路径，不是"3 个进程本身" |

   修法（`cc_hse.ko` v0.3.0）：**计数器只由模块里唯一一个泵循环读**，读到的拍全部累加进一条
   **全系统共享的单调时钟**；要睡的人把自己的 deadline 记在这条时钟上，泵推进到过线为止。
   第二个等待者**绝不**去读那个计数器（会互相扰乱），退回 CC 定时器按 deadline 等（精度粗到
   ≥50ms，但不破坏时钟）；重入泵是硬错误（fail-fast）。
   修完再量：单进程 **7–11 ms**；三个并发时非泵者 ~37–57ms（粗但正确，且不再粘着到整机）；
   并发风暴之后单进程 ~37ms（修之前是 ~49–53ms —— 明显好转，但仍没完全回到 6–11ms，
   剩下的那截看起来在 mod 内部，我们这边已经不再有多读者了）。



   **0.4.0 的尝试（未落地，留档给下一轮）**：既然"计数器只能有一个读者"、而"只有一个等待者能精确定时"
   又不合用，正解应当是「**一个专用泵协程拉事件 + 到点唤醒等待者**」：

   - 泵：内核在第一次有人要睡时 spawn 一个独立进程（`hse-pump`），**只有它**调 `waitNextTick()`，
     把拍累加进共享单调时钟，每推进一次就 `queueEvent("hse_wake")`；没有等待者时它 `os.sleep(0.05)`
     歇着（既不烧 CPU，也不会像 2kHz 推模式那样淹 256 事件队列）。
   - 等待者：进程侧 `os.msleep(ms)` 只算自己的 deadline，然后 `pulledEvent("hse_wake")` 让出，
     醒来重新判定（condition-variable 风格）。进程**永远不碰**那个外设计数器。
   - `cc_hse.ko` v0.4.0 已按这个写完并编过，但**真机上第一次 `os.msleep` 就挂住**（ybench 的日志文件
     被创建、一行没写；探针那侧进程表里既没有 `lua` 也没有 `hse-pump`），而且**在这些上下文里
     `kapi.log`/`kprint` 的日志没有进 `/var/log/messages`**，所以没能定位到是在 `ensurePump`、
     `queueEvent` 还是 `pulledEvent` 那一环卡的。已回退到 v0.3.0（单泵 + 共享时钟：不挂、单进程
     6-11ms、并发时非泵者退回 CC 定时器粒度）。
   - 下一轮要查的四条（按可能性排）：
     1. **进程侧 `os.pullEvent`/`os.queueEvent` 的可用性**：模块拿的是内核态 `_G.os` 的引用，
        但在**进程协程里**调用它是否符合调度器的 resume 契约（scheduler 用 `proc.filter` 匹配事件名，
        见 `kernel/scheduler.lua`）；`os.queueEvent` 是否在 procenv 白名单里（泵进程要用）。
     2. `process.spawn` **从 syscall 内部**（也就是正在跑 `os.msleep` 的进程协程里）spawn 是否安全。
     3. **模块侧日志在运行期是否真的进 klog**（先用 `/tmp` 文件写日志验证，别依赖 klog）。
     4. 泵进程 `waitNextTick()` 的 yield 是否被调度器按事件名正确 resume（外设给的 tick 事件叫什么名字）。
   - 复现工具已就绪：`scripts/desh_probe.ko`（注入按键 + 写 bench 脚本 + 读结果）、
     `python3 tools/realmachine.py --clean --desh-probe --fast --grep X --wait-file /tmp/desh_probe_done`
     （干净系统 + 只注入探针，一轮约 50 秒）。
   - 另一条**必须记住**的教训：模块在 init 里 `process.spawn` 会**抢走 pid 1**（实测进程表出现
     `1:hse-pump 2:init`）—— 模块装载早于 init，所以任何"内核自己起的进程"都要**延迟到 init 之后**
     再 spawn（v0.4.0 里就是改成"第一次有人睡时才 spawn"）。
2. **"延迟/轮询间隔"不能用 `msleep(0)` 充当** —— 它在 HSE 下只有 2ms，循环会变成热循环。
   要等一段时间就用 `msleep(ms)`，且**默认值 ≥50ms** 走定时器那条路；真要亚 50ms 的间隔
   （<50 是逐拍唤醒，代价是每拍一个事件）得自己想清楚。
   更好的做法是**根本不轮询**：`/dev/kmsg` 的 `readLine` 天然阻塞（内部 `os.sleep(0.05)`），
   `dmesg -w` 因此改成阻塞读而不是"`readAvailable` + `msleep(50)`"。

#### 批次 2：各工具常用选项的落地（与 GNU 的取舍）

用户态工具的选项一律**照宿主 GNU 逐项实测**对齐；下面只记那些"有坑"或"有取舍"的：

- **`ls`**：新增 `-i -n -F -p -S -U -X -Q -L -H -G -g -o --color[=WHEN]`（`--color` 认 `LS_COLORS`，
  `auto` 看 stdout 的 `isTTY`），`-l` 现在会打 `name -> target`。**`-s`/`-c`/`-u` 一律 fail-fast 退出 2**：
  它们要"已分配块数"(st_blocks) 或 atime/ctime，而内核 `attributes` 都不暴露（见「已知缺口」）——
  收下却打错数字比报错更糟。
- **`cp`**：`-t DIR -T -u -l -s -P -L -d`。`-P/-d` 走 `fs.lstat`+`fs.readlink`+`fs.symlink`
  复制链接本身（`fs.open` 必然跟随链接，不能拿它复制链接）。**每个操作数失败都要 `rc=1`** ——
  老代码在循环里裸 `return`，于是"报错却退出 0"。
- **`rm`**：`-d -I --[no-]preserve-root`，并且**拒绝 `.` 与 `..`**（`rm -r .` 会把当前目录整个删掉，
  这条是安全底线），`"/"` 递归删除要显式 `--no-preserve-root`。退出码按 GNU 累计（任一失败即 1）。
- **`ln`**：`-r -t -i -L/-P`。`-r` 的相对目标按**链接所在目录**算（GNU 语义）。
- **`blkid`**：`-s TAG -o full|value|device|export|list -U UUID -L LABEL -t NAME=value -k -l`；
  有过滤令牌而一个都没命中时退出 2（util-linux 同）。
- **`df`**：`-B SIZE/--block-size -H/--si -t TYPE -x TYPE --total`；`-i` 改为 fail-fast 退出 2
  （内核没有 inode 统计）。
- **`du`**：`-m -H -l -L -P -B SIZE -t SIZE --si --exclude=GLOB`。**已知偏离**：Delin 按**表观大小**
  向上取整到块（没有 st_blocks），所以 `du -m` 的绝对值与 GNU 不同 —— 这是 ext2 驱动不暴露
  `i_blocks` 的直接后果，要等内核补。
- **`dd`**：数值**后缀**（`bs=1M`、`count=1K`、`c/w/b`、`NxM`，以前 `bs=1M` 直接报 invalid number）、
  `iflag=fullblock|count_bytes|skip_bytes`、`oflag=append|seek_bytes|notrunc`、`conv=fsync|fdatasync`
  （收尾 flush）；`oflag=direct` 等依赖宿主 IO 的旗标 fail-fast。
- **`sort`**：`-M`（月份序，未知月份在前）、`-C`（静默检查，**不打印诊断**）、`--sort=WORD`。
  坑：`-C` 是**短选项**，在长选项 `elseif` 链里就被吃掉了，必须在那里同时置 `opt.C`，
  否则 `quietCheck` 读不到（症状：`-C` 仍然打印 disorder）。
- **`systemctl`**：`kill [-s SIG]`、`is-failed`（非 failed 退出 3）、`cat`、`list-timers`、
  `--now`（enable 后接着 start）、`--quiet/--no-pager/--version`。
- **`logger`**：`-i`（tag 后缀 `[pid]`）、`-s`（同时写 stderr）、`-f FILE`、`-e`（跳空行）、
  `-[n]`（no-act，打印到 stdout）、`-S N`（截断）、`--prio-prefix`（每行 `<PRI>` 覆盖）；
  网络类（`-n/-P/-d/-T/--rfc*`）fail-fast。
- **用户工具**：`usermod -rG` 从附加组里移除（内核 `changes.groupsDel` 早就有，工具从没设过）、
  `useradd -r`（扫一个 1000 以下的空闲 uid）、`groupadd -r/-f`；`useradd -N` 与 `groupadd -U`
  需要内核支持（一定建同名私有组 / addGroup 没有成员参数）→ fail-fast 退出 2。

**测试台的坑（这一批又踩了两次）**：`tools/hosttest.lua` 的 fs 桩缺 `lstat/symlink/readlink/link/canExecute`
时，新写用例会在宿主上报 "attempt to call field 'symlink' (a nil value)" 而真机是好的 ——
桩要照内核的语义补齐；`F.lstat` 对**悬空链接**必须返回一张 `kind="symlink"` 的表（宿主上的链接
目标写的是 Delin 的路径，本来就不存在）。另外：工具**裸 `return`**（内核当 0）在宿主测试台里读到的是
`nil`，`sort -C`/`du`/`dd` 因此把结尾补成了显式 `return 0`。

#### 批次 3：新命令（19 个）与分页器、awk、bc

用户态新增 19 个 `/bin` 命令。**共同约定**：选项一律照宿主 GNU 逐项实测对齐（`newtools_test.sh`
与 `less`/`more` 的宿主自检都是逐字节比），未实现的选项 **fail-fast 退出 2**（不静默半套），
诊断走英文/ASCII（装到 CC 上的产物全 ASCII 是构建期门禁）。

| 命令 | 覆盖范围与已知偏离（详见各源码头注释） |
|---|---|
| `awk` | **完整 POSIX awk**：模式/动作、BEGIN/END/范围模式、字段与 `$0/$NF`、关联数组与 `(i,j) in a`、`if/while/do/for/for-in/break/continue/next/nextfile/exit/return/delete/print/printf`、赋值与复合赋值、三元、`~ !~`、并置、内建函数全套（`length substr index split sub gsub match sprintf sin cos atan2 exp log sqrt int rand srand tolower toupper system close fflush`）、`getline` 的四种形态、`print > file`/`>> file`/`| cmd`、用户函数（数组按引用）、`-F/-v/-f/--` 与 `var=value` 操作数、`ARGV/ARGC/ENVIRON/SUBSEP/RSTART/RLENGTH/CONVFMT/OFMT/NR/FNR/NF/FILENAME/FS/OFS/ORS/RS`。正则走内核 ERE 引擎。**偏离**：字符串比较按字节序；`/dev/stdout` 不存在（Delin 没有这个别名）；`RS` 多字符按 ERE（gawk 扩展）；无 locale，`tolower/toupper` 只折叠 ASCII；动作体外面包了 pcall（接住 `exit/next/return` 的展开），而 **Lua 5.1 不允许跨 pcall 让出**，所以宿主测试台（5.1）跑不了 awk 的 `system()`/管道 —— 真机（Lua 5.2）可以，宿主上请用 `lua5.4`（`scripts/pager_test.sh` 就是这么做宿主自检的） |
| `bc` | 任意精度十进制（字符串大数：加/减/乘/长除/取余/整数幂/整数平方根）与 POSIX bc 语言子集：表达式、赋值与复合赋值、`if/while/for/break/continue/return/print/quit/halt`、`define ... { auto ... }`、数组（含数组参数）、`ibase/obase/scale/last`、`-l` 数学库（`s c a l e j`）。**偏离**：数学库用级数展开（scale+4 保护位后截断），末位可能与 GNU 差 1；`read()` 从 stdin（或程序文本剩下的行）读；`limits` 与 `-e/-f` fail-fast |
| `more` | POSIX more：`-d -f -l -p -c -s -u -n`、`+行号`/`+/模式`/`+命令`；命令 `空格/f/b/d/u/q/=/／/n/s/!/:f/^L/.`。**偏离**：输入一次读入内存；终端不折行（CC 终端本来就截断超宽） |
| `less` | `-e -E -f -F -g -G -i -I -m -M -n -N -p PAT -P PROMPT -q -Q -R -s -S -X -x N -z N -c -C -d -j N -k -K -?/-h/-V`；命令 `空格/b/d/u/j/k/回车/g/G/PgUp/PgDn//pat/?pat/n/N/F/=/:n :p :e/-选项/q/h`。**偏离**：`-o/-O/-t/-T/-b/-B/-u/-U/-w/-a` fail-fast；没有过滤器(`&`)/标记(`m '`)/编辑(`v`)/反显高亮 |
| `date` | `-u -d STR -f FILE -r FILE -R -I[FMT] --rfc-3339=FMT` 与 GNU 的**全部** FORMAT 转换符（`%% %a..%Z %:z %::z %:::z`）；`-d` 认 `@epoch`、`now/today/yesterday/tomorrow/noon`、`YYYY-MM-DD[ T ]HH:MM[:SS][Z±HH:MM]`、`MM/DD/YYYY`、`HH:MM[:SS]`、相对表达（`N unit[s] [ago]`、`next/last/this unit`，含按历法的月/年、绝对+相对混写）。**偏离**：没有时区（一律 UTC，`%Z`=UTC、`%z`=+0000，TZ 不生效）；**不能设置时钟**（`-s` 报 Operation not permitted）；秒精度（`%N` 恒 0） |
| `env` | `-i -u NAME -0 -C DIR -S STRING --ignore-signal`；无 COMMAND 时打印环境，有则执行并原样返回退出码（127/126/125）。`-S` 是 POSIX shell 风格拆串（引号/转义/`${VAR}`/`#` 注释）。**偏离**：`--default-signal/--block-signal/--list-signal-handling/--debug` fail-fast；环境表按名字排序输出 |
| `timeout` | `-k -s/--signal --preserve-status -v --foreground`；`DURATION` 支持 `s/m/h/d` 与小数；退出码 124/125/126/127 与 GNU 一致。子进程先自立进程组（`job.setpgid`），超时对整组发信号（协作式协程下 spawn 后立刻 setpgid 无竞态）。**偏离**：时间分辨率是 50ms 轮询间隔 |
| `uname` | POSIX + GNU 全部选项（`-a -s -n -r -v -m -p -i -o` 与长选项）；值取自 `/proc/version`、`/etc/hostname`：`-s`=Delin、`-r`=内核版本、`-v`=`CraftOS <版本>, Lua <版本>`、`-m`=cc-tweaked、`-p/-i`=lua、`-o`=Delin |
| `seq` | `-f FORMAT -s SEP -w`；缺省格式由操作数小数位数决定（`1e2` 是 0 位），`-w` 零填充，末位容差用半个末位。**偏离**：IEEE double（`>2^53` 末位不精确）；不支持 `inf` |
| `yes` | 无选项（任何参数都是要重复的串，GNU 同）；写失败（内核管道返 broken pipe）时**静默**以 141 退出（Linux 上它就是被 SIGPIPE 杀死的（128+13）） |
| `which` | `-a -s --skip-dot --skip-tilde --show-dot --show-tilde --tty-only`；带 `/` 的名字不查 PATH，空 PATH 项按 `.` 处理，退出码 0/1/2。**偏离**：`-i/--read-alias` 与 `--read-functions` fail-fast（别名活在 sh 进程里） |
| `tty` | `-s/--silent/--quiet`；是终端打 `/dev/ttyN`，否则打 `not a tty`（stdout）并退 1；选项错退 2 |
| `logname` | 打 `$LOGNAME`，没有则 `logname: no login name` 退 1。**偏离**：没有 utmp，不做"这个名字还是不是当前登录"的复核 |
| `rev` | `-0`（NUL 分隔）；逐行按**字节**倒序，末尾无分隔符就不补。**偏离**：宿主 util-linux 的 rev 在 C locale 下遇多字节会报错，Delin 按字节处理二进制也能用 |
| `tac` | `-b -r -s SEP`（`-r` 用内核 BRE）；输出记录倒序、分隔符跟着它所属的记录走 |
| `nl` | POSIX nl：`-b -h -f`（`a/t/n/pBRE`）、`-d CC`、`-i`、`-l`、`-n ln/rn/rz`、`-p`、`-s`、`-v`、`-w`；段分隔符（3/2/1 个）切换页眉/正文/页脚并**重置行号**，不编号的行打等宽空白。逐条对照 coreutils `nl.c` |
| `column` | `-t` 表格（`-s` 输入分隔、`-o` 输出分隔、`-N` 列名、`-n` 表名、`-J` JSON、`-L` 保空行）与两种填充模式（缺省按列填、`-x` 按行填，`-c` 宽度、`-S N` 用空格），算法照 util-linux 的 `columnate_fill*`。**偏离**：libsmartcols 那一族（`-C/-O/-H/-R/-T/-W/-E/-l/-d/-m/-e/-K/--color/-r/-i/-p`）fail-fast |
| `base64` | `-d -i -w COLS`；编码按 4 字符组、`-w 0` 连末尾换行都不打；解码按 **quantum** 校验（`YQ==` 行、`YQ=`/`===`/`YWJj=` 报 invalid input），与 GNU 一样**边解边写**（出错前已解出的字节留在 stdout） |
| `tsort` | POSIX tsort：Knuth Algorithm T 的逐条移植（零前驱按字节序入队、后继按输入倒序递减计数、队列空了就找环、打印环并**删一条边继续**），自环丢弃。与宿主 GNU 在 500 个随机图上逐字节一致（`tools/bintest` 之外的一次性对照） |

**分页器与终端**：`more`/`less` 用内核 tty 的**原始模式**（见「终端的原始模式」）读单个按键；
stdout 不是终端时**直接照抄输入**（与 Linux 一致）。两个工具都一次读入整个输入（CC 的文件很小，
换来任意往回翻）；`less` 的 `F` 会重读文件以跟踪追加的内容。

#### `spawn` 的 `opts.stdio` 是**整表覆盖**、`opts.envClear` 才是清空

- `opts.stdio` 一旦给出，input/output **两端都按它设**（没给的端就是 nil），不会与父进程的
  stdio 合并。所以给子进程只重定向一端时**另一端也要显式传**（`xargs`/`awk` 都这么写：
  `{ input = childIn, output = io.stdout() }`）。
- `opts.envClear = true` 表示"不继承父进程的环境块，只用 `opts.env` 这张表"（`env -i` 的语义）。
  光靠"值为 nil 即删除"是**做不到**的：Lua 表里存不下 nil，`pairs` 也遍历不到它，删除项在
  spawn 侧根本看不见（`env` 因此改成总是传一张完整环境表 + `envClear`）。
- **管道端要 `ref()`**：`/bin/sh` 的父子进程共享同一个管道端对象，父进程 `close()` 会把子进程
  那份也标成关闭。给子进程的端必须用 `h:ref()` 复制一份独立引用（`awk` 的 `print | cmd` 与
  `cmd | getline` 都这么做；`xargs`/`find -exec` 的那个已知缺口见上文「管道端是共享句柄对象」）。

#### `sh` 把继承来的环境变量都变成已导出的 shell 变量

POSIX：继承的环境变量一律成为**已导出**的 shell 变量，`env FOO=bar sh -c 'echo $FOO'` 必须打印
`bar`。老代码只认表里那 8 个（PATH/HOME/USER/LOGNAME/SHELL/PWD/PPID/TERM），别的名字既不进
`vars` 也不导出 —— `env` 于是只对这几个名字有用。现在 `sh` 启动时把父进程给的所有名字补进
`vars` 并置 `exported`，但**不覆盖** shell 自己维护的名字（IFS/PS1/PWD…）。

#### POSIX 命令覆盖与 `proc.exec`

按 Wikipedia 的 [List of POSIX commands](https://en.wikipedia.org/wiki/List_of_POSIX_commands)
（IEEE Std 1003.1-2024）逐条核对：**强制命令 110 条**，Delin 已实现其中绝大部分；完整对照表与分档
清单在知识库里（`~/docs/posix/POSIX强制命令清单.md`、`~/docs/posix/Delin覆盖情况.md`）。
仍有缺口的主要是**国际化/语言工具**（`locale`/`localedef`/`gettext` 系列、`m4`、`bc`、`ar`、`pax`）、
`awk`、以及 CC 上没有意义的几项；终端类（`stty`/`tput`/`tabs`）在 16 色 ANSI 终端上只做了子集。
**逐个命令的实测对照**（与宿主 GNU 逐字节比）由各工具自己的验收记录，不在这里重复。

**`syscalls["proc.exec"](cmd, argv, opts)`**：按 PATH 查找并启动一个程序（`execvp` 的最小实现）——
查 PATH、查 `x` 位、经 VFS 读源码、处理 shebang（含 `#!/usr/bin/env prog` 特判）。
放在内核的理由：任何"我要起一个外部命令"的工具都得做同一件事，而 `spawn()` 只收**源码字符串**，
每个工具抄一遍既冗长又容易抄漏。`opts` 透传给 `spawn`（`cwd`/`env`/`stdio`/`uid`/`gid`/`sigIgnore`），
`argv[0]` 由内核填。**注意这是"起一个新进程"，不是 POSIX exec 的"替换当前进程映像"**（Delin 没有那个语义）。
使用者：`xargs`、`nohup`、sh 的 `command` 内建。

**被忽略的信号跨 spawn 继承**：`syscalls["signal.install"](sig, "ignore")` 置 `SIG_IGN`，该处置与
Linux 的 exec 一样传给子进程（`process.setHandler` 认 `"ignore"`/`"default"`，`spawn` 合并父进程的
`sig.ignored` 与 `opts.sigIgnore`）。`nohup` 就是靠这条让 COMMAND 免疫 SIGHUP 的。

**错误路径的退出码**：工具里"出错"必须 `return 1`（内核把协程返回值当退出码，裸 `return` 就是 0）。
历史上有 35 处 `stderr(...)` 后面跟裸 `return` 的写法会"报错却返回 0"，已统一修正；`cat` 按 POSIX
在某个操作数失败时**继续处理其余操作数**、最终退出 1。另外共享模板里的 `ioeMsg` 曾先匹配 `"directory"`
再兜底，而 `"No such file or directory"` 里本来就含 `directory` —— 于是"文件不存在"被报成
"Is a directory"（31 个文件），已改为先判 ENOENT（且用小写比较，Lua pattern 区分大小写）。

**构建期门禁（shadow gate）**：`local backend = { ... function() ... backend.x ... end }` 这种写法里，
初始化表达式的闭包读到的 `backend` 是**全局**（Lua 的 local 作用域从声明语句之后才开始）—— 运行期
必然 nil，而静态看不出来（真机症状：`ls /proc/self` 报 `attempt to index global 'backend'`）。
`tools/build.lua` 在压缩之前用 `minify.checkShadowedGlobals` 扫 `src/{bin,kernel,init,bios,modules}`，
命中即 fail-fast 并给出源码行号；修法是声明与赋值分开（`local backend; backend = { ... }`）。

**长按重复事件（真机反馈"按住退格只删一个字符"）**：CC 在按住某键时**持续**发 `key` 事件，第 3 个
参数 `isHeld` 为 true。Delin 以前把所有 `isHeld` 事件一律丢掉（`feedKey`/`rawFeedKey` 的第一行），
于是行编辑里按住退格/方向键只生效一次。现在有一张 `REPEATABLE` 表（`backspace delete left right
up down home end pageUp pageDown`），只有这些键放过重复事件；**Enter/Tab 故意不放**（按住回车刷空行、
按住 Tab 狂刷补全都不是想要的）。去重闩锁 `dupChar` 对重复事件同样成立：每个重复的 `key` 事件推
一个字节，紧随其后的重复 `char` 事件被吃掉 —— 不会一次删两个字符（hosttest 里锁着这 5 条）。

**滚屏与重绘的性能（真机反馈"滚屏很慢"）**：`kernel/tty.lua` 原先滚一次 = 把整屏 ~grid 全标脏再
**逐格** `dev.text`，而 term 型的 `dev.text` 是 `term.setCursorPos` + `term.blit` 两条 CC 调用 ——
51x19 一屏就是近千次调用。两条修法（都在 `kernel/tty.lua`）：

1. **（已回退，留作前车之鉴）设备原生滚动**：曾经给 `ScreenDevice` 加过可选 `scroll(n)`（控制台用
   `term.scroll(n)`），tty 有它就只滚动自己的 grid + 把新露出的末行标脏、其余不重画。真机上
   **文本不显示、光标残留**（CC 侧的滚动结果与内核 grid 对不上，而那块屏读不回来、没法自动化
   验证），所以退回了"整屏标脏重画" —— 真正贵的不是"重画多少格"，而是**逐格 blit**（见第 2 条），
   换成合并之后一次滚屏只有 ~19 次调用，够用了。要再快只能走原生滚动，但必须先解决
   "内核 grid 与设备状态同步"这个可以在真机上验证的问题。
2. **同一行连续同色的脏格合并成一次 `dev.text`**：整行输出（`ls`/`ps`/`grep`）因此从"每格一次"
   变成"每行一次"。合并会被"中间有没标记的格子/跨行/颜色变化/光标反显"打断。

`tools/hosttest.lua` 的假终端加了 `scroll` 计数与 `calls` 记账，锁住这两条（"一整行最多两条 text"、
"滚完只重画末行"）。

**宿主测试台在 Lua 5.4 下也能跑了**：`tools/hosttest.lua` 里有几处直接写 `loadstring`（5.2+ 没有），
于是 `lua5.4 tools/hosttest.lua` 一直死在 "attempt to call a nil value (global 'loadstring')" ——
现在统一走 `loadEnv(src, name, env)`（5.1: `loadstring`+`setfenv`；5.2+: `load(..., "t", env)`），
840 项在 5.1 与 5.4 下都全绿。

**构建期门禁（local gate）—— CC 的 Lua(Cobalt) 局部变量上限**：宿主 `lua5.1/5.4` 给**每个函数**
200 个局部变量名额，而 CC 的 Cobalt 是**沿嵌套链累加**的：`Parser.newLocal` 拿
`activeVariableSize + 1` 与 `LUAI_MAXVARS`(200) 比，而 `activeVariableSize` 是"当前函数 +
**所有祖先**函数"的活动局部之和。于是：

- 一个 ~196 个顶层 local 的 chunk **本来能装载**（每个内层函数只剩几个名额），**再加一个 local**
  （哪怕只是一个 helper 函数）就可能让某个内层函数越线:
  `load failed: function at line N has more than 200 local variables`；
- 而 shell 只会把装载失败打成一个 `nil`（见下「spawn 的报错」，已修），症状是**整个系统的服务
  都起不来**（`init` 的每个 `/bin/sh` 服务都报 `FAILED: /bin/sh: nil`），看着像内核坏了；
- 宿主上永远复现不出来（这正是它当年一路全绿到真机的原因）。

判据与做法（`tools/minify.lua` 的 `checkLocalBudget` + `tools/build.lua` 的 `localGate`，扫
`src/bin` 与 `src/lib`，上限 200，超限 fail-fast 并打印最坏嵌套链）：

- **文件级实现一律包成一个函数**（`local function shCoreMain(ui, S)`），chunk 只剩两三个 local；
- **文件里的 helper 函数一律是表字段**（`local F = {}` + `function F.foo`），表字段不占局部变量
  名额 —— 这一条把 `sh` 核心的最坏嵌套链从 246 降到 ~150；
- `src/bin/find` 目前是 197（离上限只差 3），动它时要留意这条门禁。

**标准正则**：`grep`/`sed`/`ed`/`expr`/`csplit`/`pgrep`/`pkill` 的**面向用户的模式**一律是
**POSIX 标准正则**（BRE / ERE），实现是内核里的唯一真源 `src/kernel/regex.lua`，工具经
`syscalls["regex.compile"](pattern, "bre"|"ere", {icase=, word=, line=, fixed=})` 用（与 user.*/init.*
同一模式：进程环境是白名单，用户态没有 require，所以共享引擎只能放内核）。方言按各命令的 POSIX 规定：
`grep` 默认 **BRE**（`-E` 切 ERE、`-G` 显式 BRE、`-F` 按字面串）；`sed` 默认 BRE（`-E`/`-r` 切 ERE）；
`ed`/`expr`/`csplit` 是 BRE；`pgrep`/`pkill` 是 ERE（procps）。匹配语义 = POSIX 的**最左最长**，
`grep -o` 与 `s///g` 都按它取（`echo ab | grep -oE 'a|ab'` 出 `ab`，不是 `a`）。
**grep 的退出码也是 POSIX/GNU 的**：0 = 选中了行、1 = 没选中、2 = 出错（选项/模式/文件读不了）——
自检脚本里 `if ... | grep -q` 因此是真门禁（以前恒 0，等于空转）。
替换区（`sed`/`ed`）用 `&`=整串匹配、`\1..\9`=捕获组、`\n/\t/\r` 转义、`\&`/`\\` 转义，
BRE 的 `s/\(a\)\(b\)/\2\1/` 与 ERE 的 `s/(a)(b)/\2\1/` 都对；`s///N` 只替第 N 次出现。
**已知偏离**：`\t`/`\n` 在**模式里**是转义（GNU sed 认，GNU grep 不认——本引擎统一认）；
子表达式捕获在退化情形（同一个 RE 里多个可选分支）按"整体最长 + 分支优先"近似 POSIX 的子表达式规则；
不支持 `[[=x=]]` 等价类与 `[[.x.]]` 排序元素；文本按字节处理（`[[:alpha:]]` 是 ASCII 字母）。
**已知 bug（未修）**：把重定向写在**函数调用**上时（`f arg > out`），函数体里启动的**外部程序**
的输出不会进重定向的目标文件（内建如 `echo` 正常）——`f() { ls /proc/self; }; f > out` 得到空文件，
而输出跑到终端上。绕法：把重定向写在实际那条命令上（`ls /proc/self > out`）。
不支持 **here-doc `<<`**（遇到即语法错误）；命令替换 `$()`/反引号、算术 `$(( ))` 与通配符已实现
（见「词展开」一节）。也**不支持带 fd 前缀的重定向**（`2>f`/`2>>f`/`>&`）：`2>>f` 会被切成
操作数 `2` + `>>f`（实测：`dd ... 2>>log` 报 `unrecognized operand '2'`）—— 脚本里要收 stderr
就得靠命令自己的 `status=`/`-s` 之类开关，别指望 `2>`。
`&` 的子 shell 是重新执行的进程（无 fork）：父 shell 的变量、函数定义与别名经赋值/定义语句注入，
但 `$?` 在子 shell 里从 0 开始（不继承父 shell 的最后状态）；子 shell 的**起始 cwd** 由内核继承
（`sh` 从 `/proc/self/cwd` 取自己的 cwd，不按 `$HOME` 猜）。`VAR=value cmd` 的赋值在命令词
展开**之前**生效（POSIX/bash 是展开之后，故 `x=0; x=1 echo $x` 在 Delin 打印 1、在 bash 打印 0）；
`read` 无法区分“末行无换行”（句柄 API 限制，按成功计）。
**语法错误**：非交互 shell 报错后以 **2** 退出（dash/bash 与 `.` 内建同此），解析器没吃完的记号
（典型：不支持的 `( list )` 子 shell 分组）算语法错而不是静默丢掉剩下的输入；关键字必须是**未加引号的
整词**（`"done"` 是命令名 done）。`set -x` 只跟踪**简单命令**（含赋值/重定向），不打印 `for`/`if` 这类复合关键字行；
`set -u` 的检查发生在命令执行前（未执行的分支不报错），交互式只丢弃当前命令、非交互式退出；
子 shell 的 `$PPID` 取内核给的父 pid（不继承环境里的 `PPID`）；`.` 的参数按 bash 语义临时替换位置参数
（dash 忽略它们）；未实现 `export -f`（函数导出）、`readonly`；**没有 `( list )` 子 shell 分组语法**
（`$(( ))` 与 `$( (cmd) )` 里那个是算术/命令替换，不是分组），`${name:-default}` 一类参数默认值展开也未实现。
因 CC 5.2 无位运算，`/etc/shadow` 哈希用盐+密码的 32 位滚动哈希（djb2）替代传统 `crypt`；
盐由内核 CSPRNG 生成（`user.makeSalt` → `random.hex`，见「随机数」一节），不再用 `math.random`。

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
宿主测试台 `tools/hosttest.lua`（680 项）与真机脚本 `tools/realmachine.py` +
`scripts/realmachine_verify.sh`。

`src/bin/sh` 已升级为 POSIX 核心子集（变量/引号/if/for/while/case/函数/test/[ ]/&&/|| /文件重定向/管道
`|` + 命令替换 `$()`/反引号 + 算术 `$(( ))` + 通配符 `* ? [ ]`），支持脚本执行（`sh script.sh` / `./script.sh`，`#!` shebang）、
`rm`/`mkdir` 补了 GNU `-r/-f`/`-p`；新增 `chmod`（八进制 + 符号模式 + `-R`）、`chown`（`owner:group` + `-R`）、
`mount`（挂载 `/dev/sdX`、`UUID=` 或镜像路径 / `-a` 按 fstab 挂载 / 无参列出）/ `umount` / `blkid` / `lsblk`；
存储经 `devdisk` 抽象为整盘（ccdisk）与分区（manifest 里的 ext2 镜像）设备节点 —— **电脑自带存储恒为
`/dev/sda`**（曾经的 bug：只枚举磁盘驱动器，自带存储与其上的分区永远不是设备），磁盘驱动器接在其后，
UUID 用 ID 加前缀模拟（`d<磁盘ID>`/`c<电脑ID>`），存储不随启动自动挂载（改由 `/etc/fstab` 声明）。
文件系统侧新增 **`mkfs.ext2` / `fsck.ext2`**（e2fsprogs 风格，逻辑在内核 `ext2.mkfs`/`ext2.fsck`，
`/bin` 只是薄壳，经 `blkdev.mkfs`/`blkdev.fsck` syscall 落到 `devdisk` 的目标解析上）：
`mkfs.ext2 -b/-N/-L/-m/-n/-q/-F` 可调块大小(1024/2048/4096)/inode 数/保留块/卷标，单块组、
已有文件系统不给 `-F` 拒绝、挂载中的一律拒绝；`fsck.ext2` 五趟检查与修复（inode/块 → 目录结构 →
连通性(孤儿 inode 重连 `/lost+found`) → 引用计数 → 位图与块组计数），`-n` 一个字节都不写、
退出码与 e2fsck 一致(0/1/4/8/16)。宿主回归 `tools/ext2test.lua`（235 项）与真机
`scripts/realmachine_verify.sh` 的 mkfs/fsck 段都以**宿主 e2fsck** 当裁判（Delin 造/修的镜像必须被判干净）。
作业控制落地：
`&` 后台作业 + `jobs`/`fg`/`bg`/`wait`/`kill %job`/`$!`、
前台作业进程组与 `^C`/`^Z` 路由、后台进程组读 tty 的 `SIGTTIN`、`/dev/null`、`sh -c`；
新增 `read` 内建（POSIX，跟随 `IFS` 变量）与 `/bin/sleep`（GNU 风格，分片睡眠便于信号打断）。
终端侧：tty 层解释 ANSI 转义（SGR 16 色/ED-EL 清屏/CUP 定位/光标显隐与保存恢复，见上文
「终端（ANSI / `$TERM=linux`）」），`$TERM=linux` 随环境导出，`echo` 支持 `-n`/`-e`，新增 `/bin/clear`，
`login` 每次提示前清屏。
`scripts/posix_test.sh`(128 项, 含 cat 的字节保真)与 `scripts/jobctl_test.sh` 在宿主与 Delin 上各跑一次逐项比对，
`scripts/sysinfo.sh` 演示实用用法。

打印机经 `ccprinter` 模块抽象成 `/dev/lpN` 字符设备（`cat f > /dev/lp0` / `lp f` 即打印，折行与
满页翻页由内核负责）+ `/sys/class/printer/<lpN>` 状态与页标题，`/bin/lp` 是 POSIX lp(1) 子集。
sysfs 也从 display 专用泛化成 class 注册表（模块用 `kapi.registerSysfsClass` 注册自己的类）。

进程可见性落地：内核 `procfs`（`/proc/<pid>/{cmdline,comm,cwd,stat,status}` + `/proc/self` +
`/proc/{mounts,uptime,version}`，boot 挂载，只读、读尽即 EOF），配套 `ps`（默认/`-e`/`-f`/`-l`/`aux`/
`-p`/`-t`/`-u`/`-o`/`--no-headers`）、`pgrep`/`pkill`（`-f`/`-x`/`-v`/`-n`/`-o`/`-u` + 信号）、
`killall`（`-e`/`-q`/`-u`/`-l`）—— 全部是 `/proc` 的消费者，不额外开 syscall。
`scripts/proc_test.sh`（41 项）在宿主 harness 与真机上各跑一次逐项比对。

用户管理落地：内核 `kernel/user.lua` 承担全部读写 —— boot 解析 `/etc/{passwd,shadow,group}` 进内存 db，
写操作经 `user.*` syscall（授权 → 改内存 → 特权写回 `/etc`，等价 setuid passwd），配套
`passwd`（含 `-d/-l/-u/-S`）、`useradd`（`-m` 建家目录）、`userdel -r`、`usermod`（`-u/-g/-G/-a/-d/-s/-c/-l/-L/-U`）、
`groupadd`/`groupdel`、`id`/`whoami`/`groups`；`/etc/shadow` 由安装侧设成 0600 root:root
（`user.get` 也不回哈希，普通进程拿不到）。`scripts/user_test.sh`（125 项）在宿主 harness 与真机上
各跑一次逐项比对，非 root 分支由 `scripts/user_helper.lua` 用内核 `spawn(uid)` 起普通用户进程验证。

软RAID 落地：内核 `kernel/md.lua`（mdadm 1.2 超级块、raid0/1/5/6/10 的条带/镜像/校验映射、
reconstruct-write、降级与重建）+ 模块 `modules/md.ko`（`md.*` syscall + 调度器心跳驱动的重建）
+ `/bin/mdadm`（create/assemble/--scan/detail/examine/manage/stop/zero-superblock/--wait）
+ `/proc/mdstat` + `/etc/mdadm.conf` + `mdadm.service`（init 把它挂进 `local-fs-pre.target`，
阵列因此**在挂载之前**就组装好）。阵列经 `devdisk.registerNode` 成为 `/dev/mdN`，
`mount`/`mkfs.ext2`/`fsck.ext2`/`blkid`/`lsblk` 零改动可用；成员可以是 `/dev/sdXN`，
也可以是真实后端上的镜像路径（`/parts/*.img`）。宿主回归 `tools/mdtest.lua`（128 项，
布局与 GF 乘法都是独立实现，阵列上的 ext2 交给宿主 e2fsck 判），真机在**电脑 #6**：
`tools/md_realmachine.py` + `scripts/md_verify.sh`（两阶段含重启后的开机自动组装）。
详见「软RAID」一节。

CEE:CC(CEECC)平台落地：`kernel/platform.lua` 认平台(`_G.cee`)、`modules/cee.ko` 摊出
`/sys/class/power/supply`(电力)与 `/sys/class/pin/pinN`(引脚与端口)，引脚上的磁盘驱动器由 `devdisk`
按 CC 挂载路径去重补进 `/dev/sdX`，电缆/枢纽设备的晚到由 `peripheral` 事件触发重扫。
真机验证在**电脑 #6**（台式 CEECC，自带存储 10MB）：`tools/ceecc_realmachine.py` + `scripts/ceecc_verify.lua`，
装机走 CCFS 根、36 项断言全绿；详见「CEE:CC 平台」一节。机架式（4096 字节存储）不在范围内。

命令批 3 落地（19 个新命令 + 终端的原始模式）：`awk`（完整 POSIX awk）、`bc`（任意精度十进制）、
分页器 `more`/`less`（建在内核 tty 的**原始模式**上：`setRaw` 之后 `read(n)` 是终端字节流，
特殊键是 ANSI 序列，见「终端的原始模式」）、`date env timeout uname seq yes which tty logname
rev tac nl column base64 tsort`（POSIX/GNU 子集，选项与退出码逐项对照宿主 GNU）。
配套：`process.spawn` 的 `opts.envClear`（`env -i` 的语义）、`sh` 把继承来的环境变量都变成
已导出的 shell 变量（`env FOO=bar sh -c 'echo $FOO'` 现在对任何名字都成立）。
宿主回归：`scripts/newtools_test.sh`（宿主与真机跑同一份，已进 `build.lua --check`）、
`scripts/pager_test.sh`（分页器的交互，宿主专用 —— 测试台的假终端支持 `setRaw` 与按键字节流）；
真机：`posix_tools_verify.sh` 的新命令段 + `scripts/rawtty_test.ko`/`rawtty_verify.lua`
（`tools/realmachine.py` 断言 `/tmp/rawtty.hex`）。

红石经 `redstone` 模块摊成 sysfs 属性文件 `/sys/class/redstone/<side>/{digital,analog,bundled}`
（六个面恒定存在），`cat`/`echo` 即读写；读 = 该面输入、写 = 该面输出，
写值严格校验（十进制整数 + 范围），非法写 fail-fast 且不改动输出状态。
`scripts/redstone_test.sh`（75 项）在宿主 harness 与真机上各跑一次逐项比对（写是否生效由 `/bin/lua`
经 CC 原始 `redstone` API 读回确认 —— 文件读的是输入，读不回自己写的输出），
`scripts/redstone_verify.lua` 在真机上以 CC 原始 `redstone` API 为真值逐项交叉核对。

### 引导

代码经 `tools/bundle.lua` 打包成自包含 Lua 文件部署。**引导契约**：CraftOS 开机执行电脑自身 FS 的
`/startup.lua`；Delin BIOS（`src/bios/startup.lua`，装到 `/startup.lua`）会扫描所有设备找 `/.boot`，
读出里面的路径并 `loadfile` 执行——`/.boot` 的内容就是引导设备上那个"内核入口"文件的路径
（如 `/boot/delin.lua`）。BIOS 启动前有 0.1s 窗口，按 `DELETE` 进 BIOS 设置（`C` 进 CraftOS shell），
无 `/.boot` 的设备不会被选为引导设备。

**BIOS 的版本号是它自己的，不跟内核版本走**：BIOS 是独立启动器（虽然属于 Delin 项目），
`src/bios/startup.lua` 里的 `Delin BIOS x.y.z` 字面量与 `src/kernel/version.lua` **无关**，
升内核版本时**不要**顺手改它，`tools/build.lua` 也没有（不该有）两者的版本一致性门禁 ——
所以 `dist/release/<版本>/payload/startup.lua` 里的 BIOS 横幅显示旧版本是正常的，不是漏改。

两条引导路径：

- **CC-fs 引导**（默认）：`kernel.lua` 直接跑 `boot.boot()`——`setupVfs` 挂根 hdd 到 `/` +
  `mountDev` + `klog.register`（`/dev/kmsg`、`/dev/log`）+ `procfs.mount` 挂 `/proc` →
  `setupDevices` 扫描存储（电脑自带存储 + 磁盘驱动器）注册
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
  3. **磁盘 CCFS 启动**（`ccdisk <外设名>`）：根 = 该磁盘的 CC 原生文件系统本身，
     内核从该盘 `/boot/delin.lua` 读。装 Delin 到磁盘时不必建 ext2 镜像，直接铺文件即可。

  两种模式都会读取 ext2 分区，挂载根文件系统，读内核镜像并设 `_G.__boot_info`；`boot.boot()`
  检测到 `__boot_info` 即走 `bootExt2`——挂 ext2 根为 `/`，`setupUsers` 从根的 `/etc/passwd`
  建用户库，模块只从 ext2 根镜像自带的 `/lib/modules/<version>/` 装载（自包含，fail-fast，
  绝不回退到引导盘/CC fs 的 `/lib`）。两条路径最后都 spawn 同一份 init 源码，随后由 init 启动
  `default.target`。

  两条路径的**用户库与模块装载是同一段代码**（`setupUsers`）：少一处就会出现
  "login 拿不到 `user.verify` → 立刻退出 → getty 重启风暴" 这种只在真机上看得见的故障。
  根上没有 `/etc/passwd` 一律 fail-fast 报错（没有用户库等于登录不了，不静默降级）。

真机流程：`tools/realmachine.py`（**先关机** → 打包 → `tools/deploy.py` 重建 ext2 根镜像 → 注入第二个 ext2 分区
供 fstab 测试 + `verify.service` → `e2fsck -fn` 门禁 → 写**磁盘 CC-fs 的引导配置**（`/.boot` = `/boot/dlub.lua`
与 `/dlub.cfg` = `bootdisk left`，缺一不可）→ 装盘并按 md5 校验 → 开机 → **引导门禁**（`/var/log/verify.log`
必须与本轮部署时不同且跑完）→ **块设备/dd 门禁**（真机 `cat /dev/sdb2 | cksum` 必须等于宿主的
`cksum /parts/data.img`；`cat_blockdev_root_part`/`cat_binary_exact`/`dd_sigint_interrupt` 三条必须 ok，
且 `dd_sigint_rc=130`）→ 用 `debugfs` 从镜像取回 `/var/log/*` → 再停机 fsck 一次 →
**mkfs/fsck 门禁**（verify.sh 在电脑自带存储的 CC-fs 上现造 `/parts/scratch.img` 并现场
`mkfs.ext2`/`fsck.ext2`，宿主把该镜像取回来用真实 `e2fsck -fn` 复判：必须干净、`LABEL=SCRATCH`、
修复后 `/hello.txt` 内容完好，并逐条核对 verify.log 里的 `ok mkfs_ext2`/`fsck_*` 与退出码））；
`scripts/realmachine_verify.sh` 是它在真机上跑的验证脚本。

**真机踩过的两个坑（别改回去）**：

- **不许用 RCON 改世界状态来"叫醒"机器**。真机测试**只允许**用 `/computercraft` 子命令
  （`dump`/`shutdown`/`turn-on`/`tp`/`queue`/`track`）。用 `forceload add` 之类去强加载电脑所在
  的区块，是在**改服务器世界状态**——那台服务器是共用的，副作用留在存档里，而且掩盖了真正的问题：
  电脑不执行是锚点/区块/存档状态的问题，不是强加载能修的。
  一次实际事故：电脑 3 在坐标 `20481033,128,20491273`（远离出生点），`dump` 显示 `On=Y`
  但既不写电脑自身 FS 也不写根镜像 —— 系统没在跑。当时用 `forceload add` 试图强加载**是错的**，
  已 `forceload remove` 撤销（该维度原本就没有强加载区块）。
  **正确做法**：机器起不来就**停下来报告这个阻塞**（引导门禁本来就会拦住），不要绕。
  真机验证的正当信号是"`realmachine.py` 的引导门禁通过"，不是"我想办法让日志变了"。

- **回退引导 = 假绿灯**。BIOS 按 `bootOrder`（电脑 3 是 `left`→`root`）扫设备，设备上没有 `/.boot` 就不算可引导；
  磁盘缺 `/.boot` 或 DLUB 读不到该盘的 `/dlub.cfg` 时会**静默回退**去引导电脑自身存储上的旧安装。
  于是 `realmachine.py` 会拿着一份**上一轮**的 `/var/log/verify.log` 报成功（改了什么都没生效也全绿）。
  所以脚本自己写两处引导配置（电脑自身 FS 的 `/.boot`=`/main.lua` + `/dlub.cfg`，磁盘 CC-fs 的
  `/.boot`=`/boot/dlub.lua` + 同盘 `/dlub.cfg`，都指向磁盘上的 ext2 根；实测磁盘 CC-fs 上**新增**的文件
  游戏侧可能读不到，电脑自身 FS 的改动则生效），并在取日志前做引导门禁：本轮 verify.log 必须变过、
  且含 `=== verify done ===`，否则直接失败。（顺带把引导日志也打出来：磁盘 CC-fs 的 `/delin.log` 是 DLUB 写的、
  根镜像里的 `/delin.log` 是内核写的、电脑自身 FS 的只在回退时才有意义。）
- **CCFS 上 `fs.attributes` 对不存在的路径是"抛错"而不是返回 nil**（ext2 后端返回 nil，所以
  宿主测试台与 ext2 根的真机都看不出来）。真机症状：CCFS 根下 `dd of=/parts/a.img`（文件还不
  存在）整个进程死在 CC 抛的 `"/parts/a.img: No such file"` 上 —— 而 dd 的输出端第一步就是
  `fs.attributes(of)`，"创建新文件"这条路直接不可用（`cp` 走 exists+open w，所以没事）。
  修法在 `kernel/vfs.lua` 的 `vfs.real`：attributes 里 pcall 一层，失败一律返回 nil（Linux 的
  stat(2) ENOENT 语义，也是 ext2 后端本来的行为）。发现它是因为软RAID 的真机验证要在
  `/parts` 下用 `dd` 造成员镜像 —— 这也说明"只有真机才跑得出来的路径"值得专门铺一遍。

- **子进程写输出文件要自己 flush**。ext2 的 `"w"` 句柄只在 flush/close 时落盘，而 `scripts/user_helper.lua`
  不等子进程就退出（`/bin/lua` 用 xpcall 跑脚本，Lua 5.1 不能跨 pcall 让出，见其注释）——
  真机上输出文件因此**是空的**，宿主测试台却看不出来（宿主文件是直写的）。现在那份 helper 把输出句柄包成
  “每次写都 flush”，谁先退出都不丢内容。
- **从内核里注入按键做交互式真机测试**（`scripts/intr_test.ko`，验证"提示符处 `^C`"就是这么测的）。
  四条经验（都是真机上量出来的，别改回去）：
  ① 载荷必须是**内核模块**：模块在调度器起来之前 `init`，正好在那里包住 `os.pullEventRaw`（调度器的每个
  事件都从它过），也从那里驱动行规程；② **按键不要走 `os.queueEvent`** —— 实测注入了 90 秒、`tty.feedInput`
  计数一直是 0：CC 事件队列里排队的按键会被**带过滤器的拉取吃掉**（`os.pullEvent("timer")` 这一路，正是
  每个进程 `os.sleep` 的实现，init 每 50ms 就有一次），真实按键能活下来只因为内核当时已经阻塞在无过滤的
  `pullEventRaw` 上。正确做法是直接调 `tty.routeKey`/`tty.feedInput` —— 那正是调度器 `routeEvent` 对真实
  按键做的事，行规程/`^C` 回显/给前台进程组投 SIGINT 全是真家伙；③ **不要靠屏幕同步** —— 内核/用户态的
  console 输出走 CC 终端的 `write`，**不经过 tty 的屏幕模型**，会把 tty 自己的格子盖掉（实测：登录提示符
  那一行还没被看见就被别的日志盖了）。可靠的办法是"用**文件系统的产物**当同步点"（命令写 `/tmp/x`，
  注入器 `vfs_api.fs.exists` 轮询），再加上 tty 行规程**会把整行缓冲起来**（没有读者也一样），于是登录那
  几行可以一次性喂进去、不需要等提示符；④ 进度用 `klog.write`（ring buffer -> syslogd -> `/var/log/messages`，
  宿主机 debugfs 读得到，注意 logrotate 会把它转成 `.1`），**别用 `kprint`**（它还画控制台）。判据三件套：
  正对照（注入器真的驱动了会话）+ 负对照（打了一半的行必须没被执行）+ 回归判据（`^C` 之后那条命令必须
  执行）；载荷收工后要把 `os.pullEventRaw` 还回去，别给后面的自检留开销。
- **真机自检服务要给足 `TimeoutStartSec`**。`realmachine.py` 生成的 verify*.service 是 `Type=oneshot`，
  而 init 引擎给 oneshot 的默认超时是 **60s**（systemd 对 oneshot 的默认其实是 infinity）—— 自检脚本
  一轮要跑近百个进程、长度已经压在这个上限附近，被 init SIGKILL 掉就表现为"`verify.log` 变了但没跑完"，
  看着像内核回归（本轮就因此误判过两轮）。生成的单元里写死 `TimeoutStartSec=600`。

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
- **信号只在进程被 resume 时投递**：调度器在 resume 前跑 `process.applySignals`，所以**任何长时间
  不让出的循环都收不到 `^C`/`^Z`，也不会被 `kill` 停掉** —— 它自己就把调度器霸住了。因此"会长时间
  搬运数据的工具"必须照 `cat`/`lp`/`dd` 那套三件套写：① 装 SIGINT handler
  （`syscalls["signal.install"](2, ...)`，只置一个标志，别在里面做事）；② 每累计 ~50ms CPU 时间
  （`os.epoch("utc")` 取差）`os.msleep(0)` 让出一次，**不是按字节让出**（每次让出都是一次事件往返，
  高频让出会淹没事件队列）；③ 循环条件里查标志，收尾时按 GNU 的退出码返回（`^C` → 130）。
  真机症状（曾经的 bug）：`dd` 读数据时 `^C` 完全无效 —— 拷贝循环从头到尾不让出，信号投不进来。
  `scripts/realmachine_verify.sh` 用 `pkill -INT -x dd` + `pgrep` + `wait`（130）锁着这条；
  注意 `&` 在 Delin 里是"起一个子 shell 跑这条命令"，`$!` 是**子 shell** 的 pid，朝它发信号只杀得掉
  子 shell（dd 变孤儿继续跑），而真机 `^C` 是 tty 投给**前台进程组**（dd 自己在内）。
- **`cat` 默认按字节拷贝**（没有 `-n/-b/-s/-E/-T/-v/-A` 时，且句柄不是终端）：POSIX/GNU cat 就是字节
  搬运工。走 `readLine` 会①把 CC 原生句柄的 `\r\n` 折成 `\n`（`\r` 丢掉，ext2 句柄不折），
  ②给末行没有换行的文件补一个 `\n` —— 文本看不出来，对块设备/二进制就是数据损坏
  （`cat /dev/sda1` 要的就是镜像原始字节）。行选项下、以及 `isTTY` 的句柄（行规程，读一次给一整行）
  仍按行处理。自检：`scripts/posix_test.sh` 的 `cat_binary_{file,stdin,pipe}_exact`（宿主与真机各跑一次）。
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
- **进程里未捕获的错误必须进内核日志**（`scheduler` 在协程 resume 失败时打
  `process <名字> (pid N) died: ...`）：父进程（`sh`）只会拿到一个"退出码 1"，工具内部崩了在真机上
  **完全看不到原因**。这行日志就是踩出来的：`devdisk.lua` 里的 `mkfs/fsck` 用了 `blockdev`/`ext2`
  却没 `require`，真机上 `mkfs.ext2` 静默 `exit 1`、`/var/log/verify.log` 里一个字都没有
  （宿主测试台也因为 `devdisk` 用的是桩而看不出来）。判据是**错误信息本身**进了 `klog`
  （`dmesg`/`kern.log` 可见），不是"父进程多了个退出码"。
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
- **设备与文件系统分层**：`devdisk` 只负责「有哪些设备」（枚举存储：电脑自带存储恒为 `sda`、磁盘驱动器
  接在其后 → `/dev/sdX` + UUID 解析 + 挂载表），
  文件系统实现由模块用 `kapi.registerFstype(name, fn)` 注册（`ext2.ko` → `ext2`，`ccdisk.ko` → `ccdisk`）；
  `mount -t <type>` 找不到处理器即报错（fail-fast，无回退）。
- **文件句柄的两种调用风格（踩过的大坑）**：CC 原生文件句柄的方法是 Java 方法，Lua 侧
  **self 是隐式的** —— 只能 `h.write(s)`（点号）；写成 `h:write(s)` 会把**句柄自己**当数据传进去，
  结果是文件里出现 `table: 0x...`，而且**不报错**，极难查。Delin 自己的句柄（ext2 后端、
  `/dev` 设备）是普通 Lua 表，方法吃冒号，全部 `/bin` 工具都按冒号写。
  两条路径必须给上层同一套语义，所以 `vfs.real()` 的 `open` 会把 CC 原生句柄包一层
  `wrapCCHandle`（见 `src/kernel/vfs.lua`），**两种调用风格都接受** ——
  于是内核里既有的点号调用（`f.readAll()`）与用户态工具的冒号调用都能用。
- **反过来不成立：tty/fb 设备句柄只吃冒号**，而且点号调用是**静默写空串**（`write(self, s)` 收到
  `self=数据, s=nil`，`tostring(nil or "")` 就是空串，返回值也不为 nil，一声不响）。
  管道句柄 `write(_, s)` 同样把点号调用里的数据丢进 `_` —— 也是静默丢。
  `tee` 就栽在这上面（写成了 `out.write(chunk)`）：FILE 目标（ext2 句柄两种风格都收）照写，
  stdout 却什么都没有 —— 交互式终端里 `tee f` 屏幕上不出现任何东西，管道里下游读到 0 字节。
  教训两条：① 工具写句柄一律冒号（`h:write` / `h:read` / `h:readLine`），点号只留给 CC 原生句柄，
  而它已经被 `wrapCCHandle` 桥过一层（`tee` 之后按这条把 `cp`/`mv`/`sed`/`ed`/`patch`/`split`/`sort`/
  `comm`/`join`/`paste`/`head`/`tail`/`wc`/`diff`/`cksum`/`file`/`strings`/`xargs`/`sh` 等全部点号调用
  清掉了）；② 测试台的 stdout/stdin 桩必须照真机句柄建
  （`tools/hosttest.lua` 的 `runTool` outHandle、`tools/harness.lua` 的顶层 stdout 桩都是
  冒号 + `s or ""`），否则这类 bug 只有真机上才露头。真机回归见 `scripts/tee_verify.lua`：
  终端那一路用 tty 句柄的**光标位置**当观测点（CC 没有屏幕读回 API），并带一个"点号调用光标
  一动不动"的控制组，保证这套观测法本身是有效的。

## 构建

```bash
lua5.1 tools/build.lua             # 构建 dist/: 压缩内核/DLUB/BIOS/工具/模块/配置 + manifest
lua5.1 tools/build.lua --check     # 构建 + 压缩等价性门禁(hosttest 680 项 + 7 个自检脚本差分)
lua5.1 tools/build.lua --release   # 构建 + 生成 dist/release/<版本>/ 发布树(安装布局的 payload)
sh tools/serve.sh                  # 开发期: 把发布树挂在 10568 端口(游戏侧 wget 安装用)
```

**ASCII 门禁 `asciiGate`（每次构建末尾都跑）**：逐字节扫 `dist/` 全部产物 + `manifest` +
每棵 `dist/release/*/` 发布树，任何文件出现非 ASCII 字节即 fail-fast 并报出 `文件:行号`
（判据与理由见「约定」一节）。它把"哪些注释会被压缩器丢掉、哪些会原样进产物"这条知识
从人脑挪到了构建期 —— 往 `src/init/*.lua`、`src/modules/*.ko` 的 `--@` 头、`src/etc/*`、
`src/units/*` 里写中文会当场挂构建。`dist/` 里**陈旧的目录也在扫描范围内**（上个版本留下的
`dist/modules/<旧版本>/`、旧发布树都是可安装的产物），命中就 `rm -rf dist` 重来。

**发布（CI）**：`.github/workflows/release.yml` 在**打 `v*` tag** 时跑
`lua5.1 tools/build.lua --check --release` + `lua5.1 tools/installertest.lua`（门禁不过不发），
然后把这棵发布树推成 **`release` 分支**的 `<版本>/` 目录（一个版本一个目录，推新版本不动旧版本）。
tag 必须等于 `v<src/kernel/version.lua 里的版本号>`，不一致直接失败（免得版本号漂了）。
安装器里写死的默认源就是它 —— `DEFAULT_URL` = `https://raw.githubusercontent.com/Hello-World2333/delin/release/<版本>`，
版本号用 `require("kernel.version")` 取（升级版本不会漏改，也就不会静默装到旧版本）：

```bash
# 游戏内(目标电脑, CraftOS 下)直接从 GitHub 装:
wget run https://raw.githubusercontent.com/Hello-World2333/delin/release/<版本>/install.lua
```

> **仓库必须保持 public**：raw.githubusercontent.com 对私有仓库一律 404（真机实测 CC 侧
> `err=Not Found`，宿主机 curl 同样 404），私有期间这个默认源对所有玩家都不可用。

`tools/build.lua` 是唯一入口：它会**自动建 `dist/`**（以前直接跑 `tools/bundle.lua` 时
干净 checkout 上没有 `dist/`（`.gitignore` 里）就报错）。`dist/` 是"可发布树"：

| 产物 | 去处 |
|---|---|
| `dist/kernel.lua` | 引导盘的 `<boot>` 行（默认 `/boot/delin.lua`） |
| `dist/dlub.lua` | 电脑自身 FS 的 `/boot/dlub.lua`（EXT2 根引导用） |
| `dist/bios/startup.lua` | 电脑自身 FS 的 `/startup.lua` |
| `dist/bin/*`、`dist/modules/<版本>/*`、`dist/units/*`、`dist/etc/*` | 目标文件系统对应路径 |
| `dist/manifest` | 版本 + 每个产物的 `size crc32`（安装器校验用，见 `tools/crc32.lua`） |
| `dist/release/<版本>/` | 发布树：`manifest` + `payload/`（`payload/` 下的相对路径 = 目标上的绝对路径） |

`tools/deploy.py` / `tools/realmachine.py` / `tools/deploy_to_computer4.py` 一律消费 `dist/`
（`dist/bin` 缺失即 fail-fast），不再直接从 `src/` 取，避免内核与工具版本不同步。

**`--#include`（构建期拼接）**：目标机的进程环境是白名单，`/bin` 工具**没有**
`require/dofile/loadfile`（见 `kernel/procenv.lua`），所以"两个工具共用一份实现"只能是构建期
拼成一整份。源文件里写一行 `--#include <相对仓库根的路径>`，`tools/include.lua` 在**压缩之前**
把它替换成那个文件的内容（可嵌套，路径一律相对仓库根）：

```lua
-- src/bin/sh(4 行的入口; 实现全在 src/lib/shcore.lua)
--#include src/lib/shcore.lua
return shellMain(nil)
```

三条约束都在 `tools/include.lua` 里 fail-fast（报出"谁 include 的谁、第几行"）：被 include 的
文件**不能有顶层 `return`**（拼接后是同一段 chunk，一个 return 会把产物截断）、不能成环、
嵌套不超过 8 层。用它的地方必须**共用同一份实现**：`tools/build.lua` 的 `minifyTo` 与
`shadowGate`、`tools/harness.lua` 往测试台铺 `src/bin` 时的 `copyTool`（**展开后写文件, 不是
`cp`** —— 不展开的话宿主跑的是"引用了一堆不存在文件"的入口，真机反而正常，白白浪费一轮排查）。
`src/lib` 也在 shadow 门禁的扫描目录里。

**压缩器**（`tools/minify.lua`）：去注释、去缩进、折叠空白，并把**局部变量/参数改名成短名**。
它不是正则清洗 —— 源码里到处是 `local args = args or {}`（右值是内核注入的**全局** `args`），
按 token 改名会压成 `local a = a or {}` 让工具全崩，所以必须先做真正的语法分析：
递归下降解析 + 作用域分析，先解析初始化表达式再声明局部，只给局部符号分配短名，
最后**从 token 流输出**（不重新打印语法树），保证输出与输入的 token 序列逐项相同（注释除外）。
三条门禁，任何一条不过即 fail-fast：① 产物能被 `lua5.1` 解析；② 重新词法分析产物与原 token
逐项比对；③ 新名不得遮蔽本 chunk 里出现的任何全局名，内层函数避开祖先已分配的新名。
实测 `src/` 全量 634,040 → 296,863 字节（-53%），内核 bundle 266,208 → 138,776（-48%）。

内核 bundle 复制到引导盘 `bootPath`（manifest 的 `boot` 行，默认 `/boot/delin.lua`）；DLUB 复制到
**电脑自身 FS** 的引导脚本入口（`/.boot` 指向的 `/main.lua`）。DLUB 还需在**电脑自身 FS** 写
`/dlub.cfg` 指定引导盘外设名（如 `bootdisk left`），缺失或非法时 DLUB 直接报错、不猜测。
产物均以 Lua 5.2+ `_ENV` 技巧打包，每个模块包一层 `__require` 到内部 shim；init 的多个源文件
（`unit.lua` + `service.lua` + `init.lua`）拼成**一个** chunk（前两者为内部模块，最后一个是顶层主程序）。


## 安装

Delin 的安装**完全发生在游戏内**：宿主机只负责用静态 http 服务托管发布树，用户在目标电脑上
一条命令起装。不需要任何外部工具、不需要改服务器文件、不需要重建镜像。

```bash
# 游戏内(目标电脑, CraftOS 下): 默认源就是 GitHub 上的 release 分支(见"构建"一节)
wget run https://raw.githubusercontent.com/Hello-World2333/delin/release/<版本>/install.lua

# 开发期也可以改用自己的 http 服务: 先 `lua5.1 tools/build.lua --release`, 再
sh tools/serve.sh                 # dist/release 挂在 10568 端口
# 然后在安装器的 Install source 步骤选 `custom ...` 手输 http://<宿主机>:10568/<版本>
```

安装器（`dist/install.lua`，由 `tools/installer.lua` + 内核同一份 `blockdev`/`ext2`/`crc32`
打包成单文件）做的事：

1. 从安装源拉 `manifest`（`version` / `files` / 每文件 `size crc32`），再逐个下载 `payload/`
   并**校验大小与 CRC32**，任何一处不符即 fail-fast（不留半成品配置）；
   - **网络层重试**：`http.get` 返回 nil（连不上）或 5xx 时最多试 3 次、每次间隔 0.5 s；4xx 不重试。
     真机实测：从 GitHub 默认源连拉 65 个 payload 会**随机**断在某个文件上（两次分别挂在
     `bin/mount` 与 `bin/chmod`，而宿主机 curl 同一批文件 0 失败）—— 一次失败就终止整个安装太脆。
     重试只包住**传输**：拉回来的 size/CRC32 不符仍然当场 FAIL，不做第二次。
2. 把 payload 铺到目标：**CCFS**（直接铺文件）或 **EXT2**（现场 `mkfs` 出镜像再写进去）。
   **`payload/` 下的相对路径 == 目标文件系统上的绝对路径**，所以里面**不含** BIOS：
   BIOS 是"电脑自身存储上的 CraftOS 引导文件"，放在发布树根 `<版本>/startup.lua`（与 `install.lua` 同级），
   安装器单独取它。曾经把 BIOS 塞进 `payload/`，于是装 ext2 时被整棵铺进**镜像根**，
   凭空多出一个永远用不到的 `/startup.lua`；
3. 写引导配置（**电脑自身存储**）：`/startup.lua`（Delin BIOS，旧的备份成 `/startup.lua.craftos`）、
   `/boot/delin.lua`、`/boot/dlub.lua`、`/.boot`、`/dlub.cfg`；
4. 全程写 `/delin-install.log`（CC 读不了屏，装完/装挂了都要能被宿主机读回）。

**交互式向导**（不是单屏热键 TUI）：一步一屏，上下箭头选、回车确认，**Backspace 退回上一步**
（文本输入里 Backspace 删字符，**已经到行首再按一次就是退回**），`Q` 退出；
光标所在的那一行整行反显高亮，`[x]` 标出回车会选中的那一项：

> 没有用 Esc：**CraftOS 根本不产生 Esc 键事件** —— 真机实测 `keys.escape` 是 `nil`、
> `keys.getName(256)` 也是 `nil`（这个版本里字母/数字键码是 ASCII、特殊键是 GLFW 码：
> `enter=257 backspace=259 up=265`），所以"回退"只能绑 Backspace。


| 步骤 | 内容 |
|---|---|
| 1. Install type | `CCFS`（直接把文件铺到目标）/ `EXT2`（现场 `mkfs` 出镜像再写进去） |
| 2. Install target | 电脑自身存储 / 每个有数据的磁盘驱动器（各带剩余空间） |
| 3. Install source | 上次用过的源 + 内置默认源，或 `custom ...` 手输 URL；**确认后立刻拉一次 `manifest`**，拉不到就留在这一步报错重输（不会等到"开始装"才发现源不通） |
| 4. Image size（仅 EXT2） | `auto` / 256 / 512 / 768 / 1024 KB，或 `custom ...` 手输 64–8192 KB。auto 按 payload + 元数据 + 目录余量算，再上浮 15%、对齐 64 块（CCFS 时这一步整个跳过） |
| 5. Summary | 列出最终配置（类型/目标/安装源/payload/镜像大小/将写入的引导配置）；`Start installation` 开装，`Cancel` 退回上一步改配置 |

装完**只有回车才重启**（`Press Enter to reboot now`），其它键一律不处理 —— 免得手滑按到别的键
把向导带回摘要页又重装一遍；装失败则是"按任意键回摘要页"（可以改配置再来一次）。
**向导每进一个步骤 / 每个文本输入
都往 `/delin-install.log` 落一行**（`wizard step 2/5: target`、`wizard size: custom 512 KB` 这类）——
CC 电脑读不了屏，宿主机只能靠日志判断它走到了哪一步、卡在了哪里。

**无人值守安装**：`/delin-install.cfg` 写齐 `url` / `type` / `target` / `size` / `auto 1`
即跳过向导直接装（真机自动化验证就是这么跑的）。

**真机自动跑完整向导**（验证交互路径本身）：`scripts/installer_interactive_test.lua`
装成电脑自身 FS 的 `/startup.lua`，配一份计划 `/installer-test.plan`（`url <install.lua URL>` /
`wait <日志标记>` / `key <键名>` / `text <字符串>`），它把安装器跑在一个协程里、另开一个协程**注入
key/char 事件**来驱动向导。喂按键的时机靠 `wait` 盯 `/delin-install.log` 里的标记同步，**不能提前
排队**：CC 里带过滤器的事件拉取（`http.get`/`sleep`）会把队列里不匹配的事件丢掉，一次性排好的按键
会被中途一次 http 请求整批吃掉（实测）。

四种落盘形态（引导入口**恒定**在电脑自身存储上：BIOS 开机只跑 `/startup.lua`）：

| 安装类型 | 目标 | 电脑自身存储 | 目标设备 |
|---|---|---|---|
| CCFS | 电脑自身存储 | BIOS、`/.boot` = `/boot/delin.lua`、`/boot/delin.lua`、`/bin`、`/lib`、`/etc` | — |
| CCFS | 磁盘 | BIOS、`/.boot` = `/boot/dlub.lua`、`/boot/dlub.lua`、`/dlub.cfg`(=`ccdisk <盘名>`) | `/boot/delin.lua`、`/bin`、`/lib`、`/etc` |
| EXT2 | 电脑自身存储 | BIOS、`/.boot` = `/boot/dlub.lua`、`/boot/dlub.lua`、`/dlub.cfg`(=`rootfs /parts/root.img`) | `/parts/root.img`(现场 mkfs) |
| EXT2 | 磁盘 | 同上一行(`bootdisk <盘名>`) | `/parts/root.img` + `/parts/manifest` |

真机实测（电脑1 = 一台电脑 + 一个磁盘驱动器，四种形态都验过；判定标准都是
`users loaded`、`modules loaded`、`init up (pid 1) default.target active`、0 次 getty 重启）：

| 形态 | 装法 | 引导日志 |
|---|---|---|
| CCFS → 电脑自身存储 | 安装器（`wget run`） | `/.boot` → `/boot/delin.lua` → 内核，直接进 `init up` |
| EXT2 → 电脑自身存储 | 安装器（游戏内 mkfs） | `[DLUB] root=/parts/root.img fs=ext2 kernel=/boot/delin.lua (142715 bytes)` → `root boot: fstype=ext2` |
| CCFS → 磁盘（`ccdisk`） | 同安装器产出（见下方配额限制） | `[DLUB] config /dlub.cfg ccdisk=right -> disk` → `root boot: fstype=ccdisk`，且盘同时以整盘/分区设备节点可见（该次实测在“自带存储还不是设备”之前，日志里盘是 `sda`；现在自带存储恒为 `sda`，盘顺延到 `sdb`） |
| EXT2 → 磁盘（`bootdisk`） | 同上 | `[DLUB] root=disk/parts/root.img fs=ext2` → `root boot: fstype=ext2` |

其它实测数据：
- **电脑自带存储成为块设备 + UUID 命名空间真机实测**（电脑3 bootdisk + 电脑4 rootfs, 2026-09-11）：
  修 bug 前电脑4（Delin 装在自带存储里）的 `delin.log` 是 `block devices: (none)` +
  `root boot: no /dev node for root partition`；修完同一台机器变成
  `block devices: sda(ccdisk,uuid=c4) sda1(ext2,uuid=c4-1) sda2(ext2,uuid=c4-2)`（`/parts/manifest` 的两个分区）。
  电脑3（根在磁盘上）：`block devices: sda(ccdisk,uuid=c3) sdb(ccdisk,uuid=d0) sdb1(ext2,uuid=d0-1) sdb2(ext2,uuid=d0-2)`，
  `mount` 里根显示为 **`/dev/sdb1 on / type ext2 (rw) uuid=d0-1`**（不再是虚拟设备名 `rootfs`），
  fstab 的 `UUID=d0-2` 自动挂载 `/mnt/data` 成功；`mount -t ccdisk /dev/sda /mnt/hdd` 列出的是
  **电脑自身 FS**（`main.lua`/`startup.lua`/`delin.log`…）→ `ok own_storage_is_block_device`；
  `mount UUID=d0-1` 可挂、裸数字 `mount UUID=0` 被拒（`no such device`，命名空间必需）。
  停机后 `e2fsck -fn` 干净。
- 游戏内 mkfs + 铺 65 个文件造出的镜像，拿到宿主机上 `e2fsck -fn` **干净**
  （97 文件 / 444 块 of 512）；512 KB 装得下 346 KB payload，真机整轮约 1 分钟。
- **交互式向导真机实测**（电脑3 + 磁盘0，注入按键走完整套向导，两种落盘路径各一轮，
  判定标准同上，另加"装完按**回车**真重启后 `init up`"）：
  - EXT2 → 电脑自身存储，`Image size` 手输 `512 KB`：向导 5 步全走到
    （`wizard step 1/4: type` … `wizard size: custom 512 KB` … `wizard confirm: start installation`），
    装完重启 → `[DLUB] root=/parts/root.img fs=ext2` → `root boot: fstype=ext2` → `init up`；
    停机后对盘上的镜像再跑 `e2fsck -fn` 干净（444/512 块）。
  - CCFS → 电脑自身存储：向导 4 步（**没有 `Image size` 这一步**），装完重启 →
    `vfs ready` → `modules loaded from /lib/modules/0.0.2`（电脑自身 FS）→ `init up`。
- **默认源（GitHub release 分支）真机实测**（电脑3，2026-09-11）：驱动直接从
  `https://raw.githubusercontent.com/Hello-World2333/delin/release/0.0.2/install.lua` 取安装器
  （43504 字节），向导 `Install source` 那一步选**内置默认源**（就是上面那个 URL）：
  `wizard source: https://raw.githubusercontent.com/.../0.0.2 (version 0.0.2, 65 files)` →
  铺完 65 个文件 → `Install OK.` → 按**回车** → `os.reboot()` →
  `spawned init as pid #1` / `[init] init up (pid 1), default.target active`（真机日志只有
  `delin.log` 与驱动日志两份，前者出现即表示确实重启进了 Delin）。
  同一套流程再跑一轮, 收尾只按 **R / Q**：驱动跑完（`feeder done`）机器仍停在
  `Press Enter to reboot now (other keys are ignored).`，`/delin.log` 不存在（没有重启）——
  "其它键不处理"这条是真机验过的，不是只在宿主假环境里过。
  注：这条链路上 `http.get` 偶发断连（见"安装"一节的网络层重试），真机驱动脚本自己也重试 3 次。
- **注意 CC 的软盘配额**：本环境 `fs.getCapacity("/disk")` 只有 **125,000 字节**（磁盘上还有个
  宿主放进去的 2 MB `data.img`），所以 `fs.getFreeSpace` 为 0 —— 安装器会**正确拒绝**并给出
  `FAIL: target has 0 B free, need 346.5 KB`（fail-fast，不留半成品配置）。
  要在磁盘上真装，需要把 `floppy_space_limit` 调大（≥ 1 MB），或把 Delin 压得更小。
  上面两种磁盘形态因此是用宿主铺盘（项目一贯做法）验证的**内核引导路径**，
  安装器的落盘代码路径由前两行（电脑自身存储）覆盖。

验证：

```bash
lua5.1 tools/hosttest.lua        # 宿主测试: init 引擎/fstab/syslogd/logrotate/systemctl/sysfs/ccprinter/procfs/tty-ANSI/redstone/devdisk (680 项)
DELIN_REPO=<压缩后的源码树> lua5.1 tools/hosttest.lua         # 压缩器等价性: 同一套测试跑在压缩产物上
DELIN_SRCBIN=<压缩后的 bin> lua5.1 tools/harness.lua /bin/sh # 同上, 工具级差分比对
lua5.4 tools/hosttest.lua        # 同上用 5.4 跑一遍(CC 是 5.2 语义, 不能只在 5.1 上验;
                                 # 测试台的 fs 门面曾用 os.execute(...)==0 判目录 —— 5.1 独有语义)
lua5.1 tools/harness.lua /bin/sh # 宿主上跑真实工具源码(sh/作业控制/管道; /sys 走真实 sysfs 后端, /proc 走真实 procfs 后端)
                                 # DELIN_HARNESS_TTY=1 让 stdin/stdout 伪装成终端(分页器/REPL/desh 的按键自检都靠它);
                                 # DELIN_HARNESS_SEED=<宿主目录> 在 setupRoot 之后把该目录铺进测试根 ——
                                 # "进程起来前就得摆好文件"的场景(如先放一份 ~/.deshrc)用得上
lua5.1 tools/installertest.lua    # 安装器宿主回归: 假 CraftOS 环境(假终端格子+脚本化事件队列)跑构建产物
                                  # dist/install.lua, 按键序列驱动整套向导(16 用例/207 断言: 两种落盘形态、
                                  # 自定义容量、坏源/空间不足/网络断连 fail-fast、http 重试、退格回退、
                                  # 无人值守、双驱动器、装完只有回车重启; 默认源用软链假装 GitHub 可访问;
                                  # 失败时 dump 每一屏 + 日志 + 目标文件树)
                                  # **自定义容量用例(case 4)的尺寸必须跟着 payload 体积长**: 它写死一个
                                  # 非预设值(0.0.4 起 1152 KB; 曾经是 896 KB)。0.0.3 -> 0.0.4 payload
                                  # 622 KB/115 文件 -> 812 KB/117 文件, 实际块用量 866 块 > 896 KB 镜像
                                  # 格式化后的 858 块空闲, 于是装到第 97 个文件报 `FAIL: no block`。
                                  # 见到这个错先按 ceil(size/1024) 逐文件求和 + 间接块 + 目录块重算容量,
                                  # 别先怀疑 ext2 分配器(auto 档由 autoBlocks 按同一份 payload 算, 不受影响)
lua5.1 tools/harness.lua /bin/sh < scripts/proc_test.sh   # /proc + ps/pgrep/pkill/killall 自检(与真机比对)
lua5.1 tools/harness.lua /bin/sh < scripts/redstone_test.sh   # /sys/class/redstone 读写/校验自检(与真机比对)
lua5.1 tools/harness.lua /bin/sh < scripts/lua_test.sh   # /bin/lua 脚本/stdin/arg/dofile/退出码 + 进程环境白名单(与真机比对)
lua5.1 tools/harness.lua /bin/sh < scripts/user_test.sh  # 用户管理(passwd/useradd/usermod/group*/id)自检(与真机比对)
lua5.1 tools/harness.lua /bin/sh < scripts/sh_expand_test.sh  # sh 展开(通配符/命令替换/算术)自检(与真机比对)
lua5.1 tools/harness.lua /bin/sh < scripts/desh_test.sh  # desh 非交互(与 sh 逐字节一致: -c/脚本/退出码/报错前缀)自检
sh scripts/desh_tty_test.sh        # desh 行编辑器(宿主专用: 伪装终端, 33 项按键自检 —— 补全/历史/^R/建议/纠错/deshrc)
sh scripts/lua_repl_test.sh        # /bin/lua 交互式 REPL(宿主专用: DELIN_HARNESS_TTY=1 伪装终端)
sh scripts/sh_intr_test.sh         # sh 交互式"提示符处 ^C"(宿主专用: 伪装终端 + 注入中断键)
lua5.1 tools/ext2test.lua        # ext2 驱动宿主回归: 真实镜像上跑目录增删, 再用宿主 e2fsck -fn 判定
lua5.1 tools/mdtest.lua          # 软RAID 宿主回归: 五个级别 + 非默认布局, 独立布局模型与独立 GF(2^8)
                                 # 乘法逐块核对成员镜像, 降级/重建/组装/拒绝规则, 阵列上的 ext2 交给 e2fsck
python3 tools/realmachine.py --base /mnt/bak/root.base.img   # 真机: 先关机->打包->部署->重启 #3->取回 /var/log/*
python3 tools/realmachine.py --printer   # 真机 + 打印机(会实际打印页面): 探测 printer API + 验证 /dev/lp0
python3 tools/md_realmachine.py          # 真机: 软RAID 两阶段验证(电脑 #6; 建阵列/降级/重建/组装,
                                         # 重启后断言开机自动组装; 见「软RAID」与「CEECC 真机验证」)

# 真机跑交互式安装向导(电脑3 + 磁盘0; 电脑先停机):
cp scripts/installer_interactive_test.lua /mnt/computer/3/startup.lua
cp scripts/installer_plan_ext2.plan       /mnt/computer/3/installer-test.plan
python3 ~/docs/tools/rcon.py "computercraft turn-on #3"   # 注入按键走完向导并重启
# 之后读回: /installer-test.log(同步与按键) /delin-install.log(向导配置+安装结果) /delin.log(引导)
```

`realmachine.py` 最后会停机再对安装到磁盘的 `root.img` 跑一次 `e2fsck -fn`：**跑一轮后 fsck 必须干净**，
不干净就整体失败（这是"Delin 自己把文件系统写坏了"的判据）。

## 约定

- 源码用 **EmmyLua** 注解仅为人类维护 / IDE 提示，不作为任何门禁；其警告与报错忽略。
- **装到 CC 电脑上的任何文件一律只用 ASCII**（不只是终端输出）：CC 终端没有中文字形，非 ASCII
  字节打出来是乱码，部分传输路径还会丢字节 —— 所以判据是**产物**：`/boot/delin.lua`、`/startup.lua`、
  `/etc/*`、`/lib/systemd/system/*`、`/bin/*`、`/lib/modules/<版本>/*`、`install.lua`，以及宿主机的
  `dist/` 全树。字符串（错误消息、`help`、提示符、日志、写入文件的文本）自不必说。
- **注释能不能写中文，取决于压缩器丢不丢它**：`src/kernel/*`、`src/bin/*`、`src/bios/*`、
  `tools/installer.lua` 的注释会被 `tools/minify.lua` 丢掉，可以中文；丢不掉的那几处必须 ASCII ——
  `src/init/*.lua`（原样嵌进 `kernel.lua` 的字符串）、`src/modules/*.ko` 的 `--@` 元数据头、
  `src/etc/*`、`src/units/*`、`src/modules/modules.alias`（原样拷贝进产物）。
  这条区别不用记：构建期门禁 `asciiGate`（`tools/build.lua`）会在每次构建末尾逐字节扫
  `dist/` 全部产物 + `manifest` + 每棵 `dist/release/*/` 发布树，有一处非 ASCII 就 fail-fast
  并报出 `文件:行号`（把中文写进上面那几处 = 当场挂构建）。
- README、for-ai.md、测试脚本（`tools/hosttest.lua`、`scripts/*.sh`）不装到 CC 上，随便用中文。
- git 提交使用本仓库 local config。

## 目录

```
src/kernel/version.lua     版本号唯一真源(`return "x.y.z"`, 同时是 /lib/modules/<version>/ 的目录名)
src/bios/startup.lua       Delin BIOS(装到电脑自身 FS 的 /startup.lua): 扫描设备的 /.boot -> loadfile
                           引导入口; DELETE 进设置 TUI, C 进 CraftOS shell
                           (版本号独立, 不与 src/kernel/version.lua 同步, 见"引导"一节)
src/kernel/scheduler.lua   协程调度器(事件循环) + resume 前信号投递
src/kernel/process.lua     进程表/进程树/spawn/隔离 env + cwd + argv + 会话/进程组/信号/作业控制
                            + 子进程退出钩子(init 服务监督) + opts.ppid
src/kernel/procenv.lua     进程环境白名单: 只把列出的 CC/Lua 全局给进程(无 __index=_G 兜底),
                           在内核层封掉 loadfile/dofile/os.run/require/settings/shell/disk/peripheral
                           /os.pullEvent/queueEvent/shutdown 等绕过 Delin 接口的渠道
src/kernel/signal.lua      POSIX 信号编号/默认动作/可捕获表/名字表
src/kernel/regex.lua       标准正则引擎(POSIX BRE/ERE; 最左最长 + 捕获组 + sed/ed 替换):
                           编译 -> 指令序列 -> Pike VM; 经 syscalls["regex.compile"] 给 /bin 工具
src/kernel/vfs.lua         虚拟文件系统: 挂载表 + resolve(路径规范化: 吃掉 "."/".." 并夹在根上)
                            + real/virtual 后端
src/kernel/vfs_api.lua     VFS 门面(fs/io) + /dev 设备注册表 + stdio
src/kernel/klog.lua        内核日志: ring buffer + /dev/kmsg(带 cursor/seek) + /dev/log + syslog 优先级名表
src/kernel/fstab.lua       /etc/fstab 解析(fstab(5) 子集) + systemd 风格 mount 单元命名
src/kernel/modules.lua     内核模块系统: .ko 解析(注释头)/依赖拓扑/装载/alias(use) + fstype 注册
src/kernel/blockdev.lua    块设备层: 文件块设备(/parts/*.img, seek+read/write)
src/kernel/platform.lua    平台层: CC / CEE:CC(CEECC) 探测 + 引脚快照 + 引脚上的磁盘驱动器(见"CEE:CC 平台")
src/kernel/devdisk.lua     存储设备抽象: 电脑自带存储/CC 磁盘/引脚驱动器 -> /dev/sdX 节点 + UUID(d<磁盘ID>/c<电脑ID>)
                           + fstype 挂载/卸载 + mkfs/fsck 的入口(目标解析/拒绝挂载中的文件系统)
src/kernel/ext2.lua        EXT2 读写: 超级块/inode(uid/gid/mode/硬链接/符号链接)/间接块/多块组
                           + mkfs(可调块大小/inode 数/保留块/卷标, 单块组) + fsck(五趟检查与修复)
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
src/bin/cat                连接文件到 stdout (默认按字节拷贝, 行选项/终端下按行; ^C -> 130)
src/bin/ls                 列目录
src/bin/mkdir              建目录 (-p 递归建父)
src/bin/mkfs.ext2          建 ext2 文件系统 (mke2fs 子集: -b/-N/-L/-m/-n/-q/-F/-v; 内核 ext2.mkfs)
src/bin/fsck.ext2          检查/修复 ext2 (e2fsck 子集: -a/-p/-n/-y/-f/-v; 内核 ext2.fsck)
src/bin/rm                 删文件/目录 (-r|-R 递归, -f 忽略不存在)
src/bin/cp                 复制文件/目录(-r 递归)
src/bin/mv                 移动/重命名(复制后删源)
src/bin/touch              创建空文件
src/bin/head               打印前 N 行 (-n N|-N)
src/bin/tail               打印后 N 行 (-n N|-N)
src/bin/wc                 统计行/词/字节 (-l|-w|-c)
src/bin/grep               按标准正则查找行 (默认 BRE; -E/-G/-F 切方言; -n -i -v -w -x -c -l -q -o -r -s;
                           退出码 0 选中 / 1 没选中 / 2 出错)
src/bin/sed                流式文本编辑器 (GNU 子集: s/y/d/p/q/a/i/c/=, 地址区间, -n -s -e -f -i)
src/bin/ed                 行编辑器 (POSIX 子集: a/i/c/d/p/n/l/s/t/m/r/w/q/u/g/v/=, 正则地址与替换, 交互逐行读)
src/bin/kill               发送信号到进程/进程组 (kill [-SIG] pid|-pgid; kill -l)
src/bin/ps                 报告进程状态, 数据源 /proc (POSIX ps + procps/GNU/BSD 常用子集:
                           默认/-e/-A/-a/-x/-f/-l/u(aux)/-p/-t/-u/-o/--no-headers; 无 TIME/%CPU/%MEM 列)
src/bin/pgrep              按进程名/命令行查找进程 (procps pgrep 子集: -f -x -v -l -a -n -o -u; ERE)
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
src/modules/cee.ko         CEECC 平台驱动: /sys/class/power/supply(电力) + /sys/class/pin/pinN(引脚与端口)
src/modules/manifest       默认装载模块清单: ext2 ccdisk redstone cee
scripts/posix_test.sh      可移植 POSIX 自检(host 与 Delin 各跑一次比对, 128 项全过; 含 cat 字节保真)
scripts/sh_expand_test.sh  sh 展开自检(通配符 * ? [ ]/命令替换 $( ) 与反引号/算术 $(( ));
                           host harness 与真机各跑一次比对, 期望值逐条对过 bash/dash;
                           含"存在 bin/ls 时 bin/ls* 必须匹配到它"的前缀匹配回归用例")
scripts/regex_test.sh      标准正则自检(grep 方言 -E/-G/-F 与退出码 0/1/2、最左最长、-o/-w/-x/-i、
                           POSIX 字符类、sed 的 BRE/ERE 与 s///N、ed/expr/csplit) —— 同一份脚本
                           在宿主(期望值由宿主 GNU 校验)、harness 与真机各跑一次
scripts/jobctl_test.sh     作业控制自检(& / $! / jobs / fg / bg / wait / kill %job, host 与真机各跑一次)
scripts/sysinfo.sh         实用小工具: 系统信息(变量/函数/for/case/if/重定向/工具)
scripts/proc_test.sh       /proc + ps/pgrep/pkill/killall 自检(host harness 与真机各跑一次比对, 41 项)
scripts/user_test.sh       用户管理自检(host harness 与真机各跑一次比对, 125 项): 改密码+内核 verify 判定/
                           建删用户与组/改名/锁定/家目录/非 root 一律被拒(靠 user_helper.lua 用 spawn 起
                           uid 1000 的进程 —— 没有 su/setuid, 这是唯一能拿到非 root 进程的办法)
scripts/user_helper.lua    上面那份自检的辅助程序: spawn <uid> <tool> ...(起完打印 pid, 由 shell 等)与
                           verify <name> <pw>(直接问内核 user.verify)
scripts/redstone_test.sh   /sys/class/redstone 读写/校验自检(host harness 与真机各跑一次比对, 75 项)
scripts/lua_test.sh        /bin/lua 自检(host harness 与真机各跑一次比对, 107 项): 脚本/stdin/arg/变参/
                           dofile+loadfile/错误消息与退出码/shebang/进程环境白名单
scripts/lua_repl_test.sh   /bin/lua 交互式 REPL 自检(宿主专用: 测试台把 stdin 伪装成终端,
                           覆盖提示符/表达式自动打印/续行/报错/SIGINT/_PROMPT/EOF 退出码, 16 项)
scripts/redstone_verify.lua  真机交叉核对: /sys/class/redstone/* 与 CC 原始 redstone API 逐项一致
                           (写 /var/log/redstone_verify.log; 由 realmachine_verify.sh 调用)
scripts/realmachine_verify.sh  真机验证脚本(由 verify.service 以 oneshot 运行, 结果写 /var/log/verify.log)
scripts/md_verify.sh        软RAID 真机验证(sh, 由 mdtest.service 以 oneshot 运行, 结果写 /var/log/md.log):
                           阶段一建 raid5+raid1 -> mkfs.ext2 -> 挂载写文件 -> --fail/--remove ->
                           降级读 -> --add 新盘 -> --wait 等重建 -> --stop/--assemble -> 写 /etc/mdadm.conf
                           并停掉阵列; 阶段二(重启后)断言阵列在启动时就已组装好且数据仍在。
                           注意 Delin 的 sh **没有 `2>&1`**(语法错误), 且 stderr 与 stdout 是同一个流
scripts/ceecc_verify.lua       CEECC 真机自检(单进程 Lua, 由 ceecc.service 运行, 结果写 /var/log/ceecc.log)
                           含 mkfs.ext2/fsck.ext2 段: 在电脑自带存储的 CC-fs 上现造 /parts/manifest +
                           /parts/scratch.img, 现场 mkfs -> 挂载写文件 -> fsck 判干净 -> 破坏块位图 ->
                           -n 报出(4) -> -y 修好(1) -> 再查干净(0); 镜像随后由宿主 e2fsck 复判
scripts/ext2_corrupt.lua   真机"造损坏"小工具: 把设备/镜像从 offset 起的若干字节清零
                           (/dev/sdXN 的字节句柄没有 seek, dd seek= 报 cannot seek, 故整体读出再写回)
scripts/posix_tools_verify.sh  真机 POSIX 工具自检(由 posix-verify.service 运行, 写 /var/log/posix_verify.log;
                           工具这一层用 sh, 需要直接看内核句柄/管道的用 /bin/lua)
scripts/posix_kernel_verify.lua  真机: 符号链接/硬链接/FIFO/umask/seek 的内核语义(上面那份用 /bin/lua 调)
scripts/tee_verify.lua     真机: tee 的 stdout 契约 —— stdout 是终端句柄(用光标位置观测)/管道/文件时
                           stdin 都必须真的写出去; 带"点号调用光标一动不动"的控制组(见 for-ai 的设计要点)
scripts/printer_probe.lua  真机探测 CC printer 原始 API 语义(页尺寸/写不折行/开页扣纸墨), 写 /var/log/printer_probe.log
scripts/printer_verify.sh  真机验证 ccprinter 模块(/dev/lp0 + /sys/class/printer, 会实际打印), 写 /var/log/printer_verify.log
tools/bundle.lua           拼装 bundle: src/ -> 单文件内核/DLUB(init 多文件拼成一个 chunk);
                           压缩与门禁交给 tools/build.lua, 本文件只负责"拼"
tools/build.lua            构建入口: 自动建 dist/, 产出压缩后的内核/DLUB/BIOS/工具/模块/配置
                           + manifest(size/crc32); --check 跑压缩等价性门禁, --release 出发布树
tools/crc32.lua            CRC32(纯 Lua, 不用位运算: 宿主 5.1 与 CC 5.2 必须算出同一个值)
tools/installer.lua        游戏内安装器(CraftOS 程序): 多步交互式向导(箭头选/回车确认/
                           Backspace 上一步, 文本输入里行首退格 = 上一步) + http 下载 + CRC32 校验
                           + 现场 mkfs 写 ext2 镜像 + 向导全程写 /delin-install.log;
                           被 bundle 成单文件 dist/install.lua
scripts/installer_interactive_test.lua  真机: 注入 key/char 事件驱动交互式向导(配合
                           /installer-test.plan 计划文件), 结果写 /installer-test.log
scripts/installer_plan_ext2.plan / scripts/installer_plan_ccfs.plan  上面那份交互计划的现成例子
                           (EXT2→电脑自身存储 手输 512 KB / CCFS→电脑自身存储; 两轮都以
                           `key enter` 收尾 = 装完回车重启进 Delin)
tools/serve.sh             开发期(本地)把 dist/release 挂在 10568 端口; 正式安装源是 GitHub 上的
                           release 分支(见"构建"一节)
.github/workflows/release.yml  打 v* tag -> 门禁(build --check --release + installertest)
                           -> 把 dist/release/<版本>/ 推成 release 分支的 <版本>/ 目录
                           (发布树要能被 CraftOS 按目录结构 http 取, 所以用分支而不是 Release assets:
                            Release 的附件是平铺的, 放不下 payload/ 子路径)。
                           切到 release 分支**要 `git clean -fdx`**: `.gitignore` 只在 main 上被跟踪,
                           切过去它随源文件一起消失, dist/ 这类"本来被忽略的未跟踪文件"就失去保护,
                           会被 `git add -A` 整棵收进发布分支(v0.0.2 第一次跑真中过, 混进 213 个文件)。
tools/minify.lua           Lua 压缩器: 词法分析 + 递归下降解析做作用域分析 + 局部变量改名,
                           只从 token 流输出(输出与输入的 token 序列逐项相同)。三重门禁:
                           lua5.1 解析 / 重词法逐 token 比对 / 改名不遮蔽任何全局名。
                           实测 634,040 -> 296,863 字节(-53%)
tools/harness.lua          host 测试台: 用真实 Delin 工具源码在宿主跑(fs/io/syscalls/spawn 桩,
                           含信号/进程组语义: kill/killpg/SIGCONT/stopped, 供 sh 作业控制验证;
                           /sys 与 /proc 走真实 kernel.sysfs/kernel.procfs 后端 + 桩显示设备
                           + 桩 printer(/dev/lp0) + 桩 redstone API(加载真实 redstone.ko)
                           + 桩进程表(ps/pgrep/pkill/killall);
                           进程环境用内核同一份白名单(src/kernel/procenv.lua), 不放宽;
                           fs.list 必须与 CC 同语义: 路径不存在/不是目录 -> **空表**
                           (`ls -A <文件>` 会把文件路径自己打印出来, 直接照搬会让宿主上的
                           fs.list(file) 返回一条路径 —— 工具的"列目录失败"分支在宿主上永远
                           走不到, 真机才炸)
                           DELIN_HARNESS_TTY=1 时把 stdin 伪装成终端(isTTY + getDeviceName),
                           输入里以 `\3` 结尾的一行 = "用户打了一半按了 ^C": 行规程丢掉该行、
                           读返回空行, 同时把 SIGINT 投给顶层那条进程组(与真机 tty.ctrlC 的两件事
                           一一对应) —— 少了投信号那一半, 提示符处 ^C 的 bug 在宿主上复现不出来
tools/hosttest.lua         宿主测试: init 单元引擎/fstab 生成/syslogd 规则/logrotate 轮转/systemctl/sysfs/ccprinter/procfs/tty-ANSI/redstone/devdisk/mkfs.ext2+fsck.ext2(680 项)
tools/installertest.lua    安装器宿主回归: 假 CraftOS(fs/term/os/http/disk/peripheral + 脚本化事件队列)
                           + 假终端格子(含 fg/bg), 用 loadfile 跑 dist/install.lua, 按键序列驱动向导
                           并断言落盘文件/镜像/日志; 失败时 dump 每一屏(含反色行标记)
tools/ext2test.lua         宿主 ext2 回归: 真实镜像上跑目录增删(空洞/links/回收) + mkfs 各参数组合
                           + fsck 的十种损坏/修复用例, 裁判一律是宿主 e2fsck -fn(235 项)
tools/deploy.py            重建干净 ext2 根镜像(基镜像+内核/bin/单元/配置/标记), 属主按基镜像逐条写回;
                           基镜像损坏/rdump 漏文件/构建后 fsck 不过一律 fail-fast
tools/mdtest.lua          软RAID 宿主回归: 五个级别 + 非默认布局的读写往返, 测试自带的**独立布局模型**
                           与**独立 GF(2^8) 乘法**逐块核对成员镜像, 降级/重建/组装/拒绝规则,
                           最后把 mkfs.ext2 造在阵列上的 ext2 抽成普通镜像交给宿主 e2fsck 判(128 项)
tools/md_realmachine.py    软RAID 真机流程(电脑 #6, 两阶段): 干净 CCFS 安装 + 注入 md_verify.sh 与
                           mdtest.service -> 第一次开机跑完整生命周期并写 /etc/mdadm.conf ->
                           重启 -> 断言阵列在启动时就已被 mdadm.service 组装好、数据仍在
tools/ceecc_realmachine.py CEECC(电脑 #6)真机流程: 先关机->打包->CCFS 根安装+注入 ceecc.service->开机->逐项断言
tools/realmachine.py       真机流程: 先关机->打包->部署->注入第二分区与 verify.service->fsck 门禁->
                           写磁盘 CC-fs 引导配置(/.boot + /dlub.cfg)->装盘并 md5 校验->开机->
                           引导门禁(verify.log 必须是本轮写的)->debugfs 取回日志->停机后再 fsck
                           (--printer 额外注入打印机探测/验证服务)
                           还注入 scripts/intr_test.ko(交互式 ^C 载荷, 只进测试镜像): 停机后从镜像
                           判定三份证据 —— /tmp/intr.before(正对照: 注入器真在提示符上执行了命令)、
                           /tmp/intr.notrun 必须**不存在**(负对照: 打了一半的行真被 ^C 取消了)、
                           /tmp/intr.after(回归: ^C 之后的第一条命令必须真的执行)
dist/                      生成物(不提交)
```
