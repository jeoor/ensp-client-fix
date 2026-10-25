@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title eNSP Client Fix
echo eNSP 窗口拖动与剪贴板修复
echo 请先保存实验并退出 eNSP。
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-eNSP.ps1" -Mode Apply %*
set "repairExit=%errorlevel%"
echo.
if not "%repairExit%"=="0" echo 操作未完成，请查看上方错误信息。
pause
exit /b %repairExit%
