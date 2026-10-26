@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0project-init\Initialize-Project.ps1" -TemplateDirectory "%~dp0." %*
exit /b %ERRORLEVEL%
