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
    Write-Host "Commands:"
    Write-Host "  setup     - Install and start all services"
    Write-Host "              Usage: $scriptName setup -UnifyKey <key> [-OrchestraUrl <url>] [-Force]"
    Write-Host "  stop      - Stop all services"
    Write-Host "  tunnel    - Start Cloudflare tunnel for Agent API (port 3000)"
    Write-Host "  liveview  - Start Cloudflare tunnel for VNC viewer (port 6080)"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  $scriptName setup -UnifyKey sk-xxx"
    Write-Host "  $scriptName stop"
    Write-Host "  $scriptName tunnel"
    exit 0
}

switch ($Command) {
    'setup' {
        $setupScript = Join-Path $toolsDir 'setup.ps1'
        $setupArgs = @()
        
        # Parse args for setup
        for ($i = 0; $i -lt $Args.Count; $i++) {
            $arg = $Args[$i]
            if ($arg -eq '-UnifyKey' -and ($i + 1) -lt $Args.Count) {
                $setupArgs += "-UnifyKey"
                $setupArgs += $Args[$i + 1]
                $i++
            } elseif ($arg -eq '-OrchestraUrl' -and ($i + 1) -lt $Args.Count) {
                $setupArgs += "-OrchestraUrl"
                $setupArgs += $Args[$i + 1]
                $i++
            } elseif ($arg -eq '-Force') {
                $setupArgs += "-Force"
            }
        }
        
        if ($setupArgs.Count -eq 0) {
            Write-Host "Usage: $scriptName setup -UnifyKey <your-key> [-OrchestraUrl <url>] [-Force]"
            Write-Host ""
            Write-Host "Example:"
            Write-Host "  $scriptName setup -UnifyKey sk-xxx"
            exit 1
        }
        
        & $setupScript @setupArgs
    }
    'stop' {
        $setupScript = Join-Path $toolsDir 'setup.ps1'
        & $setupScript -Stop
    }
    'tunnel' {
        & (Join-Path $toolsDir 'tunnel.ps1')
    }
    'liveview' {
        & (Join-Path $toolsDir 'liveview.ps1')
    }
    default {
        Write-Host "Unknown command: $Command"
        Write-Host "Run '$scriptName' without arguments to see available commands."
        exit 1
    }
}
