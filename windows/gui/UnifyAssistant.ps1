# UnifyAssistant.ps1 - System Tray GUI Application
# 
# A Windows Forms application that provides a system tray icon
# for managing Unify Desktop Assistant services.
#
# Features:
# - System tray icon with status colors
# - Start/Stop services
# - Settings configuration
# - Quick links to desktop viewer and API

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =============================================================================
# Configuration
# =============================================================================

$script:AppName = "Unify Desktop Assistant"
$script:InstallDir = Split-Path -Parent $PSScriptRoot
$script:ToolsDir = Join-Path $script:InstallDir 'tools'
$script:AgentServiceDir = Join-Path $script:InstallDir 'agent-service'
$script:SetupScript = Join-Path $script:ToolsDir 'setup.ps1'
$script:EnvFile = Join-Path $script:AgentServiceDir '.env'
$script:SettingsFile = Join-Path $script:InstallDir 'settings.json'
$script:IconPath = Join-Path $script:InstallDir 'assets\icon.ico'

# Service ports
$script:VncPort = 5900
$script:NoVncPort = 6080

# Status check interval (ms)
$script:StatusInterval = 5000

# =============================================================================
# Helper Functions
# =============================================================================

function Get-ServiceStatus {
    # Use a single .NET call to get all listening ports (fast, no WMI/CIM overhead)
    try {
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        $listeningPorts = @($listeners | ForEach-Object { $_.Port })
    } catch {
        $listeningPorts = @()
    }

    $vnc = $listeningPorts -contains $script:VncPort
    $novnc = $listeningPorts -contains $script:NoVncPort
    $agent = $listeningPorts -contains (Get-AgentPort)
    
    # Check if rathole tunnel is running
    $tunnel = $false
    try {
        $ratholeProc = Get-CimInstance Win32_Process -Filter "Name = 'rathole.exe'" -ErrorAction SilentlyContinue
        $tunnel = $null -ne $ratholeProc
    } catch {}

    return @{
        VNC = $vnc
        NoVNC = $novnc
        Agent = $agent
        Tunnel = $tunnel
        AllRunning = ($vnc -and $novnc -and $agent)
        AnyRunning = ($vnc -or $novnc -or $agent)
    }
}

function Get-Settings {
    if (Test-Path $script:SettingsFile) {
        try {
            return Get-Content $script:SettingsFile | ConvertFrom-Json
        } catch {
            return $null
        }
    }
    return $null
}

function Save-Settings {
    param($Settings)
    $Settings | ConvertTo-Json | Out-File -FilePath $script:SettingsFile -Encoding UTF8
}

function Get-EnvValue {
    param([string]$Key)
    if (Test-Path $script:EnvFile) {
        $content = Get-Content $script:EnvFile -ErrorAction SilentlyContinue
        foreach ($line in $content) {
            if ($line -match "^$Key=(.*)$") {
                return $matches[1].Trim('"', "'")
            }
        }
    }
    return ""
}

function Test-ComposeSelfHostPresent {
    return Test-Path (Join-Path $env:USERPROFILE '.unity\docker-compose.yml')
}

function Get-AgentPort {
    $raw = Get-EnvValue -Key 'PORT'
    if ($raw -match '^\d+$') {
        return [int]$raw
    }
    if (Test-ComposeSelfHostPresent) {
        return 13000
    }
    return 3000
}

function Set-EnvValue {
    param([string]$Key, [string]$Value)
    
    $envDir = Split-Path -Parent $script:EnvFile
    if (-not (Test-Path $envDir)) {
        New-Item -ItemType Directory -Force -Path $envDir | Out-Null
    }
    
    $lines = @()
    $found = $false
    
    if (Test-Path $script:EnvFile) {
        $lines = @(Get-Content $script:EnvFile -ErrorAction SilentlyContinue)
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
    
    $newLines | Out-File -FilePath $script:EnvFile -Encoding UTF8
}

# =============================================================================
# Service Control
# =============================================================================

function Start-Services {
    $key = Get-EnvValue -Key "UNIFY_KEY"
    if (-not $key) {
        [System.Windows.Forms.MessageBox]::Show(
            "Please configure your Unify API Key in Settings first.",
            "Configuration Required",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }
    
    # Run setup.ps1 -Start in background (just starts services, no admin needed)
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($script:SetupScript)`" -Start" -WindowStyle Hidden
}

function Stop-Services {
    # Run setup.ps1 -Stop in background
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($script:SetupScript)`" -Stop" -WindowStyle Hidden
}

# =============================================================================
# Tray Icon
# =============================================================================

function Get-TrayIcon {
    param([string]$Status)
    
    $size = 16
    $bitmap = New-Object System.Drawing.Bitmap($size, $size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    
    # Background
    $graphics.Clear([System.Drawing.Color]::Transparent)
    
    # Status color
    $color = switch ($Status) {
        "running" { [System.Drawing.Color]::FromArgb(255, 76, 175, 80) }   # Green
        "partial" { [System.Drawing.Color]::FromArgb(255, 255, 193, 7) }   # Yellow
        "stopped" { [System.Drawing.Color]::FromArgb(255, 244, 67, 54) }   # Red
        default   { [System.Drawing.Color]::FromArgb(255, 158, 158, 158) } # Gray
    }
    
    # Draw logo icon if available, otherwise fall back to solid circle
    if (Test-Path $script:IconPath) {
        try {
            $icon = New-Object System.Drawing.Icon($script:IconPath, $size, $size)
            $graphics.DrawIcon($icon, 0, 0)
            $icon.Dispose()
        } catch {
            # Fallback: draw solid colored circle
            $brush = New-Object System.Drawing.SolidBrush($color)
            $graphics.FillEllipse($brush, 2, 2, 12, 12)
            $brush.Dispose()
        }
    } else {
        # Fallback: draw solid colored circle
        $brush = New-Object System.Drawing.SolidBrush($color)
        $graphics.FillEllipse($brush, 2, 2, 12, 12)
        $brush.Dispose()
    }
    
    # Draw status overlay dot (6px) in bottom-right corner
    $dotSize = 6
    $dotX = $size - $dotSize
    $dotY = $size - $dotSize
    
    # Dark border for visibility
    $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 30, 30, 30), 1)
    $statusBrush = New-Object System.Drawing.SolidBrush($color)
    $graphics.FillEllipse($statusBrush, $dotX, $dotY, $dotSize - 1, $dotSize - 1)
    $graphics.DrawEllipse($borderPen, $dotX, $dotY, $dotSize - 1, $dotSize - 1)
    $statusBrush.Dispose()
    $borderPen.Dispose()
    
    $graphics.Dispose()
    
    $hIcon = $bitmap.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    # Clone so we can free the native handle and bitmap immediately
    $cloned = [System.Drawing.Icon]$icon.Clone()
    $icon.Dispose()
    $bitmap.Dispose()
    return $cloned
}

# Track last status to avoid recreating icons unnecessarily
$script:LastStatusKey = ""

function Update-TrayStatus {
    try {
        # Check for graceful shutdown signal (created by uninstaller/upgrader)
        $shutdownFile = Join-Path $script:InstallDir 'uninstall.signal'
        if (Test-Path $shutdownFile) {
            Remove-Item $shutdownFile -Force -ErrorAction SilentlyContinue
            $script:NotifyIcon.Visible = $false
            $script:NotifyIcon.Dispose()
            $appContext.ExitThread()
            [System.Windows.Forms.Application]::Exit()
            return
        }
        
        $status = Get-ServiceStatus
        
        if ($status.AllRunning) {
            $statusKey = "running"
            $statusText = "Running"
        } elseif ($status.AnyRunning) {
            $statusKey = "partial"
            $statusText = "Partial"
        } else {
            $statusKey = "stopped"
            $statusText = "Stopped"
        }
        
        # Append tunnel status
        $tunnelText = if ($status.Tunnel) { "Connected" } else { "Disconnected" }
        
        # Only recreate icon when status actually changes (avoids GDI work every tick)
        if ($script:LastStatusKey -ne $statusKey) {
            $script:LastStatusKey = $statusKey
            $oldIcon = $script:NotifyIcon.Icon
            $script:NotifyIcon.Icon = Get-TrayIcon -Status $statusKey
            if ($oldIcon) {
                try { $oldIcon.Dispose() } catch {}
            }
        }
        
        $script:NotifyIcon.Text = "$($script:AppName)`nServices: $statusText | Tunnel: $tunnelText"
        $script:StatusMenuItem.Text = "Services: $statusText | Tunnel: $tunnelText"
    } catch {
        # Silently ignore errors to prevent UI thread from freezing
    }
}

# =============================================================================
# Settings Dialog
# =============================================================================

function Invoke-Reconfigure {
    param([string]$Key)

    # Re-run setup elevated so the new key takes effect: setup.ps1 -Reconfigure
    # rewrites .env (preserving baked URLs + tunnel/device IDs), updates the
    # TightVNC password to match the key, re-registers, and restarts services.
    # It needs admin (writes HKLM + restarts service processes), so we relaunch
    # via UAC. The key is passed as an argument, matching -Start/-Stop usage.
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", "`"$($script:SetupScript)`"",
            "-Reconfigure", "-UnifyKey", "`"$Key`""
        )
        $script:NotifyIcon.ShowBalloonTip(
            3000, "Updating",
            "Applying new API key and restarting services...",
            [System.Windows.Forms.ToolTipIcon]::Info
        )
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not start reconfigure (elevation was cancelled or failed). The new key was saved but services were not restarted.",
            "Reconfigure",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }
}

function Invoke-Uninstall {
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This will stop all services, unregister this device, and remove Unify Desktop Assistant from this computer.`n`nThis cannot be undone.`n`nUninstall now?",
        "Uninstall Unify Desktop Assistant?",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    # Prefer the Inno Setup uninstaller: it self-elevates, runs setup.ps1
    # -Uninstall, and removes the install dir + the HKCU Run key. Fall back to an
    # elevated setup.ps1 -Uninstall for dev installs without the uninstaller.
    $uninst = $null
    foreach ($name in @('unins000.exe', 'unins001.exe', 'unins002.exe')) {
        $candidate = Join-Path $script:InstallDir $name
        if (Test-Path $candidate) { $uninst = $candidate; break }
    }

    try {
        if ($uninst) {
            Start-Process -FilePath $uninst -ArgumentList "/SILENT"
        } else {
            Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", "`"$($script:SetupScript)`"", "-Uninstall"
            )
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Uninstall could not be started (elevation was cancelled or failed).",
            "Uninstall",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    # Quit the tray so it doesn't hold files open during removal.
    $script:NotifyIcon.Visible = $false
    $script:NotifyIcon.Dispose()
    $appContext.ExitThread()
    [System.Windows.Forms.Application]::Exit()
}

function Show-SettingsDialog {
    $script:OldUnifyKey = Get-EnvValue -Key "UNIFY_KEY"
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Settings"
    $form.Size = New-Object System.Drawing.Size(450, 480)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    
    $yPos = 20
    
    # Unify Key Label
    $lblKey = New-Object System.Windows.Forms.Label
    $lblKey.Text = "Unify API Key:"
    $lblKey.Location = New-Object System.Drawing.Point(20, $yPos)
    $lblKey.Size = New-Object System.Drawing.Size(100, 20)
    $form.Controls.Add($lblKey)
    $yPos += 25
    
    # Unify Key TextBox
    $txtKey = New-Object System.Windows.Forms.TextBox
    $txtKey.Location = New-Object System.Drawing.Point(20, $yPos)
    $txtKey.Size = New-Object System.Drawing.Size(320, 25)
    $txtKey.UseSystemPasswordChar = $true
    $txtKey.Text = Get-EnvValue -Key "UNIFY_KEY"
    $form.Controls.Add($txtKey)
    
    # Show/Hide Button
    $btnShow = New-Object System.Windows.Forms.Button
    $btnShow.Text = "Show"
    $btnShow.Location = New-Object System.Drawing.Point(350, ($yPos - 2))
    $btnShow.Size = New-Object System.Drawing.Size(60, 27)
    $btnShow.Add_Click({
        if ($txtKey.UseSystemPasswordChar) {
            $txtKey.UseSystemPasswordChar = $false
            $btnShow.Text = "Hide"
        } else {
            $txtKey.UseSystemPasswordChar = $true
            $btnShow.Text = "Show"
        }
    })
    $form.Controls.Add($btnShow)
    $yPos += 40
    
    # Orchestra URL Label
    $lblUrl = New-Object System.Windows.Forms.Label
    $lblUrl.Text = "Orchestra URL:"
    $lblUrl.Location = New-Object System.Drawing.Point(20, $yPos)
    $lblUrl.Size = New-Object System.Drawing.Size(100, 20)
    $form.Controls.Add($lblUrl)
    $yPos += 25
    
    # Orchestra URL TextBox (read-only)
    $txtUrl = New-Object System.Windows.Forms.TextBox
    $txtUrl.Location = New-Object System.Drawing.Point(20, $yPos)
    $txtUrl.Size = New-Object System.Drawing.Size(390, 25)
    $txtUrl.Text = Get-EnvValue -Key "ORCHESTRA_URL"
    if (-not $txtUrl.Text) { $txtUrl.Text = "https://api.unify.ai/v0" }
    $txtUrl.ReadOnly = $true
    $txtUrl.BackColor = [System.Drawing.SystemColors]::Control
    $form.Controls.Add($txtUrl)
    $yPos += 40
    
    # Unity Comms URL Label
    $lblComms = New-Object System.Windows.Forms.Label
    $lblComms.Text = "Unity Comms URL:"
    $lblComms.Location = New-Object System.Drawing.Point(20, $yPos)
    $lblComms.Size = New-Object System.Drawing.Size(120, 20)
    $form.Controls.Add($lblComms)
    $yPos += 25
    
    # Unity Comms URL TextBox (read-only)
    $txtComms = New-Object System.Windows.Forms.TextBox
    $txtComms.Location = New-Object System.Drawing.Point(20, $yPos)
    $txtComms.Size = New-Object System.Drawing.Size(390, 25)
    $txtComms.Text = Get-EnvValue -Key "UNITY_COMMS_URL"
    if (-not $txtComms.Text) { $txtComms.Text = "https://service.a.run.app" }
    $txtComms.ReadOnly = $true
    $txtComms.BackColor = [System.Drawing.SystemColors]::Control
    $form.Controls.Add($txtComms)
    $yPos += 40
    
    # --- Device & Tunnel Info (read-only) ---
    $deviceId = Get-EnvValue -Key "DEVICE_ID"
    $tunnelId = Get-EnvValue -Key "TUNNEL_ID"
    $tunnelUrl = Get-EnvValue -Key "TUNNEL_URL"
    
    # Group label
    $lblDevice = New-Object System.Windows.Forms.Label
    $lblDevice.Text = "Device & Tunnel:"
    $lblDevice.Location = New-Object System.Drawing.Point(20, $yPos)
    $lblDevice.Size = New-Object System.Drawing.Size(120, 20)
    $lblDevice.Font = New-Object System.Drawing.Font($lblDevice.Font, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblDevice)
    $yPos += 25
    
    # Device ID
    $lblDeviceId = New-Object System.Windows.Forms.Label
    $lblDeviceId.Text = "Device ID:"
    $lblDeviceId.Location = New-Object System.Drawing.Point(20, $yPos)
    $lblDeviceId.Size = New-Object System.Drawing.Size(80, 20)
    $form.Controls.Add($lblDeviceId)
    
    $txtDeviceId = New-Object System.Windows.Forms.TextBox
    $txtDeviceId.Location = New-Object System.Drawing.Point(105, $yPos)
    $txtDeviceId.Size = New-Object System.Drawing.Size(305, 22)
    $txtDeviceId.Text = if ($deviceId) { $deviceId } else { "(not registered)" }
    $txtDeviceId.ReadOnly = $true
    $txtDeviceId.BackColor = [System.Drawing.SystemColors]::Control
    $form.Controls.Add($txtDeviceId)
    $yPos += 28
    
    # Tunnel ID
    $lblTunnelId = New-Object System.Windows.Forms.Label
    $lblTunnelId.Text = "Tunnel ID:"
    $lblTunnelId.Location = New-Object System.Drawing.Point(20, $yPos)
    $lblTunnelId.Size = New-Object System.Drawing.Size(80, 20)
    $form.Controls.Add($lblTunnelId)
    
    $txtTunnelId = New-Object System.Windows.Forms.TextBox
    $txtTunnelId.Location = New-Object System.Drawing.Point(105, $yPos)
    $txtTunnelId.Size = New-Object System.Drawing.Size(305, 22)
    $txtTunnelId.Text = if ($tunnelId) { $tunnelId } else { "(not registered)" }
    $txtTunnelId.ReadOnly = $true
    $txtTunnelId.BackColor = [System.Drawing.SystemColors]::Control
    $form.Controls.Add($txtTunnelId)
    $yPos += 28
    
    # Public URL
    $lblPublicUrl = New-Object System.Windows.Forms.Label
    $lblPublicUrl.Text = "Public URL:"
    $lblPublicUrl.Location = New-Object System.Drawing.Point(20, $yPos)
    $lblPublicUrl.Size = New-Object System.Drawing.Size(80, 20)
    $form.Controls.Add($lblPublicUrl)
    
    $txtPublicUrl = New-Object System.Windows.Forms.TextBox
    $txtPublicUrl.Location = New-Object System.Drawing.Point(105, $yPos)
    $txtPublicUrl.Size = New-Object System.Drawing.Size(305, 22)
    $txtPublicUrl.Text = if ($tunnelUrl) { $tunnelUrl } else { "(not available)" }
    $txtPublicUrl.ReadOnly = $true
    $txtPublicUrl.BackColor = [System.Drawing.SystemColors]::Control
    $form.Controls.Add($txtPublicUrl)
    $yPos += 40
    
    # Startup Options (always enabled, not user-editable)
    $chkStartup = New-Object System.Windows.Forms.CheckBox
    $chkStartup.Text = "Start on Windows login"
    $chkStartup.Location = New-Object System.Drawing.Point(20, $yPos)
    $chkStartup.Size = New-Object System.Drawing.Size(200, 25)
    $chkStartup.Checked = $true
    $chkStartup.Enabled = $false
    $form.Controls.Add($chkStartup)
    $yPos += 25
    
    # Auto-start services (always enabled, not user-editable)
    $chkAutoStart = New-Object System.Windows.Forms.CheckBox
    $chkAutoStart.Text = "Start services automatically"
    $chkAutoStart.Location = New-Object System.Drawing.Point(20, $yPos)
    $chkAutoStart.Size = New-Object System.Drawing.Size(200, 25)
    $chkAutoStart.Checked = $true
    $chkAutoStart.Enabled = $false
    $form.Controls.Add($chkAutoStart)
    $yPos += 40
    
    # Save Button
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(230, $yPos)
    $btnSave.Size = New-Object System.Drawing.Size(80, 30)
    $btnSave.Add_Click({
        # Persist only the API key here. The URLs are baked at install and are
        # preserved by setup.ps1 -Reconfigure, so we don't rewrite them from the
        # (read-only) fields and risk clobbering a staging/custom URL.
        $newKey = $txtKey.Text.Trim()
        Set-EnvValue -Key "UNIFY_KEY" -Value $newKey
        
        # Ensure startup registry key is always set
        $startupPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        $exePath = Join-Path $script:InstallDir "gui\UnifyAssistant.ps1"
        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$exePath`""
        Set-ItemProperty -Path $startupPath -Name "UnifyAssistant" -Value $cmd
        
        # Save settings (always auto-start)
        Save-Settings @{
            AutoStartServices = $true
        }
        
        # If the key actually changed, re-run setup so services restart and the
        # VNC password is updated to match. Writing .env alone leaves the old key
        # live in the running agent and the old VNC password on the server.
        if ($newKey -and $newKey -ne $script:OldUnifyKey) {
            Invoke-Reconfigure -Key $newKey
        }
        
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($btnSave)
    
    # Cancel Button
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(320, $yPos)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 30)
    $btnCancel.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })
    $form.Controls.Add($btnCancel)
    
    $form.ShowDialog()
}

# =============================================================================
# Log Viewer
# =============================================================================

function Show-LogViewer {
    $logFile = Join-Path $script:AgentServiceDir "agent.log"
    
    if (Test-Path $logFile) {
        Start-Process notepad.exe -ArgumentList $logFile
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "Log file not found: $logFile",
            "Log Viewer",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
}

# =============================================================================
# Main Application
# =============================================================================

# Create application context
$appContext = New-Object System.Windows.Forms.ApplicationContext

# Create notify icon
$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:NotifyIcon.Visible = $true
$script:NotifyIcon.Icon = Get-TrayIcon -Status "stopped"
$script:NotifyIcon.Text = $script:AppName

# Create context menu
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

# Title (disabled)
$titleItem = New-Object System.Windows.Forms.ToolStripMenuItem
$titleItem.Text = $script:AppName
$titleItem.Enabled = $false
$titleItem.Font = New-Object System.Drawing.Font($titleItem.Font, [System.Drawing.FontStyle]::Bold)
$contextMenu.Items.Add($titleItem) | Out-Null

# Status
$script:StatusMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:StatusMenuItem.Text = "Status: Stopped"
$script:StatusMenuItem.Enabled = $false
$contextMenu.Items.Add($script:StatusMenuItem) | Out-Null

# Separator
$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Start Services
$startItem = New-Object System.Windows.Forms.ToolStripMenuItem
$startItem.Text = "Start Services"
$startItem.Add_Click({ Start-Services })
$contextMenu.Items.Add($startItem) | Out-Null

# Stop Services
$stopItem = New-Object System.Windows.Forms.ToolStripMenuItem
$stopItem.Text = "Stop Services"
$stopItem.Add_Click({ Stop-Services })
$contextMenu.Items.Add($stopItem) | Out-Null

# Separator
$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Copy Public URL
$copyUrlItem = New-Object System.Windows.Forms.ToolStripMenuItem
$copyUrlItem.Text = "Copy Public URL"
$copyUrlItem.Add_Click({
    $tunnelUrl = Get-EnvValue -Key "TUNNEL_URL"
    if ($tunnelUrl) {
        [System.Windows.Forms.Clipboard]::SetText($tunnelUrl)
        $script:NotifyIcon.ShowBalloonTip(2000, "Copied", "Public URL copied to clipboard", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "No public URL available. Run setup first to register a tunnel.",
            "No Public URL",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
})
$contextMenu.Items.Add($copyUrlItem) | Out-Null

# Separator
$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Settings
$settingsItem = New-Object System.Windows.Forms.ToolStripMenuItem
$settingsItem.Text = "Settings..."
$settingsItem.Add_Click({ Show-SettingsDialog })
$contextMenu.Items.Add($settingsItem) | Out-Null

# View Logs
$logsItem = New-Object System.Windows.Forms.ToolStripMenuItem
$logsItem.Text = "View Logs..."
$logsItem.Add_Click({ Show-LogViewer })
$contextMenu.Items.Add($logsItem) | Out-Null

# Separator
$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Uninstall
$uninstallItem = New-Object System.Windows.Forms.ToolStripMenuItem
$uninstallItem.Text = "Uninstall..."
$uninstallItem.Add_Click({ Invoke-Uninstall })
$contextMenu.Items.Add($uninstallItem) | Out-Null

# Exit
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitItem.Text = "Exit"
$exitItem.Add_Click({
    $script:NotifyIcon.Visible = $false
    $script:NotifyIcon.Dispose()
    $appContext.ExitThread()
    [System.Windows.Forms.Application]::Exit()
})
$contextMenu.Items.Add($exitItem) | Out-Null

$script:NotifyIcon.ContextMenuStrip = $contextMenu

# Double-click to open settings
$script:NotifyIcon.Add_DoubleClick({ Show-SettingsDialog })

# Status update timer
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $script:StatusInterval
$timer.Add_Tick({ Update-TrayStatus })
$timer.Start()

# Initial status update
Update-TrayStatus

# Auto-start services (always enabled)
$key = Get-EnvValue -Key "UNIFY_KEY"
if ($key) {
    Start-Services
}

# Run application
[System.Windows.Forms.Application]::Run($appContext)
