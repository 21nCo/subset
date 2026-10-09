import type { ErrorCode, Platform } from './contract.js';
import type { MeetingLink } from './link.js';

/**
 * The browser automation seam. `@subset/minutes/chrome` implements it with playwright-core and the
 * system Chrome; tests use a fake. Nothing outside the driver touches Playwright.
 */
export interface MeetingDriver {
  open(options: OpenOptions): Promise<MeetingPage>;
}

export interface OpenOptions {
  platform: Platform;
  /** Persistent Chrome profile (Meet). Zoom uses a fresh context. */
  profileDirectory: string;
  /** Progress text for the `status` event. Must not contain the raw meeting link. */
  log: (message: string) => void;
}

export type EndSignal = 'meeting_ended' | 'page_closed' | 'aborted';

export interface MeetingPage {
  /** Installs audio capture before navigation and starts writing WebM to `outputPath`. */
  startCapture(outputPath: string): Promise<void>;
  /** Navigates to the meeting and completes the platform's join flow. */
  join(link: MeetingLink, displayName: string, signal: AbortSignal): Promise<void>;
  /** Resolves when the meeting ends, the page closes, or `signal` aborts. */
  waitForEnd(signal: AbortSignal): Promise<EndSignal>;
  /** Stops the recorder, flushes the final chunk, closes the file, and returns its size in bytes. */
  stopCapture(): Promise<number>;
  /** Best-effort click on the platform's leave button. */
  leave(): Promise<void>;
  close(): Promise<void>;
}

/** An error with a contract error code. Anything else is reported as `internal`. */
export class MinutesError extends Error {
  readonly code: ErrorCode;
  constructor(code: ErrorCode, message: string) {
    super(message);
    this.name = 'MinutesError';
    this.code = code;
  }
}
