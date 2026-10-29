# @subset.dev/bookmarks-core (SET-173)

The Bookmarks data model and the only operations that write bookmark data. It is private, independent of any host, database or UI, and depends only on `@subset.dev/links`, `@datafn/core` and `@superfunctions/db` (`scripts/check-workspaces.mjs` enforces this). Hosts (the web app, the CLI, the linkding-compatible API) wire authentication, a datafn executor and a details queue, then call these operations. Import and export (SET-174), the details job runner (SET-175), auth and HTTP are not here.

## Data model

`bookmarksSchema` is the datafn schema (resource version 1). Every row carries datafn's `__ns` namespace, so data is per user even though a deployment has one owner, and multi-user needs no migration.

| Resource | Fields |
| --- | --- |
| `bookmarks` | `id`, `apiId` (integer for the linkding-compatible API, unique per user, never reused), `url`, `canonicalUrl` (unique per user), `userTitle`, `notes`, `unread`, `archived`, `details` (`LinkDetailsV1` JSON), `detailsState` (`pending`, `ready` or `failed`), `detailsError`, `detailsFetchedAt`, `faviconKey`, `createdAt`, `updatedAt` (epoch milliseconds, from datafn's `timestamps` capability) |
| `tags` | `id`, `name` (first spelling), `nameKey` (lowercased name, unique per user) |
| `bookmark_tags` | datafn's many-to-many join rows (`id`, `from` bookmark id, `to` tag id) for the `bookmarks.tags` / `tags.bookmarks` relation |
| `bookmark_sequences` | the per-user `apiId` high-water mark (one row, id `apiId`) |

datafn does not enforce `unique`, so uniqueness lives in the migrations' unique indexes, each led by `__ns`.

## Migrations

`bookmarksTables` describes the same tables in `@superfunctions/db` `TableSchema` form, and `npm run migrations` renders them into checked-in SQL:

- `migrations/sqlite/0001_initial.sql`: SQLite, and the same SQL for Cloudflare D1. Booleans are `INTEGER` 0/1, JSON is `TEXT`, epoch milliseconds are `INTEGER`.
- `migrations/postgres/0001_initial.sql`: Postgres. Booleans are `BOOLEAN`, JSON is `JSONB`, epoch milliseconds are `BIGINT` (configure the driver to read `BIGINT` as a number).

Each table's primary key is (`__ns`, `id`). Both files ship in the package (`@subset.dev/bookmarks-core/migrations/...`). The test fails when they differ from the generator's output and applies them to empty databases. datafn creates its own internal tables (`__datafn_meta`, `__datafn_changes`, `__datafn_idempotency`) at runtime, so they are not in these migrations.

## Wiring a host

```ts
import { createDatafnServer } from '@datafn/server';
import { bookmarksSchema, createBookmarkOperations } from '@subset.dev/bookmarks-core';

const datafn = await createDatafnServer({
  schema: bookmarksSchema,
  database, // a @superfunctions/db adapter over a database migrated with the files above
  namespaceProvider: { getNamespace: (context) => context.userId },
  authorize // the host's policy; without one, set allowUnknownResources
});
const bookmarks = createBookmarkOperations({
  executor: datafn.executor,
  detailsQueue: { enqueue: (job, options) => queue.enqueue('bookmark-details', job, options) },
  context: { userId }
});
const { bookmark, duplicate } = await bookmarks.addBookmark('https://example.com/a?utm_source=x', { tags: ['Reading'] });
```

The executor is anything with datafn's `query(payload, context)` and `mutate(payload, context)`; `@datafn/server`'s `DatafnExecutor` fits. The `DetailsQueue` port has one method, `enqueue({ bookmarkId, url }, { dedupeKey })`, which matches `@superfunctions/queue` 0.2's `enqueue` with a queue name bound.

## Operations

`createBookmarkOperations({ executor, detailsQueue, context })` returns:

- `addBookmark(url, { title?, notes?, tags?, unread? })` canonicalizes the URL with `canonicalizeUrl`. When the canonical URL is already saved, it returns that bookmark with `duplicate: true`, adds any new tags and changes nothing else; it enqueues nothing. Otherwise it creates the bookmark with `detailsState: 'pending'`, the next `apiId`, `unread` defaulting to `false`, and enqueues `{ bookmarkId, url }` with `dedupeKey = bookmarkId`.
- `updateBookmark(id, { url?, title?, notes?, unread?, archived? })`. A `url` with a different canonical URL clears the details, sets `pending` and enqueues a fetch; one that another bookmark has fails with `duplicate-url` (with `existingId`). A `url` with the same canonical URL only replaces `url`.
- `setUnread(id, unread)`, `setArchived(id, archived)`.
- `deleteBookmarks(ids)`: a hard delete that removes the tag links first; tags stay. Returns `{ deleted }`, the ids that existed.
- `addTags(bookmarkId, names)`, `removeTags(bookmarkId, names)`: names match tags by `nameKey`, so `Rust`, `rust` and `RUST` are one tag that keeps its first spelling.
- `renameTag(tagId, name)`: a case-only change is allowed; a name another tag has fails with `tag-conflict` (merge instead).
- `mergeTags(sourceTagIds, targetTagId)`: every bookmark of the sources gets the target once, then the sources are deleted. All sources must exist before anything moves.
- `retryDetails(id)`: sets `pending`, clears `detailsError`, keeps any previous details until a new fetch replaces them, and enqueues.
- `getBookmark(id)` returns a `Bookmark` with its tags sorted by `nameKey`, or `null`.

`displayTitle(bookmark)` is the user's title, then `details.title`, then the URL's host and path (just the host for `/`).

Failures are `BookmarkError`s with a `code`: `invalid-input`, `invalid-url`, `not-found`, `duplicate-url`, `tag-conflict` or `conflict` (retries exhausted). Inputs are checked before anything is written: URLs are http(s) and at most 2,048 characters, titles at most 512, notes at most 20,000, and tag names are trimmed, NFC-normalized, non-empty, at most 64 characters, and free of whitespace, commas and control characters (so they survive linkding's tag strings).

### Concurrency and failure

`apiId` comes from a compare-and-set on `bookmark_sequences` through a datafn `if` guard, so it only grows and a deleted bookmark's id is never handed out again; ids that a failed write allocated are skipped. Within one process, the check-allocate-insert step and tag creation run one at a time per executor. Across processes the unique indexes decide: when an insert fails, the operation reads whether the URL or the `apiId` is now taken and returns the duplicate or allocates again, and rethrows anything else. Every update uses an `if: { id }` guard so datafn's `merge` cannot recreate a deleted row.

The operations are not transactional: the drizzle SQLite adapter has no transactions. If enqueueing fails after a bookmark is created, the bookmark stays `pending` and `addBookmark` rejects; `retryDetails` (or SET-175's runner) enqueues it again. A failure between steps of a merge or delete leaves a state the operation can safely be run again on.

### Adapters

The tests run the operations through `@datafn/server`'s executor on the `@superfunctions/db` memory adapter, and on the drizzle adapter over better-sqlite3 and over PGlite (Postgres in WebAssembly), each migrated with the checked-in SQL. The memory adapter keys rows by `id` across namespaces and has no unique indexes, so it serves one user in one process (the per-user and two-process tests run on SQL only). `@superfunctions/db` 0.3.0's Kysely adapter fails every insert (`qb.selectAll is not a function`), so hosts use the drizzle adapter until a fixed release.

## Superfunctions reuse

- Used: `@datafn/core` 0.1.1 (schema definition) and `@superfunctions/db` 0.3.0 (`TableSchema` types for the migrations; hosts pick its adapter). Test-only: `@datafn/server` 0.2.0 (the executor), with `drizzle-orm` 0.45.4, `better-sqlite3` 13.0.3 and `@electric-sql/pglite` 0.5.13.
- `@superfunctions/cli` 0.2.0 generates migrations only by introspecting a live database and parsing library init files, and does not export its SQL generators, so `scripts/generate-migrations.mjs` renders the four tables locally; it accepts only the column types they use.
- datafn validates field types and nullability but not `unique`, `enum` or length metadata, and its many-to-many delete leaves join rows behind; the migrations and operations cover these.
- `authfn` (auth), `@superfunctions/queue` (the durable details queue, behind the `DetailsQueue` port) and `@superfunctions/storage` (favicons, `faviconKey`) belong to the hosts and SET-175.

## Not verified here

Live Postgres is deferred to SET-188 (the migration and operation tests use PGlite). D1 under workerd and Cloudflare are deferred to the host issues and SET-189. No host calls these operations yet.
