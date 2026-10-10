/**
 * The Minutes event and status contract, version 1.
 *
 * `subset-minutes join --json` writes one `MinutesEvent` per line on stdout (NDJSON). The macOS app
 * and any agent read the same stream. `status --json` and `doctor --json` print one object each.
 * Every object carries `v`; a reader must reject a `v` it does not know rather than guess.
 *
 * Meeting links are reported only in redacted form (origin and path, no query or fragment), because
 * a Zoom link's `pwd` parameter is a meeting passcode.
 */

export const MINUTES_CONTRACT_VERSION = 1 as const;

export const platforms = ['google-meet', 'zoom'] as const;
export type Platform = (typeof platforms)[number];

export const sessionStates = ['launching', 'joining', 'in_meeting', 'stopping', 'ended', 'failed'] as const;
export type SessionState = (typeof sessionStates)[number];

export const endReasons = ['meeting_ended', 'stopped', 'page_closed', 'time_limit', 'failed'] as const;
export type EndReason = (typeof endReasons)[number];

export const errorCodes = [
  'usage',
  'invalid_link',
  'chrome_not_found',
  'profile_in_use',
  'join_rejected',
  'join_failed',
  'capture_failed',
  'output_unwritable',
  'internal',
] as const;
export type ErrorCode = (typeof errorCodes)[number];

interface EventBase {
  v: typeof MINUTES_CONTRACT_VERSION;
  /** ISO 8601 time the event was emitted. */
  at: string;
  /** Session id, or null when the command failed before a session existed (for example a bad link). */
  session: string | null;
}

export interface StartedEvent extends EventBase {
  type: 'started';
  platform: Platform;
  /** Redacted meeting link: origin and path only. */
  meeting: string;
  displayName: string;
  outputDirectory: string;
}
export interface StateEvent extends EventBase {
  type: 'state';
  state: SessionState;
}
export interface StatusEvent extends EventBase {
  type: 'status';
  message: string;
}
export interface RecordingEvent extends EventBase {
  type: 'recording';
  path: string;
}
export interface ErrorEvent extends EventBase {
  type: 'error';
  code: ErrorCode;
  message: string;
}
export interface EndedEvent extends EventBase {
  type: 'ended';
  reason: EndReason;
  /** The recording file, or null when no file was started. */
  path: string | null;
  /** Bytes written to `path`, or null when no file was started. */
  bytes: number | null;
}

export type MinutesEvent = StartedEvent | StateEvent | StatusEvent | RecordingEvent | ErrorEvent | EndedEvent;
export type MinutesEventType = MinutesEvent['type'];

type Fields<E> = E extends MinutesEvent ? Omit<E, 'v' | 'at' | 'session'> : never;
export type MinutesEventInput = Fields<MinutesEvent>;

export function createEvent(session: string | null, fields: MinutesEventInput, now: Date = new Date()): MinutesEvent {
  return { v: MINUTES_CONTRACT_VERSION, at: now.toISOString(), session, ...fields } as MinutesEvent;
}

// ---------------------------------------------------------------------------
// Validators. They accept only the documented shape, so a host can validate untrusted input.
// ---------------------------------------------------------------------------

const MAX_TEXT = 4_000;
const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);
const isText = (value: unknown, max = MAX_TEXT): value is string => typeof value === 'string' && value.length <= max;
const isNonEmptyText = (value: unknown, max = MAX_TEXT): value is string => isText(value, max) && value.length > 0;
const isTime = (value: unknown): value is string =>
  typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(value) && !Number.isNaN(Date.parse(value));
const isOneOf = <T extends string>(list: readonly T[], value: unknown): value is T =>
  typeof value === 'string' && (list as readonly string[]).includes(value);
const hasOnly = (value: Record<string, unknown>, keys: readonly string[]) =>
  Object.keys(value).every((key) => keys.includes(key));
const isSessionId = (value: unknown): value is string => typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(value);
/** A redacted meeting link: an https URL with no credentials, query, or fragment (a Zoom `pwd` is a passcode). */
const isRedactedLink = (value: unknown): value is string => {
  if (!isNonEmptyText(value, 2_048) || /[?#]/.test(value)) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password;
  } catch {
    return false;
  }
};

const eventKeys: Record<MinutesEventType, readonly string[]> = {
  started: ['platform', 'meeting', 'displayName', 'outputDirectory'],
  state: ['state'],
  status: ['message'],
  recording: ['path'],
  error: ['code', 'message'],
  ended: ['reason', 'path', 'bytes'],
};

export function isMinutesEvent(value: unknown): value is MinutesEvent {
  if (!isRecord(value)) return false;
  if (value.v !== MINUTES_CONTRACT_VERSION || !isTime(value.at)) return false;
  if (!isOneOf(Object.keys(eventKeys) as MinutesEventType[], value.type)) return false;
  // Only a failure before any session existed (error, then ended) has no session id.
  if (value.session === null ? value.type !== 'error' && value.type !== 'ended' : !isSessionId(value.session)) return false;
  if (!hasOnly(value, ['v', 'at', 'session', 'type', ...eventKeys[value.type]])) return false;
  switch (value.type) {
    case 'started':
      return isOneOf(platforms, value.platform) && isRedactedLink(value.meeting)
        && isText(value.displayName, 200) && isNonEmptyText(value.outputDirectory);
    case 'state':
      return isOneOf(sessionStates, value.state);
    case 'status':
      return isText(value.message);
    case 'recording':
      return isNonEmptyText(value.path);
    case 'error':
      return isOneOf(errorCodes, value.code) && isText(value.message);
    case 'ended':
      // A file and its size come together; both are null when no file was kept.
      return isOneOf(endReasons, value.reason)
        && ((value.path === null && value.bytes === null)
          || (isNonEmptyText(value.path) && Number.isSafeInteger(value.bytes) && (value.bytes as number) >= 0));
  }
}

/** Parses one NDJSON line. Returns null for anything that is not a valid version-1 event. */
export function parseEventLine(line: string): MinutesEvent | null {
  try {
    const value: unknown = JSON.parse(line);
    return isMinutesEvent(value) ? value : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Status (read-only `status --json`)
// ---------------------------------------------------------------------------

export interface SessionRecord {
  id: string;
  /** Process id of the CLI that ran the session. */
  pid: number;
  platform: Platform;
  meeting: string;
  state: SessionState;
  outputPath: string | null;
  startedAt: string;
  updatedAt: string;
  joinedAt: string | null;
  endedAt: string | null;
  endReason: EndReason | null;
  error: { code: ErrorCode; message: string } | null;
}

export interface SessionStatus extends SessionRecord {
  /** True when the session is not finished and its CLI process is still running. */
  alive: boolean;
  /** True when the record says the session is active but its process is gone. */
  stale: boolean;
}

export interface MinutesStatus {
  v: typeof MINUTES_CONTRACT_VERSION;
  kind: 'minutes.status';
  observedAt: string;
  stateDirectory: string;
  /** Sessions most recent first, at most `STATUS_SESSION_LIMIT`. */
  sessions: SessionStatus[];
  /** Records that could not be read or did not validate. */
  unreadable: number;
}

export const STATUS_SESSION_LIMIT = 20;

const recordKeys = ['id', 'pid', 'platform', 'meeting', 'state', 'outputPath', 'startedAt', 'updatedAt', 'joinedAt', 'endedAt', 'endReason', 'error'] as const;

export function isSessionRecord(value: unknown): value is SessionRecord {
  if (!isRecord(value) || !hasOnly(value, recordKeys)) return false;
  const error = value.error;
  return isSessionId(value.id)
    && Number.isSafeInteger(value.pid) && (value.pid as number) > 0
    && isOneOf(platforms, value.platform)
    && isRedactedLink(value.meeting)
    && isOneOf(sessionStates, value.state)
    && (value.outputPath === null || isNonEmptyText(value.outputPath))
    && isTime(value.startedAt) && isTime(value.updatedAt)
    && (value.joinedAt === null || isTime(value.joinedAt))
    && (value.endedAt === null || isTime(value.endedAt))
    && (value.endReason === null || isOneOf(endReasons, value.endReason))
    && (error === null || (isRecord(error) && hasOnly(error, ['code', 'message']) && isOneOf(errorCodes, error.code) && isText(error.message)));
}

export function isMinutesStatus(value: unknown): value is MinutesStatus {
  if (!isRecord(value) || !hasOnly(value, ['v', 'kind', 'observedAt', 'stateDirectory', 'sessions', 'unreadable'])) return false;
  if (value.v !== MINUTES_CONTRACT_VERSION || value.kind !== 'minutes.status' || !isTime(value.observedAt)) return false;
  if (!isNonEmptyText(value.stateDirectory) || !Number.isSafeInteger(value.unreadable) || (value.unreadable as number) < 0) return false;
  if (!Array.isArray(value.sessions) || value.sessions.length > STATUS_SESSION_LIMIT) return false;
  return value.sessions.every((session) => {
    if (!isRecord(session)) return false;
    const { alive, stale, ...record } = session;
    if (typeof alive !== 'boolean' || typeof stale !== 'boolean' || !isSessionRecord(record)) return false;
    // An active session is either alive or stale; a finished one is neither.
    const active = record.state !== 'ended' && record.state !== 'failed';
    return active ? alive !== stale : !alive && !stale;
  });
}

// ---------------------------------------------------------------------------
// Doctor (`doctor --json`)
// ---------------------------------------------------------------------------

export const checkIds = ['node', 'chrome', 'profile', 'profile_lock', 'output_directory'] as const;
export type CheckId = (typeof checkIds)[number];
/** Which checks block `join`. A report must contain every check, with these flags. */
export const requiredChecks: Readonly<Record<CheckId, boolean>> = {
  node: true,
  chrome: true,
  profile: false,
  profile_lock: false,
  output_directory: true,
};

export interface DoctorCheck {
  id: CheckId;
  ok: boolean;
  /** A failed required check blocks `join`; a failed optional check is advice. */
  required: boolean;
  detail: string;
  fix: string | null;
}

export interface MinutesDoctor {
  v: typeof MINUTES_CONTRACT_VERSION;
  kind: 'minutes.doctor';
  observedAt: string;
  /** True when every required check passed. */
  ok: boolean;
  chromePath: string | null;
  profileDirectory: string;
  outputDirectory: string;
  checks: DoctorCheck[];
}

export function isMinutesDoctor(value: unknown): value is MinutesDoctor {
  if (!isRecord(value) || !hasOnly(value, ['v', 'kind', 'observedAt', 'ok', 'chromePath', 'profileDirectory', 'outputDirectory', 'checks'])) return false;
  if (value.v !== MINUTES_CONTRACT_VERSION || value.kind !== 'minutes.doctor' || !isTime(value.observedAt)) return false;
  if (typeof value.ok !== 'boolean' || (value.chromePath !== null && !isNonEmptyText(value.chromePath))) return false;
  if (!isNonEmptyText(value.profileDirectory) || !isNonEmptyText(value.outputDirectory) || !Array.isArray(value.checks)) return false;
  const seen = new Set<string>();
  for (const check of value.checks) {
    if (!isRecord(check) || !hasOnly(check, ['id', 'ok', 'required', 'detail', 'fix'])) return false;
    if (!isOneOf(checkIds, check.id) || seen.has(check.id)) return false;
    seen.add(check.id);
    if (typeof check.ok !== 'boolean' || check.required !== requiredChecks[check.id] || !isText(check.detail)) return false;
    if (check.fix !== null && !isText(check.fix)) return false;
  }
  if (seen.size !== checkIds.length) return false;
  const requiredOk = (value.checks as DoctorCheck[]).every((check) => check.ok || !check.required);
  return value.ok === requiredOk;
}
