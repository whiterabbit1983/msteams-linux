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
        await syntheticAudio.resume();
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
      const playbacks = [];
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
        sink.srcObject = event.streams[0];
        document.body.appendChild(sink);
        sinks.push(sink);
        playbacks.push(sink.play());
      };
      const offer = await first.createOffer();
      await first.setLocalDescription(offer);
      await second.setRemoteDescription(offer);
      const answer = await second.createAnswer();
      await second.setLocalDescription(answer);
      await first.setRemoteDescription(answer);
      for (const candidate of firstCandidates) await second.addIceCandidate(candidate);
      for (const candidate of secondCandidates) await first.addIceCandidate(candidate);
      const iceDeadline = Date.now() + 20000;
      while (!['connected', 'completed'].includes(first.iceConnectionState) && Date.now() < iceDeadline) {
        if (candidateError) throw new Error('ICE candidate: ' + candidateError);
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      if (!['connected', 'completed'].includes(first.iceConnectionState)) {
        throw new Error('ICE did not connect: ' + first.iceConnectionState);
      }
      await Promise.all(playbacks);
      // ICE connectivity does not imply that RTP or the decoders have started.
      // Poll both conditions instead of sampling stats only once after 1.5 s.
      const mediaDeadline = Date.now() + 20000;
      let media = [];
      let stats;
      do {
        if (candidateError) throw new Error('ICE candidate: ' + candidateError);
        stats = await second.getStats();
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
        (await first.getStats()).forEach(report => {
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
