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
/** Rounds of optimistic retries (duplicate checks and `apiId` compare-and-set) before giving up. */
const MAX_ATTEMPTS = 64;
const SEQUENCE_ID = 'apiId';
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
 * from a concurrent writer into the same result as the check (a duplicate, or a retry with a new `apiId`).
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

  async function getBookmark(id: string): Promise<Bookmark | null> {
    const [row] = await query({ resource: 'bookmarks', select: BOOKMARK_SELECT, filters: { id: normalizeId(id, 'id') }, limit: 1 });
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

  async function requireTag(id: string): Promise<Tag> {
    const [row] = await query({ resource: 'tags', select: ['*'], filters: { id: normalizeId(id, 'tag id') }, limit: 1 });
    if (!row) throw new BookmarkError('not-found', `Tag ${id} does not exist`);
    return toTag(row);
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

  async function sequenceRow(): Promise<Row | undefined> {
    const [row] = await query({ resource: 'bookmark_sequences', select: ['id', 'value'], filters: { id: SEQUENCE_ID }, limit: 1 });
    return row;
  }

  async function isApiIdTaken(apiId: number): Promise<boolean> {
    return (await query({ resource: 'bookmarks', select: ['id'], filters: { apiId }, limit: 1 })).length > 0;
  }

  /** The next `apiId`: a compare-and-set on the per-user high-water mark, so ids only grow and are never reused. */
  async function allocateApiId(): Promise<number> {
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const row = await sequenceRow();
      if (!row) {
        try {
          await mutate({ resource: 'bookmark_sequences', operation: 'insert', id: SEQUENCE_ID, record: { value: 0 } });
        } catch (error) {
          // Another writer created it first.
          if (!(await sequenceRow())) throw error;
        }
        continue;
      }
      const current = toNumber(row.value);
      if (!Number.isSafeInteger(current) || current < 0) throw new Error(`The apiId sequence holds ${String(row.value)}`);
      try {
        await mergeExisting('bookmark_sequences', SEQUENCE_ID, { value: current + 1 });
      } catch (error) {
        // The guard failed: another writer moved the sequence on.
        if (!isGuardConflict(error)) throw error;
        continue;
      }
      return current + 1;
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
    const have = new Set(bookmark.tags.map((tag) => tag.nameKey));
    const missing = inputs.filter((tag) => !have.has(tag.nameKey));
    if (missing.length === 0) return bookmark;
    const tags = await ensureTags(missing);
    await relate(
      'relate',
      'bookmarks',
      bookmark.id,
      tags.map((tag) => tag.id)
    );
    return requireBookmark(bookmark.id);
  }

  async function enqueueDetails(bookmark: { id: string; url: string }): Promise<void> {
    await detailsQueue.enqueue({ bookmarkId: bookmark.id, url: bookmark.url }, { dedupeKey: bookmark.id });
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
          faviconKey: null
        };
        try {
          await mutate({ resource: 'bookmarks', operation: 'insert', id, record });
        } catch (error) {
          // A unique index rejected the row: another process saved the URL (a duplicate on the next pass) or got
          // the same apiId (a new one is allocated). Anything else is a failure.
          if ((await findBookmarkIdByCanonicalUrl(target.canonicalUrl)) || (await isApiIdTaken(apiId))) return null;
          throw error;
        }
        return { id, duplicate: false };
      });

    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      const saved = await saveOnce();
      // A duplicate deleted before it was read is retried too.
      const bookmark = saved && (await getBookmark(saved.id));
      if (!saved || !bookmark) continue;
      const tagged = await addTagsTo(bookmark, tags);
      if (!saved.duplicate) await enqueueDetails(tagged);
      return { bookmark: tagged, duplicate: saved.duplicate };
    }
    throw new BookmarkError('conflict', 'Could not save the bookmark because of concurrent writes; try again');
  }

  async function updateBookmark(id: string, patch: BookmarkPatch): Promise<Bookmark> {
    if (typeof patch !== 'object' || patch === null) throw new BookmarkError('invalid-input', 'The update must be an object');
    const record: Row = {};
    const userTitle = normalizeText(patch.title, 'title', MAX_TITLE_LENGTH);
    const notes = normalizeText(patch.notes, 'notes', MAX_NOTES_LENGTH);
    const unread = normalizeBoolean(patch.unread, 'unread');
    const archived = normalizeBoolean(patch.archived, 'archived');
    const target = patch.url === undefined ? undefined : normalizeUrl(patch.url);
    const current = await requireBookmark(id);

    if (userTitle !== undefined && userTitle !== current.userTitle) record.userTitle = userTitle;
    if (notes !== undefined && notes !== current.notes) record.notes = notes;
    if (unread !== undefined && unread !== current.unread) record.unread = unread;
    if (archived !== undefined && archived !== current.archived) record.archived = archived;
    let refetch = false;
    if (target && target.canonicalUrl !== current.canonicalUrl) {
      const otherId = await findBookmarkIdByCanonicalUrl(target.canonicalUrl);
      if (otherId && otherId !== current.id) {
        throw new BookmarkError('duplicate-url', `Another bookmark already has ${target.canonicalUrl}`, { existingId: otherId });
      }
      // A different page: the old details no longer apply.
      Object.assign(record, {
        url: target.url,
        canonicalUrl: target.canonicalUrl,
        details: null,
        detailsState: 'pending',
        detailsError: null,
        detailsFetchedAt: null,
        faviconKey: null
      });
      refetch = true;
    } else if (target && target.url !== current.url) {
      record.url = target.url;
    }
    if (Object.keys(record).length === 0) return current;

    try {
      await mergeExisting('bookmarks', current.id, record);
    } catch (error) {
      if (target && refetch) {
        const otherId = await findBookmarkIdByCanonicalUrl(target.canonicalUrl);
        if (otherId && otherId !== current.id) {
          throw new BookmarkError('duplicate-url', `Another bookmark already has ${target.canonicalUrl}`, {
            existingId: otherId,
            cause: error
          });
        }
      }
      if (!(await getBookmark(current.id))) throw new BookmarkError('not-found', `Bookmark ${current.id} does not exist`, { cause: error });
      throw error;
    }
    const updated = await requireBookmark(current.id);
    if (refetch) await enqueueDetails(updated);
    return updated;
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

  async function mergeTags(sourceTagIds: string[], targetTagId: string): Promise<Tag> {
    const target = await requireTag(targetTagId);
    const sources = normalizeIds(sourceTagIds, 'sourceTagIds').filter((id) => id !== target.id);
    // Every source must exist before anything moves.
    for (const id of sources) await requireTag(id);
    for (const id of sources) {
      const bookmarkIds = await taggedBookmarkIds(id);
      await relate('relate', 'tags', target.id, bookmarkIds);
      await relate('unrelate', 'tags', id, bookmarkIds);
      await mutate({ resource: 'tags', operation: 'delete', id });
    }
    return target;
  }

  async function retryDetails(id: string): Promise<Bookmark> {
    const bookmark = await requireBookmark(id);
    if (bookmark.detailsState !== 'pending' || bookmark.detailsError !== null) {
      try {
        await mergeExisting('bookmarks', bookmark.id, { detailsState: 'pending', detailsError: null });
      } catch (error) {
        if (isGuardConflict(error)) throw new BookmarkError('not-found', `Bookmark ${bookmark.id} does not exist`, { cause: error });
        throw error;
      }
    }
    const updated = await requireBookmark(bookmark.id);
    await enqueueDetails(updated);
    return updated;
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
