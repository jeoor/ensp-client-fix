@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title eNSP Client Fix

echo eNSP 客户端修复工具
echo 窗口拖动效果 / 剪贴板释放
echo.
echo 1. 检查状态
echo 2. 一次性修复（请先保存并退出 eNSP）
echo 3. 还原（需要本机备份）
echo 0. 退出
echo.
choice /c 1230 /n /m "请选择 [1/2/3/0]: "
set "selection=%errorlevel%"
if "%selection%"=="4" exit /b 0
set "mode="
if "%selection%"=="1" set "mode=Check"
if "%selection%"=="2" set "mode=Apply"
if "%selection%"=="3" set "mode=Restore"
if not defined mode exit /b 1
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-eNSP.ps1" -Mode "%mode%" %*
set "repairExit=%errorlevel%"
echo.
if not "%repairExit%"=="0" echo 操作未完成，请查看上方错误信息。
pause
exit /b %repairExit%
