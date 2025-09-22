param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$Key,
  [Parameter(Mandatory=$true, Position=1, ValueFromRemainingArguments=$true)]
  [string[]]$Value
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Value = $Value -join ' '

$envPath = Join-Path $PSScriptRoot 'agent-service\.env'

# Ensure directory exists
$envDir = Split-Path -Parent $envPath
if (-not (Test-Path $envDir)) { New-Item -ItemType Directory -Force -Path $envDir | Out-Null }

$lines = @()
if (Test-Path $envPath) {
  $lines = @(Get-Content -LiteralPath $envPath -ErrorAction SilentlyContinue)
}

# Prepare value for .env (quote if contains spaces/special chars so bash source works)
$safeRe = '^[A-Za-z0-9_./:-]+$'
if ($Value -match $safeRe) {
  $outValue = $Value
} else {
  $esc = $Value -replace '\\','\\\\'
  $esc = $esc -replace '"','\\"'
  $esc = $esc -replace '\$','\\$'
  $esc = $esc -replace '`','\\`'
  $outValue = '"' + $esc + '"'
}


$pattern = '^[\s]*' + [Regex]::Escape($Key) + '[\s]*='
$found = $false
$newLines = New-Object System.Collections.Generic.List[string]
foreach ($line in $lines) {
  if ($line -match $pattern) {
    $newLines.Add("$Key=$outValue")
    $found = $true
  } else {
    $newLines.Add($line)
  }
}
if (-not $found) {
  $newLines.Add("$Key=$outValue")
}

Set-Content -LiteralPath $envPath -Value $newLines -Encoding UTF8
Write-Host "Set $Key in .env"

# Compute Windows-style key (KEY_KEY -> KeyKey)
$windowsKey = (
  ($Key -split '[_\s]+') |
    ForEach-Object {
      if ([string]::IsNullOrWhiteSpace($_)) { '' }
      else { $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower() }
    }
) -join ''

# Persist to user environment so new shells see it (Windows-style key only)
try {
  [Environment]::SetEnvironmentVariable($windowsKey, $Value, 'User')
  Write-Host "Set user environment variable $windowsKey"
} catch {
  Write-Warning "Failed to set user environment variable ${windowsKey}: $($_.Exception.Message)"
}

# Also set for current process so subsequent commands in this session can read it (Windows-style key only)
Set-Item -Path "Env:$windowsKey" -Value $Value
