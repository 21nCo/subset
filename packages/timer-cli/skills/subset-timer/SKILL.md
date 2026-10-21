---
name: subset-timer
description: Start, check and control countdowns, stopwatches and interval workouts (Tabata, EMOM, HIIT, Pomodoro, AMRAP) on the user's computer with the subset-timer command. Use when the user asks for a timer, a reminder at a time today, a workout or focus interval, or about timers already running.
---

# Timer

`subset-timer` runs timers in a per-user background daemon on this computer. A timer keeps running, and plays its sounds and notifications, after your turn ends and after the command exits. You do not need to keep a process open or poll it.

Use it when the user asks you to:

- time something ("set a 25 minute timer", "remind me in 90 seconds");
- count down to a time today ("until 17:30");
- run a workout or focus interval (Tabata, EMOM, HIIT, Pomodoro, AMRAP, or custom work and rest rounds);
- check, pause, resume, lap, skip, reset or remove a timer.

## Rules

1. Always add `--json` and read the JSON on stdout. Do not parse the human text.
2. After starting a timer, tell the user its id (`timer.definition.id`, such as `t_ab12cd34`), its name and when it ends. The end time is `observedAt + timer.projection.remainingMs` in epoch milliseconds; give it in the user's local time. A stopwatch has no end.
3. Timers keep running after your turn ends. Say so if the user might expect the timer to stop when the conversation does.
4. Run `subset-timer reset` and `subset-timer rm` only when the user explicitly asks to reset or remove that timer. The same goes for `subset-timer preset rm`. Never reset or remove timers to tidy up.
5. Refer to timers by id once you know it. A name works only when exactly one timer has it.

## Start a timer

```sh
subset-timer start 25m --name "Tea" --json             # countdown: 90s, 25m, 1h30m, 1:30 (m:ss), 1:02:03
subset-timer start --until 17:30 --name "Standup" --json  # countdown to the next 17:30 local time
subset-timer start stopwatch --json
subset-timer start tabata --json                        # built-in presets: tabata, emom, hiit, pomodoro, amrap
subset-timer start interval --work 40s --rest 20s --rounds 10 --prep 10s --cooldown 60s --json
subset-timer start pomodoro --no-sound --json           # notifications only, no sounds
```

`start` prints `{ "timer": { "definition", "runtime", "projection" }, "observedAt" }`. `projection.status` is `running`; `projection.remainingMs` is the time left and `projection.step` the current interval step (phase, label, round).

Saved presets work like the built-in ones, by name or id:

```sh
subset-timer presets --json                             # { "presets": [...] }, built-ins first
subset-timer preset save "Leg day" --work 45s --rest 15s --rounds 8 --json
subset-timer start "Leg day" --json
subset-timer preset rm "Leg day" --json                 # only when the user asks
```

## Check and control timers

```sh
subset-timer list --json            # every timer: { structuredContent: { observedAt, timers }, text, viewId }
subset-timer status t_ab12cd34 --json
subset-timer pause t_ab12cd34 --json
subset-timer resume t_ab12cd34 --json
subset-timer lap t_ab12cd34 --json  # stopwatches and AMRAP countdowns
subset-timer skip t_ab12cd34 --json # jump to the next interval step
subset-timer reset t_ab12cd34 --json  # only when the user asks; then subset-timer start t_ab12cd34 runs it again
subset-timer rm t_ab12cd34 --json     # only when the user asks
```

`list` with `--json` gives `structuredContent.timers`, one `{ definition, runtime, projection }` per timer, and `text`, one line per timer that you can quote to the user.

## Show the timers in a browser

Only when the user asks to see or control their timers in a browser:

```sh
subset-timer serve --json   # prints { "url", "port" }, opens http://127.0.0.1:4175 (or the next free port) and runs until stopped
```

`serve` does not exit by itself, so run it in the background or ask the user to run it in their own terminal, and give them the `url`. It is only a view: timers keep running without it.

## Errors

A failure prints `{ "error": { "code", "message" } }` on stdout and exits non-zero:

| Exit | Codes | What to do |
| --- | --- | --- |
| 2 | `invalid_input`, `ambiguous` | Fix the arguments. `ambiguous` lists `candidates`; ask the user which one, or use its id. |
| 3 | `daemon_unavailable` | The daemon could not start or answer. Report the message; `subset-timer daemon status --json` shows whether it runs. |
| 4 | `not_found`, `invalid_state`, `limit_reached` | Report the message, for example that the timer is already finished and needs a reset. |

## Daemon and skill

You rarely need these: any other command starts the daemon.

```sh
subset-timer daemon status --json   # { pid, dataDir, socket, alerts, startedAt }; "alerts": "unavailable" means no sound or notifications here
subset-timer daemon stop --json     # timers keep their place and continue when it starts again
subset-timer daemon run             # foreground daemon; started for you
subset-timer skill path             # where this skill is installed
```
