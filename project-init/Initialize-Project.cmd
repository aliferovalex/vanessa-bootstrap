@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Initialize-Project.ps1" %*
exit /b %ERRORLEVEL%
