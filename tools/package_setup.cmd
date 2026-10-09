@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0package_setup.ps1" %*
pause
