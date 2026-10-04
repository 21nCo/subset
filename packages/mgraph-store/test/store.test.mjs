import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { existsSync, linkSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';
import { decodeIpcRequest, parseIpcResponse, sourceHash } from '@subset/mgraph-contracts';
import { MGraphStore, STORE_SCHEMA_VERSION, StoreConflict, StoreUnavailable } from '../dist/index.js';

/** Give each database test an isolated file and remove its WAL and lock sidecars afterward. */
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'mgraph-store-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return join(dir, 'graph.sqlite');
}
/** Create the original queue schema so upgrades run against persisted legacy rows. */
function createV1Database(filename) {
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
  return old;
}
/** Create the legacy evidence schema, whose rows do not carry source revisions. */
function createV2Database(filename) {
  const old = new DatabaseSync(filename);
  old.exec(`CREATE TABLE sources (source_id TEXT PRIMARY KEY, kind TEXT NOT NULL, locator TEXT NOT NULL,
    display_name TEXT, application_bundle_id TEXT, revision INTEGER NOT NULL DEFAULT 0,
    observed_at TEXT, state TEXT NOT NULL, reason TEXT, updated_at TEXT NOT NULL);
    CREATE TABLE observations (observation_id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL, payload TEXT NOT NULL, UNIQUE(source_id, revision));
    CREATE TABLE jobs (job_id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL, observation_id TEXT NOT NULL, state TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0, checkpoint TEXT, lease_token TEXT, lease_until INTEGER, worker_id TEXT);
    CREATE INDEX jobs_ready ON jobs(state, lease_until, job_id);
    CREATE TABLE evidence (kind TEXT NOT NULL, entity_id TEXT NOT NULL,
      source_id TEXT NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
      payload TEXT NOT NULL, PRIMARY KEY(kind, entity_id));
    CREATE INDEX evidence_source ON evidence(source_id, kind);
    CREATE TABLE evidence_terms (source_id TEXT NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
      kind TEXT NOT NULL, term TEXT NOT NULL, PRIMARY KEY(source_id, kind, term));
    CREATE INDEX evidence_terms_lookup ON evidence_terms(term, source_id);
    PRAGMA user_version = 2;`);
  return old;
}
/** Add the pre-canonical UUID ledger and replay digest columns to a v2 fixture. */
function createV3Database(filename) {
  const old = createV2Database(filename);
  old.exec(`CREATE TABLE observation_ids (id_hash TEXT PRIMARY KEY);
    ALTER TABLE jobs ADD COLUMN graph_hash TEXT;
    PRAGMA user_version = 3;`);
  return old;
}
/** Build a SET-5 observation with the content hash required at submission. */
function observation(sourceId = randomUUID(), observationId = randomUUID(), text = 'Alice knows Bob', observedAt = '2026-10-01T00:00:00.000Z') {
  return { schemaVersion: 1, observationId, source: { sourceId, kind: 'manual', locator: `note:${sourceId}` },
    observedAt, state: 'complete', content: text, sourceHash: sourceHash(text) };
}
/** Supply passage and claim provenance for a one-source completion. */
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
/** Change only declared UUID fields to test identity without changing source content. */
function uppercaseUuids(value) {
  const fields = new Set(['sourceId', 'observationId', 'targetObservationId', 'passageId', 'claimId', 'profileId',
    'relationshipId', 'clusterId', 'fromProfileId', 'toProfileId']);
  const arrays = new Set(['claimIds', 'memberProfileIds']);
  if (Array.isArray(value)) return value.map(uppercaseUuids);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).map(([key, field]) => {
    if (fields.has(key) && typeof field === 'string') return [key, field.toUpperCase()];
    if (arrays.has(key)) return [key, field.map(id => id.toUpperCase())];
    return [key, uppercaseUuids(field)];
  }));
}
/** Produce a spelling that neither lowercase nor all-uppercase legacy hashes cover. */
function mixedUuid(id) {
  return id.replace(/[a-f]/g, (letter, index) => index % 2 ? letter.toUpperCase() : letter);
}
/** Claim and complete a fixture observation, returning its token and committed graph. */
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

test('missing reader files and directories report store unavailability', t => {
  const filename = fixture(t);
  assert.throws(() => new MGraphStore(filename, { readOnly: true }), StoreUnavailable);
  assert.throws(() => new MGraphStore(join(dirname(filename), 'missing', 'graph.sqlite')), StoreUnavailable);
  const writer = new MGraphStore(filename);
  writer.close();
  const reader = new MGraphStore(filename, { readOnly: true });
  reader.close();
});

test('invalid database schemas and lock sidecars report store unavailability', t => {
  const filename = fixture(t);
  writeFileSync(filename, 'not a SQLite database');
  assert.throws(() => new MGraphStore(filename, { readOnly: true }), StoreUnavailable);
  assert.throws(() => new MGraphStore(filename), StoreUnavailable);
  rmSync(filename);

  const legacy = new DatabaseSync(filename);
  legacy.exec('CREATE TABLE sources (id TEXT)');
  legacy.close();
  assert.throws(() => new MGraphStore(filename), StoreUnavailable);
  rmSync(filename);

  const writer = new MGraphStore(filename);
  writer.close();
  const sidecar = `${filename}.writer-lock.sqlite`;
  rmSync(sidecar);
  mkdirSync(sidecar);
  assert.throws(() => new MGraphStore(filename), StoreUnavailable);
});

test('hard-linked database aliases cannot split writer locks or WAL files', t => {
  const filename = fixture(t);
  const writer = new MGraphStore(filename);
  t.after(() => writer.close());
  const alias = join(dirname(filename), 'alias.sqlite');
  linkSync(filename, alias);
  assert.throws(() => new MGraphStore(alias), StoreUnavailable);
  assert.throws(() => new MGraphStore(alias, { readOnly: true }), StoreUnavailable);
  assert.equal(existsSync(`${alias}.writer-lock.sqlite`), false);
  unlinkSync(alias);
  writer.close();
  const reopened = new MGraphStore(filename);
  reopened.close();
});

test('dangling symlink cannot create a writer lock under an alias', t => {
  const filename = fixture(t);
  const alias = join(dirname(filename), 'alias.sqlite');
  symlinkSync(filename, alias);
  assert.throws(() => new MGraphStore(alias), StoreUnavailable);
  assert.equal(existsSync(filename), false);
  assert.equal(existsSync(`${alias}.writer-lock.sqlite`), false);
  const writer = new MGraphStore(filename);
  t.after(() => writer.close());
  assert.throws(() => new MGraphStore(alias), StoreUnavailable);
  const reader = new MGraphStore(alias, { readOnly: true });
  reader.close();
});

test('snapshot and search retain every derived evidence kind', t => {
  const filename = fixture(t);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  const item = observation();
  store.submitObservation(item);
  const graph = graphFor(item);
  graph.claims[0].statement = 'Generous association';
  graph.profiles[0].name = 'Alaria';
  const peer = { schemaVersion: 1, profileId: randomUUID(), name: 'Borealis', modelVersion: 'fixture-v1',
    claimIds: [graph.claims[0].claimId] };
  graph.profiles.push(peer);
  graph.relationships.push({ schemaVersion: 1, relationshipId: randomUUID(), fromProfileId: graph.profiles[0].profileId,
    toProfileId: peer.profileId, kind: 'Collaborates', modelVersion: 'fixture-v1', claimIds: [graph.claims[0].claimId] });
  graph.clusters.push({ schemaVersion: 1, clusterId: randomUUID(), name: 'Constellation', memberProfileIds: [
    graph.profiles[0].profileId, peer.profileId], modelVersion: 'fixture-v1', claimIds: [graph.claims[0].claimId] });
  const job = store.claimNextJob('worker');
  store.completeJob(job.jobId, job.leaseToken, graph);
  const result = store.queryMemory('Alice').graph;
  assert.deepEqual([result.passages.length, result.claims.length, result.profiles.length,
    result.relationships.length, result.clusters.length], [1, 1, 2, 1, 1]);
  assert.equal(store.getSnapshot(item.source.sourceId).relationships[0].relationshipId, graph.relationships[0].relationshipId);
  for (const term of ['Generous', 'Alaria', 'Borealis', 'Collaborates', 'Constellation']) {
    assert.equal(store.queryMemory(term).graph.observations.length, 1, term);
  }
  store.rebuildSearchIndex();
  assert.equal(store.queryMemory('Generous').graph.claims.length, 1);
  store.rebuildSource(item.source.sourceId);
  for (const term of ['Generous', 'Alaria', 'Collaborates', 'Constellation']) {
    assert.equal(store.queryMemory(term).graph.observations.length, 0, term);
  }
  assert.equal(store.queryMemory('Alice').graph.observations.length, 1);
  const rebuilt = store.claimNextJob('worker');
  store.completeJob(rebuilt.jobId, rebuilt.leaseToken, graph);
  assert.equal(store.queryMemory('Generous').graph.claims.length, 1);
  store.deleteSource(item.source.sourceId);
  assert.equal(store.queryMemory('Generous').graph.observations.length, 0);
});

test('Unicode-equivalent observation and evidence terms survive rebuild, reopen and v4 upgrade', t => {
  const filename = fixture(t);
  let store = new MGraphStore(filename);
  const item = observation(randomUUID(), randomUUID(), 'Cafe\u0301 source');
  store.submitObservation(item);
  const graph = graphFor(item);
  graph.claims[0].statement = 'Cafe\u0301 claim';
  graph.profiles[0].name = 'Cafe\u0301 profile';
  const peer = { schemaVersion: 1, profileId: randomUUID(), name: 'Peer', modelVersion: 'fixture-v1',
    claimIds: [graph.claims[0].claimId] };
  graph.profiles.push(peer);
  graph.relationships.push({ schemaVersion: 1, relationshipId: randomUUID(), fromProfileId: graph.profiles[0].profileId,
    toProfileId: peer.profileId, kind: 'Cafe\u0301 link', modelVersion: 'fixture-v1', claimIds: [graph.claims[0].claimId] });
  graph.clusters.push({ schemaVersion: 1, clusterId: randomUUID(), name: 'Cafe\u0301 group',
    memberProfileIds: [graph.profiles[0].profileId, peer.profileId], modelVersion: 'fixture-v1',
    claimIds: [graph.claims[0].claimId] });
  const job = store.claimNextJob('worker');
  store.completeJob(job.jobId, job.leaseToken, graph);
  const assertFound = () => {
    for (const spelling of ['Café', 'Cafe\u0301']) {
      const found = store.queryMemory(spelling).graph;
      assert.deepEqual([found.observations.length, found.passages.length, found.claims.length,
        found.profiles.length, found.relationships.length, found.clusters.length], [1, 1, 1, 2, 1, 1]);
    }
  };
  assertFound();
  store.rebuildSearchIndex();
  assertFound();
  store.close();
  const old = new DatabaseSync(filename);
  old.exec("PRAGMA user_version = 4; DELETE FROM evidence_terms");
  old.prepare("INSERT INTO evidence_terms(source_id, kind, term) VALUES (?, 'observation', 'cafe')").run(item.source.sourceId);
  old.close();
  store = new MGraphStore(filename);
  assertFound();
  store.close();
  store = new MGraphStore(filename);
  assertFound();
  store.deleteSource(item.source.sourceId);
  assert.equal(store.queryMemory('Café').graph.observations.length, 0);
  store.close();
});

test('combining marks distinguish words before and after rebuild and v5 upgrade', t => {
  const filename = fixture(t);
  const writer = new MGraphStore(filename);
  t.after(() => writer.close());
  const first = observation(randomUUID(), randomUUID(), 'मि');
  const second = observation(randomUUID(), randomUUID(), 'मा');
  writer.submitObservation(first);
  finish(writer, first);
  writer.submitObservation(second);
  finish(writer, second);
  const matchingSourceIds = query => writer.queryMemory(query).graph.observations.map(row => row.source.sourceId);
  assert.deepEqual(matchingSourceIds('मि'), [first.source.sourceId]);
  assert.deepEqual(matchingSourceIds('मा'), [second.source.sourceId]);
  writer.rebuildSearchIndex();
  assert.deepEqual(matchingSourceIds('मि'), [first.source.sourceId]);
  assert.deepEqual(matchingSourceIds('मा'), [second.source.sourceId]);
  writer.close();

  const legacy = new DatabaseSync(filename);
  legacy.exec("DELETE FROM evidence_terms; PRAGMA user_version = 5");
  legacy.prepare("INSERT INTO evidence_terms(source_id, kind, term) VALUES (?, 'observation', 'म')")
    .run(first.source.sourceId);
  legacy.prepare("INSERT INTO evidence_terms(source_id, kind, term) VALUES (?, 'observation', 'म')")
    .run(second.source.sourceId);
  legacy.close();
  const upgraded = new MGraphStore(filename);
  t.after(() => upgraded.close());
  assert.equal(STORE_SCHEMA_VERSION, 6);
  assert.deepEqual(upgraded.queryMemory('मि').graph.observations.map(row => row.source.sourceId), [first.source.sourceId]);
  assert.deepEqual(upgraded.queryMemory('मा').graph.observations.map(row => row.source.sourceId), [second.source.sourceId]);
});

test('derived entity IDs cannot be reused by another source and fail as a typed conflict', t => {
  const filename = fixture(t);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  const first = observation();
  const second = observation();
  store.submitObservation(first);
  const firstGraph = finish(store, first).graph;
  store.submitObservation(second);
  const job = store.claimNextJob('worker');
  const conflicting = graphFor(second);
  conflicting.claims[0].claimId = firstGraph.claims[0].claimId;
  conflicting.profiles[0].claimIds = [firstGraph.claims[0].claimId];
  assert.throws(() => store.completeJob(job.jobId, job.leaseToken, conflicting), StoreConflict);
  assert.equal(store.getStatus(second.source.sourceId)[0].state, 'processing');
  assert.equal(store.pendingJobs(), 1);
  assert.equal(store.getSnapshot(first.source.sourceId).claims.length, 1);
  store.failJob(job.jobId, job.leaseToken, 'Duplicate generated ID');
  store.retryJob(job.jobId);
  const retry = store.claimNextJob('worker');
  store.completeJob(retry.jobId, retry.leaseToken, graphFor(second));
  assert.equal(store.getSnapshot(second.source.sourceId).claims.length, 1);
  assert.equal(store.pendingJobs(), 0);
});

test('v1 upgrade keeps only current revision in search, snapshot and queue', t => {
  const filename = fixture(t);
  const old = createV1Database(filename);
  const stale = observation(randomUUID(), randomUUID(), 'Obsolete keyword', '2026-10-01T00:00:00.000Z');
  const item = observation(stale.source.sourceId, randomUUID(), 'Current keyword', '2026-10-02T00:00:00.000Z');
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 2, ?, 'pending', ?)")
    .run(item.source.sourceId, item.source.locator, item.observedAt, item.observedAt);
  for (const [revision, entry] of [[1, stale], [2, item]]) {
    old.prepare('INSERT INTO observations VALUES (?, ?, ?, ?)').run(entry.observationId, item.source.sourceId, revision, JSON.stringify(entry));
    old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, ?, ?, 'pending')")
      .run(entry.observationId, item.source.sourceId, revision, entry.observationId);
  }
  old.close();
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  assert.equal(store.queryMemory('Obsolete').graph.observations.length, 0);
  assert.deepEqual(store.getSnapshot().observations.map(row => row.observationId), [item.observationId]);
  assert.equal(store.pendingJobs(), 1);
  assert.equal(store.queryMemory('Current').graph.observations[0].observationId, item.observationId);
  finish(store, item);
  assert.equal(store.queryMemory('keyword').graph.claims.length, 1);
  assert.equal(store.claimNextJob('worker'), null);
  assert.throws(() => store.submitObservation(observation(item.source.sourceId, stale.observationId,
    'Reused old ID', '2026-10-03T00:00:00.000Z')), StoreConflict);
  store.submitObservation(observation(item.source.sourceId, randomUUID(), 'Replacement', '2026-10-03T00:00:00.000Z'));
  assert.throws(() => store.submitObservation(observation(item.source.sourceId, item.observationId,
    'Reused after upgrade', '2026-10-04T00:00:00.000Z')), StoreConflict);
});

test('v1 completed work without derived evidence is requeued during upgrade', t => {
  const filename = fixture(t);
  const old = createV1Database(filename);
  const item = observation();
  const leaseToken = randomUUID();
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 1, ?, 'complete', ?)")
    .run(item.source.sourceId, item.source.locator, item.observedAt, item.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)').run(item.observationId, item.source.sourceId, JSON.stringify(item));
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state, lease_token) VALUES (?, ?, 1, ?, 'complete', ?)")
    .run(item.observationId, item.source.sourceId, item.observationId, leaseToken);
  old.close();
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  assert.deepEqual(store.getSnapshot().observations.map(row => row.observationId), [item.observationId]);
  assert.equal(store.getSnapshot().claims.length, 0);
  assert.equal(store.queryMemory('Alice').graph.observations.length, 1);
  assert.equal(store.getStatus(item.source.sourceId)[0].state, 'pending');
  assert.equal(store.pendingJobs(), 1);
  assert.throws(() => store.completeJob(item.observationId, leaseToken, graphFor(item)), StoreConflict);
  const job = store.claimNextJob('upgrade-worker');
  assert.equal(job.observationId, item.observationId);
  store.completeJob(job.jobId, job.leaseToken, graphFor(item));
  assert.equal(store.getStatus(item.source.sourceId)[0].state, 'complete');
  assert.equal(store.queryMemory('Alice').graph.claims.length, 1);
  assert.equal(store.pendingJobs(), 0);
});

test('failed late v1 upgrade rolls back schema and preserves claimable work', t => {
  const filename = fixture(t);
  const old = createV1Database(filename);
  const item = observation();
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 1, ?, 'complete', ?)")
    .run(item.source.sourceId, item.source.locator, item.observedAt, item.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)').run(item.observationId, item.source.sourceId, JSON.stringify(item));
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, 1, ?, 'complete')")
    .run(item.observationId, item.source.sourceId, item.observationId);
  old.close();
  const originalExec = DatabaseSync.prototype.exec;
  DatabaseSync.prototype.exec = function (sql) {
    if (sql.includes('CREATE TABLE observation_ids')) throw new Error('injected late upgrade failure');
    return originalExec.call(this, sql);
  };
  try { assert.throws(() => new MGraphStore(filename), /injected late upgrade failure/); }
  finally { DatabaseSync.prototype.exec = originalExec; }
  const disk = new DatabaseSync(filename);
  assert.equal(disk.prepare('PRAGMA user_version').get().user_version, 1);
  assert.equal(disk.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name IN ('evidence', 'observation_ids')").get().n, 0);
  assert.equal(disk.prepare('SELECT count(*) AS n FROM observations').get().n, 1);
  disk.close();
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  assert.equal(store.pendingJobs(), 1);
  assert.equal(store.claimNextJob('repair-worker').observationId, item.observationId);
});

test('v1 and v2 case-colliding observation IDs fail upgrade with a typed error and no schema change', t => {
  for (const [create, expectedVersion] of [[createV1Database, 1], [createV2Database, 2]]) {
    const filename = fixture(t);
    const old = create(filename);
    const reusedId = randomUUID();
    const first = observation(randomUUID(), reusedId);
    const second = observation(randomUUID(), reusedId.toUpperCase());
    for (const item of [first, second]) {
      old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 1, ?, 'pending', ?)")
        .run(item.source.sourceId, item.source.locator, item.observedAt, item.observedAt);
      old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)')
        .run(item.observationId, item.source.sourceId, JSON.stringify(item));
    }
    old.close();
    assert.throws(() => new MGraphStore(filename), error => error instanceof StoreUnavailable &&
      /Case-folded UUID collision in observations/.test(error.message));
    const disk = new DatabaseSync(filename, { readOnly: true });
    assert.equal(disk.prepare('PRAGMA user_version').get().user_version, expectedVersion);
    assert.equal(disk.prepare('SELECT count(*) AS n FROM observations').get().n, 2);
    assert.equal(disk.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name = 'observation_ids'").get().n, 0);
    disk.close();
  }
});

test('v1 and v3 upgrade refuse malformed retained status or checkpoint before schema change', t => {
  for (const [create, version] of [[createV1Database, 1], [createV3Database, 3]]) {
    for (const malformed of ['status', 'checkpoint']) {
      const filename = fixture(t);
      const old = create(filename);
      const item = observation();
      old.prepare('INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, ?, ?, 1, ?, ?, ?)')
        .run(item.source.sourceId, item.source.kind, item.source.locator, item.observedAt,
          malformed === 'status' ? 'queued' : 'pending', item.observedAt);
      old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)')
        .run(item.observationId, item.source.sourceId, JSON.stringify(item));
      old.prepare('INSERT INTO jobs(job_id, source_id, revision, observation_id, state, checkpoint) VALUES (?, ?, 1, ?, ?, ?)')
        .run(item.observationId, item.source.sourceId, item.observationId, 'pending',
          malformed === 'checkpoint' ? '{"legacyStage":"halfway","extra":true}' : null);
      old.close();
      assert.throws(() => new MGraphStore(filename), error => error instanceof StoreUnavailable &&
        new RegExp(`V${version} (source|job) .*invalid`).test(error.message));
      const disk = new DatabaseSync(filename, { readOnly: true });
      assert.equal(disk.prepare('PRAGMA user_version').get().user_version, version);
      assert.equal(disk.prepare('SELECT count(*) AS n FROM observations').get().n, 1);
      assert.equal(disk.prepare('SELECT count(*) AS n FROM jobs').get().n, 1);
      disk.close();
    }
  }
});

test('v3 upgrade refuses an invalid current observation before changing schema', t => {
  const filename = fixture(t);
  const old = createV3Database(filename);
  const item = observation();
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 1, ?, 'pending', ?)")
    .run(item.source.sourceId, item.source.locator, item.observedAt, item.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)')
    .run(item.observationId, item.source.sourceId, JSON.stringify({ ...item, content: 'Changed without updating hash' }));
  old.close();
  assert.throws(() => new MGraphStore(filename), error => error instanceof StoreUnavailable &&
    /invalid current observation/.test(error.message));
  const disk = new DatabaseSync(filename, { readOnly: true });
  assert.equal(disk.prepare('PRAGMA user_version').get().user_version, 3);
  assert.equal(disk.prepare('SELECT count(*) AS n FROM observations').get().n, 1);
  disk.close();
});

test('committed v2/v3 midpoint with complete work but no evidence is requeued', t => {
  for (const create of [createV2Database, createV3Database]) {
    const filename = fixture(t);
    const old = create(filename);
    const item = observation();
    old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 1, ?, 'complete', ?)")
      .run(item.source.sourceId, item.source.locator, item.observedAt, item.observedAt);
    old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)').run(item.observationId, item.source.sourceId, JSON.stringify(item));
    old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, 1, ?, 'complete')")
      .run(item.observationId, item.source.sourceId, item.observationId);
    old.close();
    const store = new MGraphStore(filename);
    t.after(() => store.close());
    assert.equal(store.getStatus(item.source.sourceId)[0].state, 'pending');
    assert.equal(store.getSnapshot().claims.length, 0);
    assert.equal(store.queryMemory('Alice').graph.observations.length, 1);
    assert.equal(store.pendingJobs(), 1);
    finish(store, item);
    assert.equal(store.queryMemory('Alice').graph.claims.length, 1);
  }
});

test('v3 upgrade prunes an obsolete failed job and retry cannot disturb newer completed work', t => {
  const filename = fixture(t);
  const old = createV3Database(filename);
  const stale = observation(randomUUID(), randomUUID(), 'Old revision', '2026-10-01T00:00:00Z');
  const current = observation(stale.source.sourceId, randomUUID(), 'Current revision', '2026-10-02T00:00:00Z');
  const graph = graphFor(current);
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 2, ?, 'complete', ?)")
    .run(current.source.sourceId, current.source.locator, current.observedAt, current.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)').run(stale.observationId, stale.source.sourceId, JSON.stringify(stale));
  old.prepare('INSERT INTO observations VALUES (?, ?, 2, ?)').run(current.observationId, current.source.sourceId, JSON.stringify(current));
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, 1, ?, 'failed')")
    .run(stale.observationId, stale.source.sourceId, stale.observationId);
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, 2, ?, 'complete')")
    .run(current.observationId, current.source.sourceId, current.observationId);
  const insert = old.prepare('INSERT INTO evidence(kind, entity_id, source_id, payload) VALUES (?, ?, ?, ?)');
  for (const [kind, records, key] of [
    ['passage', graph.passages, 'passageId'], ['claim', graph.claims, 'claimId'], ['profile', graph.profiles, 'profileId'],
  ]) for (const record of records) insert.run(kind, record[key], current.source.sourceId, JSON.stringify(record));
  old.close();
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  assert.throws(() => store.retryJob(stale.observationId), StoreConflict);
  assert.equal(store.getStatus(current.source.sourceId)[0].state, 'complete');
  assert.equal(store.pendingJobs(), 0);
  assert.equal(store.claimNextJob('worker'), null);
  assert.equal(store.queryMemory('Current').graph.claims.length, 1);
  assert.equal(store.queryMemory('Old').graph.observations.length, 0);
  const disk = new DatabaseSync(filename, { readOnly: true });
  assert.equal(disk.prepare('SELECT count(*) AS n FROM jobs').get().n, 1);
  assert.equal(disk.prepare('SELECT count(*) AS n FROM observations').get().n, 1);
  disk.close();
});

test('v1 upgrade refuses a completed source with no current observation before changing schema', t => {
  const filename = fixture(t);
  const old = createV1Database(filename);
  const sourceId = randomUUID();
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 1, ?, 'complete', ?)")
    .run(sourceId, `note:${sourceId}`, '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');
  old.close();
  assert.throws(() => new MGraphStore(filename), /no current observation/);
  const disk = new DatabaseSync(filename, { readOnly: true });
  assert.equal(disk.prepare('PRAGMA user_version').get().user_version, 1);
  disk.close();
});

test('v2 upgrade refuses a missing current observation and succeeds after repair', t => {
  const filename = fixture(t);
  const old = createV2Database(filename);
  const stale = observation(randomUUID(), randomUUID(), 'Old only term', '2026-10-01T00:00:00Z');
  const current = observation(stale.source.sourceId, randomUUID(), 'Restored current term', '2026-10-02T00:00:00Z');
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 2, ?, 'complete', ?)")
    .run(current.source.sourceId, current.source.locator, current.observedAt, current.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)')
    .run(stale.observationId, stale.source.sourceId, JSON.stringify(stale));
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, 1, ?, 'pending')")
    .run(stale.observationId, stale.source.sourceId, stale.observationId);
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, 2, ?, 'complete')")
    .run(current.observationId, current.source.sourceId, current.observationId);
  old.close();

  assert.throws(() => new MGraphStore(filename), /V2 source.*no current observation/);
  const disk = new DatabaseSync(filename);
  assert.equal(disk.prepare('PRAGMA user_version').get().user_version, 2);
  assert.equal(disk.prepare('SELECT count(*) AS count FROM observations').get().count, 1);
  assert.equal(disk.prepare('SELECT count(*) AS count FROM jobs').get().count, 2);
  disk.prepare('INSERT INTO observations VALUES (?, ?, 2, ?)')
    .run(current.observationId, current.source.sourceId, JSON.stringify(current));
  disk.close();

  const store = new MGraphStore(filename);
  t.after(() => store.close());
  assert.equal(store.getStatus(current.source.sourceId)[0].state, 'pending');
  assert.deepEqual(store.getSnapshot(current.source.sourceId).observations.map(row => row.observationId), [current.observationId]);
  assert.equal(store.queryMemory('Old').graph.observations.length, 0);
  assert.deepEqual(store.queryMemory('Restored').graph.observations.map(row => row.observationId), [current.observationId]);
  assert.equal(store.pendingJobs(), 1);
  const job = store.claimNextJob('repair-worker');
  assert.equal(job.observationId, current.observationId);
  store.completeJob(job.jobId, job.leaseToken, graphFor(current));
  assert.equal(store.getStatus(current.source.sourceId)[0].state, 'complete');
  assert.equal(store.queryMemory('Restored').graph.claims.length, 1);
  assert.equal(store.pendingJobs(), 0);
  assert.equal(store.claimNextJob('repair-worker'), null);
});

test('submillisecond source order accepts newer instant and fences equal or older observations', t => {
  const filename = fixture(t);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  const first = observation(randomUUID(), randomUUID(), 'First revision', '2026-10-01T00:00:00.000001Z');
  const accepted = store.submitObservation(first);
  const oldJob = store.claimNextJob('old-worker');
  const second = observation(first.source.sourceId, randomUUID(), 'Second revision', '2026-10-01T00:00:00.000002Z');
  assert.equal(store.submitObservation(second).revision, 2);
  assert.throws(() => store.completeJob(oldJob.jobId, oldJob.leaseToken, graphFor(first)), StoreConflict);
  assert.deepEqual(store.submitObservation(second), { observationId: second.observationId, revision: 2, replayed: true });
  assert.throws(() => store.submitObservation(observation(first.source.sourceId, randomUUID(), 'Equal instant',
    '2026-10-01T05:30:00.000002+05:30')), StoreConflict);
  assert.throws(() => store.submitObservation(first), StoreConflict);
  assert.equal(store.queryMemory('First').graph.observations.length, 0);
  assert.deepEqual(store.getSnapshot().observations.map(row => row.observationId), [second.observationId]);
  assert.equal(store.pendingJobs(), 1);
  const job = store.claimNextJob('new-worker');
  assert.equal(job.observationId, second.observationId);
  store.completeJob(job.jobId, job.leaseToken, graphFor(second));
  assert.equal(store.queryMemory('Second').graph.claims.length, 1);
  assert.equal(store.pendingJobs(), 0);
  assert.equal(accepted.revision, 1);
});

test('long fractional timestamps preserve ordering without trailing-zero backtracking', t => {
  const filename = fixture(t);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  const sourceId = randomUUID();
  const first = observation(sourceId, randomUUID(), 'First', `2026-10-01T00:00:00.${'0'.repeat(20_000)}1Z`);
  const second = observation(sourceId, randomUUID(), 'Second', `2026-10-01T00:00:00.${'0'.repeat(20_000)}2Z`);
  store.submitObservation(first);
  assert.equal(store.submitObservation(second).revision, 2);
  assert.equal(store.getSnapshot(sourceId).observations[0].observationId, second.observationId);
});

test('UUID casing is one identity for source, observation, graph, replay and retirement', t => {
  const filename = fixture(t);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  const item = observation();
  const uppercase = { ...item, observationId: item.observationId.toUpperCase(),
    source: { ...item.source, sourceId: item.source.sourceId.toUpperCase() } };
  assert.equal(store.submitObservation(uppercase).observationId, uppercase.observationId);
  assert.equal(store.submitObservation(item).replayed, true);
  assert.equal(store.submitObservation({ ...item, observationId: mixedUuid(item.observationId),
    source: { ...item.source, sourceId: mixedUuid(item.source.sourceId) } }).replayed, true);
  const job = store.claimNextJob('worker');
  assert.equal(job.sourceId, item.source.sourceId);
  const graph = graphFor(item);
  const upperGraph = structuredClone(graph);
  upperGraph.observations = [uppercase];
  upperGraph.passages[0].passageId = upperGraph.passages[0].passageId.toUpperCase();
  upperGraph.passages[0].observationId = item.observationId; // Mixed-case reference still names this observation.
  upperGraph.claims[0].claimId = upperGraph.claims[0].claimId.toUpperCase();
  upperGraph.claims[0].provenance[0].passageId = upperGraph.passages[0].passageId;
  upperGraph.claims[0].provenance[0].observationId = uppercase.observationId;
  upperGraph.profiles[0].profileId = upperGraph.profiles[0].profileId.toUpperCase();
  upperGraph.profiles[0].claimIds = [upperGraph.claims[0].claimId];
  store.completeJob(job.jobId.toUpperCase(), job.leaseToken.toUpperCase(), upperGraph);
  store.completeJob(job.jobId, job.leaseToken, graph);
  assert.equal(store.getSnapshot(item.source.sourceId.toUpperCase()).claims[0].claimId, graph.claims[0].claimId);
  assert.equal(store.getStatus(item.source.sourceId.toUpperCase())[0].sourceId, item.source.sourceId.toUpperCase());
  const next = observation(item.source.sourceId, randomUUID(), 'Next revision', '2026-10-02T00:00:00Z');
  store.submitObservation(next);
  assert.throws(() => store.submitObservation(observation(item.source.sourceId, item.observationId.toUpperCase(),
    'Reused after replacement', '2026-10-03T00:00:00Z')), StoreConflict);
  assert.throws(() => store.submitObservation(observation(item.source.sourceId, mixedUuid(item.observationId),
    'Reused after replacement', '2026-10-03T00:00:00Z')), StoreConflict);
  store.deleteSource(item.source.sourceId.toUpperCase());
  assert.equal(store.queryMemory('Alice').graph.observations.length, 0);
  assert.throws(() => store.submitObservation(item), StoreConflict);
  assert.throws(() => store.submitObservation(observation(randomUUID(), item.observationId.toUpperCase(),
    'Reused ID', '2026-10-02T00:00:00Z')), StoreConflict);
  assert.throws(() => store.submitObservation(observation(randomUUID(), mixedUuid(item.observationId),
    'Reused ID', '2026-10-02T00:00:00Z')), StoreConflict);
});

test('store acknowledgments preserve UUID spelling required by SET-5 response correlation', t => {
  const filename = fixture(t);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  const item = uppercaseUuids(observation());
  const submit = decodeIpcRequest({ protocolVersion: 2, requestId: randomUUID(), operation: 'submitObservation', payload: item });
  const accepted = store.submitObservation(submit.request.payload);
  assert.equal(parseIpcResponse({ protocolVersion: 2, requestId: submit.request.requestId, operation: 'submitObservation',
    ok: true, result: { kind: 'observationAccepted', observationId: accepted.observationId } }, submit).ok, true);
  const status = decodeIpcRequest({ protocolVersion: 2, requestId: randomUUID(), operation: 'getStatus',
    sourceId: item.source.sourceId });
  assert.equal(parseIpcResponse({ protocolVersion: 2, requestId: status.request.requestId, operation: 'getStatus',
    ok: true, result: { kind: 'status', statuses: store.getStatus(status.request.sourceId) } }, status).ok, true);
  assert.equal(store.getStatus()[0].sourceId, item.source.sourceId.toLowerCase());
});

test('v3 upgrade canonicalizes retained source, observation and evidence references', t => {
  const filename = fixture(t);
  const old = createV3Database(filename);
  const item = observation();
  const upperItem = uppercaseUuids(item);
  const graph = uppercaseUuids(graphFor(item));
  const token = randomUUID().toUpperCase();
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 1, ?, 'complete', ?)")
    .run(upperItem.source.sourceId, item.source.locator, item.observedAt, item.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)')
    .run(upperItem.observationId, upperItem.source.sourceId, JSON.stringify(upperItem));
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state, lease_token, graph_hash) VALUES (?, ?, 1, ?, 'complete', ?, 'old-digest')")
    .run(upperItem.observationId, upperItem.source.sourceId, upperItem.observationId, token);
  old.prepare('INSERT INTO observation_ids VALUES (?)')
    .run(createHash('sha256').update(upperItem.observationId).digest('hex'));
  const insert = old.prepare('INSERT INTO evidence(kind, entity_id, source_id, payload) VALUES (?, ?, ?, ?)');
  for (const [kind, records, key] of [
    ['passage', graph.passages, 'passageId'], ['claim', graph.claims, 'claimId'], ['profile', graph.profiles, 'profileId'],
  ]) for (const record of records) insert.run(kind, record[key], upperItem.source.sourceId, JSON.stringify(record));
  old.close();
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  assert.equal(store.submitObservation(item).replayed, true);
  const snapshot = store.getSnapshot(item.source.sourceId.toUpperCase());
  assert.equal(snapshot.observations[0].observationId, item.observationId);
  assert.equal(snapshot.passages[0].observationId, item.observationId);
  assert.equal(snapshot.claims[0].provenance[0].passageId, graph.passages[0].passageId.toLowerCase());
  assert.equal(store.queryMemory('Alice').graph.claims.length, 1);
  store.completeJob(upperItem.observationId, token, graph);
  store.deleteSource(item.source.sourceId);
  assert.equal(store.pendingJobs(), 0);
  assert.throws(() => store.submitObservation(observation(randomUUID(), upperItem.observationId,
    'Reused', '2026-10-02T00:00:00Z')), StoreConflict);
});

test('retained mixed-case v3 identity replays in every spelling and fences its old lease', t => {
  const filename = fixture(t);
  const old = createV3Database(filename);
  const item = observation();
  const legacy = { ...item, observationId: mixedUuid(item.observationId),
    source: { ...item.source, sourceId: mixedUuid(item.source.sourceId) } };
  const token = randomUUID().toUpperCase();
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 1, ?, 'processing', ?)")
    .run(legacy.source.sourceId, legacy.source.locator, legacy.observedAt, legacy.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)')
    .run(legacy.observationId, legacy.source.sourceId, JSON.stringify(legacy));
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state, attempts, lease_token, lease_until, worker_id) VALUES (?, ?, 1, ?, 'processing', 1, ?, ?, 'old')")
    .run(legacy.observationId, legacy.source.sourceId, legacy.observationId, token, Date.now() + 60_000);
  old.prepare('INSERT INTO observation_ids VALUES (?)')
    .run(createHash('sha256').update(legacy.observationId).digest('hex'));
  old.close();
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  for (const spelling of [legacy.observationId, item.observationId, item.observationId.toUpperCase()]) {
    const replay = { ...item, observationId: spelling };
    assert.equal(store.submitObservation(replay).replayed, true);
  }
  const newer = observation(item.source.sourceId, randomUUID(), 'New revision', '2026-10-02T00:00:00Z');
  store.submitObservation(newer);
  assert.throws(() => store.completeJob(legacy.observationId, token, graphFor(item)), StoreConflict);
  assert.throws(() => store.submitObservation(observation(item.source.sourceId, legacy.observationId,
    'Reused', '2026-10-03T00:00:00Z')), StoreConflict);
  assert.equal(store.pendingJobs(), 1);
  store.deleteSource(item.source.sourceId);
  assert.equal(store.pendingJobs(), 0);
  assert.throws(() => store.submitObservation(observation(randomUUID(), legacy.observationId,
    'Retired reuse', '2026-10-04T00:00:00Z')), StoreConflict);
});

test('v3 and v4 upgrades refuse opaque purged UUID hashes atomically', t => {
  for (const version of [3, 4]) {
    const filename = fixture(t);
    const old = createV3Database(filename);
    const usedId = mixedUuid(randomUUID());
    old.prepare('INSERT INTO observation_ids VALUES (?)')
      .run(createHash('sha256').update(usedId).digest('hex'));
    if (version === 4) old.exec('PRAGMA user_version = 4');
    old.close();
    assert.throws(() => new MGraphStore(filename), error => error instanceof StoreUnavailable &&
      /unresolvable retired ID/.test(error.message));
    const disk = new DatabaseSync(filename, { readOnly: true });
    assert.equal(disk.prepare('PRAGMA user_version').get().user_version, version);
    assert.equal(disk.prepare('SELECT count(*) AS n FROM observation_ids').get().n, 1);
    assert.equal(disk.prepare('SELECT count(*) AS n FROM observations').get().n, 0);
    disk.close();
  }
});

test('malformed optional source scopes never expand into all-source reads', t => {
  const filename = fixture(t);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  store.submitObservation(observation());
  for (const bad of ['', null, false, 0]) {
    assert.throws(() => store.getStatus(bad));
    assert.throws(() => store.getSnapshot(bad));
  }
  assert.throws(() => store.queryMemory('Alice', { cursor: '' }));
  assert.throws(() => store.queryMemory('Alice', { cursor: null }));
  assert.equal(store.getStatus().length, 1);
  assert.equal(store.getSnapshot().observations.length, 1);
});

test('failed rollback preserves original write and read errors', t => {
  const filename = fixture(t);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  const item = observation();
  store.submitObservation(item);
  const db = store.db;
  const originalExec = db.exec.bind(db);
  db.exec = sql => {
    if (sql === 'ROLLBACK') throw new Error('secondary rollback failure');
    return originalExec(sql);
  };
  try {
    assert.throws(() => store.submitObservation(observation(item.source.sourceId, randomUUID(), 'Old',
      '2025-10-01T00:00:00Z')), StoreConflict);
  } finally {
    db.exec = originalExec;
    originalExec('ROLLBACK');
  }
  const disk = new DatabaseSync(filename);
  disk.prepare("INSERT INTO evidence(kind, entity_id, source_id, payload) VALUES ('passage', ?, ?, ?)")
    .run(randomUUID(), item.source.sourceId, JSON.stringify({ ...graphFor(item).passages[0], observationId: randomUUID() }));
  disk.close();
  db.exec = sql => {
    if (sql === 'ROLLBACK') throw new Error('secondary rollback failure');
    return originalExec(sql);
  };
  try { assert.throws(() => store.getSnapshot(), /Passage has no live observation/); }
  finally { db.exec = originalExec; originalExec('ROLLBACK'); }
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

test('interrupted job resumes checkpoint, stale lease fails, replay is idempotent', async t => {
  const filename = fixture(t);
  let store = new MGraphStore(filename);
  const item = observation();
  const accepted = store.submitObservation(item);
  assert.equal(accepted.replayed, false);
  assert.deepEqual(store.submitObservation(item), { ...accepted, replayed: true });
  const first = store.claimNextJob('first', 100);
  assert.ok(first);
  store.checkpointJob(first.jobId, first.leaseToken, { stage: 'extracted', cursor: 'page:2' });
  store.close();
  store = new MGraphStore(filename);
  t.after(() => store.close());
  await delay(150);
  const resumed = store.claimNextJob('second', 5000);
  assert.equal(resumed.attempts, 2);
  assert.deepEqual(resumed.checkpoint, { stage: 'extracted', cursor: 'page:2' });
  const graph = graphFor(item);
  assert.throws(() => store.completeJob(first.jobId, first.leaseToken, graph), StoreConflict);
  store.completeJob(resumed.jobId, resumed.leaseToken, graph);
  store.completeJob(resumed.jobId, resumed.leaseToken, graph);
  assert.throws(() => store.completeJob(resumed.jobId, resumed.leaseToken, graphFor(item)), StoreConflict);
  store.close();
  store = new MGraphStore(filename);
  store.completeJob(resumed.jobId, resumed.leaseToken, graph);
  assert.throws(() => store.completeJob(resumed.jobId, resumed.leaseToken, graphFor(item)), StoreConflict);
  assert.equal(store.getSnapshot().claims.length, 1);
  assert.equal(store.pendingJobs(), 0);
});

test('expired lease cannot mutate before reclaim', async t => {
  const filename = fixture(t);
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  const item = observation();
  store.submitObservation(item);
  const first = store.claimNextJob('first', 20);
  await delay(50);
  assert.throws(() => store.checkpointJob(first.jobId, first.leaseToken, { stage: 'late' }), StoreConflict);
  assert.throws(() => store.renewJob(first.jobId, first.leaseToken, 1000), StoreConflict);
  assert.throws(() => store.failJob(first.jobId, first.leaseToken, 'late'), StoreConflict);
  assert.throws(() => store.completeJob(first.jobId, first.leaseToken, graphFor(item)), StoreConflict);
  assert.equal(store.pendingJobs(), 1);
  const second = store.claimNextJob('second', 5000);
  assert.equal(second.attempts, 2);
  assert.equal(second.checkpoint, null);
  store.completeJob(second.jobId, second.leaseToken, graphFor(item));
  assert.equal(store.pendingJobs(), 0);
});

test('abrupt writer exit leaves a reclaimable lock and durable queued work', async t => {
  const filename = fixture(t);
  const item = observation();
  const moduleUrl = new URL('../dist/index.js', import.meta.url).href;
  const child = spawn(process.execPath, ['--input-type=module', '-e', `
    import { MGraphStore } from ${JSON.stringify(moduleUrl)};
    const store = new MGraphStore(${JSON.stringify(filename)});
    store.submitObservation(${JSON.stringify(item)});
    const job = store.claimNextJob('terminated-worker', 100);
    store.checkpointJob(job.jobId, job.leaseToken, { stage: 'captured' });
    console.log('CHECKPOINTED');
    setInterval(() => store.pendingJobs(), 1000);
  `], { stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => child.kill('SIGKILL'));
  await new Promise((resolve, reject) => {
    child.stdout.once('data', chunk => chunk.toString().includes('CHECKPOINTED') ? resolve() : reject(new Error('Missing checkpoint signal')));
    child.once('error', reject);
    child.once('exit', code => reject(new Error(`Writer exited ${code} before checkpoint`)));
  });
  const exited = new Promise(resolve => child.once('exit', resolve));
  child.kill('SIGKILL');
  await exited;
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  await delay(150);
  const job = store.claimNextJob('replacement-worker', 5000);
  assert.equal(job.checkpoint.stage, 'captured');
  store.completeJob(job.jobId, job.leaseToken, graphFor(item));
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
  assert.throws(() => store.submitObservation(observation(first.source.sourceId, first.observationId,
    'Reused ID with newer timestamp', '2026-10-03T00:00:00.000Z')), StoreConflict);
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
  assert.throws(() => store.submitObservation(observation(randomUUID(), first.observationId,
    'Reused after deletion', '2026-10-04T00:00:00.000Z')), StoreConflict);
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
  const cyclic = graphFor(item);
  cyclic.unexpected = cyclic;
  assert.throws(() => store.completeJob(job.jobId, job.leaseToken, cyclic), /cyclic or deeply nested/);
  assert.equal(store.getStatus(item.source.sourceId)[0].state, 'processing');
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

test('v2 upgrade backfills observation identities after source replacement', t => {
  const filename = fixture(t);
  const old = createV2Database(filename);
  const first = observation();
  const completedGraph = graphFor(first);
  const leaseToken = randomUUID();
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 1, ?, 'pending', ?)")
    .run(first.source.sourceId, first.source.locator, first.observedAt, first.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)').run(first.observationId, first.source.sourceId, JSON.stringify(first));
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state, lease_token) VALUES (?, ?, 1, ?, 'complete', ?)")
    .run(first.observationId, first.source.sourceId, first.observationId, leaseToken);
  const insertEvidence = old.prepare('INSERT INTO evidence(kind, entity_id, source_id, payload) VALUES (?, ?, ?, ?)');
  for (const [kind, entries, key] of [
    ['passage', completedGraph.passages, 'passageId'], ['claim', completedGraph.claims, 'claimId'],
    ['profile', completedGraph.profiles, 'profileId'],
  ]) for (const entity of entries) insertEvidence.run(kind, entity[key], first.source.sourceId, JSON.stringify(entity));
  const stale = observation(randomUUID(), randomUUID(), 'Forgotten passage', '2026-10-01T00:00:00.000Z');
  const current = observation(stale.source.sourceId, randomUUID(), 'Fresh passage', '2026-10-02T00:00:00.000Z');
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 2, ?, 'complete', ?)")
    .run(current.source.sourceId, current.source.locator, current.observedAt, current.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 1, ?)').run(stale.observationId, stale.source.sourceId, JSON.stringify(stale));
  old.prepare('INSERT INTO observations VALUES (?, ?, 2, ?)').run(current.observationId, current.source.sourceId, JSON.stringify(current));
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, 1, ?, 'pending')")
    .run(stale.observationId, stale.source.sourceId, stale.observationId);
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, 2, ?, 'complete')")
    .run(current.observationId, current.source.sourceId, current.observationId);
  const stalePassage = graphFor(stale).passages[0];
  insertEvidence.run('passage', stalePassage.passageId, stale.source.sourceId, JSON.stringify(stalePassage));
  old.prepare("INSERT INTO evidence_terms VALUES (?, 'passage', 'forgotten')").run(stale.source.sourceId);
  old.close();
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  assert.equal(store.submitObservation(first).replayed, true);
  store.completeJob(first.observationId, leaseToken, completedGraph);
  assert.throws(() => store.completeJob(first.observationId, leaseToken, graphFor(first)), StoreConflict);
  assert.equal(store.queryMemory('Forgotten').graph.observations.length, 0);
  assert.deepEqual(store.getSnapshot(stale.source.sourceId).observations.map(row => row.observationId), [current.observationId]);
  assert.equal(store.pendingJobs(), 1);
  assert.equal(store.getStatus(stale.source.sourceId)[0].state, 'pending');
  const repaired = store.claimNextJob('repair-worker');
  assert.equal(repaired.observationId, current.observationId);
  store.completeJob(repaired.jobId, repaired.leaseToken, graphFor(current));
  assert.equal(store.queryMemory('Fresh').graph.observations.length, 1);
  assert.equal(store.pendingJobs(), 0);
  assert.throws(() => store.submitObservation(observation(stale.source.sourceId, stale.observationId,
    'Old ID reused', '2026-10-03T00:00:00.000Z')), StoreConflict);
  store.submitObservation(observation(first.source.sourceId, randomUUID(), 'New snapshot', '2026-10-02T00:00:00.000Z'));
  assert.throws(() => store.submitObservation(observation(first.source.sourceId, first.observationId,
    'Changed content', '2026-10-03T00:00:00.000Z')), StoreConflict);
});

test('v2 upgrade discards evidence-only stale revision and requeues current work', t => {
  const filename = fixture(t);
  const old = createV2Database(filename);
  const stale = observation(randomUUID(), randomUUID(), 'Oldterm only', '2026-10-01T00:00:00Z');
  const current = observation(stale.source.sourceId, randomUUID(), 'Currentterm only', '2026-10-02T00:00:00Z');
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 2, ?, 'pending', ?)")
    .run(current.source.sourceId, current.source.locator, current.observedAt, current.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 2, ?)')
    .run(current.observationId, current.source.sourceId, JSON.stringify(current));
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, 2, ?, 'pending')")
    .run(current.observationId, current.source.sourceId, current.observationId);
  const oldPassage = graphFor(stale).passages[0];
  old.prepare('INSERT INTO evidence(kind, entity_id, source_id, payload) VALUES (?, ?, ?, ?)')
    .run('passage', oldPassage.passageId, current.source.sourceId, JSON.stringify(oldPassage));
  old.prepare("INSERT INTO evidence_terms VALUES (?, 'passage', 'oldterm')").run(current.source.sourceId);
  assert.equal(old.prepare('SELECT count(*) AS n FROM observations').get().n, 1);
  assert.equal(old.prepare('SELECT count(*) AS n FROM jobs').get().n, 1);
  old.close();

  const store = new MGraphStore(filename);
  t.after(() => store.close());
  assert.equal(store.getStatus(current.source.sourceId)[0].state, 'pending');
  assert.deepEqual(store.getSnapshot(current.source.sourceId).observations.map(row => row.observationId), [current.observationId]);
  assert.equal(store.getSnapshot(current.source.sourceId).passages.length, 0);
  assert.equal(store.queryMemory('Oldterm').graph.observations.length, 0);
  store.rebuildSearchIndex();
  assert.equal(store.queryMemory('Oldterm').graph.observations.length, 0);
  assert.equal(store.queryMemory('Currentterm').graph.observations.length, 1);
  assert.equal(store.pendingJobs(), 1);
  const job = store.claimNextJob('upgrade-worker');
  assert.equal(job.observationId, current.observationId);
  assert.equal(store.claimNextJob('other-worker'), null);
  store.completeJob(job.jobId, job.leaseToken, graphFor(current));
  assert.equal(store.getStatus(current.source.sourceId)[0].state, 'complete');
  assert.equal(store.queryMemory('Currentterm').graph.claims.length, 1);
  assert.equal(store.pendingJobs(), 0);
  store.deleteSource(current.source.sourceId);
  assert.equal(store.getSnapshot(current.source.sourceId).observations.length, 0);
  assert.equal(store.queryMemory('Currentterm').graph.observations.length, 0);
  assert.equal(store.pendingJobs(), 0);
  assert.equal(store.claimNextJob('other-worker'), null);
});

test('v2 upgrade repairs a completed current job with stale evidence but no stale job', t => {
  const filename = fixture(t);
  const old = createV2Database(filename);
  const stale = observation(randomUUID(), randomUUID(), 'Former passage', '2026-10-01T00:00:00Z');
  const current = observation(stale.source.sourceId, randomUUID(), 'Present passage', '2026-10-02T00:00:00Z');
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 2, ?, 'complete', ?)")
    .run(current.source.sourceId, current.source.locator, current.observedAt, current.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 2, ?)')
    .run(current.observationId, current.source.sourceId, JSON.stringify(current));
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, 2, ?, 'complete')")
    .run(current.observationId, current.source.sourceId, current.observationId);
  const stalePassage = graphFor(stale).passages[0];
  old.prepare('INSERT INTO evidence(kind, entity_id, source_id, payload) VALUES (?, ?, ?, ?)')
    .run('passage', stalePassage.passageId, current.source.sourceId, JSON.stringify(stalePassage));
  old.close();

  const store = new MGraphStore(filename);
  t.after(() => store.close());
  assert.equal(store.getStatus(current.source.sourceId)[0].state, 'pending');
  assert.equal(store.getSnapshot(current.source.sourceId).passages.length, 0);
  assert.equal(store.queryMemory('Former').graph.observations.length, 0);
  assert.equal(store.pendingJobs(), 1);
  const job = store.claimNextJob('repair-worker');
  assert.equal(job.observationId, current.observationId);
  store.completeJob(job.jobId, job.leaseToken, graphFor(current));
  assert.equal(store.getStatus(current.source.sourceId)[0].state, 'complete');
  assert.equal(store.queryMemory('Present').graph.claims.length, 1);
});

test('v3 upgrade repairs stale passage with a current pending job', t => {
  const filename = fixture(t);
  const old = createV3Database(filename);
  const stale = observation(randomUUID(), randomUUID(), 'Stalephrase', '2026-10-01T00:00:00Z');
  const current = observation(stale.source.sourceId, randomUUID(), 'Currentphrase', '2026-10-02T00:00:00Z');
  old.prepare("INSERT INTO sources(source_id, kind, locator, revision, observed_at, state, updated_at) VALUES (?, 'manual', ?, 2, ?, 'pending', ?)")
    .run(current.source.sourceId, current.source.locator, current.observedAt, current.observedAt);
  old.prepare('INSERT INTO observations VALUES (?, ?, 2, ?)')
    .run(current.observationId, current.source.sourceId, JSON.stringify(current));
  old.prepare("INSERT INTO jobs(job_id, source_id, revision, observation_id, state) VALUES (?, ?, 2, ?, 'pending')")
    .run(current.observationId, current.source.sourceId, current.observationId);
  const passage = graphFor(stale).passages[0];
  old.prepare('INSERT INTO evidence(kind, entity_id, source_id, payload) VALUES (?, ?, ?, ?)')
    .run('passage', passage.passageId, current.source.sourceId, JSON.stringify(passage));
  old.prepare("INSERT INTO evidence_terms VALUES (?, 'passage', 'stalephrase')").run(current.source.sourceId);
  old.close();
  const store = new MGraphStore(filename);
  t.after(() => store.close());
  assert.equal(store.queryMemory('Stalephrase').graph.observations.length, 0);
  assert.equal(store.getSnapshot().passages.length, 0);
  assert.equal(store.pendingJobs(), 1);
  finish(store, current);
  assert.equal(store.queryMemory('Currentphrase').graph.claims.length, 1);
});

test('writer OS lock has one owner across simultaneous recovery and repeated close', async t => {
  const filename = fixture(t);
  const moduleUrl = new URL('../dist/index.js', import.meta.url).href;
  const script = `
    import { MGraphStore, StoreUnavailable } from ${JSON.stringify(moduleUrl)};
    try {
      const store = new MGraphStore(${JSON.stringify(filename)});
      console.log('OWNER');
      setInterval(() => store.pendingJobs(), 1000);
    } catch (error) {
      if (!(error instanceof StoreUnavailable)) throw error;
      console.log('BUSY');
    }
  `;
  async function contend() {
    const children = Array.from({ length: 5 }, () => spawn(process.execPath,
      ['--input-type=module', '-e', script], { stdio: ['ignore', 'pipe', 'pipe'] }));
    t.after(() => children.forEach(child => child.kill('SIGKILL')));
    const results = await Promise.all(children.map(child => new Promise((resolve, reject) => {
      let output = '';
      child.stdout.on('data', chunk => {
        output += chunk;
        if (output.includes('\n')) resolve({ child, result: output.trim() });
      });
      child.once('error', reject);
      child.once('exit', code => { if (!output.includes('\n')) reject(new Error(`child exited ${code} before lock result`)); });
    })));
    const owners = results.filter(entry => entry.result === 'OWNER');
    assert.equal(owners.length, 1, JSON.stringify(results.map(entry => entry.result)));
    assert.equal(results.filter(entry => entry.result === 'BUSY').length, 4);
    const ownerExit = new Promise(resolve => owners[0].child.once('exit', resolve));
    owners[0].child.kill('SIGKILL');
    await ownerExit;
    await Promise.all(results.filter(entry => entry.result === 'BUSY').map(entry =>
      entry.child.exitCode !== null ? Promise.resolve() : new Promise(resolve => entry.child.once('exit', resolve))));
  }
  await contend();
  await contend();
  const store = new MGraphStore(filename);
  store.close();
  store.close();
  const replacement = new MGraphStore(filename);
  replacement.close();
  replacement.close();
});
