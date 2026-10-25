# eNSP Window Drag Fix

一次性修补旧版 eNSP 启动时关闭 Windows“拖动时显示窗口内容”的行为。修复后仍使用原来的 eNSP 快捷方式，无需常驻程序或每次运行脚本。

本项目只分发自行编写的 PowerShell 脚本、BAT 入口和文档，不包含华为 eNSP、Oracle VirtualBox、修改版 EXE 或 DLL。

## 快速使用

1. 下载仓库源码并完整解压，先保存实验、关闭 eNSP。
2. 双击 **启动.bat**，选择“检查”“修复”或“还原”。
3. “修复”只需执行一次；写程序目录时会请求 Windows 管理员权限。
4. “还原”需要保留本机生成的 backups 目录。

启动.bat 打开的是修复工具菜单。修复完成后，正常启动 eNSP 即可。

也可使用 Windows 自带的 PowerShell：
~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Repair-eNSP-VisualEffects.ps1" -Mode Check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Repair-eNSP-VisualEffects.ps1" -Mode Apply
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Repair-eNSP-VisualEffects.ps1" -Mode Restore
~~~

自动检测会读取当前用户/整机的 32 位、64 位卸载注册表，并检查默认安装目录和桌面快捷方式。
无法定位或存在多个安装时，手动指定程序或安装目录：
~~~powershell
.\Repair-eNSP-VisualEffects.ps1 -Mode Apply -EnspPath 'E:\教学 软件\eNSP'
~~~

ExecutionPolicy Bypass 只对该次 PowerShell 进程生效，不更改系统的永久执行策略。

## 支持范围

- Windows PowerShell 5.1，使用系统自带 .NET；无需 Python、编译器或额外运行库。
- 面向 Windows 10/11。不同 Windows 版本并未全部实机测试。
- 当前仅接受下列经核对的 eNSP 1.3.00.100 客户端构建；版本号相同但文件哈希不同也会拒绝修改。
- 支持中文、空格及不同安装盘符；跨电脑只需复制脚本及可选的 BAT 入口。
- Check 只读；重复 Apply/Restore 会识别目标状态并跳过；不会强制结束 eNSP。

| 文件状态 | SHA256 |
|---|---|
| 原文件 | e2cdd4c77eaca23fbc84c9e466e6847988cc42a349df3ede0b65c1c1f8080b7e |
| 修复后 | 8bf1ad0d35310905020b20f0ffef419e34f685c90666162de762006df176d20f |

## 修改内容

将已验证客户端的文件偏移 0x3BE2B 处从 74 改为 EB，即把条件跳转改为无条件跳转，跳过关闭 SPI_SETDRAGFULLWINDOWS 的代码。只改变这一个字节。

修改前检查完整文件哈希和周围指令，写入时获取独占句柄，写后再次核对完整哈希。失败时尝试恢复原字节并校验；原文件备份用于人工恢复。

该补丁只针对窗口拖动实时显示，不修改其他视觉设置、WSL、Hyper-V、VirtualBox 或其兼容层，也不修复 AR 设备启动失败。

## 本机数据与分发

运行后可能生成：
- backups/：按电脑和安装路径分开的原文件备份；
- logs/：提权子进程失败时的错误信息；
- repair-*.json：修复或还原记录。

这些目录和记录均被 .gitignore 排除。EXE、DLL、ZIP 和临时文件也被忽略。
不要将本机生成的备份或日志加入提交；它们可能包含程序文件、电脑名称和安装路径。
已经修复但丢失原文件备份时，脚本会拒绝还原。

## 测试

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\tests\Test-Repair.ps1"
~~~

默认测试语法和未知文件拒绝机制，不需要 eNSP。可使用自己合法安装版本的原文件进行完整往返测试：
~~~powershell
.\tests\Test-Repair.ps1 -OriginalFile '完整路径\eNSP_Client.original.exe'
~~~

测试副本只写入系统临时目录，结束后清理，不修改实际安装。仓库和 CI 不提供该程序文件。
本地已验证：原文件修补与还原、重复执行、中文/空格路径、未知版本及损坏备份拒绝；实际 eNSP 启动后窗口拖动效果保持开启。

## 来源与许可

修补原理和问题分析参考 [Yish：禁止华为 ENSP 启动时关闭 Windows 窗口动画](https://cmxz.top/2541/)。
该原理并非本项目首创，本仓库提供独立实现的一次性自动修补、检查和还原工具。

原创脚本采用 [MIT License](LICENSE)。eNSP、VirtualBox 及相关名称属于各自权利人；本项目不是其官方产品，也不分发其程序文件。
