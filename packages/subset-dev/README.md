# subset.dev

A launcher for the Subset command-line tools. `npx subset.dev usage` runs `@subset.dev/usage`, so you do not have to type the scoped package name. Installed, its command is `subset`.

> Status: prepared for npm, not yet published.

## Use

Requires Node.js 22 or later.

```sh
npx subset.dev                      # list the tools
npx subset.dev usage                # same as npx @subset.dev/usage
npx subset.dev usage status         # arguments after the tool name go to the tool unchanged
npx subset.dev timer --help         # the tool's own help
npx subset.dev usage@beta           # a dist-tag or exact version (default: latest)
```

With `npm install -g subset.dev`, the same commands are `subset usage`, `subset usage status`, and so on. Note that `npx subset` (without `.dev`) runs a different, unrelated npm package.

| Tool | Runs |
| --- | --- |
| `usage` | `subset-usage` from [`@subset.dev/usage`](../usage-cli) |
| `timer` | `subset-timer` from [`@subset.dev/timer`](../timer-cli) |
| `minutes` | `subset-minutes` from [`@subset.dev/minutes`](../minutes-cli) |

`subset --help` and `subset --version` show the launcher's own help and version.

## How it works

`subset <tool>[@<version>] [arguments...]` runs `npm exec --yes --package=@subset.dev/<tool>@<version> -- <bin> [arguments...]`. The launcher has no dependencies, so `npx subset.dev usage` downloads only the launcher and the one tool you run, and npm caches both. It uses the npm that started it (through `npm_execpath`), or `npm` from `PATH` otherwise. It passes on the tool's exit code, and a signal sent to the launcher alone is forwarded to the tool.

The version is a dist-tag (`latest`, `beta`) or an exact version (`0.2.0`, `0.2.0-beta.3`). The launcher refuses ranges and other npm specs, so an argument cannot turn into an npm option or a file, URL or git dependency. Unknown tools exit with code 2 without starting npm.

## Adding a tool

Add the published package and its bin to `src/tools.mjs`. `npm run check` fails if a published package with a `bin` is missing from the list, or if an entry names a package or bin that does not exist.

## Superfunctions packages evaluated

None apply: the launcher is a dispatcher with no auth, storage, MCP or UI.
