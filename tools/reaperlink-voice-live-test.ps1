# ReaperLink Voice local live-test installer
# Run from an elevated PowerShell window on the FiveM host.

$ErrorActionPreference = "Stop"

$ServerRoot = "E:\testserver\file"
$ServerCfg = Join-Path $ServerRoot "server.cfg"
$Resources = Join-Path $ServerRoot "resources"
$PhoneParent = Join-Path $Resources "[phone]"
$Phone = Join-Path $PhoneParent "v-phone"
$FxServer = "E:\testserver\server-35245\FXServer.exe"
$Branch = "reaperlink-voice-dev"
$ZipUrl = "https://github.com/ReaperMadeIt-development/v-phone-fivem/archive/refs/heads/$Branch.zip"
$Work = Join-Path $env:TEMP "ReaperLinkVoiceTest"
$Zip = Join-Path $Work "v-phone.zip"
$Extract = Join-Path $Work "extract"
$TunnelOut = Join-Path $Work "cloudflared.out.log"
$TunnelErr = Join-Path $Work "cloudflared.err.log"

function Say($Text, $Color = "Gray") {
    Write-Host $Text -ForegroundColor $Color
}

function Set-CfgLine([string]$Name, [string]$Value) {
    $raw = Get-Content -LiteralPath $ServerCfg -Raw
    $escaped = [regex]::Escape($Name)
    $line = 'setr ' + $Name + ' "' + $Value.Replace('"','') + '"'
    if ($raw -match ("(?m)^\s*setr\s+" + $escaped + "\s+.*$")) {
        $raw = [regex]::Replace($raw, ("(?m)^\s*setr\s+" + $escaped + "\s+.*$"), $line)
    } else {
        $raw = $raw + [Environment]::NewLine + $line + [Environment]::NewLine
    }
    Set-Content -LiteralPath $ServerCfg -Value $raw -Encoding UTF8
}

Write-Host ""
Say "=== REAPERLINK VOICE LIVE TEST ===" Cyan

foreach ($required in @($ServerCfg, $PhoneParent, $FxServer)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required path not found: $required"
    }
}

Say "Stopping FXServer..." Yellow
Get-Process FXServer -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
if (Test-Path -LiteralPath $Phone) {
    $backup = Join-Path $PhoneParent ("v-phone_WORKING_BACKUP_" + $stamp)
    Say "Backing up current v-phone -> $backup" Yellow
    Copy-Item -LiteralPath $Phone -Destination $backup -Recurse -Force
}

Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Work | Out-Null
New-Item -ItemType Directory -Path $Extract | Out-Null

Say "Downloading $Branch..." Yellow
Invoke-WebRequest -Uri $ZipUrl -OutFile $Zip -UseBasicParsing
Expand-Archive -LiteralPath $Zip -DestinationPath $Extract -Force

$Source = Get-ChildItem -LiteralPath $Extract -Directory |
    Where-Object { $_.Name -like "v-phone-fivem-*" } |
    Select-Object -First 1

if (-not $Source) { throw "Downloaded branch folder was not found." }

if (Test-Path -LiteralPath $Phone) {
    Remove-Item -LiteralPath $Phone -Recurse -Force
}
Copy-Item -LiteralPath $Source.FullName -Destination $Phone -Recurse -Force

$checks = @(
    "fxmanifest.lua",
    "apps\example\app.lua",
    "html\physical.js",
    "html\reaperlink-voice.js",
    "html\reaperlink-voice-game.js",
    "html\qrcode.js",
    "html\reaper-mark.svg"
)

foreach ($rel in $checks) {
    $full = Join-Path $Phone $rel
    if (-not (Test-Path -LiteralPath $full)) { throw "Missing required file: $rel" }
    Say ("PASS  " + $rel) Green
}

$bridge = Get-Content -LiteralPath (Join-Path $Phone "apps\example\app.lua") -Raw
$httpHandlers = ([regex]::Matches($bridge, [regex]::Escape("SetHttpHandler(function(req, res)"))).Count
$pairHandlers = ([regex]::Matches($bridge, [regex]::Escape("RegisterNetEvent('v-phone:physical:pairRequest'"))).Count

if ($httpHandlers -ne 1 -or $pairHandlers -ne 1) {
    throw "Bridge sanity check failed. HTTP handlers=$httpHandlers, pair handlers=$pairHandlers"
}
Say "PASS  clean physical bridge (1 HTTP handler / 1 pair handler)" Green

$cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
if ($cloudflared) {
    Say "Starting HTTPS quick tunnel..." Yellow
    # Do not kill other cloudflared processes; another ReaperMadeIt project may be using one.
    Remove-Item -LiteralPath $TunnelOut -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TunnelErr -Force -ErrorAction SilentlyContinue

    $args = @("tunnel", "--url", "http://127.0.0.1:30120", "--no-autoupdate")
    Start-Process -FilePath $cloudflared.Source -ArgumentList $args -RedirectStandardOutput $TunnelOut -RedirectStandardError $TunnelErr -WindowStyle Hidden

    $tunnel = $null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 750
        $log = ""
        if (Test-Path -LiteralPath $TunnelOut) {
            $log += Get-Content -LiteralPath $TunnelOut -Raw -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $TunnelErr) {
            $log += [Environment]::NewLine
            $log += Get-Content -LiteralPath $TunnelErr -Raw -ErrorAction SilentlyContinue
        }
        $m = [regex]::Match($log, 'https://[a-z0-9-]+\.trycloudflare\.com')
        if ($m.Success) {
            $tunnel = $m.Value
            break
        }
    }

    if ($tunnel) {
        $public = "$tunnel/v-phone/physical"
        Set-CfgLine "reaperlink_public_url" $public
        Say "HTTPS ReaperLink URL: $public" Green
        Say "Cloudflare must stay running during the physical-phone voice test." DarkGray
    } else {
        Say "Cloudflare started but no quick-tunnel URL was detected." Red
        Say "Physical microphone testing will not work over the old plain HTTP URL." Red
    }
} else {
    Say "cloudflared was not found in PATH." Red
    Say "UI/control can still be tested, but the physical microphone needs HTTPS." Yellow
}

Say "Current voice ICE settings:" Cyan
Select-String -LiteralPath $ServerCfg -Pattern "reaperlink_voice_(stun|turn)" -ErrorAction SilentlyContinue

Say "Starting FXServer..." Yellow
Start-Process -FilePath $FxServer
Start-Sleep -Seconds 5

Write-Host ""
Say "=== INSTALLED ===" Green
Say "Branch: $Branch" Green
Say "Reconnect to FiveM, run /physicalpair, scan the QR, then place or answer a call." Cyan
Say "Watch for the ReaperLink Voice status pill on the real phone when the call becomes active." Cyan
