# ReaperLink Voice Tester Installer
# ReaperMadeIt-development
# Windows FiveM TEST/PREVIEW installer. Backs up v-phone and server.cfg before changes.

param(
    [string]$ServerData,
    [switch]$NoGui
)

$ErrorActionPreference = 'Stop'
$RepoBranch = 'reaperlink-voice-dev'
$RepoZip = 'https://github.com/ReaperMadeIt-development/v-phone-fivem/archive/refs/heads/reaperlink-voice-dev.zip'
$NL = [Environment]::NewLine

function Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + $NL)
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    } else {
        Write-Host $line
    }
}

function Progress {
    param([int]$Value)
    if ($script:ProgressBar) {
        $script:ProgressBar.Value = [Math]::Max(0,[Math]::Min(100,$Value))
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Normalize-PhysicalUrl {
    param([string]$Value)
    $v = ([string]$Value).Trim().TrimEnd('/')
    if (-not $v) { return $null }
    if ($v -notmatch '^https://') { throw 'ReaperLink voice requires an HTTPS public URL.' }
    if ($v -notmatch '/v-phone/physical$') { $v += '/v-phone/physical' }
    return $v
}

function Set-CfgLine {
    param([string]$Cfg,[string]$Key,[string]$Value)
    $content = [System.IO.File]::ReadAllText($Cfg)
    $escaped = [Regex]::Escape($Key)
    $line = 'setr {0} "{1}"' -f $Key,$Value
    if ($content -match ('(?im)^\s*setr\s+' + $escaped + '\s+.*$')) {
        $content = [Regex]::Replace($content, ('(?im)^\s*setr\s+' + $escaped + '\s+.*$'), $line, 1)
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
    $found = @(Get-ChildItem -LiteralPath $Resources -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'v-phone' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'fxmanifest.lua')) })
    if ($found.Count -gt 0) { return $found[0].FullName }
    return $null
}

function Find-Voice {
    param([string]$Resources)
    foreach ($name in @('pma-voice','saltychat','SaltyChat','tokovoip','toko-voip')) {
        $hit = Get-ChildItem -LiteralPath $Resources -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq $name } | Select-Object -First 1
        if ($hit) { return $hit.Name }
    }
    return $null
}

function Find-Cloudflared {
    $cmd = Get-Command cloudflared -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $direct = @(
        (Join-Path $env:ProgramFiles 'cloudflared\cloudflared.exe'),
        (Join-Path $env:ProgramData 'ReaperLink\cloudflared.exe')
    )
    foreach ($item in $direct) {
        if ([System.IO.File]::Exists($item)) { return $item }
    }
    $wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if ([System.IO.Directory]::Exists($wingetRoot)) {
        $hit = Get-ChildItem -LiteralPath $wingetRoot -Filter cloudflared.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Install-Cloudflared {
    Log 'cloudflared not found. Installing the official Cloudflare client.'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        $args = @('install','--id','Cloudflare.cloudflared','-e','--accept-package-agreements','--accept-source-agreements','--silent')
        $p = Start-Process -FilePath $winget.Source -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -eq 0) {
            $path = Find-Cloudflared
            if ($path) { return $path }
        }
    }
    $dir = Join-Path $env:ProgramData 'ReaperLink'
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    $exe = Join-Path $dir 'cloudflared.exe'
    Invoke-WebRequest 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $exe -UseBasicParsing
    if (-not [System.IO.File]::Exists($exe)) { throw 'Could not install cloudflared.' }
    return $exe
}

function Start-QuickTunnel {
    param([string]$Cloudflared,[string]$WorkDir)
    $stdout = Join-Path $WorkDir 'cloudflared.out.log'
    $stderr = Join-Path $WorkDir 'cloudflared.err.log'
    Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
    Log 'Starting temporary Cloudflare HTTPS tunnel.'
    $args = @('tunnel','--url','http://127.0.0.1:30120','--no-autoupdate')
    $proc = Start-Process -FilePath $Cloudflared -ArgumentList $args -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(45)
    $url = $null
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        foreach ($file in @($stderr,$stdout)) {
            if ([System.IO.File]::Exists($file)) {
                $text = [System.IO.File]::ReadAllText($file)
                $m = [Regex]::Match($text,'https://[a-zA-Z0-9-]+\.trycloudflare\.com')
                if ($m.Success) { $url = $m.Value; break }
            }
        }
        if ($url) { break }
        if ([type]::GetType('System.Windows.Forms.Application')) { [System.Windows.Forms.Application]::DoEvents() }
    }
    if (-not $url) {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
        throw 'Cloudflare Quick Tunnel did not return an HTTPS URL.'
    }
    return [PSCustomObject]@{
        Url = ($url.TrimEnd('/') + '/v-phone/physical')
        ProcessId = $proc.Id
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Copy-ReaperLinkResource {
    param([string]$Destination,[string]$WorkDir)
    $embedded = Join-Path $PSScriptRoot 'resource\v-phone'
    if (Test-Path -LiteralPath (Join-Path $embedded 'fxmanifest.lua')) {
        Log 'Using bundled ReaperLink resource.'
        [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
        Get-ChildItem -LiteralPath $embedded -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
        }
        return
    }

    Log ('Downloading ReaperLink branch ' + $RepoBranch + '.')
    $zip = Join-Path $WorkDir 'reaperlink.zip'
    $extract = Join-Path $WorkDir 'extract'
    Invoke-WebRequest $RepoZip -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $source = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    if (-not $source -or -not (Test-Path -LiteralPath (Join-Path $source.FullName 'fxmanifest.lua'))) { throw 'Downloaded archive is invalid.' }
    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
    Get-ChildItem -LiteralPath $source.FullName -Force | ForEach-Object {
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
    $escape = { param($s) ([string]$s).Replace("'","''") }
    $body = $template.Replace('__CFG_BACKUP__',(& $escape $CfgBackup))
    $body = $body.Replace('__SERVER_CFG__',(& $escape (Join-Path $ServerRoot 'server.cfg')))
    $body = $body.Replace('__CURRENT__',(& $escape $CurrentVPhone))
    $body = $body.Replace('__BACKUP__',(& $escape $BackupVPhone))
    $body = $body.Replace('__TUNNEL_PID__',[string]$TunnelPid)
    [System.IO.File]::WriteAllText($path,$body,[System.Text.UTF8Encoding]::new($false))
    return $path
}

function Install-ReaperLink {
    param([string]$Root,[bool]$UseTunnel,[string]$ManualUrl,[string]$Stun,[string]$TurnUrl,[string]$TurnUser,[string]$TurnPass)

    $Root = [System.IO.Path]::GetFullPath($Root.Trim())
    $cfg = Join-Path $Root 'server.cfg'
    $resources = Join-Path $Root 'resources'
    if (-not (Test-Path -LiteralPath $cfg)) { throw ('server.cfg not found in: ' + $Root) }
    if (-not (Test-Path -LiteralPath $resources)) { throw ('resources folder not found in: ' + $Root) }

    Progress 5
    Log ('Server data: ' + $Root)

    $voice = Find-Voice $resources
    if ($voice) { Log ('Detected voice resource: ' + $voice) }
    else { Log 'WARNING: no supported FiveM voice resource detected. pma-voice is recommended.' }

    if ((Get-Process FXServer -ErrorAction SilentlyContinue) -and -not $NoGui) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ('FXServer appears to be running.' + $NL + $NL + 'For the safest install, stop the test server in txAdmin first.' + $NL + 'Continue anyway?'),
            'ReaperLink Installer',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { throw 'Installation cancelled. Stop FXServer and run the installer again.' }
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $work = Join-Path $env:TEMP ('ReaperLinkInstaller_' + $stamp)
    [System.IO.Directory]::CreateDirectory($work) | Out-Null

    $cfgBackup = $cfg + '.reaperlink-backup_' + $stamp
    [System.IO.File]::Copy($cfg,$cfgBackup,$true)
    Log ('Backed up server.cfg -> ' + $cfgBackup)
    Progress 15

    $existing = Find-VPhone $resources
    $savedConfig = ''
    if ($existing) {
        $destination = $existing
        $backup = Join-Path ([System.IO.Directory]::GetParent($existing).FullName) ('v-phone_REAPERLINK_BACKUP_' + $stamp)
        Log ('Backing up existing v-phone -> ' + $backup)
        Copy-Item -LiteralPath $existing -Destination $backup -Recurse -Force
        $oldConfig = Join-Path $existing 'config.lua'
        if (Test-Path -LiteralPath $oldConfig) {
            $savedConfig = Join-Path $work 'existing-config.lua'
            Copy-Item -LiteralPath $oldConfig -Destination $savedConfig -Force
            Log 'Preserved the existing v-phone config.lua.'
        }
        [System.IO.Directory]::Delete($existing,$true)
    } else {
        $phoneGroup = Join-Path $resources '[phone]'
        [System.IO.Directory]::CreateDirectory($phoneGroup) | Out-Null
        $destination = Join-Path $phoneGroup 'v-phone'
        $backup = ''
        Log ('No existing v-phone found. Installing to ' + $destination)
    }
    Progress 30

    Copy-ReaperLinkResource -Destination $destination -WorkDir $work
    if ($savedConfig -and (Test-Path -LiteralPath $savedConfig)) {
        Copy-Item -LiteralPath $savedConfig -Destination (Join-Path $destination 'config.lua') -Force
        Log 'Restored the server owner''s existing config.lua into ReaperLink.'
    }
    foreach ($required in @('fxmanifest.lua','apps\example\app.lua','html\physical.js','html\reaperlink-voice.js','html\reaperlink-voice-game.js')) {
        if (-not (Test-Path -LiteralPath (Join-Path $destination $required))) { throw ('Installed resource is missing ' + $required) }
    }
    Log 'ReaperLink resource files verified.'
    Progress 55

    $tunnelPid = 0
    if ($UseTunnel) {
        $cloudflared = Find-Cloudflared
        if (-not $cloudflared) { $cloudflared = Install-Cloudflared }
        Log ('cloudflared: ' + $cloudflared)
        $tunnel = Start-QuickTunnel -Cloudflared $cloudflared -WorkDir $work
        $publicUrl = $tunnel.Url
        $tunnelPid = [int]$tunnel.ProcessId
        Log ('Temporary HTTPS URL: ' + $publicUrl)
    } else {
        $publicUrl = Normalize-PhysicalUrl $ManualUrl
        Log ('Using supplied HTTPS URL: ' + $publicUrl)
    }
    Progress 70

    Set-CfgLine $cfg 'reaperlink_public_url' $publicUrl
    Set-CfgLine $cfg 'reaperlink_voice_stun' ([string]$Stun).Trim()
    Set-CfgLine $cfg 'reaperlink_voice_turn_url' ([string]$TurnUrl).Trim()
    Set-CfgLine $cfg 'reaperlink_voice_turn_user' ([string]$TurnUser).Trim()
    Set-CfgLine $cfg 'reaperlink_voice_turn_pass' ([string]$TurnPass).Trim()
    Ensure-CfgCommand $cfg 'ensure v-phone'
    Log 'Updated server.cfg.'
    Progress 82

    $rollback = Write-Rollback -ServerRoot $Root -CurrentVPhone $destination -BackupVPhone $backup -CfgBackup $cfgBackup -TunnelPid $tunnelPid

    $state = [ordered]@{
        installed_at = (Get-Date).ToString('o')
        build = 'ReaperLink Voice TEST/PREVIEW'
        branch = $RepoBranch
        vphone_path = $destination
        vphone_backup = $backup
        server_cfg_backup = $cfgBackup
        public_url = $publicUrl
        cloudflared_pid = $tunnelPid
        voice_resource = $voice
        rollback_script = $rollback
    }
    $statePath = Join-Path $Root 'reaperlink-install-state.json'
    [System.IO.File]::WriteAllText($statePath,($state | ConvertTo-Json -Depth 5),[System.Text.UTF8Encoding]::new($false))

    Progress 100
    Log 'INSTALL COMPLETE'
    Log ('Rollback script: ' + $rollback)
    Log 'Start/restart FiveM, join, run /physicalpair, and scan the QR.'
    Log 'Keep cloudflared running while using a Quick Tunnel.'
    return [PSCustomObject]$state
}

if ($NoGui) {
    if (-not $ServerData) { throw 'Use -ServerData <path> with -NoGui.' }
    Install-ReaperLink -Root $ServerData -UseTunnel $true -ManualUrl '' -Stun '' -TurnUrl '' -TurnUser '' -TurnPass '' | Out-Null
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ReaperLink Voice - FiveM Tester Installer'
$form.Size = New-Object System.Drawing.Size(760,590)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI',9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'ReaperLink Voice'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold',20)
$title.Location = New-Object System.Drawing.Point(24,18)
$title.AutoSize = $true
$form.Controls.Add($title)

$badge = New-Object System.Windows.Forms.Label
$badge.Text = 'TEST / PREVIEW BUILD'
$badge.Font = New-Object System.Drawing.Font('Segoe UI Semibold',9)
$badge.ForeColor = [System.Drawing.Color]::DarkOrange
$badge.Location = New-Object System.Drawing.Point(28,58)
$badge.AutoSize = $true
$form.Controls.Add($badge)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(24,88)
$tabs.Size = New-Object System.Drawing.Size(700,390)
$form.Controls.Add($tabs)

$pageWelcome = New-Object System.Windows.Forms.TabPage
$pageWelcome.Text = '1. Welcome'
$tabs.TabPages.Add($pageWelcome)

$welcome = New-Object System.Windows.Forms.Label
$welcome.Text = @'
This wizard installs the ReaperLink physical-phone test build into a Windows FiveM server.

It will:
 - Back up the existing v-phone resource.
 - Back up server.cfg.
 - Install ReaperLink Voice.
 - Configure the physical-phone HTTPS address.
 - Optionally create a temporary Cloudflare HTTPS tunnel.
 - Create a rollback script.

This is a tester build, not a production release.
The physical UI and solo phone microphone/speaker test have been proven.
Full mixed-player voice still needs live multi-player testing.

Stop the test server in txAdmin before installing when possible.
'@
$welcome.Location = New-Object System.Drawing.Point(22,24)
$welcome.Size = New-Object System.Drawing.Size(640,300)
$pageWelcome.Controls.Add($welcome)

$pageServer = New-Object System.Windows.Forms.TabPage
$pageServer.Text = '2. Server'
$tabs.TabPages.Add($pageServer)

$serverLabel = New-Object System.Windows.Forms.Label
$serverLabel.Text = 'FiveM server-data folder (contains server.cfg and resources):'
$serverLabel.Location = New-Object System.Drawing.Point(20,25)
$serverLabel.AutoSize = $true
$pageServer.Controls.Add($serverLabel)

$serverText = New-Object System.Windows.Forms.TextBox
$serverText.Location = New-Object System.Drawing.Point(22,54)
$serverText.Size = New-Object System.Drawing.Size(535,25)
if ($ServerData) { $serverText.Text = $ServerData }
elseif (Test-Path -LiteralPath 'E:\testserver\file\server.cfg') { $serverText.Text = 'E:\testserver\file' }
$pageServer.Controls.Add($serverText)

$browse = New-Object System.Windows.Forms.Button
$browse.Text = 'Browse...'
$browse.Location = New-Object System.Drawing.Point(570,52)
$browse.Size = New-Object System.Drawing.Size(90,28)
$pageServer.Controls.Add($browse)
$browse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select your FiveM server-data folder'
    if ($serverText.Text) { $dlg.SelectedPath = $serverText.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $serverText.Text = $dlg.SelectedPath }
})

$serverHelp = New-Object System.Windows.Forms.Label
$serverHelp.Text = 'Example: C:\FXServer\server-data   or   E:\testserver\file'
$serverHelp.ForeColor = [System.Drawing.Color]::DimGray
$serverHelp.Location = New-Object System.Drawing.Point(22,90)
$serverHelp.AutoSize = $true
$pageServer.Controls.Add($serverHelp)

$pageNetwork = New-Object System.Windows.Forms.TabPage
$pageNetwork.Text = '3. HTTPS / Voice'
$tabs.TabPages.Add($pageNetwork)

$quick = New-Object System.Windows.Forms.RadioButton
$quick.Text = 'Create temporary Cloudflare HTTPS tunnel automatically (recommended for testing)'
$quick.Location = New-Object System.Drawing.Point(22,22)
$quick.Size = New-Object System.Drawing.Size(620,25)
$quick.Checked = $true
$pageNetwork.Controls.Add($quick)

$manual = New-Object System.Windows.Forms.RadioButton
$manual.Text = 'Use my own public HTTPS URL'
$manual.Location = New-Object System.Drawing.Point(22,52)
$manual.Size = New-Object System.Drawing.Size(350,25)
$pageNetwork.Controls.Add($manual)

$urlLabel = New-Object System.Windows.Forms.Label
$urlLabel.Text = 'Public URL:'
$urlLabel.Location = New-Object System.Drawing.Point(44,86)
$urlLabel.AutoSize = $true
$pageNetwork.Controls.Add($urlLabel)

$urlText = New-Object System.Windows.Forms.TextBox
$urlText.Location = New-Object System.Drawing.Point(120,82)
$urlText.Size = New-Object System.Drawing.Size(520,25)
$urlText.Enabled = $false
$pageNetwork.Controls.Add($urlText)
$manual.Add_CheckedChanged({ $urlText.Enabled = $manual.Checked })

$stunLabel = New-Object System.Windows.Forms.Label
$stunLabel.Text = 'Optional STUN/TURN for cross-network tests:'
$stunLabel.Location = New-Object System.Drawing.Point(22,132)
$stunLabel.AutoSize = $true
$pageNetwork.Controls.Add($stunLabel)

$stunText = New-Object System.Windows.Forms.TextBox
$stunText.Location = New-Object System.Drawing.Point(22,158)
$stunText.Size = New-Object System.Drawing.Size(300,25)
$pageNetwork.Controls.Add($stunText)

$turnText = New-Object System.Windows.Forms.TextBox
$turnText.Location = New-Object System.Drawing.Point(338,158)
$turnText.Size = New-Object System.Drawing.Size(302,25)
$pageNetwork.Controls.Add($turnText)

$turnUserText = New-Object System.Windows.Forms.TextBox
$turnUserText.Location = New-Object System.Drawing.Point(22,194)
$turnUserText.Size = New-Object System.Drawing.Size(300,25)
$pageNetwork.Controls.Add($turnUserText)

$turnPassText = New-Object System.Windows.Forms.TextBox
$turnPassText.Location = New-Object System.Drawing.Point(338,194)
$turnPassText.Size = New-Object System.Drawing.Size(302,25)
$turnPassText.UseSystemPasswordChar = $true
$pageNetwork.Controls.Add($turnPassText)

$networkHelp = New-Object System.Windows.Forms.Label
$networkHelp.Text = 'Top: STUN URL | TURN URL. Bottom: TURN username | TURN password. Same-Wi-Fi testing can normally begin blank.'
$networkHelp.ForeColor = [System.Drawing.Color]::DimGray
$networkHelp.Location = New-Object System.Drawing.Point(22,236)
$networkHelp.Size = New-Object System.Drawing.Size(620,60)
$pageNetwork.Controls.Add($networkHelp)

$pageInstall = New-Object System.Windows.Forms.TabPage
$pageInstall.Text = '4. Install'
$tabs.TabPages.Add($pageInstall)

$script:ProgressBar = New-Object System.Windows.Forms.ProgressBar
$script:ProgressBar.Location = New-Object System.Drawing.Point(20,20)
$script:ProgressBar.Size = New-Object System.Drawing.Size(640,22)
$pageInstall.Controls.Add($script:ProgressBar)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Location = New-Object System.Drawing.Point(20,55)
$script:LogBox.Size = New-Object System.Drawing.Size(640,270)
$script:LogBox.Multiline = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.ReadOnly = $true
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas',8.5)
$pageInstall.Controls.Add($script:LogBox)

$back = New-Object System.Windows.Forms.Button
$back.Text = '< Back'
$back.Location = New-Object System.Drawing.Point(470,500)
$back.Size = New-Object System.Drawing.Size(80,30)
$form.Controls.Add($back)

$next = New-Object System.Windows.Forms.Button
$next.Text = 'Next >'
$next.Location = New-Object System.Drawing.Point(560,500)
$next.Size = New-Object System.Drawing.Size(80,30)
$form.Controls.Add($next)

$install = New-Object System.Windows.Forms.Button
$install.Text = 'Install'
$install.Location = New-Object System.Drawing.Point(650,500)
$install.Size = New-Object System.Drawing.Size(74,30)
$install.Enabled = $false
$form.Controls.Add($install)

$back.Add_Click({ if ($tabs.SelectedIndex -gt 0) { $tabs.SelectedIndex-- } })

$next.Add_Click({
    if ($tabs.SelectedIndex -eq 1) {
        $root = $serverText.Text.Trim()
        if (-not (Test-Path -LiteralPath (Join-Path $root 'server.cfg')) -or -not (Test-Path -LiteralPath (Join-Path $root 'resources'))) {
            [System.Windows.Forms.MessageBox]::Show('That folder does not contain both server.cfg and resources.','ReaperLink Installer',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }
    }
    if ($tabs.SelectedIndex -eq 2 -and $manual.Checked) {
        try { Normalize-PhysicalUrl $urlText.Text | Out-Null }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'ReaperLink Installer',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }
    }
    if ($tabs.SelectedIndex -lt 3) { $tabs.SelectedIndex++ }
})

$tabs.Add_SelectedIndexChanged({
    $back.Enabled = $tabs.SelectedIndex -gt 0
    $next.Enabled = $tabs.SelectedIndex -lt 3
    $install.Enabled = $tabs.SelectedIndex -eq 3
})

$install.Add_Click({
    $install.Enabled = $false
    $back.Enabled = $false
    $next.Enabled = $false
    try {
        $state = Install-ReaperLink -Root $serverText.Text -UseTunnel $quick.Checked -ManualUrl $urlText.Text -Stun $stunText.Text -TurnUrl $turnText.Text -TurnUser $turnUserText.Text -TurnPass $turnPassText.Text
        $message = 'ReaperLink test build installed.' + $NL + $NL + 'Public phone URL:' + $NL + $state.public_url + $NL + $NL + 'Start/restart FiveM, join, and run /physicalpair.'
        [System.Windows.Forms.MessageBox]::Show($message,'ReaperLink Installer',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        Log ('ERROR: ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'ReaperLink Installer',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        $install.Enabled = $true
        $back.Enabled = $true
    }
})

$tabs.SelectedIndex = 0
$back.Enabled = $false
[void]$form.ShowDialog()
