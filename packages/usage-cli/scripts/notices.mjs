// dist/THIRD_PARTY_NOTICES.md for scripts/build.mjs, from the modules rolldown bundled.
import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';

/**
 * Bundled packages whose own build inlines other packages (read from their source maps), which are
 * then listed as well. The installed copy supplies the licence text; the inlined version may differ.
 */
const INLINED = { '@mcpfn/core': ['@modelcontextprotocol/sdk', 'zod', 'zod-to-json-schema'] };

/**
 * The directory of `name` as Node resolves it for the package in `dir`: its own node_modules
 * first, then each enclosing one, so a nested copy wins over a different hoisted one.
 */
export async function dependencyDir(dir, name) {
  for (let from = dir; ; from = path.dirname(from)) {
    const candidate = path.join(from, 'node_modules', name);
    if (await stat(path.join(candidate, 'package.json')).then(() => true, () => false)) return candidate;
    if (path.dirname(from) === from) throw new Error(`Cannot find ${name}, a dependency of ${dir}.`);
  }
}

/** The MIT licence text after its copyright line, as the upstream repositories below ship it. */
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

/**
 * The licence of a bundled package that ships no licence file, from its upstream repository's
 * LICENSE, with the copyright line as that file states it, for the version checked. Generation
 * fails for any other package or version without a licence file.
 */
const UPSTREAM_LICENCES = {
  // https://github.com/21nCo/super-functions/blob/dev/LICENSE
  '@mcpfn/core@0.0.5': `MIT License\n\nCopyright (c) 2025 21n\n\n${MIT}`,
  // https://github.com/cfworker/cfworker/blob/main/LICENSE.md
  '@cfworker/json-schema@4.1.1': `MIT License\n\nCopyright (c) 2020 Jeremy Danyow\n\n${MIT}`,
};

const readManifest = async (dir) => JSON.parse(await readFile(path.join(dir, 'package.json'), 'utf8'));

/**
 * The name, version, licence and licence text of every package in the bundle, read from the module
 * paths rolldown bundled, plus the packages those inline (see INLINED), found as their dependency.
 */
export async function notices(chunks) {
  const roots = new Map();
  for (const chunk of chunks) {
    for (const id of Object.keys(chunk.modules ?? {})) {
      const match = /^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//.exec(id);
      if (match) roots.set(match[1], null);
    }
  }
  for (const dir of [...roots.keys()]) {
    const manifest = await readManifest(dir);
    for (const inlined of INLINED[manifest.name] ?? []) {
      const version = manifest.dependencies?.[inlined] ?? manifest.devDependencies?.[inlined];
      // An exact pin is the version inlined; otherwise say only which package inlined it.
      roots.set(await dependencyDir(dir, inlined), /^\d+\.\d+\.\d+$/.test(version ?? '') ? version : `as inlined by ${manifest.name} ${manifest.version}`);
    }
  }
  const entries = [];
  for (const [dir, inlinedVersion] of roots) {
    const manifest = await readManifest(dir);
    const licenceFile = (await readdir(dir)).find((name) => /^(?:licen[cs]e|copying)(?:\.\w+)?$/i.test(name));
    const text = licenceFile ? (await readFile(path.join(dir, licenceFile), 'utf8')).trim() : UPSTREAM_LICENCES[`${manifest.name}@${manifest.version}`];
    if (!text) throw new Error(`${manifest.name} ${manifest.version} ships no licence file; check its upstream licence and add it to UPSTREAM_LICENCES in scripts/notices.mjs.`);
    entries.push({ heading: `${manifest.name} ${inlinedVersion ?? manifest.version} (${manifest.license})`, text });
  }
  entries.sort((a, b) => a.heading.localeCompare(b.heading));
  const sections = entries.map(({ heading, text }) => `## ${heading}\n\n\`\`\`\n${text}\n\`\`\`\n`);
  return `# Third-party notices\n\nThe files in dist/ bundle these packages.\n\n${sections.join('\n')}`;
}
