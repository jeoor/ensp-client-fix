@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title eNSP Client Fix
echo eNSP 客户端状态检查
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-eNSP.ps1" -Mode Check -HumanReadable %*
set "repairExit=%errorlevel%"
echo.
if not "%repairExit%"=="0" echo 检查未完成，请查看上方错误信息。
echo 按任意键关闭窗口。
pause >nul
exit /b %repairExit%
