param(
  [Parameter(Mandatory=$true)]
  [ValidateSet("js-syntax","manifest","signaling-routes","session-security","browser-voice","ice-config","physical-regression","call-sync","https-gate","package-smoke")]
  [string]$Task,
  [Parameter(Mandatory=$true)]
  [string]$Slot
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path ".").Path
$outDir = Join-Path $root ".voice-validation"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$report = Join-Path $outDir "$Task.txt"
Remove-Item $report -Force -ErrorAction SilentlyContinue

function Pass([string]$m) { Add-Content $report "PASS: $m"; Write-Host "PASS: $m" -ForegroundColor Green }
function Fail([string]$m) { Add-Content $report "FAIL: $m"; throw $m }
function Has([string]$path,[string]$needle) {
  $text = Get-Content -LiteralPath (Join-Path $root $path) -Raw
  if ($text.Contains($needle)) { Pass "$path contains $needle" } else { Fail "$path missing $needle" }
}

Add-Content $report "ReaperLink Voice validation"
Add-Content $report "Requested slot: $Slot"
Add-Content $report "Actual runner: $env:RUNNER_NAME"
Add-Content $report "Task: $Task"
Add-Content $report "Commit: $env:GITHUB_SHA"

switch ($Task) {
  "js-syntax" {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail "node unavailable after setup-node" }
    node --check .\html\reaperlink-voice.js
    if ($LASTEXITCODE -ne 0) { Fail "reaperlink-voice.js syntax error" }
    node --check .\html\physical.js
    if ($LASTEXITCODE -ne 0) { Fail "physical.js syntax error" }
    node --check .\html\reaperlink-voice-game.js
    if ($LASTEXITCODE -ne 0) { Fail "reaperlink-voice-game.js syntax error" }
    Pass "physical and FiveM voice JavaScript parses"
  }
  "manifest" {
    Has "fxmanifest.lua" "'html/reaperlink-voice.js'"
    Has "fxmanifest.lua" "'html/reaperlink-voice-game.js'"
    Has "html/index.html" '<script src="reaperlink-voice-game.js"></script>'
    Has "apps/example/app.lua" '<script src="reaperlink-voice.js"></script>'
  }
  "signaling-routes" {
    Has "apps/example/app.lua" "^/physical/voice/join/"
    Has "apps/example/app.lua" "^/physical/voice/events/"
    Has "apps/example/app.lua" "^/physical/voice/chunk/"
    Has "apps/example/app.lua" "^/physical/voice/send/"
    Has "apps/example/app.lua" "^/physical/voice/leave/"
    Has "apps/example/app.lua" "v-phone:physical:gameVoiceJoin"
    Has "apps/example/app.lua" "v-phone:physical:gameVoiceSignal"
    Has "apps/example/app.lua" "v-phone:physical:gameVoiceLeave"
  }
  "session-security" {
    Has "apps/example/app.lua" "voiceById"
    Has "apps/example/app.lua" "voiceCallId"
    Has "apps/example/app.lua" "bridgeState(s.source)"
    Has "apps/example/app.lua" "tostring(peer.callId or '') ~= tostring(mine.callId or '')"
    Has "apps/example/app.lua" "sessionForToken"
    Has "server/main.lua" "function ReaperLinkCallBridgeState(src)"
    Has "apps/example/app.lua" "browser may only join the active call mirrored"
    $bridge = Get-Content -LiteralPath (Join-Path $root "apps/example/app.lua") -Raw
    $handlerCount = ([regex]::Matches($bridge, [regex]::Escape("SetHttpHandler(function(req, res)"))).Count
    if ($handlerCount -eq 1) {
      Pass "one physical HTTP handler"
    } else { Fail "duplicate physical HTTP handler detected ($handlerCount)" }
    $lines = (Get-Content -LiteralPath (Join-Path $root "apps/example/app.lua")).Count
    if ($lines -lt 1400) { Pass "physical bridge file size sane ($lines lines)" }
    else { Fail "physical bridge file unexpectedly large ($lines lines)" }
  }
  "browser-voice" {
    Has "html/reaperlink-voice.js" "navigator.mediaDevices.getUserMedia"
    Has "html/reaperlink-voice.js" "RTCPeerConnection"
    Has "html/reaperlink-voice.js" "echoCancellation:true"
    Has "html/reaperlink-voice.js" "noiseSuppression:true"
    Has "html/reaperlink-voice.js" "autoGainControl:true"
    Has "html/reaperlink-voice.js" "audio.autoplay = true"
    Has "html/reaperlink-voice-game.js" "navigator.mediaDevices.getUserMedia"
    Has "html/reaperlink-voice-game.js" "RTCPeerConnection"
    Has "html/reaperlink-voice-game.js" "reaperVoiceGameSignal"
  }
  "ice-config" {
    Has "apps/example/app.lua" "reaperlink_voice_stun"
    Has "apps/example/app.lua" "reaperlink_voice_turn_url"
    Has "html/reaperlink-voice.js" "iceServers()"
    Has "html/reaperlink-voice-game.js" "iceServers()"
  }
  "physical-regression" {
    Has "html/physical.js" "window.__VPHONE_IS_PHYSICAL__ = true"
    Has "html/physical.js" "/events/"
    Has "apps/example/app.lua" "/physical/pair/"
    Has "apps/example/app.lua" "/physical/api/"
    Has "apps/example/app.lua" "/physical/open/"
  }
  "call-sync" {
    Has "apps/example/app.lua" "message.action == 'call'"
    Has "apps/example/app.lua" "nextCall.state == 'active'"
    Has "html/reaperlink-voice.js" "message.action !== 'call'"
    Has "html/reaperlink-voice.js" "call.state === 'active'"
    Has "apps/example/app.lua" "reaperlink:gameVoiceStart"
    Has "apps/example/app.lua" "selfPhysical"
    Has "client/main.lua" "ReaperLinkMixedVoiceActive"
    Has "client/main.lua" "function ReaperLinkCallIsActive(id)"
    Has "apps/example/app.lua" "function ReaperLinkVoiceRefreshCall(callId)"
    Has "apps/example/app.lua" "function ReaperLinkVoiceEndCall(callId)"
    Has "apps/example/app.lua" "VOICE_STALE_MS"
  }
  "https-gate" {
    Has "html/reaperlink-voice.js" "window.isSecureContext"
    Has "html/reaperlink-voice.js" "Voice needs HTTPS for phone microphone"
  }
  "package-smoke" {
    foreach ($p in @(
      "fxmanifest.lua",
      "apps/example/app.lua",
      "html/index.html",
      "html/physical.js",
      "html/reaperlink-voice.js",
      "html/reaperlink-voice-game.js",
      "html/qrcode.js",
      "html/reaper-mark.svg"
    )) {
      if (Test-Path -LiteralPath (Join-Path $root $p)) { Pass "$p exists" } else { Fail "$p missing" }
    }
  }
}

Add-Content $report "RESULT: SUCCESS"
