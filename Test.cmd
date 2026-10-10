@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0surround\tests\Invoke-TestSuite.ps1" %*
exit /b %ERRORLEVEL%
