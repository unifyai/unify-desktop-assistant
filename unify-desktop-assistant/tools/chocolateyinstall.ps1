$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Unblock all shipped scripts/binaries
Get-ChildItem $toolsDir -Recurse -Include *.ps1,*.psm1,*.cmd,*.exe,*.dll -ErrorAction SilentlyContinue | ForEach-Object {
  try { Unblock-File -Path $_.FullName } catch {}
}

# Create PATH shim for the dispatcher via a cmd wrapper for reliability
Install-BinFile -Name 'unify-desktop-assistant' -Path (Join-Path $toolsDir 'unify-desktop-assistant.cmd')


