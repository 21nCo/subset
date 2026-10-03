import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';
import { sourceHash } from '@subset/mgraph-contracts';
import { MGraphStore, STORE_SCHEMA_VERSION, StoreConflict, StoreUnavailable } from '../dist/index.js';

function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'mgraph-store-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return join(dir, 'graph.sqlite');
}
function observation(sourceId = randomUUID(), observationId = randomUUID(), text = 'Alice knows Bob', observedAt = '2026-10-01T00:00:00.000Z') {
  return { schemaVersion: 1, observationId, source: { sourceId, kind: 'manual', locator: `note:${sourceId}` },
    observedAt, state: 'complete', content: text, sourceHash: sourceHash(text) };
}
function graphFor(observation) {
  const passage = { schemaVersion: 1, passageId: randomUUID(), observationId: observation.observationId,
    sourceHash: observation.sourceHash, start: 0, end: Array.from(observation.content).length, text: observation.content };
  const claim = { schemaVersion: 1, claimId: randomUUID(), statement: observation.content,
    provenance: [{ observationId: observation.observationId, passageId: passage.passageId,
      sourceHash: observation.sourceHash, modelVersion: 'fixture-v1' }] };
  return { schemaVersion: 1, observations: [observation], passages: [passage], claims: [claim],
    profiles: [{ schemaVersion: 1, profileId: randomUUID(), name: 'Alice', modelVersion: 'fixture-v1', claimIds: [claim.claimId] }],
    relationships: [], clusters: [], statuses: [] };
}
function finish(store, observation) {
  const job = store.claimNextJob('test-worker');
  assert.ok(job);
  const graph = graphFor(observation);
  store.completeJob(job.jobId, job.leaseToken, graph);
  return { job, graph };
}

test('fresh migration, evidence lookup, rebuild and read-only clients', t => {
  const filename = fixture(t);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  const db = new DatabaseSync(filename, { readOnly: true });
  assert.equal(db.prepare('PRAGMA user_version').get().user_version, STORE_SCHEMA_VERSION);
  db.close();
  const first = observation();
  store.submitObservation(first);
  const { graph } = finish(store, first);
  const reader = new MGraphStore(filename, { readOnly: true });
  t.after(() => reader.close());
  assert.throws(() => new MGraphStore(filename), StoreUnavailable);
  assert.equal(reader.queryMemory('Alice knows').graph.claims[0].claimId, graph.claims[0].claimId);
  assert.throws(() => reader.submitObservation(first), /Read-only/);
  store.rebuildSearchIndex();
  assert.equal(reader.queryMemory('Bob').graph.passages.length, 1);
  store.rebuildSource(first.source.sourceId);
  assert.equal(reader.queryMemory('Bob').graph.passages.length, 0);
  assert.equal(reader.getStatus(first.source.sourceId)[0].state, 'pending');
  finish(store, first);
  assert.equal(reader.queryMemory('Bob').graph.passages.length, 1);
});

test('v1 upgrade preserves observations and creates searchable evidence', t => {
  const filename = fixture(t);
  const old = new DatabaseSync(filename);
  old.exec(`CREATE TABLE sources (source_id TEXT PRIMARY KEY, kind TEXT NOT NULL, locator TEXT NOT NULL,
    display_name TEXT, application_bundle_id TEXT, revision INTEGER NOT NULL DEFAULT 0,
    observed_at TEXT, state TEXT NOT NULL, reason TEXT, updated_at TEXT NOT NULL);
    CREATE TABLE observations (observation_id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL, payload TEXT NOT NULL, UNIQUE(source_id, revision));
    CREATE TABLE jobs (job_id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL, observation_id TEXT NOT NULL, state TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0, checkpoint TEXT, lease_token TEXT, lease_until INTEGER);
    CREATE INDEX jobs_ready ON jobs(state, lease_until, job_id);
    PRAGMA user_version = 1;`);
  const item = observation();
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 1, ?, 'pending', ?)")
    .run(item.source.sourceId, item.source.locator, item.observedAt, item.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)').run(item.observationId, item.source.sourceId, JSON.stringify(item));
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, 1, ?, 'pending')")
    .run(item.observationId, item.source.sourceId, item.observationId);
  old.close();
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  assert.equal(store.queryMemory('Alice').graph.observations[0].observationId, item.observationId);
  finish(store, item);
  assert.equal(store.queryMemory('Bob').graph.claims.length, 1);
});

test('WAL reader snapshot remains stable while one writer advances a source', t => {
  const filename = fixture(t);
  const writer = new MGraphStore(filename);
  t.after(() => writer.close());
  const first = observation();
  writer.submitObservation(first);
  const readerDb = new DatabaseSync(filename, { readOnly: true });
  t.after(() => readerDb.close());
  readerDb.exec('BEGIN');
  assert.equal(readerDb.prepare('SELECT count(*) AS n FROM observations').get().n, 1);
  const second = observation(first.source.sourceId, randomUUID(), 'Carol knows Dave', '2026-10-02T00:00:00.000Z');
  writer.submitObservation(second);
  assert.equal(readerDb.prepare('SELECT payload FROM observations').get().payload, JSON.stringify(first));
  readerDb.exec('COMMIT');
  assert.equal(readerDb.prepare('SELECT payload FROM observations').get().payload, JSON.stringify(second));
  const reader = new MGraphStore(filename, { readOnly: true });
  t.after(() => reader.close());
  assert.equal(reader.queryMemory('Carol').graph.observations.length, 1);
});

test('interrupted job resumes checkpoint, stale lease fails, replay is idempotent', t => {
  const filename = fixture(t);
  let store = new MGraphStore(filename);
  const item = observation();
  const accepted = store.submitObservation(item);
  assert.equal(accepted.replayed, false);
  assert.deepEqual(store.submitObservation(item), { ...accepted, replayed: true });
  const first = store.claimNextJob('first', 1000, 1000);
  assert.ok(first);
  store.checkpointJob(first.jobId, first.leaseToken, { stage: 'extracted', cursor: 'page:2' }, 1500);
  store.close();
  store = new MGraphStore(filename);
  t.after(() => store.close());
  const resumed = store.claimNextJob('second', 1000, 2001);
  assert.equal(resumed.attempts, 2);
  assert.deepEqual(resumed.checkpoint, { stage: 'extracted', cursor: 'page:2' });
  const graph = graphFor(item);
  assert.throws(() => store.completeJob(first.jobId, first.leaseToken, graph, 2001), StoreConflict);
  store.completeJob(resumed.jobId, resumed.leaseToken, graph, 2500);
  store.completeJob(resumed.jobId, resumed.leaseToken, graph, 2500);
  assert.equal(store.getSnapshot().claims.length, 1);
  assert.equal(store.pendingJobs(), 0);
});

test('abrupt writer exit leaves a reclaimable lock and durable queued work', t => {
  const filename = fixture(t);
  const item = observation();
  const moduleUrl = new URL('../dist/index.js', import.meta.url).href;
  const child = spawnSync(process.execPath, ['--input-type=module', '-e', `
    import { MGraphStore } from ${JSON.stringify(moduleUrl)};
    const store = new MGraphStore(${JSON.stringify(filename)});
    store.submitObservation(${JSON.stringify(item)});
    const job = store.claimNextJob('terminated-worker', 1000, 1000);
    store.checkpointJob(job.jobId, job.leaseToken, { stage: 'captured' }, 1500);
    process.exit(0);
  `], { encoding: 'utf8' });
  assert.equal(child.status, 0, child.stderr);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  const job = store.claimNextJob('replacement-worker', 1000, 2001);
  assert.equal(job.checkpoint.stage, 'captured');
  store.completeJob(job.jobId, job.leaseToken, graphFor(item), 2500);
  assert.equal(store.queryMemory('Alice').graph.claims.length, 1);
});

test('newer revision fences old job and old submission; deletion erases content and queue', t => {
  const filename = fixture(t);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  const first = observation();
  store.submitObservation(first);
  const oldJob = store.claimNextJob('worker', 10_000);
  const second = observation(first.source.sourceId, randomUUID(), 'New revision only', '2026-10-02T00:00:00.000Z');
  store.submitObservation(second);
  assert.throws(() => store.completeJob(oldJob.jobId, oldJob.leaseToken, graphFor(first)), StoreConflict);
  assert.throws(() => store.submitObservation(first), StoreConflict);
  finish(store, second);
  assert.equal(store.queryMemory('New').graph.observations.length, 1);
  store.rebuildSource(first.source.sourceId);
  assert.equal(store.pendingJobs(), 1);
  store.deleteSource(first.source.sourceId);
  assert.equal(store.pendingJobs(), 0);
  assert.equal(store.queryMemory('New').graph.observations.length, 0);
  assert.equal(store.getSnapshot().observations.length, 0);
  assert.equal(store.getStatus(first.source.sourceId)[0].state, 'deleted');
  assert.equal(store.claimNextJob('worker'), null);
  assert.throws(() => store.submitObservation(second), StoreConflict);
  const disk = new DatabaseSync(filename, { readOnly: true });
  const retained = disk.prepare('SELECT locator, display_name, observed_at FROM sources WHERE source_id = ?').get(first.source.sourceId);
  assert.deepEqual({ ...retained }, { locator: '', display_name: null, observed_at: null });
  assert.equal(disk.prepare('SELECT count(*) AS n FROM observations').get().n, 0);
  assert.equal(disk.prepare('SELECT count(*) AS n FROM evidence_terms').get().n, 0);
  disk.close();
  store.rebuildSearchIndex();
  assert.equal(store.queryMemory('New').graph.observations.length, 0);
});

test('invalid graph, malformed query, revocation and failed-job retry', t => {
  const filename = fixture(t);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  const item = observation();
  store.submitObservation(item);
  let job = store.claimNextJob('worker');
  const invalid = graphFor(item);
  invalid.passages[0].text = 'wrong excerpt';
  assert.throws(() => store.completeJob(job.jobId, job.leaseToken, invalid), /Passage mismatch/);
  store.failJob(job.jobId, job.leaseToken, 'Extraction failed');
  assert.equal(store.getStatus(item.source.sourceId)[0].state, 'failed');
  store.retryJob(job.jobId);
  job = store.claimNextJob('worker');
  store.completeJob(job.jobId, job.leaseToken, graphFor(item));
  assert.equal(store.queryMemory('Alice!').graph.claims.length, 1);
  assert.equal(store.queryMemory('???').graph.observations.length, 0);
  store.revokeSource(item.source.sourceId, 'Permission removed');
  assert.equal(store.queryMemory('Alice').graph.observations.length, 0);
  assert.equal(store.getStatus(item.source.sourceId)[0].state, 'permissionRevoked');
  assert.throws(() => store.rebuildSource(item.source.sourceId), StoreConflict);
});
