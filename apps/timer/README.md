# @subset/timer-web

The private page `subset-timer serve` serves (SET-78): a Svelte 5 and Vite app that mounts the Timer board from `@subset/timer/view` with an HTTP transport (`src/transport.ts`) to the serve host's `/api`. `npm run build` writes `dist/`, which the `@subset.dev/timer` build copies into its `web/` folder. The page runs only behind `subset-timer serve`; see [Web host](../../packages/timer-cli/README.md#web-host-set-78) for the API, the request guard and the reconnect behaviour.

`npm run check` runs `svelte-check` with warnings as errors. Nothing here is checked in a real browser yet (SET-85).
