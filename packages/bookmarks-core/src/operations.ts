import { isLinkDetailsV1, type LinkDetailsV1 } from '@subset.dev/links';
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

type Row = Record<string, unknown>;
type TagInput = { name: string; nameKey: string };

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
   * Claims the next `apiId` by inserting it into `bookmark_api_ids`. Claims are never deleted, so the primary key
   * settles concurrent claims of one number, ids only grow and a deleted bookmark's id is not handed out again.
   */
  async function allocateApiId(): Promise<number> {
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const [last] = await query({ resource: 'bookmark_api_ids', select: ['value'], sort: ['-value'], limit: 1 });
      const next = (last ? toNumber(last.value) : 0) + 1;
      if (!Number.isSafeInteger(next) || next < 1) throw new Error(`The last apiId is ${String(last?.value)}`);
      try {
        await mutate({ resource: 'bookmark_api_ids', operation: 'insert', id: String(next), record: { value: next } });
        return next;
      } catch (error) {
        // Another writer claimed the number first: read the new last one.
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

  async function addTagsTo(bookmark: Bookmark, inputs: TagInput[]): Promise<Bookmark> {
    let current = bookmark;
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const have = new Set(current.tags.map((tag) => tag.nameKey));
      const missing = inputs.filter((tag) => !have.has(tag.nameKey));
      if (missing.length === 0) return current;
      const tags = await ensureTags(missing);
      try {
        await relate(
          'relate',
          'bookmarks',
          current.id,
          tags.map((tag) => tag.id)
        );
      } catch (error) {
        // datafn refuses to link a tag that a concurrent merge or rename conflict removed: find or create it again.
        if (!isNotFound(error)) throw error;
        current = await requireBookmark(current.id);
        continue;
      }
      return requireBookmark(current.id);
    }
    throw new BookmarkError('conflict', 'Could not add the tags because of concurrent writes; try again');
  }

  /**
   * Reads the bookmark and, while its details are pending, enqueues a fetch of its current URL. The add-time
   * request (`detailsRequest` null) is keyed by the bookmark id, like the job `addBookmark` enqueues. A later
   * request is keyed by the bookmark, the request id and the canonical URL, so a job still queued for an earlier
   * request or page cannot absorb it, while repeating the call for the same request adds nothing.
   */
  async function requestDetails(id: string): Promise<Bookmark> {
    const row = await getBookmarkRow(id);
    if (!row) throw new BookmarkError('not-found', `Bookmark ${id} does not exist`);
    const bookmark = toBookmark(row);
    if (bookmark.detailsState !== 'pending') return bookmark;
    const request = toOptionalString(row.detailsRequest);
    const dedupeKey = request === null ? bookmark.id : `${bookmark.id}:${await sha256Hex(`${request}\n${bookmark.canonicalUrl}`)}`;
    await detailsQueue.enqueue({ bookmarkId: bookmark.id, url: bookmark.url }, { dedupeKey });
    return bookmark;
  }

  async function addBookmark(url: string, options: AddBookmarkOptions = {}): Promise<AddBookmarkResult> {
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
        const apiId = await allocateApiId();
        const id = crypto.randomUUID();
        const record = {
          apiId,
          url: target.url,
          canonicalUrl: target.canonicalUrl,
          userTitle,
          notes,
          unread,
          archived: false,
          details: null,
          detailsState: 'pending',
          detailsError: null,
          detailsFetchedAt: null,
          faviconKey: null,
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
      if (!saved.duplicate) await detailsQueue.enqueue({ bookmarkId: saved.id, url: target.url }, { dedupeKey: saved.id });
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

    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const current = await requireBookmark(id);
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
        Object.assign(record, {
          details: null,
          detailsState: 'pending',
          detailsError: null,
          detailsFetchedAt: null,
          faviconKey: null,
          detailsRequest: crypto.randomUUID()
        });
      }
      if (Object.keys(record).length === 0) return current;

      try {
        await mutate({ resource: 'bookmarks', operation: 'merge', id: current.id, record, if: guard });
      } catch (error) {
        if (target && moved) {
          const otherId = await findBookmarkIdByCanonicalUrl(target.canonicalUrl);
          if (otherId && otherId !== current.id) throw duplicateUrl(otherId, error);
        }
        // The bookmark was deleted (not-found on the next read) or its URL changed since it was read: decide again.
        if (isGuardConflict(error)) continue;
        throw error;
      }
      // After any URL write, moved or not, a pending bookmark gets a job for the page it is on now: so repeating an
      // update whose enqueue failed recovers, and so does a write that datafn let past a concurrent move.
      return target ? requestDetails(current.id) : requireBookmark(current.id);
    }
    throw new BookmarkError('conflict', 'Could not update the bookmark because of concurrent writes; try again');
  }

  async function deleteBookmarks(ids: string[]): Promise<{ deleted: string[] }> {
    const deleted: string[] = [];
    for (const id of normalizeIds(ids, 'ids')) {
      const bookmark = await getBookmark(id);
      if (!bookmark) continue;
      // datafn leaves join rows behind when a record is deleted, so the tag links go first.
      await relate(
        'unrelate',
        'bookmarks',
        id,
        bookmark.tags.map((tag) => tag.id)
      );
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
    return serialized(executor, () => renameTagNow(tagId, next));
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

  async function mergeTags(sourceTagIds: string[], targetTagId: string): Promise<Tag> {
    const target = await requireTag(targetTagId);
    const sources = normalizeIds(sourceTagIds, 'sourceTagIds').filter((id) => id !== target.id);
    // Every source must exist, or have been merged into this target by an earlier run, before anything moves; so
    // an interrupted merge is finished by repeating it.
    const remaining: string[] = [];
    for (const id of sources) {
      if (await findTag(id)) remaining.push(id);
      else if ((await mergedInto(id)) !== target.id) throw new BookmarkError('not-found', `Tag ${id} does not exist`);
    }
    for (const id of remaining) {
      // Moves the source's bookmarks until it has none, so one tagged while the merge runs is moved too.
      for (let attempt = 0; ; attempt++) {
        const bookmarkIds = await taggedBookmarkIds(id);
        if (bookmarkIds.length === 0) break;
        if (attempt === MAX_ATTEMPTS) throw new BookmarkError('conflict', 'Could not merge the tags because of concurrent writes; try again');
        try {
          await relate('relate', 'tags', target.id, bookmarkIds);
        } catch (error) {
          // A bookmark deleted since the read: read the members again (the target is checked so this cannot spin).
          if (!isNotFound(error)) throw error;
          await requireTag(target.id);
          continue;
        }
        await relate('unrelate', 'tags', id, bookmarkIds);
      }
      // Recorded before the delete; `merge` creates the row or points it at this target.
      await mutate({ resource: 'tag_merges', operation: 'merge', id, record: { targetId: target.id } });
      await mutate({ resource: 'tags', operation: 'delete', id });
    }
    return target;
  }

  async function retryDetails(id: string): Promise<Bookmark> {
    const bookmark = await requireBookmark(id);
    // A bookmark already pending keeps its request, so retrying while its job is queued adds no job.
    if (bookmark.detailsState !== 'pending' || bookmark.detailsError !== null) {
      try {
        await mergeExisting('bookmarks', bookmark.id, { detailsState: 'pending', detailsError: null, detailsRequest: crypto.randomUUID() });
      } catch (error) {
        if (isGuardConflict(error)) throw new BookmarkError('not-found', `Bookmark ${bookmark.id} does not exist`, { cause: error });
        throw error;
      }
    }
    return requestDetails(bookmark.id);
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
    retryDetails
  };
}
