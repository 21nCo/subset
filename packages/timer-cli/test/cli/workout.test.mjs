import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import test from 'node:test';
import { HELP } from '../../src/commands/index.mjs';
import { WORKOUT_FILE_LIMIT, readStream, stdinReader } from '../../src/commands/workout.mjs';
import { PACKAGE_ROOT, cliDaemon } from './helpers.mjs';

process.env.TZ = 'UTC';

const EXERCISES = ['Jumping jacks', 'Squats', 'High knees', 'Lunges', 'Butt kicks', 'Side lunges', 'Skaters', 'Squat pulses',
  'Mountain climbers (standing)', 'Jump squats', 'Cross jacks', 'Calf raises', 'Speed skaters', 'Squat hold', 'Burpees (no push-up)'];

function workDir(t) {
  const dir = mkdtempSync(join(tmpdir(), 'timer-workout-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function writeWorkout(dir, name, body) {
  const path = join(dir, name);
  writeFileSync(path, typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
  return path;
}

const work = (label, durationMs) => ({ label, phase: 'work', durationMs });
const rest = (durationMs) => ({ label: 'Rest', phase: 'rest', durationMs });

test('start interval --step makes labelled steps, with --rest between them and one round by default', async (t) => {
  const { run } = await cliDaemon(t);
  const result = await run(['start', 'interval', '--step', 'Squats:40s', '--step', 'Plank: hold:1:30', '--step', '  Lunges  :45s', '--rest', '20s', '--prep', '10s', '--name', 'Legs', '--json']);
  assert.equal(result.code, 0, result.stdout);
  const { definition } = result.json().timer;
  assert.deepEqual(definition.segments, [work('Squats', 40_000), rest(20_000), work('Plank: hold', 90_000), rest(20_000), work('Lunges', 45_000)]);
  assert.deepEqual([definition.name, definition.rounds, definition.prepMs, definition.cooldownMs], ['Legs', 1, 10_000, undefined]);

  const noRest = (await run(['start', 'interval', '--step', 'A:10s', '--step', 'B:20s', '--rounds', '3', '--cooldown', '1m', '--json'])).json().timer.definition;
  assert.deepEqual([noRest.segments, noRest.rounds, noRest.cooldownMs], [[work('A', 10_000), work('B', 20_000)], 3, 60_000]);

  const human = await run(['start', 'interval', '--step', 'Squats:40s', '--step', 'Lunges:40s', '--rest', '20s', '--name', 'Text']);
  assert.equal(human.code, 0);
  assert.match(human.stdout, /^Text \(t_[0-9a-z]{8}\): running · Squats · step 1\/3 · 0:40 left · next rest 0:20\nEnds at /);
});

test('start --file runs a 30-step workout from a file or stdin', async (t) => {
  const { run, client, clock } = await cliDaemon(t);
  const dir = workDir(t);
  // 15 moves of 40 s with a 20 s rest after each but the last, then a one-minute stretch: 30 steps in one round.
  const steps = EXERCISES.flatMap((label, index) => [{ label, duration: '40s' }, ...(index < EXERCISES.length - 1 ? [{ label: 'Rest', duration: 20, phase: 'rest' }] : [])]);
  steps.push({ label: 'Stretch', duration: '1:00', phase: 'cooldown' });
  const path = writeWorkout(dir, 'hiit.json', { name: '15 min standing HIIT', prep: '10s', steps });

  const result = await run(['start', '--file', path, '--json']);
  assert.equal(result.code, 0, result.stdout);
  const { definition, projection } = result.json().timer;
  assert.equal(definition.name, '15 min standing HIIT');
  assert.equal(definition.segments.length, 30);
  assert.deepEqual(definition.segments.slice(0, 3), [work('Jumping jacks', 40_000), rest(20_000), work('Squats', 40_000)]);
  assert.deepEqual(definition.segments.slice(-2), [work('Burpees (no push-up)', 40_000), { label: 'Stretch', phase: 'cooldown', durationMs: 60_000 }]);
  assert.deepEqual([definition.rounds, definition.prepMs, definition.cooldownMs, definition.sound], [1, 10_000, undefined, true]);
  assert.equal(projection.status, 'running');

  // The daemon's agent text names each step by its label and its place among the 30.
  const line = async () => (await client.timers()).body.text.split('\n').find((entry) => entry.includes(`(${definition.id})`));
  const head = `15 min standing HIIT (${definition.id}): running · `;
  assert.equal(await line(), `${head}prep · 0:10 left · next Jumping jacks 0:40`);
  clock.advance(38_000);
  assert.equal(await line(), `${head}Jumping jacks · step 1/30 · 0:12 left · next rest 0:20`);
  clock.advance(20_000);
  assert.equal(await line(), `${head}rest · step 2/30 · 0:12 left · next Squats 0:40`);
  // The stretch starts after 10 s of prep, 15 moves and 14 rests: at 890 s.
  clock.advance(905_000 - 58_000);
  assert.equal(await line(), `${head}Stretch · step 30/30 · 0:45 left`);
  // `status` prints the same line, and when the workout ends: 950 s after it started at 09:00.
  assert.equal((await run(['status', definition.id])).stdout, `${await line()}\nEnds at 09:15:50.\n`);

  // `rest` in the file goes between steps only; a relative path is read from the working directory; --name and
  // --no-sound override the file.
  writeWorkout(dir, 'circuit.json', { name: 'Circuit', rest: 20, steps: EXERCISES.map((label) => ({ label, duration: '40s' })) });
  const relative = await run(['start', '--file', 'circuit.json', '--name', 'Morning', '--no-sound', '--json'], { cwd: dir });
  assert.equal(relative.code, 0, relative.stdout);
  const circuit = relative.json().timer.definition;
  assert.deepEqual([circuit.name, circuit.sound, circuit.segments.length], ['Morning', false, 29]);
  assert.deepEqual(circuit.segments.slice(-3), [work('Squat hold', 40_000), rest(20_000), work('Burpees (no push-up)', 40_000)]);

  // stdin, with explicit phases and numbers of seconds.
  const stdin = JSON.stringify({ rounds: 2, sound: false, steps: [{ label: 'Warm up', duration: 60, phase: 'prep' }, { label: 'Row', duration: '2m' }, { label: 'Easy', duration: '1:00', phase: 'rest' }] });
  const piped = await run(['start', '--file', '-', '--json'], { readStdin: async () => stdin });
  assert.equal(piped.code, 0, piped.stdout);
  const pipedDefinition = piped.json().timer.definition;
  assert.deepEqual(pipedDefinition.segments, [{ label: 'Warm up', phase: 'prep', durationMs: 60_000 }, work('Row', 120_000), { label: 'Easy', phase: 'rest', durationMs: 60_000 }]);
  assert.deepEqual([pipedDefinition.rounds, pipedDefinition.sound], [2, false]);
});

test('preset save takes --step flags and workout files', async (t) => {
  const { run } = await cliDaemon(t);
  const dir = workDir(t);
  const steps = await run(['preset', 'save', 'Legs', '--step', 'Squats:40s', '--step', 'Lunges:40s', '--rest', '15s', '--json']);
  assert.equal(steps.code, 0, steps.stdout);
  assert.deepEqual(steps.json().preset.timer, { kind: 'interval', segments: [work('Squats', 40_000), rest(15_000), work('Lunges', 40_000)], rounds: 1 });

  const path = writeWorkout(dir, 'core.json', { name: 'Ignored for presets', rounds: 3, steps: [{ label: 'Plank', duration: '1m' }] });
  const file = await run(['preset', 'save', 'Core', '--file', path, '--no-sound', '--json']);
  assert.equal(file.code, 0, file.stdout);
  assert.deepEqual([file.json().preset.name, file.json().preset.timer], ['Core', { kind: 'interval', segments: [work('Plank', 60_000)], rounds: 3, sound: false }]);

  const listed = await run(['presets']);
  assert.match(listed.stdout, /^Legs \(p_[0-9a-z]{8}\): 1 round of squats 0:40, rest 0:15, lunges 0:40 · 1:35 total$/mi);
  assert.equal((await run(['start', 'core', '--json'])).json().timer.definition.segments[0].label, 'Plank');
});

test('labelled workouts refuse bad input with the step it concerns, and change nothing', async (t) => {
  const { run, client } = await cliDaemon(t);
  const dir = workDir(t);
  const before = (await client.timers()).body.structuredContent.timers.length;
  const tooMany = Array.from({ length: 51 }, (_, index) => ({ label: `Move ${index + 1}`, duration: '30s' }));
  const cases = [
    [['start', 'interval', '--step', 'Squats'], '--step 1', /needs a label and a duration/],
    [['start', 'interval', '--step', ':40s'], '--step 1', /non-empty label/],
    [['start', 'interval', '--step', 'A:40s', '--step', `${'x'.repeat(41)}:40s`], '--step 2', /at most 40 characters/],
    [['start', 'interval', '--step', 'A:40s', '--rounds', '0'], '--rounds', /from 1 to 99/],
    [['start', 'interval', '--step', 'A:40s', '--rounds', 'two'], '--rounds', /not a whole number/],
    [['start', 'interval', '--step', 'A:40s', '--rest', 'soon'], '--rest', /./],
    [['start', '--file', writeWorkout(dir, 'many.json', { rest: '10s', steps: tooMany })], 'steps', /101 steps with its rests; a workout has at most 100/],
    [['start', '--file', writeWorkout(dir, 'unknown.json', { steps: [{ label: 'A', duration: '1m', image: 'a.png' }], colour: 'red' })], 'colour', /not a workout field/],
    [['start', '--file', writeWorkout(dir, 'bad-step.json', { steps: [{ label: 'A', duration: '1m' }, { label: 'B', duration: 0 }] })], 'steps[1].duration', /whole number of seconds/],
    [['start', '--file', writeWorkout(dir, 'no-duration.json', { steps: [{ label: 'A' }] })], 'steps[0].duration', /required/],
    [['start', '--file', writeWorkout(dir, 'phase.json', { steps: [{ label: 'A', duration: '1m', phase: 'sprint' }] })], 'steps[0].phase', /one of prep, work, rest, cooldown/],
    [['start', '--file', writeWorkout(dir, 'empty.json', { steps: [] })], 'steps', /at least one step/],
    [['start', '--file', writeWorkout(dir, 'array.json', [])], '(root)', /JSON object/],
    [['start', '--file', writeWorkout(dir, 'name.json', { name: 'two\nlines', steps: [{ label: 'A', duration: '1m' }] })], 'name', /one line/],
    [['start', 'interval', '--step', 'A:40s', '--step', 'B\tC:40s', '--rest', '10s'], '--step 2', /one line without control/],
    [['start', 'interval', '--step', 'A:40s', '--step', 'B\u202Eevil:40s'], '--step 2', /bidi/],
    [['start', '--file', writeWorkout(dir, 'invisible.json', { rest: 10, steps: [{ label: 'A', duration: 10 }, { label: 'B', duration: 10 }, { label: '\u200B', duration: 10 }] })], 'steps[2].label', /visible character/],
    [['start', '--file', writeWorkout(dir, 'tab-name.json', { name: 'A\tB', steps: [{ label: 'A', duration: 10 }] })], 'name', /control/],
    [['start', '--file', writeWorkout(dir, 'null-phase.json', { steps: [{ label: 'A', duration: 1, phase: null }] })], 'steps[0].phase', /one of prep, work, rest, cooldown/]
  ];
  for (const [argv, path, message] of cases) {
    const result = await run([...argv, '--json']);
    assert.equal(result.code, 2, `${argv.join(' ')}: ${result.stdout}`);
    const { error } = result.json();
    assert.equal(error.code, 'invalid_input', argv.join(' '));
    const issue = error.issues?.find((entry) => entry.path === path);
    assert.ok(issue, `${argv.join(' ')}: no issue at ${path} in ${JSON.stringify(error)}`);
    assert.match(issue.message, message, argv.join(' '));
  }

  // Refusals of a whole flag or file name that flag, or (root) for a file that is not JSON.
  const empty = join(dir, 'empty.json');
  const refusals = [
    [['start', 'interval', '--step', 'A:40s', '--work', '40s'], '--work', /--step cannot be combined with --work/],
    [['start', '--step', 'A:40s'], '--step', /--step applies only to start interval/],
    [['start', 'tabata', '--file', empty], '<spec>', /--file takes the whole workout/],
    [['start', '--file', empty, '--rest', '10s'], '--rest', /--file takes the whole workout/],
    [['start', '--file', empty, '--step', 'A:1m'], '--step', /--file takes the whole workout/],
    [['start', '--file', empty, '--until', '17:30'], '--until', /--file takes the whole workout/],
    [['preset', 'save', 'X', '--file', empty, '--step', 'A:1m'], '--step', /--file takes the whole workout; use it without --step/],
    [['preset', 'save', 'X', '--file', empty, '--work', '1m'], '--work', /--file takes the whole workout; use it without --work/],
    [['preset', 'save', 'X', '--step', 'A:40s', '--work', '1m'], '--work', /--step cannot be combined with --work/],
    [['start', '--file', join(dir, 'missing.json')], '--file', /cannot read .*ENOENT/],
    [['start', '--file', dir], '--file', /is not a file/],
    [['start', '--file', writeWorkout(dir, 'broken.json', '{"steps": [')], '(root)', /^Workout file: not valid JSON/],
    [['preset', 'save', 'X', '--file', join(dir, 'broken.json')], '(root)', /^Workout file: not valid JSON/],
    [['start', '--file', writeWorkout(dir, 'large.json', ' '.repeat(WORKOUT_FILE_LIMIT + 1))], '--file', /large\.json is larger than 1 MiB/],
    [['preset', 'save', 'X', '--file', join(dir, 'large.json')], '--file', /large\.json is larger than 1 MiB/]
  ];
  // A FIFO with no writer is refused at once, not waited on.
  const fifo = join(dir, 'fifo.json');
  execFileSync('mkfifo', [fifo]);
  refusals.push([['start', '--file', fifo], '--file', /fifo\.json is not a file\.$/]);
  // Bytes that are not UTF-8 (a Latin-1 "Café") are refused, not decoded with replacement characters.
  const latin1 = Buffer.from('{"steps": [{"label": "Caf\xe9", "duration": 10}]}', 'latin1');
  const latin1Path = writeWorkout(dir, 'latin1.json', latin1);
  // A stdin that fails partway, as an interrupted read does.
  const failing = () => readStream(new Readable({ read() {
    this.push(Buffer.from('{"steps": ['));
    this.destroy(Object.assign(new Error('read failed'), { code: 'EIO' }));
  } }));
  const stdinRefusals = [
    [['start', '--file', '-'], '--file', /stdin is larger than 1 MiB/, { readStdin: async () => 'x'.repeat(WORKOUT_FILE_LIMIT + 1) }],
    [['preset', 'save', 'X', '--file', '-'], '(root)', /not valid JSON/, { readStdin: async () => 'steps: []' }],
    [['start', '--file', latin1Path], '(root)', /^Workout file: not valid UTF-8\.$/],
    [['preset', 'save', 'X', '--file', latin1Path], '(root)', /^Workout file: not valid UTF-8\.$/],
    [['start', '--file', '-'], '(root)', /not valid UTF-8/, { readStdin: stdinReader(Readable.from([latin1])) }],
    [['preset', 'save', 'X', '--file', '-'], '(root)', /not valid UTF-8/, { readStdin: stdinReader(Readable.from([latin1])) }],
    [['start', '--file', '-'], '--file', /cannot read stdin \(EIO\)/, { readStdin: failing }],
    [['preset', 'save', 'X', '--file', '-'], '--file', /cannot read stdin \(EIO\)/, { readStdin: failing }],
    [['start', '--file', '-'], '--file', /cannot read stdin \(closed\)/, { readStdin: async () => { throw 'closed'; } }],
    // An interactive terminal would wait silently for end of input, so it is refused at once.
    [['start', '--file', '-'], '--file', /--file - needs a workout piped to stdin, not a terminal/, { readStdin: stdinReader({ isTTY: true }) }],
    [['preset', 'save', 'X', '--file', '-'], '--file', /--file - needs a workout piped to stdin, not a terminal/, { readStdin: stdinReader({ isTTY: true }) }]
  ];
  for (const [argv, path, message, io] of [...refusals, ...stdinRefusals]) {
    const result = await run([...argv, '--json'], io);
    assert.equal(result.code, 2, `${argv.join(' ')}: ${result.stdout}`);
    const { error } = result.json();
    assert.equal(error.code, 'invalid_input', argv.join(' '));
    assert.match(error.message, message, argv.join(' '));
    assert.deepEqual(error.issues?.map((issue) => issue.path), [path], `${argv.join(' ')}: ${JSON.stringify(error)}`);
  }

  // A symbolic link to a workout file is read like the file itself.
  const link = join(dir, 'link.json');
  symlinkSync(writeWorkout(dir, 'target.json', { steps: [{ label: 'Linked', duration: '1m' }] }), link);
  assert.equal((await run(['start', '--file', link, '--json'])).code, 0);

  assert.equal((await client.timers()).body.structuredContent.timers.length, before + 1);
  assert.equal((await run(['presets', '--json'])).json().presets.filter((preset) => preset.name === 'X').length, 0);
});

test('workout files and stdin keep UTF-8 labels whole, even split across reads', async (t) => {
  const { run } = await cliDaemon(t);
  const dir = workDir(t);
  const body = Buffer.from(JSON.stringify({ name: 'Übungen', steps: [{ label: 'Café squats', duration: '40s' }, { label: 'Ćwiczenie', duration: 20 }] }));
  const started = await run(['start', '--file', writeWorkout(dir, 'utf8.json', body), '--json']);
  assert.equal(started.code, 0, started.stdout);
  const { definition } = started.json().timer;
  assert.deepEqual([definition.name, ...definition.segments.map((segment) => segment.label)], ['Übungen', 'Café squats', 'Ćwiczenie']);

  // The two bytes of "é" arrive in different chunks.
  const at = body.indexOf(Buffer.from('é')) + 1;
  const saved = await run(['preset', 'save', 'Cafe', '--file', '-', '--json'], { readStdin: stdinReader(Readable.from([body.subarray(0, at), body.subarray(at)])) });
  assert.equal(saved.code, 0, saved.stdout);
  assert.deepEqual(saved.json().preset.timer.segments.map((segment) => segment.label), ['Café squats', 'Ćwiczenie']);
});

test('workout files and stdin may start with a UTF-8 byte order mark, as Windows editors write them', async (t) => {
  const { run } = await cliDaemon(t);
  const dir = workDir(t);
  const bom = Buffer.from([0xef, 0xbb, 0xbf]);
  const body = Buffer.concat([bom, Buffer.from(JSON.stringify({ name: 'Übungen', steps: [{ label: 'Café squats', duration: '40s' }] }))]);
  const path = writeWorkout(dir, 'bom.json', body);
  const labels = (definition) => [definition.name, ...definition.segments.map((segment) => segment.label)];

  const fromFile = await run(['start', '--file', path, '--json']);
  assert.equal(fromFile.code, 0, fromFile.stdout);
  assert.deepEqual(labels(fromFile.json().timer.definition), ['Übungen', 'Café squats']);
  // The mark arrives split across reads.
  const fromStdin = await run(['start', '--file', '-', '--json'], { readStdin: stdinReader(Readable.from([body.subarray(0, 2), body.subarray(2)])) });
  assert.equal(fromStdin.code, 0, fromStdin.stdout);
  assert.deepEqual(labels(fromStdin.json().timer.definition), ['Übungen', 'Café squats']);

  const savedFile = await run(['preset', 'save', 'Bom file', '--file', path, '--json']);
  assert.equal(savedFile.code, 0, savedFile.stdout);
  assert.deepEqual(savedFile.json().preset.timer.segments.map((segment) => segment.label), ['Café squats']);
  const savedStdin = await run(['preset', 'save', 'Bom stdin', '--file', '-', '--json'], { readStdin: stdinReader(Readable.from([body])) });
  assert.equal(savedStdin.code, 0, savedStdin.stdout);
  assert.deepEqual(savedStdin.json().preset.timer.segments.map((segment) => segment.label), ['Café squats']);

  // Only one mark is dropped, and malformed bytes after it are still refused.
  for (const bytes of [Buffer.concat([bom, body]), Buffer.concat([bom, Buffer.from('{"steps": [{"label": "Caf\xe9", "duration": 10}]}', 'latin1')])]) {
    const refused = await run(['start', '--file', writeWorkout(dir, 'bad-bom.json', bytes), '--json']);
    assert.equal(refused.code, 2, refused.stdout);
    assert.deepEqual(refused.json().error.issues.map((issue) => issue.path), ['(root)']);
  }
});

test('the CLI reads a workout from its real stdin', (t) => {
  const dataDir = workDir(t);
  const cli = (input) => spawnSync(process.execPath, [join(PACKAGE_ROOT, 'src/cli.mjs'), 'start', '--file', '-', '--json'],
    { input, encoding: 'utf8', env: { ...process.env, SUBSET_TIMER_DATA_DIR: dataDir, SUBSET_TIMER_ALERTS: 'off' }, timeout: 20_000 });
  // Refused before the daemon is reached, so no daemon starts.
  const unknown = cli(JSON.stringify({ steps: [{ label: 'A', duration: '1m' }], colour: 'red' }));
  assert.equal(unknown.status, 2, unknown.stderr);
  assert.deepEqual(JSON.parse(unknown.stdout).error.issues.map((issue) => issue.path), ['colour']);
  const large = cli(`{"steps": [${' '.repeat(WORKOUT_FILE_LIMIT)}]}`);
  assert.equal(large.status, 2, large.stderr);
  assert.deepEqual(JSON.parse(large.stdout).error, { code: 'invalid_input', message: 'The workout on stdin is larger than 1 MiB.',
    issues: [{ path: '--file', message: 'the workout on stdin is larger than 1 MiB' }] });
});

test('--help lists --step and --file', () => {
  assert.match(HELP, /interval --step "Squats:40s"/);
  assert.match(HELP, /--file <path\|->/);
  assert.match(HELP, /preset save <name> .*--step/);
});
