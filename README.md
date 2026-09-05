# Delin OS

适用于 **CC: Tweaked (ComputerCraft)** 的操作系统。目标：**在尽可能模仿 Linux 的同时不过度设计。**

## v0.0.1 — 协程调度内核 + PID 1

一个自持事件循环的**协程调度器**内核，引导后 spawn 出 **PID 1（init）** 作为第一个进程，
各进程跑在**隔离的 `_ENV`** 里，形成进程树。源码结构化放在 `src/`，经 `tools/bundle.lua`
打包成单个自包含 Lua 文件部署到磁盘 `/boot`。

### 设计要点

- **并发**：内核自持 `os.pullEventRaw` 循环，`coroutine.create/resume` + 按协程 yield 的
  filter 分发事件（与 `parallel` 同源，但由内核完全掌控任务生命周期）。
- **原始 API 直用**：任务体内直接用 `os.sleep`/`os.pullEvent`/`fs`…… 调度器驱动，不包 `ctx.sleep`。
- **隔离环境**：每个进程用自己的 `_ENV`（`load(src, name, "t", env)`）；`env` 里注入内核上下文
  `spawn`/`pid`/`ppid`/`print`，并通过 `__index = _G` 兜底原始 API。
- **`spawn` 只收源码字符串**：`spawn(src, name?)` 在独立 `_ENV` 里建子进程；要跑文件由程序
  自己用 `fs` 读、把内容当字符串传给 `spawn`。
- **进程树**：`{ pid, ppid, status, children }`；父死子并入 init。
- **print 覆盖**：内核自供 `print`（写日志 + 终端），因为 CC 自带 `print` 不走 `io.stdout`。
- **stdio 按进程隔离**：每个进程有自己的 `stdin/stdout`；spawn 时从父进程继承（或 boot 默认终端），
  `stdio.set` 只改当前进程。这样多个 tty 的 login 各自绑定自己的 tty，互不覆盖。
- **getty/login**：开机后 init 在每个 `/dev/ttyN` 上 spawn 一个 `login` 进程；login 提示用户名/密码
  （密码隐藏回显），验证通过后用该用户的 uid/gid spawn `sh`（同 tty stdio），`sh` 退出后回到 login 循环。
- **tty 焦点切换**：只有前台 tty 接收键盘。`Ctrl+Alt+1..0` 切换前台 tty，让多个 tty 共用一把键盘。

### 构建

```bash
lua5.1 tools/bundle.lua          # 生成 dist/delin-0.0.1.lua
```

产物复制到 CC 电脑磁盘 `/boot/delin-0.0.1.lua`，`/boot/.boot` 指向它，重启即引导。

## 约定

- 源码用 **EmmyLua** 注解仅为人类维护 / IDE 提示，不作为任何门禁；其警告与报错忽略。
- git 提交使用本仓库 local config。

## 目录

```
src/kernel/scheduler.lua   协程调度器(事件循环)
src/kernel/process.lua     进程表/pid/spawn(source)/隔离 env
src/kernel/boot.lua        入口: 日志→spawn PID1(init)→run
src/kernel/tty.lua         字符终端(/dev/ttyN): 行规程+回显+焦点切换
src/kernel/user.lua        用户库(/etc/passwd|shadow|group, salt+hash)
src/init/ext2_init.lua     EXT2 根引导的 PID 1: 在每个 tty spawn login
src/bin/sh                 交互/脚本 shell
src/bin/login              getty/login: 登录提示→验证→启动 sh→循环
tools/bundle.lua           打包 src/ → dist/delin-*.lua
dist/                      生成物(不提交)
```
