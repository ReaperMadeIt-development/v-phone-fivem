# ReaperLink Voice - live test

Development branch: reaperlink-voice-dev

Rollback branch: reaperlink-rc1

## Implemented

- Physical handset microphone capture with echo cancellation, noise suppression and automatic gain control.
- Physical handset remote audio playback.
- WebRTC signaling tied to the authenticated ReaperLink physical session.
- The server derives the active voice room from v-phone's own call state; the browser cannot choose an arbitrary call.
- Physical-to-physical WebRTC calls.
- Mixed physical-handset to normal FiveM-client WebRTC calls.
- Normal FiveM-to-FiveM calls remain on the existing v-voice / pma-voice path.
- Mixed mode waits for the normal FiveM NUI microphone before leaving pma-voice.
- If the FiveM NUI microphone cannot start, the mixed call falls back to normal FiveM headset audio.
- Stale physical voice endpoints are removed when a mobile browser disappears.
- Early ICE candidates are queued until the remote description exists.
- Optional STUN/TURN configuration.

## HTTPS

The physical phone microphone requires a secure browser context. Plain LAN HTTP remains useful for UI and control testing, but live microphone testing needs HTTPS.

The local live-test script under tools can start a Cloudflare quick tunnel when cloudflared is installed and update reaperlink_public_url automatically.

## Optional ICE convars

~~~cfg
setr reaperlink_voice_stun ""
setr reaperlink_voice_turn_url ""
setr reaperlink_voice_turn_user ""
setr reaperlink_voice_turn_pass ""
~~~

Same-LAN testing can be attempted without them. Reliable cross-network deployment should use operator-controlled STUN/TURN infrastructure.

## Live-test gate

1. Normal FiveM headset to normal FiveM headset must behave exactly as before.
2. Physical handset to physical handset.
3. Physical handset to normal FiveM headset.
4. Answer and hang up from the real phone.
5. Mute from the physical ReaperLink Voice status control.
6. Kill or suspend the real-phone browser during a call and confirm cleanup/fallback.
7. Deny the FiveM NUI microphone and confirm fallback to normal FiveM audio.
8. Deny the physical-phone microphone and confirm no half-open voice room remains.
9. Re-pair and make a second call after the first ends.
10. Confirm QR pairing and non-call apps still work.

Do not merge this branch into RC1 until these live voice tests pass.
