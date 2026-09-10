#!/usr/bin/env python3
# Delin rootfs deploy: 用基础镜像(能启动的旧 root.img)+ 更新后的内核/bin/脚本,
# 重建一个干净的 ext2 镜像(避免 debugfs 在原镜像上叠加写导致的元数据损坏)。
#
# 属主: rdump 以非 root 运行时无法恢复 uid/gid(只报 "Operation not permitted while
# changing ownership"), debugfs 的 mkdir/write 也一律建成 root:root。因此新镜像的
# uid/gid 一律以**基镜像**为准逐条写回; 基镜像里没有的路径(新增目录/文件)= root:root。
#
# fail-fast: debugfs 遇到坏目录/坏 inode 只打印错误、退出码仍是 0, 会静默漏掉整个目录
# (历史事故: 基镜像 /lib 坏掉 -> rdump 漏掉 /lib -> 新镜像 /lib 空)。所以这里对
# rdump/ls/写回的输出逐行检查, 任何损坏迹象立即中止; 构建完再跑一次只读 fsck 门禁。
#
# 用法: python3 tools/deploy.py  <base_root.img>  <out.img>
import os, sys, subprocess, tempfile, shutil, stat

DBG = "/usr/sbin/debugfs"
MKFS = "/usr/sbin/mkfs.ext2"
FSCK = "/usr/sbin/e2fsck"
REPO = "/home/worker/delin"

# debugfs 以非 root 运行必然出现的告警(无法 chown 导出文件), 不算失败。
BENIGN = ("changing ownership",)
# 出现这些字样即视为元数据损坏, 必须中止。
BAD = ("corrupted", "short read", "i/o error", "not found", "invalid", "illegal")


def _module_version():
    # 版本号唯一真源: src/kernel/version.lua (`return "x.y.z"`)。读不到就失败, 不回退。
    import re
    path = os.path.join(REPO, "src/kernel/version.lua")
    with open(path, "r", encoding="utf-8") as f:
        m = re.search(r'^\s*return\s+"([^"]+)"', f.read(), re.M)
    if not m:
        raise RuntimeError(f"无法从 {path} 读出版本号")
    return m.group(1)


def dryrun(*a):
    return subprocess.run(a, capture_output=True, text=True)


def run(*a, **kw):
    p = subprocess.run(a, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        raise RuntimeError(f"cmd failed: {' '.join(map(str,a))}\n{p.stdout}\n{p.stderr}")
    return p.stdout


def _check_out(what, out):
    for line in out.splitlines():
        if any(b in line for b in BENIGN):
            continue
        low = line.lower()
        if any(b in low for b in BAD):
            raise RuntimeError(f"{what}: 基镜像/镜像损坏, 拒绝继续\n{out}")


def rdump(img, dst):
    p = dryrun(DBG, "-R", "rdump / " + dst, img)
    out = p.stdout + p.stderr
    if p.returncode != 0:
        raise RuntimeError(f"rdump 失败: {img}\n{out}")
    _check_out(f"rdump {img}", out)
    return out


def df(cmd, img, check=True):
    p = dryrun(DBG, "-w", "-R", cmd, img)
    if check:
        if p.returncode != 0:
            raise RuntimeError(f"debugfs {cmd}: {p.stdout}\n{p.stderr}")
        _check_out(f"debugfs {cmd}", p.stdout + p.stderr)
    return p


def base_ownership(img):
    """基镜像 path -> (uid, gid)。用 `ls -l -p` 的机读输出递归遍历, 每行形如
    /<ino>/<mode>/<uid>/<gid>/<name>/<size>/ (目录 size 为空)。"""
    owner = {}

    def walk(path):
        p = dryrun(DBG, "-R", "ls -l -p " + path, img)
        out = p.stdout + p.stderr
        if p.returncode != 0:
            raise RuntimeError(f"读取基镜像属主失败: {path}\n{out}")
        _check_out(f"ls {path}", out)
        for line in out.splitlines():
            if not line.startswith("/"):
                continue
            f = line.split("/")
            if len(f) < 6:
                continue
            name = f[5]
            if name in (".", ".."):
                continue
            child = path.rstrip("/") + "/" + name
            owner[child] = (int(f[3]), int(f[4]))
            if stat.S_ISDIR(int(f[2], 8)):
                walk(child)

    walk("/")
    return owner


def main():
    base = sys.argv[1]
    out = sys.argv[2]
    work = tempfile.mkdtemp(prefix="delinrootfs")
    try:
        rootfs = os.path.join(work, "rootfs")
        os.makedirs(rootfs)
        # 0) 先从基镜像取属主表(基镜像坏在这里就立刻失败, 不产生半成品镜像)
        owner = base_ownership(base)
        # 1) 导出基础镜像全部文件
        rdump(base, rootfs)
        # 2) 更新文件
        shutil.copy(os.path.join(REPO, "dist/kernel.lua"), os.path.join(rootfs, "boot/delin.lua"))
        # 部署全部 bin 工具, 保证真机与 src/bin 一致。
        for f in sorted(os.listdir(os.path.join(REPO, "src/bin"))):
            shutil.copy(os.path.join(REPO, "src/bin", f), os.path.join(rootfs, "bin", f))
            os.chmod(os.path.join(rootfs, "bin", f), 0o755)
        os.makedirs(os.path.join(rootfs, "root"), exist_ok=True)
        os.makedirs(os.path.join(rootfs, "tmp"),  exist_ok=True)
        os.makedirs(os.path.join(rootfs, "run"),  exist_ok=True)
        os.makedirs(os.path.join(rootfs, "var", "log"), exist_ok=True)
        os.makedirs(os.path.join(rootfs, "mnt"), exist_ok=True)
        shutil.copy(os.path.join(REPO, "scripts/posix_test.sh"), os.path.join(rootfs, "root/posix_test.sh"))
        shutil.copy(os.path.join(REPO, "scripts/jobctl_test.sh"), os.path.join(rootfs, "root/jobctl_test.sh"))
        shutil.copy(os.path.join(REPO, "scripts/sysinfo.sh"),    os.path.join(rootfs, "root/sysinfo.sh"))
        # 单元文件: src/units/* -> /lib/systemd/system/ (厂商单元)
        unitdir = os.path.join(rootfs, "lib", "systemd", "system")
        os.makedirs(unitdir, exist_ok=True)
        for f in sorted(os.listdir(os.path.join(REPO, "src/units"))):
            shutil.copy(os.path.join(REPO, "src/units", f), os.path.join(unitdir, f))
        # 系统配置: src/etc/* -> /etc/
        for f in sorted(os.listdir(os.path.join(REPO, "src/etc"))):
            shutil.copy(os.path.join(REPO, "src/etc", f), os.path.join(rootfs, "etc", f))
        # 启用单元: /etc/systemd/system/<target>.wants/<unit> 空标记(systemd 的 enable)
        for target, unit in (("multi-user.target", "syslogd.service"),
                             ("timers.target", "logrotate.timer")):
            wantdir = os.path.join(rootfs, "etc", "systemd", "system", target + ".wants")
            os.makedirs(wantdir, exist_ok=True)
            open(os.path.join(wantdir, unit), "w").close()
        # 安装内核模块(src/modules -> /lib/modules/<version>/):
        # 基镜像的 /lib 可能因 debugfs 元数据损坏而无法 rdump, 且模块应始终取当前 src。
        ver = _module_version()
        moddir = os.path.join(rootfs, "lib", "modules", ver)
        os.makedirs(moddir, exist_ok=True)
        for f in sorted(os.listdir(os.path.join(REPO, "src/modules"))):
            p = os.path.join(REPO, "src/modules", f)
            if os.path.isfile(p):
                shutil.copy(p, os.path.join(moddir, f))
                os.chmod(os.path.join(moddir, f), 0o755)
        # 3) 建全新 ext2 镜像
        run(MKFS, "-q", "-t", "ext2", "-b", "1024", out, "2048")
        # 4) 写回目录 + 文件 + 属主/属组
        def walk(d, rel):
            entries = sorted(os.listdir(d))
            for name in entries:
                if name in (".",".."): continue
                p = os.path.join(d, name)
                rp = rel + "/" + name if rel else "/" + name
                st = os.lstat(p)
                uid, gid = owner.get(rp, (0, 0))
                mode = "0" + oct(st.st_mode & 0o777777)[2:]
                if stat.S_ISDIR(st.st_mode):
                    df("mkdir " + rp, out)
                elif stat.S_ISREG(st.st_mode):
                    df("write " + p + " " + rp, out)
                else:
                    continue
                df(f"set_inode_field {rp} mode {mode}", out)
                df(f"set_inode_field {rp} uid {uid}", out)
                df(f"set_inode_field {rp} gid {gid}", out)
                if stat.S_ISDIR(st.st_mode):
                    walk(p, rp)
        walk(rootfs, "")
        # 5) 门禁: 新镜像必须通过只读 fsck(构建期就发现元数据问题, 不带上真机)
        p = dryrun(FSCK, "-fn", out)
        if p.returncode != 0:
            raise RuntimeError("新镜像未通过 e2fsck -fn:\n" + p.stdout + p.stderr)
        nonroot = sum(1 for v in owner.values() if v != (0, 0))
        print("deployed ->", out, os.path.getsize(out), "bytes; 保留非 root 属主条目:", nonroot)
    finally:
        shutil.rmtree(work, ignore_errors=True)

if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print("deploy 失败: %s" % e, file=sys.stderr)
        sys.exit(1)
