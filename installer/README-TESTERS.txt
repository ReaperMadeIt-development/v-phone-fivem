REAPERLINK VOICE - TESTER PACKAGE
=================================

ReaperLink turns v-phone into a paired real-smartphone control surface and adds
experimental physical-handset voice.

STATUS
------
This package is for controlled TESTING, not production deployment.

Already proven on a real handset:
- HTTPS physical-phone pairing
- full physical-phone UI/control bridge
- phone microphone permission/capture
- phone audio playback
- solo mic -> playback test

Still requires broader live testing:
- physical phone <-> another physical phone
- physical phone <-> normal FiveM headset
- receiver/earpiece vs speaker routing on multiple phone/browser models
- cross-network STUN/TURN conditions
- reconnect/fallback behavior under real player load

INSTALL
-------
1. Stop the FiveM test server in txAdmin when possible.
2. Extract this ZIP on the Windows machine that hosts the FiveM server.
3. Double-click Install-ReaperLink.bat.
4. Pick the FiveM server-data folder containing:
      server.cfg
      resources\
5. For a quick test, keep "Temporary Cloudflare HTTPS tunnel" selected.
6. Click Install.
7. Start/restart the FiveM server.
8. Join the server and run:
      /physicalpair
9. Scan the QR code on the real phone.

VOICE TEST
----------
Solo hardware check:
    /reaperlinkvoicetest

Then test with another player:
- physical phone -> FiveM headset
- FiveM headset -> physical phone
- mute
- speaker toggle
- answer/hang up
- browser disconnect/reconnect

ROLLBACK
--------
The installer creates:
    ReaperLink-Rollback.ps1
inside the selected server-data folder.

It also backs up:
- the existing v-phone directory
- server.cfg

Run the rollback script from PowerShell, then restart the FiveM server.

HTTPS
-----
A mobile browser normally requires HTTPS for microphone capture.

The installer can launch a temporary Cloudflare Quick Tunnel. That process must
remain running while the test is active. A production server should use a
stable HTTPS hostname/tunnel or reverse proxy instead of a temporary quick tunnel.

VOICE NETWORKING
----------------
Same-Wi-Fi testing can often begin without STUN/TURN.
Reliable voice across different NATs/networks should use server-operator-controlled
STUN/TURN infrastructure.

LICENSING / ATTRIBUTION
-----------------------
This package includes modified v-phone code. Keep LICENSE, NOTICE, and
THIRD_PARTY_NOTICES.md with distributed copies.

v-phone / iFruit copyright and attribution remain with vyrriox.
ReaperLink modifications are distributed by ReaperMadeIt-development.

Repository:
https://github.com/ReaperMadeIt-development/v-phone-fivem
Branch:
reaperlink-voice-dev
