param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$Key
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$envPath = Join-Path $PSScriptRoot 'agent-service\.env'
if (-not (Test-Path $envPath)) { return }

$lines = Get-Content -LiteralPath $envPath -ErrorAction SilentlyContinue
$pattern = '^[\s]*' + [Regex]::Escape($Key) + '[\s]*='

$newLines = $lines | Where-Object { $_ -notmatch $pattern }

Set-Content -LiteralPath $envPath -Value $newLines -Encoding UTF8
Write-Host "Removed $Key from .env (if present)"


