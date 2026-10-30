import { isLinkDetailsV1, type LinkDetailsV1 } from '@subset.dev/links';
import {
  MAX_IMPORT_BYTES,
  MAX_IMPORT_ITEMS,
  tooManyItems,
  warningList,
  type ImportItem,
  type ImportResult,
  type ImportWarning,
  type ParsedImport
} from './import.js';
import {
  MAX_NOTES_LENGTH,
  MAX_TITLE_LENGTH,
  normalizeBoolean,
  normalizeId,
  normalizeIds,
  normalizeTagName,
  normalizeTagNames,
  normalizeText,
  normalizeUrl
} from './input.js';
import { MAX_FOLDER_TAG_REFERENCES, renderNetscape } from './netscape.js';
import { BOOKMARKS_RESOURCE_VERSION, DETAILS_STATES, type DetailsState } from './schema.js';
import { BookmarkError, type Bookmark, type BookmarksExecutor, type DetailsQueue, type Tag } from './types.js';

export interface AddBookmarkOptions {
  /** The user's title; empty means none, so the page title is shown. */
  title?: string | null;
  notes?: string | null;
  tags?: string[];
  /** Defaults to `false`. */
  unread?: boolean;
}

export interface AddBookmarkResult {
  bookmark: Bookmark;
  /** True when the canonical URL was already saved: only new tags were added to the existing bookmark. */
  duplicate: boolean;
}

/** Fields left `undefined` are unchanged. `title` and `notes` accept `null` or `''` to clear. */
export interface BookmarkPatch {
  url?: string;
  title?: string | null;
  notes?: string | null;
  unread?: boolean;
  archived?: boolean;
}

export interface BookmarkOperations {
  getBookmark(id: string): Promise<Bookmark | null>;
  addBookmark(url: string, options?: AddBookmarkOptions): Promise<AddBookmarkResult>;
  updateBookmark(id: string, patch: BookmarkPatch): Promise<Bookmark>;
  setUnread(id: string, unread: boolean): Promise<Bookmark>;
  setArchived(id: string, archived: boolean): Promise<Bookmark>;
  /** Hard delete. Tags stay, even when no bookmark uses them any more. Returns the ids that existed. */
  deleteBookmarks(ids: string[]): Promise<{ deleted: string[] }>;
  addTags(bookmarkId: string, names: string[]): Promise<Bookmark>;
  removeTags(bookmarkId: string, names: string[]): Promise<Bookmark>;
  renameTag(tagId: string, name: string): Promise<Tag>;
  /** Moves every bookmark of the source tags to the target tag, then deletes the source tags. */
  mergeTags(sourceTagIds: string[], targetTagId: string): Promise<Tag>;
  /** Marks the bookmark's details pending again and enqueues a fetch. */
  retryDetails(id: string): Promise<Bookmark>;
  /** Saves parsed import items the way `addBookmark` saves a URL, many at a time. */
  importBookmarks(input: ParsedImport | readonly ImportItem[]): Promise<ImportResult>;
  /** Every bookmark as a Netscape bookmark file, by apiId; `ADD_DATE` is its `addedAt`, else its `createdAt`. */
  exportNetscape(): Promise<string>;
}

export interface BookmarkOperationsOptions<TContext> {
  executor: BookmarksExecutor<TContext>;
  detailsQueue: DetailsQueue;
  /** Passed with every executor call; the host's datafn `namespaceProvider` maps it to the user. */
  context?: TContext;
}

const version = BOOKMARKS_RESOURCE_VERSION;
/** datafn's default query limit. */
const PAGE_SIZE = 100;
/** Rounds of optimistic retries (duplicate checks, `apiId` claims and guarded updates) before giving up. */
const MAX_ATTEMPTS = 64;
const BOOKMARK_SELECT = ['*', 'tags.*'];
/** Import items saved per step: one apiId claim and one batch of datafn inserts (under datafn's default 500). */
const IMPORT_BATCH = 100;

/**
 * Most tags the items given to `importBookmarks` may list in all, counted before they are checked. It is more than any
 * file `parseImport` reads can give: its folders give at most `MAX_FOLDER_TAG_REFERENCES`, and each of its own tags
 * takes at least two of its `MAX_IMPORT_BYTES` (a character and a separator).
 */
export const MAX_IMPORT_TAG_REFERENCES = MAX_FOLDER_TAG_REFERENCES + MAX_IMPORT_BYTES / 2;

type Row = Record<string, unknown>;
type TagInput = { name: string; nameKey: string };

/** An import item that passed the checks: what `addBookmark` would save for it. */
interface ImportEntry {
  url: string;
  canonicalUrl: string;
  title: string | null;
  notes: string | null;
  tags: TagInput[];
  unread: boolean;
  archived: boolean;
  /** Epoch milliseconds, or null when the exporter gave no date. */
  addedAt: number | null;
}

/** An import entry and the bookmark that has its URL. */
type SavedEntry = { id: string; entry: ImportEntry };
/** A saved bookmark's id and stored dates (epoch milliseconds; `addedAt` null when it has none). */
type SavedDates = { id: string; addedAt: number | null; createdAt: number };

/** Trims optional import text and cuts it to `max` characters with a warning, where `addBookmark` would refuse it. */
function clampText(value: unknown, field: string, max: number, warn: (message: string) => void): string | null {
  if (typeof value !== 'string') return null;
  const chars = [...value.trim()];
  if (chars.length <= max) return chars.length === 0 ? null : chars.join('');
  warn(`The ${field} was cut to ${max.toLocaleString('en-US')} characters`);
  return chars.slice(0, max).join('').trim();
}

/** Checks an import item: null (with a warning) when its URL cannot be saved. Invalid tags are dropped with a warning. */
function toImportEntry(item: unknown, position: number, add: (warning: ImportWarning) => void): ImportEntry | null {
  const record = typeof item === 'object' && item !== null ? (item as Record<string, unknown>) : {};
  const rawUrl = typeof record.url === 'string' ? record.url : undefined;
  const warn = (message: string) => add({ item: position, ...(rawUrl === undefined ? {} : { url: rawUrl }), message });
  let target: { url: string; canonicalUrl: string };
  try {
    target = normalizeUrl(rawUrl ?? '');
  } catch (error) {
    if (!(error instanceof BookmarkError)) throw error;
    warn(`Skipped: ${error.message}`);
    return null;
  }
  const tags = new Map<string, TagInput>();
  for (const name of Array.isArray(record.tags) ? (record.tags as unknown[]) : []) {
    try {
      const tag = normalizeTagName(name);
      if (!tags.has(tag.nameKey)) tags.set(tag.nameKey, tag);
    } catch (error) {
      if (!(error instanceof BookmarkError)) throw error;
      warn(`Tag dropped: ${error.message}`);
    }
  }
  return {
    ...target,
    title: clampText(record.title, 'title', MAX_TITLE_LENGTH, warn),
    notes: clampText(record.notes, 'notes', MAX_NOTES_LENGTH, warn),
    tags: [...tags.values()],
    unread: record.unread === true,
    archived: record.archived === true,
    // An exporter writes 0 for a date it does not know.
    addedAt: typeof record.addedAt === 'number' && Number.isSafeInteger(record.addedAt) && record.addedAt > 0 ? record.addedAt : null
  };
}

/** The earlier of two dates either of which may be unknown. */
const earliest = (a: number | null, b: number | null) => (a === null ? b : b === null ? a : Math.min(a, b));

/** The details of a bookmark whose page changed: none yet, and a fetch pending. */
const CLEARED_DETAILS = { details: null, detailsState: 'pending', detailsError: null, detailsFetchedAt: null, faviconKey: null };
/** A details request names the canonical URL it was made for, so a row whose request names another page shows it. */
const newRequest = (canonicalUrl: string) => `${crypto.randomUUID()} ${canonicalUrl}`;

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== 'boolean') throw new BookmarkError('invalid-input', `${field} must be a boolean`);
  return value;
}

function requireArray<T>(value: T[], field: string): T[] {
  if (!Array.isArray(value)) throw new BookmarkError('invalid-input', `${field} must be an array`);
  return value;
}

/**
 * A failed `if` guard. datafn reports it as `CONFLICT` on every adapter, unlike a unique-index violation, which
 * depends on the adapter (`CONFLICT` on SQLite, `INTERNAL` on Postgres), so index conflicts are recognized by
 * reading the state that would cause them.
 */
const isGuardConflict = (error: unknown) =>
  typeof error === 'object' && error !== null && (error as { code?: unknown }).code === 'CONFLICT';

/** datafn's executor throws `NOT_FOUND` when a relation names a record that does not exist. */
const isNotFound = (error: unknown) =>
  typeof error === 'object' && error !== null && (error as { code?: unknown }).code === 'NOT_FOUND';

/**
 * One chain of uniqueness-sensitive writes (check, allocate, insert) per executor in this process. The memory
 * adapter has no unique indexes and its transactions do not detect conflicts, so without this two concurrent
 * adds could both pass the checks; on SQL the unique indexes still guard writers in other processes.
 */
const writeChains = new WeakMap<object, Promise<unknown>>();

function serialized<T>(key: object, task: () => Promise<T>): Promise<T> {
  const run = (writeChains.get(key) ?? Promise.resolve()).then(task);
  writeChains.set(key, run.catch(() => undefined));
  return run;
}

/** SHA-256 of `text` in hex, so a details job key stays short for any URL. */
async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function chunks<T>(items: T[], size = PAGE_SIZE): T[][] {
  const out: T[][] = [];
  for (let start = 0; start < items.length; start += size) out.push(items.slice(start, start + size));
  return out;
}

// Storage adapters differ in how they return booleans, big integers and JSON, so rows are coerced on the way out.
const toNumber = (value: unknown) => (typeof value === 'number' ? value : Number(value));
const toBoolean = (value: unknown) => value === true || value === 1 || value === '1' || value === 'true';
const toOptionalString = (value: unknown) => (typeof value === 'string' ? value : null);
const toOptionalNumber = (value: unknown) => (value === null || value === undefined ? null : toNumber(value));

function toDetails(value: unknown): LinkDetailsV1 | null {
  let parsed = value;
  if (typeof value === 'string') {
    try {
      parsed = JSON.parse(value);
    } catch {
      return null;
    }
  }
  return isLinkDetailsV1(parsed) ? parsed : null;
}

function toTag(row: Row): Tag {
  return { id: String(row.id), name: String(row.name), nameKey: String(row.nameKey) };
}

function toBookmark(row: Row): Bookmark {
  const state = row.detailsState as DetailsState;
  const tags = Array.isArray(row.tags) ? (row.tags as Row[]).map(toTag) : [];
  return {
    id: String(row.id),
    apiId: toNumber(row.apiId),
    url: String(row.url),
    canonicalUrl: String(row.canonicalUrl),
    userTitle: toOptionalString(row.userTitle),
    notes: toOptionalString(row.notes),
    unread: toBoolean(row.unread),
    archived: toBoolean(row.archived),
    details: toDetails(row.details),
    detailsState: DETAILS_STATES.includes(state) ? state : 'failed',
    detailsError: toOptionalString(row.detailsError),
    detailsFetchedAt: toOptionalNumber(row.detailsFetchedAt),
    faviconKey: toOptionalString(row.faviconKey),
    addedAt: toOptionalNumber(row.addedAt),
    createdAt: toNumber(row.createdAt),
    updatedAt: toNumber(row.updatedAt),
    tags: tags.sort((a, b) => (a.nameKey < b.nameKey ? -1 : a.nameKey > b.nameKey ? 1 : 0))
  };
}

/**
 * The Bookmarks write operations over a datafn executor. Uniqueness of `canonicalUrl`, `apiId` and tag names per
 * user is enforced by the migrations' unique indexes; these operations check first and turn an index conflict
 * from a concurrent writer into the same result as the check (a duplicate, or a claim of the next `apiId`).
 */
export function createBookmarkOperations<TContext = unknown>(options: BookmarkOperationsOptions<TContext>): BookmarkOperations {
  const { executor, detailsQueue, context } = options;

  async function query(payload: Row): Promise<Row[]> {
    const result = await executor.query<{ data?: unknown }>({ version, ...payload }, context);
    if (!result || !Array.isArray(result.data)) throw new Error(`datafn query on ${String(payload.resource)} returned no data`);
    return result.data as Row[];
  }

  async function mutate(payload: Row): Promise<void> {
    const result = await executor.mutate<{ ok?: unknown; errors?: { code?: string; message?: string }[] }>(
      { version, ...payload },
      context
    );
    if (result?.ok !== true) {
      const error = result?.errors?.[0];
      throw Object.assign(new Error(error?.message ?? `datafn ${String(payload.operation)} on ${String(payload.resource)} failed`), {
        code: error?.code
      });
    }
  }

  /** Sends the mutations as one datafn batch, which runs each on its own: true for each that succeeded. */
  async function mutateEach(payloads: Row[]): Promise<boolean[]> {
    if (payloads.length === 0) return [];
    const results = await executor.mutate<unknown>(
      payloads.map((payload) => ({ version, ...payload })),
      context
    );
    if (!Array.isArray(results) || results.length !== payloads.length) throw new Error('datafn returned no result for a batch of mutations');
    return results.map((result) => (result as { ok?: unknown } | null)?.ok === true);
  }

  async function getBookmarkRow(id: string): Promise<Row | null> {
    const [row] = await query({ resource: 'bookmarks', select: BOOKMARK_SELECT, filters: { id: normalizeId(id, 'id') }, limit: 1 });
    return row ?? null;
  }

  async function getBookmark(id: string): Promise<Bookmark | null> {
    const row = await getBookmarkRow(id);
    return row ? toBookmark(row) : null;
  }

  async function requireBookmark(id: string): Promise<Bookmark> {
    const bookmark = await getBookmark(id);
    if (!bookmark) throw new BookmarkError('not-found', `Bookmark ${id} does not exist`);
    return bookmark;
  }

  async function findBookmarkIdByCanonicalUrl(canonicalUrl: string): Promise<string | null> {
    const [row] = await query({ resource: 'bookmarks', select: ['id'], filters: { canonicalUrl }, limit: 1 });
    return row ? String(row.id) : null;
  }

  async function findTag(id: string): Promise<Tag | null> {
    const [row] = await query({ resource: 'tags', select: ['*'], filters: { id: normalizeId(id, 'tag id') }, limit: 1 });
    return row ? toTag(row) : null;
  }

  async function requireTag(id: string): Promise<Tag> {
    const tag = await findTag(id);
    if (!tag) throw new BookmarkError('not-found', `Tag ${id} does not exist`);
    return tag;
  }

  async function findTagsByKey(keys: string[]): Promise<Map<string, Tag>> {
    const found = new Map<string, Tag>();
    for (const chunk of chunks(keys)) {
      for (const row of await query({ resource: 'tags', select: ['*'], filters: { nameKey: { $in: chunk } }, limit: PAGE_SIZE })) {
        const tag = toTag(row);
        found.set(tag.nameKey, tag);
      }
    }
    return found;
  }

  /** Updates an existing row only: the guard keeps datafn's `merge` from creating a deleted record again. */
  async function mergeExisting(resource: string, id: string, record: Row): Promise<void> {
    await mutate({ resource, operation: 'merge', id, record, if: { id } });
  }

  async function isApiIdClaimed(apiId: number): Promise<boolean> {
    return (await query({ resource: 'bookmark_api_ids', select: ['id'], filters: { id: String(apiId) }, limit: 1 })).length > 0;
  }

  /**
   * Claims the next `count` apiIds, from the last claimed number plus one, by inserting one row into
   * `bookmark_api_ids` whose id is the first number and whose value is the last. Claims are never deleted, so the
   * primary key settles concurrent claims from one number: the loser reads the new last number and claims after it.
   * Every claim starts right after the last one read, so a range is claimed whole or not at all; ids only grow and a
   * deleted bookmark's id is not handed out again. Returns the first number.
   */
  async function allocateApiIds(count = 1): Promise<number> {
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const [last] = await query({ resource: 'bookmark_api_ids', select: ['value'], sort: ['-value'], limit: 1 });
      const next = (last ? toNumber(last.value) : 0) + 1;
      const end = next + count - 1;
      if (!Number.isSafeInteger(end) || next < 1) throw new Error(`The last apiId is ${String(last?.value)}`);
      try {
        await mutate({ resource: 'bookmark_api_ids', operation: 'insert', id: String(next), record: { value: end } });
        return next;
      } catch (error) {
        // Another writer claimed from the number first: read the new last one.
        if (!(await isApiIdClaimed(next))) throw error;
      }
    }
    throw new BookmarkError('conflict', 'Could not assign an API id because of concurrent writes; try again');
  }

  /** Finds or creates each tag. A concurrent creation of the same name resolves to the tag that won. */
  async function ensureTags(inputs: TagInput[]): Promise<Tag[]> {
    if (inputs.length === 0) return [];
    return serialized(executor, async () => {
      const found = await findTagsByKey(inputs.map((tag) => tag.nameKey));
      for (const input of inputs) {
        for (let attempt = 0; !found.has(input.nameKey); attempt++) {
          if (attempt === MAX_ATTEMPTS) throw new BookmarkError('conflict', `Could not create tag ${input.name}; try again`);
          const id = crypto.randomUUID();
          try {
            await mutate({ resource: 'tags', operation: 'insert', id, record: { name: input.name, nameKey: input.nameKey } });
            found.set(input.nameKey, { id, ...input });
          } catch (error) {
            // Only the unique name index can reject a fresh id: use the tag that won.
            const existing = (await findTagsByKey([input.nameKey])).get(input.nameKey);
            if (!existing) throw error;
            found.set(input.nameKey, existing);
          }
        }
      }
      return inputs.map((input) => found.get(input.nameKey) as Tag);
    });
  }

  async function relate(operation: 'relate' | 'unrelate', resource: 'bookmarks' | 'tags', id: string, ids: string[]): Promise<void> {
    const relation = resource === 'bookmarks' ? 'tags' : 'bookmarks';
    for (const chunk of chunks(ids)) await mutate({ resource, operation, id, relations: { [relation]: chunk } });
  }

  async function mergeTargets(tagIds: string[]): Promise<Map<string, string>> {
    const targets = new Map<string, string>();
    for (const chunk of chunks(tagIds)) {
      for (const row of await query({ resource: 'tag_merges', select: ['id', 'targetId'], filters: { id: { $in: chunk } }, limit: PAGE_SIZE })) {
        targets.set(String(row.id), String(row.targetId));
      }
    }
    return targets;
  }

  async function existingIds(resource: 'bookmarks' | 'tags', ids: string[]): Promise<Set<string>> {
    const found = new Set<string>();
    for (const chunk of chunks(ids)) {
      for (const row of await query({ resource, select: ['id'], filters: { id: { $in: chunk } }, limit: PAGE_SIZE })) found.add(String(row.id));
    }
    return found;
  }

  const existingTagIds = (tagIds: string[]) => existingIds('tags', tagIds);

  /**
   * Links the bookmark to the tags that exist and returns the ids of those that do not. datafn refuses the whole
   * relate when one tag is gone (or the bookmark, which fails here), and on SQL the join row's foreign keys refuse a
   * link to a tag or bookmark deleted after datafn's check, so the rest are linked again without it.
   */
  async function relateExisting(bookmarkId: string, tagIds: string[]): Promise<Set<string>> {
    const gone = new Set<string>();
    for (let link = tagIds, attempt = 0; link.length > 0; attempt++) {
      if (attempt === MAX_ATTEMPTS) throw new BookmarkError('conflict', 'Could not add the tags because of concurrent writes; try again');
      try {
        await relate('relate', 'bookmarks', bookmarkId, link);
        break;
      } catch (error) {
        await requireBookmark(bookmarkId);
        const live = await existingTagIds(link);
        if (live.size === link.length) throw error;
        for (const id of link) if (!live.has(id)) gone.add(id);
        link = link.filter((id) => live.has(id));
      }
    }
    return gone;
  }

  /**
   * Links the bookmark to the tags and, for each tag a merge has recorded, on along its merge records too. A merge
   * records a source before its last read of the source's bookmarks, so a link that merge did not see was written
   * after the record, and reading the records here finds it. `recorded` holds the records of tags already linked,
   * which are followed without linking those tags again. Each tag's records are a chain of their own: a tag that
   * is gone ends only its chain. Returns the requested tags whose chain linked nothing that still exists (each was
   * removed without a merge), so the caller finds or creates them again by name.
   */
  async function linkTagChains(bookmarkId: string, tagIds: string[], recorded = new Map<string, string>()): Promise<string[]> {
    // The requested or already linked tags each tag was reached from.
    const origins = new Map<string, Set<string>>();
    const reach = (id: string, from: Iterable<string>) => {
      const set = origins.get(id) ?? new Set<string>();
      for (const origin of from) set.add(origin);
      origins.set(id, set);
    };
    for (const id of tagIds) reach(id, [id]);
    for (const [id, target] of recorded) reach(target, [id]);
    const kept = new Set(recorded.keys());
    // Each record is followed once, so an interrupted merge of A into B and a later merge of B into A end.
    const followed = new Set(recorded.keys());
    let link = [...origins.keys()];
    for (let hop = 0; link.length > 0; hop++) {
      if (hop === MAX_ATTEMPTS) throw new BookmarkError('conflict', 'Could not add the tags because of concurrent writes; try again');
      const gone = await relateExisting(bookmarkId, link);
      const merged = await mergeTargets(link.filter((id) => !followed.has(id)));
      // A linked tag with no record may have been deleted since without a merge: it keeps nothing.
      const live = await existingTagIds(link.filter((id) => !gone.has(id) && !merged.has(id) && !followed.has(id)));
      const next = new Set<string>();
      for (const id of link) {
        const from = origins.get(id) ?? new Set<string>();
        if (!gone.has(id) && (merged.has(id) || followed.has(id) || live.has(id))) for (const origin of from) kept.add(origin);
        const target = merged.get(id);
        if (target === undefined) continue;
        followed.add(id);
        reach(target, from);
        next.add(target);
      }
      link = [...next];
    }
    return tagIds.filter((id) => !kept.has(id));
  }

  /** linkTagChains: true when every requested tag's chain linked a tag that still exists. */
  const linkTags = async (bookmarkId: string, tagIds: string[], recorded?: Map<string, string>) =>
    (await linkTagChains(bookmarkId, tagIds, recorded)).length === 0;

  async function addTagsTo(bookmark: Bookmark, inputs: TagInput[]): Promise<Bookmark> {
    let current = bookmark;
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const have = new Map(current.tags.map((tag) => [tag.nameKey, tag.id]));
      const missing = inputs.filter((tag) => !have.has(tag.nameKey));
      // A requested tag already linked may be a merge source whose last read missed the link (an earlier call
      // failed after linking it), so its records are followed as for a new link.
      const recorded = await mergeTargets(inputs.flatMap((tag) => have.get(tag.nameKey) ?? []));
      if (missing.length === 0 && recorded.size === 0) return current;
      const tags = await ensureTags(missing);
      if (await linkTags(current.id, tags.map((tag) => tag.id), recorded)) return requireBookmark(current.id);
      current = await requireBookmark(current.id);
    }
    throw new BookmarkError('conflict', 'Could not add the tags because of concurrent writes; try again');
  }

  /**
   * Reads the bookmark and, while its details are pending, enqueues a fetch of its current URL for the request it
   * has, which the job carries with the page. The add-time request (`detailsRequest` null) is keyed by the bookmark
   * id, like the job `addBookmark` enqueues. A later request is keyed by the bookmark, the request id and the
   * canonical URL, so a job still queued for an earlier request or page cannot absorb it, while repeating the call for
   * the same request adds nothing.
   */
  async function requestDetails(id: string): Promise<Bookmark> {
    const row = await getBookmarkRow(id);
    if (!row) throw new BookmarkError('not-found', `Bookmark ${id} does not exist`);
    const bookmark = toBookmark(row);
    if (bookmark.detailsState !== 'pending') return bookmark;
    const request = toOptionalString(row.detailsRequest);
    const dedupeKey = request === null ? bookmark.id : `${bookmark.id}:${await sha256Hex(`${request}\n${bookmark.canonicalUrl}`)}`;
    await detailsQueue.enqueue({ bookmarkId: bookmark.id, url: bookmark.url, canonicalUrl: bookmark.canonicalUrl, detailsRequest: request }, { dedupeKey });
    return bookmark;
  }

  async function addBookmark(url: string, options: AddBookmarkOptions = {}): Promise<AddBookmarkResult> {
    if (typeof options !== 'object' || options === null) throw new BookmarkError('invalid-input', 'The options must be an object');
    const target = normalizeUrl(url);
    const userTitle = normalizeText(options.title, 'title', MAX_TITLE_LENGTH) ?? null;
    const notes = normalizeText(options.notes, 'notes', MAX_NOTES_LENGTH) ?? null;
    const unread = normalizeBoolean(options.unread, 'unread') ?? false;
    const tags = normalizeTagNames(options.tags);

    // Finds the saved bookmark or inserts a new one; null means a concurrent writer won a unique index: retry.
    const saveOnce = () =>
      serialized(executor, async (): Promise<{ id: string; duplicate: boolean } | null> => {
        const existingId = await findBookmarkIdByCanonicalUrl(target.canonicalUrl);
        if (existingId) return { id: existingId, duplicate: true };
        const apiId = await allocateApiIds();
        const id = crypto.randomUUID();
        const record = {
          apiId,
          url: target.url,
          canonicalUrl: target.canonicalUrl,
          userTitle,
          notes,
          unread,
          archived: false,
          // Written, not left out, so every adapter stores null: an import's date guard matches it.
          addedAt: null,
          ...CLEARED_DETAILS,
          detailsRequest: null
        };
        try {
          await mutate({ resource: 'bookmarks', operation: 'insert', id, record });
        } catch (error) {
          // The canonical URL index rejected the row: another process saved the URL, a duplicate on the next pass.
          if (await findBookmarkIdByCanonicalUrl(target.canonicalUrl)) return null;
          throw error;
        }
        return { id, duplicate: false };
      });

    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const saved = await saveOnce();
      if (!saved) continue;
      // Enqueued before tagging, so a failure while tagging leaves a bookmark whose details still arrive and a
      // repeated add (a duplicate) adds the tags.
      if (!saved.duplicate) {
        await detailsQueue.enqueue({ bookmarkId: saved.id, url: target.url, canonicalUrl: target.canonicalUrl, detailsRequest: null }, { dedupeKey: saved.id });
      }
      // A bookmark deleted before it was read is saved again.
      const bookmark = await getBookmark(saved.id);
      if (!bookmark) continue;
      return { bookmark: await addTagsTo(bookmark, tags), duplicate: saved.duplicate };
    }
    throw new BookmarkError('conflict', 'Could not save the bookmark because of concurrent writes; try again');
  }

  async function updateBookmark(id: string, patch: BookmarkPatch): Promise<Bookmark> {
    if (typeof patch !== 'object' || patch === null) throw new BookmarkError('invalid-input', 'The update must be an object');
    // Every requested field is written, even one that already looks equal, so a stale read cannot drop it.
    const fields: Row = {};
    const userTitle = normalizeText(patch.title, 'title', MAX_TITLE_LENGTH);
    const notes = normalizeText(patch.notes, 'notes', MAX_NOTES_LENGTH);
    const unread = normalizeBoolean(patch.unread, 'unread');
    const archived = normalizeBoolean(patch.archived, 'archived');
    const target = patch.url === undefined ? undefined : normalizeUrl(patch.url);
    if (userTitle !== undefined) fields.userTitle = userTitle;
    if (notes !== undefined) fields.notes = notes;
    if (unread !== undefined) fields.unread = unread;
    if (archived !== undefined) fields.archived = archived;
    const duplicateUrl = (existingId: string, cause?: unknown) =>
      new BookmarkError('duplicate-url', `Another bookmark already has ${target?.canonicalUrl}`, { existingId, cause });

    // One read, check and write: the bookmark when there is nothing to write, the details request the row has
    // once written, `false` to decide again. With a `url` it runs in the per-executor chain, like an add, so on the
    // memory adapter (no unique index) no other writer here can take the canonical URL between the check and the write.
    const writeOnce = async (): Promise<Bookmark | boolean> => {
      const row = await getBookmarkRow(id);
      if (!row) throw new BookmarkError('not-found', `Bookmark ${id} does not exist`);
      const current = toBookmark(row);
      const record: Row = { ...fields };
      // Without a URL only existence is guarded (so `merge` cannot recreate a deleted row). With one, `url`,
      // `canonicalUrl` and the details are written together and only while the URL is still the one read here.
      let guard: Row = { id: current.id };
      let moved = false;
      if (target) {
        guard = { id: current.id, url: current.url, canonicalUrl: current.canonicalUrl };
        Object.assign(record, { url: target.url, canonicalUrl: target.canonicalUrl });
        moved = target.canonicalUrl !== current.canonicalUrl;
      }
      if (target && moved) {
        const otherId = await findBookmarkIdByCanonicalUrl(target.canonicalUrl);
        if (otherId && otherId !== current.id) throw duplicateUrl(otherId);
        // A different page: the old details no longer apply, and this is a new request for them.
        Object.assign(record, { ...CLEARED_DETAILS, detailsRequest: newRequest(target.canonicalUrl) });
      }
      if (Object.keys(record).length === 0) return current;

      try {
        await mutate({ resource: 'bookmarks', operation: 'merge', id: current.id, record, if: guard });
      } catch (error) {
        if (target && moved) {
          const otherId = await findBookmarkIdByCanonicalUrl(target.canonicalUrl);
          if (otherId && otherId !== current.id) throw duplicateUrl(otherId, error);
        }
        // The bookmark was deleted (not-found on the next read; datafn says NOT_FOUND when the delete landed after
        // its guard read) or its URL changed since it was read: decide again.
        if (isGuardConflict(error) || isNotFound(error)) return false;
        throw error;
      }
      return true;
    };

    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const written = await (target ? serialized(executor, writeOnce) : writeOnce());
      if (written === false) continue;
      if (written !== true) return written;
      return target ? settleUrlWrite(id) : requireBookmark(id);
    }
    throw new BookmarkError('conflict', 'Could not update the bookmark because of concurrent writes; try again');
  }

  /**
   * Runs after a URL write. datafn checks an `if` guard by reading the row before it writes, so the write can land
   * after another writer moved the bookmark to another page and that page's details were stored. That move wrote a
   * request naming its page, so a bookmark whose request names another page than its own (null is the add-time
   * request) may show that page's details: they are cleared and asked for again. The row alone decides, so repeating
   * an interrupted update repairs it too. Then a pending bookmark gets a job for the page it is on now.
   */
  async function settleUrlWrite(id: string): Promise<Bookmark> {
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const row = await getBookmarkRow(id);
      if (!row) throw new BookmarkError('not-found', `Bookmark ${id} does not exist`);
      const found = toOptionalString(row.detailsRequest);
      const canonicalUrl = String(row.canonicalUrl);
      if (found === null || found.slice(found.indexOf(' ') + 1) === canonicalUrl) return requestDetails(id);
      try {
        await mutate({
          resource: 'bookmarks',
          operation: 'merge',
          id,
          record: { ...CLEARED_DETAILS, detailsRequest: newRequest(canonicalUrl) },
          if: { id, canonicalUrl, detailsRequest: found }
        });
        return requestDetails(id);
      } catch (error) {
        // A deleted bookmark fails with not-found on the next read.
        if (!isGuardConflict(error) && !isNotFound(error)) throw error;
      }
    }
    throw new BookmarkError('conflict', 'Could not update the bookmark because of concurrent writes; try again');
  }

  async function deleteBookmarks(ids: string[]): Promise<{ deleted: string[] }> {
    const deleted: string[] = [];
    for (const id of normalizeIds(ids, 'ids')) {
      const bookmark = await getBookmark(id);
      if (!bookmark) continue;
      // On SQL the join rows go with the bookmark (foreign keys). The memory adapter has none and datafn leaves join
      // rows behind, so the tag links go first, until a read finds none (a tag added meanwhile is unlinked too).
      for (let tags = bookmark.tags, attempt = 0; tags.length > 0; attempt++) {
        if (attempt === MAX_ATTEMPTS) throw new BookmarkError('conflict', 'Could not delete the bookmark because of concurrent writes; try again');
        await relate('unrelate', 'bookmarks', id, tags.map((tag) => tag.id));
        tags = (await getBookmark(id))?.tags ?? [];
      }
      await mutate({ resource: 'bookmarks', operation: 'delete', id });
      deleted.push(id);
    }
    return { deleted };
  }

  async function removeTags(bookmarkId: string, names: string[]): Promise<Bookmark> {
    const keys = new Set(normalizeTagNames(requireArray(names, 'names')).map((tag) => tag.nameKey));
    const bookmark = await requireBookmark(bookmarkId);
    const remove = bookmark.tags.filter((tag) => keys.has(tag.nameKey)).map((tag) => tag.id);
    if (remove.length === 0) return bookmark;
    await relate('unrelate', 'bookmarks', bookmark.id, remove);
    return requireBookmark(bookmark.id);
  }

  async function renameTag(tagId: string, name: string): Promise<Tag> {
    const next = normalizeTagName(name);
    // In the same chain as tag creation, so on the memory adapter (no unique index) no other writer here can take
    // the name between the check and the write.
    const renamed = await serialized(executor, () => renameTagNow(tagId, next));
    // A merge recorded before the write (it may have deleted the tag, which the write then wrote again) is finished,
    // following its target on if that was merged since, so a tag a merge reported as merged stays gone and a rename
    // leaves no record.
    const recorded = await mergedInto(renamed.id);
    if (recorded === null) return renamed;
    await mergeTags([renamed.id], recorded);
    throw new BookmarkError('not-found', `Tag ${renamed.id} was merged into another tag`);
  }

  async function renameTagNow(tagId: string, next: TagInput): Promise<Tag> {
    const tag = await requireTag(tagId);
    if (next.name === tag.name) return tag;
    const otherTag = async () => {
      const other = (await findTagsByKey([next.nameKey])).get(next.nameKey);
      return other && other.id !== tag.id ? other : undefined;
    };
    const conflict = (other: Tag, cause?: unknown) =>
      new BookmarkError('tag-conflict', `Tag ${other.name} already exists; merge the tags instead`, { existingId: other.id, cause });
    const before = await otherTag();
    if (before) throw conflict(before);
    try {
      await mergeExisting('tags', tag.id, next);
    } catch (error) {
      const after = await otherTag();
      if (after) throw conflict(after, error);
      await requireTag(tag.id);
      throw error;
    }
    return { id: tag.id, ...next };
  }

  async function taggedBookmarkIds(tagId: string): Promise<string[]> {
    const ids: string[] = [];
    for (let offset = 0; ; offset += PAGE_SIZE) {
      const page = await query({
        resource: 'bookmarks',
        select: ['id'],
        filters: { 'tags.id': tagId },
        sort: ['id'],
        limit: PAGE_SIZE,
        offset
      });
      ids.push(...page.map((row) => String(row.id)));
      if (page.length < PAGE_SIZE) return ids;
    }
  }

  async function mergedInto(sourceId: string): Promise<string | null> {
    const [row] = await query({ resource: 'tag_merges', select: ['targetId'], filters: { id: sourceId }, limit: 1 });
    return row ? String(row.targetId) : null;
  }

  /**
   * Follows the merge records from `tagId` to the tag they end at, each passed once: the tags passed and that end,
   * null when they lead back to one passed.
   */
  async function mergeWalk(tagId: string): Promise<{ passed: Set<string>; end: string | null }> {
    const passed = new Set<string>();
    for (let id = tagId; ; ) {
      passed.add(id);
      const next = await mergedInto(id);
      if (next === null) return { passed, end: id };
      if (passed.has(next)) return { passed, end: null };
      id = next;
    }
  }

  /**
   * Whether `tagId`'s merge records lead to where `targetId`'s end: one walk passes the target, or the target's walk
   * meets it. Ends found apart but merged on since (between the two walks) are walked again; false when the records
   * lead back to a tag passed or settle at another end.
   */
  async function sameMergeEnd(tagId: string, targetId: string): Promise<boolean> {
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const from = await mergeWalk(tagId);
      if (from.end === null) return false;
      if (from.passed.has(targetId)) return true;
      const to = await mergeWalk(targetId);
      if (to.end === null) return false;
      if ([...to.passed].some((id) => from.passed.has(id))) return true;
      if ((await mergedInto(from.end)) === null && (await mergedInto(to.end)) === null) return false;
    }
    throw new BookmarkError('conflict', 'Could not merge the tags because of concurrent writes; try again');
  }

  /**
   * The live tag at the end of `tagId`'s merge records. An end found deleted but recorded since (merged on between
   * the walk and the read) is walked again; null when the records lead back to a tag passed or end at a tag deleted
   * with no record.
   */
  async function liveEnd(tagId: string): Promise<Tag | null> {
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const { end } = await mergeWalk(tagId);
      if (end === null) return null;
      const tag = await findTag(end);
      if (tag) return tag;
      if ((await mergedInto(end)) === null) return null;
    }
    throw new BookmarkError('conflict', 'Could not merge the tags because of concurrent writes; try again');
  }

  /**
   * Claims the source for a merge into `targetId`: its `tag_merges` record is inserted only when it has none (the
   * primary key refuses a second on SQL; the memory adapter, which overwrites, gets the read and insert in the
   * per-executor chain), so one merge decision holds at a time. Returns the record and whether this call wrote it,
   * or null when it is another merge's (`isOurs` false).
   */
  function claimMerge(sourceId: string, targetId: string, isOurs: (recorded: string) => Promise<boolean>) {
    return serialized(executor, async (): Promise<{ recorded: string; inserted: boolean } | null> => {
      for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
        const recorded = await mergedInto(sourceId);
        if (recorded !== null) return (await isOurs(recorded)) ? { recorded, inserted: false } : null;
        try {
          await mutate({ resource: 'tag_merges', operation: 'insert', id: sourceId, record: { targetId } });
          return { recorded: targetId, inserted: true };
        } catch (error) {
          // Only another merge's record can refuse the insert: read it.
          if ((await mergedInto(sourceId)) === null) throw error;
        }
      }
      throw new BookmarkError('conflict', 'Could not merge the tags because of concurrent writes; try again');
    });
  }

  /**
   * Links the bookmarks (none on a merge's last read) to the tag and, like linkTags, on along its merge records.
   * `moved` when they reached a live tag no merge has recorded, `retry` when one of the bookmarks was deleted, and
   * `conflict` when the records lead back to a tag already passed (merges into each other, one of them
   * `sourceId`'s) or end at a deleted tag.
   */
  async function attachAlongMerges(bookmarkIds: string[], tagId: string, sourceId: string): Promise<'moved' | 'retry' | 'conflict'> {
    const passed = new Set([sourceId]);
    for (let tag = tagId; !passed.has(tag); ) {
      passed.add(tag);
      let linked = true;
      try {
        await relate('relate', 'tags', tag, bookmarkIds);
      } catch (error) {
        // datafn's check, or on SQL a foreign key after it, refused a tag or bookmark deleted meanwhile.
        if (await findTag(tag)) {
          if ((await existingIds('bookmarks', bookmarkIds)).size === bookmarkIds.length) throw error;
          return 'retry';
        }
        linked = false;
      }
      const next = await mergedInto(tag);
      // With nothing to link, the relate did not show whether the tag exists.
      if (next === null) return linked && (bookmarkIds.length > 0 || (await findTag(tag)) !== null) ? 'moved' : 'conflict';
      tag = next;
    }
    return 'conflict';
  }

  async function mergeTags(sourceTagIds: string[], targetTagId: string): Promise<Tag> {
    // A target merged on since an interrupted merge into it is followed to the end of its records.
    const target = (await findTag(targetTagId)) ?? (await liveEnd(targetTagId));
    if (!target) throw new BookmarkError('not-found', `Tag ${targetTagId} does not exist`);
    const into = target;
    // A record is this merge's when it names the target or its records end where the target's do.
    const isOurs = async (recorded: string) => recorded === into.id || (await sameMergeEnd(recorded, into.id));
    const sources = normalizeIds(sourceTagIds, 'sourceTagIds').filter((id) => id !== into.id && id !== targetTagId);
    // Every source must exist, or have been merged into this target by an earlier run, before anything moves; so
    // an interrupted merge is finished by repeating it.
    const remaining: string[] = [];
    for (const id of sources) {
      if (await findTag(id)) remaining.push(id);
      else {
        const recorded = await mergedInto(id);
        if (recorded === null || !(await isOurs(recorded))) throw new BookmarkError('not-found', `Tag ${id} does not exist`);
      }
    }
    const claimed = async (id: string) => {
      const claim = await claimMerge(id, into.id, isOurs);
      if (!claim) throw new BookmarkError('conflict', `Tag ${id} is being merged into another tag; repeat that merge first`);
      return claim;
    };
    for (const id of remaining) {
      // Claimed before the last read of the source's bookmarks, so a link written after that read is followed to
      // the target by linkTags.
      let claim = await claimed(id);
      // Moves the source's bookmarks until it has none, so one tagged while the merge runs is moved too. They are
      // unlinked from the source only once linked to the end of the target's merges, which a later merge of that
      // tag reads after recording it, so a merge of the target running meanwhile carries them on. The records are
      // walked after the last, empty read too, so a source is deleted only while they lead to a live tag.
      for (let attempt = 0; ; attempt++) {
        if (attempt === MAX_ATTEMPTS) throw new BookmarkError('conflict', 'Could not merge the tags because of concurrent writes; try again');
        const bookmarkIds = await taggedBookmarkIds(id);
        const moved = await attachAlongMerges(bookmarkIds, into.id, id);
        if (moved === 'retry') continue;
        if (moved === 'conflict') {
          // The target is being merged back into the source (or the merges cross): withdraw this merge's record so
          // the source stays a plain tag, and keep its bookmarks on it.
          try {
            await mutate({ resource: 'tag_merges', operation: 'delete', id, if: { id, targetId: claim.recorded } });
          } catch (error) {
            if (!isGuardConflict(error)) throw error;
          }
          throw new BookmarkError('conflict', `Tag ${into.name} is being merged into another tag; finish that merge first`);
        }
        if (bookmarkIds.length === 0) {
          // A merge back into this target that saw the cycle may have withdrawn the record since the walk: claim
          // again, then read and walk again, so the cycle gives conflict and a bookmark tagged meanwhile is moved.
          claim = await claimed(id);
          if (!claim.inserted) break;
          continue;
        }
        await relate('unrelate', 'tags', id, bookmarkIds);
      }
      await mutate({ resource: 'tags', operation: 'delete', id });
    }
    // The target may have been merged on meanwhile, the bookmarks following its records: return the tag they end at
    // (the target itself while its records lead to no live tag).
    const result = (await liveEnd(into.id)) ?? (await findTag(into.id));
    if (!result) throw new BookmarkError('not-found', `Tag ${into.id} was merged into a tag that no longer exists`);
    return result;
  }

  async function retryDetails(id: string): Promise<Bookmark> {
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const bookmark = await requireBookmark(id);
      // A bookmark already pending keeps its request, so retrying while its job is queued adds no job.
      if (bookmark.detailsState === 'pending' && bookmark.detailsError === null) return requestDetails(bookmark.id);
      // The request names the page read here and comes with cleared details, so the write is guarded on that page: after a page change, decide again.
      const record = { ...CLEARED_DETAILS, detailsRequest: newRequest(bookmark.canonicalUrl) };
      try {
        await mutate({ resource: 'bookmarks', operation: 'merge', id: bookmark.id, record, if: { id: bookmark.id, canonicalUrl: bookmark.canonicalUrl } });
        return requestDetails(bookmark.id);
      } catch (error) {
        if (!isGuardConflict(error) && !isNotFound(error)) throw error;
      }
    }
    throw new BookmarkError('conflict', 'Could not retry the details because of concurrent writes; try again');
  }

  const toSavedDates = (row: Row): SavedDates => ({ id: String(row.id), addedAt: toOptionalNumber(row.addedAt), createdAt: toNumber(row.createdAt) });

  /** The saved bookmarks with these canonical URLs: their ids and stored dates. */
  async function bookmarksByCanonicalUrl(canonicalUrls: string[]): Promise<Map<string, SavedDates>> {
    const found = new Map<string, SavedDates>();
    for (const chunk of chunks(canonicalUrls)) {
      const select = ['id', 'canonicalUrl', 'addedAt', 'createdAt'];
      for (const row of await query({ resource: 'bookmarks', select, filters: { canonicalUrl: { $in: chunk } }, limit: PAGE_SIZE })) {
        found.set(String(row.canonicalUrl), toSavedDates(row));
      }
    }
    return found;
  }

  /**
   * Gives a saved bookmark an import entry's date when the entry says it was added earlier, at the whole seconds an
   * export carries: a URL saved twice keeps the earliest date, and importing a bookmark's own export changes nothing.
   * The write is guarded on the date it replaces still being at least a second later (`addedAt`, or a null `addedAt`
   * and `createdAt`), so an earlier date another import saved meanwhile is never raised; on a conflict the date is read
   * again. One deleted meanwhile is left to the tagging, which reports it.
   */
  async function keepEarliestAdded(saved: SavedDates, entry: ImportEntry): Promise<void> {
    if (entry.addedAt === null) return;
    const { id } = saved;
    const later = (Math.floor(entry.addedAt / 1000) + 1) * 1000;
    for (let attempt = 0, dates: SavedDates | null = saved; dates !== null; attempt++) {
      if ((dates.addedAt ?? dates.createdAt) < later) return;
      if (attempt === MAX_ATTEMPTS) throw new BookmarkError('conflict', 'Could not save the date a bookmark was added because of concurrent writes; try again');
      const guard = dates.addedAt === null ? { id, addedAt: null, createdAt: { $gte: later } } : { id, addedAt: { $gte: later } };
      try {
        await mutate({ resource: 'bookmarks', operation: 'merge', id, record: { addedAt: entry.addedAt }, if: guard });
        return;
      } catch (error) {
        if (!isGuardConflict(error)) throw error;
      }
      const [row] = await query({ resource: 'bookmarks', select: ['id', 'addedAt', 'createdAt'], filters: { id }, limit: 1 });
      dates = row ? toSavedDates(row) : null;
    }
  }

  /**
   * Saves one batch of import entries, as `addBookmark` saves one URL: in the per-executor chain, entries already
   * saved are found, and the rest get one claimed range of apiIds and are inserted in one datafn batch. An insert
   * that fails because another process saved the URL meanwhile makes that entry an existing one. An existing
   * bookmark takes the entry's date when that is earlier.
   */
  function saveImportBatch(batch: ImportEntry[]) {
    return serialized(executor, async (): Promise<{ created: SavedEntry[]; existing: SavedEntry[] }> => {
      const found = await bookmarksByCanonicalUrl(batch.map((entry) => entry.canonicalUrl));
      const existing: SavedEntry[] = [];
      const fresh: ImportEntry[] = [];
      for (const entry of batch) {
        const saved = found.get(entry.canonicalUrl);
        if (saved === undefined) fresh.push(entry);
        else {
          await keepEarliestAdded(saved, entry);
          existing.push({ id: saved.id, entry });
        }
      }
      if (fresh.length === 0) return { created: [], existing };
      const first = await allocateApiIds(fresh.length);
      const rows = fresh.map((entry, index) => ({ id: crypto.randomUUID(), entry, apiId: first + index }));
      const inserted = await mutateEach(
        rows.map(({ id, entry, apiId }) => ({
          resource: 'bookmarks',
          operation: 'insert',
          id,
          record: {
            apiId,
            url: entry.url,
            canonicalUrl: entry.canonicalUrl,
            userTitle: entry.title,
            notes: entry.notes,
            unread: entry.unread,
            archived: entry.archived,
            addedAt: entry.addedAt,
            ...CLEARED_DETAILS,
            // Only an untitled bookmark needs its details for a title; one with a title is not fetched.
            detailsState: entry.title === null ? 'pending' : 'ready',
            detailsRequest: null
          }
        }))
      );
      const created = rows.filter((_, index) => inserted[index]);
      const failed = rows.filter((_, index) => !inserted[index]);
      if (failed.length > 0) {
        const now = await bookmarksByCanonicalUrl(failed.map(({ entry }) => entry.canonicalUrl));
        for (const { entry } of failed) {
          const saved = now.get(entry.canonicalUrl);
          if (saved === undefined) throw new Error(`Saving the bookmark for ${entry.url} failed`);
          await keepEarliestAdded(saved, entry);
          existing.push({ id: saved.id, entry });
        }
      }
      return { created: created.map(({ id, entry }) => ({ id, entry })), existing };
    });
  }

  /**
   * Gives saved import entries their tags. New bookmarks are linked a tag at a time, up to a page of bookmarks per
   * datafn relate. Then the merge records of every requested tag a bookmark has are read: a merge records its source
   * before its last read of the source's bookmarks, so one that missed these links is found, and those bookmarks
   * follow its records, as `addBookmark` does. So do bookmarks a relate refused (a tag deleted meanwhile) and saved
   * bookmarks that lack a requested tag.
   */
  async function tagImported(created: SavedEntry[], existing: SavedEntry[], tagsByKey: Map<string, Tag>, warn: (warning: ImportWarning) => void): Promise<void> {
    const entries = new Map([...created, ...existing].map(({ id, entry }) => [id, entry]));
    // Tag id -> the bookmarks here that asked for it and have it.
    const holders = new Map<string, Set<string>>();
    const hold = (tagId: string, bookmarkId: string) => holders.set(tagId, (holders.get(tagId) ?? new Set()).add(bookmarkId));
    const oneByOne = new Set<string>();

    const byTag = new Map<string, string[]>();
    for (const { id, entry } of created) {
      for (const input of entry.tags) {
        const tagId = (tagsByKey.get(input.nameKey) as Tag).id;
        const ids = byTag.get(tagId);
        if (ids) ids.push(id);
        else byTag.set(tagId, [id]);
      }
    }
    for (const [tagId, bookmarkIds] of byTag) {
      for (const chunk of chunks(bookmarkIds)) {
        try {
          await relate('relate', 'tags', tagId, chunk);
          for (const id of chunk) hold(tagId, id);
        } catch {
          for (const id of chunk) oneByOne.add(id);
        }
      }
    }

    const tagged = existing.filter(({ entry }) => entry.tags.length > 0).map(({ id }) => id);
    for (const chunk of chunks(tagged)) {
      for (const row of await query({ resource: 'bookmarks', select: BOOKMARK_SELECT, filters: { id: { $in: chunk } }, limit: PAGE_SIZE })) {
        const bookmark = toBookmark(row);
        const have = new Map(bookmark.tags.map((tag) => [tag.nameKey, tag.id]));
        for (const input of (entries.get(bookmark.id) as ImportEntry).tags) {
          const tagId = have.get(input.nameKey);
          if (tagId === undefined) oneByOne.add(bookmark.id);
          else hold(tagId, bookmark.id);
        }
      }
    }

    // A held tag merged away, or deleted without a merge since it was linked (taking its links), is given again.
    const held = [...holders.keys()];
    const recorded = await mergeTargets(held);
    const live = await existingTagIds(held);
    for (const tagId of held) if (recorded.has(tagId) || !live.has(tagId)) for (const id of holders.get(tagId) ?? []) oneByOne.add(id);
    for (const id of oneByOne) {
      const entry = entries.get(id) as ImportEntry;
      const bookmark = await getBookmark(id);
      if (bookmark) await tagOneImported(bookmark, entry.tags, tagsByKey);
      else warn({ url: entry.url, message: 'The bookmark was deleted while it was being imported, so it has no tags' });
    }
  }

  /**
   * Gives one imported bookmark its tags as `addTagsTo` would, starting from the tags the import resolved: a tag the
   * bookmark lacks is linked by the id the import found or created, so one merged away (and deleted) since is
   * followed along its records to the tag it went into, and the records of those it has are followed too. Only a tag
   * whose chain linked nothing (it was deleted without a merge) is found or created again by name.
   */
  async function tagOneImported(bookmark: Bookmark, inputs: TagInput[], tagsByKey: Map<string, Tag>): Promise<void> {
    const have = new Map(bookmark.tags.map((tag) => [tag.nameKey, tag.id]));
    const recorded = await mergeTargets(inputs.flatMap((input) => have.get(input.nameKey) ?? []));
    const missing = inputs.filter((input) => !have.has(input.nameKey));
    const lost = new Set(await linkTagChains(bookmark.id, missing.map((input) => (tagsByKey.get(input.nameKey) as Tag).id), recorded));
    const byName = missing.filter((input) => lost.has((tagsByKey.get(input.nameKey) as Tag).id));
    if (byName.length > 0) await addTagsTo(await requireBookmark(bookmark.id), byName);
  }

  async function importBookmarks(input: ParsedImport | readonly ImportItem[]): Promise<ImportResult> {
    const parsed: { items?: unknown; warnings?: unknown } = Array.isArray(input) ? { items: input } : ((input ?? {}) as object);
    if (!Array.isArray(parsed.items)) throw new BookmarkError('invalid-input', 'The import must be an array of items or the result of parseImport');
    if (parsed.items.length > MAX_IMPORT_ITEMS) throw tooManyItems();
    let tagReferences = 0;
    for (const item of parsed.items as unknown[]) {
      const tags = typeof item === 'object' && item !== null ? (item as { tags?: unknown }).tags : undefined;
      if (Array.isArray(tags)) tagReferences += tags.length;
    }
    if (tagReferences > MAX_IMPORT_TAG_REFERENCES) {
      throw new BookmarkError(
        'too-large',
        `The import lists more than ${MAX_IMPORT_TAG_REFERENCES.toLocaleString('en-US')} tags in all (MAX_IMPORT_TAG_REFERENCES)`
      );
    }
    const warnings = warningList(Array.isArray(parsed.warnings) ? (parsed.warnings as ImportWarning[]) : []);
    // One entry per canonical URL: a later item with the same URL is merged into it, as a duplicate add would be.
    const entries = new Map<string, { entry: ImportEntry; keys: Set<string> }>();
    // Each tag in the first spelling the file gives it, as one add after another would create it.
    const allTags = new Map<string, TagInput>();
    let skipped = 0;
    let merged = 0;
    parsed.items.forEach((item: unknown, index) => {
      const entry = toImportEntry(item, index + 1, warnings.add);
      if (!entry) {
        skipped++;
        return;
      }
      for (const tag of entry.tags) if (!allTags.has(tag.nameKey)) allTags.set(tag.nameKey, tag);
      const earlier = entries.get(entry.canonicalUrl);
      if (!earlier) {
        entries.set(entry.canonicalUrl, { entry, keys: new Set(entry.tags.map((tag) => tag.nameKey)) });
        return;
      }
      merged++;
      earlier.entry.addedAt = earliest(earlier.entry.addedAt, entry.addedAt);
      for (const tag of entry.tags) {
        if (earlier.keys.has(tag.nameKey)) continue;
        earlier.keys.add(tag.nameKey);
        earlier.entry.tags.push(tag);
      }
    });
    const tagsByKey = new Map((await ensureTags([...allTags.values()])).map((tag) => [tag.nameKey, tag]));

    let added = 0;
    for (const batch of chunks([...entries.values()].map(({ entry }) => entry), IMPORT_BATCH)) {
      const { created, existing } = await saveImportBatch(batch);
      added += created.length;
      merged += existing.length;
      // As in an add, the details are enqueued before tagging.
      for (const { id, entry } of created) {
        if (entry.title === null) {
          await detailsQueue.enqueue({ bookmarkId: id, url: entry.url, canonicalUrl: entry.canonicalUrl, detailsRequest: null }, { dedupeKey: id });
        }
      }
      await tagImported(created, existing, tagsByKey, warnings.add);
    }
    return { added, merged, skipped, warnings: warnings.list() };
  }

  async function exportNetscape(): Promise<string> {
    const bookmarks: Bookmark[] = [];
    for (let after = 0; ; ) {
      const rows = await query({ resource: 'bookmarks', select: BOOKMARK_SELECT, filters: { apiId: { $gt: after } }, sort: ['apiId'], limit: PAGE_SIZE });
      for (const row of rows) bookmarks.push(toBookmark(row));
      if (rows.length < PAGE_SIZE) break;
      after = bookmarks[bookmarks.length - 1].apiId;
    }
    return renderNetscape(
      bookmarks.map((bookmark) => ({
        url: bookmark.url,
        title: bookmark.userTitle ?? bookmark.details?.title ?? null,
        notes: bookmark.notes,
        tags: bookmark.tags.map((tag) => tag.name),
        unread: bookmark.unread,
        archived: bookmark.archived,
        addedAt: bookmark.addedAt,
        createdAt: bookmark.createdAt,
        updatedAt: bookmark.updatedAt
      }))
    );
  }

  return {
    getBookmark,
    addBookmark,
    updateBookmark,
    setUnread: async (id, unread) => updateBookmark(id, { unread: requireBoolean(unread, 'unread') }),
    setArchived: async (id, archived) => updateBookmark(id, { archived: requireBoolean(archived, 'archived') }),
    deleteBookmarks,
    addTags: async (bookmarkId, names) => addTagsTo(await requireBookmark(bookmarkId), normalizeTagNames(requireArray(names, 'names'))),
    removeTags,
    renameTag,
    mergeTags,
    retryDetails,
    importBookmarks,
    exportNetscape
  };
}
