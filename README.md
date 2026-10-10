<div align="center">
  <h1>Subset</h1>
  <p><strong>The useful subset of everything.</strong></p>
 <p>Growing directory of focused apps: Use it yourself. Build it in. Give it to your agent.</p>
</div>
<div align="center">
  
<br />

[![Status: Alpha](https://img.shields.io/badge/status-alpha-orange.svg)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](/LICENSE)
[![Discord](https://img.shields.io/discord/831815510563749889?logo=discord&amp;logoColor=white)](https://discord.com/invite/9HJqKYTZKg)
[![YouTube](https://img.shields.io/youtube/channel/views/UCEE8Uvy4krxIGXAGy2q5wrA?style=flat&logo=youtube&logoColor=white&color=FF0000&label=@21nCo)](https://www.youtube.com/@21nCo)


</div>

---
Subset is a collection of small, independently useful apps. Each app solves one focused problem and can, where its platform allows, also serve as a capability inside 21n products or as an interface returned by an AI agent.

The first pilots are a **usage dashboard** and a **PDF annotation and review tool**. The local usage dashboard supports isolated Codex/ChatGPT connections, Claude Code and Antigravity CLI quota snapshots, Cursor team-member spending, and, with opt-in local sign-ins, live usage for Claude, personal Cursor, Factory Droid, Devin, Amp, and logins stored by Pi, OpenCode, omp, and Hermes. It runs as the `subset-usage` CLI (`@subset.dev/usage`, prepared for npm but not yet published); neither pilot is released. The directory labels availability accordingly.

## Product model

A Subset capability has a clear user outcome, its own data and operations, and one or more delivery surfaces:

| Surface | Example |
| --- | --- |
| Standalone web app | A usage dashboard opened from the Subset directory |
| Embedded web view | The same usage view inside Nucleum or Outright |
| Agent interface | A trusted, registered view shown beside a structured tool result |
| Agent CLI and skill | A shell-capable agent reads structured status or opens a local view through a published CLI |
| Native app or package | Clipboard history or system capture on macOS/iOS |

The directory at `subset.dev` should eventually show only the surfaces actually shipped for each capability. Web install, desktop download, native import, agent CLI/skill, and hosted agent view are separate release claims. A local browser view does not imply in-agent embedding.

## Repository

This is an npm workspaces monorepo:

```text
apps/
  directory/             Svelte and Tailwind directory scaffold
packages/
  catalog/               Typed catalog metadata shared with the directory
scripts/
  check-workspaces.mjs   Workspace and boundary validation
```

Future capability packages belong under `packages/<capability>/`; their standalone hosts belong under `apps/<app>/`. Native Swift packages and app targets may live under `native/` and are validated through Xcode rather than npm workspaces. The directory is a discovery and distribution surface, not the runtime owner of every capability.

The current `@subset/*` workspaces are private. Any package later published to npm uses the `@subset.dev/<name>` scope; app hosts remain private. No npm package is published from this scaffold.

## Development

Requires Node.js 22.13 or newer and npm 10.

```bash
npm ci
npm run dev
npm run check
npm run build
```

`npm run check` validates workspace ownership and runs the catalog and directory checks. `npm run build` builds packages before apps. The directory scaffold runs locally; this repository has no Cloudflare deployment configured yet.

## Architecture rules

See [AGENTS.md](AGENTS.md) for the architecture, reuse, security, validation, and release rules, and [docs/architecture.md](docs/architecture.md) for the current stack and delivery decisions. The main boundary is that a capability's data and operations cannot depend on its standalone app shell. Nucleum and Outright integrate through explicit adapters. System permissions stay in native hosts. Agent hosts render registered views from structured tool results rather than executing arbitrary model-generated UI code.

Before implementing auth, billing, storage, uploads, MCP, UI primitives, or observability, inspect the matching package in [`superfunctions-dev`](../superfunctions-dev) and reuse a compatible published package or supported interface where practical. Do not copy Superfunctions source into Subset. Record the choice and any gap in the capability's README.

## Current status

The monorepo and directory are an initial scaffold. The [usage package](packages/usage/README.md) and local standalone preview are under development, with no public or agent surface verified. No downloadable binaries are published, and `subset.dev` deployment has not been configured. [Minutes](packages/minutes/README.md), a meeting-recorder bot, runs as the `subset-minutes` CLI (`@subset.dev/minutes`, prepared for npm but not published) and as a [macOS app](native/minutes/README.md) that runs the same CLI; neither has joined a live meeting in verification. A local [M Graph macOS capture spike](native/mgraph/README.md) tests Accessibility collection and development packaging without adding a catalog availability claim. Pilot requirements and delivery plans are tracked in [SET-1: usage dashboard](https://linear.app/21n/issue/SET-1/pilot-a-reusable-usage-status-dashboard) and [SET-2: PDF annotation and review](https://linear.app/21n/issue/SET-2/pilot-reusable-pdf-annotation-and-agent-review).

## License

[MIT](LICENSE)
