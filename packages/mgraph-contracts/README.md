# M Graph contracts (SET-5)

This private `@subset/mgraph-contracts` workspace defines the local memory service's data and IPC boundary. Its consumers are a future collector adapter, local store, and memory query client. It does not collect Accessibility data, persist records, serve IPC, render a UI, or connect to a hosted service. The SET-4 native spike still emits its own `CaptureResult`; a later adapter must convert successful captures into this contract and must not treat failed captures as text.

## Versions and exported validation

- Domain records carry `schemaVersion: 1`. IPC envelopes carry `protocolVersion: 1` or `2`. The current protocol is 2.
- `observationSchema`, `evidencePassageSchema`, `claimSchema`, `profileSchema`, `relationshipSchema`, `clusterSchema`, `processingStatusSchema`, `graphSnapshotSchema`, and the IPC request/response schemas validate individual shapes. All objects are closed to unknown fields.
- `parseObservation`, `parseGraphSnapshot`, `decodeIpcRequest`, and `parseIpcResponse` enforce additional semantic rules. Use these at trust boundaries. Build output includes draft 2020-12 JSON Schemas under `dist/schemas/` for non-TypeScript consumers. JSON Schema alone cannot verify hashes, graph references, passage offsets, retired-source purging, or response correlation.
- `decodeIpcRequest` returns `{ wireVersion, request }`. A v1 request is normalized to the v2 in-process shape while retaining `wireVersion: 1` for the reply. Pass the entire decoded value to `parseIpcResponse(response, decoded)` so reply validation uses the original wire version. The normalized `request` alone is not a response correlation value. Version 2 adds an optional `cursor` to `queryMemory`; v1 rejects it. Servers must encode a response using the caller's wire version. Unknown versions and fields are rejected.

## Record rules

`SourceIdentity.sourceId` is a stable local identity for one logical source. Its `kind`, `locator`, and optional `applicationBundleId` must remain consistent across observations in one graph snapshot; `displayName` may change. A changed canonical identity needs a new `sourceId`. `locator` identifies the source within its kind; both it and `displayName` may contain private information and belong only in local storage or authorized responses. An observation is an immutable snapshot with a unique `observationId`, source identity, and time. `complete` and `partial` carry nonempty `content` plus `sourceHash`, the lowercase SHA-256 of the exact UTF-8 content. `partial` also requires `partialReason`. `deleted` carries a target observation ID, and `permissionRevoked` carries a reason. Neither terminal state accepts content or hash. A new observation is needed after any content change.

Passages cite a live observation, repeat its hash, and contain an exact excerpt located by Unicode code point offsets `[start, end)` in the observation content. A claim has at least one provenance entry with an observation ID, passage ID, source hash, and claim model version. Every entry must resolve to the matching passage and observation. Profiles, relationships, and clusters each carry their own derivation `modelVersion` and refer to existing claims; those claim links trace each entity to source hashes, passages, and observations. Relationships and clusters also refer to existing profiles. A graph snapshot cannot retain readable observations, passages, or claims for a source marked deleted or permission revoked. A terminal status may coexist with its terminal observation. The local store must erase other retained representations and derived indexes as part of those operations; this package only rejects a leaked graph snapshot.

Processing states are `pending`, `processing`, `complete`, `partial`, `failed`, `deleted`, and `permissionRevoked`. `partial`, `failed`, and `permissionRevoked` require a reason. A status is per source and has an update time. Graph snapshots and `getStatus` responses contain at most one current status per source. The schema does not infer a status from an observation, and a pending source need not yet have an observation. The store owns durable ordering and recovery after interruption.

## Local IPC

| Operation | Kind | Input | Result |
| --- | --- | --- | --- |
| `submitObservation` | write | Observation | Accepted observation ID |
| `queryMemory` | read | Query, optional 1–100 limit and v2 cursor | Provenance-checked graph, optional v2 next cursor |
| `getStatus` | read | Optional source ID | Source statuses |
| `deleteSource` | write | Source ID | Deleted source ID/state |
| `revokeSource` | write | Source ID | Permission-revoked source ID/state |

Every request has a UUID `requestId`; responses echo the ID, operation, and wire version. Errors have a code, message, and `retryable` flag. `parseIpcResponse` requires the full value returned by `decodeIpcRequest`, checks its `wireVersion` and expected operation, and checks source and observation identities when supplied. A server should deduplicate retried writes by request ID and persist the result atomically with the mutation. The wire framing, local peer authorization, socket permissions, maximum frame size, pagination implementation, shutdown behavior, and durable retry policy belong to the service in SET-6 or later. A request ID is a correlation and retry key, not an authorization token. The IPC payload must not carry credentials. An unauthorized write must return `unauthorized`; clients must not infer that `retryable: true` makes an unauthorized operation safe to repeat without a new grant.

For a future Unix socket transport, use one UTF-8 JSON value per frame with an explicit byte limit, reject oversized or malformed frames before dispatch, and authenticate the local peer before any read or write. Each write needs its own host authorization decision. Swift clients can validate the generated JSON Schema and must implement the documented semantic checks, including SHA-256 and Unicode code point passage ranges. No platform-specific capture result is accepted directly as an IPC observation.

## Risk and evidence

| Boundary | Failure mode | Focused evidence |
| --- | --- | --- |
| Observation and passage | Changed content, incorrect hash or out-of-bounds Unicode offset, malformed state | Valid/invalid schema and hash/excerpt tests |
| Derived graph | Dangling claim, wrong source, missing entity model version, invalid profile/relation/cluster edge | Full graph, generated schema, and broken-reference tests |
| Lifecycle | Partial record lacks reason; deleted/revoked source leaks text; duplicate current status | State, retirement, and status-response tests |
| IPC | Wrong operation, response ID, or wire version; v2 diagnostic masked; unsafe retry assumption | Full v1 request/reply and v2 cursor round trips, malformed request diagnostic, response-correlation tests; retry/authorization policy documented |
| Portability | Generated schema differs from runtime shape | Ajv validates representative generated JSON Schema artifacts |

Run `npm run test --workspace=@subset/mgraph-contracts`. Repository gates are `npm run check` and `npm run build`. Tests prove the contract implementation and generated artifacts, not persistence, native permissions, live IPC, or hosted behavior. For this issue, Railway Postgres, Cloudflare Preview, connected provider sandboxes, and Aside Browser have no runtime boundary to exercise; the final reviewer can verify the schema/provenance contract with the generated artifacts and focused tests.

## Superfunctions reuse check

The prescribed `/Users/serro/Documents/dev/n/superfunctions-dev` checkout is absent on this host, so current `mcpfn`, `apifn`, and `datafn` implementation, manifest, and documentation could not be inspected. They are candidates for a later MCP adapter, API client, or synced store, not for this local data and IPC shape. Used Superfunctions package/version: none. Runtime structural validation uses published `zod` 4.6.5; `ajv` 8.20.0 and `ajv-formats` 3.0.1 validate generated schemas in tests. No Superfunctions source or checkout path is copied or used as a runtime dependency.
