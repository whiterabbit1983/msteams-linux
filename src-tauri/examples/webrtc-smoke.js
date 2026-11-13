// Pure checks are also tested in Node without starting GTK or media devices.
function collectInboundMedia(stats) {
  const media = [];
  stats.forEach(report => {
    if (report.type !== 'inbound-rtp' || !(report.bytesReceived > 0)) return;
    const codec = stats.get(report.codecId);
    const kind = report.kind || report.mediaType ||
      (codec && codec.mimeType || '').split('/')[0].toLowerCase();
    if (kind === 'audio' || kind === 'video') media.push(kind + ':' + report.bytesReceived);
  });
  return media;
}

function mediaIsDecoded(media, sinks) {
  const audio = sinks.find(sink => sink.tagName === 'AUDIO');
  const video = sinks.find(sink => sink.tagName === 'VIDEO');
  return media.some(value => value.startsWith('audio:')) &&
    media.some(value => value.startsWith('video:')) &&
    !!audio && !!video && audio.currentTime > 0 && video.currentTime > 0 && video.videoWidth > 0;
}

function withTimeout(promise, label, milliseconds = 5000) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Timed out: ' + label)), milliseconds);
    })
  ]).finally(() => clearTimeout(timer));
}

function startPlayback(sink, reportError) {
  // play() may remain pending until RTP arrives. Never block the RTP checks on it.
  try {
    Promise.resolve(sink.play()).catch(reportError);
  } catch (error) {
    reportError(error);
  }
}

// The guard permits unit tests of the checks without executing the media test.
if (typeof document !== 'undefined') {
  (async () => {
    let stream;
    let first;
    let second;
    let syntheticAudio;
    let oscillator;
    let frameTimer;
    let candidateError;
    let playbackError;
    const step = async (label, promise) => {
      console.log('WebRTC step: ' + label);
      const result = await withTimeout(promise, label);
      console.log('WebRTC done: ' + label);
      return result;
    };
    try {
      if (typeof RTCPeerConnection !== 'function') throw new Error('RTCPeerConnection unavailable');
      const videoCodecs = RTCRtpSender.getCapabilities('video').codecs;
      if (!videoCodecs.some(codec => codec.mimeType.toLowerCase() === 'video/h264')) {
        throw new Error('H.264 unavailable: ' + JSON.stringify(videoCodecs));
      }
      if (new URLSearchParams(location.search).has('synthetic')) {
        const canvas = document.createElement('canvas');
        canvas.width = 160;
        canvas.height = 120;
        document.body.appendChild(canvas);
        const context = canvas.getContext('2d');
        let frame = 0;
        frameTimer = setInterval(() => {
          context.fillStyle = frame++ % 2 ? '#146eb4' : '#d83b01';
          context.fillRect(0, 0, canvas.width, canvas.height);
        }, 50);
        syntheticAudio = new AudioContext();
        await step('AudioContext.resume', syntheticAudio.resume());
        oscillator = syntheticAudio.createOscillator();
        const destination = syntheticAudio.createMediaStreamDestination();
        oscillator.connect(destination);
        oscillator.start();
        stream = new MediaStream([
          ...canvas.captureStream(10).getVideoTracks(),
          ...destination.stream.getAudioTracks()
        ]);
      } else {
        stream = await navigator.mediaDevices.getUserMedia({audio: true, video: true});
      }
      first = new RTCPeerConnection();
      second = new RTCPeerConnection();
      for (const track of stream.getTracks()) first.addTrack(track, stream);
      const firstCandidates = [];
      const secondCandidates = [];
      const sinks = [];
      const reportCandidateError = error => { candidateError = String(error); };
      first.onicecandidate = event => {
        if (!event.candidate) return;
        if (second.remoteDescription) second.addIceCandidate(event.candidate).catch(reportCandidateError);
        else firstCandidates.push(event.candidate);
      };
      second.onicecandidate = event => {
        if (!event.candidate) return;
        if (first.remoteDescription) first.addIceCandidate(event.candidate).catch(reportCandidateError);
        else secondCandidates.push(event.candidate);
      };
      second.ontrack = event => {
        const sink = document.createElement(event.track.kind === 'audio' ? 'audio' : 'video');
        sink.muted = true;
        sink.playsInline = true;
        sink.srcObject = new MediaStream([event.track]);
        document.body.appendChild(sink);
        sinks.push(sink);
        console.log('WebRTC received track: ' + event.track.kind);
        startPlayback(sink, error => { playbackError = String(error); });
      };
      const offer = await step('createOffer', first.createOffer());
      await step('sender.setLocalDescription', first.setLocalDescription(offer));
      await step('receiver.setRemoteDescription', second.setRemoteDescription(offer));
      const answer = await step('createAnswer', second.createAnswer());
      await step('receiver.setLocalDescription', second.setLocalDescription(answer));
      await step('sender.setRemoteDescription', first.setRemoteDescription(answer));
      for (const candidate of firstCandidates) await withTimeout(second.addIceCandidate(candidate), 'receiver.addIceCandidate');
      for (const candidate of secondCandidates) await withTimeout(first.addIceCandidate(candidate), 'sender.addIceCandidate');
      const iceDeadline = Date.now() + 20000;
      while (!['connected', 'completed'].includes(first.iceConnectionState) && Date.now() < iceDeadline) {
        if (candidateError) throw new Error('ICE candidate: ' + candidateError);
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      if (!['connected', 'completed'].includes(first.iceConnectionState)) {
        throw new Error('ICE did not connect: ' + first.iceConnectionState);
      }
      console.log('WebRTC ICE connected: ' + JSON.stringify({
        ice: [first.iceConnectionState, second.iceConnectionState],
        audioContext: syntheticAudio && syntheticAudio.state,
        tracks: stream.getTracks().map(track => ({kind: track.kind, state: track.readyState, muted: track.muted})),
        transceivers: first.getTransceivers().map(transceiver => ({direction: transceiver.direction, current: transceiver.currentDirection})),
        sinks: sinks.map(sink => ({tag: sink.tagName, time: sink.currentTime, ready: sink.readyState}))
      }));
      // ICE connectivity does not imply that RTP or the decoders have started.
      // Poll both conditions instead of sampling stats only once after 1.5 s.
      const mediaDeadline = Date.now() + 20000;
      let media = [];
      let stats;
      do {
        if (candidateError) throw new Error('ICE candidate: ' + candidateError);
        if (playbackError) throw new Error('Playback failed: ' + playbackError);
        stats = await withTimeout(second.getStats(), 'receiver.getStats');
        media = collectInboundMedia(stats);
        if (mediaIsDecoded(media, sinks)) break;
        await new Promise(resolve => setTimeout(resolve, 250));
      } while (Date.now() < mediaDeadline);
      if (!mediaIsDecoded(media, sinks)) {
        const inbound = [];
        stats.forEach(report => {
          if (report.type === 'inbound-rtp' || report.type === 'codec') inbound.push(report);
        });
        const outbound = [];
        (await withTimeout(first.getStats(), 'sender.getStats')).forEach(report => {
          if (report.type === 'outbound-rtp') outbound.push(report);
        });
        throw new Error('Media did not start: ' + JSON.stringify({
          ice: [first.iceConnectionState, second.iceConnectionState],
          connection: [first.connectionState, second.connectionState],
          audioContext: syntheticAudio && syntheticAudio.state,
          tracks: stream.getTracks().map(track => ({kind: track.kind, state: track.readyState, muted: track.muted})),
          sinks: sinks.map(sink => ({tag: sink.tagName, time: sink.currentTime, width: sink.videoWidth, ready: sink.readyState})),
          inbound, outbound, media
        }));
      }
      const video = sinks.find(sink => sink.tagName === 'VIDEO');
      document.title = 'PASS ' + JSON.stringify({ice: first.iceConnectionState, media, width: video.videoWidth});
    } catch (error) {
      document.title = 'ERROR ' + (error && error.message || error) + '\n' + (error && error.stack || '');
    } finally {
      if (frameTimer) clearInterval(frameTimer);
      if (oscillator) oscillator.stop();
      if (stream) stream.getTracks().forEach(track => track.stop());
      if (first) first.close();
      if (second) second.close();
      if (syntheticAudio) await syntheticAudio.close();
    }
  })();
}
undefined;
