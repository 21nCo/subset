import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  MINUTES_CONTRACT_VERSION,
  createEvent,
  isMinutesDoctor,
  isMinutesEvent,
  isMinutesStatus,
  isSessionRecord,
  parseEventLine,
} from '../dist/index.js';

const at = new Date('2026-10-09T10:00:00.000Z');
const valid = [
  createEvent('20261009T100000Z-abc123', { type: 'started', platform: 'zoom', meeting: 'https://zoom.us/j/1234567890', displayName: 'Bot', outputDirectory: '/tmp/out' }, at),
  createEvent('20261009T100000Z-abc123', { type: 'state', state: 'in_meeting' }, at),
  createEvent('20261009T100000Z-abc123', { type: 'status', message: 'hello' }, at),
  createEvent('20261009T100000Z-abc123', { type: 'recording', path: '/tmp/out/a.webm' }, at),
  createEvent(null, { type: 'error', code: 'invalid_link', message: 'bad' }, at),
  createEvent('20261009T100000Z-abc123', { type: 'ended', reason: 'stopped', path: '/tmp/out/a.webm', bytes: 1024 }, at),
  createEvent(null, { type: 'ended', reason: 'failed', path: null, bytes: null }, at),
];

test('accepts every documented event shape', () => {
  for (const event of valid) {
    assert.equal(event.v, MINUTES_CONTRACT_VERSION);
    assert.equal(event.at, at.toISOString());
    assert.equal(isMinutesEvent(event), true, JSON.stringify(event));
    assert.deepEqual(parseEventLine(JSON.stringify(event)), event);
  }
});

test('rejects unknown versions, types, values, and extra fields', () => {
  const [started, state, , recording, error, ended] = valid;
  const invalid = [
    null, [], 'x',
    { ...state, v: 2 },
    { ...state, v: '1' },
    { ...state, at: 'yesterday' },
    { ...state, session: '../etc' },
    { ...state, type: 'joined' },
    { ...state, state: 'recording' },
    { ...started, platform: 'teams' },
    { ...started, meeting: '' },
    { ...started, url: 'https://zoom.us/j/1?pwd=secret' },
    { ...recording, path: '' },
    { ...error, code: 'boom' },
    { ...error, message: { text: 'x' } },
    { ...ended, reason: 'done' },
    { ...ended, bytes: -1 },
    { ...ended, bytes: 1.5 },
    { ...state, extra: true },
  ];
  for (const value of invalid) assert.equal(isMinutesEvent(value), false, JSON.stringify(value));
  assert.equal(parseEventLine('not json'), null);
  assert.equal(parseEventLine('{"v":1}'), null);
});

const record = {
  id: '20261009T100000Z-abc123', pid: 42, platform: 'google-meet', meeting: 'https://meet.google.com/abc-defg-hij',
  state: 'ended', outputPath: '/tmp/a.webm', startedAt: at.toISOString(), updatedAt: at.toISOString(),
  joinedAt: at.toISOString(), endedAt: at.toISOString(), endReason: 'meeting_ended', error: null,
};

test('validates session records and status', () => {
  assert.equal(isSessionRecord(record), true);
  assert.equal(isSessionRecord({ ...record, pid: 0 }), false);
  assert.equal(isSessionRecord({ ...record, error: { code: 'internal', message: 'x', stack: 'y' } }), false);
  assert.equal(isSessionRecord({ ...record, token: 'x' }), false);
  const status = { v: 1, kind: 'minutes.status', observedAt: at.toISOString(), stateDirectory: '/tmp/s', sessions: [{ ...record, alive: false, stale: false }], unreadable: 0 };
  assert.equal(isMinutesStatus(status), true);
  assert.equal(isMinutesStatus({ ...status, sessions: [record] }), false);
  assert.equal(isMinutesStatus({ ...status, kind: 'minutes.doctor' }), false);
  assert.equal(isMinutesStatus({ ...status, sessions: Array(21).fill(status.sessions[0]) }), false);
});

test('validates doctor output and its ok summary', () => {
  const doctor = {
    v: 1, kind: 'minutes.doctor', observedAt: at.toISOString(), ok: false, chromePath: null,
    profileDirectory: '/p', outputDirectory: '/o',
    checks: [
      { id: 'node', ok: true, required: true, detail: 'Node.js 22.13.0', fix: null },
      { id: 'chrome', ok: false, required: true, detail: 'missing', fix: 'install' },
      { id: 'profile', ok: false, required: false, detail: 'guest', fix: 'sign in' },
    ],
  };
  assert.equal(isMinutesDoctor(doctor), true);
  assert.equal(isMinutesDoctor({ ...doctor, ok: true }), false);
  assert.equal(isMinutesDoctor({ ...doctor, checks: [...doctor.checks, doctor.checks[0]] }), false);
  assert.equal(isMinutesDoctor({ ...doctor, checks: [{ ...doctor.checks[0], id: 'disk' }] }), false);
});
