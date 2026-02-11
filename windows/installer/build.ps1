# build.ps1 - Build Unify Desktop Assistant Installer
#
# This script builds the Inno Setup installer for Unify Desktop Assistant.
#
# Prerequisites:
#   - Inno Setup 6.x installed (https://jrsoftware.org/isinfo.php)
#   - Or install via: choco install innosetup -y
#
# Usage:
#   .\build.ps1                 # Build installer
#   .\build.ps1 -Version 1.2.0  # Build with custom version
#   .\build.ps1 -Clean          # Clean output before building

param(
    [string]$Version,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$script:InstallerDir = $PSScriptRoot
$script:ProjectDir = Split-Path -Parent $script:InstallerDir
$script:OutputDir = Join-Path $script:InstallerDir 'output'
$script:AssetsDir = Join-Path $script:InstallerDir 'assets'

Write-Host ""
Write-Host "=========================================="
Write-Host "  Unify Desktop Assistant - Build Installer"
Write-Host "=========================================="
Write-Host ""

# =============================================================================
# Find Inno Setup
# =============================================================================

function Find-InnoSetup {
    $paths = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 5\ISCC.exe"
    )
    
    foreach ($path in $paths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    # Try to find via PATH
    $iscc = Get-Command iscc -ErrorAction SilentlyContinue
    if ($iscc) {
        return $iscc.Source
    }
    
    return $null
}

# =============================================================================
# Create Placeholder Assets
# =============================================================================

function Create-PlaceholderAssets {
    Write-Host "Creating placeholder assets..." -ForegroundColor Cyan
    
    if (-not (Test-Path $script:AssetsDir)) {
        New-Item -ItemType Directory -Force -Path $script:AssetsDir | Out-Null
    }
    
    # Create placeholder icon.ico if not exists
    $iconPath = Join-Path $script:AssetsDir 'icon.ico'
    if (-not (Test-Path $iconPath)) {
        Write-Host "  Creating placeholder icon.ico..." -ForegroundColor Yellow
        
        # Create a simple 16x16 placeholder ICO file
        # ICO header + one 16x16 BMP image entry
        $icoHeader = @(
            0x00, 0x00,           # Reserved
            0x01, 0x00,           # Image type: 1 = ICO
            0x01, 0x00            # Number of images: 1
        )
        
        # ICO directory entry for 16x16
        $icoEntry = @(
            0x10,                 # Width: 16
            0x10,                 # Height: 16
            0x00,                 # Color palette: 0
            0x00,                 # Reserved
            0x01, 0x00,           # Color planes: 1
            0x20, 0x00,           # Bits per pixel: 32
            0x68, 0x04, 0x00, 0x00, # Image size in bytes
            0x16, 0x00, 0x00, 0x00  # Offset to image data
        )
        
        # Simple 16x16 BMP (all blue with transparency)
        $bmpHeader = @(
            # BITMAPINFOHEADER (40 bytes)
            0x28, 0x00, 0x00, 0x00, # Header size: 40
            0x10, 0x00, 0x00, 0x00, # Width: 16
            0x20, 0x00, 0x00, 0x00, # Height: 32 (doubled for mask)
            0x01, 0x00,             # Planes: 1
            0x20, 0x00,             # Bits per pixel: 32
            0x00, 0x00, 0x00, 0x00, # Compression: none
            0x00, 0x04, 0x00, 0x00, # Image size
            0x00, 0x00, 0x00, 0x00, # X pixels per meter
            0x00, 0x00, 0x00, 0x00, # Y pixels per meter
            0x00, 0x00, 0x00, 0x00, # Colors used
            0x00, 0x00, 0x00, 0x00  # Important colors
        )
        
        # Create pixel data (16x16 BGRA - blue circle)
        $pixels = New-Object byte[] (16 * 16 * 4)
        $centerX = 8
        $centerY = 8
        $radius = 6
        
        for ($y = 0; $y -lt 16; $y++) {
            for ($x = 0; $x -lt 16; $x++) {
                $offset = ($y * 16 + $x) * 4
                $dist = [Math]::Sqrt(($x - $centerX) * ($x - $centerX) + ($y - $centerY) * ($y - $centerY))
                
                if ($dist -le $radius) {
                    # Blue color with full opacity
                    $pixels[$offset + 0] = 0xE0  # B
                    $pixels[$offset + 1] = 0x80  # G
                    $pixels[$offset + 2] = 0x20  # R
                    $pixels[$offset + 3] = 0xFF  # A
                } else {
                    # Transparent
                    $pixels[$offset + 0] = 0x00
                    $pixels[$offset + 1] = 0x00
                    $pixels[$offset + 2] = 0x00
                    $pixels[$offset + 3] = 0x00
                }
            }
        }
        
        # AND mask (all zeros for 32-bit with alpha)
        $mask = New-Object byte[] (16 * 16 / 8)
        
        # Write ICO file
        $stream = [System.IO.File]::OpenWrite($iconPath)
        $stream.Write($icoHeader, 0, $icoHeader.Length)
        $stream.Write($icoEntry, 0, $icoEntry.Length)
        $stream.Write($bmpHeader, 0, $bmpHeader.Length)
        $stream.Write($pixels, 0, $pixels.Length)
        $stream.Write($mask, 0, $mask.Length)
        $stream.Close()
        
        Write-Host "  Created placeholder icon (replace with real icon)" -ForegroundColor Yellow
    }
    
    # Create placeholder wizard images if not exist
    $wizardPath = Join-Path $script:AssetsDir 'wizard.bmp'
    $wizardSmallPath = Join-Path $script:AssetsDir 'wizard-small.bmp'
    
    if (-not (Test-Path $wizardPath)) {
        Write-Host "  Wizard images not found - installer will use defaults" -ForegroundColor Yellow
    }
}

# =============================================================================
# Clean Output
# =============================================================================

function Clean-Output {
    Write-Host "Cleaning output directory..." -ForegroundColor Cyan
    
    if (Test-Path $script:OutputDir) {
        Remove-Item -Recurse -Force $script:OutputDir
        Write-Host "  Cleaned" -ForegroundColor Green
    } else {
        Write-Host "  Nothing to clean" -ForegroundColor Gray
    }
}

# =============================================================================
# Build Installer
# =============================================================================

function Build-Installer {
    param([string]$ISCC)
    
    Write-Host "Building installer..." -ForegroundColor Cyan
    
    # Create output directory
    if (-not (Test-Path $script:OutputDir)) {
        New-Item -ItemType Directory -Force -Path $script:OutputDir | Out-Null
    }
    
    $issFile = Join-Path $script:InstallerDir 'setup.iss'
    
    if (-not (Test-Path $issFile)) {
        throw "setup.iss not found at $issFile"
    }
    
    # Build arguments
    $args = @(
        "/O`"$($script:OutputDir)`""
    )
    
    if ($Version) {
        $args += "/DAppVersion=$Version"
    }
    
    $args += "`"$issFile`""
    
    Write-Host "  Running: $ISCC $($args -join ' ')" -ForegroundColor Gray
    
    & $ISCC @args
    
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup compilation failed with exit code $LASTEXITCODE"
    }
    
    Write-Host ""
    Write-Host "Build complete!" -ForegroundColor Green
    Write-Host ""
    
    # List output files
    Write-Host "Output files:" -ForegroundColor Cyan
    Get-ChildItem $script:OutputDir -Filter "*.exe" | ForEach-Object {
        $sizeMB = [math]::Round($_.Length / 1MB, 2)
        Write-Host "  $($_.Name) ($sizeMB MB)" -ForegroundColor Green
    }
}

# =============================================================================
# Main
# =============================================================================

# Clean if requested
if ($Clean) {
    Clean-Output
}

# Find Inno Setup
$iscc = Find-InnoSetup

if (-not $iscc) {
    Write-Host ""
    Write-Host "ERROR: Inno Setup not found!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Install Inno Setup:" -ForegroundColor Yellow
    Write-Host "  Option 1: Download from https://jrsoftware.org/isinfo.php" -ForegroundColor Gray
    Write-Host "  Option 2: choco install innosetup -y" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

Write-Host "Found Inno Setup: $iscc" -ForegroundColor Green

# Create placeholder assets if needed
Create-PlaceholderAssets

# Build
Build-Installer -ISCC $iscc

Write-Host ""
