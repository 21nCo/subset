import { defaultSpawn, notificationFor, playParts, runProcess } from './process.mjs';

export const AFPLAY = '/usr/bin/afplay';
export const OSASCRIPT = '/usr/bin/osascript';

/** Only these built-in system sounds are played; no path comes from a timer or a user. */
export const MACOS_SOUNDS = {
  tick: ['/System/Library/Sounds/Tink.aiff'],
  segment: ['/System/Library/Sounds/Pop.aiff'],
  finish: ['/System/Library/Sounds/Glass.aiff', '/System/Library/Sounds/Glass.aiff', '/System/Library/Sounds/Glass.aiff']
};

/**
 * The fixed AppleScript. The title and body arrive only as `argv` of `on run argv`, after `--`, so
 * a timer name is never part of the script text and never read as an osascript option.
 */
export const NOTIFY_SCRIPT = ['on run argv', 'display notification (item 2 of argv) with title (item 1 of argv)', 'end run'];

export function osascriptArgs(title, body) {
  return [...NOTIFY_SCRIPT.flatMap((line) => ['-e', line]), '--', title, body];
}

/**
 * The macOS sink: `afplay` plays a built-in sound for ticks (Tink), steps (Pop) and the finish
 * (Glass three times) when the timer's `sound` is on, and `osascript` posts a notification for the
 * finish and for alerts missed while away. It plays only the parts not in `progress.played`.
 */
export function createMacosSink({ spawn = defaultSpawn } = {}) {
  return {
    name: 'macos',
    async alert(alert, timer, progress) {
      const notification = notificationFor(alert, timer);
      await playParts(
        {
          sounds: timer.sound === false ? [] : (MACOS_SOUNDS[alert.kind] ?? []),
          playSound: (path, onStart) => runProcess(spawn, AFPLAY, [path], onStart),
          notify: notification && ((onStart) => runProcess(spawn, OSASCRIPT, osascriptArgs(notification.title, notification.body), onStart))
        },
        progress
      );
    }
  };
}
