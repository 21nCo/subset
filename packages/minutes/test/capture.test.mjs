import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { installAudioCapture } from '../dist/audio/capture.js';

/** A page stand-in: records the exposed bindings and answers the two evaluate calls the capture makes. */
function fakePage() {
  const bindings = new Map();
  const page = {
    bindings,
    closed: false,
    exposeFunction: async (name, fn) => { bindings.set(name, fn); },
    addInitScript: async () => {},
    evaluate: async (expression) => expression.includes('.start()') || expression.includes('.stop()'),
    isClosed: () => page.closed,
  };
  return page;
}

/** A begun capture with one remote track and one delivered slice. */
async function begunCapture(page, outputPath) {
  const capture = await installAudioCapture(page, outputPath);
  await capture.begin();
  await page.bindings.get('__minutesAudioTrack__')();
  await page.bindings.get('__minutesAudioChunk__')(Buffer.from('audio').toString('base64'));
  return capture;
}

async function setup(t) {
  const directory = await mkdtemp(path.join(tmpdir(), 'minutes-capture-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const outputPath = path.join(directory, 'recording.webm');
  await writeFile(outputPath, '');
  return outputPath;
}

test('a recording with no remote audio track fails as capture_failed and keeps the file', async (t) => {
  const outputPath = await setup(t);
  const page = fakePage();
  const capture = await installAudioCapture(page, outputPath);
  await capture.begin();
  await page.bindings.get('__minutesAudioChunk__')(Buffer.from('silence').toString('base64'));
  await assert.rejects(capture.stop(), (error) => error.code === 'capture_failed' && /No participant audio/.test(error.message));
  assert.equal(await readFile(outputPath, 'utf8'), 'silence');
});

test('a recording with a connected remote track returns its size', async (t) => {
  const outputPath = await setup(t);
  const page = fakePage();
  const capture = await installAudioCapture(page, outputPath);
  await capture.begin();
  await page.bindings.get('__minutesAudioTrack__')();
  await page.bindings.get('__minutesAudioChunk__')(Buffer.from('audio').toString('base64'));
  assert.equal(await capture.stop(), 5);
});

test('a page that closed before stop is an incomplete recording, not a success', async (t) => {
  const outputPath = await setup(t);
  const page = fakePage();
  const capture = await begunCapture(page, outputPath);
  page.closed = true;
  await assert.rejects(capture.stop(), (error) => error.code === 'capture_failed' && /did not hand over/.test(error.message));
  assert.equal(await readFile(outputPath, 'utf8'), 'audio');
});

test('a page that closes while stop is pending is an incomplete recording', async (t) => {
  const outputPath = await setup(t);
  const page = fakePage();
  const capture = await begunCapture(page, outputPath);
  page.evaluate = async () => { page.closed = true; throw new Error('Target page, context or browser has been closed'); };
  await assert.rejects(capture.stop(), (error) => error.code === 'capture_failed');
});
