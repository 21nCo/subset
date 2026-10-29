import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createSilentSink } from '../../src/alerts/index.mjs';
import { createClient, socketRequest } from '../../src/daemon/index.mjs';
import { HELP, VERSION } from '../../src/commands/index.mjs';
import { FIXTURES, PACKAGE_ROOT, cliDaemon, refuseSpawn, runCli } from './helpers.mjs';
import { eventually, tempDataDir, within } from '../daemon/helpers.mjs';

// "Ends at" lines are local times; the fixtures' 09:00 UTC reads the same everywhere this runs.
process.env.TZ = 'UTC';

const fixture = (name) => JSON.parse(readFileSync(join(FIXTURES, name), 'utf8'));
const agentResult = fixture('agent-result.json');
const operations = fixture('operations.json').cases;
const fixtureCase = (name) => {
  const found = operations.find((entry) => entry.name === name);
  assert.ok(found, `No SET-74 operation fixture "${name}"`);
  return found;
};

// The daemon records the AMRAP countdown, whose time was up in the fixture store, as finished when it
// starts. Its projection, and so every line of text, is unchanged.
const AMRAP = 't_nwkjbbkw';
function withAmrapRecorded(board) {
  return {
    ...board,
    timers: board.timers.map((timer) => (timer.definition.id === AMRAP
      ? { ...timer, runtime: { ...timer.runtime, status: 'finished', startedAt: null, accumulatedMs: timer.projection.elapsedMs } }
      : timer))
  };
}

test('list prints the SET-74 agent text, and with --json the agent result', async (t) => {
  const { run } = await cliDaemon(t, { fixture: true });
  const expected = { ...agentResult, structuredContent: withAmrapRecorded(agentResult.structuredContent) };
  for (const argv of [[], ['list']]) {
    const human = await run(argv);
    assert.deepEqual({ code: human.code, stderr: human.stderr }, { code: 0, stderr: '' });
    assert.equal(human.stdout, `${agentResult.text}\n`);
  }
  for (const argv of [['--json'], ['list', '--json']]) {
    const result = await run(argv);
    assert.equal(result.code, 0);
    assert.deepEqual(result.json(), expected);
    // One line: an agent can read it with a single JSON.parse.
    assert.equal(result.stdout.trimEnd().includes('\n'), false);
  }
  assert.deepEqual(fixtureCase('list every timer').result, agentResult.structuredContent);
});

test('an empty board says so', async (t) => {
  const { run } = await cliDaemon(t);
  assert.equal((await run(['list'])).stdout, 'No timers.\n');
});

// Each SET-74 operation fixture the CLI can express, as the command that runs it and the human text it prints.
const OPERATION_COMMANDS = [
  ['start an idle timer', ['start', 't_ac50bvkp'], 'Pomodoro (t_ac50bvkp): running · segment 1/8 · work (Focus) · 25:00 left · next rest (Break) 5:00\nEnds at 11:10:00.'],
  ['start fixes an until countdown to a duration', ['start', 't_v9pdg8p9'], 'Standup (t_v9pdg8p9): running · 30:00 left\nEnds at 09:30:00.'],
  ['start a preset in one step', ['start', 'emom'], 'EMOM (t_4tvjx8bj): running · round 1/10 · work · 1:00 left · next work 1:00\nEnds at 09:10:00.'],
  ['pause a running interval', ['pause', 't_adygqpxx'], 'Tabata (t_adygqpxx): paused · round 3/8 · work · 0:12 left · next rest 0:10'],
  ['resume a paused countdown', ['resume', 't_dk1facen'], 'Tea (t_dk1facen): running · 1:40 left\nEnds at 09:01:40.'],
  ['lap a stopwatch', ['lap', 't_rcrt44q9'], 'Run (t_rcrt44q9): running · 10:00 elapsed · 3 laps'],
  ['skip to the next segment', ['skip', 't_adygqpxx'], 'Tabata (t_adygqpxx): running · round 3/8 · rest · 0:10 left · next work 0:20\nEnds at 09:02:40.'],
  ['reset a finished timer', ['reset', 't_daesff02'], 'Stretch (t_daesff02): idle · 0:30 total'],
  ['get one timer', ['status', 't_dk1facen'], 'Tea (t_dk1facen): paused · 1:40 left'],
  ['remove a timer', ['rm', 't_rcrt44q9'], 'Removed Run (t_rcrt44q9).'],
  ['remove a saved preset', ['preset', 'rm', 'p_xja3zjdj'], 'Removed preset Ladder (p_xja3zjdj).']
];

for (const [name, argv, text] of OPERATION_COMMANDS) {
  test(`subset-timer ${argv.join(' ')} matches the SET-74 fixture "${name}"`, async (t) => {
    const { result } = fixtureCase(name);
    const json = await (await cliDaemon(t, { fixture: true })).run([...argv, '--json']);
    assert.deepEqual({ code: json.code, stderr: json.stderr }, { code: 0, stderr: '' });
    assert.deepEqual(json.json(), result);
    const human = await (await cliDaemon(t, { fixture: true })).run(argv);
    assert.deepEqual({ code: human.code, stdout: human.stdout, stderr: human.stderr }, { code: 0, stdout: `${text}\n`, stderr: '' });
  });
}

test('presets lists the built-in and saved presets, and --json is the presets.list result', async (t) => {
  const { run } = await cliDaemon(t, { fixture: true });
  const json = await run(['presets', '--json']);
  assert.equal(json.code, 0);
  assert.deepEqual(json.json(), fixtureCase('list presets').result);
  assert.equal((await run(['presets'])).stdout, [
    'Tabata (tabata, built in): 8 rounds of work 0:20, rest 0:10 · prep 0:10 · 4:10 total',
    'EMOM (emom, built in): 10 rounds of work 1:00 · 10:00 total',
    'HIIT 40/20 (hiit-40-20, built in): 10 rounds of work 0:40, rest 0:20 · 10:00 total',
    'Pomodoro (pomodoro, built in): 1 round of 8 segments · 2:10:00 total',
    'AMRAP (amrap, built in): countdown 20:00 with laps',
    'Ladder (p_xja3zjdj): 3 rounds of Squats 0:45, rest 0:15, Lunges 0:45, rest 0:15 · cooldown 2:00 · 8:00 total',
    ''
  ].join('\n'));
});

// Daemon refusals keep the SET-74 code and message; the exit status says which kind it was.
const REFUSALS = [
  ['start a running timer', ['start', 't_adygqpxx'], 4],
  ['start a finished timer', ['start', 't_daesff02'], 4],
  ['pause a timer whose time is up', ['pause', AMRAP], 4],
  ['resume a running timer', ['resume', 't_rcrt44q9'], 4],
  ['lap an interval timer', ['lap', 't_adygqpxx'], 4],
  ['skip a stopwatch', ['skip', 't_rcrt44q9'], 4],
  ['remove a built-in preset', ['preset', 'rm', 'tabata'], 4]
];

for (const [name, argv, exitCode] of REFUSALS) {
  test(`subset-timer ${argv.join(' ')} reports the SET-74 error "${name}"`, async (t) => {
    const { error } = fixtureCase(name);
    const { run } = await cliDaemon(t, { fixture: true });
    const json = await run([...argv, '--json']);
    assert.deepEqual({ code: json.code, stderr: json.stderr }, { code: exitCode, stderr: '' });
    assert.deepEqual(json.json(), { error });
    const human = await run(argv);
    assert.deepEqual({ code: human.code, stdout: human.stdout, stderr: human.stderr }, { code: exitCode, stdout: '', stderr: `subset-timer: ${error.message}\n` });
  });
}

test('start creates countdowns, stopwatches, intervals, presets and --until countdowns', async (t) => {
  const { run, sink, clock } = await cliDaemon(t);
  const start = async (...argv) => {
    const result = await run(['start', ...argv, '--json']);
    assert.equal(result.code, 0, `${argv.join(' ')}: ${result.stdout}`);
    return result.json().timer;
  };

  const tea = await start('1h30m', '--name', 'Tea');
  assert.deepEqual([tea.definition.kind, tea.definition.name, tea.definition.durationMs, tea.definition.sound, tea.projection.status], ['countdown', 'Tea', 5_400_000, true, 'running']);
  assert.equal((await start('1:30')).definition.durationMs, 90_000);
  assert.equal((await start('stopwatch')).definition.kind, 'stopwatch');

  const interval = await start('interval', '--work', '40s', '--rest', '20s', '--rounds', '10', '--prep', '10s', '--cooldown', '60s', '--no-sound');
  assert.deepEqual(
    { segments: interval.definition.segments, rounds: interval.definition.rounds, prepMs: interval.definition.prepMs, cooldownMs: interval.definition.cooldownMs, sound: interval.definition.sound },
    { segments: [{ label: 'Work', phase: 'work', durationMs: 40_000 }, { label: 'Rest', phase: 'rest', durationMs: 20_000 }], rounds: 10, prepMs: 10_000, cooldownMs: 60_000, sound: false }
  );
  assert.deepEqual((await start('interval', '--work', '1m', '--rounds', '3')).definition.segments, [{ label: 'Work', phase: 'work', durationMs: 60_000 }]);

  // Preset names and aliases, ignoring case; --no-sound sends the preset's timer with its sound off.
  for (const [spec, name] of [['tabata', 'Tabata'], ['EMOM', 'EMOM'], ['hiit', 'HIIT 40/20'], ['Pomodoro', 'Pomodoro'], ['amrap', 'AMRAP']]) {
    const timer = await start(spec);
    assert.deepEqual([timer.definition.name, timer.definition.sound], [name, true], spec);
  }
  const quiet = await start('tabata', '--no-sound', '--name', 'Quiet');
  assert.deepEqual([quiet.definition.name, quiet.definition.sound, quiet.definition.rounds], ['Quiet', false, 8]);

  // 2026-10-19 09:00 UTC; 17:30 is later today.
  const until = await start('--until', '17:30', '--name', 'Standup');
  assert.equal(until.projection.remainingMs, Date.UTC(2026, 9, 19, 17, 30) - clock.now());
  assert.match((await run(['status', until.definition.id])).stdout, /\nEnds at 17:30:00\.\n$/);

  // A saved preset by name.
  assert.equal((await run(['preset', 'save', 'Leg day', '--work', '45s', '--rest', '15s', '--rounds', '8'])).code, 0);
  assert.equal((await start('leg DAY')).definition.name, 'Leg day');

  // Starting an idle timer again after reset, by id.
  assert.equal((await run(['reset', tea.definition.id])).code, 0);
  assert.equal((await start(tea.definition.id)).projection.status, 'running');

  // --no-sound reaches the daemon's sink as the timer's sound flag; the CLI itself plays nothing.
  const quick = await start('2s', '--no-sound', '--name', 'Quick');
  sink.received.length = 0;
  clock.advance(2_000);
  const finish = sink.received.find(({ alert }) => alert.timerId === quick.definition.id && alert.kind === 'finish');
  assert.equal(finish?.timer.sound, false);
});

test('preset save stores an interval preset and prints it', async (t) => {
  const { run } = await cliDaemon(t);
  const human = await run(['preset', 'save', 'Rowing', '--work', '2m', '--rest', '1m', '--rounds', '5', '--no-sound']);
  assert.equal(human.code, 0);
  assert.match(human.stdout, /^Saved preset Rowing \(p_[0-9a-z]{8}\)\.\n$/);
  const json = await run(['preset', 'save', 'Sprints', '--work', '30s', '--rounds', '6', '--json']);
  assert.deepEqual(
    { name: json.json().preset.name, timer: json.json().preset.timer },
    { name: 'Sprints', timer: { kind: 'interval', segments: [{ label: 'Work', phase: 'work', durationMs: 30_000 }], rounds: 6 } }
  );
  const listed = (await run(['presets', '--json'])).json().presets.find((preset) => preset.name === 'Rowing');
  assert.equal(listed.timer.sound, false);
  assert.equal((await run(['preset', 'rm', 'rowing'])).code, 0);
  assert.equal((await run(['presets', '--json'])).json().presets.some((preset) => preset.name === 'Rowing'), false);
});

test('<ref> is an exact id, else a unique name ignoring case; several matches are ambiguous', async (t) => {
  const { run } = await cliDaemon(t);
  const first = (await run(['start', '5m', '--name', 'Tea', '--json'])).json().timer.definition.id;
  assert.equal((await run(['pause', 'tEA'])).code, 0);
  const second = (await run(['start', '3m', '--name', 'tea', '--json'])).json().timer.definition.id;

  const ambiguous = await run(['status', 'TEA', '--json']);
  assert.equal(ambiguous.code, 2);
  assert.deepEqual(ambiguous.json(), {
    error: {
      code: 'ambiguous',
      message: '"TEA" matches 2 timers; use an id.',
      candidates: [{ id: first, name: 'Tea', status: 'paused' }, { id: second, name: 'tea', status: 'running' }]
    }
  });
  const human = await run(['rm', 'Tea']);
  assert.deepEqual({ code: human.code, stdout: human.stdout }, { code: 2, stdout: '' });
  assert.equal(human.stderr, `subset-timer: "Tea" matches 2 timers; use an id.\n  ${first}  Tea (paused)\n  ${second}  tea (running)\n`);

  // An exact id wins, and a timer named like another's id is still reached by its name only when unique.
  assert.equal((await run(['resume', first, '--json'])).json().timer.definition.id, first);
  const named = (await run(['start', '1m', '--name', first, '--json'])).json().timer.definition.id;
  assert.equal((await run(['status', first, '--json'])).json().timer.definition.id, first);
  assert.notEqual(named, first);

  const missing = await run(['status', 'coffee', '--json']);
  assert.deepEqual({ code: missing.code, error: missing.json().error }, { code: 4, error: { code: 'not_found', message: 'No timer with the id or name "coffee".' } });

  // Presets resolve the same way.
  await run(['preset', 'save', 'Rounds', '--work', '1m', '--rounds', '2']);
  await run(['preset', 'save', 'ROUNDS', '--work', '2m', '--rounds', '2']);
  const presetAmbiguous = await run(['preset', 'rm', 'rounds', '--json']);
  assert.equal(presetAmbiguous.code, 2);
  assert.equal(presetAmbiguous.json().error.code, 'ambiguous');
  assert.equal(presetAmbiguous.json().error.candidates.length, 2);
  assert.equal((await run(['start', 'rounds', '--json'])).json().error.code, 'ambiguous');
});

test('invalid input exits 2 with a JSON error on stdout', async (t) => {
  const { run } = await cliDaemon(t);
  const cases = [
    [['start', '90']],
    [['start', '0s']],
    [['start', '1h30']],
    [['start']],
    [['start', 'interval', '--work', '40s']],
    [['start', 'interval', '--rounds', '3']],
    [['start', 'interval', '--work', '40s', '--rounds', 'ten']],
    [['start', 'interval', '--work', 'soon', '--rounds', '3']],
    [['start', '25m', '--work', '40s']],
    [['start', '25m', '--until', '17:30']],
    [['start', '--until', '5pm']],
    [['start', '25m', '--frobnicate']],
    [['start', 'tabata', 'emom']],
    [['status']],
    [['pause', '  ']],
    [['frobnicate']],
    [['preset', 'frobnicate']],
    [['daemon']],
    [['constructor']],
    [['preset', 'save', 'Bad', '--work', '40s', '--rounds', '0']]
  ];
  for (const [argv] of cases) {
    const result = await run([...argv, '--json']);
    assert.equal(result.code, 2, `${argv.join(' ')}: ${result.stdout}`);
    assert.equal(result.json().error.code, 'invalid_input', argv.join(' '));
    assert.equal(typeof result.json().error.message, 'string');
    const human = await run(argv);
    assert.equal(human.code, 2);
    assert.equal(human.stdout, '');
    assert.match(human.stderr, /^subset-timer: /);
  }
  // Something that is neither a duration nor a preset is not_found, with a pointer to the presets.
  const unknown = await run(['start', 'jog', '--json']);
  assert.deepEqual({ code: unknown.code, error: unknown.json().error.code }, { code: 4, error: 'not_found' });
  assert.match(unknown.json().error.message, /not a duration, stopwatch, interval or preset/);
  // --name=--json is a name, not the --json option.
  const named = await run(['start', '1m', '--name=--json']);
  assert.equal(named.code, 0);
  assert.match(named.stdout, /^--json \(t_/);
});

test('every exit status: 0 ok, 2 invalid or ambiguous, 3 daemon unavailable, 4 not found or invalid state', async (t) => {
  const { run } = await cliDaemon(t, { fixture: true });
  assert.equal((await run(['list'])).code, 0);
  assert.equal((await run(['start', '90'])).code, 2);
  assert.equal((await run(['status', 't_zzzzzzzz'])).code, 4);
  assert.equal((await run(['resume', 't_rcrt44q9'])).code, 4);

  // No daemon, and none can start: the client gives up and the command exits 3.
  const dataDir = tempDataDir(t);
  const spawned = [];
  const client = createClient({
    dataDir,
    startTimeoutMs: 200,
    spawn: (...args) => {
      spawned.push(args);
      return { on() {}, unref() {} };
    }
  });
  const unavailable = await runCli(['list', '--json'], { client });
  assert.equal(unavailable.code, 3);
  assert.equal(unavailable.json().error.code, 'daemon_unavailable');
  assert.equal(spawned.length, 1);
  assert.deepEqual(spawned[0][1].slice(1), ['daemon', 'run']);
  const human = await runCli(['pause', 'Tea'], { client });
  assert.equal(human.code, 3);
  assert.match(human.stderr, /^subset-timer: The Timer daemon did not start within 0\.2 s\.\n$/);

  // daemon status never starts one.
  const status = await runCli(['daemon', 'status', '--json'], { client });
  assert.deepEqual({ code: status.code, json: status.json() }, { code: 3, json: { error: { code: 'daemon_unavailable', message: 'The Timer daemon is not running.' } } });
  assert.equal(spawned.length, 2);
});

test('daemon status reports the pid, data directory and alert sink; daemon stop stops it', async (t) => {
  const { run, daemon, dataDir } = await cliDaemon(t, { sink: createSilentSink() });
  const status = await run(['daemon', 'status', '--json']);
  assert.equal(status.code, 0);
  assert.deepEqual(
    { pid: status.json().pid, dataDir: status.json().dataDir, socket: status.json().socket, alerts: status.json().alerts },
    { pid: process.pid, dataDir, socket: daemon.paths.socket, alerts: 'unavailable' }
  );
  const human = await run(['daemon', 'status']);
  assert.match(human.stdout, new RegExp(`^pid: ${process.pid}\ndata dir: .+\nsocket: .+\nalerts: unavailable\nstarted: \\d{4}-`));

  const stopped = await run(['daemon', 'stop', '--json']);
  assert.deepEqual({ code: stopped.code, json: stopped.json() }, { code: 0, json: { stopped: true } });
  await daemon.closed;
  const again = await run(['daemon', 'stop']);
  assert.deepEqual({ code: again.code, stdout: again.stdout }, { code: 0, stdout: 'The Timer daemon is not running.\n' });
});

test('daemon stop returns only once the daemon finishing its sink has let go of the lock, so a daemon run right after starts', async (t) => {
  let finishPlaying;
  const playing = [];
  const sink = {
    name: 'slow',
    alert(alert, timer) {
      playing.push(timer.name);
      return new Promise((resolve) => {
        finishPlaying = resolve;
      });
    }
  };
  const { run, daemon, dataDir, op, clock } = await cliDaemon(t, { sink });
  assert.equal((await op('start', { timer: { kind: 'countdown', durationMs: 1_000, countdownTicks: false, name: 'Egg' } })).status, 200);
  clock.advance(1_000);
  await eventually(() => playing.length === 1);

  let stopped = null;
  const stopping = run(['daemon', 'stop', '--json']).then((result) => {
    stopped = result;
    return result;
  });
  // The socket is gone, but the daemon still holds the lock while its sink plays.
  await eventually(() => !existsSync(daemon.paths.socket));
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.deepEqual([stopped, existsSync(daemon.paths.lock)], [null, true]);
  finishPlaying();
  const result = await within(stopping, 5_000, 'daemon stop');
  assert.deepEqual({ code: result.code, json: result.json() }, { code: 0, json: { stopped: true } });
  assert.equal(existsSync(daemon.paths.lock), false);

  const foreground = [];
  const next = await runCli(['daemon', 'run', '--json'], {
    env: { SUBSET_TIMER_ALERTS: 'off', SUBSET_TIMER_DATA_DIR: dataDir },
    foreground: async (started) => {
      foreground.push(started.pid);
      await started.shutdown();
    }
  });
  assert.deepEqual({ code: next.code, stdout: next.stdout, foreground }, { code: 0, stdout: '', foreground: [process.pid] });
});

test('daemon stop counts a daemon.lock it cannot read as still held: it returns once the lock can be read, and fails at its bound if it never can', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'std-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const lock = join(dir, 'daemon.lock');
  for (const recovers of [true, false]) {
    // A directory in its place: every read of the lock fails.
    mkdirSync(lock);
    let answering = true;
    const client = {
      paths: { lock },
      async status() {
        if (!answering) throw new Error('connect ENOENT');
        return { status: 200, body: { pid: process.pid } };
      },
      async shutdown() {
        answering = false;
      }
    };
    let stopped = null;
    const stopping = runCli(['daemon', 'stop', '--json'], { client }).then((result) => (stopped = result));
    // The socket is gone, but the lock cannot tell whether the daemon still holds it.
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert.equal(stopped, null, `recovers: ${recovers}`);
    if (recovers) rmSync(lock, { recursive: true });
    const result = await within(stopping, 10_000, 'daemon stop');
    assert.deepEqual(
      { code: result.code, json: result.json() },
      recovers
        ? { code: 0, json: { stopped: true } }
        : { code: 3, json: { error: { code: 'daemon_unavailable', message: 'The Timer daemon did not stop within 8 s.' } } }
    );
    rmSync(lock, { recursive: true, force: true });
  }
});

test('daemon run runs the daemon with the selected sink in the foreground', async () => {
  const started = [];
  const daemon = { closed: Promise.resolve(0) };
  const foreground = [];
  const result = await runCli(['daemon', 'run'], {
    env: { SUBSET_TIMER_ALERTS: 'off', SUBSET_TIMER_DATA_DIR: '/nonexistent' },
    client: {},
    startDaemon: async (options) => {
      started.push(options);
      return daemon;
    },
    foreground: async (handle) => foreground.push(handle)
  });
  assert.deepEqual({ code: result.code, stdout: result.stdout }, { code: 0, stdout: '' });
  assert.equal(started.length, 1);
  assert.equal(started[0].sink.name, 'off');
  assert.equal(started[0].dataDir, '/nonexistent');
  assert.deepEqual(foreground, [daemon]);
});

test('a daemon that cannot start or be reached is daemon_unavailable, exit 3, never a crash', async (t) => {
  const noForeground = () => assert.fail('daemon run went to the foreground.');
  // daemon.sock under this directory is longer than any platform's socket path limit.
  const longDir = join(tempDataDir(t), 'x'.repeat(120));
  const env = { SUBSET_TIMER_ALERTS: 'off', SUBSET_TIMER_DATA_DIR: longDir };
  for (const argv of [['list'], ['status', 'Tea'], ['start', '5m'], ['daemon', 'status'], ['daemon', 'stop'], ['daemon', 'run']]) {
    const result = await runCli([...argv, '--json'], { env, foreground: noForeground });
    assert.deepEqual({ code: result.code, error: result.json().error.code, stderr: result.stderr }, { code: 3, error: 'daemon_unavailable', stderr: '' }, argv.join(' '));
    assert.match(result.json().error.message, /longer than 103 bytes; set SUBSET_TIMER_DATA_DIR to a shorter directory\.$/);
    const human = await runCli(argv, { env, foreground: noForeground });
    assert.equal(human.code, 3);
    assert.match(human.stderr, /^subset-timer: .+\n$/);
  }

  // The client rejects, rather than raising an uncaught socket error, for a path it cannot connect to.
  const longSocket = join(longDir, 'daemon.sock');
  await assert.rejects(socketRequest(longSocket, 'GET', '/v1/daemon'));
  const client = createClient({ dataDir: longDir, spawn: refuseSpawn, startTimeoutMs: 200 });
  await assert.rejects(client.timers(), { code: 'daemon_unavailable' });
  await assert.rejects(client.events(() => {}), { code: 'daemon_unavailable' });

  // A second daemon run while one holds the data directory.
  const { dataDir } = await cliDaemon(t);
  const second = await runCli(['daemon', 'run', '--json'], { env: { SUBSET_TIMER_ALERTS: 'off', SUBSET_TIMER_DATA_DIR: dataDir }, foreground: noForeground });
  assert.deepEqual(
    { code: second.code, json: second.json() },
    { code: 3, json: { error: { code: 'daemon_unavailable', message: `The Timer daemon is already running (pid ${process.pid}).` } } }
  );
});

test('skill path, --version and --help need no daemon', async () => {
  const client = new Proxy({}, { get: () => assert.fail('The command used the daemon.') });
  const path = await runCli(['skill', 'path'], { client });
  assert.deepEqual({ code: path.code, stdout: path.stdout }, { code: 0, stdout: `${join(PACKAGE_ROOT, 'skills', 'subset-timer')}\n` });
  assert.ok(readFileSync(join(path.stdout.trim(), 'SKILL.md'), 'utf8').startsWith('---\nname: subset-timer\n'));
  assert.deepEqual((await runCli(['skill', 'path', '--json'], { client })).json(), { path: join(PACKAGE_ROOT, 'skills', 'subset-timer') });

  const manifest = JSON.parse(readFileSync(join(PACKAGE_ROOT, 'package.json'), 'utf8'));
  assert.equal(VERSION, manifest.version);
  for (const flag of ['--version', '-v']) assert.equal((await runCli([flag], { client })).stdout, `${manifest.version}\n`);
  for (const argv of [['--help'], ['-h'], ['start', '--help'], ['status', 'Tea', '-h'], ['frobnicate', '--help']]) {
    const help = await runCli(argv, { client });
    assert.deepEqual({ code: help.code, stdout: help.stdout }, { code: 0, stdout: HELP });
  }
});

test('--help is help only as an option, not as a value or after --', async (t) => {
  const { run } = await cliDaemon(t);
  const id = (await run(['start', '5m', '--name=--help', '--json'])).json().timer.definition.id;
  const status = await run(['status', '--json', '--', '--help']);
  assert.deepEqual({ code: status.code, id: status.json().timer.definition.id }, { code: 0, id });
  assert.equal((await run(['pause', '--', '-h'])).code, 4);
  assert.equal((await run(['pause', '--', '--help'])).code, 0);
});

test('--help lists every command SKILL.md uses, and SKILL.md uses only commands that exist', () => {
  const skill = readFileSync(join(PACKAGE_ROOT, 'skills/subset-timer/SKILL.md'), 'utf8');
  const helpCommands = new Set([...HELP.matchAll(/^ {2}([a-z]+(?: (?:run|status|stop|path|save|rm))?)(?= |$)/gm)].map((match) => match[1]));
  const skillCommands = new Set([...skill.matchAll(/(?:^|`)subset-timer ([a-z]+)(?: (run|status|stop|path|save|rm)\b)?/gm)]
    .map(([, command, sub]) => (['daemon', 'skill', 'preset'].includes(command) ? `${command} ${sub}` : command)));
  assert.deepEqual([...skillCommands].filter((command) => !helpCommands.has(command)), []);
  // The skill teaches every timer, preset, daemon and web command.
  const expected = ['list', 'status', 'start', 'pause', 'resume', 'lap', 'skip', 'reset', 'rm', 'presets', 'preset save', 'preset rm', 'daemon run', 'daemon status', 'daemon stop', 'skill path', 'serve'];
  // `mcp` is started by an MCP host, not run by a shell agent, so the skill leaves it out.
  assert.deepEqual([...helpCommands].sort(), [...expected, 'mcp'].sort());
  assert.deepEqual([...skillCommands].sort(), [...expected].sort());
  // The rules the issue requires.
  assert.match(skill, /Always add `--json`/);
  assert.match(skill, /its id/);
  assert.match(skill, /when it ends/);
  assert.match(skill, /keep running after your turn ends/);
  assert.match(skill, /`subset-timer reset` and `subset-timer rm` only when the user explicitly asks/);
});
