--[[ Delin 版本号唯一真源。
     这个字符串同时是 **内核模块 ABI 版本**: /lib/modules/<version>/ 的目录名,
     因此改动它等于改动模块目录, 部署侧 (tools/deploy.py) 与测试 (tools/harness.lua,
     tools/hosttest.lua) 都从这里取, 不再各自写字面量。
     BIOS (src/bios/startup.lua) 是 CraftOS 程序, 不能 require; 它保留字面量,
     而且**版本号独立** —— BIOS 是独立启动器, 虽然属于 Delin 项目, 但不跟内核版本走,
     因此 build 不做、也不该做两者的版本一致性门禁。 ]]

return "0.0.3"
