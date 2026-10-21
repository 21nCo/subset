import { spawn as nodeSpawn } from 'node:child_process';

/** How long a sound or notification process may run before it is stopped. */
export const ALERT_PROCESS_TIMEOUT_MS = 10_000;

/**
 * Runs `command` with an argument array and no shell, so nothing in `args` is ever parsed as shell
 * or script text. Resolves when it exits 0; rejects when it cannot start, fails or times out.
 */
export function runProcess(spawn, command, args) {
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(command, args, { stdio: 'ignore', shell: false, windowsHide: true });
    } catch (error) {
      reject(error);
      return;
    }
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

/** Plays `sounds` one after another, each with `play(path)`. */
export async function playInOrder(play, sounds) {
  for (const sound of sounds) await play(sound);
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
