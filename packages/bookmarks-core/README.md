# @subset.dev/bookmarks-core (SET-173)

The Bookmarks data model and the only operations that write bookmark data. It is private, independent of any host, database or UI, and depends only on `@subset.dev/links`, `@datafn/core` and `@superfunctions/db` (`scripts/check-workspaces.mjs` enforces this). Hosts (the web app, the CLI, the linkding-compatible API) wire authentication, a datafn executor and a details queue, then call these operations. Import and export (SET-174), the details job runner (SET-175), auth and HTTP are not here.

## Data model

`bookmarksSchema` is the datafn schema (resource version 1). Every row carries datafn's `__ns` namespace, so data is per user even though a deployment has one owner, and multi-user needs no migration.

| Resource | Fields |
| --- | --- |
| `bookmarks` | `id`, `apiId` (integer for the linkding-compatible API, unique per user, never reused), `url`, `canonicalUrl` (unique per user), `userTitle`, `notes`, `unread`, `archived`, `details` (`LinkDetailsV1` JSON), `detailsState` (`pending`, `ready` or `failed`), `detailsError`, `detailsFetchedAt`, `faviconKey`, `createdAt`, `updatedAt` (epoch milliseconds, from datafn's `timestamps` capability) |
| `tags` | `id`, `name` (first spelling), `nameKey` (lowercased name, unique per user) |
| `bookmark_tags` | datafn's many-to-many join rows (`id`, `from` bookmark id, `to` tag id) for the `bookmarks.tags` / `tags.bookmarks` relation |
| `bookmark_api_ids` | every `apiId` ever assigned (`value`, row id = the number); rows are never deleted |
| `tag_merges` | each merged-away tag (row id = the source tag id) and its `targetId`, so an interrupted merge can be run again |

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

The executor is anything with datafn's `query(payload, context)` and `mutate(payload, context)`; `@datafn/server`'s `DatafnExecutor` fits. The `DetailsQueue` port has one method, `enqueue({ bookmarkId, url }, { dedupeKey })`, which matches `@superfunctions/queue` 0.2's `enqueue` with a queue name bound (a job with the same key that is queued or running makes it a no-op).

A details job asks for the details of `url`. By the time it runs the bookmark may be on another page (which enqueued its own job) or gone, so the runner (SET-175) stores a result only while the bookmark's `canonicalUrl` is still `canonicalizeUrl(job.url)`, with a datafn `if: { id, canonicalUrl }` guard, and otherwise drops it.

## Operations

`createBookmarkOperations({ executor, detailsQueue, context })` returns:

- `addBookmark(url, { title?, notes?, tags?, unread? })` canonicalizes the URL with `canonicalizeUrl`. When the canonical URL is already saved, it returns that bookmark with `duplicate: true`, adds any new tags and changes nothing else; it enqueues nothing. Otherwise it creates the bookmark with `detailsState: 'pending'`, the next `apiId`, `unread` defaulting to `false`, and enqueues `{ bookmarkId, url }` with `dedupeKey = bookmarkId`.
- `updateBookmark(id, { url?, title?, notes?, unread?, archived? })` writes every field given. A `url` with a different canonical URL clears the details, sets `pending` and enqueues a fetch keyed `<id>:<SHA-256 of the canonical URL>`, so a job still queued for the old URL does not absorb it; one that another bookmark has fails with `duplicate-url` (with `existingId`). A `url` with the same canonical URL keeps the details.
- `setUnread(id, unread)`, `setArchived(id, archived)`.
- `deleteBookmarks(ids)`: a hard delete that removes the tag links first; tags stay. Returns `{ deleted }`, the ids that existed.
- `addTags(bookmarkId, names)`, `removeTags(bookmarkId, names)`: names match tags by `nameKey`, so `Rust`, `rust` and `RUST` are one tag that keeps its first spelling.
- `renameTag(tagId, name)`: a case-only change is allowed; a name another tag has fails with `tag-conflict` (merge instead).
- `mergeTags(sourceTagIds, targetTagId)`: every bookmark of the sources gets the target once, then each source is recorded in `tag_merges` and deleted. Before anything moves, every source must exist or have been merged into the same target by an earlier run; so repeating an interrupted merge finishes it, and an unknown source fails with `not-found`.
- `retryDetails(id)`: sets `pending`, clears `detailsError`, keeps any previous details until a new fetch replaces them, and enqueues under the same URL key as a page change.
- `getBookmark(id)` returns a `Bookmark` with its tags sorted by `nameKey`, or `null`.

`displayTitle(bookmark)` is the user's title, then `details.title`, then the URL's host and path (just the host for `/`).

Failures are `BookmarkError`s with a `code`: `invalid-input`, `invalid-url`, `not-found`, `duplicate-url`, `tag-conflict` or `conflict` (retries exhausted). Inputs are checked before anything is written: URLs are http(s) and at most 2,048 characters, titles at most 512, notes at most 20,000, and tag names are trimmed, NFC-normalized, non-empty, at most 64 characters, and free of whitespace, commas and control characters (so they survive linkding's tag strings).

### Concurrency and failure

`apiId` is claimed by inserting the next number into `bookmark_api_ids`. Claims are never deleted, so the primary key decides between concurrent writers (the loser reads the new last number and claims the next), ids only grow, and a deleted bookmark's id is never handed out again; a claim whose bookmark insert then fails is skipped. Within one process, the check-claim-insert step and tag creation run one at a time per executor. Across processes the unique indexes decide: when a bookmark insert fails, the operation reads whether the URL is now saved and returns the duplicate, and rethrows anything else.

Updates go through datafn `merge` with an `if` guard: `{ id }`, so a deleted row is not recreated, and with a `url`, `{ id, url, canonicalUrl }` as read, so `url`, `canonicalUrl` and the details always change together. When the guard fails the operation reads the bookmark again and decides again (or fails with `not-found`). datafn reads the guard and then writes, inside one transaction where the adapter has them (Postgres, at its default isolation; the drizzle SQLite adapter has none), so it is not a database-level compare-and-set: a write that lands between another writer's guard read and its write is overwritten by the later one. Because every URL write sets `url` and `canonicalUrl` together, the pair stays consistent even then; only details stored for the overwritten page inside that window would stay until `retryDetails`.

A tag that a concurrent merge deletes after `addTags` or `addBookmark` found it is created again, because datafn refuses to link a missing record. datafn checks that the records exist and then writes the link, so a link written between that check and a concurrent delete can remain; reads skip a link whose bookmark or tag is gone, so it is invisible, and the tag is not on the bookmark.

The operations are not transactional. Each is safe to repeat after a failure between its steps:

- `addBookmark` inserts, then enqueues, then tags. If tagging fails, the details job is already queued and adding the URL again (a duplicate) adds the tags. If enqueueing fails, the bookmark stays `pending` with no job and `addBookmark` rejects; adding again is a duplicate and enqueues nothing, so the host calls `retryDetails` (or SET-175's runner finds pending bookmarks).
- `deleteBookmarks` unlinks a bookmark's tags, then deletes it; repeating it deletes what is left.
- `mergeTags` moves, records and deletes one source at a time; repeating it finishes the rest.

### Adapters

The tests run the operations through `@datafn/server`'s executor on the `@superfunctions/db` memory adapter, and on the drizzle adapter over better-sqlite3 and over PGlite (Postgres in WebAssembly), each migrated with the checked-in SQL. The memory adapter keys rows by `id` across namespaces and has no unique indexes, so it serves one user in one process (the per-user and two-process tests run on SQL only). `@superfunctions/db` 0.3.0's Kysely adapter fails every insert (`qb.selectAll is not a function`), so hosts use the drizzle adapter until a fixed release.

## Superfunctions reuse

- Used: `@datafn/core` 0.1.1 (schema definition) and `@superfunctions/db` 0.3.0 (`TableSchema` types for the migrations; hosts pick its adapter). Test-only: `@datafn/server` 0.2.0 (the executor), with `drizzle-orm` 0.45.4, `better-sqlite3` 13.0.3 and `@electric-sql/pglite` 0.5.13.
- `@superfunctions/cli` 0.2.0 generates migrations only by introspecting a live database and parsing library init files, and does not export its SQL generators, so `scripts/generate-migrations.mjs` renders the tables locally; it accepts only the column types they use.
- datafn validates field types and nullability but not `unique`, `enum` or length metadata, and its many-to-many delete leaves join rows behind; the migrations and operations cover these.
- `authfn` (auth), `@superfunctions/queue` (the durable details queue, behind the `DetailsQueue` port) and `@superfunctions/storage` (favicons, `faviconKey`) belong to the hosts and SET-175.

## Not verified here

Live Postgres is deferred to SET-188 (the migration and operation tests use PGlite). D1 under workerd and Cloudflare are deferred to the host issues and SET-189. No host calls these operations yet.
