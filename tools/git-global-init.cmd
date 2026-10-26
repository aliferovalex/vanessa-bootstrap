@echo off
rem Compatibility entry point: configure the current project, not global Git.
call "%~dp0git-project-init.cmd" %*
exit /b %ERRORLEVEL%
