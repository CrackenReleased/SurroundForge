@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Bridge.ps1" -Action Restart
if errorlevel 1 pause
