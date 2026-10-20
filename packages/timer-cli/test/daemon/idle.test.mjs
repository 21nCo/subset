import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import test from 'node:test';
import { IDLE_EXIT_MS } from '../../src/daemon/index.mjs';
import { eventually, startTestDaemon, subscribe } from './helpers.mjs';

function settled(promise) {
  let done = false;
  promise.then(() => {
    done = true;
  });
  return () => done;
}

test('with nothing running and no subscriber the daemon exits 0 after 10 minutes, removing its socket and lock', async (t) => {
  const { daemon, clock, op } = await startTestDaemon(t);
  assert.equal(IDLE_EXIT_MS, 10 * 60_000);
  // An idle or finished timer does not keep the daemon alive.
  await op('create', { timer: { kind: 'stopwatch' } });
  const exited = settled(daemon.closed);
  clock.advance(IDLE_EXIT_MS - 1);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(exited(), false);
  clock.advance(1);
  assert.equal(await daemon.closed, 0);
  assert.equal(existsSync(daemon.paths.socket), false);
  assert.equal(existsSync(daemon.paths.lock), false);
});

test('an events subscriber cancels the idle exit until it leaves', async (t) => {
  const { daemon, clock } = await startTestDaemon(t);
  const events = subscribe(daemon.paths.socket);
  await events.waitFor((list) => list.length === 1);
  const exited = settled(daemon.closed);
  clock.advance(3 * IDLE_EXIT_MS);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(exited(), false);

  events.close();
  await eventually(() => daemon.subscriberCount === 0);
  clock.advance(IDLE_EXIT_MS - 1);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(exited(), false);
  clock.advance(1);
  assert.equal(await daemon.closed, 0);
});

test('running and paused timers keep the daemon alive; the countdown starts when the last one finishes', async (t) => {
  const { daemon, clock, op } = await startTestDaemon(t);
  const exited = settled(daemon.closed);
  const paused = await op('start', { timer: { kind: 'stopwatch' } });
  await op('pause', { id: paused.body.timer.definition.id });
  await op('start', { timer: { kind: 'countdown', durationMs: 30 * 60_000 } });
  clock.advance(30 * 60_000);
  await op('remove', { id: paused.body.timer.definition.id });
  // The countdown finished at 30 minutes; the removal just now restarted the 10 minutes.
  clock.advance(IDLE_EXIT_MS - 1);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(exited(), false);
  clock.advance(1);
  assert.equal(await daemon.closed, 0);
});
