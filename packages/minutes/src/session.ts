import { mkdir, rm, stat } from 'node:fs/promises';
import {
  createEvent,
  type EndReason,
  type ErrorCode,
  type MinutesEvent,
  type MinutesEventInput,
  type SessionRecord,
  type SessionState,
} from './contract.js';
import { MinutesError, type MeetingDriver, type MeetingPage } from './driver.js';
import { redactUrlsInText, type MeetingLink } from './link.js';
import { createSessionId, reserveRecordingPath } from './paths.js';

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------

const transitions: Record<SessionState, readonly SessionState[]> = {
  launching: ['joining', 'stopping', 'failed'],
  joining: ['in_meeting', 'stopping', 'failed'],
  in_meeting: ['stopping', 'failed'],
  stopping: ['ended', 'failed'],
  ended: [],
  failed: [],
};

export const terminalStates: readonly SessionState[] = ['ended', 'failed'];
export const isTerminal = (state: SessionState) => terminalStates.includes(state);
export const canTransition = (from: SessionState, to: SessionState) => transitions[from].includes(to);

export function transition(from: SessionState, to: SessionState): SessionState {
  if (!canTransition(from, to)) throw new Error(`Invalid Minutes session transition ${from} -> ${to}`);
  return to;
}

// ---------------------------------------------------------------------------
// Session runner
// ---------------------------------------------------------------------------

export interface RunSessionOptions {
  link: MeetingLink;
  displayName: string;
  outputDirectory: string;
  profileDirectory: string;
  driver: MeetingDriver;
  /** Receives every event in order. */
  emit: (event: MinutesEvent) => void;
  /** Receives the session record after each change, for `status`. Failures are ignored. */
  persist?: (record: SessionRecord) => Promise<void> | void;
  /** Aborting asks the session to leave and finalize the recording. */
  signal?: AbortSignal;
  /** Hard stop after this long in the meeting. Defaults to four hours. */
  maxDurationMs?: number;
  sessionId?: string;
  pid?: number;
  now?: () => Date;
}

export interface SessionResult {
  id: string;
  state: 'ended' | 'failed';
  reason: EndReason;
  path: string | null;
  bytes: number | null;
  error: { code: ErrorCode; message: string } | null;
}

export const DEFAULT_MAX_DURATION_MS = 4 * 60 * 60 * 1_000;
export const DEFAULT_DISPLAY_NAME = 'Minutes Notetaker';

class Aborted extends Error {}

function raceAbort<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) {
    work.catch(() => {});
    return Promise.reject(new Aborted());
  }
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(new Aborted());
    signal.addEventListener('abort', onAbort, { once: true });
    work.then(
      (value) => { signal.removeEventListener('abort', onAbort); resolve(value); },
      (error) => { signal.removeEventListener('abort', onAbort); reject(error); },
    );
  }).catch((error) => {
    work.catch(() => {});
    throw error;
  });
}

/** Maps any error to a contract error. URLs in the message are redacted: a browser error can echo the Zoom link with its passcode. */
export function errorDetails(error: unknown): { code: ErrorCode; message: string } {
  if (error instanceof MinutesError) return { code: error.code, message: redactUrlsInText(error.message).slice(0, 2_000) };
  const message = error instanceof Error ? error.message : String(error);
  return { code: 'internal', message: redactUrlsInText(message).slice(0, 2_000) };
}

/** Resolves true if `work` settles successfully within `ms`, false otherwise. */
function settlesWithin(work: Promise<unknown>, ms: number): Promise<boolean> {
  let timer: NodeJS.Timeout | undefined;
  return Promise.race([
    work.then(() => true, () => false),
    new Promise<boolean>((resolve) => { timer = setTimeout(() => resolve(false), ms); }),
  ]).finally(() => clearTimeout(timer));
}

const fileSize = (file: string) => stat(file).then((info) => info.size, () => 0);

/** Runs one bot session from launch to a finalized recording. Never throws; the result and events describe failures. */
export async function runMeetingSession(options: RunSessionOptions): Promise<SessionResult> {
  const now = options.now ?? (() => new Date());
  const id = options.sessionId ?? createSessionId(now());
  const signal = options.signal ?? new AbortController().signal;
  const { link, driver } = options;
  const displayName = options.displayName.trim() || DEFAULT_DISPLAY_NAME;

  const startedAt = now();
  let state: SessionState = 'launching';
  const record: SessionRecord = {
    id,
    pid: options.pid ?? process.pid,
    platform: link.platform,
    meeting: link.redacted,
    state,
    outputPath: null,
    startedAt: startedAt.toISOString(),
    updatedAt: startedAt.toISOString(),
    joinedAt: null,
    endedAt: null,
    endReason: null,
    error: null,
  };

  let persistQueue = Promise.resolve();
  const persist = () => {
    if (!options.persist) return;
    const snapshot = { ...record, error: record.error && { ...record.error } };
    persistQueue = persistQueue.then(() => options.persist?.(snapshot)).catch(() => {});
  };
  const emit = (fields: MinutesEventInput) => options.emit(createEvent(id, fields, now()));
  const status = (message: string) => emit({ type: 'status', message });
  const moveTo = (next: SessionState) => {
    state = transition(state, next);
    record.state = state;
    record.updatedAt = now().toISOString();
    if (next === 'in_meeting') record.joinedAt = record.updatedAt;
    if (isTerminal(next)) record.endedAt = record.updatedAt;
    emit({ type: 'state', state });
    persist();
  };

  emit({ type: 'started', platform: link.platform, meeting: link.redacted, displayName, outputDirectory: options.outputDirectory });
  emit({ type: 'state', state });
  persist();

  // A time limit aborts the wait like a stop request, but ends with its own reason.
  const limit = new AbortController();
  const stop = AbortSignal.any([signal, limit.signal]);
  let timer: NodeJS.Timeout | undefined;

  let page: MeetingPage | undefined;
  let starting: Promise<void> | undefined;
  let capturing = false;
  let bytes: number | null = null;
  let reason: EndReason = 'stopped';
  let failure: { code: ErrorCode; message: string } | null = null;

  try {
    try {
      await mkdir(options.outputDirectory, { recursive: true });
      record.outputPath = await reserveRecordingPath(options.outputDirectory, link.platform, startedAt);
    } catch (error) {
      throw new MinutesError('output_unwritable', `Cannot write to the output folder ${options.outputDirectory}: ${errorDetails(error).message}`);
    }

    const opening = driver.open({ platform: link.platform, profileDirectory: options.profileDirectory, log: status });
    try {
      page = await raceAbort(opening, stop);
    } catch (error) {
      // A stop during launch: close the browser if it finishes opening later.
      opening.then((late) => late.close().catch(() => {}), () => {});
      throw error;
    }
    starting = page.startCapture(record.outputPath);
    await raceAbort(starting, stop);
    capturing = true;
    emit({ type: 'recording', path: record.outputPath });
    persist();

    moveTo('joining');
    await raceAbort(page.join(link, displayName, stop), stop);
    moveTo('in_meeting');
    status('The bot is in the meeting. Recording until the meeting ends or the bot is stopped.');

    timer = setTimeout(() => limit.abort(), options.maxDurationMs ?? DEFAULT_MAX_DURATION_MS);
    const end = await page.waitForEnd(stop);
    reason = end === 'aborted' ? (limit.signal.aborted && !signal.aborted ? 'time_limit' : 'stopped') : end;
  } catch (error) {
    if (error instanceof Aborted || (stop.aborted && !(error instanceof MinutesError))) {
      reason = limit.signal.aborted && !signal.aborted ? 'time_limit' : 'stopped';
    } else {
      failure = errorDetails(error);
      reason = 'failed';
    }
  } finally {
    clearTimeout(timer);
  }

  const reportFailure = (details: { code: ErrorCode; message: string }) => {
    failure = details;
    reason = 'failed';
    emit({ type: 'error', ...details });
    record.error = details;
  };
  if (failure) {
    reportFailure(failure);
  } else {
    moveTo('stopping');
  }
  const shouldLeave = !failure && reason !== 'meeting_ended' && reason !== 'page_closed';

  // A stop that arrived while capture was being installed: let the install finish so its file is closed.
  if (page && starting && !capturing) capturing = await settlesWithin(starting, 10_000);

  // Finalize: flush the recording first, then leave and close.
  if (page && capturing && record.outputPath) {
    try {
      bytes = await page.stopCapture();
      if (bytes > 0) status(`Saved ${bytes} bytes of audio.`);
    } catch (error) {
      // A recording that could not be flushed is not a success; report what is on disk.
      bytes = await fileSize(record.outputPath);
      const details = errorDetails(error);
      reportFailure({ code: 'capture_failed', message: `The recording may be incomplete (${bytes} bytes saved): ${details.message}` });
    }
  }
  if (page) {
    if (shouldLeave) await page.leave().catch(() => {});
    await page.close().catch(() => {});
  }

  // No audio was captured (stopped or failed before recording began): remove the empty reserved file.
  if (record.outputPath && (!capturing || bytes === 0)) {
    await rm(record.outputPath, { force: true }).catch(() => {});
    record.outputPath = null;
    bytes = null;
  }

  record.endReason = reason;
  moveTo(failure ? 'failed' : 'ended');
  const path = record.outputPath;
  emit({ type: 'ended', reason, path, bytes: path ? bytes ?? 0 : null });
  await persistQueue;

  return { id, state: failure ? 'failed' : 'ended', reason, path, bytes: path ? bytes ?? 0 : null, error: failure };
}
