param(
    [Parameter(Position = 0, Mandatory = $false)]
    [string] $Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $Args
)

$ErrorActionPreference = 'Stop'
$toolsDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptName = "unify-desktop-assistant"

if (-not $Command) {
    Write-Host "Usage: $scriptName <command> [args...]"
    Write-Host ""
    Write-Host "Available commands:"
    Write-Host "  install     - Run installation script"
    Write-Host "  start       - Start remote assistant"
    Write-Host "  tunnel      - Start tunnel script"
    Write-Host "  liveview    - Launch live view"
    Write-Host "  add-env     - Add environment variable (key, value)"
    Write-Host "  list-env    - List environment variables"
    Write-Host "  remove-env  - Remove environment variable (key)"
    exit 0
}

switch ($Command) {
    'install' {
        $installScript = Join-Path $toolsDir 'install.ps1'
        Write-Host "Running installer: $installScript"
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript
    }
    'start' {
        Push-Location $toolsDir
        try {
            & (Join-Path $toolsDir 'remote.ps1')
        } finally {
            Pop-Location
        }
    }
    'tunnel' {
        & (Join-Path $toolsDir 'tunnel.ps1')
    }
    'liveview' {
        & (Join-Path $toolsDir 'liveview.ps1')
    }
    'add-env' {
        if ($Args.Count -lt 2) {
            Write-Host "Usage: $scriptName add-env <KEY> <VALUE>"
            exit 1
        }
        & (Join-Path $toolsDir 'add-env.ps1') -Key $Args[0] -Value ($Args[1..($Args.Count-1)] -join ' ')
    }
    'list-env' {
        & (Join-Path $toolsDir 'list-env.ps1')
    }
    'remove-env' {
        if ($Args.Count -lt 1) {
            Write-Host "Usage: $scriptName remove-env <KEY>"
            exit 1
        }
        & (Join-Path $toolsDir 'remove-env.ps1') -Key $Args[0]
    }
    default {
        Write-Host "Unknown command: $Command"
        exit 1
    }
}
