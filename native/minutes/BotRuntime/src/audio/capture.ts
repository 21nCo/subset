import fs from 'node:fs';
import path from 'node:path';
import type { Page } from 'playwright-core';
import { recording, status } from '../status.js';

/**
 * Injected into the browser page before navigation. Hooks RTCPeerConnection
 * to intercept incoming audio tracks from all remote participants, pipes them
 * through a shared AudioContext, and records with MediaRecorder.
 *
 * Chunks are sent back to Node.js via window.__audioChunk__ (exposed function).
 */
const CAPTURE_INIT_SCRIPT = `
(function() {
  if (window.__meetingCaptureInit__) return;
  window.__meetingCaptureInit__ = true;

  const _ctx = new AudioContext({ sampleRate: 48000 });
  const _dest = _ctx.createMediaStreamDestination();
  const _seenStreams = new Set();

  function connectAudioTrack(track, streams) {
    const stream = (streams && streams[0]) || new MediaStream([track]);
    if (_seenStreams.has(stream.id)) return;
    _seenStreams.add(stream.id);
    try {
      const src = _ctx.createMediaStreamSource(stream);
      src.connect(_dest);
      console.log('[meeting-bot] Connected audio stream', stream.id);
    } catch (e) {
      console.warn('[meeting-bot] Failed to connect audio stream:', e);
    }
  }

  // Patch addEventListener to intercept RTCPeerConnection 'track' events.
  const _origAEL = EventTarget.prototype.addEventListener;
  EventTarget.prototype.addEventListener = function(type, listener, opts) {
    if (type === 'track' && this instanceof RTCPeerConnection) {
      const wrapped = function(event) {
        if (event.track && event.track.kind === 'audio') {
          connectAudioTrack(event.track, event.streams);
        }
        return listener.apply(this, arguments);
      };
      return _origAEL.call(this, type, wrapped, opts);
    }
    return _origAEL.call(this, type, listener, opts);
  };

  // Also patch ontrack setter for code that assigns directly.
  const _origOntrack = Object.getOwnPropertyDescriptor(RTCPeerConnection.prototype, 'ontrack');
  if (_origOntrack) {
    Object.defineProperty(RTCPeerConnection.prototype, 'ontrack', {
      set(handler) {
        const wrapped = function(event) {
          if (event.track && event.track.kind === 'audio') {
            connectAudioTrack(event.track, event.streams);
          }
          return handler && handler.apply(this, arguments);
        };
        _origOntrack.set && _origOntrack.set.call(this, wrapped);
      },
      get() {
        return _origOntrack.get && _origOntrack.get.call(this);
      },
      configurable: true,
    });
  }

  // Start MediaRecorder — chunks sent every 4 s.
  const mimeType = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg'].find(
    (m) => MediaRecorder.isTypeSupported(m)
  ) || '';

  const _recorder = new MediaRecorder(_dest.stream, mimeType ? { mimeType } : {});
  _recorder.ondataavailable = function(e) {
    if (!e.data || e.data.size === 0) return;
    e.data.arrayBuffer().then(function(buf) {
      window.__audioChunk__(Array.from(new Uint8Array(buf)));
    }).catch(() => {});
  };
  _recorder.onerror = function(e) {
    console.error('[meeting-bot] MediaRecorder error', e);
  };
  _recorder.start(4000);
  window.__meetingRecorder__ = _recorder;
  console.log('[meeting-bot] Audio capture ready, mimeType:', mimeType || '(default)');
})();
`;

export async function setupAudioCapture(
  page: Page,
  recordingDir: string,
  meetingUrl: string
): Promise<{ stop: () => void; outputPath: string }> {
  await fs.promises.mkdir(recordingDir, { recursive: true });

  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const safeName = new URL(meetingUrl).hostname.replace(/\./g, '_');
  const outputPath = path.join(recordingDir, `recording_${safeName}_${timestamp}.webm`);
  const fileStream = fs.createWriteStream(outputPath, { flags: 'a' });

  // Inject the capture script before page scripts run.
  await page.addInitScript(CAPTURE_INIT_SCRIPT);

  // Expose the chunk callback.
  await page.exposeFunction('__audioChunk__', (chunk: number[]) => {
    fileStream.write(Buffer.from(chunk));
  });

  recording(outputPath);
  status(`Audio capture → ${outputPath}`);

  return {
    stop() {
      fileStream.end();
      page
        .evaluate('window.__meetingRecorder__ && window.__meetingRecorder__.stop()')
        .catch(() => {});
    },
    outputPath,
  };
}
