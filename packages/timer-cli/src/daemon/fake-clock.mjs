/**
 * A manual clock and timer source with the shape of `systemClock`, for tests. Like Node's timers,
 * timeouts run on a monotonic timeline, separate from the wall clock `now` returns: `advance`
 * moves both forward and fires each due timeout in order at its own time, while `jump` moves only
 * the wall clock, as a sleeping computer or a changed system clock does.
 */
export function createFakeClock(start = Date.UTC(2026, 0, 1)) {
  let wall = start;
  let monotonic = 0;
  let sequence = 0;
  const pending = new Map();

  function nextDue(limit) {
    let found = null;
    for (const [id, entry] of pending) {
      if (entry.at > limit) continue;
      if (!found || entry.at < found.entry.at || (entry.at === found.entry.at && id < found.id)) found = { id, entry };
    }
    return found;
  }

  function moveTo(target) {
    wall += target - monotonic;
    monotonic = target;
  }

  return {
    now: () => wall,
    setTimeout(callback, ms) {
      const id = ++sequence;
      pending.set(id, { at: monotonic + Math.max(0, Math.floor(Number(ms) || 0)), callback });
      return id;
    },
    clearTimeout(id) {
      pending.delete(id);
    },
    advance(ms) {
      const target = monotonic + ms;
      for (let due = nextDue(target); due; due = nextDue(target)) {
        pending.delete(due.id);
        moveTo(Math.max(monotonic, due.entry.at));
        due.entry.callback();
      }
      moveTo(target);
    },
    jump(ms) {
      wall += ms;
    },
    get pendingCount() {
      return pending.size;
    }
  };
}
