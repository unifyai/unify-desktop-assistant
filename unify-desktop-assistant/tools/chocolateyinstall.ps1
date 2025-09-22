$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host "Installing Unify Desktop Assistant..."

# Example: install files (replace with your real installer/archive)
# Install-ChocolateyZipPackage 'unify-desktop-assistant' 'https://example.com/archive.zip' $toolsDir

# Register the dispatcher (so `unify-desktop-assistant` works in PATH)
Install-BinFile -Name 'unify-desktop-assistant' -Path (Join-Path $toolsDir 'unify-desktop-assistant.cmd')

# Optionally run custom setup
# $installScript = Join-Path $toolsDir 'install.ps1'
# if (Test-Path $installScript) {
#     & $installScript
# }

Write-Host "Unify Desktop Assistant installation complete."
