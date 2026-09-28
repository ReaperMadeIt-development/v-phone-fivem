/* ReaperLink Voice - FiveM/NUI mixed-mode endpoint
 *
 * Inert in the physical browser. It runs only in the normal FiveM NUI when a call has a
 * physical ReaperLink participant. That call temporarily uses WebRTC instead of the pma
 * call channel, while ordinary phone calls remain on the existing FiveM voice resource.
 */
(() => {
  'use strict';

  if (window.__VPHONE_PHYSICAL__) return;

  const resource = typeof window.GetParentResourceName === 'function'
    ? window.GetParentResourceName()
    : 'v-phone';

  let callId = null;
  let voiceId = null;
  let localStream = null;
  let starting = false;
  let stopped = true;
  let iceCfg = {};
  const peers = new Map();
  const audios = new Map();

  async function nui(name, data = {}) {
    const r = await fetch(`https://${resource}/${name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data)
    });
    if (!r.ok) throw new Error(`${name}: HTTP ${r.status}`);
    try { return await r.json(); } catch (_) { return {}; }
  }

  function report(error) {
    const text = String(error && (error.message || error) || 'unknown');
    console.error('[ReaperLink Voice]', text);
    nui('reaperVoiceGameError', { error: text }).catch(() => {});
  }

  function iceServers() {
    const servers = [];
    if (iceCfg && iceCfg.stun) servers.push({ urls: String(iceCfg.stun) });
    const turn = iceCfg && iceCfg.turn;
    if (turn && turn.url) {
      const item = { urls: String(turn.url) };
      if (turn.username) item.username = String(turn.username);
      if (turn.credential) item.credential = String(turn.credential);
      servers.push(item);
    }
    return servers;
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

  function closePeers() {
    for (const peerId of Array.from(peers.keys())) closePeer(peerId);
  }

  async function sendSignal(peerId, payload) {
    if (!voiceId || stopped) return;
    await nui('reaperVoiceGameSignal', { peer: peerId, data: payload });
  }

  function getPeer(peerId) {
    peerId = String(peerId);
    let pc = peers.get(peerId);
    if (pc) return pc;

    pc = new RTCPeerConnection({ iceServers: iceServers() });
    peers.set(peerId, pc);

    if (localStream) {
      for (const track of localStream.getTracks()) pc.addTrack(track, localStream);
    }

    pc.onicecandidate = event => {
      if (event.candidate) {
        sendSignal(peerId, { type: 'ice', candidate: event.candidate }).catch(report);
      }
    };

    pc.ontrack = event => {
      let audio = audios.get(peerId);
      if (!audio) {
        audio = document.createElement('audio');
        audio.autoplay = true;
        audio.playsInline = true;
        audio.style.display = 'none';
        audio.dataset.reaperlinkGamePeer = peerId;
        document.body.appendChild(audio);
        audios.set(peerId, audio);
      }
      audio.srcObject = event.streams[0] || new MediaStream([event.track]);
      audio.play().catch(report);
    };

    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'failed' || pc.connectionState === 'closed') {
        closePeer(peerId);
      }
    };

    return pc;
  }

  async function offer(peerId) {
    const pc = getPeer(peerId);
    if (pc.signalingState !== 'stable') return;
    const desc = await pc.createOffer({ offerToReceiveAudio: true });
    await pc.setLocalDescription(desc);
    await sendSignal(peerId, {
      type: 'description',
      description: pc.localDescription
    });
  }

  async function handleSignal(peerId, data) {
    if (!data || typeof data !== 'object') return;
    const pc = getPeer(peerId);

    if (data.type === 'description' && data.description) {
      const desc = data.description;
      if (desc.type === 'offer') {
        await pc.setRemoteDescription(desc);
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        await sendSignal(peerId, {
          type: 'description',
          description: pc.localDescription
        });
      } else if (desc.type === 'answer') {
        await pc.setRemoteDescription(desc);
      }
      return;
    }

    if (data.type === 'ice' && data.candidate) {
      try { await pc.addIceCandidate(data.candidate); } catch (_) {}
    }
  }

  async function start(nextCallId, nextIce) {
    nextCallId = Number(nextCallId);
    if (!nextCallId) return;
    if (callId === nextCallId && !stopped) return;

    await stop(false);
    callId = nextCallId;
    iceCfg = nextIce && typeof nextIce === 'object' ? nextIce : {};
    starting = true;
    stopped = false;

    try {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        throw new Error('FiveM NUI microphone capture is unavailable');
      }

      localStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true
        },
        video: false
      });

      const joined = await nui('reaperVoiceGameJoin', { callId });
      if (joined && joined.error) throw new Error(joined.error);
      starting = false;
    } catch (err) {
      starting = false;
      report(err);
      await stop(false);
    }
  }

  async function stop(notify = true) {
    const oldCall = callId;
    const hadVoice = !!voiceId;
    stopped = true;
    starting = false;
    voiceId = null;
    callId = null;
    closePeers();

    if (localStream) {
      for (const track of localStream.getTracks()) {
        try { track.stop(); } catch (_) {}
      }
      localStream = null;
    }

    if (notify && (oldCall || hadVoice)) {
      nui('reaperVoiceGameLeave', { callId: oldCall }).catch(() => {});
    }
  }

  async function handleEvent(event) {
    if (!event || typeof event !== 'object') return;

    if (event.type === 'ready') {
      if (Number(event.callId) !== Number(callId) || stopped) return;
      voiceId = String(event.voiceId || '');
      if (!voiceId) return;
      const list = Array.isArray(event.peers) ? event.peers.map(String) : [];
      for (const peerId of list) {
        if (voiceId < peerId) await offer(peerId);
        else getPeer(peerId);
      }
      return;
    }

    if (event.type === 'peer-join' && event.peer && voiceId && !stopped) {
      const peerId = String(event.peer);
      if (voiceId < peerId) await offer(peerId);
      else getPeer(peerId);
      return;
    }

    if (event.type === 'peer-leave' && event.peer) {
      closePeer(String(event.peer));
      return;
    }

    if (event.type === 'signal' && event.peer && voiceId && !stopped) {
      await handleSignal(String(event.peer), event.data);
      return;
    }

    if (event.type === 'error') {
      report(event.error || 'voice-room');
    }
  }

  window.addEventListener('message', event => {
    const message = event && event.data;
    if (!message || typeof message !== 'object') return;

    if (message.action === 'reaperlink:gameVoiceStart') {
      start(message.callId, message.ice).catch(report);
    } else if (message.action === 'reaperlink:gameVoiceStop') {
      stop(true).catch(() => {});
    } else if (message.action === 'reaperlink:gameVoiceEvent') {
      handleEvent(message.event).catch(report);
    }
  });

  window.addEventListener('beforeunload', () => {
    stop(true).catch(() => {});
  });

  window.ReaperLinkGameVoice = {
    state: () => ({
      callId,
      voiceId,
      peers: peers.size,
      starting,
      stopped,
      hasMic: !!localStream
    }),
    stop
  };
})();
