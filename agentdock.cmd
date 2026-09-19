@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem Parse the invocation and exit together before a child can update this file.
rem No CALL or nested CMD parsing: quoted repository paths remain intact.
(
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-entry.ps1" %*
  exit /b
)
