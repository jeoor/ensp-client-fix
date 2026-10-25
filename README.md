# eNSP Client Fix

一次性修复旧版 eNSP 的窗口拖动效果和剪贴板释放问题。修复后使用原来的 eNSP 快捷方式即可。

- **窗口拖动效果**：保留 Windows“拖动时显示窗口内容”的设置。
- **剪贴板释放**：读取文本失败时也释放剪贴板，避免其他软件持续无法复制粘贴。

## 快速使用

1. 下载源码并完整解压，保存实验、退出 eNSP。
2. 双击 **启动.bat**，选择检查、修复或还原。
3. 修复执行一次即可；写程序目录时会请求 Windows 管理员权限。
4. 保留工具目录下的 backups/，供还原使用。

也可以使用 Windows 自带的 PowerShell：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Repair-eNSP.ps1" -Mode Check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Repair-eNSP.ps1" -Mode Apply
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Repair-eNSP.ps1" -Mode Restore
~~~

默认操作两项修复。单独处理一项时，使用 -Fix：

~~~powershell
.\Repair-eNSP.ps1 -Mode Apply -Fix Clipboard
.\Repair-eNSP.ps1 -Mode Restore -Fix Clipboard
.\Repair-eNSP.ps1 -Mode Apply -Fix VisualEffects
~~~

脚本自动读取安装信息和桌面快捷方式。无法定位或存在多个安装时，指定程序或安装目录：

~~~powershell
.\Repair-eNSP.ps1 -Mode Apply -EnspPath 'E:\教学 软件\eNSP'
~~~

## 支持范围

使用 Windows PowerShell 5.1 和系统自带 .NET，面向 Windows 10/11。不同系统版本并未全部实机测试。

当前支持经过核对的 **eNSP 1.3.00.100** 客户端，文件大小为 3,547,136 字节。版本号相同但文件哈希不同也会拒绝修改。

| 状态 | SHA256 |
|---|---|
| 原版 | e2cdd4c77eaca23fbc84c9e466e6847988cc42a349df3ede0b65c1c1f8080b7e |
| 窗口拖动修复 | 8bf1ad0d35310905020b20f0ffef419e34f685c90666162de762006df176d20f |
| 剪贴板修复 | e567ddfabd65000b440211dd5e5a3b149b36e766c7619daaf0fdcd0ea65e230b |
| 两项均修复 | 50e64999d0f3e9937fb8131066dd22615eda90c64b7bbdd64d5b4b937d2e4ed7 |

## 修改原理

| 修复 | 文件偏移 | 字节修改 | 作用 |
|---|---|---|---|
| 窗口拖动 | 0x3BE2B | 74 → EB | 跳过启动时关闭完整窗口拖动的调用 |
| 剪贴板 | 0xD5A90 | B6 → 7A | 读取文本失败后，先执行 CloseClipboard 再返回 |

剪贴板缺陷位于文本粘贴路径：OpenClipboard 成功后，如果 GetClipboardData(CF_TEXT) 返回空句柄，原分支直接退出，跳过 CloseClipboard。复制图片、文件等内容后粘贴，可能触发这个分支。

修改前检查完整文件哈希和周围指令，写入时获取独占句柄，写后再次核对完整哈希。失败时尝试恢复原字节并校验。两项修复可以分别应用和还原。

## 备份与还原

首次修复会在工具目录的 backups/ 下保存经过校验的原版文件，按电脑和安装路径分开存放。
还原时使用同一份工具并保留对应备份。单独还原一项时保留另一项的状态。

## 验证

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\tests\Test-Repair.ps1"
~~~

默认测试语法和未知文件拒绝机制。使用本机原版文件可运行完整测试：

~~~powershell
.\tests\Test-Repair.ps1 -OriginalFile '完整路径\eNSP_Client.original.exe'
~~~

完整测试覆盖四种文件状态与三种修复选择、重复执行、只读检查、损坏备份和文件占用，并解码实际跳转目标，验证剪贴板读取失败路径会到达 CloseClipboard。

测试使用临时副本。剪贴板修改已完成静态分支校验，实际 GUI 故障的复测仍需在 eNSP 中进行。

## 来源与许可

窗口拖动修补原理参考 [Yish：禁止华为 ENSP 启动时关闭 Windows 窗口动画](https://cmxz.top/2541/)。
剪贴板释放缺陷由本项目对客户端粘贴路径的反汇编定位。Windows 剪贴板调用约定见 [Microsoft：OpenClipboard](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-openclipboard)。

脚本采用 [MIT License](LICENSE)。项目仅分发脚本、BAT 入口、测试和文档；eNSP 程序文件由使用者自行安装。
