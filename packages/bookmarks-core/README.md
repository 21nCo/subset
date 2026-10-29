# @subset.dev/bookmarks-core (SET-173)

The Bookmarks data model and the only operations that write bookmark data. It is private, independent of any host, database or UI, and depends only on `@subset.dev/links`, `@datafn/core` and `@superfunctions/db` (`scripts/check-workspaces.mjs` enforces this). Hosts (the web app, the CLI, the linkding-compatible API) wire authentication, a datafn executor and a details queue, then call these operations. Import and export (SET-174), the details job runner (SET-175), auth and HTTP are not here.

## Data model

`bookmarksSchema` is the datafn schema (resource version 1). Every row carries datafn's `__ns` namespace, so data is per user even though a deployment has one owner, and multi-user needs no migration.

| Resource | Fields |
| --- | --- |
| `bookmarks` | `id`, `apiId` (integer for the linkding-compatible API, unique per user, never reused), `url`, `canonicalUrl` (unique per user), `userTitle`, `notes`, `unread`, `archived`, `details` (`LinkDetailsV1` JSON), `detailsState` (`pending`, `ready` or `failed`), `detailsError`, `detailsFetchedAt`, `faviconKey`, `detailsRequest` (internal: a new id each time details are asked for after the add), `createdAt`, `updatedAt` (epoch milliseconds, from datafn's `timestamps` capability) |
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

The add-time job's `dedupeKey` is the bookmark id. A page change, or a retry of details that are not pending, writes a new `detailsRequest` id with `pending`, and its job's key is `<bookmark id>:<SHA-256 of the request id and the canonical URL>`. So each request gets its own job, including a return to a page whose earlier job is still queued, while repeating a call for the same request (a retry while pending, the same URL again) adds nothing while that job is queued.

## Operations

`createBookmarkOperations({ executor, detailsQueue, context })` returns:

- `addBookmark(url, { title?, notes?, tags?, unread? })` canonicalizes the URL with `canonicalizeUrl`. When the canonical URL is already saved, it returns that bookmark with `duplicate: true`, adds any new tags and changes nothing else; it enqueues nothing. Otherwise it creates the bookmark with `detailsState: 'pending'`, the next `apiId`, `unread` defaulting to `false`, and enqueues `{ bookmarkId, url }` with `dedupeKey = bookmarkId`.
- `updateBookmark(id, { url?, title?, notes?, unread?, archived? })` writes every field given. A `url` with a different canonical URL clears the details (and `detailsFetchedAt` and `faviconKey`) and sets `pending` with a new request; one that another bookmark has fails with `duplicate-url` (with `existingId`). A `url` with the same canonical URL keeps the details. After any `url` write the bookmark is read again and, if it is pending, a fetch of its current URL is enqueued, so repeating an update whose enqueue failed recovers.
- `setUnread(id, unread)`, `setArchived(id, archived)`.
- `deleteBookmarks(ids)`: a hard delete that removes the tag links first; tags stay. Returns `{ deleted }`, the ids that existed.
- `addTags(bookmarkId, names)`, `removeTags(bookmarkId, names)`: names match tags by `nameKey`, so `Rust`, `rust` and `RUST` are one tag that keeps its first spelling.
- `renameTag(tagId, name)`: a case-only change is allowed; a name another tag has fails with `tag-conflict` (merge instead). The check and the write run in the same per-executor chain as tag creation.
- `mergeTags(sourceTagIds, targetTagId)`: every bookmark of the sources gets the target once and each source is deleted. Each source is first recorded in `tag_merges`, then its bookmarks are moved to the target until a read finds none, then it is deleted. Before anything moves, every source must exist or have been merged into the same target by an earlier run; so repeating an interrupted merge finishes it, and an unknown source fails with `not-found`. When the target is itself being merged, the bookmarks also get the end of its merges; when its merges lead back to the source (two merges into each other), the merge fails with `conflict` and withdraws its record (see below).
- `retryDetails(id)`: sets `pending` with a new request, clears `detailsError`, keeps any previous details until a new fetch replaces them, and enqueues a fetch. A bookmark already pending keeps its request, so retrying it while its job is queued adds nothing and retrying after the job is done enqueues it again.
- `getBookmark(id)` returns a `Bookmark` with its tags sorted by `nameKey`, or `null`.

`displayTitle(bookmark)` is the user's title, then `details.title`, then the URL's host and path (just the host for `/`).

Failures are `BookmarkError`s with a `code`: `invalid-input`, `invalid-url`, `not-found`, `duplicate-url`, `tag-conflict` or `conflict` (retries exhausted). Inputs are checked before anything is written: URLs are http(s) and at most 2,048 characters, titles at most 512, notes at most 20,000, and tag names are trimmed, NFC-normalized, non-empty, at most 64 characters, and free of whitespace, commas and control characters (so they survive linkding's tag strings).

### Concurrency and failure

`apiId` is claimed by inserting the next number into `bookmark_api_ids`. Claims are never deleted, so the primary key decides between concurrent writers (the loser reads the new last number and claims the next), ids only grow, and a deleted bookmark's id is never handed out again; a claim whose bookmark insert then fails is skipped. Within one process, the check-claim-insert step, a URL update's duplicate check and write, tag creation and renames run one at a time per executor. Across processes the unique indexes decide: when a bookmark insert fails, the operation reads whether the URL is now saved and returns the duplicate, and rethrows anything else.

Updates go through datafn `merge` with an `if` guard: `{ id }`, so a deleted row is not recreated, and with a `url`, `{ id, url, canonicalUrl }` as read, so `url`, `canonicalUrl` and the details always change together. When the guard fails the operation reads the bookmark again and decides again (or fails with `not-found`).

The guard is an upstream datafn limitation: datafn reads the guarded row and then writes it, inside one transaction where the adapter has them (Postgres, at its default isolation; the drizzle SQLite adapter has none), and its executor offers no compare-and-set, so none is possible here. A write that lands between another writer's guard read and its write is overwritten by the later one. Every URL write sets `url` and `canonicalUrl` together, so the pair stays consistent, and the later writer then reads the bookmark again. A page change writes a new `detailsRequest`, so when the bookmark is on the URL just written but its request is not the one that write left, a concurrent page change landed in that window and any details may be that page's: they are cleared (guarded on the request read) and requested again. Then a pending bookmark gets a job for its current page. What remains is the details runner's own guarded store (SET-175): a fetch result that passes its guard read just before a page change is written after it.

When `addTags` or an add (new or duplicate) links a tag, it then reads `tag_merges` for it and, if the tag is being or has been merged, also links the bookmark to the merge target (following further merges of the target). A merge records a source before its last read of the source's bookmarks, so a link that read missed was written after the record and is found by the adder's read: whatever merge runs concurrently or is repeated, a bookmark given a tag keeps that tag or its merge target. A tag a merge deleted before the link is followed to the target the same way. A requested tag the bookmark already has is not linked again, but its records are read and followed the same way, so repeating an add that failed after linking a source still reaches the target, and a tag with no record writes nothing. If the records end at a deleted tag no merge recorded (the window below), the bookmark keeps the tag it has.

A merge's own move is such a link too: it links the source's bookmarks to the target and on along the target's merge records to a live tag no merge has recorded, and only then unlinks them from the source. A concurrent merge of that tag recorded it before its last read, so it either reads the bookmarks or they followed its record; so a merge chained onto a finishing one ends on the last target. The records are walked again after the last read that finds no bookmarks, before the source is deleted, so this holds for a source with no bookmarks too. When the records lead back to the source or to a tag already passed (merges into each other), or end at a deleted tag, there is no live end: the merge deletes its record (if it still names its target), keeps the bookmarks on the source (they may also have the target) and fails with `conflict`. Each merge records itself before it reads, so of two merges into each other at least one sees the other and at most one completes; both may fail, and running one again then completes it. A merge interrupted after its record keeps blocking a merge back into its source until it is repeated. One more window: if two merges of the same source into the same target run at once and one withdraws the record while the other deletes the source, a tag linked in between is found gone with no record and is created again by name. Two merges of one source into different targets can both complete; the bookmarks may end on one target while the record names the other, and repeating the merge into a target the record does not name fails with `not-found`. A bookmark tagged with a source while its merge runs has both tags until the merge moves it. What datafn leaves: it checks that the records exist and then writes the link, so a link written between that check and a concurrent delete remains as a join row; reads skip a link whose bookmark or tag is gone, so it is invisible.

The operations are not transactional. Each is safe to repeat after a failure between its steps:

- `addBookmark` inserts, then enqueues, then tags. If tagging fails, the details job is already queued and adding the URL again (a duplicate) adds the tags, following the merge records of any already linked. Repeating `addTags` does the same. If enqueueing fails, the bookmark stays `pending` with no job and `addBookmark` rejects; adding again is a duplicate and enqueues nothing, so the host calls `retryDetails` (or SET-175's runner finds pending bookmarks).
- `deleteBookmarks` unlinks a bookmark's tags, then deletes it; repeating it deletes what is left.
- `updateBookmark` with a `url` writes, then enqueues; if enqueueing fails, repeating the update enqueues the fetch.
- `mergeTags` records, moves and deletes one source at a time; repeating it finishes the rest. A source recorded but not yet deleted is still a tag, and adding it to a bookmark also adds the target.

### Adapters

The tests run the operations through `@datafn/server`'s executor on the `@superfunctions/db` memory adapter, and on the drizzle adapter over better-sqlite3 and over PGlite (Postgres in WebAssembly), each migrated with the checked-in SQL. The memory adapter keys rows by `id` across namespaces and has no unique indexes, so it serves one user in one process (the per-user and two-process tests run on SQL only). `@superfunctions/db` 0.3.0's Kysely adapter fails every insert (`qb.selectAll is not a function`), so hosts use the drizzle adapter until a fixed release.

## Superfunctions reuse

- Used: `@datafn/core` 0.1.1 (schema definition) and `@superfunctions/db` 0.3.0 (`TableSchema` types for the migrations; hosts pick its adapter). Test-only: `@datafn/server` 0.2.0 (the executor), with `drizzle-orm` 0.45.4, `better-sqlite3` 13.0.3 and `@electric-sql/pglite` 0.5.13.
- `@superfunctions/cli` 0.2.0 generates migrations only by introspecting a live database and parsing library init files, and does not export its SQL generators, so `scripts/generate-migrations.mjs` renders the tables locally; it accepts only the column types they use.
- datafn validates field types and nullability but not `unique`, `enum` or length metadata, and its many-to-many delete leaves join rows behind; the migrations and operations cover these.
- `authfn` (auth), `@superfunctions/queue` (the durable details queue, behind the `DetailsQueue` port) and `@superfunctions/storage` (favicons, `faviconKey`) belong to the hosts and SET-175.

## Not verified here

Live Postgres is deferred to SET-188 (the migration and operation tests use PGlite). D1 under workerd and Cloudflare are deferred to the host issues and SET-189. No host calls these operations yet.
