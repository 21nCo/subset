// Bundles the CLI, its daemon and alert sinks with the private @subset/timer package (and its zod
// dependency) inlined into dist/cli.mjs. The published package has no runtime dependencies.
import { chmod, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'rolldown';

const root = fileURLToPath(new URL('..', import.meta.url));
const exists = (file) => stat(file).then(() => true, () => false);

if (process.argv.includes('--check')) {
  // prepack runs the build first; this refuses to pack an incomplete package.
  const cli = path.join(root, 'dist/cli.mjs');
  for (const file of [cli, path.join(root, 'skills/subset-timer/SKILL.md'), path.join(root, 'README.md')]) {
    if (!(await exists(file))) { console.error(`Missing ${path.relative(root, file)}. Run npm run build at the repository root first.`); process.exit(1); }
  }
  if (!(await readFile(cli, 'utf8')).startsWith('#!/usr/bin/env node')) { console.error('dist/cli.mjs has no shebang.'); process.exit(1); }
  const chunks = (await readdir(path.join(root, 'dist'))).filter((name) => name.endsWith('.mjs'));
  const sources = await Promise.all(chunks.map((name) => readFile(path.join(root, 'dist', name), 'utf8')));
  // Code lines only: a kept JSDoc type such as import('@subset/timer').TimerDefinition is not an import.
  const code = (source) => source.split('\n').filter((line) => !/^\s*(?:\*|\/\/)/.test(line)).join('\n');
  if (sources.some((source) => /(?:\bfrom|\bimport\()\s*["'](?!node:)[^."'/]/.test(code(source)))) { console.error('dist/ still imports a package; bundle it instead.'); process.exit(1); }
  process.exit(0);
}

await rm(path.join(root, 'dist'), { recursive: true, force: true });
await build({
  input: { cli: path.join(root, 'src/cli.mjs') },
  platform: 'node',
  external: [/^node:/],
  output: { dir: path.join(root, 'dist'), format: 'esm', entryFileNames: '[name].mjs', chunkFileNames: '[name].mjs' }
});
// src/cli.mjs starts with a shebang; make sure the bundle does too, once, and is executable.
const cliFile = path.join(root, 'dist/cli.mjs');
const bundled = (await readFile(cliFile, 'utf8')).replace(/^#!.*\n/, '');
await writeFile(cliFile, `#!/usr/bin/env node\n${bundled}`);
await chmod(cliFile, 0o755);
