@echo off
rem Double-click launcher. Starts the installer script in Windows PowerShell for this run only.
rem No system setting is changed to allow it: the execution policy is bypassed for this one process.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-GpuUnlock.ps1" %*
