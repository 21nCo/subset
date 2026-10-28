import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { dependencyDir, notices } from '../scripts/notices.mjs';

const hostDirectory = fileURLToPath(new URL('..', import.meta.url));
// What rolldown reports for a bundle holding one module of the package in `dir`.
const chunkOf = (dir) => ({ modules: { [join(dir, 'dist', 'index.js')]: {} } });

test('the notices carry the full MIT text of @mcpfn/core, which ships no licence file', async () => {
  const text = await notices([chunkOf(await dependencyDir(hostDirectory, '@mcpfn/core'))]);
  const section = text.split('\n## ').find((part) => part.startsWith('@mcpfn/core '));
  assert.match(section, /^@mcpfn\/core 0\.0\.5 \(MIT\)\n/);
  assert.match(section, /\nMIT License\n\nCopyright \(c\) 2025 21n\n\nPermission is hereby granted, free of charge,/);
  assert.match(section, /OTHER DEALINGS IN THE\nSOFTWARE\.\n```/);
  assert.doesNotMatch(text, /ships no licence file/);
});

test('the notices fail for a bundled package with no licence file and no checked upstream licence', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'subset-usage-notices-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const dir = join(root, 'node_modules', 'unlicensed');
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, 'package.json'), JSON.stringify({ name: 'unlicensed', version: '1.0.0', license: 'MIT', author: 'Someone' }));
  await assert.rejects(notices([chunkOf(dir)]), /unlicensed 1\.0\.0 ships no licence file/);
});
