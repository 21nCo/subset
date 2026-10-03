import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import test from 'node:test';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import {
  decodeIpcRequest, graphSnapshotSchema, ipcRequestV1Schema, ipcRequestV2Schema,
  jsonSchemas, observationSchema, parseGraphSnapshot, parseIpcRequest, parseIpcResponse,
  parseObservation, sourceHash,
} from '../dist/index.js';

const ids = Object.fromEntries(['source', 'observation', 'passage', 'claim', 'profile', 'other', 'relationship', 'cluster', 'request']
  .map((name, index) => [name, `00000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`]));
const at = '2026-10-03T00:00:00Z';
const source = { sourceId: ids.source, kind: 'accessibility', locator: 'app:example/window:1', applicationBundleId: 'dev.example.app' };
const content = 'Alice works with Bob. 🌍';
const observation = { schemaVersion: 1, observationId: ids.observation, source, observedAt: at, state: 'complete', content, sourceHash: sourceHash(content) };
const passage = { schemaVersion: 1, passageId: ids.passage, observationId: ids.observation, sourceHash: observation.sourceHash, start: 0, end: 21, text: 'Alice works with Bob.' };
const claim = { schemaVersion: 1, claimId: ids.claim, statement: 'Alice works with Bob', provenance: [{ observationId: ids.observation, passageId: ids.passage, sourceHash: observation.sourceHash, modelVersion: 'model-2026-09' }] };
const graph = {
  schemaVersion: 1, observations: [observation], passages: [passage], claims: [claim],
  profiles: [
    { schemaVersion: 1, profileId: ids.profile, name: 'Alice', modelVersion: 'profile-model-1', claimIds: [ids.claim] },
    { schemaVersion: 1, profileId: ids.other, name: 'Bob', modelVersion: 'profile-model-1', claimIds: [ids.claim] },
  ],
  relationships: [{ schemaVersion: 1, relationshipId: ids.relationship, fromProfileId: ids.profile, toProfileId: ids.other, kind: 'worksWith', modelVersion: 'relation-model-2', claimIds: [ids.claim] }],
  clusters: [{ schemaVersion: 1, clusterId: ids.cluster, name: 'Colleagues', memberProfileIds: [ids.profile, ids.other], modelVersion: 'cluster-model-3', claimIds: [ids.claim] }],
  statuses: [{ schemaVersion: 1, sourceId: ids.source, updatedAt: at, state: 'complete' }],
};
const copy = value => structuredClone(value);

test('valid graph resolves every claim to exact passage, observation, hash, and model version', () => {
  assert.deepEqual(parseGraphSnapshot(graph), graph);
  assert.equal(graphSnapshotSchema.safeParse(graph).success, true);
  assert.equal(parseObservation(observation).sourceHash, sourceHash(content));
});

test('every derived entity names its own model and traces through claims to source evidence', () => {
  const byClaimId = new Map(graph.claims.map(item => [item.claimId, item]));
  for (const entity of [...graph.profiles, ...graph.relationships, ...graph.clusters]) {
    assert.ok(entity.modelVersion);
    for (const claimId of entity.claimIds) {
      const cited = byClaimId.get(claimId).provenance[0];
      assert.equal(cited.observationId, observation.observationId);
      assert.equal(cited.passageId, passage.passageId);
      assert.equal(cited.sourceHash, observation.sourceHash);
    }
  }
  for (const kind of ['profiles', 'relationships', 'clusters']) {
    const missing = copy(graph);
    delete missing[kind][0].modelVersion;
    assert.equal(graphSnapshotSchema.safeParse(missing).success, false, `${kind} missing model`);
    assert.throws(() => parseGraphSnapshot(missing));
    const empty = copy(graph);
    empty[kind][0].modelVersion = '';
    assert.equal(graphSnapshotSchema.safeParse(empty).success, false, `${kind} empty model`);
    assert.throws(() => parseGraphSnapshot(empty));
    const disconnected = copy(graph);
    disconnected[kind][0].claimIds = [ids.other];
    assert.throws(() => parseGraphSnapshot(disconnected), /[Cc]laim missing/);
  }
});

test('claim provenance rejects absent or mismatched passages and observations', () => {
  for (const change of [
    g => { g.claims[0].provenance[0].passageId = ids.other; },
    g => { g.claims[0].provenance[0].observationId = ids.other; },
    g => { g.claims[0].provenance[0].sourceHash = 'a'.repeat(64); },
    g => { g.passages[0].text = 'Different content'; },
    g => { g.observations[0].content = 'Changed content'; },
  ]) {
    const bad = copy(graph); change(bad);
    assert.throws(() => parseGraphSnapshot(bad));
  }
});

test('passage offsets must fit Unicode code points without slice clamping', () => {
  const codePointLength = Array.from(content).length;
  const unicode = copy(graph);
  unicode.passages[0] = { ...unicode.passages[0], start: codePointLength - 1, end: codePointLength, text: '🌍' };
  assert.deepEqual(parseGraphSnapshot(unicode), unicode);
  unicode.passages[0].end = codePointLength + 1;
  assert.throws(() => parseGraphSnapshot(unicode), /offset out of bounds/);
});

test('one source ID has one canonical kind, locator, and application identity', () => {
  const changedName = copy(graph);
  changedName.observations.push({ ...observation, observationId: ids.other, source: { ...source, displayName: 'Renamed window' } });
  assert.deepEqual(parseGraphSnapshot(changedName), changedName);
  for (const changedSource of [
    { ...source, kind: 'file' },
    { ...source, locator: 'app:example/window:2' },
    { ...source, applicationBundleId: 'dev.other.app' },
  ]) {
    const conflicting = copy(changedName);
    conflicting.observations[1].source = changedSource;
    assert.throws(() => parseGraphSnapshot(conflicting), /Conflicting source identity/);
  }
});

test('invalid graph edges and malformed schema fields fail', () => {
  for (const change of [
    g => { g.profiles[0].claimIds = [ids.other]; },
    g => { g.relationships[0].toProfileId = ids.cluster; },
    g => { g.clusters[0].memberProfileIds = [ids.cluster]; },
    g => { g.claims[0].provenance[0].modelVersion = ''; },
    g => { g.observations[0].secret = 'unsupported'; },
    g => { g.passages.push(copy(g.passages[0])); },
  ]) {
    const bad = copy(graph); change(bad);
    assert.throws(() => parseGraphSnapshot(bad));
  }
});

test('partial observations cite available content; deletion and revocation remove readable evidence', () => {
  const partial = copy(graph);
  partial.observations[0].state = 'partial'; partial.observations[0].partialReason = 'Capture budget reached';
  partial.statuses[0] = { ...partial.statuses[0], state: 'partial', reason: 'Capture budget reached' };
  assert.deepEqual(parseGraphSnapshot(partial), partial);
  assert.equal(observationSchema.safeParse({ ...observation, state: 'partial' }).success, false);
  for (const state of ['deleted', 'permissionRevoked']) {
    const terminal = {
      schemaVersion: 1, observationId: ids.observation, source, observedAt: at, state,
      ...(state === 'deleted' ? { targetObservationId: ids.other } : { reason: 'Permission withdrawn' }),
    };
    assert.equal(observationSchema.safeParse(terminal).success, true);
    assert.equal(observationSchema.safeParse({ ...terminal, content }).success, false);
    const retired = copy(graph);
    retired.observations = [terminal];
    retired.statuses = [{ schemaVersion: 1, sourceId: ids.source, updatedAt: at, state, ...(state === 'permissionRevoked' ? { reason: 'Permission withdrawn' } : {}) }];
    assert.throws(() => parseGraphSnapshot(retired), /Passage has no live observation/);
    retired.passages = []; retired.claims = []; retired.profiles = []; retired.relationships = []; retired.clusters = [];
    assert.deepEqual(parseGraphSnapshot(retired), retired);
    retired.observations.push({ ...observation, observationId: ids.other });
    assert.throws(() => parseGraphSnapshot(retired), /retains observation/);
    retired.observations.pop();
    retired.statuses[0] = { schemaVersion: 1, sourceId: ids.source, updatedAt: at, state: 'complete' };
    assert.throws(() => parseGraphSnapshot(retired), /Terminal status mismatch/);
  }
});

test('a deletion target cannot cross source ownership in a graph or query reply', () => {
  const tombstoneSource = { ...source, sourceId: ids.cluster, locator: 'app:example/window:2' };
  const tombstone = { schemaVersion: 1, observationId: ids.relationship, source: tombstoneSource,
    observedAt: at, state: 'deleted', targetObservationId: ids.observation };
  const crossSource = copy(graph);
  crossSource.observations.push(tombstone);
  crossSource.statuses.push({ schemaVersion: 1, sourceId: tombstoneSource.sourceId, updatedAt: at, state: 'deleted' });
  assert.throws(() => parseGraphSnapshot(crossSource), /Deletion target belongs to another source/);
  const decoded = decodeIpcRequest({ protocolVersion: 2, requestId: ids.request, operation: 'queryMemory', query: 'Alice' });
  const reply = { protocolVersion: 2, requestId: ids.request, operation: 'queryMemory', ok: true,
    result: { kind: 'memory', graph: crossSource } };
  assert.throws(() => parseIpcResponse(reply, decoded), /Deletion target belongs to another source/);

  // A missing target can be an erased observation. A present target may be a
  // terminal event from the same source, but readable data must stay erased.
  tombstone.targetObservationId = ids.other;
  crossSource.observations[1].targetObservationId = ids.other;
  assert.deepEqual(parseGraphSnapshot(crossSource), crossSource);
  const sameSource = copy(crossSource);
  sameSource.observations = [
    { ...tombstone, targetObservationId: ids.other },
    { ...tombstone, observationId: ids.other, targetObservationId: ids.passage },
  ];
  sameSource.passages = []; sameSource.claims = []; sameSource.profiles = [];
  sameSource.relationships = []; sameSource.clusters = [];
  sameSource.statuses = [crossSource.statuses[1]];
  assert.deepEqual(parseGraphSnapshot(sameSource), sameSource);
  sameSource.observations.push({ ...observation, source: tombstoneSource });
  assert.throws(() => parseGraphSnapshot(sameSource), /retains observation/);
});

test('IPC v1 query upgrades to v2; v2 cursor and strict version transition', () => {
  const v1 = { protocolVersion: 1, requestId: ids.request, operation: 'queryMemory', query: 'Alice', limit: 5 };
  assert.equal(ipcRequestV1Schema.safeParse(v1).success, true);
  assert.deepEqual(parseIpcRequest(v1), { ...v1, protocolVersion: 2 });
  assert.deepEqual(decodeIpcRequest(v1), { wireVersion: 1, request: { ...v1, protocolVersion: 2 } });
  assert.equal(ipcRequestV2Schema.safeParse({ ...v1, protocolVersion: 2, cursor: 'next' }).success, true);
  assert.equal(ipcRequestV1Schema.safeParse({ ...v1, cursor: 'next' }).success, false);
  assert.throws(() => parseIpcRequest({ ...v1, protocolVersion: 3 }));
  assert.throws(() => parseIpcRequest({ ...v1, limit: 0 }));
  assert.throws(() => parseIpcRequest({ ...v1, operation: 'deleteSource' }));
  assert.throws(() => parseIpcRequest({ ...v1, protocolVersion: 2, cursor: '' }), error =>
    error.issues?.some(issue => issue.path.join('.') === 'cursor' && issue.code === 'too_small'));
  assert.throws(() => parseIpcRequest({ protocolVersion: 2, requestId: ids.request, operation: 'submitObservation', payload: { ...observation, sourceHash: 'a'.repeat(64) } }), /hash mismatch/);
});

test('IPC submit accepts content states but terminal states require their own operations in both versions', () => {
  const partial = { ...observation, state: 'partial', partialReason: 'Capture budget reached' };
  const terminal = [
    { schemaVersion: 1, observationId: ids.observation, source, observedAt: at, state: 'deleted', targetObservationId: ids.other },
    { schemaVersion: 1, observationId: ids.observation, source, observedAt: at, state: 'permissionRevoked', reason: 'Permission withdrawn' },
  ];
  for (const version of [1, 2]) {
    const schema = version === 1 ? ipcRequestV1Schema : ipcRequestV2Schema;
    const request = { protocolVersion: version, requestId: ids.request, operation: 'submitObservation' };
    for (const payload of [observation, partial]) {
      assert.equal(schema.safeParse({ ...request, payload }).success, true);
      assert.equal(decodeIpcRequest({ ...request, payload }).request.payload.state, payload.state);
    }
    for (const payload of terminal) {
      assert.equal(observationSchema.safeParse(payload).success, true);
      assert.equal(schema.safeParse({ ...request, payload }).success, false);
      assert.throws(() => decodeIpcRequest({ ...request, payload }));
    }
    for (const operation of ['deleteSource', 'revokeSource']) {
      const dedicated = { protocolVersion: version, requestId: ids.request, operation, sourceId: ids.source };
      assert.equal(schema.safeParse(dedicated).success, true);
      assert.equal(decodeIpcRequest(dedicated).request.operation, operation);
    }
  }
});

test('IPC responses correlate operation, version, and semantic graph; errors are explicit', () => {
  const request = { protocolVersion: 1, requestId: ids.request, operation: 'queryMemory', query: 'Alice' };
  const decoded = decodeIpcRequest(request);
  const response = { protocolVersion: 1, requestId: ids.request, operation: 'queryMemory', ok: true, result: { kind: 'memory', graph } };
  assert.deepEqual(parseIpcResponse(response, decoded), response);
  assert.throws(() => parseIpcResponse(response, decoded.request), /decoded wire version/);
  assert.throws(() => parseIpcResponse(response, { wireVersion: 1, request: { ...decoded.request, cursor: 'next' } }));
  assert.throws(() => parseIpcResponse({ ...response, protocolVersion: 2 }, decoded));
  assert.throws(() => parseIpcResponse({ ...response, requestId: ids.other }, decoded), /correlation/);
  assert.throws(() => parseIpcResponse({ ...response, result: { kind: 'status', statuses: [] } }, decoded), /operation/);
  assert.throws(() => parseIpcResponse({ ...response, result: { ...response.result, nextCursor: 'next' } }, decoded));
  const error = { protocolVersion: 1, requestId: ids.request, operation: 'queryMemory', ok: false, error: { code: 'unauthorized', message: 'Local peer denied', retryable: false } };
  assert.deepEqual(parseIpcResponse(error, decoded), error);
  const v2 = decodeIpcRequest({ ...request, protocolVersion: 2, cursor: 'next' });
  assert.equal(parseIpcResponse({ ...response, protocolVersion: 2, result: { ...response.result, nextCursor: 'next' } }, v2).result.nextCursor, 'next');
  const mutation = { protocolVersion: 2, requestId: ids.request, operation: 'deleteSource', sourceId: ids.source };
  assert.throws(() => parseIpcResponse({ protocolVersion: 2, requestId: ids.request, operation: 'deleteSource', ok: true, result: { kind: 'sourceChanged', sourceId: ids.other, state: 'deleted' } }, decodeIpcRequest(mutation)), /identity/);
  const statusRequest = { protocolVersion: 2, requestId: ids.request, operation: 'getStatus' };
  const statusResponse = { ...statusRequest, ok: true, result: { kind: 'status', statuses: [
    { schemaVersion: 1, sourceId: ids.source, updatedAt: at, state: 'processing' },
    { schemaVersion: 1, sourceId: ids.source, updatedAt: at, state: 'permissionRevoked', reason: 'Permission withdrawn' },
  ] } };
  assert.throws(() => parseIpcResponse(statusResponse, decodeIpcRequest(statusRequest)), /Duplicate source status/);
});

test('portable JSON Schema artifacts retain version and object constraints', async () => {
  const ajv = new Ajv2020({ strict: true });
  addFormats(ajv);
  const response = version => ({ protocolVersion: version, requestId: ids.request, operation: 'queryMemory', ok: true,
    result: { kind: 'memory', graph } });
  const fixtures = {
    sourceIdentity: [source, { ...source, kind: 'unknown' }],
    observation: [observation, { ...observation, schemaVersion: 2 }],
    evidencePassage: [passage, { ...passage, start: -1 }],
    claim: [claim, { ...claim, provenance: [] }],
    profile: [graph.profiles[0], { ...graph.profiles[0], modelVersion: '' }],
    relationship: [graph.relationships[0], { ...graph.relationships[0], modelVersion: '' }],
    cluster: [graph.clusters[0], { ...graph.clusters[0], modelVersion: '' }],
    processingStatus: [graph.statuses[0], { ...graph.statuses[0], state: 'partial' }],
    graphSnapshot: [graph, { ...graph, unexpected: true }],
    ipcRequestV1: [{ protocolVersion: 1, requestId: ids.request, operation: 'getStatus' },
      { protocolVersion: 2, requestId: ids.request, operation: 'getStatus' }],
    ipcRequestV2: [{ protocolVersion: 2, requestId: ids.request, operation: 'queryMemory', query: 'Alice', cursor: 'next' },
      { protocolVersion: 2, requestId: ids.request, operation: 'deleteSource' }],
    ipcResponseV1: [response(1), response(2)],
    ipcResponseV2: [response(2), response(1)],
  };
  const names = Object.keys(jsonSchemas);
  assert.deepEqual(names.sort(), Object.keys(fixtures).sort());
  assert.deepEqual((await readdir(new URL('../dist/schemas/', import.meta.url))).sort(), names.map(name => `${name}.json`).sort());
  for (const name of names) {
    const schema = JSON.parse(await readFile(new URL(`../dist/schemas/${name}.json`, import.meta.url)));
    assert.equal(schema.$schema, 'https://json-schema.org/draft/2020-12/schema');
    assert.deepEqual(schema, jsonSchemas[name]);
    const validate = ajv.compile(schema);
    assert.equal(validate(fixtures[name][0]), true, `${name} valid: ${ajv.errorsText(validate.errors)}`);
    assert.equal(validate(fixtures[name][1]), false, `${name} invalid`);
    if (name === 'ipcRequestV1' || name === 'ipcRequestV2') {
      const version = name === 'ipcRequestV1' ? 1 : 2;
      const request = { protocolVersion: version, requestId: ids.request, operation: 'submitObservation' };
      assert.equal(validate({ ...request, payload: observation }), true);
      assert.equal(validate({ ...request, payload: { ...observation, state: 'partial', partialReason: 'Capture budget reached' } }), true);
      for (const payload of [
        { schemaVersion: 1, observationId: ids.observation, source, observedAt: at, state: 'deleted', targetObservationId: ids.other },
        { schemaVersion: 1, observationId: ids.observation, source, observedAt: at, state: 'permissionRevoked', reason: 'Permission withdrawn' },
      ]) assert.equal(validate({ ...request, payload }), false);
      for (const operation of ['deleteSource', 'revokeSource']) {
        assert.equal(validate({ protocolVersion: version, requestId: ids.request, operation, sourceId: ids.source }), true);
      }
    }
  }
});
