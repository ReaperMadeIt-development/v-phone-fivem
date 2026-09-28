/* ReaperLink Voice - physical handset WebRTC media path
 *
 * Loaded only by the paired physical browser. FiveM remains authoritative for call state;
 * this module may join only the active call id mirrored from the paired client.
 */
(() => {
  'use strict';

  const cfg = window.__VPHONE_PHYSICAL__;
  if (!cfg || !cfg.token || !cfg.base) return;

  const token = String(cfg.token);
  const base = String(cfg.base).replace(/\/+$/, '');
  const nativeFetch = window.fetch.bind(window);
  const encoder = new TextEncoder();


  function iceServers() {
    const voice = cfg.voice && typeof cfg.voice === 'object' ? cfg.voice : {};
    const servers = [];
    if (voice.stun) servers.push({ urls:String(voice.stun) });
    if (voice.turn && voice.turn.url) {
      const entry = { urls:String(voice.turn.url) };
      if (voice.turn.username) entry.username = String(voice.turn.username);
      if (voice.turn.credential) entry.credential = String(voice.turn.credential);
      servers.push(entry);
    }
    return servers;
  }

  let activeCallId = null;
  let localStream = null;
  let voiceId = null;
  let eventAfter = 0;
  let polling = false;
  let stopping = false;
  let muted = false;
  const peers = new Map();
  const audios = new Map();

  function bytesToBase64Url(bytes) {
    let binary = '';
    const step = 0x8000;
    for (let i = 0; i < bytes.length; i += step) {
      binary += String.fromCharCode(...bytes.subarray(i, Math.min(i + step, bytes.length)));
    }
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
  }

  function encodeText(value) {
    return bytesToBase64Url(encoder.encode(String(value ?? '')));
  }

  function requestId() {
    if (window.crypto && crypto.getRandomValues) {
      const a = new Uint32Array(4);
      crypto.getRandomValues(a);
      return Array.from(a, n => n.toString(16).padStart(8, '0')).join('');
    }
    return (Date.now().toString(16) + Math.random().toString(16).slice(2)).replace(/[^a-z0-9]/gi, '');
  }

  function ensureUi() {
    if (document.getElementById('reaperlink-voice-status')) return;
    const style = document.createElement('style');
    style.textContent = `
      #reaperlink-voice-status {
        position:fixed; z-index:2147483645; left:50%; bottom:max(12px,env(safe-area-inset-bottom));
        transform:translateX(-50%); display:none; align-items:center; gap:8px;
        max-width:92vw; padding:9px 12px; border-radius:999px;
        background:rgba(12,12,16,.92); border:1px solid rgba(255,255,255,.12);
        color:#f3f3f3; font:650 12px system-ui,-apple-system,Segoe UI,sans-serif;
        box-shadow:0 8px 30px rgba(0,0,0,.35); backdrop-filter:blur(12px);
      }
      #reaperlink-voice-status.show { display:flex; }
      #reaperlink-voice-status button {
        border:0; border-radius:999px; padding:6px 9px; background:#24242b; color:#fff;
        font:700 12px system-ui,-apple-system,Segoe UI,sans-serif;
      }
      #reaperlink-voice-status[data-state="live"] .dot { background:#65dc78; }
      #reaperlink-voice-status[data-state="warn"] .dot { background:#ffb84d; }
      #reaperlink-voice-status[data-state="bad"] .dot { background:#ff5d67; }
      #reaperlink-voice-status .dot {
        width:8px;height:8px;border-radius:50%;background:#777;box-shadow:0 0 10px currentColor;
      }
    `;
    document.head.appendChild(style);

    const el = document.createElement('div');
    el.id = 'reaperlink-voice-status';
    el.innerHTML = '<span class="dot"></span><span class="label">ReaperLink Voice</span><button type="button" class="mute">Mute</button>';
    document.body.appendChild(el);
    el.querySelector('.mute').addEventListener('click', () => setMuted(!muted));
  }

  function setStatus(text, state = 'warn', show = true) {
    ensureUi();
    const el = document.getElementById('reaperlink-voice-status');
    if (!el) return;
    el.dataset.state = state;
    el.querySelector('.label').textContent = text;
    el.classList.toggle('show', show);
  }

  function setMuted(value) {
    muted = !!value;
    if (localStream) {
      for (const track of localStream.getAudioTracks()) track.enabled = !muted;
    }
    const el = document.getElementById('reaperlink-voice-status');
    const btn = el && el.querySelector('.mute');
    if (btn) btn.textContent = muted ? 'Unmute' : 'Mute';
    return muted;
  }

  function closePeer(peerId) {
    const pc = peers.get(peerId);
    if (pc) {
      try { pc.onicecandidate = null; pc.ontrack = null; pc.close(); } catch (_) {}
      peers.delete(peerId);
    }
    const audio = audios.get(peerId);
    if (audio) {
      try { audio.srcObject = null; audio.remove(); } catch (_) {}
      audios.delete(peerId);
    }
  }

  function closeAllPeers() {
    for (const peerId of Array.from(peers.keys())) closePeer(peerId);
  }

  async function sendSignal(peerId, payload) {
    if (!voiceId || stopping) return;
    const id = requestId();
    const encoded = encodeText(JSON.stringify(payload));
    const size = 3200;
    const total = Math.max(1, Math.ceil(encoded.length / size));

    for (let i = 0; i < total; i++) {
      const part = encoded.slice(i * size, (i + 1) * size) || 'e30';
      const r = await nativeFetch(
        `${base}/voice/chunk/${token}/${id}/${i + 1}/${total}/${part}`,
        { cache:'no-store', credentials:'omit' }
      );
      if (!r.ok) throw new Error('voice chunk ' + r.status);
    }

    const r = await nativeFetch(
      `${base}/voice/send/${token}/${id}/${encodeURIComponent(peerId)}`,
      { cache:'no-store', credentials:'omit' }
    );
    if (!r.ok) throw new Error('voice signal ' + r.status);
  }

  function peerConnection(peerId) {
    let pc = peers.get(peerId);
    if (pc) return pc;

    pc = new RTCPeerConnection({ iceServers: iceServers() });
    pc.__reaperPendingIce = [];
    peers.set(peerId, pc);

    if (localStream) {
      for (const track of localStream.getTracks()) pc.addTrack(track, localStream);
    }

    pc.onicecandidate = event => {
      if (!event.candidate) return;
      sendSignal(peerId, { type:'ice', candidate:event.candidate }).catch(() => {});
    };

    pc.ontrack = event => {
      let audio = audios.get(peerId);
      if (!audio) {
        audio = document.createElement('audio');
        audio.autoplay = true;
        audio.playsInline = true;
        audio.setAttribute('data-reaperlink-peer', peerId);
        audio.style.display = 'none';
        document.body.appendChild(audio);
        audios.set(peerId, audio);
      }
      audio.srcObject = event.streams[0] || new MediaStream([event.track]);
      audio.play().catch(() => {
        setStatus('Tap phone once to enable call audio', 'warn');
      });
    };

    pc.onconnectionstatechange = () => {
      const state = pc.connectionState;
      if (state === 'connected') {
        setStatus(muted ? 'ReaperLink Voice · muted' : 'ReaperLink Voice · live', 'live');
      } else if (state === 'failed' || state === 'closed') {
        closePeer(peerId);
      }
    };

    return pc;
  }

  async function makeOffer(peerId) {
    const pc = peerConnection(peerId);
    if (pc.signalingState !== 'stable') return;
    const offer = await pc.createOffer({ offerToReceiveAudio:true });
    await pc.setLocalDescription(offer);
    await sendSignal(peerId, { type:'description', description:pc.localDescription });
  }

  async function flushIce(pc) {
    const pending = Array.isArray(pc.__reaperPendingIce) ? pc.__reaperPendingIce.splice(0) : [];
    for (const candidate of pending) {
      try { await pc.addIceCandidate(candidate); } catch (_) {}
    }
  }

  async function handleSignal(peerId, data) {
    if (!data || typeof data !== 'object') return;
    const pc = peerConnection(peerId);

    if (data.type === 'description' && data.description) {
      const desc = data.description;
      if (desc.type === 'offer') {
        await pc.setRemoteDescription(desc);
        await flushIce(pc);
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        await sendSignal(peerId, { type:'description', description:pc.localDescription });
      } else if (desc.type === 'answer') {
        await pc.setRemoteDescription(desc);
        await flushIce(pc);
      }
      return;
    }

    if (data.type === 'ice' && data.candidate) {
      if (!pc.remoteDescription || !pc.remoteDescription.type) {
        pc.__reaperPendingIce.push(data.candidate);
      } else {
        try { await pc.addIceCandidate(data.candidate); } catch (_) {}
      }
    }
  }

  async function pollVoice() {
    if (polling || stopping || !voiceId) return;
    polling = true;
    try {
      while (!stopping && voiceId) {
        const r = await nativeFetch(
          `${base}/voice/events/${token}/${eventAfter}`,
          { cache:'no-store', credentials:'omit' }
        );
        if (!r.ok) throw new Error('voice events ' + r.status);
        const body = await r.json();
        const events = Array.isArray(body.events) ? body.events : [];

        for (const entry of events) {
          const seq = Number(entry && entry.seq) || 0;
          if (seq > eventAfter) eventAfter = seq;
          const event = entry && entry.event;
          if (!event) continue;

          if (event.type === 'peer-join' && event.peer) {
            const peerId = String(event.peer);
            if (voiceId < peerId) makeOffer(peerId).catch(() => {});
          } else if (event.type === 'peer-leave' && event.peer) {
            closePeer(String(event.peer));
          } else if (event.type === 'signal' && event.peer) {
            handleSignal(String(event.peer), event.data).catch(() => {});
          }
        }

        await new Promise(resolve => setTimeout(resolve, 140));
      }
    } catch (_) {
      if (!stopping && voiceId) {
        setStatus('ReaperLink Voice reconnecting…', 'warn');
        setTimeout(() => { polling = false; pollVoice(); }, 800);
        return;
      }
    }
    polling = false;
  }

  async function startVoice(callId) {
    callId = Number(callId);
    if (!callId || activeCallId === callId || stopping) return;

    await stopVoice(false);
    activeCallId = callId;
    stopping = false;

    if (!window.isSecureContext) {
      setStatus('Voice needs HTTPS for phone microphone', 'bad');
      return;
    }
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      setStatus('Phone browser does not provide microphone access', 'bad');
      return;
    }

    try {
      setStatus('Requesting phone microphone…', 'warn');
      localStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation:true,
          noiseSuppression:true,
          autoGainControl:true
        },
        video:false
      });
      setMuted(muted);

      const r = await nativeFetch(`${base}/voice/join/${token}`, {
        cache:'no-store', credentials:'omit'
      });
      if (!r.ok) throw new Error('join ' + r.status);
      const joined = await r.json();

      voiceId = String(joined.voiceId || '');
      eventAfter = Number(joined.seq) || 0;
      if (!voiceId) throw new Error('voice id');

      const list = Array.isArray(joined.peers) ? joined.peers.map(String) : [];
      for (const peerId of list) {
        if (voiceId < peerId) await makeOffer(peerId);
        else peerConnection(peerId);
      }

      setStatus(list.length ? 'Connecting ReaperLink Voice…' : 'ReaperLink Voice ready', 'live');
      pollVoice();
    } catch (err) {
      console.error('[ReaperLink Voice] start failed', err);
      setStatus('ReaperLink Voice unavailable', 'bad');
      await stopVoice(false);
      activeCallId = callId;
    }
  }

  async function stopVoice(hide = true) {
    stopping = true;
    const oldVoiceId = voiceId;
    voiceId = null;
    eventAfter = 0;
    closeAllPeers();

    if (localStream) {
      for (const track of localStream.getTracks()) {
        try { track.stop(); } catch (_) {}
      }
      localStream = null;
    }

    if (oldVoiceId) {
      nativeFetch(`${base}/voice/leave/${token}`, {
        cache:'no-store', credentials:'omit'
      }).catch(() => {});
    }

    activeCallId = null;
    stopping = false;
    if (hide) setStatus('', 'warn', false);
  }

  window.addEventListener('message', event => {
    const message = event && event.data;
    if (!message || typeof message !== 'object') return;
    if (message.action !== 'call') return;

    const call = message.call;
    if (call && call.state === 'active' && call.id) {
      startVoice(call.id).catch(() => {});
    } else {
      stopVoice(true).catch(() => {});
    }
  });

  window.addEventListener('pagehide', () => {
    stopVoice(true).catch(() => {});
  });

  window.ReaperLinkVoice = {
    start: startVoice,
    stop: stopVoice,
    setMuted,
    toggleMute: () => setMuted(!muted),
    state: () => ({
      callId:activeCallId,
      voiceId,
      muted,
      peers:peers.size,
      secure:window.isSecureContext
    })
  };
})();
