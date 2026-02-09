# setup.ps1 - Consolidated Unify Desktop Assistant Setup Script
# 
# Single script to install, configure, and start all services for localhost use.
#
# Usage:
#   .\setup.ps1 -UnifyKey "your-key" -OrchestraUrl "https://api.unify.ai/v0"
#   .\setup.ps1 -Stop
#   .\setup.ps1 -UnifyKey "your-key" -Force  # Force reinstall
#
# Services started:
#   - TightVNC Server (port 5900)
#   - websockify + noVNC (port 6080)
#   - Agent Service (port 3000)
#
# Access URLs:
#   - Desktop: http://localhost:6080/custom.html?password=<vnc-password>
#   - Agent API: http://localhost:3000

param(
    [Parameter(Position = 0)]
    [string]$UnifyKey,
    
    [string]$OrchestraUrl = "https://api.unify.ai/v0",
    
    [switch]$Stop,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StartTime = Get-Date
$script:ToolsDir = $PSScriptRoot
$script:InstallDir = Split-Path -Parent $PSScriptRoot
$script:NoVncDir = Join-Path $script:ToolsDir 'novnc'
$script:MagnitudeDir = Join-Path $script:InstallDir 'magnitude'
$script:AgentServiceDir = Join-Path $script:InstallDir 'agent-service'

Write-Host ""
Write-Host "=========================================="
Write-Host "  Unify Desktop Assistant Setup"
Write-Host "=========================================="
Write-Host ""

# =============================================================================
# Helper Functions
# =============================================================================

function Test-PortListening {
    param([int]$Port, [int]$TimeoutMs = 1000)
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        return $null -ne $conn
    } catch {
        return $false
    }
}

function Get-PackageJsonHash {
    param([string]$Dir)
    $pkgFile = Join-Path $Dir 'package.json'
    if (Test-Path $pkgFile) {
        return (Get-FileHash $pkgFile -Algorithm MD5).Hash.Substring(0, 8)
    }
    return $null
}

function Test-DependenciesInstalled {
    param([string]$Dir)
    $nodeModules = Join-Path $Dir 'node_modules'
    if (-not (Test-Path $nodeModules)) { return $false }
    
    $hashFile = Join-Path $Dir '.pkg-hash'
    if (-not (Test-Path $hashFile)) { return $false }
    
    $savedHash = Get-Content $hashFile -ErrorAction SilentlyContinue
    $currentHash = Get-PackageJsonHash -Dir $Dir
    
    return ($savedHash -eq $currentHash)
}

function Save-DependenciesHash {
    param([string]$Dir)
    $hash = Get-PackageJsonHash -Dir $Dir
    if ($hash) {
        $hash | Out-File -FilePath (Join-Path $Dir '.pkg-hash') -Encoding UTF8 -NoNewline
    }
}


# =============================================================================
# Fast Mode Detection
# =============================================================================

function Test-FastMode {
    Write-Host "Checking installation status..." -ForegroundColor Cyan
    
    # Pre-provided packages (should always exist after installation)
    $preProvided = @(
        @{ Path = (Join-Path $script:MagnitudeDir 'packages\magnitude-core\package.json'); Name = 'Magnitude' },
        @{ Path = (Join-Path $script:AgentServiceDir 'package.json'); Name = 'AgentService' }
    )
    
    foreach ($check in $preProvided) {
        if (Test-Path $check.Path) {
            Write-Host "  [OK] $($check.Name) (pre-installed)" -ForegroundColor Green
        } else {
            Write-Host "  [ERR] $($check.Name) NOT FOUND" -ForegroundColor Red
            Write-Host "       Expected at: $($check.Path)" -ForegroundColor Red
            throw "Required component '$($check.Name)' is missing from the installation."
        }
    }
    
    # Components that need installation
    $installChecks = @(
        @{ Path = 'C:\Program Files\TightVNC\tvnserver.exe'; Name = 'TightVNC' },
        @{ Path = (Join-Path $script:NoVncDir 'vnc.html'); Name = 'noVNC' }
    )
    
    $allInstalled = $true
    foreach ($check in $installChecks) {
        if (Test-Path $check.Path) {
            Write-Host "  [OK] $($check.Name)" -ForegroundColor Green
        } else {
            Write-Host "  [--] $($check.Name) (will install)" -ForegroundColor Yellow
            $allInstalled = $false
        }
    }
    
    return $allInstalled
}

# =============================================================================
# Stop Services
# =============================================================================

function Stop-AllServices {
    Write-Host ""
    Write-Host "=== Stopping Services ===" -ForegroundColor Cyan
    
    # Stop Agent Service
    $agentProcs = Get-Process -Name "node" -ErrorAction SilentlyContinue | 
        Where-Object { $_.CommandLine -like "*agent-service*" -or $_.CommandLine -like "*ts-node*" }
    if ($agentProcs) {
        $agentProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped Agent Service" -ForegroundColor Green
    }
    
    # Stop websockify
    $websockifyProcs = Get-Process -Name "python*" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*websockify*" }
    if ($websockifyProcs) {
        $websockifyProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped websockify" -ForegroundColor Green
    }
    
    # Stop TightVNC
    $tvnExe = 'C:\Program Files\TightVNC\tvnserver.exe'
    if (Test-Path $tvnExe) {
        try { & $tvnExe -controlapp -shutdown 2>&1 | Out-Null } catch {}
        try { & net stop tvnserver 2>&1 | Out-Null } catch {}
        Write-Host "  Stopped TightVNC" -ForegroundColor Green
    }
    
    Write-Host ""
    Write-Host "All services stopped." -ForegroundColor Green
}

# =============================================================================
# Installation Functions
# =============================================================================

function Install-Chocolatey {
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        return
    }
    
    Write-Host ""
    Write-Host "=== Installing Chocolatey ===" -ForegroundColor Cyan
    
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    Write-Host "  Chocolatey installed" -ForegroundColor Green
}

function Install-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        return
    }
    
    Write-Host ""
    Write-Host "=== Installing Git ===" -ForegroundColor Cyan
    
    choco install git -y --no-progress | Out-Host
    
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    Write-Host "  Git installed" -ForegroundColor Green
}

function Install-Python {
    $pythonExe = 'C:\Program Files\Python312\python.exe'
    if ((Test-Path $pythonExe) -or (Get-Command python -ErrorAction SilentlyContinue)) {
        return
    }
    
    Write-Host ""
    Write-Host "=== Installing Python ===" -ForegroundColor Cyan
    
    choco install python312 -y --no-progress | Out-Host
    
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    # Upgrade pip
    if (Test-Path $pythonExe) {
        & $pythonExe -m pip install --upgrade pip 2>&1 | Out-Null
    }
    
    Write-Host "  Python installed" -ForegroundColor Green
}

function Install-NodeJS {
    if (Get-Command node -ErrorAction SilentlyContinue) {
        return
    }
    
    Write-Host ""
    Write-Host "=== Installing Node.js ===" -ForegroundColor Cyan
    
    choco install nodejs-lts -y --no-progress | Out-Host
    
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    Write-Host "  Node.js installed" -ForegroundColor Green
}

function Install-Bun {
    $bunExe = "$env:USERPROFILE\.bun\bin\bun.exe"
    if ((Test-Path $bunExe) -or (Get-Command bun -ErrorAction SilentlyContinue)) {
        return
    }
    
    Write-Host ""
    Write-Host "=== Installing Bun ===" -ForegroundColor Cyan
    
    try {
        powershell -Command "irm bun.sh/install.ps1 | iex" 2>&1 | Out-Null
        Write-Host "  Bun installed" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: Bun install failed (optional)" -ForegroundColor Yellow
    }
}

function Install-TightVNC {
    param([string]$Password = "unify123")
    
    Write-Host ""
    Write-Host "=== Installing TightVNC ===" -ForegroundColor Cyan
    
    $tvnExe = 'C:\Program Files\TightVNC\tvnserver.exe'
    
    if (-not (Test-Path $tvnExe)) {
        # Download and install via MSI with password parameters (no user interaction)
        $vncInstallerUrl = 'https://www.tightvnc.com/download/2.8.81/tightvnc-2.8.81-gpl-setup-64bit.msi'
        $vncInstallerPath = 'C:\temp\tightvnc.msi'
        
        New-Item -ItemType Directory -Force -Path 'C:\temp' | Out-Null
        
        Write-Host "  Downloading TightVNC..."
        Invoke-WebRequest -Uri $vncInstallerUrl -OutFile $vncInstallerPath -UseBasicParsing
        
        Write-Host "  Installing TightVNC (silent with password)..."
        $vncArgs = @(
            "/i", $vncInstallerPath,
            "/quiet", "/norestart",
            "ADDLOCAL=Server",
            "SET_USEVNCAUTHENTICATION=1",
            "VALUE_OF_USEVNCAUTHENTICATION=1",
            "SET_PASSWORD=1",
            "VALUE_OF_PASSWORD=$Password",
            "SET_USECONTROLAUTHENTICATION=1",
            "VALUE_OF_USECONTROLAUTHENTICATION=1",
            "SET_CONTROLPASSWORD=1",
            "VALUE_OF_CONTROLPASSWORD=$Password"
        )
        $vncProcess = Start-Process msiexec.exe -ArgumentList $vncArgs -Wait -NoNewWindow -PassThru
        
        Write-Host "  TightVNC installation exit code: $($vncProcess.ExitCode)"
        
        if (Test-Path $tvnExe) {
            Write-Host "  TightVNC installed" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: TightVNC may not have installed correctly" -ForegroundColor Yellow
        }
        
        # Cleanup
        Remove-Item $vncInstallerPath -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "  TightVNC already installed" -ForegroundColor Green
    }
    
    # Configure TightVNC registry settings (both HKLM and HKCU for service and app mode)
    Write-Host "  Configuring TightVNC settings..."
    
    $regPaths = @(
        'HKLM:\SOFTWARE\TightVNC\Server',
        'HKLM:\SOFTWARE\WOW6432Node\TightVNC\Server',
        'HKCU:\SOFTWARE\TightVNC\Server',
        'HKCU:\SOFTWARE\WOW6432Node\TightVNC\Server'
    )
    
    foreach ($regPath in $regPaths) {
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        
        # Critical settings for websockify to connect via localhost
        Set-ItemProperty -Path $regPath -Name 'AllowLoopback' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name 'AcceptRfbConnections' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name 'UseVncAuthentication' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name 'QueryIfNoPassword' -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name 'RfbPort' -Value 5900 -Type DWord -Force
    }
    
    Write-Host "  Registry settings configured" -ForegroundColor Green
    
    # Copy encrypted password from HKLM to HKCU (for app-mode operation)
    $hklmPath = 'HKLM:\SOFTWARE\TightVNC\Server'
    $hkcuPath = 'HKCU:\SOFTWARE\TightVNC\Server'
    $passwordExists = (Get-ItemProperty -Path $hkcuPath -Name 'Password' -ErrorAction SilentlyContinue).Password
    
    if (-not $passwordExists) {
        Write-Host "  Configuring password for app-mode..."
        
        # Start service briefly to initialize password in registry
        Set-Service -Name "tvnserver" -StartupType Manual -ErrorAction SilentlyContinue
        Start-Service -Name "tvnserver" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        
        # Copy encrypted password bytes from HKLM to HKCU
        try {
            $passwordBytes = Get-ItemPropertyValue -Path $hklmPath -Name 'Password' -ErrorAction Stop
            Set-ItemProperty -Path $hkcuPath -Name 'Password' -Value $passwordBytes -Type Binary -Force
            $controlPwdBytes = Get-ItemPropertyValue -Path $hklmPath -Name 'ControlPassword' -ErrorAction Stop
            Set-ItemProperty -Path $hkcuPath -Name 'ControlPassword' -Value $controlPwdBytes -Type Binary -Force
            Write-Host "  Password configured automatically" -ForegroundColor Green
        } catch {
            Write-Host "  WARNING: Password copy failed - $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Password already configured" -ForegroundColor Green
    }
    
    # Set service to automatic startup
    Set-Service -Name "tvnserver" -StartupType Automatic -ErrorAction SilentlyContinue
    Write-Host "  TightVNC configured" -ForegroundColor Green
}

function Install-NoVNC {
    Write-Host ""
    Write-Host "=== Installing noVNC ===" -ForegroundColor Cyan
    
    if (-not (Test-Path $script:NoVncDir)) {
        New-Item -ItemType Directory -Force -Path $script:NoVncDir | Out-Null
    }
    
    $vncHtml = Join-Path $script:NoVncDir 'vnc.html'
    
    if (-not (Test-Path $vncHtml)) {
        Write-Host "  Cloning noVNC repository..."
        git clone --depth 1 https://github.com/novnc/noVNC.git $script:NoVncDir 2>&1 | Out-Null
        
        if (Test-Path $vncHtml) {
            Write-Host "  noVNC cloned" -ForegroundColor Green
        } else {
            throw "noVNC clone failed"
        }
    }
    
    # Create custom.html - iframe wrapper that hides noVNC controls
    Write-Host "  Creating custom.html..."
    
    $customHtml = @'
<!DOCTYPE html>
<html>
<head>
    <title>Desktop</title>
    <style>
        body, html { margin: 0; padding: 0; overflow: hidden; background: #000; }
        iframe { width: 100vw; height: 100vh; border: none; }
    </style>
</head>
<body>
    <iframe id="vnc" src=""></iframe>
    <script>
        const params = new URLSearchParams(window.location.search);
        params.set('resize', 'scale');
        params.set('autoconnect', '1');
        params.set('reconnect', '1');
        params.set('show_dot', '1');
        document.getElementById('vnc').src = `vnc.html?${params}`;
        
        // Inject CSS to hide control bar, logo, and remote cursor
        document.getElementById('vnc').onload = function() {
            try {
                const style = this.contentDocument.createElement('style');
                style.textContent = `
                    #noVNC_control_bar,
                    #noVNC_control_bar_anchor,
                    #noVNC_control_bar_handle,
                    #noVNC_logo,
                    #noVNC_status { display: none !important; }
                    .noVNC_cursor { display: none !important; }
                `;
                this.contentDocument.head.appendChild(style);
            } catch (e) {
                console.warn('Could not inject CSS (cross-origin)', e);
            }
        };
    </script>
</body>
</html>
'@
    
    $customHtml | Out-File -FilePath (Join-Path $script:NoVncDir 'custom.html') -Encoding UTF8
    Copy-Item (Join-Path $script:NoVncDir 'custom.html') (Join-Path $script:NoVncDir 'index.html') -Force
    
    Write-Host "  custom.html created" -ForegroundColor Green
}

function Install-Websockify {
    Write-Host ""
    Write-Host "=== Installing websockify ===" -ForegroundColor Cyan
    
    $pythonExe = 'C:\Program Files\Python312\python.exe'
    if (-not (Test-Path $pythonExe)) {
        $pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
    }
    
    if ($pythonExe -and (Test-Path $pythonExe)) {
        & $pythonExe -m pip install websockify --quiet 2>&1 | Out-Null
        Write-Host "  websockify installed via pip" -ForegroundColor Green
    } else {
        throw "Python not found, cannot install websockify"
    }
}

function Install-Magnitude {
    param([switch]$Force)
    
    Write-Host ""
    Write-Host "=== Setting up Magnitude ===" -ForegroundColor Cyan
    
    $magnitudeCoreDir = Join-Path $script:MagnitudeDir 'packages\magnitude-core'
    
    # Magnitude is pre-provided in the installer, no git clone needed
    if (-not (Test-Path (Join-Path $magnitudeCoreDir 'package.json'))) {
        Write-Host "  ERROR: magnitude not found at $script:MagnitudeDir" -ForegroundColor Red
        Write-Host "  This should be included in the installer package." -ForegroundColor Red
        return
    }
    
    # Check if deps need install
    if ((Test-DependenciesInstalled -Dir $magnitudeCoreDir) -and -not $Force) {
        Write-Host "  Dependencies up-to-date" -ForegroundColor Green
    } else {
        Write-Host "  Installing dependencies and building magnitude-core..."
        
        Push-Location $magnitudeCoreDir
        
        # Prefer bun, fallback to npm
        $bunExe = "$env:USERPROFILE\.bun\bin\bun.exe"
        if (Test-Path $bunExe) {
            & $bunExe install 2>&1 | Out-Null
        } else {
            npm install 2>&1 | Out-Null
        }
        
        npm run build 2>&1 | Out-Null
        
        Save-DependenciesHash -Dir $magnitudeCoreDir
        Pop-Location
        
        Write-Host "  magnitude-core built" -ForegroundColor Green
    }
}

function Install-AgentService {
    param([switch]$Force)
    
    Write-Host ""
    Write-Host "=== Installing Agent Service ===" -ForegroundColor Cyan
    
    $pkgJson = Join-Path $script:AgentServiceDir 'package.json'
    
    if (-not (Test-Path $pkgJson)) {
        Write-Host "  ERROR: agent-service not found at $script:AgentServiceDir" -ForegroundColor Red
        return
    }
    
    # Check if deps need install
    if ((Test-DependenciesInstalled -Dir $script:AgentServiceDir) -and -not $Force) {
        Write-Host "  Dependencies up-to-date" -ForegroundColor Green
    } else {
        Write-Host "  Installing dependencies..."
        
        Push-Location $script:AgentServiceDir
        
        npm install 2>&1 | Out-Null
        npx playwright@1.52.0 install --with-deps chromium 2>&1 | Out-Null
        
        Save-DependenciesHash -Dir $script:AgentServiceDir
        Pop-Location
        
        Write-Host "  Dependencies installed" -ForegroundColor Green
    }
}

# =============================================================================
# Configuration Functions
# =============================================================================

function Setup-AgentServiceEnv {
    param(
        [string]$UnifyKey,
        [string]$OrchestraUrl
    )
    
    Write-Host ""
    Write-Host "=== Configuring Agent Service ===" -ForegroundColor Cyan
    
    $envFile = Join-Path $script:AgentServiceDir '.env'
    
    $envContent = @"
# Agent Service Environment Configuration
# Generated: $(Get-Date)

PORT=3000
UNIFY_KEY=$UnifyKey
ORCHESTRA_URL=$OrchestraUrl
"@
    
    $envContent | Out-File -FilePath $envFile -Encoding UTF8
    
    Write-Host "  .env created" -ForegroundColor Green
    Write-Host "    UNIFY_KEY: $(if ($UnifyKey) { '(set)' } else { '(not set)' })" -ForegroundColor Gray
    Write-Host "    ORCHESTRA_URL: $OrchestraUrl" -ForegroundColor Gray
}

function Setup-WebsockifyStartup {
    Write-Host ""
    Write-Host "=== Setting up websockify startup ===" -ForegroundColor Cyan
    
    $batFile = Join-Path $script:NoVncDir 'start-websockify.bat'
    
    # Find Python
    $pythonExe = 'C:\Program Files\Python312\python.exe'
    if (-not (Test-Path $pythonExe)) {
        $pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
    }
    
    if (-not $pythonExe) {
        Write-Host "  ERROR: Python not found" -ForegroundColor Red
        return
    }
    
    # Create startup script - CRITICAL: localhost:5900 (not hardcoded IP)
    $websockifyScript = @"
@echo off
cd /d "$($script:NoVncDir)"
"$pythonExe" -m websockify --web "$($script:NoVncDir)" 6080 localhost:5900
"@
    
    $websockifyScript | Out-File -FilePath $batFile -Encoding ASCII
    
    # Create scheduled task for auto-start on logon
    $taskName = "UnifyWebsockify"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    
    if (-not $existingTask) {
        $action = New-ScheduledTaskAction -Execute $batFile -WorkingDirectory $script:NoVncDir
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
        Write-Host "  Scheduled task created: $taskName" -ForegroundColor Green
    } else {
        Write-Host "  Scheduled task exists: $taskName" -ForegroundColor Green
    }
}

function Setup-AgentServiceStartup {
    Write-Host ""
    Write-Host "=== Setting up Agent Service startup ===" -ForegroundColor Cyan
    
    $batFile = Join-Path $script:AgentServiceDir 'start-agent.bat'
    
    # Create startup script
    $agentScript = @"
@echo off
cd /d "$($script:AgentServiceDir)"
npx ts-node src/index.ts >> "$($script:AgentServiceDir)\agent.log" 2>&1
"@
    
    $agentScript | Out-File -FilePath $batFile -Encoding ASCII
    
    # Create scheduled task for auto-start on logon
    $taskName = "UnifyAgentService"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    
    if (-not $existingTask) {
        $action = New-ScheduledTaskAction -Execute $batFile -WorkingDirectory $script:AgentServiceDir
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
        Write-Host "  Scheduled task created: $taskName" -ForegroundColor Green
    } else {
        Write-Host "  Scheduled task exists: $taskName" -ForegroundColor Green
    }
}

function Configure-Firewall {
    Write-Host ""
    Write-Host "=== Configuring Firewall ===" -ForegroundColor Cyan
    
    $rules = @(
        @{ Name = 'Unify-noVNC'; Port = 6080; Description = 'noVNC WebSocket' },
        @{ Name = 'Unify-AgentService'; Port = 3000; Description = 'Agent Service API' }
    )
    
    foreach ($rule in $rules) {
        $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -LocalPort $rule.Port -Protocol TCP -Action Allow -Profile Any | Out-Null
            Write-Host "  Created rule: $($rule.Name) (port $($rule.Port))" -ForegroundColor Green
        } else {
            Write-Host "  Rule exists: $($rule.Name) (port $($rule.Port))" -ForegroundColor Green
        }
    }
}

# =============================================================================
# Start Services
# =============================================================================

function Start-AllServices {
    Write-Host ""
    Write-Host "=== Starting Services ===" -ForegroundColor Cyan
    
    # Start TightVNC
    $tvnExe = 'C:\Program Files\TightVNC\tvnserver.exe'
    if (Test-Path $tvnExe) {
        # Stop existing service first
        try { & net stop tvnserver 2>&1 | Out-Null } catch {}
        Start-Sleep -Milliseconds 500
        
        # Start in app mode
        Write-Host "  Starting TightVNC..." -ForegroundColor Gray
        Start-Process -FilePath $tvnExe -ArgumentList '-run' -PassThru | Out-Null
        Start-Sleep -Milliseconds 500
        
        # Reload settings
        try { & $tvnExe -controlapp -reload 2>&1 | Out-Null } catch {}
    }
    
    # Start websockify
    if (-not (Test-PortListening -Port 6080)) {
        $batFile = Join-Path $script:NoVncDir 'start-websockify.bat'
        if (Test-Path $batFile) {
            Write-Host "  Starting websockify..." -ForegroundColor Gray
            Start-Process -FilePath $batFile -WorkingDirectory $script:NoVncDir -WindowStyle Hidden
        }
    }
    
    # Start Agent Service
    if (-not (Test-PortListening -Port 3000)) {
        $batFile = Join-Path $script:AgentServiceDir 'start-agent.bat'
        if (Test-Path $batFile) {
            Write-Host "  Starting Agent Service..." -ForegroundColor Gray
            Start-Process -FilePath $batFile -WorkingDirectory $script:AgentServiceDir -WindowStyle Hidden
        }
    }
    
    # Wait for services to start
    Write-Host ""
    Write-Host "  Waiting for services..." -ForegroundColor Gray
    Start-Sleep -Seconds 3
    
    # Verify
    Write-Host ""
    Write-Host "Service Status:" -ForegroundColor Cyan
    
    if (Test-PortListening -Port 5900) {
        Write-Host "  [OK] TightVNC (port 5900)" -ForegroundColor Green
    } else {
        Write-Host "  [--] TightVNC (port 5900) - starting..." -ForegroundColor Yellow
    }
    
    if (Test-PortListening -Port 6080) {
        Write-Host "  [OK] websockify (port 6080)" -ForegroundColor Green
    } else {
        Write-Host "  [--] websockify (port 6080) - starting..." -ForegroundColor Yellow
    }
    
    if (Test-PortListening -Port 3000) {
        Write-Host "  [OK] Agent Service (port 3000)" -ForegroundColor Green
    } else {
        Write-Host "  [--] Agent Service (port 3000) - starting..." -ForegroundColor Yellow
    }
}

# =============================================================================
# Summary
# =============================================================================

function Show-Summary {
    param([string]$UnifyKey)
    
    $elapsed = (Get-Date) - $script:StartTime
    
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  Setup Complete!"
    Write-Host "=========================================="
    Write-Host ""
    Write-Host "Access URLs:" -ForegroundColor Cyan
    
    $vncUrl = "http://localhost:6080/custom.html"
    if ($UnifyKey) {
        $vncUrl += "?password=$UnifyKey"
    }
    
    Write-Host "  Desktop:       $vncUrl" -ForegroundColor Green
    Write-Host "  Agent Service: http://localhost:3000" -ForegroundColor Green
    Write-Host ""
    Write-Host "Time elapsed: $([math]::Round($elapsed.TotalSeconds, 1)) seconds" -ForegroundColor Magenta
    Write-Host ""
}

# =============================================================================
# Main Execution
# =============================================================================

# Handle stop command
if ($Stop) {
    Stop-AllServices
    exit 0
}

# Validate required parameters
if (-not $UnifyKey) {
    Write-Host "ERROR: -UnifyKey is required" -ForegroundColor Red
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Cyan
    Write-Host "  .\setup.ps1 -UnifyKey 'your-key' [-OrchestraUrl 'https://api.unify.ai/v0']"
    Write-Host "  .\setup.ps1 -Stop"
    Write-Host ""
    exit 1
}

# Detect fast mode
$fastMode = (Test-FastMode) -and -not $Force

if ($fastMode) {
    Write-Host ""
    Write-Host "Fast mode: All components installed, skipping installations" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Full install mode" -ForegroundColor Yellow
    
    # Install prerequisites
    Install-Chocolatey
    Install-Git
    Install-Python
    Install-NodeJS
    Install-Bun
    
    # Install main components
    Install-TightVNC -Password $UnifyKey
    Install-NoVNC
    Install-Websockify
    Install-Magnitude -Force:$Force
    Install-AgentService -Force:$Force
}

# Always run configuration
Setup-AgentServiceEnv -UnifyKey $UnifyKey -OrchestraUrl $OrchestraUrl
Setup-WebsockifyStartup
Setup-AgentServiceStartup
Configure-Firewall

# Start services
Start-AllServices

# Show summary
Show-Summary -UnifyKey $UnifyKey
