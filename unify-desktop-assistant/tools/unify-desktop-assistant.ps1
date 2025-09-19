param(
    [Parameter(Position=0)]
    [string]$Command
)

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

switch ($Command.ToLower()) {
    "install" { & "$toolsDir\install.ps1" @args }
    "start"   { & "$toolsDir\remote.ps1" @args }
    "tunnel"  { & "$toolsDir\tunnel.ps1" @args }
    "liveview" { & "$toolsDir\liveview.ps1" @args }
    default {
        Write-Host "Usage: unify-desktop-assistant <install|start|tunnel|liveview>"
        exit 1
    }
}
