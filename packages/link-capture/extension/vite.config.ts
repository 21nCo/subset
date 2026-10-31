import { fileURLToPath } from 'node:url';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import { extfnVite } from '@extfn/vite';
import { defineConfig, type Plugin } from 'vite';

const root = fileURLToPath(new URL('.', import.meta.url));

/**
 * `@extfn/core` 0.1.0 exports its build-time config loader from the same entry as the runtime, and that loader imports
 * `node:fs/promises`, `node:path` and `node:url`, so a browser bundle of `getRuntime` fails. The extension never calls
 * the loader: inside `@extfn/core` those three imports resolve to stubs, and the loader is tree-shaken away.
 * TEMPORARY until extfn 0.2.0 (SFO-44); remove once `@extfn/core` has a browser-only entry.
 */
function extfnCoreNodeStubs(): Plugin {
  const stubs: Record<string, string> = {
    'node:fs/promises': 'export default {};',
    'node:path': 'export default {};',
    'node:url': 'export function pathToFileURL() { throw new Error("node:url is not available in an extension"); }'
  };
  const prefix = '\0extfn-core-stub:';
  return {
    name: 'extfn-core-node-stubs',
    enforce: 'pre',
    resolveId(id, importer) {
      if (id in stubs && importer?.replaceAll('\\', '/').includes('/node_modules/@extfn/core/')) return `${prefix}${id}`;
    },
    load(id) {
      if (id.startsWith(prefix)) return stubs[id.slice(prefix.length)];
    }
  };
}

export default defineConfig({
  root,
  // Writes dist-extension/chromium-mv3 and dist-extension/firefox-mv3, each with its manifest.
  build: { outDir: fileURLToPath(new URL('../dist-extension', import.meta.url)), minify: false },
  plugins: [extfnCoreNodeStubs(), svelte(), ...extfnVite({ configPath: fileURLToPath(new URL('./extfn.config.ts', import.meta.url)) })]
});
