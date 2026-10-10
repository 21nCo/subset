import { createWriteStream, type WriteStream } from 'node:fs';
import { rm } from 'node:fs/promises';
import type { Page } from 'playwright-core';
import { MinutesError } from '../driver.js';

const CHUNK_BINDING = '__minutesAudioChunk__';

/**
 * Injected before the meeting page's own scripts. It hooks `RTCPeerConnection` track events, mixes
 * every remote audio track into one `MediaStreamDestination`, and records it with `MediaRecorder`
 * (WebM/Opus when available) in 4-second slices sent to Node as base64.
 *
 * A silent source keeps the timeline continuous. Only the top-level document records, so a page with several frames still produces one WebM stream.
 * `window.__minutesCapture__.stop()` stops the recorder and resolves after the final slice reached Node:
 * true when every slice was delivered, false when one was lost.
 */
export const CAPTURE_INIT_SCRIPT = `
(function () {
  if (window.top !== window || window.__minutesCapture__) return;
  const ctx = new AudioContext({ sampleRate: 48000 });
  const destination = ctx.createMediaStreamDestination();
  // One source per remote audio track (a stream can carry several), deduplicated by track id.
  const seen = new Set();
  // A silent source keeps the recording's timeline running from the start, so the file is valid
  // and aligned to meeting time even before (or without) any remote audio.
  const silence = ctx.createConstantSource();
  silence.offset.value = 0;
  silence.connect(destination);
  silence.start();

  function connect(track) {
    if (seen.has(track.id)) return;
    seen.add(track.id);
    try {
      ctx.createMediaStreamSource(new MediaStream([track])).connect(destination);
      if (ctx.state === 'suspended') ctx.resume().catch(function () {});
    } catch (error) {
      console.warn('[minutes] could not connect an audio stream', error);
    }
  }

  // One wrapper per listener, so adding the same listener twice is still deduplicated by the browser and
  // removeEventListener with the page's original listener still removes it.
  const wrappers = new WeakMap();
  const isTrackListener = function (target, type, listener) {
    return type === 'track' && target instanceof RTCPeerConnection && listener && (typeof listener === 'function' || typeof listener === 'object');
  };
  const originalAdd = EventTarget.prototype.addEventListener;
  const originalRemove = EventTarget.prototype.removeEventListener;
  EventTarget.prototype.addEventListener = function (type, listener, options) {
    if (isTrackListener(this, type, listener)) {
      let wrapped = wrappers.get(listener);
      if (!wrapped) {
        wrapped = function (event) {
          if (event.track && event.track.kind === 'audio') connect(event.track);
          return typeof listener === 'function' ? listener.apply(this, arguments) : listener.handleEvent(event);
        };
        wrappers.set(listener, wrapped);
      }
      return originalAdd.call(this, type, wrapped, options);
    }
    return originalAdd.call(this, type, listener, options);
  };
  EventTarget.prototype.removeEventListener = function (type, listener, options) {
    if (isTrackListener(this, type, listener) && wrappers.has(listener)) {
      return originalRemove.call(this, type, wrappers.get(listener), options);
    }
    return originalRemove.call(this, type, listener, options);
  };

  const ontrack = Object.getOwnPropertyDescriptor(RTCPeerConnection.prototype, 'ontrack');
  if (ontrack && ontrack.set) {
    Object.defineProperty(RTCPeerConnection.prototype, 'ontrack', {
      configurable: true,
      get: function () { return ontrack.get ? ontrack.get.call(this) : undefined; },
      set: function (handler) {
        const wrapped = function (event) {
          if (event.track && event.track.kind === 'audio') connect(event.track);
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
  let lostSlice = false;
  recorder.ondataavailable = function (event) {
    if (!event.data || event.data.size === 0) return;
    const blob = event.data;
    pending = pending
      .then(function () { return blob.arrayBuffer(); })
      .then(function (buffer) { return window.${CHUNK_BINDING}(toBase64(buffer)); })
      .catch(function (error) {
        lostSlice = true;
        console.warn('[minutes] an audio slice was not delivered', error);
      });
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
        const done = function () { pending.then(function () { resolve(!lostSlice); }); };
        if (recorder.state === 'inactive') { done(); return; }
        recorder.addEventListener('stop', done, { once: true });
        recorder.stop();
      });
    },
  };
})();
`;

export interface AudioCapture {
  /** Starts the recorder in the current document (the meeting page). Call after the join. */
  begin(): Promise<void>;
  /**
   * Stops recording, waits for the last slice, closes the file, and returns its size in bytes. Throws
   * `capture_failed` (after closing the file) when a write failed or audio slices were not delivered.
   */
  stop(): Promise<number>;
}

/** Installs the capture script and the chunk binding on `page`. Call before navigating. */
export async function installAudioCapture(page: Page, outputPath: string): Promise<AudioCapture> {
  let stream: WriteStream;
  try {
    // The session reserved this (empty) file; take it over.
    stream = createWriteStream(outputPath, { flags: 'w', mode: 0o600 });
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

  let lateSlices = 0;
  try {
    await page.exposeFunction(CHUNK_BINDING, (base64: unknown) => {
      if (typeof base64 !== 'string') return;
      if (stream.writableEnded) { lateSlices += 1; return; }
      const chunk = Buffer.from(base64, 'base64');
      bytes += chunk.length;
      stream.write(chunk);
    });
    await page.addInitScript(CAPTURE_INIT_SCRIPT);
  } catch (error) {
    // Leave no empty file and no open stream behind.
    await new Promise<void>((resolve) => stream.end(() => resolve()));
    await rm(outputPath, { force: true }).catch(() => {});
    throw new MinutesError('capture_failed', `Could not install audio capture: ${(error as Error).message}`);
  }

  let stopped: Promise<number> | null = null;
  let begun = false;
  return {
    async begin() {
      const started = await page.evaluate('window.__minutesCapture__ ? window.__minutesCapture__.start() : false');
      if (started !== true) throw new MinutesError('capture_failed', 'Audio capture is not available on the meeting page.');
      begun = true;
    },
    stop() {
      stopped ??= (async () => {
        // Nothing to flush when recording never began, or the page already closed (the meeting ended).
        let flushed = true;
        if (begun && !page.isClosed()) {
          const result = await Promise.race([
            page.evaluate('window.__minutesCapture__ ? window.__minutesCapture__.stop() : false').catch(() => 'error'),
            new Promise((resolve) => setTimeout(() => resolve('timeout'), 10_000).unref()),
          ]);
          flushed = result === true || page.isClosed();
        }
        await new Promise<void>((resolve) => stream.end(() => resolve()));
        if (writeError) throw new MinutesError('capture_failed', `Writing the recording failed: ${(writeError as Error).message}`);
        if (!flushed || lateSlices > 0) {
          throw new MinutesError('capture_failed', 'The recorder did not hand over all of its audio, so the end of the recording may be missing.');
        }
        return bytes;
      })();
      return stopped;
    },
  };
}
