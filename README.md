# Delin OS

适用于 **CC: Tweaked (ComputerCraft)** 的Unix-like操作系统。致力于让Linux用户无痛迁移。

## 安装

在CC电脑上运行此命令即可安装:
```
wget run https://raw.githubusercontent.com/Hello-World2333/delin/refs/heads/release/0.0.2/install.lua
```
推荐使用ext2安装，因为Delin在CCFS上不支持文件权限。  
安装后使用用户名root和密码12345678登录。

## demo

在Delin OS上，你可以使用sh的语法来编写脚本，下面这个脚本创建了一个交互式环境:
```sh
#!/bin/sh
echo "Welcome"
while true; do
    echo -n "> "
    read CMD
    if [ "$CMD" = "q" ]; then break; fi
    echo "$CMD" > /sys/class/redstone/top/analog
    echo ok
done
```
要运行这个脚本，请把它保存为redstone.sh，然后`chmod +x redstone.sh && ./redstone.sh`。进入交互环境后，输入0-15的整数改变电脑top面的红石输出，输入q退出。