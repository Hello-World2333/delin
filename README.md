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
src/init/init.lua          PID 1 程序
tools/bundle.lua           打包 src/ → dist/delin-*.lua
dist/                      生成物(不提交)
```
