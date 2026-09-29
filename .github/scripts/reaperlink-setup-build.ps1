param(
    [string]$Attempt = "primary"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$InstallerCore = Join-Path $Root "installer\ReaperLink-InstallCore.ps1"
$InstallerScript = Join-Path $Root "installer\ReaperLink-Setup.iss"
$Dist = Join-Path $Root "dist"
$Exe = Join-Path $Dist "ReaperLink-Voice-Tester-Setup.exe"

function Find-Iscc {
    $paths = @(
        "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Inno Setup 6\ISCC.exe"
    )

    foreach ($regPath in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1"
    )) {
        try {
            $loc = (Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop).InstallLocation
            if ($loc) { $paths += (Join-Path $loc "ISCC.exe") }
        } catch {}
    }

    return ($paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
}

Write-Host "=== ReaperLink Setup Build: $Attempt ===" -ForegroundColor Cyan
Write-Host "Runner: $env:RUNNER_NAME" -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $InstallerCore)) {
    throw "Installer engine missing: $InstallerCore"
}
if (-not (Test-Path -LiteralPath $InstallerScript)) {
    throw "Inno Setup script missing: $InstallerScript"
}

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $InstallerCore,
    [ref]$tokens,
    [ref]$errors
) | Out-Null

if ($errors.Count) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw "Installer engine PowerShell syntax validation failed."
}
Write-Host "PASS installer engine syntax" -ForegroundColor Green

$iscc = Find-Iscc
if (-not $iscc) {
    Write-Host "Inno Setup not found. Installing..." -ForegroundColor Yellow
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        & $winget.Source install --id JRSoftware.InnoSetup -e --accept-package-agreements --accept-source-agreements --silent
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "winget returned exit code $LASTEXITCODE"
        }
        Start-Sleep -Seconds 2
        $iscc = Find-Iscc
    }
}

if (-not $iscc) {
    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if ($choco) {
        & $choco.Source install innosetup -y --no-progress
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Chocolatey returned exit code $LASTEXITCODE"
        }
        Start-Sleep -Seconds 2
        $iscc = Find-Iscc
    }
}

if (-not $iscc) {
    throw "ISCC.exe could not be located or installed on runner $env:RUNNER_NAME."
}

Write-Host "ISCC: $iscc" -ForegroundColor DarkGray

New-Item -ItemType Directory -Force $Dist | Out-Null
Remove-Item -LiteralPath $Exe -Force -ErrorAction SilentlyContinue

& $iscc $InstallerScript
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compile failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $Exe)) {
    throw "Setup EXE was not produced: $Exe"
}

$size = (Get-Item -LiteralPath $Exe).Length
if ($size -lt 1000000) {
    throw "Setup EXE is unexpectedly small: $size bytes."
}

$hash = (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash
Write-Host "PASS ReaperLink setup EXE compiled" -ForegroundColor Green
Write-Host "EXE: $Exe"
Write-Host "SIZE: $size"
Write-Host "SHA256: $hash"

if ($env:GITHUB_OUTPUT) {
    "exe=$Exe" >> $env:GITHUB_OUTPUT
    "size=$size" >> $env:GITHUB_OUTPUT
    "sha256=$hash" >> $env:GITHUB_OUTPUT
    "attempt=$Attempt" >> $env:GITHUB_OUTPUT
    "runner=$env:RUNNER_NAME" >> $env:GITHUB_OUTPUT
}
