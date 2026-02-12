# setup.ps1 - Consolidated Unify Desktop Assistant Setup Script
# 
# Single script to install, configure, and start all services for localhost use.
#
# Usage:
#   .\setup.ps1 -UnifyKey "your-key" -OrchestraUrl "https://api.unify.ai/v0" -UnityCommsUrl "https://unity-comms-app-000000000000.us-central1.run.app"
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
    [string]$UnityCommsUrl = "https://unity-comms-app-000000000000.us-central1.run.app",
    
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

function Find-PythonExe {
    # Search for the real Python binary, avoiding the Windows Store stub
    # (WindowsApps\python.exe redirects to the Microsoft Store and is not usable)
    
    $searchPaths = @(
        'C:\Program Files\Python312\python.exe',
        'C:\Program Files\Python311\python.exe',
        'C:\Program Files\Python310\python.exe',
        'C:\Python312\python.exe',
        'C:\Python311\python.exe',
        'C:\Python310\python.exe',
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe"
    )
    
    foreach ($p in $searchPaths) {
        if (Test-Path $p) { return $p }
    }
    
    # Fallback: use where.exe to find python, filtering out the MS Store stub
    try {
        $candidates = & where.exe python 2>$null
        if ($candidates) {
            foreach ($c in $candidates) {
                if ($c -notlike '*WindowsApps*') { return $c }
            }
        }
    } catch {}
    
    return $null
}

# =============================================================================
# Fast Mode Detection
# =============================================================================

function Test-FastMode {
    Write-Host "Checking installation status..." -ForegroundColor Cyan
    
    # Pre-provided packages (should always exist after installation)
    $preProvided = @(
        @{ Path = (Join-Path $script:MagnitudeDir 'package.json'); Name = 'Magnitude' },
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
    if (Find-PythonExe) {
        return
    }
    
    Write-Host ""
    Write-Host "=== Installing Python ===" -ForegroundColor Cyan
    
    choco install python312 -y --no-progress | Out-Host
    
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    # Upgrade pip
    $pythonExe = Find-PythonExe
    if ($pythonExe) {
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
        
        # Refresh PATH so bun is available in the current session
        # (turbo reads packageManager field and looks for bun in PATH)
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        
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
}

function Configure-TightVNC {
    param([string]$Password = "unify123")
    
    Write-Host ""
    Write-Host "=== Configuring TightVNC ===" -ForegroundColor Cyan
    
    $hklmPath = 'HKLM:\SOFTWARE\TightVNC\Server'
    
    # Read the MSI-written encrypted password from HKLM (TightVNC's own encryption)
    $encryptedPwd = $null
    try {
        $encryptedPwd = Get-ItemPropertyValue -Path $hklmPath -Name 'Password' -ErrorAction Stop
    } catch {}
    
    if (-not $encryptedPwd) {
        # MSI didn't write the password yet — start the service briefly to let TightVNC initialize it
        Write-Host "  Password not in registry, initializing via service start..." -ForegroundColor Gray
        try {
            Stop-Service -Name "tvnserver" -Force -ErrorAction SilentlyContinue
            Start-Service -Name "tvnserver" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Stop-Service -Name "tvnserver" -Force -ErrorAction SilentlyContinue
        } catch {}
        
        try {
            $encryptedPwd = Get-ItemPropertyValue -Path $hklmPath -Name 'Password' -ErrorAction Stop
        } catch {}
    }
    
    if (-not $encryptedPwd) {
        Write-Host "  WARNING: Could not read TightVNC password from registry" -ForegroundColor Yellow
        Write-Host "  VNC authentication may fail — check HKLM:\SOFTWARE\TightVNC\Server" -ForegroundColor Yellow
        return
    }
    
    Write-Host "  Read encrypted password from HKLM ($($encryptedPwd.Length) bytes)" -ForegroundColor Gray
    
    # Copy the MSI-written password + settings to all registry paths
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
        
        # Copy MSI-encrypted password (TightVNC's own format, guaranteed correct)
        Set-ItemProperty -Path $regPath -Name 'Password' -Value ([byte[]]$encryptedPwd) -Type Binary -Force
        Set-ItemProperty -Path $regPath -Name 'ControlPassword' -Value ([byte[]]$encryptedPwd) -Type Binary -Force
    }
    
    Write-Host "  Registry settings configured" -ForegroundColor Green
    Write-Host "  Password copied to all registry paths" -ForegroundColor Green
    
    # Disable the Windows service — we run TightVNC in app mode via Setup-TightVNCStartup
    # This prevents the service from auto-starting and conflicting with the app-mode instance
    Stop-Service -Name "tvnserver" -Force -ErrorAction SilentlyContinue
    Set-Service -Name "tvnserver" -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Host "  TightVNC configured (app mode)" -ForegroundColor Green
}

function Install-NoVNC {
    Write-Host ""
    Write-Host "=== Installing noVNC ===" -ForegroundColor Cyan
    
    $vncHtml = Join-Path $script:NoVncDir 'vnc.html'
    
    if (-not (Test-Path $vncHtml)) {
        # Clean up any partial/failed previous clone
        if (Test-Path $script:NoVncDir) {
            Remove-Item -Recurse -Force $script:NoVncDir -ErrorAction SilentlyContinue
        }
        
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
    
    $pythonExe = Find-PythonExe
    
    if ($pythonExe) {
        & $pythonExe -m pip install websockify --quiet 2>&1 | Out-Null
        Write-Host "  websockify installed via pip (using $pythonExe)" -ForegroundColor Green
    } else {
        throw "Python not found, cannot install websockify"
    }
}

function Install-Magnitude {
    param([switch]$Force)
    
    Write-Host ""
    Write-Host "=== Setting up Magnitude ===" -ForegroundColor Cyan
    
    # Magnitude is pre-provided in the installer as a monorepo (turbo workspace)
    if (-not (Test-Path (Join-Path $script:MagnitudeDir 'package.json'))) {
        Write-Host "  ERROR: magnitude not found at $script:MagnitudeDir" -ForegroundColor Red
        Write-Host "  This should be included in the installer package." -ForegroundColor Red
        return
    }
    
    # Check if deps need install
    if ((Test-DependenciesInstalled -Dir $script:MagnitudeDir) -and -not $Force) {
        Write-Host "  Dependencies up-to-date" -ForegroundColor Green
    } else {
        Write-Host "  Installing dependencies and building magnitude workspace..."
        
        Push-Location $script:MagnitudeDir
        
        # Install at monorepo root — postinstall runs "turbo run build" which builds
        # magnitude-extract then magnitude-core in correct dependency order
        $bunExe = "$env:USERPROFILE\.bun\bin\bun.exe"
        if (Test-Path $bunExe) {
            Write-Host "  Running bun install (includes build via postinstall)..."
            & $bunExe install 2>&1 | Out-Host
        } else {
            Write-Host "  Running npm install (includes build via postinstall)..."
            npm install 2>&1 | Out-Host
        }
        
        # Verify builds succeeded
        # if ((Test-Path $coreDistDir) -and (Test-Path $extractDistDir)) {
        #     Save-DependenciesHash -Dir $script:MagnitudeDir
        #     Write-Host "  magnitude workspace built" -ForegroundColor Green
        # } else {
        #     Write-Host "  WARNING: magnitude build may have failed — dist/ not found" -ForegroundColor Yellow
        #     if (-not (Test-Path $extractDistDir)) {
        #         Write-Host "    Missing: magnitude-extract/dist/" -ForegroundColor Yellow
        #     }
        #     if (-not (Test-Path $coreDistDir)) {
        #         Write-Host "    Missing: magnitude-core/dist/" -ForegroundColor Yellow
        #     }
        # }
        
        Pop-Location
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
        Push-Location $script:AgentServiceDir
        
        Write-Host "  Installing npm dependencies..."
        npm install 2>&1 | Out-Host
        
        Write-Host "  Installing Playwright + Chromium (this may take a few minutes)..."
        npx -y playwright@1.52.0 install --with-deps chromium 2>&1 | Out-Host
        
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
        [string]$OrchestraUrl,
        [string]$UnityCommsUrl
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
UNITY_COMMS_URL=$UnityCommsUrl
"@
    
    $envContent | Out-File -FilePath $envFile -Encoding UTF8
    
    Write-Host "  .env created" -ForegroundColor Green
    Write-Host "    UNIFY_KEY: $(if ($UnifyKey) { '(set)' } else { '(not set)' })" -ForegroundColor Gray
    Write-Host "    ORCHESTRA_URL: $OrchestraUrl" -ForegroundColor Gray
    Write-Host "    UNITY_COMMS_URL: $UnityCommsUrl" -ForegroundColor Gray
}

function Setup-WebsockifyStartup {
    Write-Host ""
    Write-Host "=== Setting up websockify startup ===" -ForegroundColor Cyan
    
    $batFile = Join-Path $script:NoVncDir 'start-websockify.bat'
    $vbsFile = Join-Path $script:NoVncDir 'start-websockify.vbs'
    
    # Find Python (avoid MS Store stub)
    $pythonExe = Find-PythonExe
    
    if (-not $pythonExe) {
        Write-Host "  ERROR: Python not found" -ForegroundColor Red
        return
    }
    
    # Create startup script - CRITICAL: localhost:5900 (not hardcoded IP)
    $wsLog = Join-Path $script:NoVncDir 'websockify.log'
    $websockifyScript = @"
@echo off
cd /d "$($script:NoVncDir)"
"$pythonExe" -m websockify --web "$($script:NoVncDir)" 6080 localhost:5900 > "$wsLog" 2>&1
"@
    
    $websockifyScript | Out-File -FilePath $batFile -Encoding ASCII
    
    # Create VBS wrapper to run the bat file hidden (no visible cmd window)
    $vbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "cmd /c """"$batFile""""", 0, False
"@
    $vbsContent | Out-File -FilePath $vbsFile -Encoding ASCII
    
    # Create/update scheduled task for auto-start on logon (uses VBS to hide window)
    $taskName = "UnifyWebsockify"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsFile`"" -WorkingDirectory $script:NoVncDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    Write-Host "  Scheduled task created: $taskName (hidden)" -ForegroundColor Green
}

function Setup-AgentServiceStartup {
    Write-Host ""
    Write-Host "=== Setting up Agent Service startup ===" -ForegroundColor Cyan
    
    $batFile = Join-Path $script:AgentServiceDir 'start-agent.bat'
    $vbsFile = Join-Path $script:AgentServiceDir 'start-agent.vbs'
    
    # Create startup script
    $agentLog = Join-Path $script:AgentServiceDir 'agent.log'
    $agentScript = @"
@echo off
cd /d "$($script:AgentServiceDir)"
npx -y ts-node src/index.ts > "$agentLog" 2>&1
"@
    
    $agentScript | Out-File -FilePath $batFile -Encoding ASCII
    
    # Create VBS wrapper to run the bat file hidden (no visible cmd window)
    $vbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "cmd /c """"$batFile""""", 0, False
"@
    $vbsContent | Out-File -FilePath $vbsFile -Encoding ASCII
    
    # Create/update scheduled task for auto-start on logon (uses VBS to hide window)
    $taskName = "UnifyAgentService"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsFile`"" -WorkingDirectory $script:AgentServiceDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    Write-Host "  Scheduled task created: $taskName (hidden)" -ForegroundColor Green
}

function Setup-TightVNCStartup {
    Write-Host ""
    Write-Host "=== Setting up TightVNC startup ===" -ForegroundColor Cyan
    
    $tvnExe = 'C:\Program Files\TightVNC\tvnserver.exe'
    $vbsFile = Join-Path $script:ToolsDir 'start-tightvnc.vbs'
    
    if (-not (Test-Path $tvnExe)) {
        Write-Host "  ERROR: TightVNC not found at $tvnExe" -ForegroundColor Red
        return
    }
    
    # Create VBS wrapper to run TightVNC in app mode hidden (no visible window)
    $vbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run """$tvnExe"" -run", 0, False
"@
    $vbsContent | Out-File -FilePath $vbsFile -Encoding ASCII
    
    # Create/update scheduled task for auto-start on logon (uses VBS to hide window)
    $taskName = "UnifyTightVNC"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsFile`"" -WorkingDirectory $script:ToolsDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    Write-Host "  Scheduled task created: $taskName (hidden)" -ForegroundColor Green
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
    
    # Start websockify directly via cmd.exe with log redirection
    $wsLog = Join-Path $script:NoVncDir 'websockify.log'
    if (-not (Test-PortListening -Port 6080)) {
        $pythonExe = Find-PythonExe
        
        if ($pythonExe) {
            Write-Host "  Starting websockify (using $pythonExe)..." -ForegroundColor Gray
            Start-Process cmd.exe -ArgumentList "/c `"`"$pythonExe`" -m websockify --web `"$($script:NoVncDir)`" 6080 localhost:5900 > `"$wsLog`" 2>&1`"" -WindowStyle Hidden
        } else {
            Write-Host "  ERROR: Python not found, cannot start websockify" -ForegroundColor Red
        }
    }
    
    # Start Agent Service directly via cmd.exe with log redirection
    $agentLog = Join-Path $script:AgentServiceDir 'agent.log'
    if (-not (Test-PortListening -Port 3000)) {
        Write-Host "  Starting Agent Service..." -ForegroundColor Gray
        Start-Process cmd.exe -ArgumentList "/c cd /d `"$($script:AgentServiceDir)`" && npx -y ts-node src/index.ts > `"$agentLog`" 2>&1" -WindowStyle Hidden
    }
    
    # Poll for services to come up (up to 20 seconds)
    Write-Host ""
    Write-Host "  Waiting for services to start..." -ForegroundColor Gray
    
    $maxWait = 20
    $waited = 0
    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 2
        $waited += 2
        
        $vncUp = Test-PortListening -Port 5900
        $wsUp = Test-PortListening -Port 6080
        $agentUp = Test-PortListening -Port 3000
        
        if ($vncUp -and $wsUp -and $agentUp) { break }
        
        # Progress indicator
        $status = @()
        if (-not $vncUp) { $status += "VNC" }
        if (-not $wsUp) { $status += "websockify" }
        if (-not $agentUp) { $status += "agent" }
        Write-Host "  Waiting ($waited`s): $($status -join ', ')..." -ForegroundColor Gray
    }
    
    # Final status report
    Write-Host ""
    Write-Host "Service Status:" -ForegroundColor Cyan
    
    $allOk = $true
    
    if (Test-PortListening -Port 5900) {
        Write-Host "  [OK] TightVNC (port 5900)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] TightVNC (port 5900)" -ForegroundColor Red
        $allOk = $false
    }
    
    if (Test-PortListening -Port 6080) {
        Write-Host "  [OK] websockify (port 6080)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] websockify (port 6080)" -ForegroundColor Red
        $allOk = $false
        if (Test-Path $wsLog) {
            Write-Host "  Log ($wsLog):" -ForegroundColor Gray
            Get-Content $wsLog -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        }
    }
    
    if (Test-PortListening -Port 3000) {
        Write-Host "  [OK] Agent Service (port 3000)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Agent Service (port 3000)" -ForegroundColor Red
        $allOk = $false
        if (Test-Path $agentLog) {
            Write-Host "  Log ($agentLog):" -ForegroundColor Gray
            Get-Content $agentLog -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        }
    }
    
    if (-not $allOk) {
        Write-Host ""
        Write-Host "  Some services failed to start. Check the log files above for details." -ForegroundColor Yellow
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
    Write-Host "  .\setup.ps1 -UnifyKey 'your-key' [-OrchestraUrl 'https://api.unify.ai/v0'] [-UnityCommsUrl 'https://...']"
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
Configure-TightVNC -Password $UnifyKey
Setup-AgentServiceEnv -UnifyKey $UnifyKey -OrchestraUrl $OrchestraUrl -UnityCommsUrl $UnityCommsUrl
Setup-TightVNCStartup
Setup-WebsockifyStartup
Setup-AgentServiceStartup
Configure-Firewall

# Start services
Start-AllServices

# Show summary
Show-Summary -UnifyKey $UnifyKey
