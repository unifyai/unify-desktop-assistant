# setup.ps1 - Consolidated Unify Desktop Assistant Setup Script
# 
# Single script to install, configure, and start all services for localhost use.
#
# Usage:
#   .\setup.ps1 -UnifyKey "your-key" -OrchestraUrl "https://api.unify.ai/v0" -UnityCommsUrl "https://unity-comms-app-000000000000.us-central1.run.app"
#   .\setup.ps1 -Start       # Start services only (no install/config, no admin needed)
#   .\setup.ps1 -Stop
#   .\setup.ps1 -Uninstall   # Stop services, remove scheduled tasks & firewall rules
#   .\setup.ps1 -UnifyKey "your-key" -Force  # Force reinstall
#
# Services started:
#   - TightVNC Server (port 5900)
#   - websockify + noVNC (port 6080)
#   - Agent Service (port 3000 cloud SaaS, 13000 when ~/.unity compose self-host)
#
# Access URLs:
#   - Desktop: http://localhost:6080/custom.html?password=<vnc-password>
#   - Agent API: http://localhost:3000 (or :13000 for Unity Docker self-host)

param(
    [Parameter(Position = 0)]
    [string]$UnifyKey,
    
    [string]$OrchestraUrl = "https://api.unify.ai/v0",
    [string]$UnityCommsUrl = "https://unity-comms-app-000000000000.us-central1.run.app",
    [string]$DeviceName,
    
    [switch]$Start,
    [switch]$Stop,
    [switch]$Uninstall,
    [switch]$Reconfigure,
    [switch]$Force,
    [switch]$SelfHost,
    [switch]$LinkCoordinator,
    [string]$CoordinatorAgentId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SelfHostMode = [bool]$SelfHost
$script:LinkCoordinator = [bool]$LinkCoordinator
$script:CoordinatorAgentId = $CoordinatorAgentId
$script:SelfHostAgentPort = 13000
$script:ComposeSelfHostOrchestraUrl = 'http://127.0.0.1:8000/v0'
$script:ComposeSelfHostCommsUrl = 'http://127.0.0.1:8001'

$script:StartTime = Get-Date
$script:ToolsDir = $PSScriptRoot
$script:InstallDir = Split-Path -Parent $PSScriptRoot
$script:NoVncDir = Join-Path $script:ToolsDir 'novnc'
$script:MagnitudeDir = Join-Path $script:InstallDir 'magnitude'
$script:AgentServiceDir = Join-Path $script:InstallDir 'agent-service'
$script:RatholeDir = Join-Path $script:InstallDir 'rathole'
$script:RatholeExe = Join-Path $script:RatholeDir 'rathole.exe'
$script:RatholeConfig = Join-Path $script:RatholeDir 'client.toml'

Write-Host ""
Write-Host "=========================================="
Write-Host "  Unify Desktop Assistant Setup"
Write-Host "=========================================="
Write-Host ""

# =============================================================================
# Helper Functions
# =============================================================================

# Run a native command without $ErrorActionPreference = 'Stop' killing it
# when the command writes to stderr (git, choco, npm, pip, bun all do this).
# Uses dot-sourcing (.) so the script block runs in THIS scope where
# $ErrorActionPreference is already set to SilentlyContinue, and avoids
# 2>&1 which converts stderr lines into ErrorRecord objects.
function Invoke-NativeCommand {
    param([scriptblock]$Command)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        . $Command
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

function Add-DefenderExclusions {
    # Exclude the dirs that get thousands of files written during install
    # (bun/npm node_modules + caches, extracted Chromium). Defender real-time
    # scanning of these throttles the install to a crawl and makes it appear hung
    # at random spots (the bun global cache at ~/.bun is the worst offender).
    # Best-effort; install runs elevated as the launching user, so their profile
    # env vars resolve correctly.
    $paths = @(
        $script:InstallDir,
        'C:\ms-playwright',
        "$env:USERPROFILE\.bun",
        "$env:LOCALAPPDATA\npm-cache"
    )
    foreach ($p in $paths) {
        if (-not $p) { continue }
        try {
            Add-MpPreference -ExclusionPath $p -ErrorAction Stop
            Write-Host "  Defender exclusion added: $p" -ForegroundColor Green
        } catch {
            Write-Host "  WARNING: Could not add Defender exclusion for ${p}: $_" -ForegroundColor Yellow
        }
    }

    # Process exclusions skip scanning of any file these touch, regardless of
    # location — the most robust guard for the bun/npm install phases.
    $procs = @('bun.exe', 'node.exe')
    foreach ($proc in $procs) {
        try {
            Add-MpPreference -ExclusionProcess $proc -ErrorAction Stop
            Write-Host "  Defender process exclusion added: $proc" -ForegroundColor Green
        } catch {
            Write-Host "  WARNING: Could not add Defender process exclusion for ${proc}: $_" -ForegroundColor Yellow
        }
    }
}

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
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $bytes = [System.IO.File]::ReadAllBytes($pkgFile)
        $hash = [BitConverter]::ToString($md5.ComputeHash($bytes)).Replace("-","")
        $md5.Dispose()
        return $hash.Substring(0, 8)
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
        @{ Path = (Join-Path $script:NoVncDir 'vnc.html'); Name = 'noVNC' },
        @{ Path = $script:RatholeExe; Name = 'Rathole' }
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
    
    # Stop tunnel first
    Stop-Tunnel
    
    # Use WMI (Get-CimInstance) for reliable CommandLine access across sessions/contexts.
    # Get-Process.CommandLine is unreliable in Windows PowerShell 5.1 and elevated contexts.
    
    # Stop Agent Service (node running ts-node/agent-service)
    $agentProcs = Get-CimInstance Win32_Process -Filter "Name = 'node.exe' AND (CommandLine LIKE '%agent-service%' OR CommandLine LIKE '%ts-node%')" -ErrorAction SilentlyContinue
    foreach ($proc in $agentProcs) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped Agent Service (PID $($proc.ProcessId))" -ForegroundColor Green
    }
    
    # Stop websockify (python running websockify)
    $websockifyProcs = Get-CimInstance Win32_Process -Filter "Name LIKE 'python%' AND CommandLine LIKE '%websockify%'" -ErrorAction SilentlyContinue
    foreach ($proc in $websockifyProcs) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped websockify (PID $($proc.ProcessId))" -ForegroundColor Green
    }
    
    # Stop parent cmd.exe processes that launched websockify or agent-service
    $cmdProcs = Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe' AND (CommandLine LIKE '%websockify%' OR CommandLine LIKE '%agent-service%' OR CommandLine LIKE '%ts-node%')" -ErrorAction SilentlyContinue
    foreach ($proc in $cmdProcs) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped cmd.exe wrapper (PID $($proc.ProcessId))" -ForegroundColor Green
    }
    
    # Stop TightVNC (only if actually running - avoids popup when no instance exists)
    $tvnExe = 'C:\Program Files\TightVNC\tvnserver.exe'
    $tvnRunning = (Test-PortListening -Port 5900) -or (Get-Process -Name 'tvnserver' -ErrorAction SilentlyContinue)
    if ($tvnRunning) {
        try { & $tvnExe -controlapp -shutdown 2>&1 | Out-Null } catch {}
        try { & net stop tvnserver 2>&1 | Out-Null } catch {}
        Write-Host "  Stopped TightVNC" -ForegroundColor Green
    } else {
        Write-Host "  TightVNC not running, skipping" -ForegroundColor Gray
    }
    
    # Final sweep: kill any remaining processes by port (catches anything the above missed)
    $agentPort = Get-AgentServicePort
    foreach ($port in @(5900, 6080, $agentPort)) {
        $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        foreach ($conn in $conns) {
            Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
            Write-Host "  Killed process on port $port (PID $($conn.OwningProcess))" -ForegroundColor Green
        }
    }
    
    Write-Host ""
    Write-Host "All services stopped." -ForegroundColor Green
}

function Uninstall-All {
    Write-Host ""
    Write-Host "=== Uninstalling Unify Desktop Assistant ===" -ForegroundColor Cyan
    
    # 1. Stop all services (includes tunnel)
    Stop-AllServices
    
    # 2. Unregister desktop and tunnel from server
    $unifyKey = Get-EnvValue -Key "UNIFY_KEY"
    $orchestraUrl = Get-EnvValue -Key "ORCHESTRA_URL"
    $commsUrl = Get-EnvValue -Key "UNITY_COMMS_URL"
    
    if ($unifyKey) {
        Write-Host ""
        Write-Host "Cleaning up remote registrations..." -ForegroundColor Cyan
        if ($orchestraUrl) { Unregister-Desktop -UnifyKey $unifyKey -OrchestraUrl $orchestraUrl }
        if ($commsUrl) { Unregister-Tunnel -UnifyKey $unifyKey -CommsUrl $commsUrl }
    }
    
    # 3. Remove scheduled tasks
    Write-Host ""
    Write-Host "Removing scheduled tasks..." -ForegroundColor Cyan
    foreach ($taskName in @('UnifyWebsockify', 'UnifyAgentService', 'UnifyTightVNC')) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  Removed: $taskName" -ForegroundColor Green
        }
    }
    
    # 4. Remove firewall rules
    Write-Host ""
    Write-Host "Removing firewall rules..." -ForegroundColor Cyan
    foreach ($ruleName in @('Unify-noVNC', 'Unify-AgentService')) {
        $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($rule) {
            Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
            Write-Host "  Removed: $ruleName" -ForegroundColor Green
        }
    }
    
    # 5. Remove rathole directory
    if (Test-Path $script:RatholeDir) {
        Remove-Item -Recurse -Force $script:RatholeDir -ErrorAction SilentlyContinue
        Write-Host "  Removed rathole directory" -ForegroundColor Green
    }
    
    Write-Host ""
    Write-Host "Uninstall cleanup complete." -ForegroundColor Green
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
    
    Invoke-NativeCommand { choco install git -y --no-progress }
    
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
    
    Invoke-NativeCommand { choco install python312 -y --no-progress }
    
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    # Upgrade pip
    $pythonExe = Find-PythonExe
    if ($pythonExe) {
        Invoke-NativeCommand { & $pythonExe -m pip install --upgrade pip }
    }
    
    Write-Host "  Python installed" -ForegroundColor Green
}

function Install-NodeJS {
    if (Get-Command node -ErrorAction SilentlyContinue) {
        return
    }
    
    Write-Host ""
    Write-Host "=== Installing Node.js ===" -ForegroundColor Cyan
    
    Invoke-NativeCommand { choco install nodejs-lts -y --no-progress }
    
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
        Invoke-NativeCommand {
            powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm bun.sh/install.ps1 | iex"
        }
        
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

# Encrypt a plaintext VNC password into TightVNC's on-disk format.
# VNC stores the password DES-encrypted with a well-known fixed key, using the
# d3des variant that reverses the bit order of each key byte relative to FIPS
# DES. We reproduce that here so .NET's standard DES yields the same bytes
# TightVNC expects. The password is capped at 8 bytes (VNC auth limit) and
# zero-padded, matching how noVNC truncates the key it sends.
function ConvertTo-VncPassword {
    param([string]$Plain)

    $fixed = [byte[]](0x17, 0x52, 0x6B, 0x06, 0x23, 0x4E, 0x58, 0x07)
    $key = New-Object byte[] 8
    for ($i = 0; $i -lt 8; $i++) {
        $b = $fixed[$i]
        $r = 0
        for ($j = 0; $j -lt 8; $j++) {
            $r = (($r -shl 1) -bor ($b -band 1)) -band 0xFF
            $b = $b -shr 1
        }
        $key[$i] = [byte]$r
    }

    $pwBytes = New-Object byte[] 8
    $src = [System.Text.Encoding]::ASCII.GetBytes($Plain)
    $n = [Math]::Min(8, $src.Length)
    for ($i = 0; $i -lt $n; $i++) { $pwBytes[$i] = $src[$i] }

    $des = [System.Security.Cryptography.DES]::Create()
    $des.Mode = [System.Security.Cryptography.CipherMode]::ECB
    $des.Padding = [System.Security.Cryptography.PaddingMode]::None
    $des.Key = $key
    $encryptor = $des.CreateEncryptor()
    $out = $encryptor.TransformFinalBlock($pwBytes, 0, 8)
    $encryptor.Dispose()
    $des.Dispose()
    return ,$out
}

# Re-derive the TightVNC password from the API key and write it to every
# registry path. Used on key change (reconfigure): the install-time path copies
# the MSI-written blob, which does NOT track a later key change, so without this
# the noVNC viewer (which sends the new key) would fail VNC auth.
function Set-TightVNCPassword {
    param([string]$Plain)

    Write-Host ""
    Write-Host "=== Updating TightVNC password ===" -ForegroundColor Cyan

    if (-not $Plain) {
        Write-Host "  No key provided; skipping VNC password update" -ForegroundColor Yellow
        return
    }

    $enc = ConvertTo-VncPassword -Plain $Plain

    $regPaths = @(
        'HKLM:\SOFTWARE\TightVNC\Server',
        'HKLM:\SOFTWARE\WOW6432Node\TightVNC\Server',
        'HKCU:\SOFTWARE\TightVNC\Server',
        'HKCU:\SOFTWARE\WOW6432Node\TightVNC\Server'
    )

    foreach ($regPath in $regPaths) {
        try {
            if (-not (Test-Path $regPath)) {
                New-Item -Path $regPath -Force | Out-Null
            }
            Set-ItemProperty -Path $regPath -Name 'UseVncAuthentication' -Value 1 -Type DWord -Force
            Set-ItemProperty -Path $regPath -Name 'Password' -Value ([byte[]]$enc) -Type Binary -Force
            Set-ItemProperty -Path $regPath -Name 'ControlPassword' -Value ([byte[]]$enc) -Type Binary -Force
        } catch {
            Write-Host "  WARNING: could not write $regPath ($_)" -ForegroundColor Yellow
        }
    }

    Write-Host "  VNC password updated to match the API key" -ForegroundColor Green
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
        # MSI didn't write the password yet - start the service briefly to let TightVNC initialize it
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
        Write-Host "  VNC authentication may fail - check HKLM:\SOFTWARE\TightVNC\Server" -ForegroundColor Yellow
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
    
    # Disable the Windows service - we run TightVNC in app mode via Setup-TightVNCStartup
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
        Invoke-NativeCommand { git clone --depth 1 https://github.com/novnc/noVNC.git $script:NoVncDir }
        
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
        Invoke-NativeCommand { & $pythonExe -m pip install websockify --quiet }
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
        
        # Install at monorepo root - postinstall runs "turbo run build" which builds
        # magnitude-extract then magnitude-core in correct dependency order
        $bunExe = "$env:USERPROFILE\.bun\bin\bun.exe"
        if (Test-Path $bunExe) {
            Write-Host "  Running bun install (includes build via postinstall)..."
            Invoke-NativeCommand { & $bunExe install }
        } else {
            Write-Host "  Running npm install (includes build via postinstall)..."
            Invoke-NativeCommand { npm install }
        }
        
        # Verify builds succeeded
        # if ((Test-Path $coreDistDir) -and (Test-Path $extractDistDir)) {
        #     Save-DependenciesHash -Dir $script:MagnitudeDir
        #     Write-Host "  magnitude workspace built" -ForegroundColor Green
        # } else {
        #     Write-Host "  WARNING: magnitude build may have failed - dist/ not found" -ForegroundColor Yellow
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

function Install-Chromium {
    # patchright/Playwright's own (node) archive extractor hangs on some Windows
    # VMs right at "extracting archive" (download succeeds, extraction never
    # writes a byte; not Defender/disk — native Expand-Archive of the same zip is
    # instant). Provision Chromium ourselves: download the zip and extract it with
    # Expand-Archive into the exact dir Playwright expects, then drop the
    # INSTALLATION_COMPLETE marker so patchright treats it as already installed
    # and never runs its broken extractor. Falls back to `patchright install` if
    # anything here fails, so we're never worse off than before.
    $browsersRoot = 'C:\ms-playwright'
    $coreDir = Join-Path $script:MagnitudeDir 'packages\magnitude-core'

    $rev = $null
    try {
        $browsersJson = Get-ChildItem -Path $script:MagnitudeDir -Recurse -Filter 'browsers.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'patchright-core' } | Select-Object -First 1
        if (-not $browsersJson) {
            $browsersJson = Get-ChildItem -Path $script:MagnitudeDir -Recurse -Filter 'browsers.json' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match 'playwright-core' } | Select-Object -First 1
        }
        if ($browsersJson) {
            $data = Get-Content $browsersJson.FullName -Raw | ConvertFrom-Json
            $chromium = $data.browsers | Where-Object { $_.name -eq 'chromium' } | Select-Object -First 1
            if ($chromium) { $rev = $chromium.revision }
        }
    } catch {
        Write-Host "  WARNING: Could not read Chromium revision: $_" -ForegroundColor Yellow
    }

    if (-not $rev) {
        Write-Host "  Could not determine Chromium revision; falling back to patchright install..." -ForegroundColor Yellow
        Push-Location $coreDir
        Invoke-NativeCommand { npx --yes patchright install chromium }
        Pop-Location
        return
    }

    $browserDir = Join-Path $browsersRoot "chromium-$rev"
    $chromeExe = Join-Path $browserDir 'chrome-win\chrome.exe'
    $marker = Join-Path $browserDir 'INSTALLATION_COMPLETE'

    if ((Test-Path $chromeExe) -and (Test-Path $marker)) {
        Write-Host "  Chromium already installed (revision $rev)" -ForegroundColor Green
        return
    }

    $url = "https://cdn.playwright.dev/dbazure/download/playwright/builds/chromium/$rev/chromium-win64.zip"
    $zip = Join-Path $env:TEMP "chromium-$rev.zip"
    $ok = $false
    $prevProgress = $ProgressPreference
    try {
        Write-Host "  Downloading Chromium (revision $rev)..."
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop

        Write-Host "  Extracting Chromium (native unzip)..."
        New-Item -ItemType Directory -Force -Path $browserDir | Out-Null
        Expand-Archive -Path $zip -DestinationPath $browserDir -Force -ErrorAction Stop

        if (Test-Path $chromeExe) {
            New-Item -ItemType File -Force -Path $marker | Out-Null
            $ok = $true
            Write-Host "  Chromium installed (revision $rev)" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: chrome.exe not found after extraction." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  WARNING: Manual Chromium provisioning failed: $_" -ForegroundColor Yellow
    } finally {
        $ProgressPreference = $prevProgress
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }

    if (-not $ok) {
        Write-Host "  Falling back to patchright install..." -ForegroundColor Yellow
        Push-Location $coreDir
        Invoke-NativeCommand { npx --yes patchright install chromium }
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
        Invoke-NativeCommand { npm install }
        
        Save-DependenciesHash -Dir $script:AgentServiceDir
        Pop-Location
        
        Write-Host "  Installing Patchright + Chromium (this may take a few minutes)..."
        [System.Environment]::SetEnvironmentVariable('PLAYWRIGHT_BROWSERS_PATH', 'C:\ms-playwright', 'Machine')
        $env:PLAYWRIGHT_BROWSERS_PATH = 'C:\ms-playwright'
        Install-Chromium

        Write-Host "  Dependencies installed" -ForegroundColor Green
    }
}

# =============================================================================
# Tunnel & Device Functions
# =============================================================================

function Install-Rathole {
    Write-Host ""
    Write-Host "=== Installing Rathole ===" -ForegroundColor Cyan
    
    if (Test-Path $script:RatholeExe) {
        Write-Host "  Rathole already installed" -ForegroundColor Green
        return
    }
    
    if (-not (Test-Path $script:RatholeDir)) {
        New-Item -ItemType Directory -Force -Path $script:RatholeDir | Out-Null
    }
    
    Write-Host "  Adding Windows Defender exclusion for rathole directory..."
    try {
        Add-MpPreference -ExclusionPath $script:RatholeDir -ErrorAction Stop
        Write-Host "  Defender exclusion added" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: Could not add Defender exclusion: $_" -ForegroundColor Yellow
    }
    
    $ratholeVersion = "0.5.0"
    $downloadUrl = "https://github.com/rapiz1/rathole/releases/download/v$ratholeVersion/rathole-x86_64-pc-windows-msvc.zip"
    $zipPath = Join-Path $env:TEMP "rathole-$ratholeVersion.zip"
    
    Write-Host "  Downloading rathole v$ratholeVersion..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    
    Write-Host "  Extracting..."
    Expand-Archive -Path $zipPath -DestinationPath $script:RatholeDir -Force
    
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    
    if (Test-Path $script:RatholeExe) {
        Write-Host "  Rathole installed" -ForegroundColor Green
    } else {
        throw "Rathole installation failed -- rathole.exe not found after extraction"
    }
}

function Get-EnvValue {
    param([string]$Key)
    $envFile = Join-Path $script:AgentServiceDir '.env'
    if (Test-Path $envFile) {
        $content = Get-Content $envFile -ErrorAction SilentlyContinue
        foreach ($line in $content) {
            if ($line -match "^$Key=(.*)$") {
                return $matches[1].Trim('"', "'")
            }
        }
    }
    return ""
}

function Set-EnvValue {
    param([string]$Key, [string]$Value)
    $envFile = Join-Path $script:AgentServiceDir '.env'
    
    $envDir = Split-Path -Parent $envFile
    if (-not (Test-Path $envDir)) {
        New-Item -ItemType Directory -Force -Path $envDir | Out-Null
    }
    
    $lines = @()
    $found = $false
    
    if (Test-Path $envFile) {
        $lines = @(Get-Content $envFile -ErrorAction SilentlyContinue)
    }
    
    $newLines = @()
    foreach ($line in $lines) {
        if ($line -match "^$Key=") {
            $newLines += "$Key=$Value"
            $found = $true
        } else {
            $newLines += $line
        }
    }
    
    if (-not $found) {
        $newLines += "$Key=$Value"
    }
    
    $newLines | Out-File -FilePath $envFile -Encoding UTF8
}

function Test-ComposeSelfHostPresent {
    return Test-Path (Join-Path $env:USERPROFILE '.unity\docker-compose.yml')
}

function Apply-ComposeSelfHostMode {
    if (-not (Test-ComposeSelfHostPresent)) {
        return
    }
    $script:SelfHostMode = $true
    Set-Variable -Name OrchestraUrl -Value $script:ComposeSelfHostOrchestraUrl -Scope Script
    Set-Variable -Name UnityCommsUrl -Value $script:ComposeSelfHostCommsUrl -Scope Script
    $script:LinkCoordinator = $true
}

function Explain-OrchestraConnectFailure {
    param(
        [string]$ActionDescription,
        [string]$OrchestraUrl,
        [string]$HttpCode = '000'
    )

    if ($HttpCode -and $HttpCode -ne '000') {
        return $false
    }

    Write-Host "  ERROR: Could not connect to Orchestra at ${OrchestraUrl} while trying to ${ActionDescription}." -ForegroundColor Red
    if ((Test-ComposeSelfHostPresent) -or ($OrchestraUrl -match '127\.0\.0\.1|localhost')) {
        Write-Host "  Orchestra is not reachable on this machine — the Unity Docker stack is probably stopped." -ForegroundColor Yellow
        Write-Host "  Start it first:" -ForegroundColor Yellow
        Write-Host "    unity stack up" -ForegroundColor Yellow
        Write-Host "  Wait until Orchestra responds on port 8000, then register again from tray Settings" -ForegroundColor Yellow
        Write-Host "  (paste your API key) or run:" -ForegroundColor Yellow
        Write-Host "    $($script:ToolsDir)\setup.ps1 -Reconfigure -UnifyKey YOUR_KEY" -ForegroundColor Yellow
    } else {
        Write-Host "  Check that Orchestra is reachable from this machine and your network is connected." -ForegroundColor Yellow
    }
    return $true
}

function Get-AgentServicePort {
    $port = Get-EnvValue -Key 'PORT'
    if ($port -match '^\d+$') {
        return [int]$port
    }
    if ($script:SelfHostMode -or (Get-EnvValue -Key 'SELF_HOST') -eq '1') {
        return $script:SelfHostAgentPort
    }
    return 3000
}

function Get-SelfHostRegistrationUrl {
    return "http://host.docker.internal:$(Get-AgentServicePort)"
}

function Resolve-CoordinatorAgentId {
    param(
        [string]$UnifyKey,
        [string]$OrchestraUrl
    )

    if ($script:CoordinatorAgentId) {
        return $script:CoordinatorAgentId
    }

    $runtimeFile = Join-Path $env:USERPROFILE '.unity\coordinator-runtime.json'
    if (Test-Path $runtimeFile) {
        try {
            $runtime = Get-Content $runtimeFile -Raw | ConvertFrom-Json
            $fromFile = $runtime.coordinatorAgentId
            if (-not $fromFile) { $fromFile = $runtime.coordinator_agent_id }
            if ($fromFile) { return "$fromFile" }
        } catch {}
    }

    $headers = @{ Authorization = "Bearer $UnifyKey" }
    try {
        $resp = Invoke-RestMethod -Method GET `
            -Uri "$($OrchestraUrl.TrimEnd('/'))/assistant" `
            -Headers $headers `
            -ErrorAction Stop
        $items = if ($resp.info) { $resp.info } else { $resp }
        foreach ($item in $items) {
            if ($item.is_coordinator) {
                return "$($item.agent_id)"
            }
        }
    } catch {}
    return $null
}

function Link-DesktopToCoordinator {
    param(
        [string]$UnifyKey,
        [string]$OrchestraUrl,
        [string]$DesktopId,
        [string]$CoordinatorId
    )

    Write-Host ""
    Write-Host "=== Linking Desktop to Coordinator ===" -ForegroundColor Cyan

    $headers = @{
        Authorization = "Bearer $UnifyKey"
        'Content-Type' = 'application/json'
    }
    $body = @{
        assistant_id = [int]$CoordinatorId
        desktop_id = [int]$DesktopId
        filesys_sync = $false
    } | ConvertTo-Json -Compress

    try {
        Invoke-RestMethod -Method POST `
            -Uri "$($OrchestraUrl.TrimEnd('/'))/desktop/link" `
            -Headers $headers `
            -Body $body `
            -ErrorAction Stop | Out-Null
    } catch {
        if (Explain-OrchestraConnectFailure -ActionDescription 'link this desktop to the Coordinator' -OrchestraUrl $OrchestraUrl) {
            return
        }
        Write-Host "  ERROR: Desktop link failed: $_" -ForegroundColor Red
        return
    }

    Write-Host "  Linked desktop ${DesktopId} to Coordinator assistant ${CoordinatorId}" -ForegroundColor Green
}

function Register-SelfHostDesktop {
    param(
        [string]$UnifyKey,
        [string]$OrchestraUrl,
        [string]$DeviceName
    )

    $regUrl = Get-SelfHostRegistrationUrl

    Write-Host ""
    Write-Host "=== Self-Host Desktop Registration ===" -ForegroundColor Cyan
    Write-Host "  Orchestra: $OrchestraUrl" -ForegroundColor Gray
    Write-Host "  Agent URL for Unity CM: $regUrl" -ForegroundColor Gray

    Register-Desktop -UnifyKey $UnifyKey -OrchestraUrl $OrchestraUrl -DeviceName $DeviceName -TunnelUrl $regUrl

    if ($script:LinkCoordinator) {
        $desktopId = Get-EnvValue -Key 'DEVICE_ID'
        $coordinatorId = Resolve-CoordinatorAgentId -UnifyKey $UnifyKey -OrchestraUrl $OrchestraUrl
        if (-not $desktopId -or -not $coordinatorId) {
            Write-Host "  WARNING: Could not link desktop — missing device or coordinator id" -ForegroundColor Yellow
            return
        }
        Link-DesktopToCoordinator -UnifyKey $UnifyKey -OrchestraUrl $OrchestraUrl `
            -DesktopId $desktopId -CoordinatorId $coordinatorId
        Write-Host ""
        Write-Host "  Restart the Unity stack so CM reloads linked desktops:" -ForegroundColor Yellow
        Write-Host "    unity restart" -ForegroundColor Yellow
    }
}

function Register-Tunnel {
    param(
        [string]$UnifyKey,
        [string]$CommsUrl,
        [int]$LocalPort = 3000,
        [string]$TunnelName
    )
    
    Write-Host ""
    Write-Host "=== Registering Tunnel ===" -ForegroundColor Cyan
    
    # Check for existing tunnel
    $existingTunnelId = Get-EnvValue -Key "TUNNEL_ID"
    if ($existingTunnelId) {
        Write-Host "  Tunnel already registered: $existingTunnelId" -ForegroundColor Green
        $existingUrl = Get-EnvValue -Key "TUNNEL_URL"
        if ($existingUrl) {
            Write-Host "  URL: $existingUrl" -ForegroundColor Green
        }
        return
    }
    
    $body = @{ local_port = $LocalPort }
    if ($TunnelName) { $body.name = $TunnelName }
    
    $headers = @{
        Authorization = "Bearer $UnifyKey"
        'Content-Type' = 'application/json'
    }
    
    try {
        $resp = Invoke-RestMethod -Method POST `
            -Uri "$CommsUrl/infra/tunnel/register" `
            -Headers $headers `
            -Body ($body | ConvertTo-Json -Compress) `
            -ErrorAction Stop
    } catch {
        Write-Host "  ERROR: Tunnel registration failed: $_" -ForegroundColor Red
        return
    }
    
    $tunnelId = $resp.tunnel_id
    $tunnelUrl = $resp.url
    $clientConfig = $resp.client_config
    $clientToken = $resp.client_token
    
    # Persist to .env
    Set-EnvValue -Key "TUNNEL_ID" -Value $tunnelId
    Set-EnvValue -Key "TUNNEL_URL" -Value $tunnelUrl
    Set-EnvValue -Key "TUNNEL_TOKEN" -Value $clientToken
    
    # Write rathole client config
    if (-not (Test-Path $script:RatholeDir)) {
        New-Item -ItemType Directory -Force -Path $script:RatholeDir | Out-Null
    }
    $clientConfig | Out-File -FilePath $script:RatholeConfig -Encoding UTF8
    
    Write-Host "  Tunnel registered: $tunnelId" -ForegroundColor Green
    Write-Host "  Public URL: $tunnelUrl" -ForegroundColor Green
    Write-Host "  Config written to: $($script:RatholeConfig)" -ForegroundColor Gray
}

function Start-Tunnel {
    Write-Host ""
    Write-Host "=== Starting Tunnel ===" -ForegroundColor Cyan
    
    if (-not (Test-Path $script:RatholeExe)) {
        Write-Host "  Rathole not installed, skipping tunnel start" -ForegroundColor Yellow
        return
    }
    
    if (-not (Test-Path $script:RatholeConfig)) {
        Write-Host "  No tunnel config found, skipping tunnel start" -ForegroundColor Yellow
        return
    }
    
    # Check if rathole is already running
    $existing = Get-CimInstance Win32_Process -Filter "Name = 'rathole.exe'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  Tunnel already running (PID $($existing.ProcessId))" -ForegroundColor Green
        return
    }
    
    $ratholeLog = Join-Path $script:RatholeDir 'rathole.log'
    
    Write-Host "  Starting rathole tunnel client..." -ForegroundColor Gray
    Start-Process cmd.exe -ArgumentList "/c `"`"$($script:RatholeExe)`" `"$($script:RatholeConfig)`" > `"$ratholeLog`" 2>&1`"" -WindowStyle Hidden
    
    # Wait briefly for the process to start
    Start-Sleep -Seconds 2
    
    $running = Get-CimInstance Win32_Process -Filter "Name = 'rathole.exe'" -ErrorAction SilentlyContinue
    if ($running) {
        $tunnelUrl = Get-EnvValue -Key "TUNNEL_URL"
        Write-Host "  Tunnel running (PID $($running.ProcessId))" -ForegroundColor Green
        if ($tunnelUrl) {
            Write-Host "  Public URL: $tunnelUrl" -ForegroundColor Green
        }
    } else {
        Write-Host "  WARNING: Tunnel may have failed to start. Check log: $ratholeLog" -ForegroundColor Yellow
        if (Test-Path $ratholeLog) {
            Get-Content $ratholeLog -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        }
    }
}

function Stop-Tunnel {
    # Stop rathole process
    $ratholeProcs = Get-CimInstance Win32_Process -Filter "Name = 'rathole.exe'" -ErrorAction SilentlyContinue
    foreach ($proc in $ratholeProcs) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped rathole tunnel (PID $($proc.ProcessId))" -ForegroundColor Green
    }
    
    # Stop parent cmd.exe processes that launched rathole
    $cmdProcs = Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe' AND CommandLine LIKE '%rathole%'" -ErrorAction SilentlyContinue
    foreach ($proc in $cmdProcs) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped rathole cmd wrapper (PID $($proc.ProcessId))" -ForegroundColor Green
    }
}

function Unregister-Tunnel {
    param(
        [string]$UnifyKey,
        [string]$CommsUrl
    )
    
    $tunnelId = Get-EnvValue -Key "TUNNEL_ID"
    if (-not $tunnelId) { return }
    
    Write-Host "  Deleting tunnel $tunnelId..." -ForegroundColor Gray
    
    $headers = @{ Authorization = "Bearer $UnifyKey" }
    try {
        Invoke-RestMethod -Method DELETE `
            -Uri "$CommsUrl/infra/tunnel/$tunnelId" `
            -Headers $headers `
            -ErrorAction Stop | Out-Null
        Write-Host "  Tunnel deleted from server" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: Could not delete tunnel from server: $_" -ForegroundColor Yellow
    }
    
    # Clear local state
    Set-EnvValue -Key "TUNNEL_ID" -Value ""
    Set-EnvValue -Key "TUNNEL_URL" -Value ""
    Set-EnvValue -Key "TUNNEL_TOKEN" -Value ""
    
    # Remove rathole config
    if (Test-Path $script:RatholeConfig) {
        Remove-Item $script:RatholeConfig -Force -ErrorAction SilentlyContinue
    }
}

function Register-Desktop {
    param(
        [string]$UnifyKey,
        [string]$OrchestraUrl,
        [string]$DeviceName,
        [string]$TunnelUrl
    )
    
    Write-Host ""
    Write-Host "=== Registering Desktop ===" -ForegroundColor Cyan
    
    # Check for existing device
    $existingId = Get-EnvValue -Key "DEVICE_ID"
    if ($existingId) {
        Write-Host "  Desktop already registered: ID=$existingId" -ForegroundColor Green
        # Update URL if it changed
        if ($TunnelUrl) {
            Write-Host "  Updating URL to: $TunnelUrl" -ForegroundColor Gray
            $headers = @{
                Authorization = "Bearer $UnifyKey"
                'Content-Type' = 'application/json'
            }
            $body = @{ url = $TunnelUrl } | ConvertTo-Json -Compress
            try {
                Invoke-RestMethod -Method PATCH `
                    -Uri "$OrchestraUrl/desktop/$existingId" `
                    -Headers $headers `
                    -Body $body `
                    -ErrorAction Stop | Out-Null
                Write-Host "  URL updated" -ForegroundColor Green
            } catch {
                if (Explain-OrchestraConnectFailure -ActionDescription 'update the desktop URL' -OrchestraUrl $OrchestraUrl) {
                    Write-Host "  WARNING: Could not update desktop URL (Orchestra unreachable)" -ForegroundColor Yellow
                } else {
                    Write-Host "  WARNING: Could not update desktop URL: $_" -ForegroundColor Yellow
                }
            }
        }
        return
    }
    
    if (-not $TunnelUrl) {
        Write-Host "  ERROR: No desktop URL available for registration" -ForegroundColor Red
        return
    }
    
    if (-not $DeviceName) {
        $DeviceName = "$env:COMPUTERNAME"
    }
    
    $headers = @{
        Authorization = "Bearer $UnifyKey"
        'Content-Type' = 'application/json'
    }
    $body = @{
        name = $DeviceName
        url = $TunnelUrl
        os = "windows"
    } | ConvertTo-Json -Compress
    
    try {
        $resp = Invoke-RestMethod -Method POST `
            -Uri "$OrchestraUrl/desktop" `
            -Headers $headers `
            -Body $body `
            -ErrorAction Stop
    } catch {
        if (Explain-OrchestraConnectFailure -ActionDescription 'register this desktop' -OrchestraUrl $OrchestraUrl) {
            return
        }
        Write-Host "  ERROR: Desktop registration failed: $_" -ForegroundColor Red
        return
    }
    
    $deviceId = $resp.info.id
    Set-EnvValue -Key "DEVICE_ID" -Value $deviceId
    
    Write-Host "  Desktop registered: ID=$deviceId" -ForegroundColor Green
    Write-Host "  Name: $DeviceName" -ForegroundColor Gray
    Write-Host "  URL: $TunnelUrl" -ForegroundColor Gray
}

function Unregister-Desktop {
    param(
        [string]$UnifyKey,
        [string]$OrchestraUrl
    )
    
    $deviceId = Get-EnvValue -Key "DEVICE_ID"
    if (-not $deviceId) { return }
    
    Write-Host "  Deleting desktop $deviceId..." -ForegroundColor Gray
    
    $headers = @{ Authorization = "Bearer $UnifyKey" }
    try {
        Invoke-RestMethod -Method DELETE `
            -Uri "$OrchestraUrl/desktop/$deviceId" `
            -Headers $headers `
            -ErrorAction Stop | Out-Null
        Write-Host "  Desktop deleted from server" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: Could not delete desktop from server (may be assigned to an assistant): $_" -ForegroundColor Yellow
    }
    
    Set-EnvValue -Key "DEVICE_ID" -Value ""
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
    
    # Preserve existing tunnel/device values if .env already exists
    $existingTunnelId = Get-EnvValue -Key "TUNNEL_ID"
    $existingTunnelUrl = Get-EnvValue -Key "TUNNEL_URL"
    $existingTunnelToken = Get-EnvValue -Key "TUNNEL_TOKEN"
    $existingDeviceId = Get-EnvValue -Key "DEVICE_ID"
    $agentPort = Get-AgentServicePort
    $selfHostFlag = if ($script:SelfHostMode) { '1' } else { '0' }
    
    $envContent = @"
# Agent Service Environment Configuration
# Generated: $(Get-Date)

PORT=$agentPort
UNIFY_KEY=$UnifyKey
ORCHESTRA_URL=$OrchestraUrl
UNITY_COMMS_URL=$UnityCommsUrl
SELF_HOST=$selfHostFlag
PLAYWRIGHT_BROWSERS_PATH=C:\ms-playwright

# Tunnel & Device (managed by setup/registration)
TUNNEL_ID=$existingTunnelId
TUNNEL_URL=$existingTunnelUrl
TUNNEL_TOKEN=$existingTunnelToken
DEVICE_ID=$existingDeviceId
"@
    
    $envContent | Out-File -FilePath $envFile -Encoding UTF8
    
    Write-Host "  .env created" -ForegroundColor Green
    Write-Host "    UNIFY_KEY: $(if ($UnifyKey) { '(set)' } else { '(not set)' })" -ForegroundColor Gray
    Write-Host "    ORCHESTRA_URL: $OrchestraUrl" -ForegroundColor Gray
    Write-Host "    UNITY_COMMS_URL: $UnityCommsUrl" -ForegroundColor Gray
    if ($existingDeviceId) {
        Write-Host "    DEVICE_ID: $existingDeviceId (preserved)" -ForegroundColor Gray
    }
    if ($existingTunnelId) {
        Write-Host "    TUNNEL_ID: $existingTunnelId (preserved)" -ForegroundColor Gray
    }
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
set PLAYWRIGHT_BROWSERS_PATH=C:\ms-playwright
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
    
    $agentPort = Get-AgentServicePort
    $rules = @(
        @{ Name = 'Unify-noVNC'; Port = 6080; Description = 'noVNC WebSocket' },
        @{ Name = 'Unify-AgentService'; Port = $agentPort; Description = 'Agent Service API' }
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

    $agentPort = Get-AgentServicePort

    # Refresh PATH from the registry so Node/npx resolve here. When this runs
    # from a long-lived process with a stale PATH (e.g. the tray app invoking
    # -Reconfigure/-Start before its environment knew about Node), the agent's
    # `cmd /c ... npx ...` child would otherwise fail with "npx is not
    # recognized". Full installs refresh PATH during Install-NodeJS/Bun; the
    # reconfigure/start paths skip that, so do it here for all entry points.
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

    # Start TightVNC (only if not already running)
    $tvnExe = 'C:\Program Files\TightVNC\tvnserver.exe'
    if ((Test-Path $tvnExe) -and -not (Test-PortListening -Port 5900)) {
        # Stop existing service if registered (may not be how it was started)
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
    if (-not (Test-PortListening -Port $agentPort)) {
        Write-Host "  Starting Agent Service on port ${agentPort}..." -ForegroundColor Gray
        Start-Process cmd.exe -ArgumentList "/c cd /d `"$($script:AgentServiceDir)`" & npx -y ts-node src/index.ts > `"$agentLog`" 2>&1" -WindowStyle Hidden
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
        $agentUp = Test-PortListening -Port $agentPort
        
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
    
    if (Test-PortListening -Port $agentPort) {
        Write-Host "  [OK] Agent Service (port ${agentPort})" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Agent Service (port ${agentPort})" -ForegroundColor Red
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
    
    # The tunnel forwards the agent port to the cloud; skip it in self-host mode.
    if ($allOk -and -not $script:SelfHostMode -and (Get-EnvValue -Key 'SELF_HOST') -ne '1') {
        Start-Tunnel
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
    Write-Host "Local URLs:" -ForegroundColor Cyan
    
    $agentPort = Get-AgentServicePort
    $vncUrl = "http://localhost:6080/custom.html"
    if ($UnifyKey) {
        $vncUrl += "?password=$UnifyKey"
    }
    
    Write-Host "  Desktop:       $vncUrl" -ForegroundColor Green
    Write-Host "  Agent Service: http://localhost:${agentPort}" -ForegroundColor Green
    
    # Tunnel & Device info
    $tunnelUrl = Get-EnvValue -Key "TUNNEL_URL"
    $tunnelId = Get-EnvValue -Key "TUNNEL_ID"
    $deviceId = Get-EnvValue -Key "DEVICE_ID"
    
    if ($tunnelUrl -and -not $script:SelfHostMode -and (Get-EnvValue -Key 'SELF_HOST') -ne '1') {
        Write-Host ""
        Write-Host "Public Access:" -ForegroundColor Cyan
        Write-Host "  Tunnel URL:  $tunnelUrl" -ForegroundColor Green
        Write-Host "  Tunnel ID:   $tunnelId" -ForegroundColor Gray
    }
    
    if ($deviceId) {
        Write-Host ""
        Write-Host "Device Registration:" -ForegroundColor Cyan
        Write-Host "  Device ID:   $deviceId" -ForegroundColor Green
    }
    
    Write-Host ""
    Write-Host "Time elapsed: $([math]::Round($elapsed.TotalSeconds, 1)) seconds" -ForegroundColor Magenta
    Write-Host ""
}

# =============================================================================
# Main Execution
# =============================================================================

# Handle start command (just start services, no install/config - no admin needed)
if ($Start) {
    Start-AllServices
    exit 0
}

# Handle stop command
if ($Stop) {
    Stop-AllServices
    exit 0
}

# Handle uninstall command
if ($Uninstall) {
    Uninstall-All
    exit 0
}

# Handle reconfigure (lightweight key update: re-apply key + VNC password +
# re-register + restart services). Used by the tray when the API key changes.
# It deliberately skips dependency installs and Setup-*Startup (the scheduled
# tasks already exist). Requires admin: it writes the TightVNC password to HKLM
# and restarts the per-service processes.
if ($Reconfigure) {
    Write-Host ""
    Write-Host "Reconfigure mode" -ForegroundColor Yellow

    if (-not $UnifyKey) {
        Write-Host "ERROR: -Reconfigure requires -UnifyKey" -ForegroundColor Red
        exit 1
    }

    # Settings only changes the API key — preserve the URLs baked at install,
    # otherwise Setup-AgentServiceEnv would reset them to the script defaults
    # and break a staging/custom install.
    Apply-ComposeSelfHostMode
    if (-not (Test-ComposeSelfHostPresent)) {
        $existingOrch = Get-EnvValue -Key "ORCHESTRA_URL"
        $existingComms = Get-EnvValue -Key "UNITY_COMMS_URL"
        if ($existingOrch) { $OrchestraUrl = $existingOrch }
        if ($existingComms) { $UnityCommsUrl = $existingComms }
        if ((Get-EnvValue -Key 'SELF_HOST') -eq '1') {
            $script:SelfHostMode = $true
            if (-not $existingOrch) { $OrchestraUrl = $script:ComposeSelfHostOrchestraUrl }
            if (-not $existingComms) { $UnityCommsUrl = $script:ComposeSelfHostCommsUrl }
            $script:LinkCoordinator = $true
        }
    }

    # Rewrite .env (preserves TUNNEL_*/DEVICE_ID) and re-apply the VNC password
    # so the TightVNC server matches the new key (noVNC sends the key as the
    # VNC password). Without this the viewer would fail after a key change.
    Setup-AgentServiceEnv -UnifyKey $UnifyKey -OrchestraUrl $OrchestraUrl -UnityCommsUrl $UnityCommsUrl
    Set-TightVNCPassword -Plain $UnifyKey

    # Restart services so the agent picks up the new key (it reads UNIFY_KEY at
    # process start).
    Stop-AllServices

    if ($script:SelfHostMode) {
        if (-not $OrchestraUrl) { $OrchestraUrl = $script:ComposeSelfHostOrchestraUrl }
        Register-SelfHostDesktop -UnifyKey $UnifyKey -OrchestraUrl $OrchestraUrl -DeviceName $DeviceName
    } else {
        Register-Tunnel -UnifyKey $UnifyKey -CommsUrl $UnityCommsUrl -LocalPort (Get-AgentServicePort) -TunnelName $DeviceName
        $tunnelUrl = Get-EnvValue -Key "TUNNEL_URL"
        if ($tunnelUrl) {
            Register-Desktop -UnifyKey $UnifyKey -OrchestraUrl $OrchestraUrl -DeviceName $DeviceName -TunnelUrl $tunnelUrl
        }
    }

    Start-AllServices
    exit 0
}

# Validate required parameters
if (-not $UnifyKey) {
    Write-Host "ERROR: -UnifyKey is required" -ForegroundColor Red
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Cyan
    Write-Host "  .\setup.ps1 -UnifyKey 'your-key' [-OrchestraUrl 'https://api.unify.ai/v0'] [-UnityCommsUrl 'https://...']"
    Write-Host "  .\setup.ps1 -Start"
    Write-Host "  .\setup.ps1 -Stop"
    Write-Host "  .\setup.ps1 -Uninstall"
    Write-Host "  .\setup.ps1 -Reconfigure -UnifyKey 'your-key'"
    Write-Host ""
    exit 1
}

try {
    # Detect fast mode
    $fastMode = (Test-FastMode) -and -not $Force

    if ($fastMode) {
        Write-Host ""
        Write-Host "Fast mode: All components installed, skipping installations" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "Full install mode" -ForegroundColor Yellow

        # Exclude install + browser dirs from Defender up front. Real-time
        # scanning of the many files written by bun/npm/patchright throttles the
        # install to a crawl and makes it look hung at random points.
        Add-DefenderExclusions

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
        Install-Rathole
    }

    # Always run configuration
    Apply-ComposeSelfHostMode
    if ($script:SelfHostMode) {
        if (-not $OrchestraUrl) { $OrchestraUrl = $script:ComposeSelfHostOrchestraUrl }
        if (-not $UnityCommsUrl) { $UnityCommsUrl = $script:ComposeSelfHostCommsUrl }
        $script:LinkCoordinator = $true
    }
    Configure-TightVNC -Password $UnifyKey
    Setup-AgentServiceEnv -UnifyKey $UnifyKey -OrchestraUrl $OrchestraUrl -UnityCommsUrl $UnityCommsUrl
    Setup-TightVNCStartup
    Setup-WebsockifyStartup
    Setup-AgentServiceStartup
    Configure-Firewall

    # Start services (includes tunnel start after local services are up)
    Start-AllServices

    if ($script:SelfHostMode) {
        Register-SelfHostDesktop -UnifyKey $UnifyKey -OrchestraUrl $OrchestraUrl -DeviceName $DeviceName
    } else {
        Register-Tunnel -UnifyKey $UnifyKey -CommsUrl $UnityCommsUrl -LocalPort (Get-AgentServicePort) -TunnelName $DeviceName
        
        $tunnelUrl = Get-EnvValue -Key "TUNNEL_URL"
        if ($tunnelUrl) {
            # Ensure tunnel is running with the freshly-written config
            Start-Tunnel
            Register-Desktop -UnifyKey $UnifyKey -OrchestraUrl $OrchestraUrl -DeviceName $DeviceName -TunnelUrl $tunnelUrl
        }
    }

    # Show summary
    Show-Summary -UnifyKey $UnifyKey
    exit 0
} catch {
    Write-Host ""
    Write-Host "===========================================" -ForegroundColor Red
    Write-Host "  Setup FAILED" -ForegroundColor Red
    Write-Host "===========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Press any key to close this window..." -ForegroundColor Yellow
    cmd /c pause | Out-Null
    exit 1
}
