import { createHash, randomUUID } from 'node:crypto';
import { chmodSync, realpathSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { isDeepStrictEqual } from 'node:util';
import { z } from 'zod';
import {
  parseGraphSnapshot, parseObservation,
  type GraphSnapshot, type Observation,
} from '@subset/mgraph-contracts';

export const STORE_SCHEMA_VERSION = 3;
const uuid = z.uuid();
const checkpointSchema = z.strictObject({ stage: z.string().min(1).max(128), cursor: z.string().max(4096).optional() });
export type JobCheckpoint = z.infer<typeof checkpointSchema>;
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

export class StoreConflict extends Error { constructor(message: string) { super(message); this.name = 'StoreConflict'; } }
export class StoreUnavailable extends Error { constructor(message: string) { super(message); this.name = 'StoreUnavailable'; } }

function canonicalPath(filename: string): string {
  if (filename === ':memory:') throw new StoreUnavailable('Store requires a local database file');
  const full = resolve(filename);
  try { return realpathSync(full); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
    return join(realpathSync(dirname(full)), basename(full));
  }
}

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

function idHash(id: string): string { return createHash('sha256').update(id).digest('hex'); }
function graphHash(graph: GraphSnapshot): string { return createHash('sha256').update(JSON.stringify(graph)).digest('hex'); }
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

function transaction<T>(db: DatabaseSync, fn: () => T): T {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
}

function readTransaction<T>(db: DatabaseSync, fn: () => T): T {
  db.exec('BEGIN');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
}

function migrate(db: DatabaseSync): void {
  const version = Number((db.prepare('PRAGMA user_version').get() as { user_version: number }).user_version);
  if (version > STORE_SCHEMA_VERSION) throw new StoreUnavailable(`Store schema ${version} is newer than this binary`);
  if (version < 1) transaction(db, () => {
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
  });
  if (version < 2) transaction(db, () => {
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
    // Version 1 already held observations. Reindex them as part of the same upgrade transaction.
    for (const row of db.prepare('SELECT source_id, payload FROM observations').all() as { source_id: string; payload: string }[]) {
      const observation = parseObservation(JSON.parse(row.payload));
      if (observation.state === 'complete' || observation.state === 'partial') {
        indexText(db, row.source_id, 'observation', observation.content);
      }
    }
  });
  if (version < 3) transaction(db, () => {
    db.exec(`
      CREATE TABLE observation_ids (id_hash TEXT PRIMARY KEY);
      ALTER TABLE jobs ADD COLUMN graph_hash TEXT;
      PRAGMA user_version = 3;
    `);
    const insert = db.prepare('INSERT INTO observation_ids(id_hash) VALUES (?)');
    for (const row of db.prepare('SELECT observation_id FROM observations').all() as { observation_id: string }[]) {
      insert.run(idHash(row.observation_id));
    }
    const update = db.prepare('UPDATE jobs SET graph_hash = ? WHERE job_id = ?');
    for (const row of db.prepare("SELECT job_id, source_id, observation_id FROM jobs WHERE state = 'complete'")
      .all() as { job_id: string; source_id: string; observation_id: string }[]) {
      update.run(graphHash(storedCompletedGraph(db, row.source_id, row.observation_id)), row.job_id);
    }
  });
}

function statusFrom(row: SourceRow): GraphSnapshot['statuses'][number] {
  const base = { schemaVersion: 1 as const, sourceId: row.source_id, updatedAt: row.updated_at };
  if (row.state === 'partial' || row.state === 'failed' || row.state === 'permissionRevoked') {
    return { ...base, state: row.state, reason: row.reason ?? 'Unknown reason' };
  }
  return { ...base, state: row.state as 'pending' | 'processing' | 'complete' | 'deleted' };
}
function nowIso(): string { return new Date().toISOString(); }
function live(state: string): boolean { return state !== 'deleted' && state !== 'permissionRevoked'; }
function terms(text: string): string[] { return [...new Set((text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []))]; }
function indexText(db: DatabaseSync, sourceId: string, kind: string, body: string): void {
  const insert = db.prepare('INSERT OR IGNORE INTO evidence_terms(source_id, kind, term) VALUES (?, ?, ?)');
  for (const term of terms(body)) insert.run(sourceId, kind, term);
}

export class MGraphStore {
  private readonly db: DatabaseSync;
  private readonly writerLock?: DatabaseSync;
  private closed = false;
  readonly readOnly: boolean;

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

  private releaseWriterLock(): void {
    if (!this.writerLock) return;
    this.writerLock.close();
  }
  close(): void {
    if (this.closed) return;
    this.closed = true;
    try { this.db.close(); }
    finally { this.releaseWriterLock(); }
  }
  private writable(): void { if (this.readOnly) throw new StoreUnavailable('Read-only client cannot mutate the store'); }
  private source(sourceId: string): SourceRow | undefined {
    return this.db.prepare('SELECT * FROM sources WHERE source_id = ?').get(sourceId) as SourceRow | undefined;
  }
  private job(jobId: string): JobRow | undefined {
    return this.db.prepare('SELECT * FROM jobs WHERE job_id = ?').get(jobId) as JobRow | undefined;
  }
  private purgeContent(sourceId: string): void {
    this.db.prepare('DELETE FROM evidence_terms WHERE source_id = ?').run(sourceId);
    this.db.prepare('DELETE FROM evidence WHERE source_id = ?').run(sourceId);
    this.db.prepare('DELETE FROM observations WHERE source_id = ?').run(sourceId);
  }

  submitObservation(input: unknown): { observationId: string; revision: number; replayed: boolean } {
    this.writable();
    const observation = parseObservation(input);
    if (observation.state !== 'complete' && observation.state !== 'partial') throw new StoreConflict('Terminal observations require deleteSource or revokeSource');
    return transaction(this.db, () => {
      const sourceId = observation.source.sourceId;
      const existing = this.source(sourceId);
      if (existing) {
        if (!live(existing.state)) throw new StoreConflict('A retired source ID cannot be reused');
        if (existing.kind !== observation.source.kind || existing.locator !== observation.source.locator ||
            existing.application_bundle_id !== (observation.source.applicationBundleId ?? null)) {
          throw new StoreConflict('Source identity changed');
        }
        if (existing.observed_at && Date.parse(observation.observedAt) <= Date.parse(existing.observed_at)) {
          const prior = this.db.prepare('SELECT source_id, payload, revision FROM observations WHERE observation_id = ?').get(observation.observationId) as
            | { source_id: string; payload: string; revision: number } | undefined;
          if (prior?.source_id === sourceId && prior.payload === JSON.stringify(observation)) {
            return { observationId: observation.observationId, revision: prior.revision, replayed: true };
          }
          throw new StoreConflict('Observation is older than the current source revision');
        }
      }
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
      return { observationId: observation.observationId, revision, replayed: false };
    });
  }

  getStatus(sourceId?: string): GraphSnapshot['statuses'] {
    if (sourceId) uuid.parse(sourceId);
    const rows = (sourceId
      ? this.db.prepare('SELECT * FROM sources WHERE source_id = ?').all(sourceId)
      : this.db.prepare('SELECT * FROM sources ORDER BY source_id').all()) as SourceRow[];
    return rows.map(statusFrom);
  }

  claimNextJob(workerId: string, leaseMs = 30_000, at = Date.now()): ProcessingJob | null {
    this.writable();
    z.string().min(1).max(128).parse(workerId);
    if (!Number.isSafeInteger(leaseMs) || leaseMs < 1 || leaseMs > 3_600_000 || !Number.isSafeInteger(at)) throw new TypeError('Invalid lease');
    return transaction(this.db, () => {
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

  private assertLease(jobId: string, leaseToken: string, at: number): JobRow {
    const job = this.job(uuid.parse(jobId));
    if (!job || job.state !== 'processing' || job.lease_token !== uuid.parse(leaseToken) ||
        job.lease_until === null || job.lease_until <= at || this.source(job.source_id)?.revision !== job.revision) {
      throw new StoreConflict('Job lease or source revision is stale');
    }
    return job;
  }
  checkpointJob(jobId: string, leaseToken: string, input: unknown, at = Date.now()): void {
    this.writable();
    const checkpoint = checkpointSchema.parse(input);
    transaction(this.db, () => {
      this.assertLease(jobId, leaseToken, at);
      this.db.prepare('UPDATE jobs SET checkpoint = ? WHERE job_id = ?').run(JSON.stringify(checkpoint), jobId);
    });
  }
  renewJob(jobId: string, leaseToken: string, leaseMs = 30_000, at = Date.now()): number {
    this.writable();
    if (!Number.isSafeInteger(leaseMs) || leaseMs < 1 || leaseMs > 3_600_000) throw new TypeError('Invalid lease');
    return transaction(this.db, () => {
      this.assertLease(jobId, leaseToken, at);
      this.db.prepare('UPDATE jobs SET lease_until = ? WHERE job_id = ?').run(at + leaseMs, jobId);
      return at + leaseMs;
    });
  }

  completeJob(jobId: string, leaseToken: string, input: unknown, at = Date.now()): void {
    this.writable();
    const graph = parseGraphSnapshot(input);
    transaction(this.db, () => {
      const existing = this.job(uuid.parse(jobId));
      if (existing?.state === 'complete' && existing.lease_token === uuid.parse(leaseToken)) {
        if (existing.graph_hash !== graphHash(graph)) throw new StoreConflict('Completed job graph differs from original');
        return;
      }
      const job = this.assertLease(jobId, leaseToken, at);
      const current = this.db.prepare('SELECT payload FROM observations WHERE observation_id = ? AND source_id = ? AND revision = ?')
        .get(job.observation_id, job.source_id, job.revision) as JsonRow | undefined;
      if (!current || graph.observations.length !== 1 || !isDeepStrictEqual(graph.observations[0], JSON.parse(current.payload)) || graph.statuses.length) {
        throw new StoreConflict('Job graph must contain exactly the current observation and no status override');
      }
      for (const passage of graph.passages) if (passage.observationId !== job.observation_id) throw new StoreConflict('Passage cites another source');
      this.db.prepare("DELETE FROM evidence_terms WHERE source_id = ? AND kind = 'passage'").run(job.source_id);
      this.db.prepare('DELETE FROM evidence WHERE source_id = ?').run(job.source_id);
      const insert = this.db.prepare('INSERT INTO evidence(kind, entity_id, source_id, payload) VALUES (?, ?, ?, ?)');
      for (const entity of graph.passages) {
        insert.run('passage', entity.passageId, job.source_id, JSON.stringify(entity));
        indexText(this.db, job.source_id, 'passage', entity.text);
      }
      for (const entity of graph.claims) insert.run('claim', entity.claimId, job.source_id, JSON.stringify(entity));
      for (const entity of graph.profiles) insert.run('profile', entity.profileId, job.source_id, JSON.stringify(entity));
      for (const entity of graph.relationships) insert.run('relationship', entity.relationshipId, job.source_id, JSON.stringify(entity));
      for (const entity of graph.clusters) insert.run('cluster', entity.clusterId, job.source_id, JSON.stringify(entity));
      this.db.prepare("UPDATE jobs SET state = 'complete', checkpoint = NULL, lease_until = NULL, graph_hash = ? WHERE job_id = ?")
        .run(graphHash(graph), jobId);
      const state = graph.observations[0].state;
      const reason = state === 'partial' ? graph.observations[0].partialReason : null;
      this.db.prepare('UPDATE sources SET state = ?, reason = ?, updated_at = ? WHERE source_id = ?')
        .run(state, reason, nowIso(), job.source_id);
    });
  }

  failJob(jobId: string, leaseToken: string, reason: string, at = Date.now()): void {
    this.writable();
    z.string().min(1).max(512).parse(reason);
    transaction(this.db, () => {
      const job = this.assertLease(jobId, leaseToken, at);
      this.db.prepare("UPDATE jobs SET state = 'failed', lease_token = NULL, lease_until = NULL WHERE job_id = ?").run(jobId);
      this.db.prepare("UPDATE sources SET state = 'failed', reason = ?, updated_at = ? WHERE source_id = ?")
        .run(reason, nowIso(), job.source_id);
    });
  }
  retryJob(jobId: string): void {
    this.writable();
    transaction(this.db, () => {
      const job = this.job(uuid.parse(jobId));
      if (!job || job.state !== 'failed' || !live(this.source(job.source_id)?.state ?? 'deleted')) throw new StoreConflict('Job is not retryable');
      this.db.prepare("UPDATE jobs SET state = 'pending', worker_id = NULL WHERE job_id = ?").run(jobId);
      this.db.prepare("UPDATE sources SET state = 'pending', reason = NULL, updated_at = ? WHERE source_id = ?").run(nowIso(), job.source_id);
    });
  }

  private retire(sourceId: string, state: 'deleted' | 'permissionRevoked', reason: string | null): void {
    this.writable();
    uuid.parse(sourceId);
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
  deleteSource(sourceId: string): void { this.retire(sourceId, 'deleted', null); }
  revokeSource(sourceId: string, reason: string): void {
    z.string().min(1).max(512).parse(reason);
    this.retire(sourceId, 'permissionRevoked', reason);
  }

  rebuildSource(sourceId: string): string {
    this.writable();
    uuid.parse(sourceId);
    return transaction(this.db, () => {
      const source = this.source(sourceId);
      if (!source || !live(source.state)) throw new StoreConflict('Source cannot be rebuilt');
      const observation = this.db.prepare('SELECT observation_id, payload FROM observations WHERE source_id = ?')
        .get(sourceId) as { observation_id: string; payload: string } | undefined;
      if (!observation) throw new StoreConflict('Source has no observation');
      this.db.prepare("DELETE FROM evidence_terms WHERE source_id = ? AND kind = 'passage'").run(sourceId);
      this.db.prepare('DELETE FROM evidence WHERE source_id = ?').run(sourceId);
      this.db.prepare('DELETE FROM jobs WHERE source_id = ?').run(sourceId);
      const jobId = randomUUID();
      this.db.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, ?, ?, 'pending')")
        .run(jobId, sourceId, source.revision, observation.observation_id);
      this.db.prepare("UPDATE sources SET state = 'pending', reason = NULL, updated_at = ? WHERE source_id = ?").run(nowIso(), sourceId);
      return jobId;
    });
  }

  rebuildSearchIndex(): void {
    this.writable();
    transaction(this.db, () => {
      this.db.exec('DELETE FROM evidence_terms');
      for (const row of this.db.prepare('SELECT source_id, payload FROM observations').all() as { source_id: string; payload: string }[]) {
        const observation = parseObservation(JSON.parse(row.payload));
        if (observation.state === 'complete' || observation.state === 'partial') {
          indexText(this.db, row.source_id, 'observation', observation.content);
        }
      }
      for (const row of this.db.prepare("SELECT source_id, payload FROM evidence WHERE kind = 'passage'").all() as { source_id: string; payload: string }[]) {
        const passage = JSON.parse(row.payload) as GraphSnapshot['passages'][number];
        indexText(this.db, row.source_id, 'passage', passage.text);
      }
    });
  }

  private snapshot(sourceIds: string[]): GraphSnapshot {
    const graph: GraphSnapshot = { schemaVersion: 1, observations: [], passages: [], claims: [], profiles: [], relationships: [], clusters: [], statuses: [] };
    for (const sourceId of sourceIds) {
      const source = this.source(sourceId);
      if (!source || !live(source.state)) continue;
      for (const row of this.db.prepare('SELECT payload FROM observations WHERE source_id = ?').all(sourceId) as JsonRow[]) {
        graph.observations.push(JSON.parse(row.payload) as Observation);
      }
      for (const row of this.db.prepare('SELECT kind, payload FROM evidence WHERE source_id = ?').all(sourceId) as { kind: string; payload: string }[]) {
        const entity = JSON.parse(row.payload);
        if (row.kind === 'passage') graph.passages.push(entity);
        if (row.kind === 'claim') graph.claims.push(entity);
        if (row.kind === 'profile') graph.profiles.push(entity);
        if (row.kind === 'relationship') graph.relationships.push(entity);
        if (row.kind === 'cluster') graph.clusters.push(entity);
      }
      graph.statuses.push(statusFrom(source));
    }
    return parseGraphSnapshot(graph);
  }
  getSnapshot(sourceId?: string): GraphSnapshot {
    if (sourceId) uuid.parse(sourceId);
    return readTransaction(this.db, () => {
      const ids = (sourceId ? [sourceId] : (this.db.prepare("SELECT source_id FROM sources WHERE state NOT IN ('deleted', 'permissionRevoked') ORDER BY source_id").all() as IdRow[]).map(r => r.source_id));
      return this.snapshot(ids);
    });
  }
  queryMemory(query: string, options: { limit?: number; cursor?: string } = {}): { graph: GraphSnapshot; nextCursor?: string } {
    z.string().min(1).max(512).parse(query);
    const limit = options.limit ?? 20;
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new TypeError('Invalid query limit');
    let after = '';
    if (options.cursor) {
      z.string().min(1).max(512).parse(options.cursor);
      after = Buffer.from(options.cursor, 'base64url').toString('utf8');
      uuid.parse(after);
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
      if (rows.length > limit) result.nextCursor = Buffer.from(selected[selected.length - 1]).toString('base64url');
      return result;
    });
  }

  // Useful for an owner to expose queue state without leaking payloads.
  pendingJobs(): number {
    return (this.db.prepare("SELECT count(*) AS count FROM jobs WHERE state IN ('pending', 'processing')").get() as { count: number }).count;
  }
}
