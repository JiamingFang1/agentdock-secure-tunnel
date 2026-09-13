@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1
if errorlevel 1 exit /b %errorlevel%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\windows.ps1 %*
