# subset.dev

A launcher for the Subset command-line tools. `npx subset.dev usage` runs `@subset.dev/usage`, so you do not have to type the scoped package name. Installed, its command is `subset`.

> Status: 0.1.0 is published on npm. Later versions are released with a `subset-dev-v<version>` tag.

## Use

Requires Node.js 22 or later.

```sh
npx subset.dev                      # list the tools
npx subset.dev usage                # same as npx @subset.dev/usage
npx subset.dev usage status         # arguments after the tool name go to the tool unchanged
npx subset.dev timer --help         # the tool's own help
npx subset.dev usage@beta           # latest, beta, next or an exact version (default: latest)
```

With `npm install -g subset.dev`, the same commands are `subset usage`, `subset usage status`, and so on. Note that `npx subset` (without `.dev`) runs a different, unrelated npm package.

| Tool | Runs |
| --- | --- |
| `usage` | `subset-usage` from [`@subset.dev/usage`](../usage-cli) |
| `timer` | `subset-timer` from [`@subset.dev/timer`](../timer-cli) |
| `minutes` | `subset-minutes` from [`@subset.dev/minutes`](../minutes-cli) |

`subset --help` and `subset --version` show the launcher's own help and version.

## How it works

`subset <tool>[@<version>] [arguments...]` first asks npm for the tool: `npm exec --yes --package=@subset.dev/<tool>@<version>` fetches it into npm's cache (or uses a local install that satisfies the version) and reports the `PATH` it would run it with. The launcher takes the tool's bin from the first `node_modules/.bin` folder on that `PATH` that holds the package, and loads that ES module into its own Node.js process, as if Node.js had been started on it. The launcher has no dependencies, so `npx subset.dev usage` downloads only the launcher and the one tool you run, and npm caches both.

npm runs as the `npm-cli.js` of the npm that started the launcher (through `npm_execpath`), or otherwise as `npm` from `PATH`; on Windows it is always `npm-cli.js` (beside the first `npm.cmd` on `PATH`, or the npm installed with Node.js), never `cmd.exe`. No shell is involved, so arguments such as `%PATH%` or a path ending in `\` reach the tool unchanged.

Because the tool runs in the launcher's own process, there is no second process to pass signals on: Ctrl-C, a hangup or a SIGTERM reaches the tool once, whether it is sent to the process or to its whole process group, and the tool reads the terminal and sets the exit code itself.

The version is a dist-tag the release workflow publishes (`latest`, `beta`, `next`) or an exact version (`0.2.0`, `0.2.0-beta.3`). The launcher refuses ranges (including tag-like ones such as `x` or `v1`) and other npm specs, so an argument cannot turn into an npm option or a file, URL or git dependency. Unknown tools exit with code 2 without starting npm.

## Adding a tool

Add the published package and its bin to `src/tools.mjs`. `npm run check` fails if a published package with a `bin` is missing from the list, or if an entry names a package or bin that does not exist.

## Superfunctions packages evaluated

None apply: the launcher is a dispatcher with no auth, storage, MCP or UI.
