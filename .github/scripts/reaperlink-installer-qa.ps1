param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('source-gate','safety-gate','payload-gate','compile-gate','distribution-gate')]
  [string]$Task,

  [string]$Persona = 'QA'
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$reportDir = Join-Path $root '.installer-qa'
New-Item -ItemType Directory -Force $reportDir | Out-Null
$report = Join-Path $reportDir ($Task + '.txt')

function Pass([string]$Message) {
  Add-Content -LiteralPath $report -Value ("PASS  " + $Message)
  Write-Host ("PASS  " + $Message) -ForegroundColor Green
}

function Fail([string]$Message) {
  Add-Content -LiteralPath $report -Value ("FAIL  " + $Message)
  throw $Message
}

function ReadText([string]$Relative) {
  $path = Join-Path $root $Relative
  if (-not (Test-Path -LiteralPath $path)) { Fail ("Missing file: " + $Relative) }
  return [System.IO.File]::ReadAllText($path)
}

function Find-Iscc {
  $candidates = @(
    "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Inno Setup 6\ISCC.exe"
  )

  foreach ($regPath in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1'
  )) {
    try {
      $loc = (Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop).InstallLocation
      if ($loc) { $candidates += (Join-Path $loc 'ISCC.exe') }
    } catch {}
  }

  return ($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
}

Set-Content -LiteralPath $report -Value ("ReaperLink Installer QA - " + $Persona + " - " + $Task)

switch ($Task) {
  'source-gate' {
    $core = Join-Path $root 'installer\ReaperLink-InstallCore.ps1'
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($core,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) {
      $errors | ForEach-Object { Add-Content -LiteralPath $report -Value $_.Message }
      Fail 'Install core PowerShell has syntax errors.'
    }
    Pass 'Install core PowerShell parses cleanly.'

    $iss = ReadText 'installer\ReaperLink-Setup.iss'
    foreach ($needle in @(
      'WizardStyle=modern',
      'PrivilegesRequired=admin',
      'OutputBaseFilename=ReaperLink-Voice-Tester-Setup',
      'VersionInfoProductVersion=0.1.0.0',
      'CreateInputDirPage',
      'CreateInputOptionPage',
      'CreateInputQueryPage',
      'ReaperLink-Rollback.ps1'
    )) {
      if (-not $iss.Contains($needle)) { Fail ("Setup wizard missing expected directive/code: " + $needle) }
    }
    Pass 'Setup wizard contains the required modern wizard flow and metadata.'
  }

  'safety-gate' {
    $core = ReadText 'installer\ReaperLink-InstallCore.ps1'
    foreach ($needle in @(
      "$cfg + '.reaperlink-backup_'",
      'v-phone_REAPERLINK_BACKUP_',
      'Preserved existing config.lua',
      'Restored server owner config.lua into ReaperLink',
      'Write-Rollback',
      'reaperlink-install-state.json'
    )) {
      if (-not $core.Contains($needle)) { Fail ("Safety mechanism missing: " + $needle) }
    }
    Pass 'Backups, config preservation, install state, and rollback generation are present.'

    if ($core -match '(?i)Remove-Item.+server\.cfg') { Fail 'Installer appears able to delete server.cfg.' }
    Pass 'No server.cfg deletion path detected.'
  }

  'payload-gate' {
    foreach ($required in @(
      'fxmanifest.lua',
      'apps\example\app.lua',
      'html\physical.js',
      'html\reaperlink-voice.js',
      'html\reaperlink-voice-game.js',
      'html\qrcode.js',
      'html\reaper-mark.svg',
      'LICENSE',
      'NOTICE',
      'THIRD_PARTY_NOTICES.md'
    )) {
      if (-not (Test-Path -LiteralPath (Join-Path $root $required))) { Fail ("Missing payload file: " + $required) }
    }
    Pass 'Required ReaperLink payload files exist.'

    $manifest = ReadText 'fxmanifest.lua'
    foreach ($needle in @('reaperlink-voice.js','reaperlink-voice-game.js')) {
      if (-not $manifest.Contains($needle)) { Fail ("fxmanifest missing: " + $needle) }
    }
    Pass 'fxmanifest ships the ReaperLink voice browser assets; physical.js is served by the authenticated physical HTTP bridge.'
  }

  'compile-gate' {
    $iscc = Find-Iscc
    if (-not $iscc) { Fail 'Inno Setup compiler is not installed on this QA runner.' }
    Pass ("Using Inno Setup compiler: " + $iscc)

    $out = Join-Path $root 'dist'
    New-Item -ItemType Directory -Force $out | Out-Null
    & $iscc (Join-Path $root 'installer\ReaperLink-Setup.iss')
    if ($LASTEXITCODE -ne 0) { Fail ("Inno Setup compile failed with exit code " + $LASTEXITCODE) }

    $exe = Join-Path $out 'ReaperLink-Voice-Tester-Setup.exe'
    if (-not (Test-Path -LiteralPath $exe)) { Fail 'Setup EXE was not created.' }
    $size = (Get-Item -LiteralPath $exe).Length
    if ($size -lt 1000000) { Fail ("Setup EXE is unexpectedly small: " + $size) }
    Pass ("Setup EXE compiled successfully: " + $size + " bytes")
  }

  'distribution-gate' {
    foreach ($required in @(
      'LICENSE',
      'NOTICE',
      'THIRD_PARTY_NOTICES.md',
      'installer\README-TESTERS.txt',
      'installer\TEST-CHECKLIST.txt',
      'installer\ReaperLink-Setup.iss',
      'installer\ReaperLink-InstallCore.ps1'
    )) {
      if (-not (Test-Path -LiteralPath (Join-Path $root $required))) { Fail ("Distribution file missing: " + $required) }
    }
    Pass 'Licensing, attribution, tester guide, checklist, and installer sources are present.'

    $readme = ReadText 'installer\README-TESTERS.txt'
    foreach ($needle in @('/physicalpair','/reaperlinkvoicetest','TESTING','ROLLBACK')) {
      if (-not $readme.Contains($needle)) { Fail ("Tester documentation missing: " + $needle) }
    }
    Pass 'Tester documentation contains pairing, solo voice test, testing status, and rollback guidance.'
  }
}

Pass ("QA task complete on actual runner " + $env:RUNNER_NAME)
