param(
  [Parameter(Position=0)]
  [ValidateSet('install','start','tunnel','liveview')]
  [string]$Command,
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Rest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolsDir = $PSScriptRoot

function Test-IsAdmin {
  $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
  $wp = [Security.Principal.WindowsPrincipal] $wi
  return $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $Command) {
  Write-Host "Usage: unify-desktop-assistant <install|start|tunnel|liveview> [args...]"
  exit 1
}

switch ($Command) {
  'install' {
    if (-not (Test-IsAdmin)) {
      $cmd = 'unify-desktop-assistant install'
      if ($Rest -and $Rest.Count -gt 0) { $cmd = $cmd + ' ' + ($Rest -join ' ') }
      Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command $cmd" -Verb RunAs -Wait
      exit $LASTEXITCODE
    }
    & (Join-Path $toolsDir 'install.ps1') @Rest
  }
  'start' {
    Push-Location $toolsDir
    try { & (Join-Path $toolsDir 'remote.ps1') @Rest } finally { Pop-Location }
  }
  'tunnel' {
    & (Join-Path $toolsDir 'tunnel.ps1') @Rest
  }
  'liveview' {
    & (Join-Path $toolsDir 'liveview.ps1') @Rest
  }
  default {
    Write-Host "Unknown command: $Command"
    exit 1
  }
}




