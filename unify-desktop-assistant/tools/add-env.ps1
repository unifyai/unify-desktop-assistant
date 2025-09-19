param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$Key,
  [Parameter(Mandatory=$true, Position=1)]
  [string]$Value
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$envPath = Join-Path $PSScriptRoot 'agent-service\.env'

# Ensure directory exists
$envDir = Split-Path -Parent $envPath
if (-not (Test-Path $envDir)) { New-Item -ItemType Directory -Force -Path $envDir | Out-Null }

$lines = @()
if (Test-Path $envPath) {
  $lines = Get-Content -LiteralPath $envPath -ErrorAction SilentlyContinue
}

$pattern = '^[\s]*' + [Regex]::Escape($Key) + '[\s]*='
$found = $false
$newLines = foreach ($line in $lines) {
  if ($line -match $pattern) {
    $found = $true
    "$Key=$Value"
  } else {
    $line
  }
}

if (-not $found) {
  $newLines += "$Key=$Value"
}

Set-Content -LiteralPath $envPath -Value $newLines -Encoding UTF8
Write-Host "Set $Key in .env"


