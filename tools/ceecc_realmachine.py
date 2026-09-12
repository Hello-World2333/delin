#!/usr/bin/env python3
"""Delin CEECC(台式 CEE:CC 电脑)真机验证 —— 目标机 **电脑 #6**。

电脑 #3 留给普通 CC 的验证(tools/realmachine.py), 这台专门验 CEECC 平台:
  * 平台探测(kernel/platform.lua -> 引导日志 "platform=cee (CEE:CC, N signal pins)")
  * /sys/class/power/supply 的电力属性(modules/cee.ko)
  * /sys/class/pin/pinN 的引脚/端口属性, 含"无端口引脚没有端口属性"这条真机契约
  * 红石、块设备(含电缆网络上的远端磁盘)与挂载的回归

流程(与 tools/realmachine.py 同一套约束):
  0. **先关机** —— 往电脑自身 FS 写文件必须在停机状态下进行
  1. 重新打包(dist/: kernel.lua + payload + 发布树)
  2. 在电脑 #6 自身存储上做一次**干净**的 CCFS 根安装: 清空旧文件 -> 铺 payload ->
     Delin BIOS 到 /startup.lua -> /.boot = /boot/delin.lua; 注入 /root/ceecc_verify.sh
     (scripts/ceecc_verify.sh)与 ceecc.service(oneshot, WantedBy=multi-user.target)
  3. 开机 -> 引导门禁(本轮 /var/log/ceecc.log 必须是新写的且以 "done" 收尾) -> 读回日志
  4. 逐项断言: 脚本只负责把事实记成 KEY=VALUE, 判据全在这里

用法: python3 tools/ceecc_realmachine.py [--no-reboot] [--timeout 180]
"""
import os, shutil, subprocess, sys, time

REPO = "/home/worker/delin"
COMPUTER = "/mnt/computer/6"
COMPUTER_ID = 6
RCON = os.path.expanduser("~/docs/tools/rcon.py")
DONE_MARK = "=== ceecc verify done ==="
LOG_REL = "var/log/ceecc.log"
SKELETON = ["bin", "boot", "dev", "etc", "etc/systemd/system", "etc/systemd/system/multi-user.target.wants",
            "home", "home/alice", "lib", "lib/modules", "lib/systemd/system", "mnt", "proc", "root",
            "run", "sys", "tmp", "var", "var/log"]

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


def install():
    """在电脑 #6 自身存储上做一次干净的 CCFS 根安装(磁盘上的盘不参与)。"""
    print("== install: CCFS root on computer #%d's own storage ==" % COMPUTER_ID)
    if os.path.isdir(COMPUTER):
        for entry in os.listdir(COMPUTER):
            path = os.path.join(COMPUTER, entry)
            shutil.rmtree(path) if os.path.isdir(path) else os.unlink(path)
    for d in SKELETON:
        os.makedirs(os.path.join(COMPUTER, d), exist_ok=True)

    # 直接铺 dist/(不是 dist/release/*/payload): 后者只在 --release 时重建, 拿它装机
    # 会静默装上上一轮的产物(第一次跑真机验证就栽在这: 内核是旧的, 没有 platform 行)。
    dist = os.path.join(REPO, "dist")
    for sub, dst in (("bin", "bin"), ("etc", "etc"), ("units", "lib/systemd/system"),
                     ("modules/" + VERSION, "lib/modules/" + VERSION)):
        src = os.path.join(dist, sub)
        if not os.path.isdir(src):
            raise RuntimeError("no %s in dist/ (run lua5.1 tools/build.lua)" % sub)
        shutil.copytree(src, os.path.join(COMPUTER, dst), dirs_exist_ok=True)
    shutil.copy(os.path.join(dist, "kernel.lua"), os.path.join(COMPUTER, "boot/delin.lua"))
    shutil.copy(os.path.join(dist, "dlub.lua"), os.path.join(COMPUTER, "boot/dlub.lua"))
    shutil.copy(os.path.join(REPO, "dist/bios/startup.lua"), os.path.join(COMPUTER, "startup.lua"))
    with open(os.path.join(COMPUTER, ".boot"), "w") as f:
        f.write("/boot/delin.lua")

    shutil.copy(os.path.join(REPO, "scripts/ceecc_verify.lua"), os.path.join(COMPUTER, "root/ceecc_verify.lua"))
    with open(os.path.join(COMPUTER, "lib/systemd/system/ceecc.service"), "w") as f:
        f.write("[Unit]\nDescription=Delin CEECC verification\nAfter=syslogd.service\n\n"
                "[Service]\nType=oneshot\nTimeoutStartSec=600\nExecStart=/bin/lua /root/ceecc_verify.lua\n\n"
                "[Install]\nWantedBy=multi-user.target\n")
    open(os.path.join(COMPUTER, "etc/systemd/system/multi-user.target.wants/ceecc.service"), "w").close()
    run("sync")
    time.sleep(4)  # NFS 写入有延迟


def read_log():
    path = os.path.join(COMPUTER, LOG_REL)
    if not os.path.exists(path):
        return None
    with open(path, "r", errors="replace") as f:
        return f.read()


def boot_and_collect(timeout):
    deploy_ms = time.time()
    print("== boot computer #%d ==" % COMPUTER_ID)
    run("python3", RCON, "computercraft turn-on #%d" % COMPUTER_ID, check=False)
    deadline = time.time() + timeout
    log = None
    while time.time() < deadline:
        time.sleep(5)
        text = read_log()
        if text and DONE_MARK in text:
            log = text
            break
    if log is None:
        text = read_log() or "(no /var/log/ceecc.log at all)"
        print("引导/自检超时(%ds)。当前日志:\n%s" % (timeout, text[-4000:]))
        return None
    # 引导门禁: 同一份日志可能来自上一轮 —— 内核开机日志必须是本轮写的。
    delin_log = os.path.join(COMPUTER, "delin.log")
    fresh = os.path.exists(delin_log) and os.path.getmtime(delin_log) >= deploy_ms - 5
    boot = open(delin_log, "r", errors="replace").read() if os.path.exists(delin_log) else ""
    if not fresh or "init up" not in boot:
        print("引导门禁失败: delin.log fresh=%s, 含 init up=%s" % (fresh, "init up" in boot))
        print(boot[-2000:])
        return None
    print("   boot gate ok (/delin.log 本轮新写且 init up)")
    return log, boot


def fields(log):
    out = {}
    for line in log.splitlines():
        if "=" in line and not line.startswith("--") and not line.startswith(" "):
            k, v = line.split("=", 1)
            if " " not in k:
                out[k] = v
    return out


def pins(log):
    """把 "pin pinN data=.. ports=.. .." 行解析成 {name: {字段}}。"""
    out = {}
    for line in log.splitlines():
        if line.startswith("pin pin"):
            parts = line.split()
            name = parts[1]
            d = {}
            for p in parts[2:]:
                if "=" in p:
                    k, v = p.split("=", 1)
                    d[k] = v
            out[name] = d
    return out


def attrs_of(value):
    return [a for a in value.split(",") if a]


def check(log, boot):
    f = fields(log)
    print("== checks ==")

    # 1) 平台探测
    ok("platform=cee (CEE:CC, " in boot, "引导日志里有 platform=cee", boot.splitlines()[:4])
    ok("cee: /sys/class/power/supply + /sys/class/pin registered" in boot,
       "内核日志里有 cee 模块的注册行", boot[-400:])
    eq(f.get("sysfs_power_entries"), "1", "power 类只有 supply 一个条目")
    ok(int(f.get("sysfs_pin_entries", "0")) >= 1, "pin 类按 getSignalCount 列出引脚",
       f.get("sysfs_pin_entries"))

    # 2) 电力(真机实测: 台式自持馈电, max 500W, state=ok)
    want = ["present", "voltage", "current", "power", "max_power", "headroom", "state", "reset"]
    got = attrs_of(f.get("power_supply_attrs", ""))
    ok(sorted(got) == sorted(want), "power/supply 属性清单", got)
    eq(f.get("power_present"), "1", "present=hasPower=1")
    ok(f.get("power_state", "") != "", "state 非空", f.get("power_state"))
    ok(f.get("power_max_power", "").isdigit() and int(f["power_max_power"]) > 0, "max_power 是正整数",
       f.get("power_max_power"))
    ok(f.get("power_voltage", "") != "" and f.get("power_voltage") != "0", "voltage 非 0", f.get("power_voltage"))
    eq(f.get("power_reset_rc"), "0", "写 reset=1 成功(只写属性)")
    ok(f.get("power_voltage_write_rc") != "0", "写只读属性 voltage 失败(fail-fast)",
       f.get("power_voltage_write_rc"))

    # 3) 引脚: 每个引脚都有的 5 个只读属性
    pin_map = pins(log)
    n = int(f.get("sysfs_pin_entries", "0"))
    eq(len(pin_map), n, "每个引脚一行记录")
    for name, d in sorted(pin_map.items()):
        a = attrs_of(d.get("attrs", ""))
        base = [x for x in ["data", "ports", "powered", "peripheral", "peripheral_type"] if x not in a]
        ok(base == [], "引脚 %s 有全部只读属性" % name, a)

    # 4) 有端口的引脚: 三个端口属性 + 写入落到端口 + 越界写不改状态
    port_pin = f.get("port_pin", "")
    ok(port_pin != "", "机器上至少有一个带端口的引脚", port_pin)
    if port_pin:
        a = attrs_of(pins(log)[os.path.basename(port_pin)].get("attrs", ""))
        ok(all(x in a for x in ["analog_in", "analog_out", "digital_out"]), "端口引脚有三个端口属性", a)
        eq(f.get("port_pin_write_rc"), "0", "写 analog_out=7 成功")
        eq(f.get("port_pin_analog_out_after"), "7", "analog_out 读回 7(落到 setAnalog)")
        ok(f.get("port_pin_bad_write_rc") != "0", "写 analog_out=16 失败(越界 fail-fast)",
           f.get("port_pin_bad_write_rc"))
        eq(f.get("port_pin_analog_out_after_bad"), "7", "越界写没有改动端口状态")
        eq(f.get("port_pin_analog_out_restored"), "0", "端口已复位到 0")

    # 5) 无端口的引脚: 三个端口属性必须不存在(真机上 cee 的 getAnalogOutput 会报 no signal port)
    portless = f.get("portless_pin", "")
    ok(portless != "", "机器上至少有一个不带端口的引脚", portless)
    if portless:
        a = attrs_of(pins(log)[os.path.basename(portless)].get("attrs", ""))
        ok(not any(x in a for x in ["analog_in", "analog_out", "digital_out"]),
           "无端口引脚没有端口属性", a)
        ok(f.get("portless_analog_in_rc") != "0", "无端口引脚读 analog_in 是错误(属性不存在)",
           f.get("portless_analog_in_rc"))

    # 6) 越界引脚
    ok(f.get("pin999_rc") != "0", "越界引脚 pin999 不存在", f.get("pin999_rc"))

    # 7) 回归: 红石、块设备、挂载
    sides = attrs_of(f.get("redstone_sides", ""))
    eq(len(sides), 6, "红石仍是六个面")
    eq(f.get("redstone_write_rc"), "0", "红石写仍可用")
    ok("/dev/sda / ccdisk" in log, "自带存储挂在 / 上(/proc/mounts)")
    ok("sda" in log and "disk" in log, "lsblk 列出了块设备")


VERSION = None


def main():
    global VERSION
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-reboot", action="store_true", help="只装机不重启")
    ap.add_argument("--timeout", type=int, default=180, help="等开机+自检的秒数")
    args = ap.parse_args()

    sys.path.insert(0, os.path.join(REPO, "tools"))
    print("== build ==")
    print(run("lua5.1", os.path.join(REPO, "tools/build.lua"), cwd=REPO))
    import re
    VERSION = re.search(r'"(\d+\.\d+\.\d+)"',
                        open(os.path.join(REPO, "src/kernel/version.lua")).read()).group(1)

    if not shutdown_computer():
        raise SystemExit("computer #%d 停不下来, 拒绝在运行中写它的文件系统" % COMPUTER_ID)
    install()
    if args.no_reboot:
        print("--no-reboot: 已装机, 未开机")
        return
    got = boot_and_collect(args.timeout)
    if got is None:
        raise SystemExit("真机验证失败: 没有拿到本轮的 /var/log/ceecc.log")
    log, boot = got
    print("---- /var/log/ceecc.log ----")
    print(log)
    check(log, boot)
    print("\n%d passed, %d failed" % (pass_count, fail_count))
    raise SystemExit(0 if fail_count == 0 else 1)


if __name__ == "__main__":
    main()
