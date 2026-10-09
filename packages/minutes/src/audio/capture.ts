import { createWriteStream, type WriteStream } from 'node:fs';
import type { Page } from 'playwright-core';
import { MinutesError } from '../driver.js';

const CHUNK_BINDING = '__minutesAudioChunk__';

/**
 * Injected before the meeting page's own scripts. It hooks `RTCPeerConnection` track events, mixes
 * every remote audio track into one `MediaStreamDestination`, and records it with `MediaRecorder`
 * (WebM/Opus when available) in 4-second slices sent to Node as base64.
 *
 * A silent source keeps the timeline continuous. Only the top-level document records, so a page with several frames still produces one WebM stream.
 * `window.__minutesCapture__.stop()` stops the recorder and resolves after the final slice reached Node.
 */
export const CAPTURE_INIT_SCRIPT = `
(function () {
  if (window.top !== window || window.__minutesCapture__) return;
  const ctx = new AudioContext({ sampleRate: 48000 });
  const destination = ctx.createMediaStreamDestination();
  const seen = new Set();
  // A silent source keeps the recording's timeline running from the start, so the file is valid
  // and aligned to meeting time even before (or without) any remote audio.
  const silence = ctx.createConstantSource();
  silence.offset.value = 0;
  silence.connect(destination);
  silence.start();

  function connect(track, streams) {
    const stream = (streams && streams[0]) || new MediaStream([track]);
    if (seen.has(stream.id)) return;
    seen.add(stream.id);
    try {
      ctx.createMediaStreamSource(stream).connect(destination);
      if (ctx.state === 'suspended') ctx.resume().catch(function () {});
    } catch (error) {
      console.warn('[minutes] could not connect an audio stream', error);
    }
  }

  const originalAdd = EventTarget.prototype.addEventListener;
  EventTarget.prototype.addEventListener = function (type, listener, options) {
    if (type === 'track' && this instanceof RTCPeerConnection && listener) {
      const wrapped = function (event) {
        if (event.track && event.track.kind === 'audio') connect(event.track, event.streams);
        return typeof listener === 'function' ? listener.apply(this, arguments) : listener.handleEvent(event);
      };
      return originalAdd.call(this, type, wrapped, options);
    }
    return originalAdd.call(this, type, listener, options);
  };

  const ontrack = Object.getOwnPropertyDescriptor(RTCPeerConnection.prototype, 'ontrack');
  if (ontrack && ontrack.set) {
    Object.defineProperty(RTCPeerConnection.prototype, 'ontrack', {
      configurable: true,
      get: function () { return ontrack.get ? ontrack.get.call(this) : undefined; },
      set: function (handler) {
        const wrapped = function (event) {
          if (event.track && event.track.kind === 'audio') connect(event.track, event.streams);
          return handler && handler.apply(this, arguments);
        };
        ontrack.set.call(this, handler ? wrapped : handler);
      },
    });
  }

  function toBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    let binary = '';
    for (let i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(binary);
  }

  const mimeType = ['audio/webm;codecs=opus', 'audio/webm'].find(function (type) { return MediaRecorder.isTypeSupported(type); }) || '';
  const recorder = new MediaRecorder(destination.stream, mimeType ? { mimeType: mimeType } : {});
  let pending = Promise.resolve();
  recorder.ondataavailable = function (event) {
    if (!event.data || event.data.size === 0) return;
    const blob = event.data;
    pending = pending
      .then(function () { return blob.arrayBuffer(); })
      .then(function (buffer) { return window.${CHUNK_BINDING}(toBase64(buffer)); })
      .catch(function () {});
  };
  window.__minutesCapture__ = {
    // Called by Node once the bot is in the meeting, so pages loaded during the join flow never
    // start a recorder of their own and the file holds exactly one WebM stream.
    start: function () {
      if (recorder.state === 'inactive') recorder.start(4000);
      if (ctx.state === 'suspended') ctx.resume().catch(function () {});
      return true;
    },
    stop: function () {
      return new Promise(function (resolve) {
        if (recorder.state === 'inactive') { pending.then(function () { resolve(true); }); return; }
        recorder.addEventListener('stop', function () { pending.then(function () { resolve(true); }); }, { once: true });
        recorder.stop();
      });
    },
  };
})();
`;

export interface AudioCapture {
  /** Starts the recorder in the current document (the meeting page). Call after the join. */
  begin(): Promise<void>;
  /** Stops recording, waits for the last slice, closes the file, and returns its size in bytes. */
  stop(): Promise<number>;
}

/** Installs the capture script and the chunk binding on `page`. Call before navigating. */
export async function installAudioCapture(page: Page, outputPath: string): Promise<AudioCapture> {
  let stream: WriteStream;
  try {
    stream = createWriteStream(outputPath, { flags: 'wx', mode: 0o600 });
    await new Promise<void>((resolve, reject) => {
      stream.once('open', () => resolve());
      stream.once('error', reject);
    });
  } catch (error) {
    throw new MinutesError('output_unwritable', `Cannot create ${outputPath}: ${(error as Error).message}`);
  }

  let bytes = 0;
  let writeError: Error | null = null;
  stream.on('error', (error) => { writeError = error; });

  await page.exposeFunction(CHUNK_BINDING, (base64: unknown) => {
    if (typeof base64 !== 'string' || stream.writableEnded) return;
    const chunk = Buffer.from(base64, 'base64');
    bytes += chunk.length;
    stream.write(chunk);
  });
  await page.addInitScript(CAPTURE_INIT_SCRIPT);

  let stopped: Promise<number> | null = null;
  return {
    async begin() {
      const started = await page.evaluate('window.__minutesCapture__ ? window.__minutesCapture__.start() : false');
      if (started !== true) throw new MinutesError('capture_failed', 'Audio capture is not available on the meeting page.');
    },
    stop() {
      stopped ??= (async () => {
        if (!page.isClosed()) {
          await Promise.race([
            page.evaluate('window.__minutesCapture__ ? window.__minutesCapture__.stop() : false').catch(() => false),
            new Promise((resolve) => setTimeout(resolve, 10_000).unref()),
          ]);
        }
        await new Promise<void>((resolve) => stream.end(() => resolve()));
        if (writeError) throw new MinutesError('capture_failed', `Writing the recording failed: ${(writeError as Error).message}`);
        return bytes;
      })();
      return stopped;
    },
  };
}
