# Subset architecture and delivery direction

This document records the current stack and the decisions still needed for the two proposed pilots. [AGENTS.md](../AGENTS.md) defines the repository rules. The usage pilot has a local implementation in progress; no public delivery surface is available.

## Current stack and ownership

| Layer | Current choice | Status and boundary |
| --- | --- | --- |
| Workspace | npm workspaces, TypeScript, Node.js 20.19+ | Implemented scaffold. `packages/*` own reusable contracts and logic; `apps/*` own hosts. |
| Directory | Svelte 5, Vite, Tailwind CSS 4 | Implemented local static preview. `@subset/catalog` owns metadata; the directory does not own capability data or credentials. |
| Web delivery | Static assets first; Cloudflare intended | No deployment configured. Add Workers or storage only for a concrete capability need and after a Superfunctions reuse check. |
| Reusable capability | `packages/<capability>/` | Planned. Domain operations, source adapters, typed inputs/outputs, and web view contracts belong here; a host wires auth, persistence, routes, and telemetry. |
| Native delivery | Swift and platform APIs when required | Planned. Native permissions and views stay in native targets; share a stable data/operation contract where useful. |
| Agent delivery | Structured result, optional registered view; separate local CLI/skill | Planned. Each host and the published CLI/skill require their own verification. |

The usage dashboard boundary is normalized per-source status and explicit read operations. Its sources are ChatGPT-signed-in Codex homes through the documented local app-server protocol, independently collected Claude Code/Antigravity CLI quota snapshots, authorized Cursor team-member spending through its official Admin API, and, only with the opt-in local sign-ins setting (see AGENTS.md), the stored sign-ins of Claude Code, Factory Droid, the Cursor app (personal plan usage), Devin, Pi, OpenCode, omp, and Hermes. Quota snapshots and spending caps remain distinct; API billing is not an implemented quota source. The local host runtime ships as the `@sub-set/usage` CLI (`packages/usage-cli`), which bundles `@subset/usage` and the built `apps/usage` view; a tag `usage-v<version>` runs `.github/workflows/publish-tag.yml`. The standalone host owns profile persistence and collector bindings, while the package owns normalization and source reads. Proposed consumers are a standalone web host, an Outright adapter, a local CLI and skill for shell-capable agents, and a registered view in an agent host. The PDF review boundary is document identity, page/annotation operations, and explicit export; web, native, product, and agent views may differ. No capability may import an app or a consuming product.

## Decisions and gates

1. Keep the directory a static build. Choose Cloudflare service, data residency, auth, cost, and rollback only when a pilot requires server-side work. No deployment is implied by this plan.
2. Inspect current `superfunctions-dev` implementation, manifest, and docs before selecting authfn, billfn, datafn, filefn, mcpfn, plugfn, apifn, uifn, or observability. Record the package/version used and gaps in each capability README. No Superfunctions dependency has been selected for a pilot yet.
3. For usage, Codex uses one `CODEX_HOME` per sign-in with manual live reads. Claude Code and Antigravity use allowlisted status-line snapshots with explicit per-account collector bindings, and a Claude account can be bound to its own `CLAUDE_CONFIG_DIR`; refresh does not advance snapshot observation times or query those providers. Cursor team profiles select an exact member ID and reference a server environment credential, never a browser token. The host provides account operations and keeps credentials out of rendered status. Live multi-account sign-ins, installed CLI compatibility, Cursor authorization, and external host behavior still need verification before any availability claim. See [the usage README](../packages/usage/README.md) and [SET-1 and its linked planning documents](https://linear.app/21n/issue/SET-1/pilot-a-reusable-usage-status-dashboard).
4. For PDF review, compare browser and SwiftUI/PDFKit behavior against the existing POC, then choose the first standalone surface based on annotation fidelity, file access, export, and permissions. Do not transfer POC code without an audit.
5. Keep catalog `availableSurfaces` empty until the actual artifact and route pass release checks. A published CLI/skill and a hosted agent view are separate claims. A localhost browser page is not an embedded agent view.

The CI scaffold runs workspace checks and builds. Capability tests, browser behavior, provider data, native permissions, external host integration, Cloudflare deployment, and release artifacts need their own checks when those surfaces exist.
