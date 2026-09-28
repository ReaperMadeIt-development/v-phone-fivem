param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "call-map",
        "browser-audio",
        "microphone",
        "webrtc",
        "signaling",
        "fivem-voice",
        "mixed-user",
        "mobile",
        "security",
        "packaging"
    )]
    [string]$Task,

    [Parameter(Mandatory = $true)]
    [string]$Slot
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path ".").Path
$reportDir = Join-Path $root ".squad-reports"
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$report = Join-Path $reportDir "$Task.txt"

function Add-Line([string]$Text = "") {
    Add-Content -LiteralPath $report -Value $Text
}

function Add-Search([string]$Heading, [string]$Pattern, [string[]]$Paths) {
    Add-Line ""
    Add-Line "=== $Heading ==="
    $existing = @()
    foreach ($p in $Paths) {
        $full = Join-Path $root $p
        if (Test-Path -LiteralPath $full) {
            $existing += $full
        }
    }

    if (-not $existing) {
        Add-Line "No matching source roots found."
        return
    }

    $files = foreach ($path in $existing) {
        if ((Get-Item -LiteralPath $path).PSIsContainer) {
            Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in ".lua", ".js", ".html", ".css", ".json", ".md" }
        }
        else {
            Get-Item -LiteralPath $path
        }
    }

    $hits = $files | Select-String -Pattern $Pattern -CaseSensitive:$false -ErrorAction SilentlyContinue
    if ($hits) {
        $hits |
            Select-Object -First 400 |
            ForEach-Object {
                $rel = $_.Path.Substring($root.Length).TrimStart("\")
                Add-Line ("{0}:{1}: {2}" -f $rel, $_.LineNumber, $_.Line.Trim())
            }
    }
    else {
        Add-Line "No hits."
    }
}

Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue

Add-Line "ReaperLink Voice Squad"
Add-Line "Task: $Task"
Add-Line "Requested slot: $Slot"
Add-Line "Actual runner: $env:RUNNER_NAME"
Add-Line "Machine: $env:COMPUTERNAME"
Add-Line "Commit: $env:GITHUB_SHA"
Add-Line "Branch: $env:GITHUB_REF"
Add-Line "Generated: $(Get-Date -Format o)"

switch ($Task) {
    "call-map" {
        Add-Search "Existing phone call lifecycle" "call|ring|dial|answer|hangup|decline|busy" @("client","server","bridge","html")
    }
    "browser-audio" {
        Add-Search "Browser audio surface" "audio|speaker|volume|media|navigator|MediaStream|AudioContext" @("html")
        Add-Line ""
        Add-Line "Browser secure-context note: getUserMedia requires HTTPS or a secure local context in normal mobile browsers."
    }
    "microphone" {
        Add-Search "Mic permission and capture hooks" "getUserMedia|microphone|permission|mute|MediaStreamTrack" @("html","client")
    }
    "webrtc" {
        Add-Search "Existing realtime/browser transport" "RTCPeerConnection|RTCSessionDescription|ICE|WebRTC|WebSocket|fetch\(" @("html","apps","server")
    }
    "signaling" {
        Add-Search "Physical session/auth transport" "physical|pair|token|session|SetHttpHandler|nuiMessage|nuiReply" @("apps","html")
    }
    "fivem-voice" {
        Add-Search "FiveM voice integrations" "pma|mumble|voice|callChannel|SetCall|proximity|radio" @("client","server","bridge","config.lua")
    }
    "mixed-user" {
        Add-Search "Call state needed for phone-to-PC fallback" "call|voice|speaker|mute|connected|disconnect|answer|hangup" @("client","server","html")
    }
    "mobile" {
        Add-Search "Mobile-browser behavior" "physical-handset|touch|pointer|visibilitychange|pagehide|beforeunload|wake|audio" @("html")
    }
    "security" {
        Add-Search "Session and trust boundaries" "token|session|identity|rate|expires|pair|origin|cors|csrf|secret" @("apps","server","html")
    }
    "packaging" {
        Add-Search "Release/install configuration" "reaperlink_public_url|physicalpair|fxmanifest|ensure|server.cfg|install|setup" @(".")
    }
}

Add-Line ""
Add-Line "=== Tool availability on actual local runner ==="
foreach ($cmd in @("git","node","npm","python","py","ffmpeg","rustc","cargo","gh","codex")) {
    $found = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($found) {
        Add-Line ("{0}: {1}" -f $cmd, $found.Source)
    }
    else {
        Add-Line ("{0}: NOT FOUND" -f $cmd)
    }
}

Add-Line ""
Add-Line "TASK COMPLETE"

Write-Host ""
Write-Host "ReaperLink Voice squad task complete" -ForegroundColor Green
Write-Host "Requested slot: $Slot"
Write-Host "Actual runner: $env:RUNNER_NAME"
Write-Host "Task: $Task"
Write-Host "Report: $report"
