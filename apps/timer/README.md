# @subset/timer-web

The private page `subset-timer serve` serves (SET-78): a Svelte 5 and Vite app that mounts the Timer board from `@subset/timer/view` with an HTTP transport (`src/transport.ts`) to the serve host's `/api`. `npm run build` writes `dist/`, which the `@subset.dev/timer` build copies into its `web/` folder. The page runs only behind `subset-timer serve`; see [Web host](../../packages/timer-cli/README.md#web-host-set-78) for the API, the request guard and the reconnect behaviour.

A second entry, `mcp-app.html` with `src/mcp-app.ts`, is the MCP App view (SET-80): `npm run build` also runs `vite build --config vite.mcp-app.config.ts`, which inlines every script and style into one file, `packages/timer-cli/mcp-app/board.html`, served by `subset-timer mcp` as `ui://subset-timer/board@1`. `src/mcp-bridge.ts` is its host bridge and `src/McpApp.svelte` its page; see [MCP App](../../packages/timer-cli/README.md#mcp-app-set-80).

`npm run check` runs `svelte-check` with warnings as errors. Nothing here is checked in a real browser yet (SET-85).
