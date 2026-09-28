# ReaperLink Voice - squad build plan

Base: `reaperlink-rc1`  
Development branch: `reaperlink-voice-dev`

The existing RC remains the rollback point. Voice work stays isolated until it passes live tests.

## Product target

A player pairs a real phone with ReaperLink and can optionally use the real handset's microphone and speaker for an in-game phone call.

The normal FiveM phone still controls the authoritative call state. ReaperLink Voice adds a media path; it does not grant new call permissions or bypass the existing phone callbacks.

Target modes:

- physical phone <-> physical phone
- physical phone <-> ordinary FiveM headset user
- ordinary FiveM headset <-> ordinary FiveM headset unchanged
- physical audio disabled -> existing PC audio behavior remains available

## Ten-runner split

1. Terminator - map the current call lifecycle.
2. Predator - browser audio/output requirements.
3. Johnny-5 - mobile microphone capture and permissions.
4. Rambo - WebRTC media core.
5. Snake Eyes - authenticated signaling tied to ReaperLink sessions.
6. Dave - FiveM voice-resource bridge/integration surface.
7. Jeff - mixed physical/PC call behavior.
8. Steve - Android/iPhone lifecycle, Bluetooth, speakerphone, reconnect.
9. Mike - session isolation, replay protection, cleanup, rate limits.
10. Gary - packaging, config, smoke tests, release checks.

## Build gates

1. Inventory and architecture.
2. Browser mic permission prototype.
3. Authenticated signaling prototype.
4. Physical-to-physical audio.
5. Mixed physical-to-PC audio.
6. Call-state sync: ringing, answer, mute, speaker, hangup.
7. Disconnect/reconnect and session cleanup.
8. Mobile browser testing.
9. Regression testing of QR pairing and all existing phone controls.
10. Release packaging.

## Important deployment requirement

Microphone capture through a normal mobile browser requires a secure context. Production ReaperLink Voice should therefore be served over HTTPS. Plain HTTP may remain useful for current LAN UI testing, but it is not the production voice deployment target.

## Runner workflow

`.github/workflows/reaperlink-voice-squad.yml` fans ten jobs across the organization's `self-hosted` + `org-shared` runner pool with `max-parallel: 10`.

The jobs record the actual `RUNNER_NAME`, so the Squad dashboard can show which physical runner accepted each slot.
