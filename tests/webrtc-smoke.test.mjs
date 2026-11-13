import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const context = vm.createContext({});
vm.runInContext(readFileSync(new URL('../src-tauri/examples/webrtc-smoke.js', import.meta.url), 'utf8'), context);
const { collectInboundMedia, mediaIsDecoded } = context;
const sinks = [
  { tagName: 'AUDIO', currentTime: 1 },
  { tagName: 'VIDEO', currentTime: 1, videoWidth: 160 },
];

function collect(reports) {
  return Array.from(collectInboundMedia(new Map(reports.map(report => [report.id, report]))));
}

test('requires positive inbound RTP bytes for both media kinds', () => {
  const media = collect([
    { id: 'a', type: 'inbound-rtp', kind: 'audio', bytesReceived: 256 },
    { id: 'v', type: 'inbound-rtp', kind: 'video', bytesReceived: 1024 },
  ]);
  assert.deepEqual(media, ['audio:256', 'video:1024']);
  assert.equal(mediaIsDecoded(media, sinks), true);
});

test('accepts mediaType or codec MIME when kind is absent', () => {
  assert.deepEqual(collect([
    { id: 'a', type: 'inbound-rtp', mediaType: 'audio', bytesReceived: 3 },
    { id: 'v', type: 'inbound-rtp', codecId: 'codec', bytesReceived: 4 },
    { id: 'codec', type: 'codec', mimeType: 'video/VP8' },
  ]), ['audio:3', 'video:4']);
});

test('outbound counters, missing counters and zero bytes cannot pass', () => {
  assert.deepEqual(collect([
    { id: 'a', type: 'outbound-rtp', kind: 'audio', bytesReceived: 9 },
    { id: 'v', type: 'inbound-rtp', kind: 'video', bytesReceived: 0 },
    { id: 'm', type: 'inbound-rtp', kind: 'audio', packetsReceived: 8 },
  ]), []);
});

test('one media kind cannot pass even when both sinks advance', () => {
  assert.equal(mediaIsDecoded(['audio:256'], sinks), false);
  assert.equal(mediaIsDecoded(['video:256'], sinks), false);
});

test('RTP cannot pass without decoded video dimensions and advancing sinks', () => {
  const media = ['audio:256', 'video:1024'];
  assert.equal(mediaIsDecoded(media, []), false);
  assert.equal(mediaIsDecoded(media, [sinks[0], { ...sinks[1], videoWidth: 0 }]), false);
  assert.equal(mediaIsDecoded(media, [{ ...sinks[0], currentTime: 0 }, sinks[1]]), false);
  assert.equal(mediaIsDecoded(media, [sinks[0], { ...sinks[1], currentTime: 0 }]), false);
});
