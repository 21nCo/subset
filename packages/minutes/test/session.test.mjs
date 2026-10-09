import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import {
  MinutesError,
  canTransition,
  isMinutesEvent,
  isSessionRecord,
  parseMeetingLink,
  readStatus,
  recordingFileName,
  resolveRecordingPath,
  runMeetingSession,
  sessionStates,
  transition,
  writeSessionRecord,
} from '../dist/index.js';

test('allows only the documented state transitions', () => {
  const allowed = new Set([
    'launching>joining', 'launching>stopping', 'launching>failed',
    'joining>in_meeting', 'joining>stopping', 'joining>failed',
    'in_meeting>stopping', 'in_meeting>failed',
    'stopping>ended', 'stopping>failed',
  ]);
  for (const from of sessionStates) {
    for (const to of sessionStates) {
      assert.equal(canTransition(from, to), allowed.has(`${from}>${to}`), `${from}>${to}`);
    }
  }
  assert.equal(transition('launching', 'joining'), 'joining');
  assert.throws(() => transition('ended', 'launching'), /Invalid Minutes session transition/);
});

test('names recordings by platform and UTC time without the meeting code', async () => {
  const startedAt = new Date('2026-10-09T10:15:30.123Z');
  assert.equal(recordingFileName('zoom', startedAt), 'minutes-zoom-2026-10-09T10-15-30Z.webm');
  assert.equal(recordingFileName('google-meet', startedAt, 1), 'minutes-google-meet-2026-10-09T10-15-30Z-2.webm');
  const taken = new Set(['/out/minutes-zoom-2026-10-09T10-15-30Z.webm']);
  assert.equal(await resolveRecordingPath('/out', 'zoom', startedAt, async (file) => taken.has(file)), '/out/minutes-zoom-2026-10-09T10-15-30Z-2.webm');
});

/** A driver that never starts a browser. `script` controls how each step behaves. */
function fakeDriver(script = {}) {
  const calls = [];
  return {
    calls,
    async open({ platform, log }) {
      calls.push(`open:${platform}`);
      log('fake chrome');
      if (script.openError) throw script.openError;
      return {
        async startCapture(file) { calls.push('startCapture'); await writeFile(file, 'webm'); },
        async join(link, name) {
          calls.push(`join:${name}`);
          if (script.joinError) throw script.joinError;
          if (script.joinHangs) await new Promise(() => {});
        },
        async waitForEnd(signal) {
          calls.push('waitForEnd');
          if (script.end) return script.end;
          if (signal.aborted) return 'aborted';
          return new Promise((resolve) => signal.addEventListener('abort', () => resolve('aborted'), { once: true }));
        },
        async stopCapture() { calls.push('stopCapture'); return 4; },
        async leave() { calls.push('leave'); },
        async close() { calls.push('close'); },
      };
    },
  };
}

async function run(t, script, extra = {}) {
  const root = await mkdtemp(path.join(tmpdir(), 'minutes-session-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const events = [];
  const records = [];
  const driver = fakeDriver(script);
  const link = parseMeetingLink('https://zoom.us/j/1234567890?pwd=secret').link;
  const result = await runMeetingSession({
    link, displayName: '  ', outputDirectory: path.join(root, 'out'), profileDirectory: path.join(root, 'profile'),
    driver, emit: (event) => events.push(event), persist: (record) => { records.push(record); return writeSessionRecord(path.join(root, 'state'), record); },
    sessionId: '20261009T100000Z-abc123', ...extra,
  });
  return { root, events, records, driver, result };
}

const states = (events) => events.filter((event) => event.type === 'state').map((event) => event.state);

test('a meeting that ends on its own finalizes the recording', async (t) => {
  const { root, events, records, driver, result } = await run(t, { end: 'meeting_ended' });
  for (const event of events) assert.equal(isMinutesEvent(event), true, JSON.stringify(event));
  assert.deepEqual(states(events), ['launching', 'joining', 'in_meeting', 'stopping', 'ended']);
  assert.equal(events[0].type, 'started');
  assert.equal(events[0].displayName, 'Minutes Notetaker');
  assert.equal(JSON.stringify(events).includes('secret'), false, 'the Zoom passcode must not appear in events');
  const last = events.at(-1);
  assert.deepEqual([last.type, last.reason, last.bytes], ['ended', 'meeting_ended', 4]);
  assert.match(last.path, /minutes-zoom-.*\.webm$/);
  assert.deepEqual(result, { id: '20261009T100000Z-abc123', state: 'ended', reason: 'meeting_ended', path: last.path, bytes: 4, error: null });
  assert.deepEqual(driver.calls, ['open:zoom', 'startCapture', 'join:Minutes Notetaker', 'waitForEnd', 'stopCapture', 'close']);
  assert.ok(records.every(isSessionRecord));

  const status = await readStatus(path.join(root, 'state'));
  assert.equal(status.sessions.length, 1);
  assert.equal(status.sessions[0].state, 'ended');
  assert.equal(status.sessions[0].endReason, 'meeting_ended');
  assert.equal(status.sessions[0].alive, false);
  assert.equal(JSON.stringify(status).includes('secret'), false);
  const file = JSON.parse(await readFile(path.join(root, 'state', '20261009T100000Z-abc123.json'), 'utf8'));
  assert.equal(file.state, 'ended');
});

test('a stop request in the meeting leaves and ends with reason stopped', async (t) => {
  const controller = new AbortController();
  const pending = run(t, {}, { signal: controller.signal });
  setTimeout(() => controller.abort(), 20);
  const { events, driver, result } = await pending;
  assert.deepEqual(states(events), ['launching', 'joining', 'in_meeting', 'stopping', 'ended']);
  assert.equal(result.reason, 'stopped');
  assert.deepEqual(driver.calls.slice(-3), ['stopCapture', 'leave', 'close']);
});

test('a stop request while joining still finalizes the file', async (t) => {
  const controller = new AbortController();
  const pending = run(t, { joinHangs: true }, { signal: controller.signal });
  setTimeout(() => controller.abort(), 20);
  const { events, result } = await pending;
  assert.deepEqual(states(events), ['launching', 'joining', 'stopping', 'ended']);
  assert.equal(result.reason, 'stopped');
  assert.equal(result.bytes, 4);
});

test('the time limit ends a session with reason time_limit', async (t) => {
  const { result } = await run(t, {}, { maxDurationMs: 10 });
  assert.equal(result.reason, 'time_limit');
  assert.equal(result.state, 'ended');
});

test('a join failure reports a coded error, keeps the partial file, and fails', async (t) => {
  const { events, result, root } = await run(t, { joinError: new MinutesError('join_rejected', 'Not admitted.') });
  const error = events.find((event) => event.type === 'error');
  assert.deepEqual([error.code, error.message], ['join_rejected', 'Not admitted.']);
  assert.deepEqual(states(events), ['launching', 'joining', 'failed']);
  assert.equal(result.state, 'failed');
  assert.equal(result.reason, 'failed');
  assert.equal(result.bytes, 4);
  const status = await readStatus(path.join(root, 'state'));
  assert.deepEqual(status.sessions[0].error, { code: 'join_rejected', message: 'Not admitted.' });
});

test('a launch failure has no recording and maps unknown errors to internal', async (t) => {
  const { events, result } = await run(t, { openError: new Error('boom') });
  assert.deepEqual(states(events), ['launching', 'failed']);
  assert.equal(events.find((event) => event.type === 'error').code, 'internal');
  assert.deepEqual([result.path, result.bytes], [null, null]);
  assert.equal(events.some((event) => event.type === 'recording'), false);
});

test('status marks an active record whose process is gone as stale and skips bad files', async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), 'minutes-status-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const at = '2026-10-09T10:00:00.000Z';
  const base = { pid: 999999, platform: 'zoom', meeting: 'https://zoom.us/j/1234567890', outputPath: null, startedAt: at, updatedAt: at, joinedAt: null, endedAt: null, endReason: null, error: null };
  await writeSessionRecord(root, { ...base, id: 'a', state: 'in_meeting' });
  await writeSessionRecord(root, { ...base, id: 'b', state: 'joining', startedAt: '2026-10-09T11:00:00.000Z' });
  await writeFile(path.join(root, 'broken.json'), '{');
  await writeFile(path.join(root, 'c.json'), JSON.stringify({ ...base, id: 'other', state: 'ended' }));
  const status = await readStatus(root, { alive: (pid) => pid !== 999999 });
  assert.deepEqual(status.sessions.map((session) => [session.id, session.alive, session.stale]), [['b', false, true], ['a', false, true]]);
  assert.equal(status.unreadable, 2);
  assert.deepEqual((await readStatus(path.join(root, 'missing'))).sessions, []);
  await assert.rejects(writeSessionRecord(root, { ...base, id: '../x', state: 'ended' }), /invalid session record/);
});
