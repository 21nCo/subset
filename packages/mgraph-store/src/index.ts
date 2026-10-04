import { createHash, randomUUID } from 'node:crypto';
import { chmodSync, realpathSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { isDeepStrictEqual } from 'node:util';
import { z } from 'zod';
import {
  parseGraphSnapshot, parseObservation, processingStatusSchema,
  type GraphSnapshot, type Observation,
} from '@subset/mgraph-contracts';

/** SQLite layout understood by writers and required by read-only clients. */
export const STORE_SCHEMA_VERSION = 5;
const uuid = z.uuid();
const checkpointSchema = z.strictObject({ stage: z.string().min(1).max(128), cursor: z.string().max(4096).optional() });
/** Persisted worker progress that survives lease expiry and process restart. */
export type JobCheckpoint = z.infer<typeof checkpointSchema>;
/** A claim scoped to one source revision and one expiring worker lease. */
export type ProcessingJob = {
  jobId: string;
  workerId: string;
  sourceId: string;
  revision: number;
  observationId: string;
  attempts: number;
  checkpoint: JobCheckpoint | null;
  leaseToken: string;
  leaseUntil: number;
};
type SourceRow = {
  source_id: string; kind: string; locator: string; display_name: string | null;
  application_bundle_id: string | null; revision: number; observed_at: string | null;
  state: string; reason: string | null; updated_at: string;
};
type JobRow = {
  job_id: string; source_id: string; revision: number; observation_id: string;
  state: string; attempts: number; checkpoint: string | null;
  lease_token: string | null; lease_until: number | null; graph_hash: string | null;
};
type JsonRow = { payload: string };
type IdRow = { source_id: string };

/** A valid operation that conflicts with source identity, revision, or lease state. */
export class StoreConflict extends Error { constructor(message: string) { super(message); this.name = 'StoreConflict'; } }
/** A database or schema condition that prevents this process from serving the store. */
export class StoreUnavailable extends Error { constructor(message: string) { super(message); this.name = 'StoreUnavailable'; } }

/** Resolve the database path so aliases contend for the same writer sidecar. */
function canonicalPath(filename: string): string {
  if (filename === ':memory:') throw new StoreUnavailable('Store requires a local database file');
  const full = resolve(filename);
  try { return realpathSync(full); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
    return join(realpathSync(dirname(full)), basename(full));
  }
}

/** Hold an OS-released SQLite write lock for the writer handle's lifetime. */
function acquireWriterLock(filename: string): DatabaseSync {
  // SQLite's OS lock is released on process death. Unlike a PID file, it cannot be
  // reclaimed by a racing opener while a new owner is initializing or closing.
  const lock = new DatabaseSync(`${filename}.writer-lock.sqlite`);
  try {
    chmodSync(`${filename}.writer-lock.sqlite`, 0o600);
    lock.exec('PRAGMA busy_timeout = 0; BEGIN IMMEDIATE');
    return lock;
  } catch (error) {
    lock.close();
    if (error instanceof Error && /SQLITE_BUSY|database is locked/.test(error.message)) {
      throw new StoreUnavailable('Another process owns the M Graph writer');
    }
    throw error;
  }
}

/** Hash the exact spelling stored by pre-v4 observation ledgers. */
function rawIdHash(id: string): string { return createHash('sha256').update(id).digest('hex'); }
/** Hash the canonical identity used by current writes. */
function idHash(id: string): string { return rawIdHash(id.toLowerCase()); }
/** Digest a validated graph for completion replay checks. */
function graphHash(graph: GraphSnapshot): string { return createHash('sha256').update(JSON.stringify(graph)).digest('hex'); }
/** Reject malformed UUIDs and fold accepted IDs for SQLite lookups. */
function canonicalId(id: string): string { return uuid.parse(id).toLowerCase(); }
const uuidFields = new Set(['sourceId', 'observationId', 'targetObservationId', 'passageId', 'claimId', 'profileId',
  'relationshipId', 'clusterId', 'fromProfileId', 'toProfileId']);
const uuidArrays = new Set(['claimIds', 'memberProfileIds']);

/** Fold only declared UUID fields and reference arrays; schemas reject other input. */
function canonicalPayload(value: unknown, ancestors = new Set<object>(), depth = 0): unknown {
  if (!value || typeof value !== 'object') return value;
  if (depth > 32 || ancestors.has(value)) throw new TypeError('Invalid cyclic or deeply nested graph');
  ancestors.add(value);
  const fold = (field: unknown): unknown => canonicalPayload(field, ancestors, depth + 1);
  const result = Array.isArray(value) ? value.map(fold) : Object.fromEntries(Object.entries(value).map(([key, field]) => {
    if (uuidFields.has(key) && typeof field === 'string') return [key, field.toLowerCase()];
    if (uuidArrays.has(key) && Array.isArray(field)) return [key, field.map(item => typeof item === 'string' ? item.toLowerCase() : item)];
    return [key, fold(field)];
  }));
  ancestors.delete(value);
  return result;
}

/** Fold UUIDs after one SET-5 validation; canonical spelling preserves content hashes. */
function canonicalObservation(parsed: Observation): Observation {
  return canonicalPayload(parsed) as Observation;
}

/** Fold UUID spelling before one graph validation so mixed-case references agree. */
function canonicalGraph(input: unknown): GraphSnapshot {
  return parseGraphSnapshot(canonicalPayload(input));
}

/** An opaque old hash without its UUID cannot prove case-insensitive identity. */
function assertResolvableLegacyLedger(db: DatabaseSync, version: number): void {
  const retained = new Set<string>();
  for (const row of db.prepare('SELECT observation_id FROM observations').all() as { observation_id: string }[]) {
    retained.add(rawIdHash(row.observation_id));
    retained.add(idHash(row.observation_id));
  }
  for (const row of db.prepare('SELECT id_hash FROM observation_ids').all() as { id_hash: string }[]) {
    if (!retained.has(row.id_hash)) {
      throw new StoreUnavailable(`V${version} observation ID ledger has an unresolvable retired ID; restore a backup or start a new store`);
    }
  }
}

/** Reject aliases before legacy rows or the canonical ID ledger can collide. */
function assertNoCaseFoldCollisions(db: DatabaseSync): void {
  for (const [table, columns] of [['sources', 'lower(source_id)'], ['observations', 'lower(observation_id)'],
    ['jobs', 'lower(job_id)'], ['evidence', 'kind, lower(entity_id)']] as const) {
    if (db.prepare(`SELECT 1 FROM ${table} GROUP BY ${columns} HAVING count(*) > 1 LIMIT 1`).get()) {
      throw new StoreUnavailable(`Case-folded UUID collision in ${table}`);
    }
  }
}

/** Normalize retained UUIDs and references before a v4 writer can serve requests. */
function normalizePersistedIds(db: DatabaseSync): void {
  assertNoCaseFoldCollisions(db);
  // The preflight rejects unresolvable hashes. Reserve each retained observation
  // under its canonical identity before changing its stored spelling.
  for (const row of db.prepare('SELECT observation_id FROM observations').all() as { observation_id: string }[]) {
    db.prepare('INSERT OR IGNORE INTO observation_ids(id_hash) VALUES (?)').run(idHash(row.observation_id.toLowerCase()));
  }
  db.exec('PRAGMA defer_foreign_keys = ON');
  db.exec(`UPDATE sources SET source_id = lower(source_id);
    UPDATE observations SET source_id = lower(source_id), observation_id = lower(observation_id);
    UPDATE jobs SET source_id = lower(source_id), observation_id = lower(observation_id), job_id = lower(job_id),
      lease_token = lower(lease_token);
    UPDATE evidence SET source_id = lower(source_id), entity_id = lower(entity_id);
    UPDATE evidence_terms SET source_id = lower(source_id);`);
  for (const row of db.prepare('SELECT observation_id, payload FROM observations').all() as { observation_id: string; payload: string }[]) {
    const payload = canonicalObservation(parseObservation(JSON.parse(row.payload)));
    db.prepare('UPDATE observations SET payload = ? WHERE observation_id = ?').run(JSON.stringify(payload), row.observation_id);
  }
  for (const row of db.prepare('SELECT kind, entity_id, payload FROM evidence').all() as { kind: string; entity_id: string; payload: string }[]) {
    db.prepare('UPDATE evidence SET payload = ? WHERE kind = ? AND entity_id = ?')
      .run(JSON.stringify(canonicalPayload(JSON.parse(row.payload))), row.kind, row.entity_id);
  }
  for (const row of db.prepare("SELECT job_id, source_id, observation_id FROM jobs WHERE state = 'complete'")
    .all() as { job_id: string; source_id: string; observation_id: string }[]) {
    db.prepare('UPDATE jobs SET graph_hash = ? WHERE job_id = ?')
      .run(graphHash(storedCompletedGraph(db, row.source_id, row.observation_id)), row.job_id);
  }
}
/** Reconstruct a completion for provenance checks and replay digest migration. */
function storedCompletedGraph(db: DatabaseSync, sourceId: string, observationId: string): GraphSnapshot {
  const observation = db.prepare('SELECT payload FROM observations WHERE source_id = ? AND observation_id = ?')
    .get(sourceId, observationId) as JsonRow | undefined;
  if (!observation) throw new StoreUnavailable('Completed job has no observation during migration');
  const entities = (kind: string): unknown[] => (db.prepare('SELECT payload FROM evidence WHERE source_id = ? AND kind = ? ORDER BY rowid')
    .all(sourceId, kind) as JsonRow[]).map(row => JSON.parse(row.payload));
  return parseGraphSnapshot({ schemaVersion: 1, observations: [JSON.parse(observation.payload)],
    passages: entities('passage'), claims: entities('claim'), profiles: entities('profile'),
    relationships: entities('relationship'), clusters: entities('cluster'), statuses: [] });
}

/** Serialize a write; rollback failures must not hide the original exception. */
function transaction<T>(db: DatabaseSync, fn: () => T): T {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    rollbackQuietly(db);
    throw error;
  }
}

/** Preserve the primary transaction failure if SQLite has already rolled back. */
function rollbackQuietly(db: DatabaseSync): void {
  try { db.exec('ROLLBACK'); }
  catch { /* SQLite may already have ended the transaction; preserve the original error. */ }
}

/** Use only the store process clock for lease ownership decisions. */
function leaseNow(): number {
  const at = Date.now();
  if (!Number.isSafeInteger(at) || at < 0) throw new StoreUnavailable('Invalid system clock');
  return at;
}

/** Keep source rows and derived evidence in one read snapshot. */
function readTransaction<T>(db: DatabaseSync, fn: () => T): T {
  db.exec('BEGIN');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    rollbackQuietly(db);
    throw error;
  }
}

/** Replace uncertain derived state with one current-revision job, or purge a tombstone. */
function requeueLegacySource(db: DatabaseSync, sourceId: string): void {
  db.prepare('DELETE FROM evidence WHERE source_id = ?').run(sourceId);
  db.prepare('DELETE FROM evidence_terms WHERE source_id = ?').run(sourceId);
  const source = db.prepare('SELECT state, revision FROM sources WHERE source_id = ?').get(sourceId) as
    { state: string; revision: number };
  if (!live(source.state)) return;
  const current = db.prepare('SELECT observation_id FROM observations WHERE source_id = ? AND revision = ?')
    .get(sourceId, source.revision) as { observation_id: string } | undefined;
  if (!current) throw new StoreUnavailable('Live source has no current observation during upgrade');
  db.prepare('DELETE FROM jobs WHERE source_id = ?').run(sourceId);
  db.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, ?, ?, 'pending')")
    .run(randomUUID(), sourceId, source.revision, current.observation_id);
  db.prepare("UPDATE sources SET state = 'pending', reason = NULL, updated_at = ? WHERE source_id = ?")
    .run(nowIso(), sourceId);
}

/** Legacy evidence lacks revision metadata; retain it only with valid current provenance. */
function markUnprovenLegacyEvidence(db: DatabaseSync, rebuildSources: Set<string>): void {
  for (const row of db.prepare('SELECT DISTINCT source_id FROM evidence').all() as IdRow[]) {
    const source = db.prepare('SELECT state, revision FROM sources WHERE source_id = ?').get(row.source_id) as
      { state: string; revision: number } | undefined;
    if (!source) throw new StoreUnavailable('Legacy evidence has no source');
    if (!live(source.state)) {
      rebuildSources.add(row.source_id);
      continue;
    }
    const completed = db.prepare(`SELECT j.observation_id FROM jobs j JOIN observations o
      ON o.observation_id = j.observation_id AND o.source_id = j.source_id AND o.revision = j.revision
      WHERE j.source_id = ? AND j.revision = ? AND j.state = 'complete' LIMIT 1`)
      .get(row.source_id, source.revision) as { observation_id: string } | undefined;
    if (!completed) {
      rebuildSources.add(row.source_id);
      continue;
    }
    try { storedCompletedGraph(db, row.source_id, completed.observation_id); }
    catch { rebuildSources.add(row.source_id); }
  }
}

/** Reserve old IDs, then remove rows that no longer belong to their source revision. */
function pruneObsoleteWork(db: DatabaseSync): void {
  for (const row of db.prepare('SELECT observation_id FROM observations').all() as { observation_id: string }[]) {
    db.prepare('INSERT OR IGNORE INTO observation_ids(id_hash) VALUES (?)').run(idHash(row.observation_id));
  }
  db.exec(`DELETE FROM jobs WHERE source_id IN (SELECT source_id FROM sources WHERE state IN ('deleted', 'permissionRevoked'))
    OR revision != (SELECT revision FROM sources WHERE source_id = jobs.source_id)
    OR NOT EXISTS (SELECT 1 FROM observations o WHERE o.observation_id = jobs.observation_id
      AND o.source_id = jobs.source_id AND o.revision = jobs.revision);
    DELETE FROM observations WHERE source_id IN (SELECT source_id FROM sources WHERE state IN ('deleted', 'permissionRevoked'))
    OR revision != (SELECT revision FROM sources WHERE source_id = observations.source_id);`);
}

/** Upgrade legacy evidence and queue state within the caller's one migration transaction. */
function upgradeToV3(db: DatabaseSync, version: number): void {
  assertNoCaseFoldCollisions(db);
  db.exec(`
    CREATE TABLE observation_ids (id_hash TEXT PRIMARY KEY);
    ALTER TABLE jobs ADD COLUMN graph_hash TEXT;
    PRAGMA user_version = 3;
  `);
  const insert = db.prepare('INSERT INTO observation_ids(id_hash) VALUES (?)');
  for (const row of db.prepare('SELECT observation_id FROM observations').all() as { observation_id: string }[]) {
    insert.run(idHash(row.observation_id));
  }
  // Older schemas could retain superseded revisions. Remember their IDs before
  // removing the payloads so an old ID cannot be submitted again after upgrade.
  const staleSources = db.prepare(`SELECT DISTINCT o.source_id FROM observations o JOIN sources s ON s.source_id = o.source_id
    WHERE o.revision != s.revision OR s.state IN ('deleted', 'permissionRevoked')
    UNION SELECT DISTINCT j.source_id FROM jobs j JOIN sources s ON s.source_id = j.source_id
    WHERE j.revision != s.revision OR s.state IN ('deleted', 'permissionRevoked')
    OR NOT EXISTS (SELECT 1 FROM observations o WHERE o.observation_id = j.observation_id
      AND o.source_id = j.source_id AND o.revision = j.revision)`).all() as IdRow[];
  const rebuildSources = new Set(staleSources.map(row => row.source_id));
  if (version === 2) markUnprovenLegacyEvidence(db, rebuildSources);
  // V2 can also be the committed midpoint of a V1 upgrade from an older
  // binary. A completed job without persisted evidence cannot prove that
  // processing finished; queue its current observation again.
  for (const row of db.prepare(`SELECT s.source_id FROM sources s
    WHERE s.state NOT IN ('deleted', 'permissionRevoked')
    AND (NOT EXISTS (SELECT 1 FROM jobs j WHERE j.source_id = s.source_id AND j.revision = s.revision)
      OR (s.state IN ('complete', 'partial') AND NOT EXISTS
        (SELECT 1 FROM evidence e WHERE e.source_id = s.source_id)))`).all() as IdRow[]) {
    rebuildSources.add(row.source_id);
  }
  if (version === 1) {
    // V1 had no evidence table. A completed V1 job cannot have persisted its
    // result, even if its observation is the current revision.
    for (const row of db.prepare(`SELECT source_id FROM sources WHERE state IN ('complete', 'partial')
      UNION SELECT source_id FROM jobs WHERE state = 'complete'`).all() as IdRow[]) {
      rebuildSources.add(row.source_id);
    }
  }
  pruneObsoleteWork(db);
  for (const sourceId of rebuildSources) requeueLegacySource(db, sourceId);
  const update = db.prepare('UPDATE jobs SET graph_hash = ? WHERE job_id = ?');
  for (const row of db.prepare("SELECT job_id, source_id, observation_id FROM jobs WHERE state = 'complete'")
    .all() as { job_id: string; source_id: string; observation_id: string }[]) {
    update.run(graphHash(storedCompletedGraph(db, row.source_id, row.observation_id)), row.job_id);
  }
}

/** Repair an older v3 file left after its predecessor committed v2 separately. */
function recoverV3Midpoint(db: DatabaseSync): void {
  const rebuildSources = new Set<string>();
  pruneObsoleteWork(db);
  for (const row of db.prepare(`SELECT s.source_id FROM sources s
    WHERE s.state NOT IN ('deleted', 'permissionRevoked') AND
    (NOT EXISTS (SELECT 1 FROM jobs j WHERE j.source_id = s.source_id AND j.revision = s.revision)
    OR (s.state IN ('complete', 'partial') AND NOT EXISTS
      (SELECT 1 FROM evidence e WHERE e.source_id = s.source_id)))`).all() as IdRow[]) {
    rebuildSources.add(row.source_id);
  }
  markUnprovenLegacyEvidence(db, rebuildSources);
  for (const sourceId of rebuildSources) requeueLegacySource(db, sourceId);
}

/** Apply all schema and data repairs atomically; never expose an intermediate version. */
function migrate(db: DatabaseSync): void {
  const version = Number((db.prepare('PRAGMA user_version').get() as { user_version: number }).user_version);
  if (version > STORE_SCHEMA_VERSION) throw new StoreUnavailable(`Store schema ${version} is newer than this binary`);
  if (version >= 1 && version < STORE_SCHEMA_VERSION) validateLegacyRows(db, version);
  if (version >= 1 && version < STORE_SCHEMA_VERSION && db.prepare(`SELECT 1 FROM sources s WHERE s.state NOT IN ('deleted', 'permissionRevoked')
    AND NOT EXISTS (SELECT 1 FROM observations o WHERE o.source_id = s.source_id AND o.revision = s.revision)
    LIMIT 1`).get()) {
    throw new StoreUnavailable(`V${version} source needs reprocessing but has no current observation`);
  }
  if (version === STORE_SCHEMA_VERSION) return;
  // A process exit during an upgrade must leave either the old schema or the
  // fully repaired new schema. No intermediate v2 commit may strand v1 work.
  transaction(db, () => {
    if (version === 3 || version === 4) assertResolvableLegacyLedger(db, version);
    if (version < 1) {
      db.exec(`
        CREATE TABLE sources (
          source_id TEXT PRIMARY KEY, kind TEXT NOT NULL, locator TEXT NOT NULL,
          display_name TEXT, application_bundle_id TEXT, revision INTEGER NOT NULL DEFAULT 0,
          observed_at TEXT, state TEXT NOT NULL, reason TEXT, updated_at TEXT NOT NULL
        );
        CREATE TABLE observations (
          observation_id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
          revision INTEGER NOT NULL, payload TEXT NOT NULL,
          UNIQUE(source_id, revision)
        );
        CREATE TABLE jobs (
          job_id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
          revision INTEGER NOT NULL, observation_id TEXT NOT NULL,
          state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
          checkpoint TEXT, lease_token TEXT, lease_until INTEGER
        );
        CREATE INDEX jobs_ready ON jobs(state, lease_until, job_id);
        PRAGMA user_version = 1;
      `);
    }
    if (version < 2) {
      db.exec('ALTER TABLE jobs ADD COLUMN worker_id TEXT');
      db.exec(`
        CREATE TABLE evidence (
          kind TEXT NOT NULL, entity_id TEXT NOT NULL, source_id TEXT NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
          payload TEXT NOT NULL, PRIMARY KEY(kind, entity_id)
        );
        CREATE INDEX evidence_source ON evidence(source_id, kind);
        CREATE TABLE evidence_terms (
          source_id TEXT NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
          kind TEXT NOT NULL, term TEXT NOT NULL,
          PRIMARY KEY(source_id, kind, term)
        );
        CREATE INDEX evidence_terms_lookup ON evidence_terms(term, source_id);
        PRAGMA user_version = 2;
      `);
    }
    if (version < 3) upgradeToV3(db, version);
    if (version < 4) {
      if (version === 3) recoverV3Midpoint(db);
      normalizePersistedIds(db);
      db.exec('PRAGMA user_version = 4');
    }
    if (version < 5) {
      rebuildSearchTerms(db);
      db.exec('PRAGMA user_version = 5');
    }
  });
}

/** Refuse retained legacy rows that cannot be served after a successful upgrade. */
function validateLegacyRows(db: DatabaseSync, version: number): void {
  validateLegacySources(db, version);
  validateLegacyJobs(db, version);
}

/** Check current source payloads before migration can rewrite or discard them. */
function validateLegacySources(db: DatabaseSync, version: number): void {
  for (const source of db.prepare('SELECT * FROM sources').all() as SourceRow[]) {
    try { statusFrom(source); }
    catch { throw new StoreUnavailable(`V${version} source ${source.source_id} has invalid status`); }
    if (!Number.isSafeInteger(source.revision) || source.revision < 0) {
      throw new StoreUnavailable(`V${version} source ${source.source_id} has invalid revision`);
    }
    if (!live(source.state)) continue;
    const current = db.prepare('SELECT observation_id, payload FROM observations WHERE source_id = ? AND revision = ?')
      .get(source.source_id, source.revision) as { observation_id: string; payload: string } | undefined;
    if (!current) continue; // The explicit missing-current-observation guard reports this below.
    let observation: Observation;
    try { observation = canonicalObservation(parseObservation(JSON.parse(current.payload))); }
    catch { throw new StoreUnavailable(`V${version} source ${source.source_id} has invalid current observation`); }
    if (observation.observationId !== current.observation_id.toLowerCase() ||
        observation.source.sourceId !== source.source_id.toLowerCase() ||
        observation.source.kind !== source.kind || observation.source.locator !== source.locator ||
        (observation.source.applicationBundleId ?? null) !== source.application_bundle_id ||
        observation.observedAt !== source.observed_at ||
        (observation.state !== 'complete' && observation.state !== 'partial')) {
      throw new StoreUnavailable(`V${version} source ${source.source_id} has mismatched current observation`);
    }
  }
}

/** Check resumable jobs and leases before migration can change queue ownership. */
function validateLegacyJobs(db: DatabaseSync, version: number): void {
  for (const job of db.prepare(`SELECT j.* FROM jobs j JOIN sources s ON s.source_id = j.source_id
    WHERE j.revision = s.revision AND s.state NOT IN ('deleted', 'permissionRevoked')
    AND EXISTS (SELECT 1 FROM observations o WHERE o.observation_id = j.observation_id
      AND o.source_id = j.source_id AND o.revision = j.revision)`).all() as JobRow[]) {
    try {
      canonicalId(job.job_id);
      canonicalId(job.observation_id);
      if (!['pending', 'processing', 'failed', 'complete'].includes(job.state)) throw new Error('Invalid job state');
      if (!Number.isSafeInteger(job.attempts) || job.attempts < 0) throw new Error('Invalid job attempts');
      if (job.checkpoint !== null) checkpointSchema.parse(JSON.parse(job.checkpoint));
      if (job.state === 'processing' && (!Number.isSafeInteger(job.lease_until) || job.lease_until! < 0 ||
          job.lease_token === null)) throw new Error('Invalid processing lease');
      if (job.lease_token !== null) canonicalId(job.lease_token);
    } catch {
      throw new StoreUnavailable(`V${version} job ${job.job_id} has invalid retained state`);
    }
  }
}

/** Validate a persisted status before returning it to a SET-5 consumer. */
function statusFrom(row: SourceRow): GraphSnapshot['statuses'][number] {
  const base = { schemaVersion: 1 as const, sourceId: row.source_id, updatedAt: row.updated_at };
  let status: unknown;
  if (row.state === 'partial' || row.state === 'failed' || row.state === 'permissionRevoked') {
    status = { ...base, state: row.state, reason: row.reason ?? 'Unknown reason' };
  } else {
    status = { ...base, state: row.state };
  }
  const parsed = processingStatusSchema.safeParse(status);
  if (!parsed.success) throw new StoreUnavailable(`Invalid persisted status for source ${row.source_id}`);
  return parsed.data;
}
function nowIso(): string { return new Date().toISOString(); }
function live(state: string): boolean { return state !== 'deleted' && state !== 'permissionRevoked'; }
/** Compare full fractional timestamps without millisecond truncation. */
function compareObservedAt(left: string, right: string): number {
  // The SET-5 schema permits arbitrary fractional precision and UTC offsets.
  // Date.parse truncates to milliseconds, so compare the seconds and fraction
  // separately after both timestamps have been validated as ISO datetimes.
  const parts = (value: string): { second: number; fraction: string } => {
    const match = /^(.*:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$/.exec(value);
    if (!match) throw new StoreConflict('Invalid persisted observation timestamp');
    const second = Date.parse(`${match[1]}${match[3]}`);
    if (!Number.isFinite(second)) throw new StoreConflict('Invalid persisted observation timestamp');
    const fraction = match[2] ?? '';
    let end = fraction.length;
    while (end > 0 && fraction[end - 1] === '0') end--;
    return { second, fraction: fraction.slice(0, end) };
  };
  const a = parts(left);
  const b = parts(right);
  if (a.second !== b.second) return Math.sign(a.second - b.second);
  const width = Math.max(a.fraction.length, b.fraction.length);
  const aFraction = a.fraction.padEnd(width, '0');
  const bFraction = b.fraction.padEnd(width, '0');
  if (aFraction < bFraction) return -1;
  if (aFraction > bFraction) return 1;
  return 0;
}

/** Decide replay before a new revision can erase the current snapshot. */
function currentReplay(db: DatabaseSync, existing: SourceRow | undefined, observation: Observation):
  { observationId: string; revision: number; replayed: true } | undefined {
  if (!existing) return undefined;
  if (!live(existing.state)) throw new StoreConflict('A retired source ID cannot be reused');
  if (existing.kind !== observation.source.kind || existing.locator !== observation.source.locator ||
      existing.application_bundle_id !== (observation.source.applicationBundleId ?? null)) {
    throw new StoreConflict('Source identity changed');
  }
  if (!existing.observed_at || compareObservedAt(observation.observedAt, existing.observed_at) > 0) return undefined;
  const prior = db.prepare('SELECT source_id, payload, revision FROM observations WHERE observation_id = ?')
    .get(observation.observationId) as { source_id: string; payload: string; revision: number } | undefined;
  if (prior?.source_id === observation.source.sourceId && prior.payload === JSON.stringify(observation)) {
    return { observationId: observation.observationId, revision: prior.revision, replayed: true };
  }
  throw new StoreConflict('Observation is older than the current source revision');
}

/** Apply one Unicode spelling to both indexed content and incoming queries. */
function terms(text: string): string[] {
  return [...new Set((text.toLowerCase().normalize('NFC').match(/[\p{L}\p{N}]+/gu) ?? []))];
}
/** Persist each distinct search token for one live source and evidence kind. */
function indexText(db: DatabaseSync, sourceId: string, kind: string, body: string): void {
  const insert = db.prepare('INSERT OR IGNORE INTO evidence_terms(source_id, kind, term) VALUES (?, ?, ?)');
  for (const term of terms(body)) insert.run(sourceId, kind, term);
}

/** Select only the user-visible text field for each derived evidence kind. */
function evidenceSearchText(kind: string, entity: unknown): string {
  const field = ({ passage: 'text', claim: 'statement', profile: 'name', relationship: 'kind', cluster: 'name' } as
    Record<string, string>)[kind];
  const value = field && entity && typeof entity === 'object' ? (entity as Record<string, unknown>)[field] : undefined;
  if (typeof value !== 'string') throw new StoreUnavailable(`Invalid searchable ${kind} evidence`);
  return value;
}

/** Rebuild observation and derived evidence terms in the caller's transaction. */
function rebuildSearchTerms(db: DatabaseSync): void {
  db.exec('DELETE FROM evidence_terms');
  for (const row of db.prepare(`SELECT o.source_id, o.payload FROM observations o JOIN sources s
    ON s.source_id = o.source_id AND s.revision = o.revision WHERE s.state NOT IN ('deleted', 'permissionRevoked')`)
    .all() as { source_id: string; payload: string }[]) {
    const observation = parseObservation(JSON.parse(row.payload));
    if (observation.state === 'complete' || observation.state === 'partial') {
      indexText(db, row.source_id, 'observation', observation.content);
    }
  }
  for (const row of db.prepare('SELECT source_id, kind, payload FROM evidence')
    .all() as { source_id: string; kind: string; payload: string }[]) {
    indexText(db, row.source_id, row.kind, evidenceSearchText(row.kind, JSON.parse(row.payload)));
  }
}

/** Place a persisted evidence row in the matching SET-5 graph collection. */
function appendEvidence(graph: GraphSnapshot, kind: string, payload: string): void {
  const entity = JSON.parse(payload);
  switch (kind) {
    case 'passage': graph.passages.push(entity); break;
    case 'claim': graph.claims.push(entity); break;
    case 'profile': graph.profiles.push(entity); break;
    case 'relationship': graph.relationships.push(entity); break;
    case 'cluster': graph.clusters.push(entity); break;
    default: throw new StoreUnavailable(`Unknown evidence kind: ${kind}`);
  }
}

/** Local SET-5 persistence, queue, and read model; the host owns authorization. */
export class MGraphStore {
  private readonly db: DatabaseSync;
  private readonly writerLock?: DatabaseSync;
  private closed = false;
  readonly readOnly: boolean;

  /** Open the sole local writer or a concurrent read-only client. */
  constructor(filename: string, options: { readOnly?: boolean } = {}) {
    this.readOnly = options.readOnly ?? false;
    const path = canonicalPath(filename);
    this.writerLock = this.readOnly ? undefined : acquireWriterLock(path);
    let opened: DatabaseSync | undefined;
    try {
      opened = new DatabaseSync(path, { readOnly: this.readOnly });
      this.db = opened;
      this.db.exec('PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000');
      if (this.readOnly) {
        const version = Number((this.db.prepare('PRAGMA user_version').get() as { user_version: number }).user_version);
        if (version !== STORE_SCHEMA_VERSION) throw new StoreUnavailable(`Reader requires schema ${STORE_SCHEMA_VERSION}; found ${version}`);
      } else {
        chmodSync(path, 0o600);
        this.db.exec('PRAGMA journal_mode = WAL');
        migrate(this.db);
      }
    } catch (error) {
      opened?.close();
      this.releaseWriterLock();
      throw error;
    }
  }

  /** Release the sidecar lock after the main handle has closed. */
  private releaseWriterLock(): void {
    if (!this.writerLock) return;
    this.writerLock.close();
  }
  /** Release the database handle and the process-held writer lock. */
  close(): void {
    if (this.closed) return;
    this.closed = true;
    try { this.db.close(); }
    finally { this.releaseWriterLock(); }
  }
  /** Reject mutations from a query-only client before starting a transaction. */
  private writable(): void { if (this.readOnly) throw new StoreUnavailable('Read-only client cannot mutate the store'); }
  /** Find one canonical source row, including its terminal tombstone. */
  private source(sourceId: string): SourceRow | undefined {
    return this.db.prepare('SELECT * FROM sources WHERE source_id = ?').get(canonicalId(sourceId)) as SourceRow | undefined;
  }
  /** Find a job by UUID independent of caller spelling. */
  private job(jobId: string): JobRow | undefined {
    return this.db.prepare('SELECT * FROM jobs WHERE job_id = ?').get(canonicalId(jobId)) as JobRow | undefined;
  }
  /** Erase payloads and terms while leaving source metadata to the caller. */
  private purgeContent(sourceId: string): void {
    this.db.prepare('DELETE FROM evidence_terms WHERE source_id = ?').run(sourceId);
    this.db.prepare('DELETE FROM evidence WHERE source_id = ?').run(sourceId);
    this.db.prepare('DELETE FROM observations WHERE source_id = ?').run(sourceId);
  }

  /** Persist one snapshot and queue its current revision, or return an exact replay. */
  submitObservation(input: unknown): { observationId: string; revision: number; replayed: boolean } {
    this.writable();
    const supplied = parseObservation(input);
    const observation = canonicalObservation(supplied);
    if (observation.state !== 'complete' && observation.state !== 'partial') throw new StoreConflict('Terminal observations require deleteSource or revokeSource');
    return transaction(this.db, () => {
      const sourceId = observation.source.sourceId;
      const existing = this.source(sourceId);
      const replay = currentReplay(this.db, existing, observation);
      if (replay) return { ...replay, observationId: supplied.observationId };
      if (this.db.prepare('SELECT 1 FROM observation_ids WHERE id_hash = ?').get(idHash(observation.observationId))) {
        throw new StoreConflict('Observation ID was already used');
      }
      // The old revision is removed before the new one is visible. Jobs for it cannot later commit.
      if (existing) {
        this.db.prepare('DELETE FROM jobs WHERE source_id = ?').run(sourceId);
        this.purgeContent(sourceId);
      }
      const revision = (existing?.revision ?? 0) + 1;
      const updatedAt = nowIso();
      if (existing) {
        this.db.prepare(`UPDATE sources SET display_name = ?, revision = ?, observed_at = ?, state = 'pending', reason = NULL,
          updated_at = ? WHERE source_id = ?`).run(observation.source.displayName ?? null, revision, observation.observedAt, updatedAt, sourceId);
      } else {
        this.db.prepare(`INSERT INTO sources(source_id, kind, locator, display_name, application_bundle_id, revision, observed_at, state, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)`).run(sourceId, observation.source.kind, observation.source.locator,
          observation.source.displayName ?? null, observation.source.applicationBundleId ?? null, revision, observation.observedAt, updatedAt);
      }
      this.db.prepare('INSERT INTO observations(observation_id, source_id, revision, payload) VALUES (?, ?, ?, ?)')
        .run(observation.observationId, sourceId, revision, JSON.stringify(observation));
      this.db.prepare('INSERT INTO observation_ids(id_hash) VALUES (?)').run(idHash(observation.observationId));
      indexText(this.db, sourceId, 'observation', observation.content);
      this.db.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, ?, ?, 'pending')")
        .run(observation.observationId, sourceId, revision, observation.observationId);
      return { observationId: supplied.observationId, revision, replayed: false };
    });
  }

  /** Read all source statuses, or the status for one validated source ID. */
  getStatus(sourceId?: string): GraphSnapshot['statuses'] {
    const canonicalSourceId = sourceId === undefined ? undefined : canonicalId(sourceId);
    const rows = (canonicalSourceId !== undefined
      ? this.db.prepare('SELECT * FROM sources WHERE source_id = ?').all(canonicalSourceId)
      : this.db.prepare('SELECT * FROM sources ORDER BY source_id').all()) as SourceRow[];
    return rows.map(row => ({ ...statusFrom(row), sourceId: sourceId ?? row.source_id }));
  }

  /** Claim one pending or expired job with a token that fences earlier workers. */
  claimNextJob(workerId: string, leaseMs = 30_000): ProcessingJob | null {
    this.writable();
    z.string().min(1).max(128).parse(workerId);
    if (!Number.isSafeInteger(leaseMs) || leaseMs < 1 || leaseMs > 3_600_000) throw new TypeError('Invalid lease');
    return transaction(this.db, () => {
      const at = leaseNow();
      const row = this.db.prepare(`SELECT j.* FROM jobs j JOIN sources s ON s.source_id = j.source_id
        WHERE (j.state = 'pending' OR (j.state = 'processing' AND j.lease_until <= ?))
        AND s.revision = j.revision AND s.state NOT IN ('deleted', 'permissionRevoked')
        ORDER BY j.job_id LIMIT 1`).get(at) as JobRow | undefined;
      if (!row) return null;
      const leaseToken = randomUUID();
      this.db.prepare(`UPDATE jobs SET state = 'processing', attempts = attempts + 1, worker_id = ?, lease_token = ?, lease_until = ? WHERE job_id = ?`)
        .run(workerId, leaseToken, at + leaseMs, row.job_id);
      this.db.prepare("UPDATE sources SET state = 'processing', reason = NULL, updated_at = ? WHERE source_id = ?")
        .run(nowIso(), row.source_id);
      return { jobId: row.job_id, workerId, sourceId: row.source_id, revision: row.revision, observationId: row.observation_id,
        attempts: row.attempts + 1, checkpoint: row.checkpoint ? checkpointSchema.parse(JSON.parse(row.checkpoint)) : null,
        leaseToken, leaseUntil: at + leaseMs };
    });
  }

  /** Fence expired tokens and superseded source revisions before any job write. */
  private assertLease(jobId: string, leaseToken: string): JobRow {
    const job = this.job(uuid.parse(jobId));
    if (job?.state !== 'processing' || job.lease_token !== canonicalId(leaseToken) ||
        job.lease_until === null || job.lease_until <= leaseNow() || this.source(job.source_id)?.revision !== job.revision) {
      throw new StoreConflict('Job lease or source revision is stale');
    }
    return job;
  }
  /** Save restart progress only while the caller still owns a live lease. */
  checkpointJob(jobId: string, leaseToken: string, input: unknown): void {
    this.writable();
    const checkpoint = checkpointSchema.parse(input);
    transaction(this.db, () => {
      const job = this.assertLease(jobId, leaseToken);
      this.db.prepare('UPDATE jobs SET checkpoint = ? WHERE job_id = ?').run(JSON.stringify(checkpoint), job.job_id);
    });
  }
  /** Extend a live lease and return its new expiry in epoch milliseconds. */
  renewJob(jobId: string, leaseToken: string, leaseMs = 30_000): number {
    this.writable();
    if (!Number.isSafeInteger(leaseMs) || leaseMs < 1 || leaseMs > 3_600_000) throw new TypeError('Invalid lease');
    return transaction(this.db, () => {
      const job = this.assertLease(jobId, leaseToken);
      const until = leaseNow() + leaseMs;
      this.db.prepare('UPDATE jobs SET lease_until = ? WHERE job_id = ?').run(until, job.job_id);
      return until;
    });
  }

  /** Commit a provenance-valid current graph once; identical token replays are safe. */
  completeJob(jobId: string, leaseToken: string, input: unknown): void {
    this.writable();
    const graph = canonicalGraph(input);
    transaction(this.db, () => {
      const existing = this.job(jobId);
      if (existing?.state === 'complete' && existing.lease_token === canonicalId(leaseToken)) {
        if (existing.graph_hash !== graphHash(graph)) throw new StoreConflict('Completed job graph differs from original');
        return;
      }
      const job = this.assertLease(jobId, leaseToken);
      const current = this.db.prepare('SELECT payload FROM observations WHERE observation_id = ? AND source_id = ? AND revision = ?')
        .get(job.observation_id, job.source_id, job.revision) as JsonRow | undefined;
      if (!current || graph.observations.length !== 1 || !isDeepStrictEqual(graph.observations[0], JSON.parse(current.payload)) || graph.statuses.length) {
        throw new StoreConflict('Job graph must contain exactly the current observation and no status override');
      }
      for (const passage of graph.passages) if (passage.observationId !== job.observation_id) throw new StoreConflict('Passage cites another source');
      this.db.prepare("DELETE FROM evidence_terms WHERE source_id = ? AND kind != 'observation'").run(job.source_id);
      this.db.prepare('DELETE FROM evidence WHERE source_id = ?').run(job.source_id);
      const insert = this.db.prepare('INSERT INTO evidence(kind, entity_id, source_id, payload) VALUES (?, ?, ?, ?)');
      const owner = this.db.prepare('SELECT source_id FROM evidence WHERE kind = ? AND entity_id = ?');
      const persist = (kind: string, id: string, entity: unknown): void => {
        if (owner.get(kind, id)) throw new StoreConflict('Derived entity ID belongs to another source');
        insert.run(kind, id, job.source_id, JSON.stringify(entity));
        indexText(this.db, job.source_id, kind, evidenceSearchText(kind, entity));
      };
      for (const entity of graph.passages) {
        persist('passage', entity.passageId, entity);
      }
      for (const entity of graph.claims) persist('claim', entity.claimId, entity);
      for (const entity of graph.profiles) persist('profile', entity.profileId, entity);
      for (const entity of graph.relationships) persist('relationship', entity.relationshipId, entity);
      for (const entity of graph.clusters) persist('cluster', entity.clusterId, entity);
      this.db.prepare("UPDATE jobs SET state = 'complete', checkpoint = NULL, lease_until = NULL, graph_hash = ? WHERE job_id = ?")
        .run(graphHash(graph), job.job_id);
      const state = graph.observations[0].state;
      const reason = state === 'partial' ? graph.observations[0].partialReason : null;
      this.db.prepare('UPDATE sources SET state = ?, reason = ?, updated_at = ? WHERE source_id = ?')
        .run(state, reason, nowIso(), job.source_id);
    });
  }

  /** Mark a leased job failed without discarding its checkpoint. */
  failJob(jobId: string, leaseToken: string, reason: string): void {
    this.writable();
    z.string().min(1).max(512).parse(reason);
    transaction(this.db, () => {
      const job = this.assertLease(jobId, leaseToken);
      this.db.prepare("UPDATE jobs SET state = 'failed', lease_token = NULL, lease_until = NULL WHERE job_id = ?").run(job.job_id);
      this.db.prepare("UPDATE sources SET state = 'failed', reason = ?, updated_at = ? WHERE source_id = ?")
        .run(reason, nowIso(), job.source_id);
    });
  }
  /** Return a failed current job to the pending queue. */
  retryJob(jobId: string): void {
    this.writable();
    transaction(this.db, () => {
      const job = this.job(jobId);
      const source = job ? this.source(job.source_id) : undefined;
      const current = job && source ? this.db.prepare(`SELECT 1 FROM observations WHERE observation_id = ?
        AND source_id = ? AND revision = ?`).get(job.observation_id, job.source_id, job.revision) : undefined;
      if (job?.state !== 'failed' || !source || !live(source.state) || source.revision !== job.revision || !current) {
        throw new StoreConflict('Job is not retryable');
      }
      this.db.prepare("UPDATE jobs SET state = 'pending', worker_id = NULL WHERE job_id = ?").run(job.job_id);
      this.db.prepare("UPDATE sources SET state = 'pending', reason = NULL, updated_at = ? WHERE source_id = ?").run(nowIso(), job.source_id);
    });
  }

  /** Atomically erase live content and queue entries, then retain a tombstone. */
  private retire(sourceId: string, state: 'deleted' | 'permissionRevoked', reason: string | null): void {
    this.writable();
    sourceId = canonicalId(sourceId);
    transaction(this.db, () => {
      const source = this.source(sourceId);
      if (!source) throw new StoreConflict('Unknown source');
      if (!live(source.state)) {
        if (source.state === state) return;
        throw new StoreConflict('Source is already retired in another state');
      }
      this.db.prepare('DELETE FROM jobs WHERE source_id = ?').run(sourceId);
      this.purgeContent(sourceId);
      this.db.prepare(`UPDATE sources SET state = ?, reason = ?, locator = '', display_name = NULL,
        application_bundle_id = NULL, observed_at = NULL, updated_at = ? WHERE source_id = ?`)
        .run(state, reason, nowIso(), sourceId);
    });
  }
  /** Erase source content and queue work while retaining its terminal tombstone. */
  deleteSource(sourceId: string): void { this.retire(sourceId, 'deleted', null); }
  /** Erase content after permission loss and retain the revocation reason. */
  revokeSource(sourceId: string, reason: string): void {
    z.string().min(1).max(512).parse(reason);
    this.retire(sourceId, 'permissionRevoked', reason);
  }

  /** Discard a live source's derived graph and queue its current observation. */
  rebuildSource(sourceId: string): string {
    this.writable();
    sourceId = canonicalId(sourceId);
    return transaction(this.db, () => {
      const source = this.source(sourceId);
      if (!source || !live(source.state)) throw new StoreConflict('Source cannot be rebuilt');
      const observation = this.db.prepare('SELECT observation_id, payload FROM observations WHERE source_id = ? AND revision = ?')
        .get(sourceId, source.revision) as { observation_id: string; payload: string } | undefined;
      if (!observation) throw new StoreConflict('Source has no observation');
      this.db.prepare("DELETE FROM evidence_terms WHERE source_id = ? AND kind != 'observation'").run(sourceId);
      this.db.prepare('DELETE FROM evidence WHERE source_id = ?').run(sourceId);
      this.db.prepare('DELETE FROM jobs WHERE source_id = ?').run(sourceId);
      const jobId = randomUUID();
      this.db.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, ?, ?, 'pending')")
        .run(jobId, sourceId, source.revision, observation.observation_id);
      this.db.prepare("UPDATE sources SET state = 'pending', reason = NULL, updated_at = ? WHERE source_id = ?").run(nowIso(), sourceId);
      return jobId;
    });
  }

  /** Rebuild persisted word lookup from current observations and passages. */
  rebuildSearchIndex(): void {
    this.writable();
    transaction(this.db, () => rebuildSearchTerms(this.db));
  }

  /** Add one live source's current observation, evidence, and status. */
  private appendSourceSnapshot(graph: GraphSnapshot, sourceId: string): void {
    const source = this.source(sourceId);
    if (!source || !live(source.state)) return;
    for (const row of this.db.prepare('SELECT payload FROM observations WHERE source_id = ? AND revision = ?')
      .all(sourceId, source.revision) as JsonRow[]) {
      graph.observations.push(JSON.parse(row.payload) as Observation);
    }
    for (const row of this.db.prepare('SELECT kind, payload FROM evidence WHERE source_id = ?').all(sourceId) as { kind: string; payload: string }[]) {
      appendEvidence(graph, row.kind, row.payload);
    }
    graph.statuses.push(statusFrom(source));
  }
  /** Validate the assembled SET-5 graph before returning it to a reader. */
  private snapshot(sourceIds: string[]): GraphSnapshot {
    const graph: GraphSnapshot = { schemaVersion: 1, observations: [], passages: [], claims: [], profiles: [], relationships: [], clusters: [], statuses: [] };
    for (const sourceId of sourceIds) this.appendSourceSnapshot(graph, sourceId);
    return parseGraphSnapshot(graph);
  }
  /** Read a revision-consistent graph for one source or every live source. */
  getSnapshot(sourceId?: string): GraphSnapshot {
    if (sourceId !== undefined) sourceId = canonicalId(sourceId);
    return readTransaction(this.db, () => {
      const ids = (sourceId !== undefined ? [sourceId] : (this.db.prepare("SELECT source_id FROM sources WHERE state NOT IN ('deleted', 'permissionRevoked') ORDER BY source_id").all() as IdRow[]).map(r => r.source_id));
      return this.snapshot(ids);
    });
  }
  /** Find live sources containing every normalized query term and page by source ID. */
  queryMemory(query: string, options: { limit?: number; cursor?: string } = {}): { graph: GraphSnapshot; nextCursor?: string } {
    z.string().min(1).max(512).parse(query);
    const limit = options.limit ?? 20;
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new TypeError('Invalid query limit');
    let after = '';
    if (options.cursor !== undefined) {
      z.string().min(1).max(512).parse(options.cursor);
      after = canonicalId(Buffer.from(options.cursor, 'base64url').toString('utf8'));
    }
    const tokens = terms(query);
    if (!tokens.length) return { graph: this.snapshot([]) };
    return readTransaction(this.db, () => {
      const placeholders = tokens.map(() => '?').join(', ');
      const rows = this.db.prepare(`SELECT t.source_id FROM evidence_terms t JOIN sources s ON s.source_id = t.source_id
        WHERE t.term IN (${placeholders}) AND t.source_id > ? AND s.state NOT IN ('deleted', 'permissionRevoked')
        GROUP BY t.source_id HAVING count(DISTINCT t.term) = ?
        ORDER BY t.source_id LIMIT ?`).all(...tokens, after, tokens.length, limit + 1) as IdRow[];
      const selected = rows.slice(0, limit).map(row => row.source_id);
      const result: { graph: GraphSnapshot; nextCursor?: string } = { graph: this.snapshot(selected) };
      if (rows.length > limit) result.nextCursor = Buffer.from(selected.at(-1)!).toString('base64url');
      return result;
    });
  }

  /** Count current pending and leased work without exposing payloads. */
  pendingJobs(): number {
    return (this.db.prepare(`SELECT count(*) AS count FROM jobs j JOIN sources s ON s.source_id = j.source_id
      WHERE j.state IN ('pending', 'processing') AND j.revision = s.revision
      AND s.state NOT IN ('deleted', 'permissionRevoked')`).get() as { count: number }).count;
  }
}
