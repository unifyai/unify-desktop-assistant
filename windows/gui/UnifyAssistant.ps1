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
$script:AgentPort = 3000

# Status check interval (ms)
$script:StatusInterval = 5000

# =============================================================================
# Helper Functions
# =============================================================================

function Test-PortListening {
    param([int]$Port)
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        return $null -ne $conn
    } catch {
        return $false
    }
}

function Get-ServiceStatus {
    $vnc = Test-PortListening -Port $script:VncPort
    $novnc = Test-PortListening -Port $script:NoVncPort
    $agent = Test-PortListening -Port $script:AgentPort
    
    return @{
        VNC = $vnc
        NoVNC = $novnc
        Agent = $agent
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
    param([string]$UnifyKey, [string]$OrchestraUrl, [string]$UnityCommsUrl)
    
    if (-not $UnifyKey) {
        $UnifyKey = Get-EnvValue -Key "UNIFY_KEY"
    }
    if (-not $OrchestraUrl) {
        $OrchestraUrl = Get-EnvValue -Key "ORCHESTRA_URL"
        if (-not $OrchestraUrl) { $OrchestraUrl = "https://api.unify.ai/v0" }
    }
    if (-not $UnityCommsUrl) {
        $UnityCommsUrl = Get-EnvValue -Key "UNITY_COMMS_URL"
        if (-not $UnityCommsUrl) { $UnityCommsUrl = "https://unity-comms-app-000000000000.us-central1.run.app" }
    }
    
    if (-not $UnifyKey) {
        [System.Windows.Forms.MessageBox]::Show(
            "Please configure your Unify API Key in Settings first.",
            "Configuration Required",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }
    
    # Run setup.ps1 in background
    $setupArgs = "-UnifyKey `"$UnifyKey`" -OrchestraUrl `"$OrchestraUrl`" -UnityCommsUrl `"$UnityCommsUrl`""
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($script:SetupScript)`" $setupArgs" -WindowStyle Hidden
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
    
    return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
}

function Update-TrayStatus {
    $status = Get-ServiceStatus
    
    if ($status.AllRunning) {
        $script:NotifyIcon.Icon = Get-TrayIcon -Status "running"
        $script:NotifyIcon.Text = "$($script:AppName)`nStatus: Running"
        $script:StatusMenuItem.Text = "Status: Running"
    } elseif ($status.AnyRunning) {
        $script:NotifyIcon.Icon = Get-TrayIcon -Status "partial"
        $script:NotifyIcon.Text = "$($script:AppName)`nStatus: Partial"
        $script:StatusMenuItem.Text = "Status: Partial"
    } else {
        $script:NotifyIcon.Icon = Get-TrayIcon -Status "stopped"
        $script:NotifyIcon.Text = "$($script:AppName)`nStatus: Stopped"
        $script:StatusMenuItem.Text = "Status: Stopped"
    }
}

# =============================================================================
# Settings Dialog
# =============================================================================

function Show-SettingsDialog {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Settings"
    $form.Size = New-Object System.Drawing.Size(450, 345)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    
    # Unify Key Label
    $lblKey = New-Object System.Windows.Forms.Label
    $lblKey.Text = "Unify API Key:"
    $lblKey.Location = New-Object System.Drawing.Point(20, 20)
    $lblKey.Size = New-Object System.Drawing.Size(100, 20)
    $form.Controls.Add($lblKey)
    
    # Unify Key TextBox
    $txtKey = New-Object System.Windows.Forms.TextBox
    $txtKey.Location = New-Object System.Drawing.Point(20, 45)
    $txtKey.Size = New-Object System.Drawing.Size(320, 25)
    $txtKey.UseSystemPasswordChar = $true
    $txtKey.Text = Get-EnvValue -Key "UNIFY_KEY"
    $form.Controls.Add($txtKey)
    
    # Show/Hide Button
    $btnShow = New-Object System.Windows.Forms.Button
    $btnShow.Text = "Show"
    $btnShow.Location = New-Object System.Drawing.Point(350, 43)
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
    
    # Orchestra URL Label
    $lblUrl = New-Object System.Windows.Forms.Label
    $lblUrl.Text = "Orchestra URL:"
    $lblUrl.Location = New-Object System.Drawing.Point(20, 85)
    $lblUrl.Size = New-Object System.Drawing.Size(100, 20)
    $form.Controls.Add($lblUrl)
    
    # Orchestra URL TextBox
    $txtUrl = New-Object System.Windows.Forms.TextBox
    $txtUrl.Location = New-Object System.Drawing.Point(20, 110)
    $txtUrl.Size = New-Object System.Drawing.Size(390, 25)
    $txtUrl.Text = Get-EnvValue -Key "ORCHESTRA_URL"
    if (-not $txtUrl.Text) { $txtUrl.Text = "https://api.unify.ai/v0" }
    $form.Controls.Add($txtUrl)
    
    # Unity Comms URL Label
    $lblComms = New-Object System.Windows.Forms.Label
    $lblComms.Text = "Unity Comms URL:"
    $lblComms.Location = New-Object System.Drawing.Point(20, 150)
    $lblComms.Size = New-Object System.Drawing.Size(120, 20)
    $form.Controls.Add($lblComms)
    
    # Unity Comms URL TextBox
    $txtComms = New-Object System.Windows.Forms.TextBox
    $txtComms.Location = New-Object System.Drawing.Point(20, 175)
    $txtComms.Size = New-Object System.Drawing.Size(390, 25)
    $txtComms.Text = Get-EnvValue -Key "UNITY_COMMS_URL"
    if (-not $txtComms.Text) { $txtComms.Text = "https://unity-comms-app-000000000000.us-central1.run.app" }
    $form.Controls.Add($txtComms)
    
    # Startup Options
    $chkStartup = New-Object System.Windows.Forms.CheckBox
    $chkStartup.Text = "Start on Windows login"
    $chkStartup.Location = New-Object System.Drawing.Point(20, 215)
    $chkStartup.Size = New-Object System.Drawing.Size(200, 25)
    
    # Check if startup entry exists
    $startupPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $startupEntry = Get-ItemProperty -Path $startupPath -Name "UnifyAssistant" -ErrorAction SilentlyContinue
    $chkStartup.Checked = $null -ne $startupEntry
    $form.Controls.Add($chkStartup)
    
    # Auto-start services
    $chkAutoStart = New-Object System.Windows.Forms.CheckBox
    $chkAutoStart.Text = "Start services automatically"
    $chkAutoStart.Location = New-Object System.Drawing.Point(20, 240)
    $chkAutoStart.Size = New-Object System.Drawing.Size(200, 25)
    $settings = Get-Settings
    $chkAutoStart.Checked = $settings -and $settings.AutoStartServices
    $form.Controls.Add($chkAutoStart)
    
    # Save Button
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(230, 275)
    $btnSave.Size = New-Object System.Drawing.Size(80, 30)
    $btnSave.Add_Click({
        # Save .env values
        Set-EnvValue -Key "UNIFY_KEY" -Value $txtKey.Text
        Set-EnvValue -Key "ORCHESTRA_URL" -Value $txtUrl.Text
        Set-EnvValue -Key "UNITY_COMMS_URL" -Value $txtComms.Text
        
        # Save startup setting
        $startupPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        if ($chkStartup.Checked) {
            $exePath = Join-Path $script:InstallDir "gui\UnifyAssistant.ps1"
            $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$exePath`""
            Set-ItemProperty -Path $startupPath -Name "UnifyAssistant" -Value $cmd
        } else {
            Remove-ItemProperty -Path $startupPath -Name "UnifyAssistant" -ErrorAction SilentlyContinue
        }
        
        # Save settings
        Save-Settings @{
            AutoStartServices = $chkAutoStart.Checked
        }
        
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($btnSave)
    
    # Cancel Button
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(320, 275)
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

# Open Desktop
$desktopItem = New-Object System.Windows.Forms.ToolStripMenuItem
$desktopItem.Text = "Open Desktop Viewer"
$desktopItem.Add_Click({
    $key = Get-EnvValue -Key "UNIFY_KEY"
    $url = "http://localhost:$($script:NoVncPort)/custom.html"
    if ($key) { $url += "?password=$key" }
    Start-Process $url
})
$contextMenu.Items.Add($desktopItem) | Out-Null

# Open API
$apiItem = New-Object System.Windows.Forms.ToolStripMenuItem
$apiItem.Text = "Open API (localhost:$($script:AgentPort))"
$apiItem.Add_Click({
    Start-Process "http://localhost:$($script:AgentPort)"
})
$contextMenu.Items.Add($apiItem) | Out-Null

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

# Auto-start services if configured
$settings = Get-Settings
if ($settings -and $settings.AutoStartServices) {
    $key = Get-EnvValue -Key "UNIFY_KEY"
    if ($key) {
        Start-Services -UnifyKey $key
    }
}

# Run application
[System.Windows.Forms.Application]::Run($appContext)
