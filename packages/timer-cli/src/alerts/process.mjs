import { spawn as nodeSpawn } from 'node:child_process';

/** How long a sound or notification process may run before it is stopped. */
export const ALERT_PROCESS_TIMEOUT_MS = 10_000;

/**
 * Runs `command` with an argument array and no shell, so nothing in `args` is ever parsed as shell
 * or script text, calling `onStart(child)` once it is spawned. Resolves when it exits 0; rejects when
 * it cannot start, fails or times out.
 */
export function runProcess(spawn, command, args, onStart = () => {}) {
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(command, args, { stdio: 'ignore', shell: false, windowsHide: true });
    } catch (error) {
      reject(error);
      return;
    }
    onStart(child);
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`${command} did not finish within ${ALERT_PROCESS_TIMEOUT_MS / 1000} s.`));
    }, ALERT_PROCESS_TIMEOUT_MS);
    timer.unref?.();
    child.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once('exit', (code, signal) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(`${command} exited with ${signal ?? `code ${code}`}.`));
    });
  });
}

/**
 * Plays an alert's parts: `sounds` one after another with `playSound(sound, onStart)`, as
 * `sound:<index>`, and beside them `notify(onStart)`, as `notification`, when given. Parts in
 * `progress.played` are skipped; `progress.started(part, pid)` is called once the process playing a
 * part is spawned (`onStart(child)`), and `progress.done(part)` as each part ends, so a daemon that
 * ends mid-play leaves the next one only what had not finished, and the processes still playing. A
 * part that fails stops the sounds after it; once every part has ended, the first failure is thrown.
 */
export async function playParts({ sounds = [], playSound, notify = null }, { played = new Set(), started = () => {}, done = () => {} } = {}) {
  const tasks = [];
  const onStart = (part) => (child) => started(part, child?.pid);
  const remaining = sounds.map((sound, index) => ({ sound, part: `sound:${index}` })).filter(({ part }) => !played.has(part));
  if (remaining.length) {
    tasks.push(
      (async () => {
        for (const { sound, part } of remaining) {
          await playSound(sound, onStart(part));
          done(part);
        }
      })()
    );
  }
  if (notify && !played.has('notification')) tasks.push(notify(onStart('notification')).then(() => done('notification')));
  const failed = (await Promise.allSettled(tasks)).find((outcome) => outcome.status === 'rejected');
  if (failed) throw failed.reason;
}

export const defaultSpawn = nodeSpawn;

const plural = (count, noun) => `${count} ${noun}${count === 1 ? '' : 's'}`;

/** The notification title and body for a `finish` or `missedWhileAway` alert, or null for the others. */
export function notificationFor(alert, timer) {
  if (alert.kind === 'finish') return { title: timer.name, body: 'Finished.' };
  if (alert.kind === 'missedWhileAway') {
    const now = alert.segment ? ` Now: ${alert.segment.label}.` : '';
    return { title: timer.name, body: `Missed ${plural(alert.missed ?? 1, 'alert')} while away.${now}` };
  }
  return null;
}
