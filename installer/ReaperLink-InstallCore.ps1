param(
    [Parameter(Mandatory=$true)][string]$OptionsPath,
    [Parameter(Mandatory=$true)][string]$PayloadRoot,
    [Parameter(Mandatory=$true)][string]$LogPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$NL = [Environment]::NewLine

function Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Fail {
    param([string]$Message)
    Log ('ERROR: ' + $Message)
    throw $Message
}

function Set-CfgLine {
    param([string]$Cfg,[string]$Key,[string]$Value)
    $content = [System.IO.File]::ReadAllText($Cfg)
    $escaped = [Regex]::Escape($Key)
    $line = 'setr {0} "{1}"' -f $Key,($Value -replace '"','\"')
    $pattern = '(?im)^\s*setr\s+' + $escaped + '\s+.*$'
    if ($content -match $pattern) {
        $content = [Regex]::Replace($content,$pattern,$line,1)
    } else {
        if ($content.Length -gt 0 -and -not $content.EndsWith($NL)) { $content += $NL }
        $content += $line + $NL
    }
    [System.IO.File]::WriteAllText($Cfg,$content,[System.Text.UTF8Encoding]::new($false))
}

function Ensure-CfgCommand {
    param([string]$Cfg,[string]$Command)
    $content = [System.IO.File]::ReadAllText($Cfg)
    $pattern = '(?im)^\s*' + [Regex]::Escape($Command) + '\s*$'
    if ($content -notmatch $pattern) {
        if ($content.Length -gt 0 -and -not $content.EndsWith($NL)) { $content += $NL }
        $content += $Command + $NL
        [System.IO.File]::WriteAllText($Cfg,$content,[System.Text.UTF8Encoding]::new($false))
    }
}

function Find-VPhone {
    param([string]$Resources)
    $matches = @(Get-ChildItem -LiteralPath $Resources -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq 'v-phone' -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'fxmanifest.lua'))
        })
    if ($matches.Count -gt 0) { return $matches[0].FullName }
    return $null
}

function Find-Voice {
    param([string]$Resources)
    foreach ($name in @('pma-voice','saltychat','SaltyChat','tokovoip','toko-voip')) {
        $hit = Get-ChildItem -LiteralPath $Resources -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq $name } |
            Select-Object -First 1
        if ($hit) { return $hit.Name }
    }
    return $null
}

function Find-Cloudflared {
    $cmd = Get-Command cloudflared -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'cloudflared\cloudflared.exe'),
        (Join-Path $env:ProgramData 'ReaperLink\cloudflared.exe')
    )) {
        if ([System.IO.File]::Exists($candidate)) { return $candidate }
    }

    $wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if ([System.IO.Directory]::Exists($wingetRoot)) {
        $hit = Get-ChildItem -LiteralPath $wingetRoot -Filter cloudflared.exe -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Install-Cloudflared {
    Log 'cloudflared not found. Installing Cloudflare client.'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        $args = @('install','--id','Cloudflare.cloudflared','-e','--accept-package-agreements','--accept-source-agreements','--silent')
        $p = Start-Process -FilePath $winget.Source -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -eq 0) {
            $found = Find-Cloudflared
            if ($found) { return $found }
        }
    }

    $dir = Join-Path $env:ProgramData 'ReaperLink'
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    $exe = Join-Path $dir 'cloudflared.exe'
    Invoke-WebRequest 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $exe -UseBasicParsing
    if (-not [System.IO.File]::Exists($exe)) { Fail 'Could not install cloudflared.' }
    return $exe
}

function Start-QuickTunnel {
    param([string]$Cloudflared,[string]$RuntimeDir)
    [System.IO.Directory]::CreateDirectory($RuntimeDir) | Out-Null
    $stdout = Join-Path $RuntimeDir 'cloudflared.out.log'
    $stderr = Join-Path $RuntimeDir 'cloudflared.err.log'
    Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue

    Log 'Starting temporary Cloudflare HTTPS tunnel.'
    $proc = Start-Process -FilePath $Cloudflared -ArgumentList @('tunnel','--url','http://127.0.0.1:30120','--no-autoupdate') -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden

    $deadline = (Get-Date).AddSeconds(60)
    $url = $null
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        foreach ($file in @($stderr,$stdout)) {
            if ([System.IO.File]::Exists($file)) {
                $text = [System.IO.File]::ReadAllText($file)
                $m = [Regex]::Match($text,'https://[a-zA-Z0-9-]+\.trycloudflare\.com')
                if ($m.Success) {
                    $url = $m.Value
                    break
                }
            }
        }
        if ($url) { break }
    }

    if (-not $url) {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
        Fail 'Cloudflare Quick Tunnel did not return an HTTPS URL.'
    }

    return [PSCustomObject]@{
        Url = ($url.TrimEnd('/') + '/v-phone/physical')
        ProcessId = $proc.Id
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Copy-Tree {
    param([string]$Source,[string]$Destination)
    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Write-Rollback {
    param([string]$ServerRoot,[string]$CurrentVPhone,[string]$BackupVPhone,[string]$CfgBackup,[int]$TunnelPid)
    $path = Join-Path $ServerRoot 'ReaperLink-Rollback.ps1'
    $template = @'
$ErrorActionPreference = 'Stop'
Write-Host 'ReaperLink rollback' -ForegroundColor Cyan
$cfgBackup = '__CFG_BACKUP__'
$serverCfg = '__SERVER_CFG__'
$current = '__CURRENT__'
$backup = '__BACKUP__'
$tunnelPid = __TUNNEL_PID__

if ($tunnelPid -gt 0) {
    Get-Process -Id $tunnelPid -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $cfgBackup) {
    [System.IO.File]::Copy($cfgBackup,$serverCfg,$true)
    Write-Host 'Restored server.cfg' -ForegroundColor Green
}
if ($backup -and (Test-Path -LiteralPath $backup)) {
    if (Test-Path -LiteralPath $current) { [System.IO.Directory]::Delete($current,$true) }
    [System.IO.Directory]::Move($backup,$current)
    Write-Host 'Restored previous v-phone.' -ForegroundColor Green
} else {
    Write-Warning 'No previous v-phone backup was recorded.'
}
Write-Host 'Rollback complete. Restart the FiveM server.' -ForegroundColor Cyan
'@

    $esc = {
        param([string]$s)
        if ($null -eq $s) { return '' }
        return $s.Replace("'","''")
    }
    $body = $template.Replace('__CFG_BACKUP__',(& $esc $CfgBackup))
    $body = $body.Replace('__SERVER_CFG__',(& $esc (Join-Path $ServerRoot 'server.cfg')))
    $body = $body.Replace('__CURRENT__',(& $esc $CurrentVPhone))
    $body = $body.Replace('__BACKUP__',(& $esc $BackupVPhone))
    $body = $body.Replace('__TUNNEL_PID__',[string]$TunnelPid)
    [System.IO.File]::WriteAllText($path,$body,[System.Text.UTF8Encoding]::new($false))
    return $path
}

try {
    if (-not (Test-Path -LiteralPath $OptionsPath)) { Fail ('Options file missing: ' + $OptionsPath) }
    if (-not (Test-Path -LiteralPath $PayloadRoot)) { Fail ('Payload folder missing: ' + $PayloadRoot) }

    $options = Get-Content -LiteralPath $OptionsPath -Raw | ConvertFrom-Json
    $root = [System.IO.Path]::GetFullPath(([string]$options.serverData).Trim())
    $cfg = Join-Path $root 'server.cfg'
    $resources = Join-Path $root 'resources'

    if (-not (Test-Path -LiteralPath $cfg)) { Fail ('server.cfg not found in ' + $root) }
    if (-not (Test-Path -LiteralPath $resources)) { Fail ('resources folder not found in ' + $root) }

    Log ('Installing ReaperLink into ' + $root)

    $voice = Find-Voice $resources
    if ($voice) { Log ('Detected voice resource: ' + $voice) }
    else { Log 'WARNING: no supported voice resource detected; pma-voice is recommended.' }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $runtimeDir = Join-Path $root 'reaperlink-runtime'
    [System.IO.Directory]::CreateDirectory($runtimeDir) | Out-Null

    $cfgBackup = $cfg + '.reaperlink-backup_' + $stamp
    [System.IO.File]::Copy($cfg,$cfgBackup,$true)
    Log ('Backed up server.cfg -> ' + $cfgBackup)

    $existing = Find-VPhone $resources
    $savedConfig = $null
    if ($existing) {
        $destination = $existing
        $backup = Join-Path ([System.IO.Directory]::GetParent($existing).FullName) ('v-phone_REAPERLINK_BACKUP_' + $stamp)
        Log ('Backing up existing v-phone -> ' + $backup)
        Copy-Item -LiteralPath $existing -Destination $backup -Recurse -Force

        $oldConfig = Join-Path $existing 'config.lua'
        if (Test-Path -LiteralPath $oldConfig) {
            $savedConfig = Join-Path $runtimeDir ('config_' + $stamp + '.lua')
            Copy-Item -LiteralPath $oldConfig -Destination $savedConfig -Force
            Log 'Preserved existing config.lua.'
        }
        [System.IO.Directory]::Delete($existing,$true)
    } else {
        $group = Join-Path $resources '[phone]'
        [System.IO.Directory]::CreateDirectory($group) | Out-Null
        $destination = Join-Path $group 'v-phone'
        $backup = ''
        Log ('No existing v-phone found. Installing fresh to ' + $destination)
    }

    Copy-Tree -Source $PayloadRoot -Destination $destination

    if ($savedConfig -and (Test-Path -LiteralPath $savedConfig)) {
        Copy-Item -LiteralPath $savedConfig -Destination (Join-Path $destination 'config.lua') -Force
        Log 'Restored server owner config.lua into ReaperLink.'
    }

    foreach ($required in @('fxmanifest.lua','apps\example\app.lua','html\physical.js','html\reaperlink-voice.js','html\reaperlink-voice-game.js')) {
        if (-not (Test-Path -LiteralPath (Join-Path $destination $required))) { Fail ('Installed resource is missing ' + $required) }
    }

    $tunnelPid = 0
    if ([string]$options.httpsMode -eq 'quick') {
        $cloudflared = Find-Cloudflared
        if (-not $cloudflared) { $cloudflared = Install-Cloudflared }
        Log ('cloudflared: ' + $cloudflared)
        $tunnel = Start-QuickTunnel -Cloudflared $cloudflared -RuntimeDir $runtimeDir
        $publicUrl = $tunnel.Url
        $tunnelPid = [int]$tunnel.ProcessId
        Log ('Temporary HTTPS URL: ' + $publicUrl)
    } else {
        $publicUrl = ([string]$options.publicUrl).Trim().TrimEnd('/')
        if (-not $publicUrl.StartsWith('https://')) { Fail 'Custom ReaperLink URL must use HTTPS.' }
        if ($publicUrl -notmatch '/v-phone/physical$') { $publicUrl += '/v-phone/physical' }
        Log ('Using supplied HTTPS URL: ' + $publicUrl)
    }

    Set-CfgLine $cfg 'reaperlink_public_url' $publicUrl
    Set-CfgLine $cfg 'reaperlink_voice_stun' ([string]$options.stun).Trim()
    Set-CfgLine $cfg 'reaperlink_voice_turn_url' ([string]$options.turnUrl).Trim()
    Set-CfgLine $cfg 'reaperlink_voice_turn_user' ([string]$options.turnUser).Trim()
    Set-CfgLine $cfg 'reaperlink_voice_turn_pass' ([string]$options.turnPass).Trim()
    Ensure-CfgCommand $cfg 'ensure v-phone'

    $rollback = Write-Rollback -ServerRoot $root -CurrentVPhone $destination -BackupVPhone $backup -CfgBackup $cfgBackup -TunnelPid $tunnelPid

    $state = [ordered]@{
        installed_at = (Get-Date).ToString('o')
        build = 'ReaperLink Voice TEST/PREVIEW'
        vphone_path = $destination
        vphone_backup = $backup
        server_cfg_backup = $cfgBackup
        public_url = $publicUrl
        cloudflared_pid = $tunnelPid
        voice_resource = $voice
        rollback_script = $rollback
    }

    [System.IO.File]::WriteAllText((Join-Path $root 'reaperlink-install-state.json'),($state | ConvertTo-Json -Depth 5),[System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $root 'reaperlink-install-result.txt'),('SUCCESS' + $NL + 'URL=' + $publicUrl + $NL + 'ROLLBACK=' + $rollback + $NL),[System.Text.UTF8Encoding]::new($false))

    Log 'INSTALL COMPLETE'
    Log ('Public URL: ' + $publicUrl)
    Log ('Rollback script: ' + $rollback)
    exit 0
}
catch {
    try { Log ('ERROR: ' + $_.Exception.Message) } catch {}
    exit 1
}
