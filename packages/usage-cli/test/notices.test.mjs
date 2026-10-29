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

// The MIT licence after its copyright line, as both upstream repositories ship it; kept apart from
// the script's copy, so a clause missing there fails.
const MIT = `Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.`;

test('the notices carry the complete MIT text of the bundled packages that ship no licence file', async () => {
  const cases = [['@mcpfn/core', '0.0.5', '2025 21n'], ['@cfworker/json-schema', '4.1.1', '2020 Jeremy Danyow']];
  const text = await notices(await Promise.all(cases.map(async ([name]) => chunkOf(await dependencyDir(hostDirectory, name)))));
  for (const [name, version, holder] of cases) {
    const section = text.split('\n## ').find((part) => part.startsWith(`${name} `));
    assert.equal(section, `${name} ${version} (MIT)\n\n\`\`\`\nMIT License\n\nCopyright (c) ${holder}\n\n${MIT}\n\`\`\`\n`);
  }
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
