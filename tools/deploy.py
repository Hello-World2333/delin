#!/usr/bin/env python3
# Delin rootfs deploy: 用基础镜像(能启动的旧 root.img)+ 更新后的内核/bin/脚本,
# 重建一个干净的 ext2 镜像(避免 debugfs 在原镜像上叠加写导致的元数据损坏)。
# 用法: python3 tools/deploy.py  <base_root.img>  <out.img>
import os, sys, subprocess, tempfile, shutil, stat

DBG = "/usr/sbin/debugfs"
MKFS = "/usr/sbin/mkfs.ext2"
REPO = "/home/worker/delin"

def run(*a, **kw):
    p = subprocess.run(a, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        raise RuntimeError(f"cmd failed: {' '.join(map(str,a))}\n{p.stdout}\n{p.stderr}")
    return p.stdout

def dryrun(*a):
    return subprocess.run(a, capture_output=True, text=True)

def rdump(img, dst):
    run(DBG, "-R", "rdump / " + dst, img, check=False)

def df(cmd, img, check=True):
    p = dryrun(DBG, "-w", "-R", cmd, img)
    if check and p.returncode != 0:
        raise RuntimeError(f"debugfs {cmd}: {p.stdout}\n{p.stderr}")
    return p

def main():
    base = sys.argv[1]
    out = sys.argv[2]
    work = tempfile.mkdtemp(prefix="delinrootfs")
    try:
        rootfs = os.path.join(work, "rootfs")
        os.makedirs(rootfs)
        # 1) 导出基础镜像全部文件
        rdump(base, rootfs)
        # 2) 更新文件
        shutil.copy(os.path.join(REPO, "dist/kernel.lua"), os.path.join(rootfs, "boot/delin.lua"))
        shutil.copy(os.path.join(REPO, "src/bin/sh"),    os.path.join(rootfs, "bin/sh"))
        shutil.copy(os.path.join(REPO, "src/bin/rm"),    os.path.join(rootfs, "bin/rm"))
        shutil.copy(os.path.join(REPO, "src/bin/mkdir"), os.path.join(rootfs, "bin/mkdir"))
        os.makedirs(os.path.join(rootfs, "root"), exist_ok=True)
        os.makedirs(os.path.join(rootfs, "tmp"),  exist_ok=True)
        shutil.copy(os.path.join(REPO, "scripts/posix_test.sh"), os.path.join(rootfs, "root/posix_test.sh"))
        shutil.copy(os.path.join(REPO, "scripts/sysinfo.sh"),    os.path.join(rootfs, "root/sysinfo.sh"))
        # 3) 建全新 ext2 镜像
        run(MKFS, "-q", "-t", "ext2", "-b", "1024", out, "2048")
        # 4) 写回目录 + 文件
        def walk(d, rel):
            entries = sorted(os.listdir(d))
            for name in entries:
                if name in (".",".."): continue
                p = os.path.join(d, name)
                rp = rel + "/" + name if rel else "/" + name
                st = os.lstat(p)
                if stat.S_ISDIR(st.st_mode):
                    df("mkdir " + rp, out, check=False)
                    df("set_inode_field " + rp + " mode 0" + oct(st.st_mode & 0o777777).replace("0o",""), out, check=False)
                    walk(p, rp)
                elif stat.S_ISREG(st.st_mode):
                    df("write " + p + " " + rp, out, check=False)
                    df("set_inode_field " + rp + " mode 0" + oct(st.st_mode & 0o777777).replace("0o",""), out, check=False)
        walk(rootfs, "")
        print("deployed ->", out, os.path.getsize(out), "bytes")
    finally:
        shutil.rmtree(work, ignore_errors=True)

if __name__ == "__main__":
    main()
