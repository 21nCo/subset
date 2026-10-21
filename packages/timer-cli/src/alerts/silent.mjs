/**
 * The sink for a platform without the sound and notification tools, or when alerts are turned off:
 * it plays and shows nothing. `daemon status` reports its name, `unavailable` by default.
 */
export function createSilentSink({ name = 'unavailable' } = {}) {
  return { name, alert() {} };
}
