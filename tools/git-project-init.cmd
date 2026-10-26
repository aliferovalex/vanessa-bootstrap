@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Initialize-ProjectGit.ps1" %*
exit /b %ERRORLEVEL%
