# M Graph local store (SET-6)

Private `@subset/mgraph-store` owns the local SQLite file for one M Graph service. The future SET-7 collector submits SET-5 observations; a local processing worker claims jobs and commits SET-5 graph records; query clients open read-only handles. This package has no capture, socket transport, authentication, hosted database, UI, or release surface. The host must authorize each write and each read, keep the database in a user-private directory, and close the store on shutdown. The catalog does not claim an available M Graph surface.

The package uses Node's built-in `node:sqlite` API (Node 22.13 or newer), SQLite WAL, foreign keys, and immediate write transactions. One process holds an OS mediated SQLite write lock on a private `*.writer-lock.sqlite` sidecar for the lifetime of its writer handle; separate read-only handles can read the main database concurrently. The OS releases this lock on process death, including when another writer is trying to open at the same time. Keep the database and lock sidecar together in a user-private directory and do not remove the sidecar while the service is running. The SQLite build on the development host has no FTS extension, so search uses a persisted Unicode word index with all-term matching. This indexes observation and passage text, is case insensitive, and supports neither phrase ranking nor stemming. No Postgres, R2, DynamoDB, `better-sqlite3`, or remote runtime is loaded.

## Operations

```ts
const writer = new MGraphStore('/private/path/mgraph.sqlite');
const reader = new MGraphStore('/private/path/mgraph.sqlite', { readOnly: true });
const { revision } = writer.submitObservation(observation);
const job = writer.claimNextJob('worker-id');
if (job) {
  writer.checkpointJob(job.jobId, job.leaseToken, { stage: 'passages', cursor: '2' });
  writer.completeJob(job.jobId, job.leaseToken, graphForCurrentObservation);
}
const { graph, nextCursor } = reader.queryMemory('alice', { limit: 20 });
writer.deleteSource(sourceId);
writer.close();
reader.close();
```

`submitObservation` accepts only complete or partial SET-5 observations. It validates the content hash, stable source identity, and strictly increasing `observedAt` for each source, including fractional seconds beyond milliseconds and UTC offsets. It replaces the prior source revision, derived records, search terms, and queued jobs atomically. A replay of the current observation ID and identical payload returns the same revision; an equal instant with a distinct payload or ID conflicts because time alone cannot order it, and an older submission cannot restore erased content. A durable SHA-256 ledger of observation IDs rejects any reuse after a revision replacement or source retirement without retaining the deleted payload. `observedAt` is the input ordering key and the store mints an integer revision for every accepted snapshot. The collector must provide timestamps that reflect its source revision order. A retired source ID cannot be resubmitted; a new canonical identity needs a new ID.

`claimNextJob` gives a worker a token and bounded lease. The worker may persist a checkpoint, renew the lease, finish with a SET-5 graph, or mark failure. Lease decisions use the store process's current clock; callers cannot supply a clock value. An expired job can be reclaimed after interruption; a stale token or source revision cannot commit, including before another worker reclaims it. `completeJob` requires exactly the current observation and a provenance-valid graph for that one source, writes evidence and search terms in one transaction, and accepts an identical completion replay without duplicating rows. A changed graph under the same completed token is a conflict. Failed jobs require `retryJob`; `rebuildSource` erases one live source's derived records and queues the current revision again. `rebuildSearchIndex` reconstructs the word index from persisted observations and passages. Derived graph batches are scoped to one source revision; multi-source inference and linking are deferred to the processing service's later contract, rather than silently mixing jobs.

`getSnapshot`, `queryMemory`, and `getStatus` return SET-5 shapes. Queries use a read transaction so they never combine rows from two revisions. `deleteSource` and `revokeSource` atomically erase its observations, derived records, search terms, and jobs while retaining only a terminal status. Repeating the same terminal operation is idempotent. The caller must perform the separate SET-5 IPC authorization and v1/v2 wire validation; this package does not expose a socket, accept a request ID as authority, or implement the IPC retry ledger. The host must not retry an unauthorized operation automatically.

## Migrations and validation

Schema v1 holds source revisions, observations, and jobs. Schema v2 adds derived evidence and the search index and backfills current v1 observations. Schema v3 adds the observation ID ledger and completed graph digests. During upgrade it records all retained observation IDs, removes obsolete revisions and jobs, and rebuilds the search index. A source with legacy stale work loses its unversioned derived evidence and gets exactly one job for its current observation. A completed v1 job is also requeued because v1 had no derived evidence table. A live v1 or v2 source without its current observation stops upgrade before any schema change; restore that observation from a backup before retrying. IDs of observations already purged by v1/v2 cannot be recovered during upgrade; the ledger protects every ID accepted after v3 and every ID still present at upgrade. Migrations run in transactions; a binary refuses a newer schema, and readers require the current schema. A database backup and local service shutdown are required before production upgrades. Run `npm run test --workspace=@subset/mgraph-store`, `npm run check`, and `npm run build` from the repository root.

| Boundary | Focused check |
| --- | --- |
| Fresh and v1 database | Schema version; missing current observation rejected before upgrade; historical revisions removed from snapshot, search and queue; completed v1 work requeued for evidence; old IDs remain reserved |
| v2 database | Missing current observation rejected without data loss and upgrade succeeds after repair; historical evidence and jobs removed; current revision requeued once; clean completed graph digest backfilled and changed replay rejected |
| One writer, readers | Simultaneous open after killed owner yields one writer; WAL reader sees stable old snapshot while writer commits; repeated close releases safely |
| Interruption and replay | Persisted checkpoint, lease expiry before reclaim, stale token rejection, identical completion replay, changed graph rejection |
| Source revision | Microsecond-newer observation accepted; equal-time conflict and exact replay distinguished; old job and old observation ID rejected after newer revision |
| Provenance and search | Invalid passage rejected; passage and claim readback; index rebuild |
| Retirement and rebuild | Queue, graph, and search empty after delete/revoke; live source rebuild queued |

The focused risk matrix covers legacy migration visibility (search, snapshot, queue), lease authorization (checkpoint, renew, fail, complete), writer interruption (lock recovery and checkpoint replay), and retirement (read and queue erasure). The host owns IPC authorization and platform access; this package owns only the local file and these state transitions.

The final reviewer should separately observe a process termination and reopen against a temporary local database, plus concurrent readers and writer in the service host. Railway Postgres, Cloudflare Preview, connected provider sandboxes, and Aside Browser have no SET-6 runtime boundary to exercise. Unit tests and a static build do not prove a host's authorization, IPC wire behavior, packaging, or deployment.

## Superfunctions reuse check

The prescribed `/Users/serro/Documents/dev/n/superfunctions-dev` path is absent on this host. We inspected the current checkout at `/Users/ar/dev/superfunctions`: `@datafn/client` 0.0.3 and its README describe IndexedDB, memory, and native-backed Core Data plus sync, and `@filefn/client` 0.1.1 is a browser upload SDK. Neither owns a local SQLite processing queue or the required source-revision deletion semantics. Used Superfunctions package/version: none. The published packages are not copied, vendored, or linked as runtime paths.
