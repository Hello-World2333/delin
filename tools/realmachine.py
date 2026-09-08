#!/usr/bin/env python3
"""Delin 真机验证(电脑 3 + 磁盘 0)。

做四件事:
  1. 重新打包内核 bundle(dist/kernel.lua)
  2. 用 tools/deploy.py 重建干净的 ext2 根镜像(基础镜像 -> 新镜像)
  3. 往镜像/磁盘里注入验证负载: 第二个 ext2 分区(/parts/data.img, 供 fstab 测试)、
     /etc/fstab 测试条目、verify.service + /root/verify.sh(systemd-like init 的自检服务)
  4. 重启电脑 #3, 等待启动, 用 debugfs 从 root.img 里取回 /var/log/*.log 打印出来

用法: python3 tools/realmachine.py [--base /mnt/disk/0/parts/root.img] [--no-reboot] [--reboot-only]

注意: 本环境里电脑自身 FS 的文件(/.boot、/main.lua)在宿主机改写后, 游戏侧似乎仍读旧内容
(磁盘镜像 /mnt/disk/0/parts/*.img 的改写则立即生效, 已验证), 因此第 3d 步写 DLUB 到 /main.lua
只对全新电脑有意义; CC-fs 引导路径无法在此环境用真机验证(由 tools/hosttest.lua 的 init 端到端
用例覆盖)。
"""
import os, shutil, subprocess, sys, time

REPO = "/home/worker/delin"
DBG = "/usr/sbin/debugfs"
MKFS = "/usr/sbin/mkfs.ext2"
DISK = "/mnt/disk/0"
COMPUTER = "/mnt/computer/3"
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
    df(img, "write %s %s" % (host_path, img_path), check=True)

def df_mkdir(img, path):
    df(img, "mkdir %s" % path)

def main():
    base = os.path.join(DISK, "parts/root.img")
    reboot = True
    skip_deploy = False
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == "--base":
            base = args.pop(0)
        elif a == "--no-reboot":
            reboot = False
        elif a == "--reboot-only":
            skip_deploy = True
        else:
            raise SystemExit("unknown arg: " + a)

    if skip_deploy:
        print("--reboot-only: skipping build/deploy")
        reboot_and_collect()
        return

    # 1) 打包
    print("== build kernel bundle ==")
    print(run("lua5.1", os.path.join(REPO, "tools/bundle.lua"), "kernel", cwd=REPO))
    print(run("lua5.1", os.path.join(REPO, "tools/bundle.lua"), "dlub", cwd=REPO))

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

    # 3d) 安装到磁盘
    shutil.copy(out, os.path.join(DISK, "parts/root.img"))
    shutil.copy(data_img, os.path.join(DISK, "parts/data.img"))
    with open(os.path.join(DISK, "parts/manifest"), "w") as f:
        f.write("root /parts/root.img ext2\n"
                "data /parts/data.img ext2\n"
                "boot /boot/delin.lua\n")
    shutil.copy(os.path.join(REPO, "dist/kernel.lua"), os.path.join(DISK, "boot/delin.lua"))
    shutil.copy(os.path.join(REPO, "dist/dlub.lua"), os.path.join(DISK, "boot/dlub.lua"))
    # 电脑自身 FS 的引导入口(BIOS 按 /.boot -> /main.lua 引导): 放 DLUB 装载器。
    mainlua = os.path.join(COMPUTER, "main.lua")
    if os.path.exists(mainlua):
        shutil.copy(mainlua, mainlua + ".bak")
    shutil.copy(os.path.join(REPO, "dist/dlub.lua"), mainlua)
    print("installed root.img/data.img/manifest/kernel + DLUB -> %s/main.lua" % COMPUTER)

    if not reboot:
        print("--no-reboot: stopping here")
        return
    reboot_and_collect()


def reboot_and_collect():
    # 4) 重启电脑 #3
    print("== reboot computer #3 ==")
    run("python3", RCON, "computercraft shutdown #3", check=False)
    time.sleep(2)
    run("python3", RCON, "computercraft turn-on #3", check=False)
    print("waiting %ds for boot ..." % WAIT)
    time.sleep(WAIT)

    # 5) 取回日志
    print("== collect logs ==")
    logs = ["/var/log/verify.log", "/var/log/messages", "/var/log/messages.1",
            "/var/log/secure", "/var/log/kern.log"]
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
    print("\n===== computer fs /delin.log (内核引导日志) =====")
    p = os.path.join(COMPUTER, "delin.log")
    if os.path.exists(p):
        with open(p, "r", errors="replace") as f:
            print(f.read()[-8000:])
    else:
        print("(missing)")

if __name__ == "__main__":
    main()
