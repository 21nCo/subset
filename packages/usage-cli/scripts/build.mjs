// Bundles the CLI with the private @subset/usage package inlined, and copies the built
// dashboard from apps/usage/dist into web/. The published package has no runtime dependencies.
import { cp, mkdir, readFile, rm, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { build } from 'rolldown';

const root = fileURLToPath(new URL('..', import.meta.url));
const webSource = fileURLToPath(new URL('../../../apps/usage/dist/', import.meta.url));
const exists = (path) => stat(path).then(() => true, () => false);

if (process.argv.includes('--check')) {
  // prepack: refuse to pack without both halves.
  for (const file of ['dist/cli.mjs', 'web/index.html']) {
    if (!(await exists(`${root}${file}`))) { console.error(`Missing ${file}. Run npm run build at the repository root first.`); process.exit(1); }
  }
  const head = (await readFile(`${root}dist/cli.mjs`, 'utf8')).slice(0, 40);
  if (!head.startsWith('#!/usr/bin/env node')) { console.error('dist/cli.mjs has no shebang.'); process.exit(1); }
  process.exit(0);
}

await rm(`${root}dist`, { recursive: true, force: true });
await build({
  input: `${root}src/server.mjs`,
  platform: 'node',
  external: [/^node:/],
  output: { file: `${root}dist/cli.mjs`, format: 'esm', banner: '#!/usr/bin/env node' },
});
if (!(await exists(`${webSource}index.html`))) { console.error('apps/usage/dist is missing. Build @subset/usage-web first.'); process.exit(1); }
await rm(`${root}web`, { recursive: true, force: true });
await mkdir(`${root}web`, { recursive: true });
await cp(webSource, `${root}web`, { recursive: true });
