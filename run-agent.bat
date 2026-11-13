@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-agent.ps1" %*
exit /b %ERRORLEVEL%
