$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host "Uninstalling Unify Desktop Assistant..."

# Remove the PATH shim
Uninstall-BinFile -Name 'unify-desktop-assistant'

# Optional: cleanup installed files
# Remove-Item -Recurse -Force $toolsDir

Write-Host "Unify Desktop Assistant uninstalled."
