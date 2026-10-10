import type { Page } from 'playwright-core';
import type { Platform } from '../contract.js';
import type { MeetingLink } from '../link.js';

/** One meeting platform's browser flow. Selectors are best-effort and break when the platform UI changes. */
export interface PlatformAdapter {
  platform: Platform;
  /** Meet reuses the signed-in bot profile; Zoom joins as a guest in a fresh context. */
  usesPersistentProfile: boolean;
  /** Any of these appearing means the meeting is over. */
  endSelectors: readonly string[];
  /** Tried in order when the bot is asked to leave. */
  leaveSelectors: readonly string[];
  join(page: Page, link: MeetingLink, displayName: string, log: (message: string) => void): Promise<void>;
}
