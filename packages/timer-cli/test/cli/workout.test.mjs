import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { HELP } from '../../src/commands/index.mjs';
import { WORKOUT_FILE_LIMIT } from '../../src/commands/workout.mjs';
import { cliDaemon } from './helpers.mjs';

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
  writeFileSync(path, typeof body === 'string' ? body : JSON.stringify(body));
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
  assert.match(human.stdout, /^Text \(t_[0-9a-z]{8}\): running · segment 1\/3 · work \(Squats\) · 0:40 left · next rest 0:20\nEnds at /);
});

test('start --file runs a 30-step workout from a file or stdin', async (t) => {
  const { run, client } = await cliDaemon(t);
  const dir = workDir(t);
  const workout = { name: '15 min standing HIIT', prep: '10s', rest: 20, steps: EXERCISES.map((label) => ({ label, duration: '40s' })) };
  const path = writeWorkout(dir, 'hiit.json', workout);

  const result = await run(['start', '--file', path, '--json']);
  assert.equal(result.code, 0, result.stdout);
  const { definition, projection } = result.json().timer;
  assert.equal(definition.name, '15 min standing HIIT');
  assert.equal(definition.segments.length, 29);
  assert.deepEqual(definition.segments.slice(0, 3), [work('Jumping jacks', 40_000), rest(20_000), work('Squats', 40_000)]);
  assert.deepEqual(definition.segments.at(-1), work('Burpees (no push-up)', 40_000));
  assert.deepEqual([definition.rounds, definition.prepMs, definition.sound], [1, 10_000, true]);
  assert.equal(projection.status, 'running');
  const listed = (await client.timers()).body.structuredContent.timers.find((timer) => timer.definition.id === definition.id);
  assert.ok(listed);

  // A relative path is read from the working directory; --name and --no-sound override the file.
  const relative = await run(['start', '--file', 'hiit.json', '--name', 'Morning', '--no-sound', '--json'], { cwd: dir });
  assert.equal(relative.code, 0, relative.stdout);
  assert.deepEqual([relative.json().timer.definition.name, relative.json().timer.definition.sound], ['Morning', false]);

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
    [['start', '--file', writeWorkout(dir, 'name.json', { name: 'two\nlines', steps: [{ label: 'A', duration: '1m' }] })], 'name', /single line/]
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

  const plain = [
    [['start', 'interval', '--step', 'A:40s', '--work', '40s'], /--step cannot be combined with --work/],
    [['start', '--file', join(dir, 'missing.json')], /cannot read .*ENOENT/],
    [['start', '--file', dir], /is not a file/],
    [['start', '--file', writeWorkout(dir, 'broken.json', '{"steps": [')], /not valid JSON/],
    [['start', '--file', writeWorkout(dir, 'large.json', ' '.repeat(WORKOUT_FILE_LIMIT + 1))], /larger than 1 MiB/],
    [['start', 'tabata', '--file', join(dir, 'empty.json')], /--file takes the whole workout/],
    [['start', '--file', join(dir, 'empty.json'), '--rest', '10s'], /--file takes the whole workout/],
    [['start', '--file', join(dir, 'empty.json'), '--until', '17:30'], /--file takes the whole workout/],
    [['start', '--step', 'A:40s'], /--step applies only to start interval/],
    [['preset', 'save', 'X', '--file', join(dir, 'empty.json'), '--step', 'A:1m'], /--file takes the whole workout; use it without --step/]
  ];
  for (const [argv, message] of plain) {
    const result = await run([...argv, '--json']);
    assert.equal(result.code, 2, `${argv.join(' ')}: ${result.stdout}`);
    assert.match(result.json().error.message, message, argv.join(' '));
  }
  const piped = await run(['start', '--file', '-', '--json'], { readStdin: async () => 'x'.repeat(WORKOUT_FILE_LIMIT + 1) });
  assert.match(piped.json().error.message, /stdin is larger than 1 MiB/);

  // A symbolic link to a workout file is read like the file itself.
  const link = join(dir, 'link.json');
  symlinkSync(writeWorkout(dir, 'target.json', { steps: [{ label: 'Linked', duration: '1m' }] }), link);
  assert.equal((await run(['start', '--file', link, '--json'])).code, 0);

  assert.equal((await client.timers()).body.structuredContent.timers.length, before + 1);
});

test('--help lists --step and --file', () => {
  assert.match(HELP, /interval --step "Squats:40s"/);
  assert.match(HELP, /--file <path\|->/);
  assert.match(HELP, /preset save <name> .*--step/);
});
