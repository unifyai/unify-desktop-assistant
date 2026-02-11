' Unify Desktop Assistant Launcher
' 
' This VBScript runs the PowerShell GUI application hidden (no console window).
' Used by the Windows installer to launch the tray app silently.

Set objShell = CreateObject("WScript.Shell")
strPath = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
strScript = strPath & "gui\UnifyAssistant.ps1"
strCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strScript & """"
objShell.Run strCommand, 0, False
