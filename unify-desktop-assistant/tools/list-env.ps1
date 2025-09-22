Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$envPath = Join-Path $PSScriptRoot 'agent-service\.env'
if (-not (Test-Path $envPath)) { return }

$content = @(Get-Content -LiteralPath $envPath -ErrorAction SilentlyContinue)
foreach ($line in $content) {
  if ($line -match '^[\s]*[^#\s][^=\s]*\s*=') {
    $key = ($line -split '=',2)[0].Trim()
    if (-not [string]::IsNullOrWhiteSpace($key)) { Write-Host $key }
  }
}


