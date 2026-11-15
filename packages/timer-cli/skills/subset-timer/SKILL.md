---
name: subset-timer
description: Start, check and control countdowns, stopwatches and interval workouts (Tabata, EMOM, HIIT, Pomodoro, AMRAP) on the user's computer with the npx -y subset.dev timer command. Use when the user asks for a timer, a reminder at a time today, a workout or focus interval, or about timers already running.
---

# Timer

`npx -y subset.dev timer` runs timers in a per-user background daemon on this computer (`subset.dev` is the Subset command; npx fetches it on first use, and `-y` skips npm's prompt). A timer keeps running, and plays its sounds and notifications, after your turn ends and after the command exits. You do not need to keep a process open or poll it.

Before Timer's first release, `npx -y subset.dev timer` works only after Timer is published to npm or a Developer ID-signed Timer app is installed; until then it fails and starts nothing, saying `timer is not on npm yet.`, or, with an unsigned Timer app installed, that the app was not run. If the user runs Timer from a build of the Subset repository, run `node <repository>/packages/timer-cli/dist/cli.mjs` in its place with the same arguments, using the absolute path of their checkout.

Use it when the user asks you to:

- time something ("set a 25 minute timer", "remind me in 90 seconds");
- count down to a time today ("until 17:30");
- run a workout or focus interval (Tabata, EMOM, HIIT, Pomodoro, AMRAP, custom work and rest rounds, or a workout of named exercises);
- check, pause, resume, lap, skip, reset or remove a timer.

## Rules

1. Always add `--json` and read the JSON on stdout. Do not parse the human text.
2. After starting a timer, tell the user its id (`timer.definition.id`, such as `t_ab12cd34`), its name and when it ends. The end time is `observedAt + timer.projection.remainingMs` in epoch milliseconds; give it in the user's local time. A stopwatch has no end.
3. Timers keep running after your turn ends. Say so if the user might expect the timer to stop when the conversation does.
4. Run `npx -y subset.dev timer reset` and `npx -y subset.dev timer rm` only when the user explicitly asks to reset or remove that timer. The same goes for `npx -y subset.dev timer preset rm`. Never reset or remove timers to tidy up.
5. Refer to timers by id once you know it. A name works only when exactly one timer has it.

## Start a timer

```sh
npx -y subset.dev timer start 25m --name "Tea" --json             # countdown: 90s, 25m, 1h30m, 1:30 (m:ss), 1:02:03
npx -y subset.dev timer start --until 17:30 --name "Standup" --json  # countdown to the next 17:30 local time
npx -y subset.dev timer start stopwatch --json
npx -y subset.dev timer start tabata --json                        # built-in presets: tabata, emom, hiit, pomodoro, amrap
npx -y subset.dev timer start interval --work 40s --rest 20s --rounds 10 --prep 10s --cooldown 60s --json
npx -y subset.dev timer start pomodoro --no-sound --json           # notifications only, no sounds
```

### A workout of named steps

For a workout where each step has its own name (a list of exercises, a routine), give each step a label. For a few steps, use `--step "Label:duration"` (repeat it; `--rest` goes between the steps, not after the last; `--rounds` defaults to 1):

```sh
npx -y subset.dev timer start interval --step "Squats:40s" --step "Lunges:40s" --step "Plank:1:00" --rest 20s --prep 10s --name "Legs" --json
```

For longer workouts, write a JSON workout file and start it with `--file` (or pipe it with `--file -`):

```sh
cat > workout.json <<'JSON'
{
  "name": "15 min standing HIIT",
  "prep": "10s",
  "rest": "20s",
  "rounds": 1,
  "steps": [
    { "label": "Jumping jacks", "duration": "40s" },
    { "label": "Squats", "duration": "40s" },
    { "label": "High knees", "duration": "40s" }
  ]
}
JSON
npx -y subset.dev timer start --file workout.json --json
```

- Workout fields: `name`, `prep`, `rest`, `rounds` (1 to 99), `cooldown`, `sound` (true or false) and `steps`. Every field but `steps` is optional.
- Step fields: `label` (up to 40 characters, one line), `duration` (`"40s"`, `"1:30"`, or a number of seconds) and `phase` (`work` by default, or `rest`, `prep`, `cooldown`). Write a rest step yourself when rests differ; use `rest` when they are all the same.
- A workout has at most 100 steps, counting the rests `rest` adds. Each duration is from 1 second to 24 hours.
- `--name` and `--no-sound` on the command line override the file's `name` and `sound`.
- An invalid file is `invalid_input` with `issues`, each with the `path` of the field (such as `steps[3].duration`, `(root)` for a file that is not JSON, or `--file` for one that cannot be read or is over 1 MiB) and a `message`. Fix that field and start again.

`start` prints `{ "timer": { "definition", "runtime", "projection" }, "observedAt" }`. `projection.status` is `running`; `projection.remainingMs` is the time left and `projection.step` the current interval step (phase, label, round).

Saved presets work like the built-in ones, by name or id:

```sh
npx -y subset.dev timer presets --json                             # { "presets": [...] }, built-ins first
npx -y subset.dev timer preset save "Leg day" --work 45s --rest 15s --rounds 8 --json
npx -y subset.dev timer preset save "Morning HIIT" --file workout.json --json   # or --step flags; the file's name is not used
npx -y subset.dev timer start "Leg day" --json
npx -y subset.dev timer preset rm "Leg day" --json                 # only when the user asks
```

## Check and control timers

```sh
npx -y subset.dev timer list --json            # every timer: { structuredContent: { observedAt, timers }, text, viewId }
npx -y subset.dev timer status t_ab12cd34 --json
npx -y subset.dev timer pause t_ab12cd34 --json
npx -y subset.dev timer resume t_ab12cd34 --json
npx -y subset.dev timer lap t_ab12cd34 --json  # stopwatches and AMRAP countdowns
npx -y subset.dev timer skip t_ab12cd34 --json # jump to the next interval step
npx -y subset.dev timer reset t_ab12cd34 --json  # only when the user asks; then npx -y subset.dev timer start t_ab12cd34 runs it again
npx -y subset.dev timer rm t_ab12cd34 --json     # only when the user asks
```

`list` with `--json` gives `structuredContent.timers`, one `{ definition, runtime, projection }` per timer, and `text`, one line per timer that you can quote to the user.

## Show the timers in a browser

Only when the user asks to see or control their timers in a browser:

```sh
npx -y subset.dev timer serve --json   # prints { "url", "port" }, opens http://127.0.0.1:4175 (or the next free port) and runs until stopped
```

`serve` does not exit by itself, so run it in the background or ask the user to run it in their own terminal, and give them the `url`. It is only a view: timers keep running without it.

## Errors

A failure prints `{ "error": { "code", "message" } }` on stdout and exits non-zero:

| Exit | Codes | What to do |
| --- | --- | --- |
| 2 | `invalid_input`, `ambiguous` | Fix the arguments. `ambiguous` lists `candidates`; ask the user which one, or use its id. |
| 3 | `daemon_unavailable` | The daemon could not start or answer. Report the message; `npx -y subset.dev timer daemon status --json` shows whether it runs. |
| 4 | `not_found`, `invalid_state`, `limit_reached` | Report the message, for example that the timer is already finished and needs a reset. |

## Daemon and skill

You rarely need these: any other command starts the daemon.

```sh
npx -y subset.dev timer daemon status --json   # { pid, dataDir, socket, alerts, startedAt }; "alerts": "unavailable" means no sound or notifications here
npx -y subset.dev timer daemon stop --json     # timers keep their place and continue when it starts again
npx -y subset.dev timer daemon run             # foreground daemon; started for you
npx -y subset.dev timer skill path             # where this skill is installed
```
