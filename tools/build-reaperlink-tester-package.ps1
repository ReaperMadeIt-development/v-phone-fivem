param(
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\dist')
)

$ErrorActionPreference = 'Stop'
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out = [System.IO.Path]::GetFullPath($OutputDir)
$stage = Join-Path $out 'ReaperLink-Tester-Package'
$zip = Join-Path $out 'ReaperLink-Tester-Package.zip'

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }

[System.IO.Directory]::CreateDirectory($stage) | Out-Null
$resourceRoot = Join-Path $stage 'resource\v-phone'
[System.IO.Directory]::CreateDirectory($resourceRoot) | Out-Null

$packageFiles = @(
    'installer\ReaperLink-Test-Installer.ps1',
    'installer\Install-ReaperLink.bat',
    'installer\README-TESTERS.txt',
    'installer\TEST-CHECKLIST.txt',
    'LICENSE',
    'NOTICE',
    'THIRD_PARTY_NOTICES.md'
)

foreach ($item in $packageFiles) {
    $src = Join-Path $repo $item
    if (-not (Test-Path -LiteralPath $src)) { throw ('Missing package file: ' + $item) }
    Copy-Item -LiteralPath $src -Destination (Join-Path $stage ([System.IO.Path]::GetFileName($item))) -Force
}

$resourceDirs = @('apps','bridge','client','compat','docs','html','locales','server','sounds')
foreach ($dir in $resourceDirs) {
    $src = Join-Path $repo $dir
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $resourceRoot -Recurse -Force
    }
}

foreach ($file in @(
    'fxmanifest.lua',
    'config.lua',
    'LICENSE',
    'NOTICE',
    'THIRD_PARTY_NOTICES.md',
    'REAPERLINK_SETUP.md',
    'REAPERLINK_VOICE_LIVE_TEST.md'
)) {
    $src = Join-Path $repo $file
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $resourceRoot -Force
    }
}

foreach ($required in @(
    'fxmanifest.lua',
    'apps\example\app.lua',
    'html\physical.js',
    'html\reaperlink-voice.js',
    'html\reaperlink-voice-game.js'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $resourceRoot $required))) {
        throw ('Package validation failed: missing ' + $required)
    }
}

Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal
$size = (Get-Item -LiteralPath $zip).Length
Write-Host ('Built ReaperLink tester package: {0} bytes' -f $size)
Write-Host $zip
