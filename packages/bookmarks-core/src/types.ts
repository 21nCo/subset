import type { LinkDetailsV1 } from '@subset.dev/links';
import type { DetailsState } from './schema.js';

export interface Tag {
  id: string;
  /** The name as first written; later spellings that differ only in case reuse this tag. */
  name: string;
  /** `name` lowercased: the per-user unique key. */
  nameKey: string;
}

export interface Bookmark {
  id: string;
  /** Integer id for the linkding-compatible API, assigned at creation, unique per user and never reused. */
  apiId: number;
  /** The URL as saved (WHATWG serialization). */
  url: string;
  /** `canonicalizeUrl(url)`, unique per user. */
  canonicalUrl: string;
  userTitle: string | null;
  notes: string | null;
  unread: boolean;
  archived: boolean;
  details: LinkDetailsV1 | null;
  detailsState: DetailsState;
  detailsError: string | null;
  /** Epoch milliseconds. */
  detailsFetchedAt: number | null;
  faviconKey: string | null;
  /** Epoch milliseconds. */
  createdAt: number;
  /** Epoch milliseconds. */
  updatedAt: number;
  /** Sorted by `nameKey`. */
  tags: Tag[];
}

export interface DetailsJob {
  bookmarkId: string;
  url: string;
}

/**
 * Where link-details work goes. A `@superfunctions/queue` adapter fits as
 * `{ enqueue: (job, options) => queue.enqueue('bookmark-details', job, options) }`.
 */
export interface DetailsQueue {
  /** A second job with the same `dedupeKey` while one is pending is a no-op. */
  enqueue(job: DetailsJob, options: { dedupeKey: string }): Promise<unknown>;
}

/**
 * The part of datafn's transport-neutral `DatafnExecutor` (`createDatafnServer(...).executor` in `@datafn/server`)
 * these operations use. The host's `namespaceProvider` maps `context` to the user's namespace.
 */
export interface BookmarksExecutor<TContext = unknown> {
  query<TResult = unknown>(payload: unknown, context?: TContext): Promise<TResult>;
  mutate<TResult = unknown>(payload: unknown, context?: TContext): Promise<TResult>;
}

export type BookmarkErrorCode = 'invalid-input' | 'invalid-url' | 'not-found' | 'duplicate-url' | 'tag-conflict' | 'conflict';

export class BookmarkError extends Error {
  readonly code: BookmarkErrorCode;
  /** For `duplicate-url`, the bookmark that already has the URL; for `tag-conflict`, the tag that has the name. */
  readonly existingId?: string;

  constructor(code: BookmarkErrorCode, message: string, options: { existingId?: string; cause?: unknown } = {}) {
    super(message, options.cause === undefined ? undefined : { cause: options.cause });
    this.name = 'BookmarkError';
    this.code = code;
    if (options.existingId !== undefined) this.existingId = options.existingId;
  }
}
