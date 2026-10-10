import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { PassThrough } from 'node:stream';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { isMinutesDoctor, isMinutesEvent, isMinutesStatus } from '@subset/minutes';
import { main } from '../src/main.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const cli = path.join(root, 'dist/cli.mjs');
const fake = path.join(root, 'test/fixtures/fake-cli.mjs');

async function sandbox(t) {
  const directory = await mkdtemp(path.join(tmpdir(), 'minutes-cli-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return { directory, env: { ...process.env, SUBSET_MINUTES_DATA_DIR: path.join(directory, 'data'), HOME: directory } };
}

const run = (args, env) => spawnSync(process.execPath, [cli, ...args], { env, encoding: 'utf8' });
const lines = (text) => text.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));

test('--help, --version, and unknown commands', () => {
  const help = run(['--help'], process.env);
  assert.equal(help.status, 0);
  assert.match(help.stdout, /subset-minutes <command>/);
  assert.match(run(['--version'], process.env).stdout, /^\d+\.\d+\.\d+\n$/);
  assert.equal(run([], process.env).status, 2);
  assert.equal(run(['record'], process.env).status, 2);
  const inherited = run(['constructor'], process.env);
  assert.equal(inherited.status, 2);
  assert.match(inherited.stderr, /Unknown command/);
});

test('join rejects an invalid link with a structured error and exit 2', async (t) => {
  const { env } = await sandbox(t);
  const result = run(['join', 'https://example.com/meeting', '--json'], env);
  assert.equal(result.status, 2);
  const events = lines(result.stdout);
  assert.ok(events.every(isMinutesEvent));
  assert.deepEqual(events.map((event) => event.type), ['error', 'ended']);
  assert.equal(events[0].code, 'invalid_link');
  assert.equal(events[1].reason, 'failed');
  const human = run(['join', 'http://meet.google.com/abc-defg-hij'], env);
  assert.equal(human.status, 2);
  assert.match(human.stderr, /https/);
  const usage = run(['join', '--json', '--bogus'], env);
  assert.equal(usage.status, 2);
  assert.equal(lines(usage.stdout)[0].code, 'usage');
  const tooShort = run(['join', 'https://zoom.us/j/1234567890', '--json', '--max-minutes', '0.1'], env);
  assert.equal(tooShort.status, 2);
  assert.match(lines(tooShort.stdout)[0].message, /--max-minutes/);
});

test('status --json is valid and read-only; doctor --json is valid', async (t) => {
  const { directory, env } = await sandbox(t);
  const status = run(['status', '--json'], env);
  assert.equal(status.status, 0);
  const parsed = JSON.parse(status.stdout);
  assert.equal(isMinutesStatus(parsed), true);
  assert.deepEqual(parsed.sessions, []);
  await assert.rejects(readFile(path.join(directory, 'data')), /ENOENT/, 'status must not create its state directory');
  const doctor = run(['doctor', '--json', '--out', path.join(directory, 'out')], env);
  assert.equal(isMinutesDoctor(JSON.parse(doctor.stdout)), true);
});

async function startFake(t, extraArgs = [], { link = 'https://zoom.us/j/1234567890?pwd=secret' } = {}) {
  const { directory, env } = await sandbox(t);
  const args = link ? [fake, 'join', link] : [fake, 'join'];
  const child = spawn(process.execPath, [...args, '--json', '--out', path.join(directory, 'out'), ...extraArgs], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  const events = [];
  let stderr = '';
  child.stderr.setEncoding('utf8').on('data', (chunk) => { stderr += chunk; });
  // 'close' follows the end of stdout, so every event has been read by then.
  const exited = new Promise((resolve) => child.on('close', (code) => resolve(code)));
  const inMeeting = new Promise((resolve, reject) => {
    readline.createInterface({ input: child.stdout }).on('line', (line) => {
      const event = JSON.parse(line);
      events.push(event);
      if (event.type === 'state' && event.state === 'in_meeting') resolve();
    });
    exited.then((code) => reject(new Error(`The fake CLI exited (${code}) before joining.\n${stderr}`)));
  });
  return { child, events, exited, env, inMeeting };
}

for (const signal of ['SIGINT', 'SIGTERM']) {
  test(`${signal} stops cleanly and finalizes the recording`, async (t) => {
    const { child, events, exited, env, inMeeting } = await startFake(t);
    await inMeeting;
    child.kill(signal);
    assert.equal(await exited, 0);
    assert.ok(events.every(isMinutesEvent));
    assert.deepEqual(events.filter((event) => event.type === 'state').map((event) => event.state), ['launching', 'joining', 'in_meeting', 'stopping', 'ended']);
    const ended = events.at(-1);
    assert.deepEqual([ended.type, ended.reason, ended.bytes], ['ended', 'stopped', 9]);
    assert.equal(await readFile(ended.path, 'utf8'), 'fake-webm');
    assert.equal(JSON.stringify(events).includes('secret'), false);

    const status = JSON.parse(run(['status', '--json'], env).stdout);
    assert.equal(isMinutesStatus(status), true);
    assert.deepEqual([status.sessions[0].state, status.sessions[0].endReason, status.sessions[0].outputPath], ['ended', 'stopped', ended.path]);
  });
}

test('--stop-on-stdin-close stops when the parent closes stdin', async (t) => {
  const { child, events, exited, inMeeting } = await startFake(t, ['--stop-on-stdin-close']);
  await inMeeting;
  child.stdin.end();
  assert.equal(await exited, 0);
  assert.equal(events.at(-1).reason, 'stopped');
});

test('--link-from-stdin reads the link from stdin, so it is not in the arguments', async (t) => {
  const { child, events, exited, inMeeting } = await startFake(t, ['--link-from-stdin', '--stop-on-stdin-close'], { link: null });
  child.stdin.write('https://zoom.us/j/1234567890?pwd=secret\n');
  await inMeeting;
  assert.equal(events[0].meeting, 'https://zoom.us/j/1234567890');
  child.stdin.end();
  assert.equal(await exited, 0);
  assert.equal(events.at(-1).reason, 'stopped');
  assert.equal(JSON.stringify(events).includes('secret'), false);
});

test('--profile must be inside the home folder', async (t) => {
  const { directory, env } = await sandbox(t);
  const outside = run(['doctor', '--json', '--profile', path.join(directory, '..')], env);
  assert.equal(outside.status, 2);
  const events = lines(outside.stdout);
  assert.equal(events[0].code, 'usage');
  assert.match(events[0].message, /inside your home folder/);
  assert.equal(run(['doctor', '--json', '--profile', '~'], env).status, 2);
  const inside = run(['doctor', '--json', '--profile', '~/bot-profile', '--out', directory], env);
  assert.notEqual(inside.status, 2);
  assert.ok(isMinutesDoctor(JSON.parse(inside.stdout)));
  // A dangling symlink inside home could lead anywhere once Chrome creates the profile through it.
  await symlink(path.join(directory, '..', 'minutes-elsewhere'), path.join(directory, 'dangling'));
  assert.equal(run(['doctor', '--json', '--profile', '~/dangling/profile'], env).status, 2);
});

/**
 * Runs `main` in-process with a stdin that never sends the link. `onWaiting` runs once `main` is reading
 * stdin (it resumes the stream after installing its listeners).
 */
async function joinFromIdleStdin(t, signal, { onWaiting } = {}) {
  const { directory, env } = await sandbox(t);
  const stdin = new PassThrough();
  if (onWaiting) stdin.once('resume', () => setImmediate(onWaiting));
  const out = [];
  let drivers = 0;
  const code = await main({
    argv: ['join', '--link-from-stdin', '--json', '--out', path.join(directory, 'out')],
    env,
    home: directory,
    stdout: (text) => out.push(text),
    stderr: () => {},
    signal,
    stdin,
    createDriver: async () => { drivers += 1; throw new Error('the driver must not start'); },
  });
  return { code, drivers, events: lines(out.join('')) };
}

test('a Stop while waiting for the stdin link ends without joining', async (t) => {
  const stop = new AbortController();
  let waited = false;
  const { code, drivers, events } = await joinFromIdleStdin(t, stop.signal, {
    onWaiting: () => { waited = true; stop.abort(); },
  });
  assert.equal(waited, true);
  assert.equal(code, 0);
  assert.equal(drivers, 0);
  assert.deepEqual(events.map((event) => [event.type, event.reason, event.session]), [['ended', 'stopped', null]]);
  assert.ok(events.every(isMinutesEvent));
});

test('a Stop that arrived before join starts ends without joining', async (t) => {
  const { code, drivers, events } = await joinFromIdleStdin(t, AbortSignal.abort());
  assert.equal(code, 0);
  assert.equal(drivers, 0);
  assert.equal(events.at(-1).reason, 'stopped');
});
