$toolsDir   = "$(Split-Path -Parent $MyInvocation.MyCommand.Definition)"
$mainScript = Join-Path $toolsDir 'unify-desktop-assistant.ps1'

# Ensure the dispatcher exists
if (!(Test-Path $mainScript)) {
    throw "Dispatcher script unify-desktop-assistant.ps1 not found in tools directory."
}

# Create batch shim for Chocolatey to place in PATH
$shimPath = Join-Path $toolsDir 'unify-desktop-assistant.bat'
$shim = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%mainScript%" %*
"@

Set-Content -Path $shimPath -Value $shim -Encoding ASCII
