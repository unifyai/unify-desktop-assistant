Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$envPath = Join-Path $PSScriptRoot 'agent-service\.env'
if (-not (Test-Path $envPath)) { return }

Get-Content -LiteralPath $envPath |
  Where-Object { $_ -match '^[\s]*[^#\s][^=\s]*\s*=' } |
  ForEach-Object {
    ($_ -split '=',2)[0].Trim()
  } |
  Sort-Object -Unique |
  ForEach-Object { Write-Host $_ }


