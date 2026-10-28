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
    const author = typeof manifest.author === 'string' ? manifest.author : manifest.author?.name;
    const text = licenceFile
      ? (await readFile(path.join(dir, licenceFile), 'utf8')).trim()
      : `${manifest.license}${author ? `, copyright ${author}` : ''}. The package ships no licence file.`;
    entries.push({ heading: `${manifest.name} ${inlinedVersion ?? manifest.version} (${manifest.license})`, text });
  }
  entries.sort((a, b) => a.heading.localeCompare(b.heading));
  const sections = entries.map(({ heading, text }) => `## ${heading}\n\n\`\`\`\n${text}\n\`\`\`\n`);
  return `# Third-party notices\n\nThe files in dist/ bundle these packages.\n\n${sections.join('\n')}`;
}
