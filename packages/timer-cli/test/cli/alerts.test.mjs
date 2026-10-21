import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';
import { createLinuxSink, createMacosSink, createSilentSink, findOnPath, selectSink } from '../../src/alerts/index.mjs';
import { LINUX_SOUNDS } from '../../src/alerts/linux.mjs';
import { AFPLAY, MACOS_SOUNDS, NOTIFY_SCRIPT, OSASCRIPT } from '../../src/alerts/macos.mjs';
import { ALERT_PROCESS_TIMEOUT_MS } from '../../src/alerts/process.mjs';

/** A `spawn` that records each call and whose child exits with `code` on the next tick. */
function recordingSpawn({ code = 0, error = null } = {}) {
  const calls = [];
  const spawn = (command, args, options) => {
    calls.push({ command, args: [...args], options });
    const child = new EventEmitter();
    child.kill = () => {};
    setImmediate(() => (error ? child.emit('error', error) : child.emit('exit', code, null)));
    return child;
  };
  return { spawn, calls };
}

// The closed injection set (SET-77 decision 2). Other forms go to SET-88.
const INJECTION_NAMES = [
  'Say "hi"',
  'back\\slash\\',
  "it's",
  'run $(rm -rf ~)',
  'tick `whoami` tock',
  'one; two',
  'line one\nline two',
  '😀'.repeat(60),
  'x" end tell',
  '" & (do shell script "touch /tmp/pwned") & "',
  'end tell\ndo shell script "id"',
  '-e',
  '--'
];

const timer = (name, sound = true) => ({ id: 't_ab12cd34', kind: 'countdown', name, sound, durationMs: 60_000 });
const at = 1_792_400_400_000;

test('a timer name reaches osascript only as argv of the fixed on run argv script, never through a shell', async () => {
  for (const name of INJECTION_NAMES) {
    const { spawn, calls } = recordingSpawn();
    await createMacosSink({ spawn }).alert({ timerId: 't_ab12cd34', kind: 'finish', at }, timer(name));
    const osascript = calls.filter((call) => call.command === OSASCRIPT);
    assert.equal(osascript.length, 1, name);
    const { args, options } = osascript[0];
    // -e and the fixed script lines, then -- and exactly the title and body as their own items.
    assert.deepEqual(args, [...NOTIFY_SCRIPT.flatMap((line) => ['-e', line]), '--', name, 'Finished.'], name);
    // The script text is fixed: nothing of the name is in any -e item.
    const separator = args.indexOf('--');
    assert.deepEqual(args.slice(0, separator), ['-e', 'on run argv', '-e', 'display notification (item 2 of argv) with title (item 1 of argv)', '-e', 'end run']);
    for (const call of calls) {
      assert.equal(call.options.shell, false, name);
      assert.ok(call.command.startsWith('/usr/bin/'), call.command);
      // No process other than osascript sees the name.
      if (call.command !== OSASCRIPT) assert.equal(call.args.some((arg) => arg.includes(name)), false, name);
    }
  }
});

test('a missed-while-away notification passes the name the same way', async () => {
  const { spawn, calls } = recordingSpawn();
  const name = INJECTION_NAMES[9];
  await createMacosSink({ spawn }).alert(
    { timerId: 't_ab12cd34', kind: 'missedWhileAway', at, missed: 3, segment: { label: 'Rest "now"' } },
    timer(name)
  );
  assert.deepEqual(calls.map((call) => call.command), [OSASCRIPT]);
  assert.deepEqual(calls[0].args.slice(-3), ['--', name, 'Missed 3 alerts while away. Now: Rest "now".']);
});

test('macOS plays only the built-in sounds, and none when the timer has sound off', async () => {
  const expected = { tick: ['Tink'], segment: ['Pop'], finish: ['Glass', 'Glass', 'Glass'], missedWhileAway: [] };
  for (const [kind, sounds] of Object.entries(expected)) {
    const { spawn, calls } = recordingSpawn();
    await createMacosSink({ spawn }).alert({ timerId: 't_ab12cd34', kind, at, secondsLeft: 3, missed: 1 }, timer('Tea'));
    const played = calls.filter((call) => call.command === AFPLAY);
    assert.deepEqual(played.map((call) => call.args), sounds.map((sound) => [`/System/Library/Sounds/${sound}.aiff`]), kind);
    assert.equal(calls.filter((call) => call.command === OSASCRIPT).length, ['finish', 'missedWhileAway'].includes(kind) ? 1 : 0, kind);

    const quiet = recordingSpawn();
    await createMacosSink({ spawn: quiet.spawn }).alert({ timerId: 't_ab12cd34', kind, at, secondsLeft: 3, missed: 1 }, timer('Tea', false));
    assert.deepEqual(quiet.calls.filter((call) => call.command === AFPLAY), [], kind);
    // Notifications still show with sound off.
    assert.equal(quiet.calls.filter((call) => call.command === OSASCRIPT).length, ['finish', 'missedWhileAway'].includes(kind) ? 1 : 0, kind);
  }
  assert.deepEqual(Object.keys(MACOS_SOUNDS).sort(), ['finish', 'segment', 'tick']);
});

test('Linux passes the name to notify-send after --, plays freedesktop sounds with paplay, and honours sound off', async () => {
  for (const name of INJECTION_NAMES) {
    const { spawn, calls } = recordingSpawn();
    const sink = createLinuxSink({ notifySend: '/usr/bin/notify-send', paplay: '/usr/bin/paplay', spawn });
    await sink.alert({ timerId: 't_ab12cd34', kind: 'finish', at }, timer(name));
    // The sounds and the notification run side by side; each tool gets exactly these arguments.
    const argsOf = (command) => calls.filter((call) => call.command === command).map((call) => call.args);
    assert.deepEqual(argsOf('/usr/bin/notify-send'), [['--app-name=Timer', '--', name, 'Finished.']], name);
    assert.deepEqual(argsOf('/usr/bin/paplay'), LINUX_SOUNDS.finish.map((sound) => [sound]), name);
    assert.equal(calls.length, 4);
    assert.ok(calls.every((call) => call.options.shell === false));
  }
  const quiet = recordingSpawn();
  await createLinuxSink({ notifySend: '/usr/bin/notify-send', paplay: '/usr/bin/paplay', spawn: quiet.spawn }).alert({ timerId: 't_ab12cd34', kind: 'tick', at, secondsLeft: 2 }, timer('Tea', false));
  assert.deepEqual(quiet.calls, []);
  // A missing sound file is skipped; only notify-send is found here.
  const partial = recordingSpawn();
  const sink = createLinuxSink({ notifySend: '/usr/bin/notify-send', spawn: partial.spawn, soundExists: () => false });
  assert.equal(sink.name, 'linux (notify-send)');
  await sink.alert({ timerId: 't_ab12cd34', kind: 'segment', at, segment: { label: 'Work' } }, timer('Tea'));
  assert.deepEqual(partial.calls, []);
});

test('a sink rejects when its tool fails, and stops one that runs too long', async (t) => {
  const failing = recordingSpawn({ code: 1 });
  await assert.rejects(createMacosSink({ spawn: failing.spawn }).alert({ timerId: 't_ab12cd34', kind: 'tick', at, secondsLeft: 1 }, timer('Tea')), /afplay exited with code 1/);
  const missing = recordingSpawn({ error: Object.assign(new Error('spawn ENOENT'), { code: 'ENOENT' }) });
  await assert.rejects(createMacosSink({ spawn: missing.spawn }).alert({ timerId: 't_ab12cd34', kind: 'finish', at }, timer('Tea')), /ENOENT/);

  t.mock.timers.enable({ apis: ['setTimeout'] });
  let killed = null;
  const hanging = (command, args, options) => {
    const child = new EventEmitter();
    child.kill = (signal) => {
      killed = { command, signal, shell: options.shell };
    };
    return child;
  };
  const pending = createMacosSink({ spawn: hanging }).alert({ timerId: 't_ab12cd34', kind: 'tick', at, secondsLeft: 1 }, timer('Tea'));
  t.mock.timers.tick(ALERT_PROCESS_TIMEOUT_MS);
  await assert.rejects(pending, /did not finish within 10 s/);
  assert.deepEqual(killed, { command: AFPLAY, signal: 'SIGKILL', shell: false });
});

test('the silent sink is selected when the tools are absent, and SUBSET_TIMER_ALERTS=off silences any platform', async () => {
  const none = () => false;
  const all = () => true;
  const { spawn, calls } = recordingSpawn();
  const env = { PATH: '/usr/local/bin:/usr/bin:relative/bin' };

  for (const [platform, executable] of [['darwin', none], ['linux', none], ['win32', all], ['freebsd', all]]) {
    const sink = selectSink({ platform, env, spawn, executable });
    assert.equal(sink.name, 'unavailable', platform);
    await sink.alert({ timerId: 't_ab12cd34', kind: 'finish', at }, timer('Tea'));
  }
  // macOS needs both afplay and osascript.
  assert.equal(selectSink({ platform: 'darwin', env, spawn, executable: (path) => path === AFPLAY }).name, 'unavailable');
  assert.equal(selectSink({ platform: 'darwin', env, spawn, executable: all }).name, 'macos');
  assert.equal(selectSink({ platform: 'linux', env, spawn, executable: all, soundExists: all }).name, 'linux (notify-send, paplay)');
  const paplayOnly = (path) => path === '/usr/bin/paplay';
  assert.equal(selectSink({ platform: 'linux', env, spawn, executable: paplayOnly, soundExists: (path) => path.endsWith('/complete.oga') }).name, 'linux (paplay)');
  // paplay with none of the freedesktop sounds to play cannot alert.
  assert.equal(selectSink({ platform: 'linux', env, spawn, executable: paplayOnly, soundExists: none }).name, 'unavailable');
  assert.equal(selectSink({ platform: 'linux', env, spawn, executable: all, soundExists: none }).name, 'linux (notify-send)');
  for (const platform of ['darwin', 'linux']) assert.equal(selectSink({ platform, env: { ...env, SUBSET_TIMER_ALERTS: 'off' }, spawn, executable: all }).name, 'off');
  assert.deepEqual(calls, []);

  // Only absolute PATH directories are searched, in order.
  const seen = [];
  assert.equal(findOnPath('paplay', env, (path) => {
    seen.push(path);
    return false;
  }), null);
  assert.deepEqual(seen, ['/usr/local/bin/paplay', '/usr/bin/paplay']);
  assert.equal(createSilentSink().name, 'unavailable');
});
