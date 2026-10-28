import { defaultSpawn, notificationFor, playParts, runProcess } from './process.mjs';

const STEREO = '/usr/share/sounds/freedesktop/stereo';
/** Only these freedesktop sound theme files are played; no path comes from a timer or a user. */
export const LINUX_SOUNDS = {
  tick: [`${STEREO}/audio-volume-change.oga`],
  segment: [`${STEREO}/message.oga`],
  finish: [`${STEREO}/complete.oga`, `${STEREO}/complete.oga`, `${STEREO}/complete.oga`]
};

export function notifySendArgs(title, body) {
  return ['--app-name=Timer', '--', title, body];
}

/**
 * The Linux sink, given the absolute paths of the tools found on `PATH` (either may be null):
 * `paplay` plays a freedesktop sound when the timer's `sound` is on and the file exists, and
 * `notify-send` posts a notification for the finish and for alerts missed while away. It plays
 * only the parts not in `progress.played`.
 */
export function createLinuxSink({ notifySend = null, paplay = null, spawn = defaultSpawn, soundExists = () => true } = {}) {
  return {
    name: `linux (${[notifySend && 'notify-send', paplay && 'paplay'].filter(Boolean).join(', ')})`,
    async alert(alert, timer, progress) {
      const notification = notifySend && notificationFor(alert, timer);
      await playParts(
        {
          sounds: paplay && timer.sound !== false ? (LINUX_SOUNDS[alert.kind]?.filter((path) => soundExists(path)) ?? []) : [],
          playSound: (path) => runProcess(spawn, paplay, [path]),
          notify: notification && (() => runProcess(spawn, notifySend, notifySendArgs(notification.title, notification.body)))
        },
        progress
      );
    }
  };
}
