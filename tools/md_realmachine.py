#!/usr/bin/env python3
"""Delin 软RAID 真机验证 —— 目标机 **电脑 #6**(台式 CEE:CC, 自带存储 10MB)。

为什么要在这台机器上验: 它的自带存储有 10MB(普通电脑 1MB), 装得下"成员镜像 + 根文件系统",
于是软RAID 的整条生命周期能在真机上跑完 —— 直接用 /parts/*.img 当成员设备(与 mdadm 收
镜像路径这条 Delin 约定一致), 不需要真的插一堆软盘。

流程(与 tools/ceecc_realmachine.py 同一套约束: 停机 -> 装机 -> 开机 -> 读回日志 -> 逐项断言):
  0. **先关机** —— 往电脑自身 FS 写文件必须在停机状态下进行
  1. 重新打包(dist/: kernel.lua + payload + 发布树)
  2. 在电脑 #6 自身存储上做一次**干净**的 CCFS 根安装: 清空旧文件 -> 铺 payload ->
     Delin BIOS 到 /startup.lua -> /.boot = /boot/delin.lua; 注入 /root/md_verify.sh
     (scripts/md_verify.sh)与 mdtest.service(oneshot, TimeoutStartSec=600)
  3. 第一次开机: 跑 phase 1(建阵列/格式化/挂载/降级/重建/组装), 末尾写 /etc/mdadm.conf
     并**停掉所有阵列**, 留下 /root/md-phase1.done
  4. 第二次开机(reboot): 引导时由 init 的 local-fs-pre.target 拉起的 mdadm.service
     自动组装, phase 2 断言"阵列在启动时就已经在跑" + 数据仍在
  5. 读回 /var/log/md.log 逐项断言(脚本只记 ok/ng 与 KEY=VALUE, 判据全在这里)

用法: python3 tools/md_realmachine.py [--no-reboot] [--timeout 300]
"""
import os, shutil, subprocess, sys, time

REPO = "/home/worker/delin"
COMPUTER = "/mnt/computer/6"
COMPUTER_ID = 6
RCON = os.path.expanduser("~/docs/tools/rcon.py")
DONE1 = "=== phase 1 done ==="
DONE2 = "=== md verify done ==="
LOG_REL = "var/log/md.log"
SKELETON = ["bin", "boot", "dev", "etc", "etc/systemd/system", "etc/systemd/system/multi-user.target.wants",
            "home", "home/alice", "lib", "lib/modules", "lib/systemd/system", "mnt", "parts", "proc",
            "root", "run", "sys", "tmp", "var", "var/log"]

# 每一项都必须出现(脚本被 init 的超时杀掉时, 缺项就是失败, 不能只看 ng)
REQUIRED = [
    "create_raid5", "create_raid1", "mdstat_md0_raid5", "mdstat_md1_raid1", "mdstat_md0_all_in_sync",
    "dev_nodes", "not_mounted_yet", "mkfs_on_array", "fsck_clean", "mount_array", "umount_array",
    "fail_member", "remove_member", "mdstat_degraded", "mount_degraded", "read_degraded",
    "add_replacement", "wait_recovery", "mdstat_recovered", "mount_after_rebuild", "read_after_rebuild",
    "examine_member", "examine_magic", "examine_checksum", "examine_replacement_role",
    "stop_array", "stopped_array_not_mountable", "assemble_explicit", "mount_reassembled",
    "read_reassembled", "write_mdadm_conf", "conf_has_md0", "conf_has_md1", "all_arrays_stopped",
    # phase 2(重启后)
    "mdadm_service_active", "boot_md0_assembled", "boot_md1_assembled", "boot_md0_all_in_sync",
    "boot_mount_array", "boot_read_survived", "boot_superblock_intact",
]

pass_count, fail_count = 0, 0


def run(*a, check=True, cwd=None):
    p = subprocess.run(a, capture_output=True, text=True, cwd=cwd)
    if check and p.returncode != 0:
        raise RuntimeError("cmd failed: %s\n%s\n%s" % (" ".join(a), p.stdout, p.stderr))
    return p.stdout + p.stderr


def ok(cond, label, extra=""):
    global pass_count, fail_count
    if cond:
        pass_count += 1
        print("ok   %s" % label)
    else:
        fail_count += 1
        print("FAIL %s%s" % (label, ("  -- " + str(extra)) if extra else ""))


def eq(got, want, label):
    ok(got == want, label, "got=%r want=%r" % (got, want))


def computer_on():
    out = run("python3", RCON, "computercraft dump #%d" % COMPUTER_ID, check=False)
    for line in out.splitlines():
        if line.strip().startswith("On"):
            parts = line.split("|")
            if len(parts) >= 2:
                return parts[1].strip().upper().startswith("Y")
    return None


def shutdown_computer(timeout=90):
    print("== shutdown computer #%d (写电脑自身 FS 必须在停机状态下) ==" % COMPUTER_ID)
    run("python3", RCON, "computercraft shutdown #%d" % COMPUTER_ID, check=False)
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(2)
        if computer_on() is False:
            time.sleep(3)  # 再等一拍让游戏侧落盘
            print("   off")
            return True
    print("   WARNING: 机器在 %ds 内没有停下来" % timeout)
    return False


RUNTOKEN = None


def install(version):
    """在电脑 #6 自身存储上做一次干净的 CCFS 根安装(磁盘上的盘不参与)。"""
    print("== install: CCFS root on computer #%d's own storage ==" % COMPUTER_ID)
    if os.path.isdir(COMPUTER):
        for entry in os.listdir(COMPUTER):
            path = os.path.join(COMPUTER, entry)
            shutil.rmtree(path) if os.path.isdir(path) else os.unlink(path)
    for d in SKELETON:
        os.makedirs(os.path.join(COMPUTER, d), exist_ok=True)

    # 铺 dist/(不是 dist/release/*/payload: 后者只在 --release 时重建, 拿它装机
    # 会静默装上上一轮的产物 —— ceecc 那轮就栽在这)。
    dist = os.path.join(REPO, "dist")
    for sub, dst in (("bin", "bin"), ("etc", "etc"), ("units", "lib/systemd/system"),
                     ("modules/" + version, "lib/modules/" + version)):
        src = os.path.join(dist, sub)
        if not os.path.isdir(src):
            raise RuntimeError("no %s in dist/ (run lua5.1 tools/build.lua)" % sub)
        shutil.copytree(src, os.path.join(COMPUTER, dst), dirs_exist_ok=True)
    shutil.copy(os.path.join(dist, "kernel.lua"), os.path.join(COMPUTER, "boot/delin.lua"))
    shutil.copy(os.path.join(dist, "dlub.lua"), os.path.join(COMPUTER, "boot/dlub.lua"))
    shutil.copy(os.path.join(REPO, "dist/bios/startup.lua"), os.path.join(COMPUTER, "startup.lua"))
    with open(os.path.join(COMPUTER, ".boot"), "w") as f:
        f.write("/boot/delin.lua")

    # 注入验证脚本, 并把 RUNTOKEN 换成唯一串: 日志里出现它才算"这一轮的结果"。
    # (NFS 会缓存属性与内容, 只比 mtime 会把上一轮的日志当成这一轮的 —— 踩过一次。)
    global RUNTOKEN
    RUNTOKEN = "t%d" % int(time.time())
    with open(os.path.join(REPO, "scripts/md_verify.sh"), "r", encoding="utf-8") as f:
        script = f.read()
    if "\nRUNTOKEN=dev\n" not in script:
        raise RuntimeError("md_verify.sh: RUNTOKEN=dev placeholder not found")
    script = script.replace("\nRUNTOKEN=dev\n", "\nRUNTOKEN=%s\n" % RUNTOKEN, 1)
    with open(os.path.join(COMPUTER, "root/md_verify.sh"), "w", encoding="utf-8") as f:
        f.write(script)
    with open(os.path.join(COMPUTER, "lib/systemd/system/mdtest.service"), "w") as f:
        f.write("[Unit]\nDescription=Delin software RAID verification\nAfter=syslogd.service\n\n"
                "[Service]\nType=oneshot\nTimeoutStartSec=600\n"
                "ExecStart=/bin/sh /root/md_verify.sh\n\n"
                "[Install]\nWantedBy=multi-user.target\n")
    open(os.path.join(COMPUTER, "etc/systemd/system/multi-user.target.wants/mdtest.service"), "w").close()
    run("sync")
    time.sleep(4)  # NFS 写入有延迟


def read_log():
    path = os.path.join(COMPUTER, LOG_REL)
    if not os.path.exists(path):
        return None
    with open(path, "r", errors="replace") as f:
        return f.read()


def read_delin_log():
    path = os.path.join(COMPUTER, "delin.log")
    if not os.path.exists(path):
        return ""
    with open(path, "r", errors="replace") as f:
        return f.read()


def boot_and_wait(mark, timeout):
    """开机 -> 等日志里出现 mark; 返回 (log, boot_log) 或 None。"""
    print("== boot computer #%d (waiting for %r) ==" % (COMPUTER_ID, mark))
    run("python3", RCON, "computercraft turn-on #%d" % COMPUTER_ID, check=False)
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(5)
        text = read_log()
        if text and mark in text and ("run-token=%s" % RUNTOKEN) in text:
            # 引导门禁: 日志必须是**本轮**写的(否则会拿着一份上一轮的结果报成功)。
            # "init up" 要等 default.target 起来才打印, 而自检服务是它的一部分 —— 自检写完日志
            # 到 init 打印之间有个时间差, 这里要等一下, 别把"晚一拍"判成引导失败(踩过一次)。
            boot = ""
            for _ in range(20):
                boot = read_delin_log()
                if "init up" in boot:
                    break
                time.sleep(2)
            if "init up" not in boot:
                print("引导门禁失败: /delin.log 里没有 init up")
                print(boot[-2000:])
                return None
            print("   boot gate ok (%s, run-token %s)" % (mark, RUNTOKEN))
            return text, boot
    print("超时(%ds)等 %r。当前日志尾部:\n%s" % (timeout, mark, (read_log() or "(空)")[-3000:]))
    return None


def checksum_of(log):
    for line in log.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0].isdigit() and parts[2].endswith("hello.txt"):
            return parts[0]
    return None


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-reboot", action="store_true", help="只装机不重启")
    ap.add_argument("--timeout", type=int, default=300, help="每次开机的等待秒数")
    args = ap.parse_args()

    print("== build ==")
    print(run("lua5.1", os.path.join(REPO, "tools/build.lua"), cwd=REPO))
    import re
    version = re.search(r'"(\d+\.\d+\.\d+)"',
                        open(os.path.join(REPO, "src/kernel/version.lua")).read()).group(1)

    if not shutdown_computer():
        raise SystemExit("computer #%d 停不下来, 拒绝在运行中写它的文件系统" % COMPUTER_ID)
    install(version)
    if args.no_reboot:
        print("--no-reboot: 已装机, 未开机")
        return

    # ---- 第一次开机: phase 1 ----
    got = boot_and_wait(DONE1, args.timeout)
    if got is None:
        raise SystemExit("phase 1 失败: 没等到 %r" % DONE1)
    log1, boot1 = got
    print("---- /var/log/md.log (phase 1) ----")
    print(log1)
    ok("mdassembly: mdadm.service <- local-fs-pre.target" in boot1,
       "init 把 mdadm.service 挂进了 local-fs-pre.target")

    # 重启前先确认阵列确实被停掉了(否则 phase 2 测的不是"开机自动组装")
    ok("all_arrays_stopped" in log1 and "ng  all_arrays_stopped" not in log1,
       "phase 1 结束时阵列已全部停掉")

    # ---- 第二次开机: phase 2 ----
    print("== reboot for phase 2 ==")
    if not shutdown_computer():
        raise SystemExit("computer #%d 停不下来" % COMPUTER_ID)
    got = boot_and_wait(DONE2, args.timeout)
    if got is None:
        raise SystemExit("phase 2 失败: 没等到 %r" % DONE2)
    log2, boot2 = got
    print("---- /var/log/md.log (phase 2) ----")
    print(log2)

    # ---- 断言 ----
    print("== checks ==")
    ok_count, ng_lines = 0, []
    for line in log2.splitlines():
        s = line.strip()
        if s.startswith("ok  "):
            ok_count += 1
        elif s.startswith("ng  "):
            ng_lines.append(s)
    ok(ng_lines == [], "日志里没有任何 ng 行", ng_lines)
    missing = [n for n in REQUIRED if ("ok  " + n) not in log2]
    ok(missing == [], "所有必需的检查项都跑到了", missing)
    ok(ok_count >= len(REQUIRED), "ok 行数 >= 必需项数(%d)" % len(REQUIRED), ok_count)
    ok("mdadm --version" in log2 or "mdadm (Delin OS)" in log2, "mdadm 工具在真机上可执行")
    cs = checksum_of(log2)
    ok(cs is not None and cs != "0", "hello.txt 的 cksum 被记录下来了", cs)
    ok("md0 : active raid5" in log2, "重启后 /proc/mdstat 里 md0 仍是 active raid5")
    ok("A92B4EFC" in log2.upper() or "a92b4efc" in log2, "超级块 magic 出现在 examine 输出里")

    print("\n%d passed, %d failed" % (pass_count, fail_count))
    raise SystemExit(0 if fail_count == 0 else 1)


if __name__ == "__main__":
    main()
