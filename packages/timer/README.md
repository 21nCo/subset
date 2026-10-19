# Timer capability (SET-74)

This private package owns Timer's domain: timer definitions and presets, a pure state machine computed from timestamps, explicit operations with JSON Schemas, and the versioned agent result with the registered view ID `subset.timer.board@1`. It has no process, file I/O, UI, or network code. The later hosts (the per-user daemon, the `subset-timer` CLI, the MCP server, the web view and the macOS app, SET-75 to SET-82) use this contract; none of them exists yet, and no Timer surface is available.

## Capability boundary

- **Owns:** the model (schema version 1), the engine (`project`, `transitionsBetween`, `settle`), the operations, the built-in presets, the agent result and its text fallback, the JSON Schemas, and the contract fixtures.
- **Hosts own:** storage (the daemon is the single writer), id-addressed routing, authorization of write classes, alerts and sound, scheduling, and any transport. A host passes the store, the untrusted input and `now`; it persists the returned store.
- **Excluded:** storage, the daemon, any CLI, views, MCP, alerts and Swift.

Every time is wall-clock epoch milliseconds. A timer stores when its current running stretch began (`startedAt`), the running time before that (`accumulatedMs`) and the time skipped (`skippedMs`), so every surface computes the position as `accumulatedMs + skippedMs + (now - startedAt)` after sleep, wake or a restart. When the clock goes backward, the running stretch adds nothing instead of going negative.

## Model

| Kind | Fields |
| --- | --- |
| `countdown` | Exactly one of `durationMs` (1 s to 24 h) or `until` (an ISO time with an offset, 1 s to 24 h ahead). The first start fixes `until` to `durationMs`, so a reset timer runs the same length again. Optional `lapsEnabled`. |
| `stopwatch` | Laps. No end. |
| `interval` | `segments` (1 to 100) of `{ label (≤ 40), phase: prep \| work \| rest \| cooldown, durationMs (1 s to 24 h) }`, `rounds` (1 to 99), optional `prepMs` before the first round and `cooldownMs` after the last. |

Common fields: `id` (`t_` plus 8 lowercase Crockford base32 characters), `name` (1 to 60 characters, default per kind), `sound` (default true), `countdownTicks` (default true for interval timers only) and `createdAt`. Names and labels are one line of printable text, counted in Unicode code points. Names need not be unique; operations address timers by id. Ids are derived deterministically from `now` and checked for uniqueness in the store; they are not secrets.

The runtime is `idle | running | paused | finished` with `startedAt`, `accumulatedMs`, `pausedAt`, `laps[]` (`{ elapsedMs, at }`, at most 999) and `skippedMs`. The store is `{ schemaVersion: 1, timers[], presets[] }`, where `presets` holds only saved presets. Validate a persisted store with `parseStore`.

## Engine

- `project(timer, now)` returns the status at `now` (a running timer past its end is `finished`), the elapsed, remaining and total time, the current interval step (index, segment index, round, phase, label, time elapsed and left in it), and the next step.
- `transitionsBetween(timer, from, to)` lists, for a running timer, the interval step starts, final-3-second ticks (when `countdownTicks` is on) and the finish with `from < at <= to`, so a scheduler arms one timeout and asks again after each change.
- `settle(timer, now)` records a running timer whose time is up as finished.

## Operations

Each is a pure function `(store, input, now)` that validates its input and returns `{ ok: true, store, result }` or `{ ok: false, error: { code, message, issues? } }`. It never mutates the store it was given. `runOperation(name, …)` dispatches by name.

| Operation | Class | Input | Result | Errors |
| --- | --- | --- | --- | --- |
| `create` | write | `{ timer }` or `{ preset }`, optional `name` | `{ timer }` | `invalid_input`, `not_found` (preset), `limit_reached` |
| `start` | write | `{ id }` to start an idle timer, or a `create` input to create and start | `{ timer }` | as `create`, plus `invalid_state` (not idle, or an `until` that has passed) |
| `pause` | write | `{ id }` | `{ timer }` | `not_found`, `invalid_state` (not running) |
| `resume` | write | `{ id }` | `{ timer }` | `not_found`, `invalid_state` (not paused) |
| `lap` | write | `{ id }` | `{ timer }` | `not_found`, `invalid_state` (not a stopwatch or lap-enabled countdown, or not running), `limit_reached` |
| `skip` | write | `{ id }` | `{ timer }` | `not_found`, `invalid_state` (not an interval timer, or not running or paused) |
| `reset` | destructive | `{ id }` | `{ timer }` | `not_found` |
| `remove` | destructive | `{ id }` | `{ removedId }` | `not_found` |
| `list` | read | `{}` | the agent `structuredContent` | — |
| `get` | read | `{ id }` | `{ timer }` | `not_found` |
| `presets.list` | read | `{}` | `{ presets }`, built-ins first | — |
| `presets.save` | write | `{ name, timer }` (no `until`) | `{ preset }` | `invalid_input`, `limit_reached` |
| `presets.remove` | destructive | `{ id }` | `{ removedId }` | `not_found`, `invalid_state` (built-in) |

A top-level `name` in `create` or `start` overrides the timer's or preset's own name. Every operation also returns `invalid_input` for malformed input. A `{ timer }` result is a snapshot: `{ definition, runtime, projection }`. `OPERATION_WRITE_CLASS` lists the classes; hosts must have the user's explicit request before running a destructive operation.

Product decisions: a paused timer keeps its place and `resume` continues the same segment; `skip` on the last segment of the last round finishes the timer, and otherwise leaves a paused timer paused at the start of the next segment; `lap` works only on stopwatches and lap-enabled countdowns; a finished timer must be reset before it starts again.

## Presets and limits

Built-in, read-only presets: `tabata` (10 s prep, then 8 × 20 s work and 10 s rest; 4:10), `emom` (10 × 60 s work; 10:00), `hiit-40-20` (10 × 40 s work and 20 s rest; 10:00), `pomodoro` (one round of four 25 min focus segments with 5 min breaks and a final 15 min break; 2:10:00) and `amrap` (a 20 min countdown with laps). Pomodoro is one round of eight segments because rounds repeat identical segments.

Limits: 50 timers in any state (finished timers count until they are reset or removed), 50 saved presets and 999 laps per timer. Exceeding one returns `limit_reached`.

## Agent result

`agentTimerResult(store, now)` mirrors `agentUsageResult` in `@subset/usage`:

- `structuredContent`: `{ schemaVersion: 1, observedAt, timers[] }`, one snapshot per timer, so a view can re-project from timestamps without asking again;
- `text`: one line per timer, for example `Tabata (t_ab12cd34): running · round 3/8 · work · 0:12 left · next rest 0:10`, or `No timers.`;
- `viewId`: `subset.timer.board@1`.

Time left rounds up and elapsed time rounds down. A segment label that differs from its phase is shown in parentheses.

## JSON Schemas and fixtures

`schemas` holds draft 2020-12 JSON Schemas generated from the runtime validators: `inputs` and `outputs` for every operation (each input has an object root, as MCP tool definitions need), `store`, `result` (the `structuredContent`), `error` and `viewProps`. `viewProps` covers the serializable board props `{ result, capabilities: { create, destructive }, density: compact | full }`; the host also passes `actions` and an optional `now` clock, which are functions. The one rule the schemas cannot state is that `until` lies within 24 hours of `now`; the operations check it.

`fixtures/contract-v1/` holds the shared test vectors, exported as `@subset/timer/fixtures/contract-v1/*`, for the CLI tests and the Swift client (SET-81): a store with every kind and state, its agent result, each operation's recorded result or error against that store, inputs that both validators accept or reject, and example view props. Regenerate them with `npm run fixtures --workspace=@subset/timer`; the tests fail when they drift.

## Superfunctions

The reuse check for Timer (SET-73, 2026-10-19) found:

- **Used by later Timer hosts:** `@mcpfn/core@0.0.5` (MCP tools, `ui://` App resources, stdio, and later a web-standard handler for Workers) and `@mcpfn/testing@0.0.5`. This package does not depend on them; its input schemas are plain JSON Schema objects that `@mcpfn/core` tool definitions accept.
- **Gap:** mcpfn bundles `@modelcontextprotocol/sdk@1.29.0`, while 1.32.1 is current.
- **Not needed for v1:** datafn (only matters once timers sync), uifn (0.0.x, unproven inside MCP App iframes) and observability (no telemetry).

This package depends only on `zod` 4.6.5, already used by `@subset/mgraph-contracts`, for runtime validation and JSON Schema generation.

## Verification

`npm test --workspace=@subset/timer` covers projections at segment edges, the last round, pause and resume across a segment edge, skip on the last segment, a clock going backward, every preset's total, transitions, each operation's error codes, the limits, schema validation of every fixture with Ajv, and the text for each state. Root `npm run check` runs it. Nothing here exercises a host, a real clock, sleep and wake, alerts, or an agent; those belong to SET-75 to SET-87.
