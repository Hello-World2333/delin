#!/usr/bin/env python3
"""部署 Delin 到电脑4和磁盘0。

支持两种启动模式：
1. 从外部磁盘启动 (bootdisk)
2. 从电脑自带存储启动 (rootfs)

用法:
  python3 tools/deploy_to_computer4.py --mode rootfs --rootfs /parts/root.img
  python3 tools/deploy_to_computer4.py --mode bootdisk --bootdisk left
"""
import os, sys, subprocess, shutil, time

REPO = "/home/worker/delin"
COMPUTER4 = "/mnt/computer/4"
DISK0 = "/mnt/disk/0"
RCON = os.path.expanduser("~/docs/tools/rcon.py")

def run(*a, check=True, cwd=None):
    p = subprocess.run(a, capture_output=True, text=True, cwd=cwd)
    if check and p.returncode != 0:
        raise RuntimeError("cmd failed: %s\n%s\n%s" % (" ".join(a), p.stdout, p.stderr))
    return p.stdout + p.stderr

def shutdown_computer(computer_id, timeout=90):
    """关闭电脑"""
    print(f"== shutdown computer #{computer_id} ==")
    run("python3", RCON, f"computercraft shutdown #{computer_id}", check=False)
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(2)
        # 检查电脑状态
        out = run("python3", RCON, f"computercraft dump #{computer_id}", check=False)
        for line in out.splitlines():
            if line.strip().startswith("On"):
                parts = line.split("|")
                if len(parts) >= 2:
                    if parts[1].strip().upper().startswith("N"):
                        print(f"   computer #{computer_id} is off")
                        time.sleep(3)  # 等待磁盘缓存落盘
                        return True
    print(f"   WARNING: computer #{computer_id} did not shut down within {timeout}s")
    return False

def main():
    import argparse
    parser = argparse.ArgumentParser(description="部署 Delin 到电脑4")
    parser.add_argument("--mode", choices=["rootfs", "bootdisk"], default="rootfs",
                        help="启动模式: rootfs (从电脑自带存储) 或 bootdisk (从外部磁盘)")
    parser.add_argument("--rootfs", default="/parts/root.img",
                        help="rootfs 模式: ext2 根镜像路径 (默认: /parts/root.img)")
    parser.add_argument("--bootdisk", default="left",
                        help="bootdisk 模式: 外部磁盘外设名 (默认: left)")
    parser.add_argument("--no-reboot", action="store_true",
                        help="部署后不重启电脑")
    args = parser.parse_args()

    # 1. 构建
    print("== build kernel bundle ==")
    print(run("lua5.1", os.path.join(REPO, "tools/bundle.lua"), "kernel", cwd=REPO))
    print(run("lua5.1", os.path.join(REPO, "tools/bundle.lua"), "dlub", cwd=REPO))

    # 2. 部署到磁盘0
    print("== deploy to disk 0 ==")
    base_img = os.path.join(DISK0, "parts/root.img")
    if not os.path.exists(base_img):
        print(f"   WARNING: {base_img} not found, skipping disk deployment")
    else:
        # 使用现有的 deploy.py
        out_img = "/tmp/delin-root4.img"
        if os.path.exists(out_img):
            os.unlink(out_img)
        print(run(sys.executable, os.path.join(REPO, "tools/deploy.py"), base_img, out_img, cwd=REPO))
        
        # 安装到磁盘0
        shutil.copy(out_img, base_img)
        print(f"   installed root.img -> {base_img}")
        
        # 安装内核
        shutil.copy(os.path.join(REPO, "dist/kernel.lua"), os.path.join(DISK0, "boot/delin.lua"))
        print("   installed kernel.lua")
        
        # 安装 DLUB
        shutil.copy(os.path.join(REPO, "dist/dlub.lua"), os.path.join(DISK0, "boot/dlub.lua"))
        print("   installed dlub.lua")
        
        # 更新 manifest
        manifest = "root /parts/root.img ext2\nboot /boot/delin.lua\n"
        mpath = os.path.join(DISK0, "parts/manifest")
        with open(mpath, "w") as f:
            f.write(manifest)
        print(f"   updated manifest: {mpath}")

    # 3. 部署到电脑4
    print("== deploy to computer 4 ==")
    
    # 创建 /dlub.cfg
    os.makedirs(COMPUTER4, exist_ok=True)
    dlub_cfg = os.path.join(COMPUTER4, "dlub.cfg")
    with open(dlub_cfg, "w") as f:
        if args.mode == "rootfs":
            f.write(f"rootfs {args.rootfs}\n")
            print(f"   created {dlub_cfg} with rootfs={args.rootfs}")
        else:
            f.write(f"bootdisk {args.bootdisk}\n")
            print(f"   created {dlub_cfg} with bootdisk={args.bootdisk}")
    
    # 安装 DLUB 到电脑4的 /main.lua
    mainlua = os.path.join(COMPUTER4, "main.lua")
    shutil.copy(os.path.join(REPO, "dist/dlub.lua"), mainlua)
    print(f"   installed dlub.lua -> {mainlua}")
    
    # 安装内核到电脑4的 /boot/ (可选，供 rootfs 模式)
    bootdir = os.path.join(COMPUTER4, "boot")
    os.makedirs(bootdir, exist_ok=True)
    shutil.copy(os.path.join(REPO, "dist/kernel.lua"), os.path.join(bootdir, "delin.lua"))
    print(f"   installed kernel.lua -> {bootdir}/delin.lua")
    
    # 安装根镜像到电脑4 (rootfs 模式)
    if args.mode == "rootfs":
        # 复制 root.img 到电脑4
        rootfs_path = args.rootfs
        if not rootfs_path.startswith("/"):
            rootfs_path = "/" + rootfs_path
        dst_path = os.path.join(COMPUTER4, rootfs_path.lstrip("/"))
        os.makedirs(os.path.dirname(dst_path), exist_ok=True)
        
        if os.path.exists(base_img):
            shutil.copy(base_img, dst_path)
            print(f"   installed root.img -> {dst_path}")
        else:
            print(f"   WARNING: {base_img} not found, cannot copy root.img to computer 4")

    # 4. 重启电脑4
    if not args.no_reboot:
        print("== reboot computer 4 ==")
        shutdown_computer(4)
        time.sleep(2)
        run("python3", RCON, f"computercraft turn-on #4", check=False)
        print("   computer #4 started")
        print("   waiting 30s for boot ...")
        time.sleep(30)
        
        # 检查日志
        log_path = os.path.join(COMPUTER4, "delin.log")
        if os.path.exists(log_path):
            print("== boot log ==")
            with open(log_path, "r", errors="replace") as f:
                print(f.read()[-8000:])
        else:
            print("   no boot log found")
    else:
        print("--no-reboot: skipping restart")

if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print("deploy failed: %s" % e, file=sys.stderr)
        sys.exit(1)
