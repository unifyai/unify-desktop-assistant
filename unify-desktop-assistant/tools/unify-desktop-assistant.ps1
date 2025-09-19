param(
  [Parameter(Position=0)]
  [ValidateSet('install','start','tunnel','liveview','add-env','list-env','remove-env')]
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
  Write-Host "Usage: unify-desktop-assistant <install|start|tunnel|liveview|add-env|list-env|remove-env> [args...]"
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
  'add-env' {
    if ($Rest.Count -lt 2) { Write-Host "Usage: unify-desktop-assistant add-env <KEY> <VALUE>"; exit 1 }
    & (Join-Path $toolsDir 'add-env.ps1') -Key $Rest[0] -Value ($Rest[1..($Rest.Count-1)] -join ' ')
  }
  'list-env' {
    & (Join-Path $toolsDir 'list-env.ps1')
  }
  'remove-env' {
    if ($Rest.Count -lt 1) { Write-Host "Usage: unify-desktop-assistant remove-env <KEY>"; exit 1 }
    & (Join-Path $toolsDir 'remove-env.ps1') -Key $Rest[0]
  }
  default {
    Write-Host "Unknown command: $Command"
    exit 1
  }
}




