/** Structured JSON-line protocol between bot process and Swift host app. */

export interface StatusEvent {
  type: 'status';
  message: string;
}
export interface JoinedEvent {
  type: 'joined';
  platform: string;
  url: string;
}
export interface RecordingEvent {
  type: 'recording';
  path: string;
}
export interface ErrorEvent {
  type: 'error';
  message: string;
}
export interface EndedEvent {
  type: 'ended';
  reason: string;
}

export type BotEvent =
  | StatusEvent
  | JoinedEvent
  | RecordingEvent
  | ErrorEvent
  | EndedEvent;

function emit(event: BotEvent): void {
  process.stdout.write(JSON.stringify(event) + '\n');
}

export function status(message: string): void {
  emit({ type: 'status', message });
}

export function joined(platform: string, url: string): void {
  emit({ type: 'joined', platform, url });
}

export function recording(path: string): void {
  emit({ type: 'recording', path });
}

export function error(message: string): void {
  emit({ type: 'error', message });
}

export function ended(reason: string): void {
  emit({ type: 'ended', reason });
}
