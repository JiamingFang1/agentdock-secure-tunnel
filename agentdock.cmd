@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ERRORLEVEL="
rem Parse the invocation and exit together before a child can update this file.
rem Only the numeric exit code is expanded twice; paths and arguments are not.
(
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-entry.ps1" %*
  call exit /b %%errorlevel%%
)
