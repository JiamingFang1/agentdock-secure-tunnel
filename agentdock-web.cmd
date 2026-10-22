@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-web-manager.ps1"
if errorlevel 1 exit /b %errorlevel%
start "" "http://127.0.0.1:18880/"
exit /b 0
