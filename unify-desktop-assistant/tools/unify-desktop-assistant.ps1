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

if (-not $Rest) { $Rest = @() }

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
    $installScript = Join-Path $toolsDir 'install.ps1'
    $argRest = if ($Rest.Count -gt 0) { ' ' + ($Rest -join ' ') } else { '' }

    if (-not (Test-IsAdmin)) {
      # Relaunch as admin
      $p = Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$installScript`"$argRest" `
        -WorkingDirectory $toolsDir `
        -Verb RunAs `
        -Wait -PassThru
      exit $p.ExitCode
    }

    & $installScript @Rest
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
