import type { Capture } from './capture.js';

/** Whether a target can save now. */
export type SaveTargetStatus =
  | { state: 'connected' }
  /** Not connected yet, for example no server or token; `message` tells the user what to do. */
  | { state: 'needs-setup'; message?: string }
  | { state: 'error'; message: string };

/**
 * What the user chose in the popup. Each field is the user's whole value, never merged with the capture's.
 */
export interface SaveEdits {
  /** The title; omitted keeps `capture.title`. */
  title?: string;
  /**
   * The notes; omitted or empty means no notes. A target never fills notes from `capture.selectionText`: the popup
   * offers the selection as the starting notes, so empty notes mean the user removed it.
   */
  notes?: string;
  /** The tags; omitted or empty means none. */
  tags?: string[];
}

export type SaveResult =
  /** `existing` is true when the link was already saved; `openUrl` is an http(s) page showing the saved item. */
  | { ok: true; existing?: boolean; openUrl?: string }
  /** `error` is shown to the user as plain text. */
  | { ok: false; error: string };

/**
 * Where captures go. A product supplies one (Bookmarks in SET-183, Memotron in TIDY-469); link capture owns reading
 * the page and the popup flow, the target owns its server, credentials and validation.
 */
export interface SaveTarget {
  /** Stable id, used for example to key its stored token. */
  readonly id: string;
  /** Name shown to the user, for example `Bookmarks`. */
  readonly label: string;
  status(): Promise<SaveTargetStatus>;
  /** Resolves `ok: false` only when nothing was saved; a rejection means the outcome is unknown. */
  save(capture: Capture, edits: SaveEdits): Promise<SaveResult>;
  /** Up to a few existing tags starting with `prefix`, for the tag field. */
  suggestTags?(prefix: string): Promise<string[]>;
}
