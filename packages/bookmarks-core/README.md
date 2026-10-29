# @subset.dev/bookmarks-core (SET-173)

The Bookmarks data model and the only operations that write bookmark data. It is private, independent of any host, database or UI, and depends only on `@subset.dev/links`, `@datafn/core` and `@superfunctions/db` (`scripts/check-workspaces.mjs` enforces this). Hosts (the web app, the CLI, the linkding-compatible API) wire authentication, a datafn executor and a details queue, then call these operations. Import and export (SET-174), the details job runner (SET-175), auth and HTTP are not here.

## Data model

`bookmarksSchema` is the datafn schema (resource version 1). Every row carries datafn's `__ns` namespace, so data is per user even though a deployment has one owner, and multi-user needs no migration.

| Resource | Fields |
| --- | --- |
| `bookmarks` | `id`, `apiId` (integer for the linkding-compatible API, unique per user, never reused), `url`, `canonicalUrl` (unique per user), `userTitle`, `notes`, `unread`, `archived`, `details` (`LinkDetailsV1` JSON), `detailsState` (`pending`, `ready` or `failed`), `detailsError`, `detailsFetchedAt`, `faviconKey`, `detailsRequest` (internal: a new id and the canonical URL it is for, each time details are asked for after the add), `createdAt`, `updatedAt` (epoch milliseconds, from datafn's `timestamps` capability) |
| `tags` | `id`, `name` (first spelling), `nameKey` (lowercased name, unique per user) |
| `bookmark_tags` | datafn's many-to-many join rows (`id`, `from` bookmark id, `to` tag id) for the `bookmarks.tags` / `tags.bookmarks` relation; on SQL each end is a foreign key to its bookmark or tag in the same namespace, deleted with it |
| `bookmark_api_ids` | every `apiId` ever assigned (`value`, row id = the number); rows are never deleted |
| `tag_merges` | each merged-away tag (row id = the source tag id) and its `targetId`, claimed by one merge at a time, so an interrupted merge can be run again |

datafn does not enforce `unique`, so uniqueness lives in the migrations' unique indexes, each led by `__ns`.

## Migrations

`bookmarksTables` describes the same tables in `@superfunctions/db` `TableSchema` form, and `npm run migrations` renders them into checked-in SQL:

- `migrations/sqlite/0001_initial.sql`: SQLite, and the same SQL for Cloudflare D1. Booleans are `INTEGER` 0/1, JSON is `TEXT`, epoch milliseconds are `INTEGER`.
- `migrations/postgres/0001_initial.sql`: Postgres. Booleans are `BOOLEAN`, JSON is `JSONB`, epoch milliseconds, `apiId` and its claims are `BIGINT` (configure the driver to read `BIGINT` as a number).

Each table's primary key is (`__ns`, `id`), and `bookmark_tags` (`__ns`, `from`) and (`__ns`, `to`) reference `bookmarks` and `tags` with `ON DELETE CASCADE`; SQLite hosts keep `foreign_keys` on (better-sqlite3 and D1 enforce them by default). Both files ship in the package (`@subset.dev/bookmarks-core/migrations/...`). The test fails when they differ from the generator's output and applies them to empty databases. datafn creates its own internal tables (`__datafn_meta`, `__datafn_changes`, `__datafn_idempotency`) at runtime, so they are not in these migrations.

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

The executor is anything with datafn's `query(payload, context)` and `mutate(payload, context)`; `@datafn/server`'s `DatafnExecutor` fits. The `DetailsQueue` port has one method, `enqueue({ bookmarkId, url, canonicalUrl, detailsRequest }, { dedupeKey })`, which matches `@superfunctions/queue` 0.2's `enqueue` with a queue name bound (a job with the same key that is queued or running makes it a no-op).

A details job asks for the details of `url` (its page, `canonicalUrl`) for one request, `detailsRequest` (null for the add-time request, which no later request goes back to). By the time it runs the bookmark may be gone or have a newer request (a page change, including back to the same page, or a retry), which enqueued its own job, or a URL write interrupted before it settled (see below) may have left it on another page with this request. So the runner (SET-175) stores a result only while the bookmark is still on the job's page with the job's request, with a datafn `if: { id: bookmarkId, detailsRequest, canonicalUrl }` guard, and otherwise drops it.

The add-time job's `dedupeKey` is the bookmark id. A page change, or a retry of details that are not pending, writes a new `detailsRequest` (a new id and the canonical URL) with `pending`, and its job's key is `<bookmark id>:<SHA-256 of the request id and the canonical URL>`. So each request gets its own job, including a return to a page whose earlier job is still queued, while repeating a call for the same request (a retry while pending, the same URL again) adds nothing while that job is queued.

## Operations

`createBookmarkOperations({ executor, detailsQueue, context })` returns:

- `addBookmark(url, { title?, notes?, tags?, unread? })` canonicalizes the URL with `canonicalizeUrl`. When the canonical URL is already saved, it returns that bookmark with `duplicate: true`, adds any new tags and changes nothing else; it enqueues nothing. Otherwise it creates the bookmark with `detailsState: 'pending'`, the next `apiId`, `unread` defaulting to `false`, and enqueues `{ bookmarkId, url, canonicalUrl, detailsRequest: null }` with `dedupeKey = bookmarkId`.
- `updateBookmark(id, { url?, title?, notes?, unread?, archived? })` writes every field given. A `url` with a different canonical URL clears the details (and `detailsFetchedAt` and `faviconKey`) and sets `pending` with a new request; one that another bookmark has fails with `duplicate-url` (with `existingId`). A `url` with the same canonical URL keeps the details. After any `url` write the bookmark is read again and, if it is pending, a fetch of its current URL is enqueued, so repeating an update whose enqueue failed recovers.
- `setUnread(id, unread)`, `setArchived(id, archived)`.
- `deleteBookmarks(ids)`: a hard delete; tags stay. On SQL the foreign keys delete the bookmark's tag links with it and refuse a link written after the delete. For the memory adapter, which has no foreign keys, it first removes the tag links, reading them again until none remain (so a tag added meanwhile is unlinked too). Returns `{ deleted }`, the ids that existed.
- `addTags(bookmarkId, names)`, `removeTags(bookmarkId, names)`: names match tags by `nameKey`, so `Rust`, `rust` and `RUST` are one tag that keeps its first spelling.
- `renameTag(tagId, name)`: a case-only change is allowed; a name another tag has fails with `tag-conflict` (merge instead). The check and the write run in the same per-executor chain as tag creation. After the write it reads the tag's merge record: a rename racing a merge of its tag finishes that merge (into the end of its records) and fails with `not-found`, so a rename that succeeds leaves a tag no merge has recorded.
- `mergeTags(sourceTagIds, targetTagId)`: every bookmark of the sources gets the target once and each source is deleted. Each source is first claimed in `tag_merges`, then its bookmarks are moved to the target until a read finds none, then it is deleted. The claim inserts the record only when the source has none, so of two merges of one source into different targets one succeeds and the other fails with `conflict`; a record whose merges end where the target's do is this merge's, decided against the target's current end: when the two walks find different ends and either has been merged on since, they walk again (with `conflict` if merges keep moving them), so an onward merge of the target landing between the walks does not make the record look like another merge's. Before anything moves, every source must exist or have been merged into the same target by an earlier run; so repeating an interrupted merge finishes it, also after its target was merged into another tag (the merge then goes on to the end of the target's records), and an unknown source or target fails with `not-found`. It returns the live tag at the end of the target's records, also when the target is merged on while it runs, so the result is where the bookmarks are. Both the target of a repeat and the result walk the records again when the tag they end at was merged on between the walk and its read, so neither fails with `not-found` while the records lead to a live tag; if merges keep moving the end for every walk, the merge fails with `conflict`. When the target is itself being merged, the bookmarks also get the end of its merges; when its merges lead back to the source (two merges into each other), the merge fails with `conflict` and withdraws its record (see below).
- `retryDetails(id)`: sets `pending` with a new request, clears `detailsError` and any previous details, favicon and fetch time, and enqueues a fetch. The request names the page read, and it is written, with the cleared details, only while the bookmark is still on that page; after a page change in between, the retry decides again. A bookmark already pending keeps its request, so retrying it while its job is queued adds nothing and retrying after the job is done enqueues it again.
- `getBookmark(id)` returns a `Bookmark` with its tags sorted by `nameKey`, or `null`.

`displayTitle(bookmark)` is the user's title, then `details.title`, then the URL's host and path (just the host for `/`).

Failures are `BookmarkError`s with a `code`: `invalid-input`, `invalid-url`, `not-found`, `duplicate-url`, `tag-conflict` or `conflict` (retries exhausted). Inputs are checked before anything is written: URLs are http(s) and at most 2,048 characters, titles at most 512, notes at most 20,000, and tag names are trimmed, NFC-normalized, non-empty, at most 64 characters, and free of whitespace, commas and control characters (so they survive linkding's tag strings).

### Concurrency and failure

`apiId` is claimed by inserting the next number into `bookmark_api_ids`. Claims are never deleted, so the primary key decides between concurrent writers (the loser reads the new last number and claims the next), ids only grow, and a deleted bookmark's id is never handed out again; a claim whose bookmark insert then fails is skipped. Within one process, the check-claim-insert step, a URL update's duplicate check and write, tag creation, renames and merge claims run one at a time per executor. Across processes the unique indexes decide: when a bookmark insert fails, the operation reads whether the URL is now saved and returns the duplicate, and rethrows anything else.

Updates go through datafn `merge` with an `if` guard: `{ id }`, so a deleted row is not recreated (except in the window below), and with a `url`, `{ id, url, canonicalUrl }` as read, so `url`, `canonicalUrl` and the details always change together. When the guard fails, or datafn reports the row deleted after its guard read, the operation reads the bookmark again and decides again (or fails with `not-found`).

The guard is an upstream datafn limitation: datafn reads the guarded row and then writes it, inside one transaction where the adapter has them (Postgres, at its default isolation; the drizzle SQLite adapter has none), and its executor offers no compare-and-set, so none is possible here. A write that lands between another writer's guard read and its write is overwritten by the later one. Every URL write sets `url` and `canonicalUrl` together, so the pair stays consistent, and the later writer then reads the bookmark again. Every write of a `detailsRequest` naming a page (a page change, the request again after a URL write described next, a retry) also clears the details, favicon and fetch time, so a request naming the bookmark's page means any details are that page's; when after a URL write the bookmark's request names another page than the one it is on (null is the add-time request), a concurrent page change landed in that window and any details may be that page's: they are cleared (guarded on the request read) and requested again. The row alone decides, so repeating an update interrupted before this step repairs it too; until then the runner's guard, which names the job's page as well as its request, drops the other page's result. Then a pending bookmark gets a job for its current page. What remains is the same window for two guarded writes. The details runner's store (SET-175): a fetch result that passes its guard read just before a page change is written after it. A retry of details whose guard read passes just before a page change is written after it, so the bookmark on the new page carries a request naming the old one with its details cleared, so it shows no other page's details, and the next URL write on that page clears them and requests them again. For tags, a rename whose guard read passes just before a merge deletes the tag writes the tag again under its new name, with the merge record still naming it; the rename then reads that record, finishes the merge and fails with `not-found`.

When `addTags` or an add (new or duplicate) links a tag, it then reads `tag_merges` for it and, if the tag is being or has been merged, also links the bookmark to the merge target (following further merges of the target). A merge records a source before its last read of the source's bookmarks, so a link that read missed was written after the record and is found by the adder's read: whatever merge runs concurrently or is repeated, a bookmark given a tag keeps that tag or its merge target. A tag a merge deleted before the link is followed to the target the same way. A requested tag the bookmark already has is not linked again, but its records are read and followed the same way, so repeating an add that failed after linking a source still reaches the target, and a tag with no record writes nothing. Each tag's records are followed on their own: a tag that is gone (deleted, with no record) is skipped while the other tags are linked and their records followed, so records ending at such a tag (the window below) leave the bookmark with the tags it reached. A requested tag that is gone with no record, and whose records linked nothing still there, is found or created again by name.

A merge's own move is such a link too: it links the source's bookmarks to the target and on along the target's merge records to a live tag no merge has recorded, and only then unlinks them from the source. A concurrent merge of that tag recorded it before its last read, so it either reads the bookmarks or they followed its record; so a merge chained onto a finishing one ends on the last target. The records are walked again after the last read that finds no bookmarks, before the source is deleted, so this holds for a source with no bookmarks too. Just before the delete the merge reads its record again: if a merge back that saw the cycle withdrew it meanwhile, the merge claims it again and reads and walks again, so a bookmark tagged with the source in between is moved, or kept on the source when the merge then fails with `conflict`. When the records lead back to the source or to a tag already passed (merges into each other), or end at a deleted tag, there is no live end: the merge deletes its record (if it is still the one it claimed), keeps the bookmarks on the source (they may also have the target) and fails with `conflict`. Each merge records itself before it reads, so of two merges into each other at least one sees the other and at most one completes; both may fail, and running one again then completes it. A merge interrupted after its record keeps blocking a merge back into its source, or of its source into another target, until it is repeated. What remains is the window between that last read of the record and the delete, as datafn cannot make a delete depend on another row: if a merge back withdraws the record just then, a bookmark tagged with the source in between loses that tag (on SQL the link goes with the source); closing it is deferred to SET-205. A bookmark tagged with a source while its merge runs has both tags until the merge moves it. datafn checks that the records exist and then writes the link; on SQL the foreign keys refuse a link written after a concurrent delete of its bookmark or tag (`addTags` then fails with `not-found`, or skips the tag as one deleted), and delete any link with its bookmark or tag. On the memory adapter (one process, no foreign keys) such a link remains as a join row that reads skip.

The operations are not transactional. Each is safe to repeat after a failure between its steps:

- `addBookmark` inserts, then enqueues, then tags. If tagging fails, the details job is already queued and adding the URL again (a duplicate) adds the tags, following the merge records of any already linked. Repeating `addTags` does the same. If enqueueing fails, the bookmark stays `pending` with no job and `addBookmark` rejects; adding again is a duplicate and enqueues nothing, so the host calls `retryDetails` (or SET-175's runner finds pending bookmarks).
- `deleteBookmarks` unlinks a bookmark's tags until a read finds none, then deletes it (on SQL the links go with it); repeating it deletes what is left.
- `updateBookmark` with a `url` writes, then settles the details request and enqueues; repeating it after a failure in between clears another page's details and enqueues the fetch.
- `mergeTags` claims, moves and deletes one source at a time; repeating it finishes the rest, also after the target was merged on. A source recorded but not yet deleted is still a tag, and adding it to a bookmark also adds the target.

### Adapters

The tests run the operations through `@datafn/server`'s executor on the `@superfunctions/db` memory adapter, and on the drizzle adapter over better-sqlite3 and over PGlite (Postgres in WebAssembly), each migrated with the checked-in SQL. The memory adapter keys rows by `id` across namespaces and has no unique indexes or foreign keys, so it serves one user through one executor in one process (the per-user, two-process and foreign-key tests run on SQL only). `@superfunctions/db` 0.3.0's Kysely adapter fails every insert (`qb.selectAll is not a function`), so hosts use the drizzle adapter until a fixed release.

## Superfunctions reuse

- Used: `@datafn/core` 0.1.1 (schema definition) and `@superfunctions/db` 0.3.0 (`TableSchema` types for the migrations; hosts pick its adapter). Test-only: `@datafn/server` 0.2.0 (the executor), with `drizzle-orm` 0.45.4, `better-sqlite3` 13.0.3 and `@electric-sql/pglite` 0.5.13.
- `@superfunctions/cli` 0.2.0 generates migrations only by introspecting a live database and parsing library init files, and does not export its SQL generators, so `scripts/generate-migrations.mjs` renders the tables locally; it accepts only the column types they use.
- datafn validates field types and nullability but not `unique`, `enum` or length metadata, and its many-to-many delete leaves join rows behind; the migrations (unique indexes, checks and cascading foreign keys) and the operations cover these.
- `authfn` (auth), `@superfunctions/queue` (the durable details queue, behind the `DetailsQueue` port) and `@superfunctions/storage` (favicons, `faviconKey`) belong to the hosts and SET-175.

## Not verified here

Live Postgres is deferred to SET-188 (the migration and operation tests use PGlite). D1 under workerd and Cloudflare are deferred to the host issues and SET-189. No host calls these operations yet.
