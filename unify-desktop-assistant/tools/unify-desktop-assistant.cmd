@echo off
setlocal
set PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\pwsh.exe" set PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\pwsh.exe

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0unify-desktop-assistant.ps1" %*
exit /b %ERRORLEVEL%


