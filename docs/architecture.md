# Subset architecture and delivery direction

This document records the current stack and the decisions still needed for the two proposed pilots. [AGENTS.md](../AGENTS.md) defines the repository rules. Neither pilot nor any public delivery surface is implemented yet.

## Current stack and ownership

| Layer | Current choice | Status and boundary |
| --- | --- | --- |
| Workspace | npm workspaces, TypeScript, Node.js 22.13+ | Implemented scaffold. `packages/*` own reusable contracts and logic; `apps/*` own hosts. |
| Directory | Svelte 5, Vite, Tailwind CSS 4 | Implemented local static preview. `@subset/catalog` owns metadata; the directory does not own capability data or credentials. |
| Web delivery | Static assets first; Cloudflare intended | No deployment configured. Add Workers or storage only for a concrete capability need and after a Superfunctions reuse check. |
| Reusable capability | `packages/<capability>/` | Private `@subset/mgraph-contracts` defines versioned M Graph data and IPC schemas. Private `@subset/mgraph-store` owns local SQLite observations, evidence, search, and the restart-safe processing queue. The SET-7 service host, source adapters, and views remain planned; a host wires auth, permissions, routing, and telemetry. |
| Native delivery | Swift and platform APIs when required | Planned. Native permissions and views stay in native targets; share a stable data/operation contract where useful. |
| Agent delivery | Structured result, optional registered view; separate local CLI/skill | Planned. Each host and the published CLI/skill require their own verification. |

The usage dashboard boundary is normalized per-source status and explicit read operations. Proposed consumers are a standalone web host, an Outright adapter, a local CLI and skill for shell-capable agents, and a registered view in an agent host. The PDF review boundary is document identity, page/annotation operations, and explicit export; web, native, product, and agent views may differ. No capability may import an app or a consuming product.

## Decisions and gates

1. Keep the directory a static build. Choose Cloudflare service, data residency, auth, cost, and rollback only when a pilot requires server-side work. No deployment is implied by this plan.
2. Inspect current `superfunctions-dev` implementation, manifest, and docs before selecting authfn, billfn, datafn, filefn, mcpfn, plugfn, apifn, uifn, or observability. Record the package/version used and gaps in each capability README. No Superfunctions dependency has been selected for a pilot yet.
3. For usage, select the first provider only after verifying an authorized, reliable source, refresh behavior, account identity, and permitted credential path. Browser-only code cannot inspect installed agent state. See [SET-1 and its linked planning documents](https://linear.app/21n/issue/SET-1/pilot-a-reusable-usage-status-dashboard).
4. For PDF review, compare browser and SwiftUI/PDFKit behavior against the existing POC, then choose the first standalone surface based on annotation fidelity, file access, export, and permissions. Do not transfer POC code without an audit.
5. Keep catalog `availableSurfaces` empty until the actual artifact and route pass release checks. A published CLI/skill and a hosted agent view are separate claims. A localhost browser page is not an embedded agent view.

The CI scaffold runs workspace checks and builds. M Graph contract and local store tests run through `npm run check`; they cover schema validation, provenance, IPC v1/v2 compatibility, SQLite migrations, writer ownership, queue replay, revision fencing, search, and source retirement. Browser behavior, provider data, native permissions, external host integration, Cloudflare deployment, and release artifacts need their own checks when those surfaces exist.
