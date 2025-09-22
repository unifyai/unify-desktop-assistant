@echo off
REM Launch unify-desktop-assistant.ps1 with any passed arguments
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0unify-desktop-assistant.ps1" %*
