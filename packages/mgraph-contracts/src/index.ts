import { createHash } from 'node:crypto';
import { z } from 'zod';

// Version 1 is the persisted domain shape. IPC version 2 adds cursor pagination
// while retaining a version 1 read path for clients that have not upgraded.
export const SCHEMA_VERSION = 1 as const;
export const IPC_VERSION = 2 as const;

const id = z.uuid();
const timestamp = z.iso.datetime({ offset: true });
const text = z.string().min(1).max(100_000);
const label = z.string().min(1).max(512);
const hash = z.string().regex(/^[a-f0-9]{64}$/);
const modelVersion = z.string().min(1).max(128);

export const sourceIdentitySchema = z.strictObject({
  sourceId: id,
  kind: z.enum(['accessibility', 'file', 'manual', 'provider']),
  locator: label,
  displayName: label.optional(),
  applicationBundleId: label.optional(),
});

const observationBase = {
  schemaVersion: z.literal(1),
  observationId: id,
  source: sourceIdentitySchema,
  observedAt: timestamp,
};
export const observationSchema = z.discriminatedUnion('state', [
  z.strictObject({ ...observationBase, state: z.literal('complete'), content: text, sourceHash: hash }),
  z.strictObject({ ...observationBase, state: z.literal('partial'), content: text, sourceHash: hash, partialReason: label }),
  z.strictObject({ ...observationBase, state: z.literal('deleted'), targetObservationId: id }),
  z.strictObject({ ...observationBase, state: z.literal('permissionRevoked'), reason: label }),
]);
export type Observation = z.infer<typeof observationSchema>;

export const evidencePassageSchema = z.strictObject({
  schemaVersion: z.literal(1),
  passageId: id,
  observationId: id,
  sourceHash: hash,
  // Unicode code point offsets into the observation content, end exclusive.
  start: z.number().int().nonnegative(),
  end: z.number().int().positive(),
  text,
}).refine(p => p.end > p.start, { message: 'end must exceed start' });

export const claimSchema = z.strictObject({
  schemaVersion: z.literal(1),
  claimId: id,
  statement: text,
  provenance: z.array(z.strictObject({
    observationId: id,
    passageId: id,
    sourceHash: hash,
    modelVersion,
  })).min(1),
});

export const profileSchema = z.strictObject({
  schemaVersion: z.literal(1),
  profileId: id,
  name: label,
  modelVersion,
  claimIds: z.array(id).min(1),
});
export const relationshipSchema = z.strictObject({
  schemaVersion: z.literal(1),
  relationshipId: id,
  fromProfileId: id,
  toProfileId: id,
  kind: label,
  modelVersion,
  claimIds: z.array(id).min(1),
});
export const clusterSchema = z.strictObject({
  schemaVersion: z.literal(1),
  clusterId: id,
  name: label,
  memberProfileIds: z.array(id).min(1),
  modelVersion,
  claimIds: z.array(id).min(1),
});

const statusBase = { schemaVersion: z.literal(1), sourceId: id, updatedAt: timestamp };
export const processingStatusSchema = z.discriminatedUnion('state', [
  z.strictObject({ ...statusBase, state: z.literal('pending') }),
  z.strictObject({ ...statusBase, state: z.literal('processing') }),
  z.strictObject({ ...statusBase, state: z.literal('complete') }),
  z.strictObject({ ...statusBase, state: z.literal('deleted') }),
  z.strictObject({ ...statusBase, state: z.literal('partial'), reason: label }),
  z.strictObject({ ...statusBase, state: z.literal('failed'), reason: label }),
  z.strictObject({ ...statusBase, state: z.literal('permissionRevoked'), reason: label }),
]);

export const graphSnapshotSchema = z.strictObject({
  schemaVersion: z.literal(1),
  observations: z.array(observationSchema),
  passages: z.array(evidencePassageSchema),
  claims: z.array(claimSchema),
  profiles: z.array(profileSchema),
  relationships: z.array(relationshipSchema),
  clusters: z.array(clusterSchema),
  statuses: z.array(processingStatusSchema),
});
export type GraphSnapshot = z.infer<typeof graphSnapshotSchema>;

export function sourceHash(content: string): string {
  return createHash('sha256').update(content, 'utf8').digest('hex');
}

export function parseObservation(input: unknown): Observation {
  const observation = observationSchema.parse(input);
  if ((observation.state === 'complete' || observation.state === 'partial') && sourceHash(observation.content) !== observation.sourceHash) {
    throw new Error(`Observation hash mismatch: ${observation.observationId}`);
  }
  return observation;
}

function unique<T>(items: T[], key: (item: T) => string, kind: string): Map<string, T> {
  const result = new Map<string, T>();
  for (const item of items) {
    const value = key(item);
    if (result.has(value)) throw new Error(`Duplicate ${kind}: ${value}`);
    result.set(value, item);
  }
  return result;
}

function uniqueSourceStatuses(statuses: GraphSnapshot['statuses']): void {
  unique(statuses, status => status.sourceId, 'source status');
}

function consistentSourceIdentities(observations: GraphSnapshot['observations']): void {
  const sources = new Map<string, Observation['source']>();
  for (const { source } of observations) {
    const previous = sources.get(source.sourceId);
    // displayName is presentation metadata; the other fields identify the source.
    if (previous && (previous.kind !== source.kind || previous.locator !== source.locator || previous.applicationBundleId !== source.applicationBundleId)) {
      throw new Error(`Conflicting source identity: ${source.sourceId}`);
    }
    sources.set(source.sourceId, source);
  }
}

// JSON Schema validates each payload's shape. This function also checks the
// graph's referential and lifecycle invariants, which JSON Schema cannot express.
export function parseGraphSnapshot(input: unknown): GraphSnapshot {
  const graph = graphSnapshotSchema.parse(input);
  const observations = unique(graph.observations, x => x.observationId, 'observation');
  const passages = unique(graph.passages, x => x.passageId, 'passage');
  const claims = unique(graph.claims, x => x.claimId, 'claim');
  const profiles = unique(graph.profiles, x => x.profileId, 'profile');
  unique(graph.relationships, x => x.relationshipId, 'relationship');
  unique(graph.clusters, x => x.clusterId, 'cluster');
  uniqueSourceStatuses(graph.statuses);
  consistentSourceIdentities(graph.observations);
  const retired = new Set<string>();
  for (const observation of graph.observations) {
    if (observation.state === 'deleted' || observation.state === 'permissionRevoked') retired.add(observation.source.sourceId);
    else parseObservation(observation);
  }
  for (const status of graph.statuses) if (status.state === 'deleted' || status.state === 'permissionRevoked') retired.add(status.sourceId);
  for (const observation of graph.observations) {
    if (observation.state !== 'deleted' && observation.state !== 'permissionRevoked') continue;
    const status = graph.statuses.find(item => item.sourceId === observation.source.sourceId);
    if (status && status.state !== observation.state) throw new Error(`Terminal status mismatch: ${observation.source.sourceId}`);
  }
  for (const passage of graph.passages) {
    const observation = observations.get(passage.observationId);
    if (!observation || observation.state === 'deleted' || observation.state === 'permissionRevoked') throw new Error(`Passage has no live observation: ${passage.passageId}`);
    if (retired.has(observation.source.sourceId)) throw new Error(`Passage cites retired source: ${passage.passageId}`);
    const codePoints = Array.from(observation.content);
    if (passage.end > codePoints.length) throw new Error(`Passage offset out of bounds: ${passage.passageId}`);
    const slice = codePoints.slice(passage.start, passage.end).join('');
    if (slice !== passage.text || passage.sourceHash !== observation.sourceHash) throw new Error(`Passage mismatch: ${passage.passageId}`);
  }
  for (const claim of graph.claims) for (const citation of claim.provenance) {
    const passage = passages.get(citation.passageId);
    if (!passage || passage.observationId !== citation.observationId || passage.sourceHash !== citation.sourceHash) {
      throw new Error(`Claim provenance mismatch: ${claim.claimId}`);
    }
  }
  for (const profile of graph.profiles) for (const claimId of profile.claimIds) if (!claims.has(claimId)) throw new Error(`Profile claim missing: ${claimId}`);
  for (const relation of graph.relationships) {
    if (!profiles.has(relation.fromProfileId) || !profiles.has(relation.toProfileId)) throw new Error(`Relationship profile missing: ${relation.relationshipId}`);
    for (const claimId of relation.claimIds) if (!claims.has(claimId)) throw new Error(`Relationship claim missing: ${claimId}`);
  }
  for (const cluster of graph.clusters) {
    for (const profileId of cluster.memberProfileIds) if (!profiles.has(profileId)) throw new Error(`Cluster profile missing: ${profileId}`);
    for (const claimId of cluster.claimIds) if (!claims.has(claimId)) throw new Error(`Cluster claim missing: ${claimId}`);
  }
  for (const observation of graph.observations) {
    if (retired.has(observation.source.sourceId) && observation.state !== 'deleted' && observation.state !== 'permissionRevoked') {
      // A snapshot may include the terminal event but must not include retained content.
      throw new Error(`Retired source retains observation: ${observation.source.sourceId}`);
    }
  }
  return graph;
}

const requestBase = { requestId: id };
const requestOperations = [
  z.strictObject({ ...requestBase, operation: z.literal('submitObservation'), payload: observationSchema }),
  z.strictObject({ ...requestBase, operation: z.literal('queryMemory'), query: label, limit: z.number().int().min(1).max(100).optional() }),
  z.strictObject({ ...requestBase, operation: z.literal('getStatus'), sourceId: id.optional() }),
  z.strictObject({ ...requestBase, operation: z.literal('deleteSource'), sourceId: id }),
  z.strictObject({ ...requestBase, operation: z.literal('revokeSource'), sourceId: id }),
] as const;
// V1 had the same operations but no cursor. V2 adds a cursor only to queries.
export const ipcRequestV1Schema = z.discriminatedUnion('operation', [
  requestOperations[0].extend({ protocolVersion: z.literal(1) }),
  requestOperations[1].extend({ protocolVersion: z.literal(1) }),
  requestOperations[2].extend({ protocolVersion: z.literal(1) }),
  requestOperations[3].extend({ protocolVersion: z.literal(1) }),
  requestOperations[4].extend({ protocolVersion: z.literal(1) }),
]);
export const ipcRequestV2Schema = z.discriminatedUnion('operation', [
  requestOperations[0].extend({ protocolVersion: z.literal(2) }),
  requestOperations[1].extend({ protocolVersion: z.literal(2), cursor: label.optional() }),
  requestOperations[2].extend({ protocolVersion: z.literal(2) }),
  requestOperations[3].extend({ protocolVersion: z.literal(2) }),
  requestOperations[4].extend({ protocolVersion: z.literal(2) }),
]);
export type IpcRequestV2 = z.infer<typeof ipcRequestV2Schema>;
export type DecodedIpcRequest = { wireVersion: 1 | 2; request: IpcRequestV2 };
export function decodeIpcRequest(input: unknown): DecodedIpcRequest {
  if (input && typeof input === 'object' && 'protocolVersion' in input && input.protocolVersion === 1) {
    const v1 = ipcRequestV1Schema.parse(input);
    if (v1.operation === 'submitObservation') parseObservation(v1.payload);
    return { wireVersion: 1, request: ipcRequestV2Schema.parse({ ...v1, protocolVersion: 2 }) };
  }
  const v2 = ipcRequestV2Schema.parse(input);
  if (v2.operation === 'submitObservation') parseObservation(v2.payload);
  return { wireVersion: 2, request: v2 };
}
export function parseIpcRequest(input: unknown): IpcRequestV2 {
  return decodeIpcRequest(input).request;
}

const responseBase = { requestId: id, operation: z.enum(['submitObservation', 'queryMemory', 'getStatus', 'deleteSource', 'revokeSource']) };
const response = (version: 1 | 2) => z.discriminatedUnion('ok', [
  z.strictObject({ ...responseBase, protocolVersion: z.literal(version), ok: z.literal(false), error: z.strictObject({
    code: z.enum(['invalidRequest', 'unauthorized', 'conflict', 'unavailable', 'internal']),
    message: label,
    retryable: z.boolean(),
  }) }),
  z.strictObject({ ...responseBase, protocolVersion: z.literal(version), ok: z.literal(true), result: z.union([
    z.strictObject({ kind: z.literal('observationAccepted'), observationId: id }),
    z.strictObject({ kind: z.literal('memory'), graph: graphSnapshotSchema, ...(version === 2 ? { nextCursor: label.optional() } : {}) }),
    z.strictObject({ kind: z.literal('status'), statuses: z.array(processingStatusSchema) }),
    z.strictObject({ kind: z.literal('sourceChanged'), sourceId: id, state: z.enum(['deleted', 'permissionRevoked']) }),
  ]) }),
]);
export const ipcResponseV1Schema = response(1);
export const ipcResponseV2Schema = response(2);

export function parseIpcResponse(input: unknown, decoded: DecodedIpcRequest) {
  if (decoded?.wireVersion !== 1 && decoded?.wireVersion !== 2) throw new Error('Response correlation requires the decoded wire version');
  const { request } = decoded;
  const wireRequest = { ...request, protocolVersion: decoded.wireVersion };
  (decoded.wireVersion === 1 ? ipcRequestV1Schema : ipcRequestV2Schema).parse(wireRequest);
  const parsed = (decoded.wireVersion === 1 ? ipcResponseV1Schema : ipcResponseV2Schema).parse(input);
  if (parsed.requestId !== request.requestId || parsed.operation !== request.operation) throw new Error('Response correlation mismatch');
  if (parsed.ok) {
    const kindByOperation = { submitObservation: 'observationAccepted', queryMemory: 'memory', getStatus: 'status', deleteSource: 'sourceChanged', revokeSource: 'sourceChanged' };
    if (parsed.result.kind !== kindByOperation[request.operation]) throw new Error('Response result does not match operation');
    if (parsed.result.kind === 'memory') parseGraphSnapshot(parsed.result.graph);
    if (parsed.result.kind === 'sourceChanged' && parsed.result.state !== (request.operation === 'deleteSource' ? 'deleted' : 'permissionRevoked')) throw new Error('Source state does not match operation');
    if (parsed.result.kind === 'sourceChanged' && 'sourceId' in request && request.sourceId && parsed.result.sourceId !== request.sourceId) throw new Error('Source identity does not match request');
    if (parsed.result.kind === 'observationAccepted' && 'payload' in request && parsed.result.observationId !== request.payload.observationId) throw new Error('Observation identity does not match request');
    if (parsed.result.kind === 'status') {
      uniqueSourceStatuses(parsed.result.statuses);
      if ('sourceId' in request && request.sourceId && parsed.result.statuses.some(item => item.sourceId !== request.sourceId)) throw new Error('Status source does not match request');
    }
  }
  return parsed;
}

export const jsonSchemas = {
  sourceIdentity: z.toJSONSchema(sourceIdentitySchema),
  observation: z.toJSONSchema(observationSchema),
  evidencePassage: z.toJSONSchema(evidencePassageSchema),
  claim: z.toJSONSchema(claimSchema),
  profile: z.toJSONSchema(profileSchema),
  relationship: z.toJSONSchema(relationshipSchema),
  cluster: z.toJSONSchema(clusterSchema),
  processingStatus: z.toJSONSchema(processingStatusSchema),
  graphSnapshot: z.toJSONSchema(graphSnapshotSchema),
  ipcRequestV1: z.toJSONSchema(ipcRequestV1Schema),
  ipcRequestV2: z.toJSONSchema(ipcRequestV2Schema),
  ipcResponseV1: z.toJSONSchema(ipcResponseV1Schema),
  ipcResponseV2: z.toJSONSchema(ipcResponseV2Schema),
};
