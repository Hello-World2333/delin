#!/usr/bin/env python3
"""Delin 真机验证(电脑 3 + 磁盘 0)。

做五件事:
  0. **先关机** —— 读基镜像(/parts/root.img)与写盘都必须在电脑停机后进行。原来先覆盖
     root.img、之后才 shutdown: 机器还在跑 ext2 测试并写这张盘, 两边对同一文件的写入交错,
     盘上的 root.img 会变成"新镜像数据块 + 旧镜像 inode 表"的混合体(历史事故: /lib、/home
     整个目录读不出来)。
  1. 重新打包内核 bundle(dist/kernel.lua)
  2. 用 tools/deploy.py 重建干净的 ext2 根镜像(基础镜像 -> 新镜像; 属主以基镜像为准)
  3. 往镜像/磁盘里注入验证负载: 第二个 ext2 分区(/parts/data.img, 供 fstab 测试)、
     /etc/fstab 测试条目、verify.service + /root/verify.sh(systemd-like init 的自检服务);
     注入后跑 e2fsck -fn 门禁, 安装到磁盘后逐文件按 md5 校验
  4. 开机、等待启动, 用 debugfs 从 root.img 里取回 /var/log/*.log 打印出来; 再次停机后
     对安装到磁盘的 root.img 跑一次只读 fsck, 报告是否被跑坏

用法: python3 tools/realmachine.py [--base /mnt/disk/0/parts/root.img] [--no-reboot] [--reboot-only]

注意: 本环境里电脑自身 FS 的文件(/.boot、/main.lua)在宿主机改写后, 游戏侧似乎仍读旧内容
(磁盘镜像 /mnt/disk/0/parts/*.img 的改写则立即生效, 已验证), 因此第 3d 步写 DLUB 到 /main.lua
只对全新电脑有意义; CC-fs 引导路径无法在此环境用真机验证(由 tools/hosttest.lua 的 init 端到端
用例覆盖)。
"""
import hashlib, os, re, shutil, subprocess, sys, time

REPO = "/home/worker/delin"
DBG = "/usr/sbin/debugfs"
MKFS = "/usr/sbin/mkfs.ext2"
FSCK = "/usr/sbin/e2fsck"
DISK = "/mnt/disk/0"
COMPUTER = "/mnt/computer/3"
COMPUTER4 = "/mnt/computer/4"
RCON = "/home/worker/docs/tools/rcon.py"
WAIT = 75
WORK = "/tmp/delin-rm"

def run(*a, check=True, cwd=None):
    p = subprocess.run(a, capture_output=True, text=True, cwd=cwd)
    if check and p.returncode != 0:
        raise RuntimeError("cmd failed: %s\n%s\n%s" % (" ".join(a), p.stdout, p.stderr))
    return p.stdout + p.stderr

def df(img, cmd, check=False):
    return run(DBG, "-w", "-R", cmd, img, check=check)

def df_write(img, host_path, img_path):
    # debugfs 的 write 不覆盖已存在的文件(只打印 "Ext2 file already exists" 且返回 0),
    # 所以先删目标再写; 写完检查输出, 别把"没写进去"当成成功。
    df(img, "rm %s" % img_path)
    out = df(img, "write %s %s" % (host_path, img_path), check=True)
    low = out.lower()
    if "already exists" in low or "corrupted" in low or "not found" in low or "error" in low:
        raise RuntimeError("debugfs write failed: %s -> %s\n%s" % (host_path, img_path, out))

def df_mkdir(img, path):
    # debugfs 对**已存在**的目录 mkdir 会先分配 inode 再失败, 留下 "Unconnected directory
    # inode", 而它占的块在位图里又被标回空闲(会和后续文件重复分配) —— 所以先探测再建。
    out = df(img, "stat %s" % path)
    if "Inode:" in out:
        return
    df(img, "mkdir %s" % path, check=True)

def computer_on():
    out = run("python3", RCON, "computercraft dump #3", check=False)
    for line in out.splitlines():
        if line.strip().startswith("On"):
            parts = line.split("|")
            if len(parts) >= 2:
                return parts[1].strip().upper().startswith("Y")
    return None

def shutdown_computer(timeout=90):
    """读基镜像 / 写磁盘镜像之前必须让电脑停下来(见模块开头的历史事故)。"""
    print("== shutdown computer #3 (读写磁盘镜像必须在停机状态下进行) ==")
    run("python3", RCON, "computercraft shutdown #3", check=False)
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(2)
        if computer_on() is False:
            time.sleep(3)   # 再等一拍, 让游戏侧把磁盘缓存落盘
            print("   computer #3 is off")
            return
    raise RuntimeError("computer #3 在 %ds 内没有关机; 拒绝在机器运行时读写磁盘镜像" % timeout)

def install_verified(src, dst):
    """复制到游戏侧路径后按内容校验: 不一致说明还有别的写入者在动这个文件。"""
    shutil.copy(src, dst)
    with open(src, "rb") as f: a = hashlib.md5(f.read()).hexdigest()
    with open(dst, "rb") as f: b = hashlib.md5(f.read()).hexdigest()
    if a != b:
        raise RuntimeError("安装校验失败: %s 与 %s 内容不一致(%s != %s); 有别的写入者在改它" % (dst, src, b, a))
    print("   installed %-30s md5=%s" % (os.path.basename(dst), a))

def payload_fingerprint():
    """payload 指纹: dist/ 产物 + 要注入的 scripts/ 内容哈希(只看内容, 不看时间戳)。"""
    h = hashlib.sha256()
    # 本文件也进指纹: 改**注入清单**(往镜像里铺哪些文件)同样会让旧镜像失效 ——
    # 只看 dist/ 与 scripts/ 的话, 加了新 payload 却指纹没变, 会静默复用上一轮的镜像
    # (本轮踩过: newtools_test.sh 加进清单后跑出来仍是 "not deployed")。
    try:
        with open(os.path.abspath(__file__), "rb") as f:
            h.update(f.read())
    except OSError:
        pass
    for root in (os.path.join(REPO, "dist"), os.path.join(REPO, "scripts")):
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames.sort()
            for name in sorted(filenames):
                fp = os.path.join(dirpath, name)
                h.update(os.path.relpath(fp, REPO).encode())
                try:
                    with open(fp, "rb") as f:
                        h.update(f.read())
                except OSError:
                    pass
    return h.hexdigest()


def main():
    """真机验证主流程。

    速度开关(测试流程本身的开销)：
      * payload 指纹命中时**复用**上一轮注入好的镜像(省掉 deploy + 40 来次 debugfs 注入);
        指纹 = dist/ 全部产物 + scripts/ 内容的哈希, 只要动过一个字节就自动重建;
      * 引导等待是**条件轮询**(/delin.log 出现 "init up" 且镜像里的 verify.log 变过),
        不是原来那 75+30 秒盲等;
      * `--rebuild` 强制重建镜像; `--reboot-only` 只重开机+收日志。
    """
    base = os.path.join(DISK, "parts/root.img")
    reboot = True
    skip_deploy = False
    printer = False
    probe_only = False
    force_rebuild = False
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == "--base":
            base = args.pop(0)
        elif a == "--no-reboot":
            reboot = False
        elif a == "--reboot-only":
            skip_deploy = True
        elif a == "--rebuild":
            force_rebuild = True
        elif a == "--printer":
            printer = True
        elif a == "--printer-probe":
            printer, probe_only = True, True
        else:
            raise SystemExit("unknown arg: " + a)

    if skip_deploy:
        print("--reboot-only: skipping build/deploy")
        reboot_and_collect(printer)
        return

    # 0) 先关机: 下面读基镜像(live /parts/root.img)和写盘都必须在一台停机的机器上进行
    shutdown_computer()

    # 1) 打包
    print("== build kernel bundle ==")
    # 构建 dist/: 压缩内核/DLUB/工具/模块, 并生成产物清单(压缩器门禁在 build.lua 内部)
    print(run("lua5.1", os.path.join(REPO, "tools/build.lua"), cwd=REPO))

    # 1b) 宿主 ext2 回归(秒级): 驱动层的目录/links 问题先在这里挡住, 别拿真机试
    print("== host ext2 regression ==")
    print(run("lua5.1", os.path.join(REPO, "tools/ext2test.lua"), cwd=REPO))

    # 2) 部署根镜像到 /tmp, 成功后原子替换
    # payload 指纹没变就复用上一轮注入好的镜像: deploy(拷基镜像+铺文件) 与 40 来次 debugfs
    # 注入在迭代工具选项时要几十秒, 而 payload 里往往只变了一个 dist/bin/<tool>。
    # 指纹一变(reused=False)就整段重做, 不会测到旧镜像。--rebuild 可强制重建。
    fp = payload_fingerprint()
    fp_path = os.path.join(WORK, 'payload.fingerprint')
    reused = (not force_rebuild) and os.path.exists(fp_path) and open(fp_path).read().strip() == fp and os.path.exists(os.path.join(WORK, 'root.img'))
    if reused:
        print('== reuse previously injected root.img (payload %s) ==' % fp[:12])
        out = os.path.join(WORK, 'root.img')
        data_img = os.path.join(WORK, 'data.img')
    else:
        work = WORK
        os.makedirs(work, exist_ok=True)
        out = os.path.join(work, "root.img")
        if os.path.exists(out):
            os.unlink(out)
        print("== deploy rootfs from %s ==" % base)
        print(run(sys.executable, os.path.join(REPO, "tools/deploy.py"), base, out, cwd=REPO))

        # 3) 注入验证负载
        print("== inject verify payload ==")
        # 3a) 第二个分区镜像(data), 里面放一个 hello 文件
        data_img = os.path.join(work, "data.img")
        if os.path.exists(data_img):
            os.unlink(data_img)
        run(MKFS, "-q", "-t", "ext2", "-b", "1024", data_img, "512")
        hello = os.path.join(work, "hello.txt")
        with open(hello, "w") as f:
            f.write("hello from the data partition (fstab)\n")
        df_write(data_img, hello, "/hello.txt")

        # 3b) 测试用 /etc/fstab(defaults + noauto 两条)
        fstab = os.path.join(work, "fstab")
        with open(fstab, "w") as f:
            # /dev/sda 恒为电脑自带存储, 引导盘是磁盘驱动器里的第一块盘(sdb, UUID d0)。
            # data 分区走 UUID(顺带验证 UUID 命名空间), rootcopy 走设备节点(验证 sdbN 命名)。
            f.write("# real-machine verify fstab\n"
                    "UUID=d0-2   /mnt/data     ext2   defaults   0 2\n"
                    "/dev/sdb1   /mnt/rootcopy ext2   noauto     0 2\n")
        df(out, "rm /etc/fstab")
        df_write(out, fstab, "/etc/fstab")

        # 3c) verify.service + /root/verify.sh
        sh = os.path.join(REPO, "scripts/realmachine_verify.sh")
        df_write(out, sh, "/root/verify.sh")
        df(out, "set_inode_field /root/verify.sh mode 0100755")
        unit = os.path.join(work, "verify.service")
        with open(unit, "w") as f:
            # TimeoutStartSec 必须给足: 自检脚本一轮要跑近百个进程, 实测已经在默认的 60s 附近
            # (Type=oneshot 在 systemd 里的默认本来就是 infinity; Delin 的引擎默认 60s)。
            # 超时会被 init SIGKILL 掉, 表现成"verify.log 变了但没跑完"——那是**假失败**,
            # 会让人以为是内核回归(本轮就误判过两轮)。
            f.write("[Unit]\nDescription=Real-machine verification\nAfter=syslogd.service\n\n"
                    "[Service]\nType=oneshot\nTimeoutStartSec=600\nExecStart=/bin/sh /root/verify.sh\n\n"
                    "[Install]\nWantedBy=multi-user.target\n")
        df_write(out, unit, "/lib/systemd/system/verify.service")
        df_mkdir(out, "/etc/systemd/system/multi-user.target.wants")
        marker = os.path.join(work, "marker")
        open(marker, "w").close()
        df_write(out, marker, "/etc/systemd/system/multi-user.target.wants/verify.service")
        df_mkdir(out, "/mnt/rootcopy")

        # 3e) verify-sh.service: sh 内建/变量自检(. set export unset PATH PSx cd) + desh 非交互自检
        #     -> /var/log/sh_verify.log
        for src, dst in (("scripts/sh_verify.sh", "/root/sh_verify.sh"),
                         ("scripts/sh_builtin_test.sh", "/root/sh_builtin_test.sh"),
                         ("scripts/sh_expand_test.sh", "/root/sh_expand_test.sh"),
                         # desh 与 sh 共用核心: 真机上确认"非交互路径起得来、行为一致"。
                         # 交互式那部分只有宿主能测(scripts/desh_tty_test.sh 用假终端喂按键字节)。
                         ("scripts/desh_test.sh", "/root/desh_test.sh"),
                         ("scripts/regex_test.sh", "/root/regex_test.sh"),
                         ("scripts/proc_test.sh", "/root/proc_test.sh"),
                         ("scripts/redstone_test.sh", "/root/redstone_test.sh"),
                         ("scripts/redstone_verify.lua", "/root/redstone_verify.lua"),
                         ("scripts/lua_test.sh", "/root/lua_test.sh"),
                         ("scripts/user_test.sh", "/root/user_test.sh"),
                         ("scripts/user_helper.lua", "/root/user_helper.lua")):
            df_write(out, os.path.join(REPO, src), dst)
            df(out, "set_inode_field %s mode 0100755" % dst)
        unit_sh = os.path.join(work, "verify-sh.service")
        with open(unit_sh, "w") as f:
            f.write("[Unit]\nDescription=Real-machine sh builtin verification\nAfter=syslogd.service\n\n"
                    "[Service]\nType=oneshot\nTimeoutStartSec=600\nExecStart=/bin/sh /root/sh_verify.sh\n\n"
                    "[Install]\nWantedBy=multi-user.target\n")
        df_write(out, unit_sh, "/lib/systemd/system/verify-sh.service")
        df_write(out, marker, "/etc/systemd/system/multi-user.target.wants/verify-sh.service")

        # 3f) --printer: ccprinter 模块端到端验证; --printer-probe 额外注入原始 printer API 探测。
        #     默认不注入: 它们会实际打印页面, 只在需要验证打印机时消耗纸张。
        #     先清掉上一次部署残留在基础镜像里的打印机负载 —— 否则残留的 .wants 标记会让
        #     探测/验证服务在之后每次启动时都跑一遍, 白白耗纸。
        for unit, path in (("printer-probe.service", "/root/printer_probe.lua"),
                           ("printer-verify.service", "/root/printer_verify.sh")):
            df(out, "rm /etc/systemd/system/multi-user.target.wants/" + unit, check=False)
            df(out, "rm /lib/systemd/system/" + unit, check=False)
            df(out, "rm " + path, check=False)

        if printer:
            if probe_only:
                probe = os.path.join(REPO, "scripts/printer_probe.lua")
                df_write(out, probe, "/root/printer_probe.lua")
                df(out, "set_inode_field /root/printer_probe.lua mode 0100755")
                unit_p = os.path.join(work, "printer-probe.service")
                with open(unit_p, "w") as f:
                    f.write("[Unit]\nDescription=CC printer raw API probe\nAfter=syslogd.service\n\n"
                            "[Service]\nType=oneshot\nExecStart=/root/printer_probe.lua\n\n"
                            "[Install]\nWantedBy=multi-user.target\n")
                df_write(out, unit_p, "/lib/systemd/system/printer-probe.service")
                df_write(out, marker, "/etc/systemd/system/multi-user.target.wants/printer-probe.service")

            pverify = os.path.join(REPO, "scripts/printer_verify.sh")
            if os.path.exists(pverify) and not probe_only:
                df_write(out, pverify, "/root/printer_verify.sh")
                df(out, "set_inode_field /root/printer_verify.sh mode 0100755")
                unit_pv = os.path.join(work, "printer-verify.service")
                with open(unit_pv, "w") as f:
                    f.write("[Unit]\nDescription=ccprinter module verification\nAfter=syslogd.service\n\n"
                            "[Service]\nType=oneshot\nExecStart=/bin/sh /root/printer_verify.sh\n\n"
                            "[Install]\nWantedBy=multi-user.target\n")
                df_write(out, unit_pv, "/lib/systemd/system/printer-verify.service")
                df_write(out, marker, "/etc/systemd/system/multi-user.target.wants/printer-verify.service")

        # 3f2) posix-verify.service: POSIX 命令补齐后的自检(新工具 + sh 新内建 + 内核新能力:
        #      符号链接/硬链接/命名管道/umask/seek) -> /var/log/posix_verify.log
        #      内核那部分用 /bin/lua 跑 —— 见 scripts/posix_kernel_verify.lua 的头注释: 这里要验的是
        #      **内核语义本身**, 不该依赖某个工具的包装(而且部分能力当时还没有命令行入口)。
        #      newtools_test.sh 是新命令批(awk/bc/分页器/date/...)的自检主体 —— 宿主与真机
        #      跑同一份(build.lua --check 里也跑), 由 posix_tools_verify.sh 调它。
        for src, dst in (("scripts/posix_tools_verify.sh", "/root/posix_tools_verify.sh"),
                         ("scripts/newtools_test.sh", "/root/newtools_test.sh"),
                         ("scripts/posix_kernel_verify.lua", "/root/posix_kernel_verify.lua"),
                         ("scripts/tee_verify.lua", "/root/tee_verify.lua")):
            df_write(out, os.path.join(REPO, src), dst)
            df(out, "set_inode_field %s mode 0100755" % dst)
        unit_posix = os.path.join(work, "posix-verify.service")
        with open(unit_posix, "w") as f:
            f.write("[Unit]\nDescription=Real-machine POSIX tools verification\nAfter=syslogd.service\n\n"
                    "[Service]\nType=oneshot\nTimeoutStartSec=600\nExecStart=/bin/sh /root/posix_tools_verify.sh\n\n"
                    "[Install]\nWantedBy=multi-user.target\n")
        df_write(out, unit_posix, "/lib/systemd/system/posix-verify.service")
        df_write(out, marker, "/etc/systemd/system/multi-user.target.wants/posix-verify.service")

        # 3f3) mkfs.ext2/fsck.ext2 真机验证要用的"造损坏"小工具(见 scripts/ext2_corrupt.lua 的头注释:
        #      /dev/sdXN 的字节句柄没有 seek, dd seek= 在这种设备上明确报 cannot seek)。
        df_write(out, os.path.join(REPO, "scripts/ext2_corrupt.lua"), "/root/ext2_corrupt.lua")
        df(out, "set_inode_field /root/ext2_corrupt.lua mode 0100755")

        # 3f4) 交互式 "提示符处 ^C" 载荷(scripts/intr_test.ko, 见它的头注释): 真机上只有内核态
        #      能驱动行规程(进程连 os.queueEvent 都被 procenv 禁掉), 所以按键注入做成一个内核
        #      模块 —— 它在调度器起来之前包住 os.pullEventRaw, 再用 tty.routeKey/tty.feedInput
        #      喂按键(走 CC 事件队列的按键会被别的进程 os.sleep 里的过滤拉取吃掉, 实测过)。
        #      模块由 /lib/modules/<版本>/manifest 点名装载, 所以 .ko 与 manifest 两样都要铺。
        ver = re.search(r'^\s*return\s+"([^"]+)"', open(os.path.join(REPO, "src/kernel/version.lua")).read(), re.M).group(1)
        moddir = "/lib/modules/" + ver
        df_write(out, os.path.join(REPO, "scripts/intr_test.ko"), moddir + "/intrtest.ko")
        cur_manifest = subprocess.run([DBG, "-R", "cat " + moddir + "/manifest", out],
                                      capture_output=True, text=True).stdout
        if "intrtest" not in cur_manifest.split():
            mfile = os.path.join(work, "module-manifest")
            with open(mfile, "w") as f:
                f.write(cur_manifest.strip("\n") + "\nintrtest\n")
            df_write(out, mfile, moddir + "/manifest")

        # 3f5) tty 原始模式自检(scripts/rawtty_test.ko + scripts/rawtty_verify.lua):
        #      分页器 more/less 建在"原始模式 + 终端字节流"这条契约上, 而键盘事件只有内核态
        #      能注入 —— 模块喂按键, Lua 脚本在 /dev/tty0 上 setRaw 并读回字节。
        df_write(out, os.path.join(REPO, "scripts/rawtty_verify.lua"), "/root/rawtty_verify.lua")
        df(out, "set_inode_field /root/rawtty_verify.lua mode 0100755")
        unit_raw = os.path.join(work, "rawtty-verify.service")
        with open(unit_raw, "w") as f:
            f.write("[Unit]\nDescription=Real-machine tty raw mode verification\n"
                    "After=syslogd.service\n\n"
                    "[Service]\nType=oneshot\nTimeoutStartSec=120\n"
                    "ExecStart=/bin/lua /root/rawtty_verify.lua\n\n"
                    "[Install]\nWantedBy=multi-user.target\n")
        df_write(out, unit_raw, "/lib/systemd/system/rawtty-verify.service")
        df_write(out, marker, "/etc/systemd/system/multi-user.target.wants/rawtty-verify.service")
        df_write(out, os.path.join(REPO, "scripts/rawtty_test.ko"), moddir + "/rawtty.ko")
        if "rawtty" not in cur_manifest.split():
            mfile = os.path.join(work, "module-manifest")
            with open(mfile, "w") as f:
                f.write(cur_manifest.strip("\n") + "\nrawtty\n")
            df_write(out, mfile, moddir + "/manifest")

        # 3g) 门禁: 注入后镜像仍必须干净, 不把坏镜像带上真机
        p = subprocess.run([FSCK, "-fn", out], capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError("注入后的镜像未通过 e2fsck -fn:\n" + p.stdout + p.stderr)
        open(fp_path, 'w').write(fp)

    # 3d) 安装到磁盘(逐文件按内容校验; 机器此时已停机)
    install_verified(out, os.path.join(DISK, "parts/root.img"))
    install_verified(data_img, os.path.join(DISK, "parts/data.img"))
    manifest = "root /parts/root.img ext2\ndata /parts/data.img ext2\nboot /boot/delin.lua\n"
    mpath = os.path.join(DISK, "parts/manifest")
    with open(mpath, "w") as f:
        f.write(manifest)
    with open(mpath, "r") as f:
        if f.read() != manifest:
            raise RuntimeError("manifest 写入校验失败: %s" % mpath)
    install_verified(os.path.join(REPO, "dist/kernel.lua"), os.path.join(DISK, "boot/delin.lua"))
    install_verified(os.path.join(REPO, "dist/dlub.lua"), os.path.join(DISK, "boot/dlub.lua"))
    # 3d2) 引导配置: 磁盘 CC-fs 与电脑自身 FS 各放一对 —— BIOS 扫到哪个设备, DLUB 都能挂到**同一个**
    #      ext2 根(电脑自身 FS: /.boot -> /main.lua(DLUB) + /dlub.cfg 指向磁盘; 磁盘: /.boot ->
    #      /boot/dlub.lua + 该盘自己的 /dlub.cfg)。
    #      缺 /.boot 的设备不算可引导设备, 缺 /dlub.cfg 则 DLUB 直接报错、BIOS 回退去引导电脑自带存储
    #      上的旧安装 —— 结果是"机器起来了但跑的是旧系统", 本脚本还会拿着一份**上一轮**的
    #      /var/log/verify.log 报成功(踩过)。实测本环境里磁盘 CC-fs 上**新增**的文件游戏侧可能读不到,
    #      而电脑自身 FS 的改动是生效的, 所以两处都写, 并在取日志时做引导门禁(见下文 boot_guard)。
    for base, pairs in ((DISK, ((".boot", "/boot/dlub.lua"), ("dlub.cfg", "bootdisk left\n"))),
                        (COMPUTER, ((".boot", "/main.lua"), ("dlub.cfg", "bootdisk left\n")))):
        for name, text in pairs:
            p = os.path.join(base, name)
            with open(p, "w") as f:
                f.write(text)
            with open(p, "r") as f:
                if f.read() != text:
                    raise RuntimeError("%s 写入校验失败: %s" % (name, p))
            print("   boot config: %s = %r" % (p, text.strip()))
    # 电脑自身 FS 放 DLUB 装载器(由上面的 /.boot 指向)。
    mainlua = os.path.join(COMPUTER, "main.lua")
    if os.path.exists(mainlua):
        shutil.copy(mainlua, mainlua + ".bak")
    shutil.copy(os.path.join(REPO, "dist/dlub.lua"), mainlua)
    with open(mainlua, "rb") as f: got = hashlib.md5(f.read()).hexdigest()
    with open(os.path.join(REPO, "dist/dlub.lua"), "rb") as f: want = hashlib.md5(f.read()).hexdigest()
    if got != want:
        print("   WARNING: %s 读回内容与 dist/dlub.lua 不一致(本环境电脑自身 FS 改写可能不生效)" % mainlua)
    print("installed root.img/data.img/manifest/kernel + DLUB -> %s/main.lua" % COMPUTER)

    # 3h) 部署到电脑4 (rootfs 模式)
    print("== deploy to computer 4 ==")
    # 创建 /dlub.cfg
    os.makedirs(COMPUTER4, exist_ok=True)
    dlub_cfg = os.path.join(COMPUTER4, "dlub.cfg")
    with open(dlub_cfg, "w") as f:
        f.write("rootfs /parts/root.img\n")
    print("   created %s with rootfs=/parts/root.img" % dlub_cfg)
    
    # 安装 DLUB 到电脑4的 /main.lua
    mainlua4 = os.path.join(COMPUTER4, "main.lua")
    shutil.copy(os.path.join(REPO, "dist/dlub.lua"), mainlua4)
    print("   installed dlub.lua -> %s" % mainlua4)
    
    # 安装内核到电脑4的 /boot/
    bootdir4 = os.path.join(COMPUTER4, "boot")
    os.makedirs(bootdir4, exist_ok=True)
    shutil.copy(os.path.join(REPO, "dist/kernel.lua"), os.path.join(bootdir4, "delin.lua"))
    print("   installed kernel.lua -> %s/delin.lua" % bootdir4)
    
    # 安装根镜像到电脑4
    rootfs_path = "/parts/root.img"
    dst_path = os.path.join(COMPUTER4, "parts/root.img")
    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    shutil.copy(out, dst_path)
    print("   installed root.img -> %s" % dst_path)

    if not reboot:
        print("--no-reboot: stopping here (computer #3 已关机)")
        return
    reboot_and_collect(printer)


def reboot_and_collect(printer=False):
    # 引导指纹: 开机前的 verify.log, 开机后必须变 —— 否则说明这轮根本没从磁盘根启动
    verify_before = subprocess.run([DBG, "-R", "cat /var/log/verify.log", os.path.join(DISK, "parts/root.img")],
                                   capture_output=True, text=True).stdout

    # 4) 重启电脑 #3
    print("== reboot computer #3 ==")
    run("python3", RCON, "computercraft shutdown #3", check=False)
    time.sleep(2)
    run("python3", RCON, "computercraft turn-on #3", check=False)
    # 等**条件**而不是等固定秒数: 以前是 sleep(75)+sleep(30)=盲等 105s, 现在一看 /delin.log
    # 出现 "init up"、且镜像里的 verify.log 已经变过就往下走(正常 30-40s), 最长给 WAIT+30s。
    t0 = time.time()
    deadline = t0 + WAIT + 30
    next_note = 15
    while time.time() < deadline:
        time.sleep(3)
        # 判据只有一条: 镜像里的 /var/log/verify.log 变了(说明这一轮真的从磁盘根起来了,
        # 而且 verify.service 已经跑过)。**不要**去看 /mnt/disk/0/delin.log —— 那是 NFS
        # 看到的游戏侧文件, 实测开机后 100s 还是旧内容(知识库「电脑文件(NFS 挂载, 不稳定)」
        # 记着这条), 拿它当条件会一直等不到, 白等一整轮。
        cur = subprocess.run([DBG, "-R", "cat /var/log/verify.log", os.path.join(DISK, "parts/root.img")],
                             capture_output=True, text=True).stdout
        if cur != verify_before:
            print("   boot guard ready after %.0fs" % (time.time() - t0))
            break
        if time.time() - t0 >= next_note:
            next_note += 15
            print("   ... %.0fs: verify.log 还是上一轮的" % (time.time() - t0))
    else:
        print("   (%.0fs 内 verify.log 没变, 继续往下走看日志)" % (time.time() - t0))

    # 4b) 重启电脑 #4
    print("== reboot computer #4 ==")
    run("python3", RCON, "computercraft shutdown #4", check=False)
    time.sleep(2)
    run("python3", RCON, "computercraft turn-on #4", check=False)
    # 电脑 #4 只用来取它那份 /delin.log; NFS 内容不保证即时可见, 所以只等固定 15s
    print("waiting 15s for computer #4 ...")
    time.sleep(15)

    # 5) 取回日志
    print("== collect logs ==")
    print("\n===== 引导日志 =====")
    # 三段各有出处: 磁盘 CC-fs 上的 /delin.log 是 DLUB 写的; 根镜像里的 /delin.log 是内核写的
    # (ext2 根); 电脑自身 FS 的 /delin.log 只在这台机器**回退**去引导自带存储时才有意义。
    for label, path in (("disk ccfs", os.path.join(DISK, "delin.log")),
                        ("computer3 ccfs", os.path.join(COMPUTER, "delin.log")),
                        # 电脑 4 跑 rootfs 模式(根 = 电脑自带存储上的 /parts/root.img):
                        # 它的 /delin.log 是"自带存储被识别成 /dev/sda 与根分区对上节点"的直接证据。
                        ("computer4 ccfs (rootfs)", os.path.join(COMPUTER4, "delin.log"))):
        print("----- %s: %s -----" % (label, path))
        if os.path.exists(path):
            with open(path, "r", errors="replace") as f:
                print(f.read()[-4000:])
        else:
            print("(missing)")
    # 5a) 引导门禁: 磁盘根必须真的启动了。BIOS 只有扫不到磁盘 /.boot、或 DLUB 读不到该盘
    #     /dlub.cfg 时才会回退去引导电脑自身 FS —— 那种情况下这里读到的 verify.log 是**上一轮**的,
    #     会让"改了什么都没生效"看起来像全绿(踩过一次: 磁盘缺 /dlub.cfg, 机器回退到 CCFS 根)。
    # 轮询等待自检跑完: 固定 sleep 是不够的 —— 自检脚本随批次增多而变长(每加一条检查就是一次
    # 进程启动, 真机上很贵), 实测同一份代码会偶发卡在"日志变了但还没写完"上, 报成"失效验证"。
    # 判据仍然是"日志里出现 === verify done ===", 只是给它足够的时间(最多 6 分钟)。
    fresh = ""
    deadline = time.time() + 360
    last_change = time.time()
    prev = None
    while time.time() < deadline:
        fresh = subprocess.run([DBG, "-R", "cat /var/log/verify.log", os.path.join(DISK, "parts/root.img")],
                               capture_output=True, text=True).stdout
        if "=== verify done ===" in fresh:
            break
        if fresh != prev:
            prev = fresh
            last_change = time.time()
        elif fresh.strip() and time.time() - last_change > 60:
            # 日志已经有内容、却 60 秒不再增长 => 这个服务已经死了(真机上偶发: 它会在
            # mkfs/fsck 段中途停住)。别白等满 6 分钟 —— 立刻带着半截日志去报错,
            # 人一眼就能看出卡在哪一条。
            print("   (verify.log 60s 没有增长, 判定 verify.service 中途停了)")
            break
        time.sleep(5)
    if "=== verify done ===" not in fresh:
        print("   (自检在 6 分钟内没有写出 '=== verify done ===', 下面是当前内容)")
        print(fresh[-3000:])
    if fresh == verify_before:
        raise RuntimeError(
            "失效验证: 磁盘根没有启动 —— /var/log/verify.log 与部署时逐字节相同(本轮的 verify.service 没跑)。\n"
            "多半是 BIOS/DLUB 回退到电脑自身 FS 的旧安装了; 上面的 /delin.log 是那次引导的日志。")
    if "=== verify done ===" not in fresh:
        raise RuntimeError("失效验证: verify.log 变了但没有跑完(缺 '=== verify done ==='):\n" + fresh[-2000:])
    # 上面等的只是 realmachine_verify.sh(verify.log)。posix-verify.service 是**另一个**服务,
    # 它写 /var/log/posix_verify.log, 此刻可能还没跑完 —— 那样收上来的是半截日志(真机踩过:
    # 新增的检查项一个都没出现, 看起来像"改动没生效")。再等它的汇总行, 最多 5 分钟。
    p_deadline = time.time() + 300
    while time.time() < p_deadline:
        plog = subprocess.run([DBG, "-R", "cat /var/log/posix_verify.log",
                              os.path.join(DISK, "parts/root.img")],
                              capture_output=True, text=True).stdout
        if "== summary:" in plog:
            break
        time.sleep(10)
    else:
        print("   (posix_verify.log 5 分钟内没有写出 '== summary:', 可能还在跑)")
    print("   boot guard ok: 磁盘根已引导, verify.log 是本轮写的")

    # 5a2) cat 块设备 / dd 可中断: 这两条是本轮修的 bug, 单独设门禁(其余 ok/ng 行由人读日志)。
    #      cksum 口径: /dev/sdb2 = /parts/data.img, 本机只读不改写它, 因此宿主的 POSIX cksum
    #      必须与真机 `cat /dev/sdb2 | cksum` 的输出完全一致(即逐字节相同)。
    data_img_path = os.path.join(DISK, "parts/data.img")
    want = " ".join(run("cksum", data_img_path).split()[:2])  # "crc size /path" -> "crc size"
    m = re.search(r"^cat_dev2_cksum=(\d+ \d+)", fresh, re.M)
    got = m.group(1) if m else "(missing)"
    if got != want:
        raise RuntimeError("cat 块设备输出与宿主镜像不一致: 真机 %s, 宿主 %s (%s)"
                           % (got, want, data_img_path))
    print("   ok cat /dev/sdb2 == 宿主 %s (cksum %s)" % (data_img_path, got))
    for name in ("cat_blockdev_root_part", "cat_binary_exact", "dd_sigint_interrupt"):
        if ("ok " + name) not in fresh:
            raise RuntimeError("真机自检未通过: %s(verify.log 里没有 'ok %s')" % (name, name))
        print("   ok %s" % name)
    m = re.search(r"^dd_sigint_rc=(\d+)", fresh, re.M)
    if not m or m.group(1) != "130":
        raise RuntimeError("dd 被 SIGINT 中断后的退出码不是 130: %s"
                           % (m.group(1) if m else "(missing)"))
    print("   ok dd_sigint_rc=130")
    logs = ["/var/log/verify.log", "/var/log/sh_verify.log", "/var/log/posix_verify.log", "/var/log/messages", "/var/log/messages.1",
            "/var/log/secure", "/var/log/kern.log", "/var/log/redstone_verify.log", "/delin.log"]
    if printer:
        logs += ["/var/log/printer_probe.log", "/var/log/printer_verify.log"]
    for path in logs:
        dst = os.path.join(WORK, "dump-" + os.path.basename(path))
        if os.path.exists(dst):
            os.unlink(dst)
        run(DBG, "-R", "dump %s %s" % (path, dst), os.path.join(DISK, "parts/root.img"), check=False)
        print("\n===== %s =====" % path)
        if os.path.exists(dst):
            with open(dst, "r", errors="replace") as f:
                data = f.read()
            print(data[:12000] if data else "(empty)")
        else:
            print("(not found in image)")

    # 6) 停机后再对安装到磁盘的 root.img 做一次只读 fsck: 运行时读会得到撕裂的镜像。
    #    这是"Delin 自己写坏的"唯一权威判据, 有错就整体失败(exit != 0)。
    print("\n===== 停机后 fsck: /parts/root.img =====")
    shutdown_computer()

    # 6a) 交互式 "提示符处 ^C" 门禁(载荷 = /lib/modules/<版本>/intrtest.ko, 见其头注释)。
    #     机器已经停了, 从镜像里读三份证据, 缺一不可:
    #       /tmp/intr.before 正对照 —— 注入器真的在提示符上按计划驱动了 tty(没有它就说明
    #                        这轮根本没跑到那一步, "after 不存在"证明不了任何事);
    #       /tmp/intr.notrun 负对照 —— 打了一半的那行必须没被执行(^C 真的被行规程吃掉了),
    #                        否则"after 存在"可能只是 ^C 压根没生效;
    #       /tmp/intr.after  回归判据 —— ^C 之后的第一条命令必须真的执行(修复前它刚 spawn
    #                        就被残留的 SIGINT 杀掉, 这个文件不会出现)。
    img = os.path.join(DISK, "parts/root.img")
    def img_file(path):
        if "Inode:" not in df(img, "stat " + path):
            return None
        # debugfs 的 banner 会混进 stdout(同上面对 scratch 镜像的写法): 只取第一行内容。
        lines = df(img, "cat " + path).splitlines()
        return lines[0].strip() if lines else None
    print("\n===== 交互式 ^C 门禁(tty0 注入按键) =====")
    # 载荷的进度走 klog(内核 ring -> syslogd), 落在 /var/log/messages*; 它**不能**用 kprint
    # 打进度(那会同时画到控制台, 把会话搅乱, 见载荷头注释)。日志只作诊断打印 —— 一轮里
    # logrotate 随时可能把 messages 转成 messages.1, 拿它当门禁会变成"看运气"。
    for name in ("/var/log/messages", "/var/log/messages.1"):
        for line in df(img, "cat " + name).splitlines():
            if "[intrtest]" in line:
                print("   | " + line.strip())
    before = img_file("/tmp/intr.before")
    notrun = img_file("/tmp/intr.notrun")
    after = img_file("/tmp/intr.after")
    if before != "INTR-BEFORE":
        raise RuntimeError("交互式 ^C 正对照缺失: /tmp/intr.before=%r —— 注入器没能在提示符上执行命令"
                           "(见上面打印的 [intrtest] 进度)" % before)
    print("   ok positive control: /tmp/intr.before written")
    if notrun is not None:
        raise RuntimeError("交互式 ^C 负对照失败: /tmp/intr.notrun 存在 —— ^C 没有取消打了一半的那行")
    print("   ok negative control: the half-typed line was cancelled")
    if after != "INTR-AFTER":
        raise RuntimeError("交互式 ^C 门禁失败: /tmp/intr.after=%r —— ^C 之后的第一条命令没有执行"
                           "(残留的 SIGINT 把它杀了; 见 src/bin/sh 交互循环)" % after)
    print("   ok regression: the command right after ^C ran")

    # 6a2) tty **原始模式**门禁(载荷 = scripts/rawtty_test.ko + /root/rawtty_verify.lua):
    #      分页器 more/less 全靠这条契约(setRaw 之后 read(n) = 终端字节流, 特殊键是 ANSI 序列),
    #      而它只有真机的内核 tty 层能验。判据是 /tmp/rawtty.hex 逐字节等于期望序列:
    #        x | 空格 | ↑(1b 5b 41) | 7 | enter(只一次, 去重闩锁生效) | ^D(普通字节)
    print("\n===== tty 原始模式门禁(rawtty 注入按键) =====")
    for name in ("/var/log/rawtty_verify.log", "/var/log/messages", "/var/log/messages.1"):
        if "Inode:" not in df(img, "stat " + name):
            continue
        for line in df(img, "cat " + name).splitlines():
            if "rawtty" in line:
                print("   | " + line.strip())
    raw_hex = img_file("/tmp/rawtty.hex")
    want_hex = "78201b5b41370a04"
    if raw_hex != want_hex:
        raise RuntimeError("tty 原始模式门禁失败: /tmp/rawtty.hex=%r, 期望 %r"
                           "(见上面打印的 [rawtty] 进度; 元凶通常是 setRaw 的字节语义或按键映射)"
                           % (raw_hex, want_hex))
    print("   ok raw tty: setRaw + read(n) returned " + raw_hex)

    p = subprocess.run([FSCK, "-fn", os.path.join(DISK, "parts/root.img")], capture_output=True, text=True)
    out = (p.stdout + p.stderr).strip()
    print(out[-3000:] if out else "(no output)")
    print("e2fsck exit=%d" % p.returncode)
    if p.returncode != 0:
        raise RuntimeError("运行一轮后 root.img 不再 fsck 干净 —— Delin 把自己写坏了, 见上面输出")

    # 7) mkfs.ext2 / fsck.ext2: 真机在**电脑自带存储的 CC-fs** 上现场造了一个分区镜像
    #    (/parts/scratch.img, 见 verify.sh 的 mkfs 段): mkfs.ext2 格式化 -> 挂载写文件 ->
    #    fsck.ext2 判干净 -> 手工破坏块位图 -> -n 报出(4) -> -y 修好(1) -> 再查干净(0)。
    #    这里是权威裁判: 把那个镜像拿回宿主机用真实 e2fsck 判, 并且要求修复后数据还在。
    print("\n===== 真机 mkfs.ext2 造的镜像: 宿主 e2fsck -fn =====")
    scratch = os.path.join(COMPUTER, "parts/scratch.img")
    if not os.path.exists(scratch):
        raise RuntimeError("真机 mkfs.ext2 门禁失败: %s 不存在(verify.sh 的 mkfs 段没跑成?)" % scratch)
    p = subprocess.run([FSCK, "-fn", scratch], capture_output=True, text=True)
    out = (p.stdout + p.stderr).strip()
    print(out[-2000:] if out else "(no output)")
    print("e2fsck exit=%d" % p.returncode)
    if p.returncode != 0:
        raise RuntimeError("真机 mkfs.ext2/fsck.ext2 出来的镜像 e2fsck 判不干净 —— 见上面输出")
    lab = run("/sbin/blkid", scratch).strip()
    print("   %s" % lab)
    if 'LABEL="SCRATCH"' not in lab or 'TYPE="ext2"' not in lab:
        raise RuntimeError("真机 mkfs.ext2 的卷标/类型不对: %s" % lab)
    # debugfs 的 banner 会混在 stdout 里("debugfs 1.47.2 ..."), 只取第一行内容
    hello = df(scratch, "cat /hello.txt").splitlines()[0].strip()
    inner = df(scratch, "cat /dir/inner.txt").splitlines()[0].strip()
    if hello != "hello-from-mkfs" or inner != "inner":
        raise RuntimeError("真机 fsck.ext2 修完之后文件内容不对: /hello.txt=%r /dir/inner.txt=%r"
                           % (hello, inner))
    print("   ok e2fsck clean + LABEL=SCRATCH + 修复后数据完好")

    # verify.log 里的 ok/ng 与退出码逐条设门禁(其余行由人读日志)
    for name in ("mkfs_ext2", "mkfs_refuses_existing", "fsck_refuses_mounted",
                 "fsck_detects_corruption", "fsck_fixes_corruption", "fsck_clean_after_fix"):
        if ("ok " + name) not in fresh:
            raise RuntimeError("真机自检未通过: %s(verify.log 里没有 'ok %s')" % (name, name))
        print("   ok %s" % name)
    for key, want in (("mkfs_rc", "0"), ("mkfs_existing_rc", "1"), ("mkfs_dryrun_rc", "0"),
                      ("mkfs_force_rc", "0"), ("fsck_clean_rc", "0"), ("fsck_mounted_rc", "8"),
                      ("fsck_broken_rc", "4"), ("fsck_fix_rc", "1"), ("fsck_after_fix_rc", "0")):
        m = re.search(r"^%s=(\d+)" % key, fresh, re.M)
        if not m or m.group(1) != want:
            raise RuntimeError("真机 %s 不是 %s: %s" % (key, want, m.group(1) if m else "(missing)"))
        print("   ok %s=%s" % (key, want))

if __name__ == "__main__":
    main()
