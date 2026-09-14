@echo off
setlocal
set "ROOT=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\bootstrap-tunnel.ps1"
if errorlevel 1 exit /b %errorlevel%

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\windows.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

if "%EXITCODE%"=="0" exit /b 0

if /I "%~1"=="start" goto diagnostics
if /I "%~1"=="restart" goto diagnostics
if /I "%~1"=="apply" goto diagnostics
exit /b %EXITCODE%

:diagnostics
echo.
echo Startup failed. Collecting AgentDock diagnostics...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\windows.ps1" logs
exit /b %EXITCODE%
