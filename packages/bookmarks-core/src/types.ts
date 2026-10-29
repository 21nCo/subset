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

/**
 * A request to fetch the details of `url` for a bookmark. By the time the job runs the bookmark may have been
 * deleted, or details asked for again (a page change, including back to this page, or a retry), which enqueued its
 * own job, or a URL write interrupted before it settled may have left the bookmark on another page with this
 * request. So the runner stores a result only while the bookmark is still on the job's page with the job's request
 * (a datafn `if` guard `{ id: bookmarkId, detailsRequest, canonicalUrl }`) and otherwise drops it.
 */
export interface DetailsJob {
  bookmarkId: string;
  url: string;
  /** `canonicalizeUrl(url)` as saved when the job was enqueued: the page the result is for. */
  canonicalUrl: string;
  /** The request this job is for: null for the add-time request, which no later request goes back to. */
  detailsRequest: string | null;
}

/**
 * Where link-details work goes. A `@superfunctions/queue` adapter fits as
 * `{ enqueue: (job, options) => queue.enqueue('bookmark-details', job, options) }`.
 */
export interface DetailsQueue {
  /**
   * A second job with the same `dedupeKey` while one is queued or running is a no-op. The add-time key is the
   * bookmark id; a later page change or retry uses `<bookmark id>:<SHA-256 of a new request id and the canonical
   * URL>`, so each such request gets its own job and repeating one while its job is queued adds nothing.
   */
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

export type BookmarkErrorCode = 'invalid-input' | 'invalid-url' | 'not-found' | 'duplicate-url' | 'tag-conflict' | 'conflict' | 'too-large';

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
