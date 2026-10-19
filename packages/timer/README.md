# Timer capability (SET-74, SET-75)

This private package owns Timer's domain: timer definitions and presets, a pure state machine computed from timestamps, explicit operations with JSON Schemas, the versioned agent result with the registered view ID `subset.timer.board@1`, and that board view as a host-agnostic Svelte 5 component. It has no process, file I/O or network code. The later hosts (the per-user daemon, the `subset-timer` CLI, the MCP server, the local web host and the macOS app, SET-76 to SET-82) use this contract; none of them exists yet, and no Timer surface is available.

## Capability boundary

- **Owns:** the model (schema version 1), the engine (`project`, `transitionsBetween`, `settle`), the operations, the built-in presets, the agent result and its text fallback, the JSON Schemas, the contract fixtures, and the board view with its view-model helpers.
- **Hosts own:** storage (the daemon is the single writer), id-addressed routing, authorization of write classes, alerts and sound, scheduling, and any transport. A host passes the store, the untrusted input and `now`; it persists the returned store.
- **Excluded:** storage, the daemon, any CLI, MCP, alerts, sound and Swift.

Every time is wall-clock epoch milliseconds. A timer stores when its current running stretch began (`startedAt`), the running time before that (`accumulatedMs`) and the time skipped (`skippedMs`), so every surface computes the position as `accumulatedMs + skippedMs + (now - startedAt)` after sleep, wake or a restart. When the clock goes backward, the running stretch adds nothing instead of going negative.

## Model

| Kind | Fields |
| --- | --- |
| `countdown` | Exactly one of `durationMs` (1 s to 24 h) or `until` (an ISO time with an offset, 1 s to 24 h ahead). The first start fixes `until` to `durationMs`, so a reset timer runs the same length again. Optional `lapsEnabled`. |
| `stopwatch` | Laps. No end. |
| `interval` | `segments` (1 to 100) of `{ label (≤ 40), phase: prep \| work \| rest \| cooldown, durationMs (1 s to 24 h) }`, `rounds` (1 to 99), optional `prepMs` before the first round and `cooldownMs` after the last. |

Common fields: `id` (`t_` plus 8 lowercase Crockford base32 characters), `name` (1 to 60 characters, default per kind), `sound` (default true), `countdownTicks` (default true for interval timers only) and `createdAt`. Names and labels are one line of text with at least one visible character, counted in Unicode code points: control characters, line and paragraph separators, and bidi embeddings, overrides and isolates (U+202A to U+202E, U+2066 to U+2069) are rejected, while joiner sequences such as emoji stay valid. Names need not be unique; operations address timers by id. Timers and presets draw ids from the store's `idSequence`, which only grows: `issuedId` maps each sequence to a distinct id, so a removed id is never issued again, whatever the clock. A store can issue `ID_SPACE` (2^40) ids, after which `create`, `start` and `presets.save` return `limit_reached`. Ids are not secrets.

The runtime is `idle | running | paused | finished` with `startedAt`, `accumulatedMs`, `pausedAt`, `laps[]` (`{ elapsedMs, at }`, at most 999) and `skippedMs`. The store is `{ schemaVersion: 1, idSequence (0 to 2^40), timers[], presets[] }`, where `presets` holds only saved presets. Validate a persisted store with `parseStore`, which also checks that each runtime fits its definition:

- an idle timer has no position, laps or skips;
- a countdown that has started has a fixed `durationMs`;
- only stopwatches and lap-enabled countdowns hold laps, and only interval timers hold `skippedMs`;
- a stopwatch never finishes;
- a running or paused timer's `accumulatedMs + skippedMs` is below its total, and a finished one's equals it.

`schemas.store` states every rule but the last, which needs arithmetic.

## Engine

- `project(timer, now)` returns the status at `now` (a running timer past its end is `finished`), the elapsed, remaining and total time, the current interval step (index, segment index, round, phase, label, time elapsed and left in it), and the next step.
- `transitionsBetween(timer, from, to)` lists, for a running timer, the interval step starts, final-3-second ticks (when `countdownTicks` is on) and the finish with `from < at <= to`, in time order, so a scheduler arms one timeout and asks again after each change. A step of 3 seconds or less has a tick at its own start, listed after its segment event. Nothing at or before the position a running stretch began from is listed, so resuming at a step's start does not repeat that step's events.
- `settle(timer, now)` records a running timer whose time is up as finished.

## Operations

Each is a pure function `(store, input, now)` that validates its input (an omitted input means `{}`; `null` is malformed) and `now` (whole, non-negative epoch milliseconds, else `invalid_input` on the path `now`), and returns `{ ok: true, store, result }` or `{ ok: false, error: { code, message, issues? } }`. It never mutates the store it was given. `runOperation(name, …)` dispatches by name.

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

A timer's name is the top-level `name` in `create` or `start` if given, else the `name` inside the timer or the preset's `timer`, else the preset's own name (a saved preset `Morning` whose `timer.name` is `Run` creates timers named `Run`), else a default per kind. Every operation also returns `invalid_input` for malformed input. A `{ timer }` result is a snapshot: `{ definition, runtime, projection }`. `OPERATION_WRITE_CLASS` lists the classes; hosts must have the user's explicit request before running a destructive operation.

Product decisions: a paused timer keeps its place and `resume` continues the same segment; `skip` on the last segment of the last round finishes the timer, skipping any cooldown, and otherwise moves to the start of the next step (from the prep to the first round, from the cooldown to the finish), leaving a paused timer paused; `lap` works only on stopwatches and lap-enabled countdowns; a finished timer must be reset before it starts again.

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

`schemas` holds draft 2020-12 JSON Schemas generated from the runtime validators: `inputs` and `outputs` for every operation (each input has an object root, as MCP tool definitions need), `store`, `result` (the `structuredContent`), `error` and `viewProps`. `viewProps` covers the serializable board props `{ result, capabilities: { create, destructive }, density: compact | full }`; the host also passes `actions` and an optional `now` clock, which are functions. The rules the schemas cannot state are that `until` lies within 24 hours of `now`, which the operations check, and the store's position rule, which `parseStore` checks.

`fixtures/contract-v1/` holds the shared test vectors, exported as `@subset/timer/fixtures/contract-v1/*`, for the CLI tests and the Swift client (SET-81): a store with every kind and state, its agent result, each operation's recorded result or error against that store, inputs that both validators accept or reject, and example view props. Regenerate them with `npm run fixtures --workspace=@subset/timer`; the tests fail when they drift.

## Board view (SET-75)

`@subset/timer/view` is `src/view/TimerBoard.svelte`, the view registered as `subset.timer.board@1`. It needs Svelte 5 (a peer dependency) and a bundler that compiles `.svelte` and TypeScript sources, such as Vite with `@sveltejs/vite-plugin-svelte`. It never fetches: the local web host (SET-78), the MCP App (SET-80) and later product embeds each pass their own transport through `actions`.

| Prop | Type | Meaning |
| --- | --- | --- |
| `result` | `TimerBoardResult` | The agent result's `structuredContent` or a `list` result. The board validates it and shows an error instead of timers when it does not match, when `observedAt` is later than a `Date` can show, or when a timer id appears twice. A new value replaces the board's timers. |
| `actions` | `{ invoke(operation, input): Promise<result \| { error }> }` | Runs one operation. The view calls `start`, `pause`, `resume`, `lap`, `skip`, `reset`, `remove`, `create` and `presets.list`. A rejected promise counts as that operation failing. |
| `now` | `() => number`, optional | Epoch milliseconds; defaults to `Date.now`. |
| `capabilities` | `{ create: boolean; destructive: boolean }` | `create: false` hides the create form; `destructive: false` hides reset and remove. |
| `density` | `compact \| full` | `compact` suits an inline chat card: smaller cards, a lap count instead of the lap list, and the create form starts closed. |

`schemas.viewProps` is the JSON Schema of the serializable props (`result`, `capabilities`, `density`); `TimerBoardProps` in `@subset/timer/view-model` is the full type.

- **Rendering.** Every 250 ms the board re-projects each timer from its timestamps with `project`; it never counts ticks. Interval cards show the phase colour and label, the round (for example `Round 3/8`), the time left in the step, a progress ring and the next step. Countdowns show the time left and a ring; stopwatches show the time elapsed and their latest laps. The header shows the result's `observedAt`. After a successful action the returned snapshot replaces its timer (or a removal drops it) until the host passes a new `result`. Each reply must match its operation's result schema and name the timer acted on; one that does not counts as that operation failing and leaves the board as it was. A reply to an action that started before the host passed a newer `result` is not applied, so it cannot bring back a timer the host removed or undo a newer change; its failure is still shown. A failed action shows an inline error naming the operation, for example `Pause failed: …`, on its card or above the board.
- **Controls.** `controlStates` enables each control by the timer's status at `now` with the operations' own rules: start when idle (an `until` countdown only while its time is 1 second to 24 hours away), pause when running, resume when paused, lap on running stopwatches and lap-enabled countdowns, skip on running or paused interval timers, reset unless idle, remove always. Lap and skip are hidden on kinds that cannot use them.
- **Destructive actions.** Reset and remove run on a second press of the same control within 3 seconds; the first press changes its label to `Press again to reset`. There is no modal.
- **Keyboard.** Every control is a button in Tab order and each card is focusable. On a focused card, Space starts, pauses or resumes, L takes a lap and S skips; a held key acts once. Focus stays on the card after an action, and moves to the timer list when its card is removed.
- **Announcements.** One polite live region announces a new interval step (`Tabata: Rest, round 3 of 8, 0:10.`), pause, resume, finish and failed actions. It never announces the passing seconds; the time readouts are `role="timer"`, which screen readers do not read out as they change.
- **Motion and themes.** With `prefers-reduced-motion` the progress ring does not animate. Colour is never the only sign of the phase: its label is always shown. Light and dark themes follow `prefers-color-scheme`.
- **Create.** A timer comes from a preset (built-ins at once, replaced by the host's `presets.list` result with any saved presets), a duration, a stopwatch, or a custom interval sequence of up to 100 segments with rounds, optional prep and cooldown, sound and final-3-second ticks. Durations accept seconds, `m:ss` or `h:mm:ss`. In every mode, including the name, the form validates with the operations' own `create` and `timerSpec` validators and shows each error beside its field.

`@subset/timer/view-model` (`src/view/view-model.ts`, compiled to `dist/view/`) holds the pure helpers: time formatting, the control table, keyboard mapping, the destructive second press, the create-form drafts and their validation, announcement selection, and reading and settling action replies. Saving and removing presets, alerts, sound, persistence and an app shell are not part of the view.

## Superfunctions

The reuse check for Timer (SET-73, 2026-10-19) found:

- **Used by later Timer hosts:** `@mcpfn/core@0.0.5` (MCP tools, `ui://` App resources, stdio, and later a web-standard handler for Workers) and `@mcpfn/testing@0.0.5`. This package does not depend on them; its input schemas are plain JSON Schema objects that `@mcpfn/core` tool definitions accept.
- **Gap:** mcpfn bundles `@modelcontextprotocol/sdk@1.29.0`, while 1.32.1 is current.
- **Not needed for v1:** datafn (only matters once timers sync), uifn (0.0.x, unproven inside MCP App iframes, so the board view uses plain Svelte and CSS custom properties) and observability (no telemetry).

This package depends only on `zod` 4.6.5, already used by `@subset/mgraph-contracts`, for runtime validation and JSON Schema generation, and on Svelte 5 as a peer dependency for the board view.

## Verification

`npm test --workspace=@subset/timer` covers projections at segment edges, the last round, pause and resume across a segment edge, skip on the last segment, a clock going backward, every preset's total, transitions, each operation's error codes, the limits, schema validation of every fixture with Ajv, and the text for each state. For the view, `test/view-model.test.mjs` covers the formatting edges (0, 59.9 s, 1 h), the control table for every kind and state checked against the operations, the keyboard mapping (a held key acts once), the destructive second press, interval-editor validation against the schema fixtures, name and field validation in every create mode, announcement selection, including that re-projecting every 250 ms announces only step changes, rejection of a malformed or mismatched reply for every operation, replies that arrive after a newer host result, and results the board could not render. `npm run check --workspace=@subset/timer` runs `tsc` and `svelte-check` (`check:view`) with warnings as errors. Root `npm run check` runs both. Nothing here renders the view in a browser or checks it with a screen reader (deferred to SET-85 and SET-86), or exercises a host, a real clock, sleep and wake, alerts, or an agent; those belong to SET-76 to SET-87.
