param(
  [string]$Hostname,
  [string]$TunnelName,
  [int]$LocalPort
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Apply defaults from env or hardcoded values
if ([string]::IsNullOrWhiteSpace($Hostname)) { $Hostname = $env:TUNNEL_HOSTNAME }
if ([string]::IsNullOrWhiteSpace($TunnelName)) {
  if (-not [string]::IsNullOrWhiteSpace($env:TUNNEL_NAME)) { $TunnelName = $env:TUNNEL_NAME } else { $TunnelName = 'myapp' }
}
if (-not $LocalPort -or $LocalPort -eq 0) { $LocalPort = 3000 }

# Unify API parameters (optional)
$UnifyBaseUrl = if ($env:UNIFY_BASE_URL) { $env:UNIFY_BASE_URL } else { 'https://api.unify.ai/v0' }
if ([string]::IsNullOrWhiteSpace($UnifyKey)) { $UnifyKey = $env:UNIFY_KEY }
if ([string]::IsNullOrWhiteSpace($AssistantName)) { $AssistantName = $env:ASSISTANT_NAME }
$script:AssistantId = $null

function Ensure-Cloudflared {
  $cf = Get-Command cloudflared -ErrorAction SilentlyContinue
  if ($cf) {
    Write-Host "[tunnel] cloudflared is available: $((cloudflared --version) -split "`n")[0]"
    return
  }
  Write-Host "[tunnel] cloudflared not found. Attempting installation via Chocolatey..."
  $choco = Get-Command choco -ErrorAction SilentlyContinue
  if (-not $choco) {
    throw "[tunnel] Chocolatey not found and cloudflared missing. Install cloudflared from https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/ and retry."
  }
  choco install cloudflared -y --no-progress | Out-Host
  $cf = Get-Command cloudflared -ErrorAction SilentlyContinue
  if (-not $cf) {
    throw "[tunnel] cloudflared installation appears to have failed or PATH not updated. Open a new PowerShell window and retry."
  }
}

function Get-CredentialsFilePath {
  param(
    [string]$CloudflaredDir
  )
  $latest = Get-ChildItem -Path $CloudflaredDir -Filter '*.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($latest) { return $latest.FullName }
  return $null
}

function Write-ConfigYaml {
  param(
    [string]$CloudflaredDir,
    [string]$TunnelName,
    [string]$CredentialsFile,
    [string]$Hostname,
    [int]$LocalPort
  )
  $configPath = Join-Path $CloudflaredDir 'config.yml'
  $yaml = @"
tunnel: $TunnelName
credentials-file: $CredentialsFile
ingress:
  - hostname: $Hostname
    service: http://localhost:$LocalPort
  - service: http_status:404
"@
  Set-Content -Path $configPath -Value $yaml -Encoding UTF8
  return $configPath
}

function Get-AssistantId {
  param(
    [string]$AssistantName
  )
  if ([string]::IsNullOrWhiteSpace($UnifyKey) -or [string]::IsNullOrWhiteSpace($AssistantName)) { return $null }
  try {
    $headers = @{ Authorization = "Bearer $UnifyKey" }
    $resp = Invoke-RestMethod -Method GET -Uri ("{0}/assistant" -f $UnifyBaseUrl) -Headers $headers -ErrorAction Stop
  } catch {
    return $null
  }
  if (-not $resp -or -not $resp.info) { return $null }
  $target = $AssistantName.ToLower()
  $matches = @()
  foreach ($a in $resp.info) {
    $first = if ($a.first_name) { $a.first_name } else { '' }
    $last = if ($a.surname) { $a.surname } else { '' }
    $full = ("{0} {1}" -f $first,$last).Trim().ToLower()
    if ($full -eq $target) { $matches += $a }
  }
  if ($matches.Count -ne 1) { return $null }
  $id = $matches[0].agent_id
  if (-not $id) { return $null }
  return [string]$id
}

function Patch-DesktopUrl {
  param(
    [string]$AssistantId,
    [string]$Url
  )
  if ([string]::IsNullOrWhiteSpace($UnifyKey) -or [string]::IsNullOrWhiteSpace($AssistantId)) { return }
  $headers = @{ Authorization = "Bearer $UnifyKey"; 'Content-Type' = 'application/json' }
  $body = @{ desktop_url = $Url } | ConvertTo-Json -Compress
  try { Invoke-RestMethod -Method Patch -Uri ("{0}/assistant/{1}/config" -f $UnifyBaseUrl,$AssistantId) -Headers $headers -Body $body -ErrorAction Stop | Out-Null } catch {}
}

function Clear-DesktopUrl {
  if ([string]::IsNullOrWhiteSpace($UnifyKey)) { return }
  if (-not $script:AssistantId) {
    if ($AssistantName) { $script:AssistantId = Get-AssistantId -AssistantName $AssistantName }
  }
  if (-not $script:AssistantId) { return }
  Patch-DesktopUrl -AssistantId $script:AssistantId -Url ""
}

Write-Host "[tunnel] Starting Cloudflare Tunnel setup..."
Ensure-Cloudflared

$cfDir = Join-Path $env:USERPROFILE '.cloudflared'
if (-not (Test-Path $cfDir)) {
  New-Item -ItemType Directory -Force -Path $cfDir | Out-Null
}

# if ([string]::IsNullOrWhiteSpace($Hostname)) {
Write-Host "[tunnel] INFO: No hostname provided. Starting ad-hoc tunnel to http://localhost:$LocalPort ..."

$logFile = Join-Path $env:TEMP ("trycloudflare_{0}.log" -f $LocalPort)
$errFile = Join-Path $env:TEMP ("trycloudflare_{0}_err.log" -f $LocalPort)
try { Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue } catch {}
try { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } catch {}

$cfProc = Start-Process -FilePath 'cloudflared' -ArgumentList @('tunnel','--url',("http://localhost:{0}" -f $LocalPort)) -RedirectStandardOutput $logFile -RedirectStandardError $errFile -WindowStyle Hidden -PassThru

try {
  $url = $null
  for ($i=0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 300
    try {
      $content = $null
      if (Test-Path $logFile) {
        $content = Get-Content -LiteralPath $logFile -Raw -ErrorAction SilentlyContinue
      }
      if (-not $content -and (Test-Path $errFile)) {
        $content = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
      }
      if ($content) {
        $m = [Regex]::Match($content,'https://[A-Za-z0-9\.-]+\.trycloudflare\.com')
        if ($m.Success) { $url = $m.Value; break }
      }
    } catch {}
  }
  if ($url) {
    Write-Host "[tunnel] Public URL: $url"
    if ($AssistantName -and $UnifyKey) {
      $script:AssistantId = Get-AssistantId -AssistantName $AssistantName
      if ($script:AssistantId) { Patch-DesktopUrl -AssistantId $script:AssistantId -Url $url }
    }
  } else {
    Write-Host "[tunnel] Waiting for public URL... check logs: $logFile"
  }

  Wait-Process -Id $cfProc.Id
} finally {
  Write-Host "[tunnel] Cleaning up..."
  try { if ($cfProc -and -not $cfProc.HasExited) { Stop-Process -Id $cfProc.Id -Force -ErrorAction SilentlyContinue } } catch {}
  Clear-DesktopUrl
}
#   exit $LASTEXITCODE
# }

# if (-not (Test-Path (Join-Path $cfDir 'cert.pem'))) {
#   Write-Host "[tunnel] ERROR: cloudflared is not logged in. Run: cloudflared tunnel login" -ForegroundColor Red
#   exit 1
# }

# # Create tunnel if missing
# $tunnelExists = $false
# try {
#   & cloudflared tunnel info "$TunnelName" | Out-Null
#   if ($LASTEXITCODE -eq 0) { $tunnelExists = $true }
# } catch {}

# $credentialsFile = $null
# if (-not $tunnelExists) {
#   Write-Host "[tunnel] Creating tunnel '$TunnelName'..."
#   $createOut = & cloudflared tunnel create "$TunnelName" 2>&1
#   $pattern = [Regex]::Escape($cfDir) + "\\[a-f0-9-]+\.json"
#   $match = [Regex]::Match($createOut, $pattern)
#   if ($match.Success) { $credentialsFile = $match.Value }
#   if (-not $credentialsFile) {
#     $credentialsFile = Get-CredentialsFilePath -CloudflaredDir $cfDir
#   }
# } else {
#   $credentialsFile = Get-CredentialsFilePath -CloudflaredDir $cfDir
# }

# if (-not $credentialsFile -or -not (Test-Path $credentialsFile)) {
#   Write-Host "[tunnel] ERROR: Could not find tunnel credentials JSON in $cfDir" -ForegroundColor Red
#   exit 1
# }

# $configPath = Write-ConfigYaml -CloudflaredDir $cfDir -TunnelName $TunnelName -CredentialsFile $credentialsFile -Hostname $Hostname -LocalPort $LocalPort

# try {
#   & cloudflared tunnel route dns "$TunnelName" "$Hostname" | Out-Host
# } catch {}

# Write-Host "[tunnel] Running tunnel '$TunnelName' for https://$Hostname → http://localhost:$LocalPort"
# & cloudflared tunnel run "$TunnelName"
