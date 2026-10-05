@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0stalzone-server-blocker.ps1" -Command gui
endlocal
