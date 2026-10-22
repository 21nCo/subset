import assert from 'node:assert/strict';
import { execFile, execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import test from 'node:test';
import { pidAlive } from '../../src/daemon/index.mjs';
import { eventually, tempDataDir } from '../daemon/helpers.mjs';
import { PACKAGE_ROOT } from './helpers.mjs';

// The package test script builds dist/cli.mjs first.
const CLI = join(PACKAGE_ROOT, 'dist/cli.mjs');
const manifest = JSON.parse(readFileSync(join(PACKAGE_ROOT, 'package.json'), 'utf8'));

function cli(dataDir, ...argv) {
  const result = spawnSync(process.execPath, [CLI, ...argv], {
    env: { ...process.env, SUBSET_TIMER_DATA_DIR: dataDir, SUBSET_TIMER_ALERTS: 'off' },
    encoding: 'utf8',
    timeout: 20_000
  });
  return { code: result.status, stdout: result.stdout, stderr: result.stderr, json: () => JSON.parse(result.stdout) };
}

test('the manifest is ready to publish as @subset.dev/timer 0.1.0 with the subset-timer bin', () => {
  assert.deepEqual(
    { name: manifest.name, version: manifest.version, private: manifest.private, bin: manifest.bin, files: manifest.files, engines: manifest.engines },
    { name: '@subset.dev/timer', version: '0.1.0', private: false, bin: { 'subset-timer': 'dist/cli.mjs' }, files: ['dist', 'web', 'mcp-app', 'skills', 'README.md'], engines: { node: '>=22.13' } }
  );
  // Workspaces are bundled, so nothing installs at runtime.
  assert.equal(manifest.dependencies, undefined);
  const releases = JSON.parse(readFileSync(join(PACKAGE_ROOT, '../../release-packages.json'), 'utf8'));
  assert.deepEqual(releases.find((entry) => entry.slug === 'timer'), { slug: 'timer', path: 'packages/timer-cli', name: '@subset.dev/timer', inputs: ['packages/timer-cli', 'packages/timer', 'apps/timer'] });
});

test('the bundle is executable, imports only Node built-ins and its own chunks, and prints its version', () => {
  const source = readFileSync(CLI, 'utf8');
  assert.ok(source.startsWith('#!/usr/bin/env node\n'));
  assert.equal(statSync(CLI).mode & 0o111, 0o111);
  // Code lines only: a JSDoc type such as import('@subset/timer').TimerDefinition is not an import.
  const imports = (file) => {
    const code = readFileSync(join(PACKAGE_ROOT, 'dist', file), 'utf8').split('\n').filter((line) => !/^\s*(?:\*|\/\/)/.test(line)).join('\n');
    return [...code.matchAll(/(?:\bfrom|\bimport\()\s*["']([^"']+)["']/g)].map((match) => match[1]);
  };
  assert.ok(imports('cli.mjs').includes('node:child_process'));
  // `subset-timer mcp` alone loads the MCP server and @mcpfn/core.
  assert.deepEqual(imports('cli.mjs').filter((specifier) => !specifier.startsWith('node:')).sort(), ['./common.mjs', './mcp-server.mjs']);
  assert.ok(!readFileSync(join(PACKAGE_ROOT, 'dist/common.mjs'), 'utf8').includes('@modelcontextprotocol'));
  // Relative specifiers in the chunks are the chunks themselves, or JSDoc types kept from bundled packages.
  for (const file of ['common.mjs', 'mcp-server.mjs']) {
    assert.deepEqual(imports(file).filter((specifier) => !/^(?:node:|\.)/.test(specifier)), [], file);
  }
  assert.equal(execFileSync(process.execPath, [CLI, '--version'], { encoding: 'utf8' }), '0.1.0\n');
  // The bundled skill path is the package's own skills folder.
  assert.equal(execFileSync(process.execPath, [CLI, 'skill', 'path'], { encoding: 'utf8' }), `${join(PACKAGE_ROOT, 'skills', 'subset-timer')}\n`);
});

const RUNTIME = join(PACKAGE_ROOT, 'app-runtime');
const GENERATIONS = join(PACKAGE_ROOT, '.app-runtime');
const stage = (nodeArgs = []) => spawnSync(process.execPath, [...nodeArgs, join(PACKAGE_ROOT, 'scripts/build.mjs'), '--stage-app-runtime'], { encoding: 'utf8' });
// Stands for a build interrupted at the moment it publishes its generation.
const KILL_AT_PUBLISH = ['--import', `data:text/javascript,${encodeURIComponent('import fs from "node:fs/promises"; import { syncBuiltinESMExports } from "node:module"; const { rename } = fs; fs.rename = (from, to) => (String(to).endsWith("app-runtime") ? process.kill(process.pid, "SIGKILL") : rename(from, to)); syncBuiltinESMExports();')}`];
const assertComplete = (runtime) => {
  const listing = (folder) => readdirSync(folder, { recursive: true }).sort();
  assert.deepEqual(readdirSync(runtime).sort(), ['dist', 'mcp-app', 'skills', 'web']);
  for (const folder of ['dist', 'web', 'mcp-app', 'skills']) assert.deepEqual(listing(join(runtime, folder)), listing(join(PACKAGE_ROOT, folder)), folder);
  assert.equal(readFileSync(join(runtime, 'dist/cli.mjs'), 'utf8'), readFileSync(CLI, 'utf8'));
};

test('the build stages app-runtime, a link to the generation the macOS app embeds, with the same dist, web, mcp-app and skills', () => {
  const generation = readlinkSync(RUNTIME);
  assert.match(generation, /^\.app-runtime\/\d+-\d+$/);
  assertComplete(RUNTIME);
  // The embedded CLI finds its skill inside the runtime, as it does inside an installed package.
  assert.equal(execFileSync(process.execPath, [join(RUNTIME, 'dist/cli.mjs'), 'skill', 'path'], { encoding: 'utf8' }), `${join(PACKAGE_ROOT, generation, 'skills', 'subset-timer')}\n`);
  assert.deepEqual(readdirSync(GENERATIONS), [basename(generation)]);
});

test('staging app-runtime removes what interrupted builds left behind, and keeps a running build\'s generation', (t) => {
  const previous = readlinkSync(RUNTIME);
  // Named for this test's own process, it stands for another build still staging.
  const live = join(GENERATIONS, `${process.pid}-1`);
  t.after(() => rmSync(live, { recursive: true, force: true }));
  for (const folder of [join(GENERATIONS, '999999999-1'), live]) {
    mkdirSync(join(folder, 'dist'), { recursive: true });
    writeFileSync(join(folder, 'dist/cli.mjs'), 'partial');
  }
  symlinkSync('.app-runtime/999999999-1', join(GENERATIONS, '999999999-1.link'));
  assert.equal(stage().status, 0);
  const current = readlinkSync(RUNTIME);
  assert.notEqual(current, previous);
  assert.deepEqual(readdirSync(GENERATIONS).sort(), [basename(current), `${process.pid}-1`].sort());
  assert.equal(readFileSync(join(live, 'dist/cli.mjs'), 'utf8'), 'partial');
  assertComplete(RUNTIME);
});

test('a build interrupted while publishing leaves app-runtime on the previous complete generation', () => {
  const previous = readlinkSync(RUNTIME);
  assert.equal(stage(KILL_AT_PUBLISH).signal, 'SIGKILL');
  assert.equal(readlinkSync(RUNTIME), previous);
  assertComplete(RUNTIME);
  assert.equal(readdirSync(GENERATIONS).length, 3); // the previous generation, and the interrupted one with its link
  assert.equal(stage().status, 0);
  assert.deepEqual(readdirSync(GENERATIONS), [basename(readlinkSync(RUNTIME))]);
});

test('overlapping builds each publish a complete generation and none fails', async () => {
  const runs = Array.from({ length: 4 }, () => new Promise((resolve) => execFile(process.execPath, [join(PACKAGE_ROOT, 'scripts/build.mjs'), '--stage-app-runtime'], (error) => resolve(error))));
  assert.deepEqual(await Promise.all(runs), [null, null, null, null]);
  assertComplete(RUNTIME);
  // A replaced generation whose build was still running when the last one finished goes with the next build.
  assert.equal(stage().status, 0);
  assert.deepEqual(readdirSync(GENERATIONS), [basename(readlinkSync(RUNTIME))]);
});

test('the Embed Timer CLI phase copies a complete runtime while builds publish and are interrupted during the copy', { skip: process.platform !== 'darwin' && 'ditto is macOS only' }, (t) => {
  const generator = readFileSync(join(PACKAGE_ROOT, '../../native/timer/ProjectGenerator.rb'), 'utf8');
  const script = /embed\.shell_script = <<~'SH'\n([\s\S]*?)\nSH\n/.exec(generator)[1].replace(/^ {2}/gm, '');
  const temp = mkdtempSync(join(tmpdir(), 'timer-embed-'));
  t.after(() => rmSync(temp, { recursive: true, force: true }));
  // The first copy starts after one build published a newer generation (removing the one the phase read) and another
  // was interrupted while publishing.
  const marker = join(temp, 'published');
  const build = [process.execPath, join(PACKAGE_ROOT, 'scripts/build.mjs'), '--stage-app-runtime'].map((arg) => `'${arg}'`).join(' ');
  mkdirSync(join(temp, 'bin'));
  writeFileSync(join(temp, 'bin/ditto'), `#!/bin/sh\nif [ ! -e '${marker}' ]; then touch '${marker}'; ${build}; NODE_OPTIONS='${KILL_AT_PUBLISH.join(' ')}' ${build}; fi\nexec /usr/bin/ditto "$@"\n`, { mode: 0o755 });
  const result = spawnSync('/bin/sh', ['-c', script], {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${join(temp, 'bin')}:${process.env.PATH}`, SRCROOT: join(PACKAGE_ROOT, '../../native/timer'), TARGET_BUILD_DIR: temp, UNLOCALIZED_RESOURCES_FOLDER_PATH: 'Resources', CONFIGURATION: 'Release' }
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assertComplete(join(temp, 'Resources/timer-cli'));
});

test('dist/THIRD_PARTY_NOTICES.md carries the licence of every bundled package', () => {
  const notices = readFileSync(join(PACKAGE_ROOT, 'dist/THIRD_PARTY_NOTICES.md'), 'utf8');
  const headings = [...notices.matchAll(/^## (\S+) \S+ \((.+)\)$/gm)].map(([, name, licence]) => `${name} ${licence}`);
  for (const expected of ['zod MIT', '@mcpfn/core MIT', '@modelcontextprotocol/sdk MIT', 'ajv MIT', 'ajv-formats MIT', '@cfworker/json-schema MIT', 'fast-uri BSD-3-Clause']) {
    assert.ok(headings.includes(expected), `${expected} in ${headings.join(', ')}`);
  }
  // The licence texts themselves, with BSD-3-Clause's conditions for fast-uri.
  assert.match(notices, /Permission is hereby granted, free of charge/);
  assert.match(notices, /Redistributions of source code must retain the above copyright\s+notice/);
});

test('npm pack ships dist/ (the CLI, its MCP server, their common chunk and the third-party notices), the built board and its MCP App view, the skill and the README, and no sources or tests', () => {
  // prepack's check accepts the bundle it built (it throws, failing the test, when it refuses).
  execFileSync(process.execPath, [join(PACKAGE_ROOT, 'scripts/build.mjs'), '--check'], { encoding: 'utf8' });
  const [packed] = JSON.parse(execFileSync('npm', ['pack', '--dry-run', '--json', '--ignore-scripts'], { cwd: PACKAGE_ROOT, encoding: 'utf8' }));
  const files = packed.files.map((file) => file.path).sort();
  // The board's assets have hashed names.
  const web = files.filter((file) => file.startsWith('web/'));
  assert.deepEqual(files.filter((file) => !file.startsWith('web/')), ['README.md', 'dist/THIRD_PARTY_NOTICES.md', 'dist/cli.mjs', 'dist/common.mjs', 'dist/mcp-server.mjs', 'mcp-app/board.html', 'package.json', 'skills/subset-timer/SKILL.md']);
  assert.ok(web.includes('web/index.html') && web.includes('web/favicon.svg'), web.join(', '));
  assert.ok(web.every((file) => /^web\/(?:index\.html|favicon\.svg|assets\/index-[\w-]+\.(?:js|css))$/.test(file)), web.join(', '));
  assert.equal(packed.name, '@subset.dev/timer');
  assert.equal(packed.version, '0.1.0');
});

test('the built CLI starts the daemon on first use, reports it, and stops it', async (t) => {
  const dataDir = tempDataDir(t);
  // daemon status never starts one.
  assert.equal(cli(dataDir, 'daemon', 'status', '--json').code, 3);

  const started = cli(dataDir, 'start', '25m', '--name', 'Tea', '--json');
  assert.equal(started.code, 0, started.stderr);
  const id = started.json().timer.definition.id;

  const status = cli(dataDir, 'daemon', 'status', '--json');
  assert.equal(status.code, 0);
  assert.deepEqual({ dataDir: status.json().dataDir, alerts: status.json().alerts }, { dataDir, alerts: 'off' });
  const { pid } = status.json();
  assert.notEqual(pid, process.pid);

  // The timer outlives the command that started it.
  const listed = cli(dataDir, 'list');
  assert.match(listed.stdout, new RegExp(`^Tea \\(${id}\\): running · 2[45]:\\d\\d left\\n$`));

  assert.deepEqual(cli(dataDir, 'daemon', 'stop', '--json').json(), { stopped: true });
  await eventually(() => !pidAlive(pid), 10_000);
  // Timers keep their place and continue when the daemon starts again.
  assert.equal(cli(dataDir, 'status', id, '--json').json().timer.projection.status, 'running');
  cli(dataDir, 'daemon', 'stop');
});
