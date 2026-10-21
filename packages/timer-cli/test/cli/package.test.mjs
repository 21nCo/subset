import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
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
