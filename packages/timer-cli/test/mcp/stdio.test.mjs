import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { join } from 'node:path';
import test from 'node:test';
import { pidAlive, readLock } from '../../src/daemon/index.mjs';
import { PACKAGE_ROOT } from '../cli/helpers.mjs';
import { tempDataDir, within } from '../daemon/helpers.mjs';

// The package test script builds dist/cli.mjs first.
const CLI = join(PACKAGE_ROOT, 'dist/cli.mjs');

/** `subset-timer mcp` as a child process speaking newline-delimited JSON-RPC on its stdin and stdout. */
function startMcp(t, dataDir) {
  const child = spawn(process.execPath, [CLI, 'mcp'], {
    env: { ...process.env, SUBSET_TIMER_DATA_DIR: dataDir, SUBSET_TIMER_ALERTS: 'off' },
    stdio: ['pipe', 'pipe', 'pipe']
  });
  t.after(() => child.exitCode === null && child.kill());
  let stdout = '';
  let stderr = '';
  const frames = [];
  const waiting = new Map();
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    stdout += chunk;
    let end;
    while ((end = stdout.indexOf('\n')) >= 0) {
      const line = stdout.slice(0, end);
      stdout = stdout.slice(end + 1);
      // Every line on stdout must be a protocol frame; anything else fails here.
      const frame = JSON.parse(line);
      frames.push(frame);
      waiting.get(frame.id)?.(frame);
    }
  });
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
  });
  const exited = new Promise((resolve) => child.on('exit', (code, signal) => resolve({ code, signal })));
  let nextId = 0;
  const send = (frame) => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...frame })}\n`);
  const request = (method, params) => {
    const id = ++nextId;
    const reply = new Promise((resolve) => waiting.set(id, resolve));
    send({ id, method, params });
    return within(reply, 15_000, `the reply to ${method}`);
  };
  return { child, frames, exited, send, request, rest: () => stdout, stderr: () => stderr };
}

test('subset-timer mcp speaks MCP on stdio, exits 0 when stdin closes, and leaves the daemon running', async (t) => {
  const dataDir = tempDataDir(t);
  const mcp = startMcp(t, dataDir);
  const init = await mcp.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1.0.0' } });
  assert.deepEqual(init.result.serverInfo, { name: 'subset-timer', version: '0.1.0' });
  assert.ok(init.result.capabilities.tools);
  mcp.send({ method: 'notifications/initialized' });

  const listed = await mcp.request('tools/list', {});
  assert.equal(listed.result.tools.length, 12);

  // The first call starts the daemon.
  const started = await mcp.request('tools/call', { name: 'timer_start', arguments: { durationSeconds: 1500, name: 'Tea' } });
  assert.equal(started.result.isError, undefined, JSON.stringify(started));
  const id = started.result.structuredContent.affectedTimerId;
  assert.match(started.result.content[0].text, new RegExp(`^Started Tea \\(${id}\\)\\. Ends at `));
  const refused = await mcp.request('tools/call', { name: 'timer_pause', arguments: { id: 't_00000000' } });
  assert.deepEqual([refused.result.isError, refused.result.structuredContent.error.code], [true, 'not_found']);

  const { pid } = readLock(join(dataDir, 'daemon.lock'));
  assert.notEqual(pid, mcp.child.pid);

  mcp.child.stdin.end();
  assert.deepEqual(await within(mcp.exited, 10_000, 'the MCP server to exit'), { code: 0, signal: null });
  // stdout held only complete JSON-RPC frames; logs went to stderr.
  assert.equal(mcp.rest(), '');
  assert.deepEqual(mcp.frames.map((frame) => [frame.jsonrpc, frame.id, 'result' in frame]), [1, 2, 3, 4].map((id) => ['2.0', id, true]));
  assert.match(mcp.stderr(), /^subset-timer mcp: 0\.1\.0 serving on stdio$/m);

  // The daemon and the timer outlive the session.
  assert.ok(pidAlive(pid));
  const listedAfter = spawnSync(process.execPath, [CLI, 'list'], { env: { ...process.env, SUBSET_TIMER_DATA_DIR: dataDir }, encoding: 'utf8', timeout: 20_000 });
  assert.match(listedAfter.stdout, new RegExp(`^Tea \\(${id}\\): running · 2[45]:\\d\\d left\\n$`));
});

test('subset-timer mcp exits 0 at once when stdin closes before anything was sent, starting no daemon', async (t) => {
  const dataDir = tempDataDir(t);
  const mcp = startMcp(t, dataDir);
  mcp.child.stdin.end();
  assert.deepEqual(await within(mcp.exited, 10_000, 'the MCP server to exit'), { code: 0, signal: null });
  assert.deepEqual(mcp.frames, []);
  assert.equal(readLock(join(dataDir, 'daemon.lock')), null);
});

test('subset-timer mcp takes no arguments and is listed in --help', () => {
  const extra = spawnSync(process.execPath, [CLI, 'mcp', 'now'], { encoding: 'utf8', timeout: 20_000 });
  assert.equal(extra.status, 2);
  assert.equal(extra.stdout, '');
  const help = spawnSync(process.execPath, [CLI, '--help'], { encoding: 'utf8', timeout: 20_000 });
  assert.match(help.stdout, /^ {2}mcp {2,}Run the MCP server on stdin and stdout/m);
});
