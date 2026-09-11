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
import hashlib, os, shutil, subprocess, sys, time

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

def main():
    base = os.path.join(DISK, "parts/root.img")
    reboot = True
    skip_deploy = False
    printer = False
    probe_only = False
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == "--base":
            base = args.pop(0)
        elif a == "--no-reboot":
            reboot = False
        elif a == "--reboot-only":
            skip_deploy = True
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
        f.write("# real-machine verify fstab\n"
                "/dev/sda2   /mnt/data     ext2   defaults   0 2\n"
                "/dev/sda1   /mnt/rootcopy ext2   noauto     0 2\n")
    df(out, "rm /etc/fstab")
    df_write(out, fstab, "/etc/fstab")

    # 3c) verify.service + /root/verify.sh
    sh = os.path.join(REPO, "scripts/realmachine_verify.sh")
    df_write(out, sh, "/root/verify.sh")
    df(out, "set_inode_field /root/verify.sh mode 0100755")
    unit = os.path.join(work, "verify.service")
    with open(unit, "w") as f:
        f.write("[Unit]\nDescription=Real-machine verification\nAfter=syslogd.service\n\n"
                "[Service]\nType=oneshot\nExecStart=/bin/sh /root/verify.sh\n\n"
                "[Install]\nWantedBy=multi-user.target\n")
    df_write(out, unit, "/lib/systemd/system/verify.service")
    df_mkdir(out, "/etc/systemd/system/multi-user.target.wants")
    marker = os.path.join(work, "marker")
    open(marker, "w").close()
    df_write(out, marker, "/etc/systemd/system/multi-user.target.wants/verify.service")
    df_mkdir(out, "/mnt/rootcopy")

    # 3e) verify-sh.service: sh 内建/变量自检(. set export unset PATH PSx cd) -> /var/log/sh_verify.log
    for src, dst in (("scripts/sh_verify.sh", "/root/sh_verify.sh"),
                     ("scripts/sh_builtin_test.sh", "/root/sh_builtin_test.sh"),
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
                "[Service]\nType=oneshot\nExecStart=/bin/sh /root/sh_verify.sh\n\n"
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
    for src, dst in (("scripts/posix_tools_verify.sh", "/root/posix_tools_verify.sh"),
                     ("scripts/posix_kernel_verify.lua", "/root/posix_kernel_verify.lua"),
                     ("scripts/tee_verify.lua", "/root/tee_verify.lua")):
        df_write(out, os.path.join(REPO, src), dst)
        df(out, "set_inode_field %s mode 0100755" % dst)
    unit_posix = os.path.join(work, "posix-verify.service")
    with open(unit_posix, "w") as f:
        f.write("[Unit]\nDescription=Real-machine POSIX tools verification\nAfter=syslogd.service\n\n"
                "[Service]\nType=oneshot\nExecStart=/bin/sh /root/posix_tools_verify.sh\n\n"
                "[Install]\nWantedBy=multi-user.target\n")
    df_write(out, unit_posix, "/lib/systemd/system/posix-verify.service")
    df_write(out, marker, "/etc/systemd/system/multi-user.target.wants/posix-verify.service")

    # 3g) 门禁: 注入后镜像仍必须干净, 不把坏镜像带上真机
    p = subprocess.run([FSCK, "-fn", out], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("注入后的镜像未通过 e2fsck -fn:\n" + p.stdout + p.stderr)

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
    print("waiting %ds for boot ..." % WAIT)
    time.sleep(WAIT)

    # 4b) 重启电脑 #4
    print("== reboot computer #4 ==")
    run("python3", RCON, "computercraft shutdown #4", check=False)
    time.sleep(2)
    run("python3", RCON, "computercraft turn-on #4", check=False)
    print("waiting 30s for boot ...")
    time.sleep(30)

    # 5) 取回日志
    print("== collect logs ==")
    print("\n===== 引导日志 =====")
    # 三段各有出处: 磁盘 CC-fs 上的 /delin.log 是 DLUB 写的; 根镜像里的 /delin.log 是内核写的
    # (ext2 根); 电脑自身 FS 的 /delin.log 只在这台机器**回退**去引导自带存储时才有意义。
    for label, path in (("disk ccfs", os.path.join(DISK, "delin.log")),
                        ("computer ccfs", os.path.join(COMPUTER, "delin.log"))):
        print("----- %s: %s -----" % (label, path))
        if os.path.exists(path):
            with open(path, "r", errors="replace") as f:
                print(f.read()[-4000:])
        else:
            print("(missing)")
    # 5a) 引导门禁: 磁盘根必须真的启动了。BIOS 只有扫不到磁盘 /.boot、或 DLUB 读不到该盘
    #     /dlub.cfg 时才会回退去引导电脑自身 FS —— 那种情况下这里读到的 verify.log 是**上一轮**的,
    #     会让"改了什么都没生效"看起来像全绿(踩过一次: 磁盘缺 /dlub.cfg, 机器回退到 CCFS 根)。
    fresh = subprocess.run([DBG, "-R", "cat /var/log/verify.log", os.path.join(DISK, "parts/root.img")],
                           capture_output=True, text=True).stdout
    if fresh == verify_before:
        raise RuntimeError(
            "失效验证: 磁盘根没有启动 —— /var/log/verify.log 与部署时逐字节相同(本轮的 verify.service 没跑)。\n"
            "多半是 BIOS/DLUB 回退到电脑自身 FS 的旧安装了; 上面的 /delin.log 是那次引导的日志。")
    if "=== verify done ===" not in fresh:
        raise RuntimeError("失效验证: verify.log 变了但没有跑完(缺 '=== verify done ==='):\n" + fresh[-2000:])
    print("   boot guard ok: 磁盘根已引导, verify.log 是本轮写的")
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
    p = subprocess.run([FSCK, "-fn", os.path.join(DISK, "parts/root.img")], capture_output=True, text=True)
    out = (p.stdout + p.stderr).strip()
    print(out[-3000:] if out else "(no output)")
    print("e2fsck exit=%d" % p.returncode)
    if p.returncode != 0:
        raise RuntimeError("运行一轮后 root.img 不再 fsck 干净 —— Delin 把自己写坏了, 见上面输出")

if __name__ == "__main__":
    main()
