// Checks the reference extension that `npm run build` wrote for each target: the manifest is the reviewed snapshot,
// every file it names exists, and the background starts in a bare worker scope (no window or document) and registers
// the link menu through that target's global (`chrome` or `browser`). It does not load the extension in a browser;
// live browsers are SET-191.
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const root = new URL('../', import.meta.url);
const targets = { 'chromium-mv3': 'chrome', 'firefox-mv3': 'browser' };

for (const [target, globalName] of Object.entries(targets)) {
  const dir = new URL(`dist-extension/${target}/`, root);
  const manifest = JSON.parse(readFileSync(new URL('manifest.json', dir), 'utf8'));
  const snapshot = JSON.parse(readFileSync(new URL(`test/manifest.${target}.json`, root), 'utf8'));
  assert.deepEqual(manifest, snapshot, `${target}: the built manifest differs from test/manifest.${target}.json`);

  const named = [manifest.background.service_worker, ...(manifest.background.scripts ?? []), manifest.action.default_popup];
  for (const file of named) assert.ok(existsSync(new URL(file, dir)), `${target}: ${file} is named in the manifest but was not built`);
  const popup = readFileSync(new URL(manifest.action.default_popup, dir), 'utf8');
  for (const [, file] of popup.matchAll(/(?:src|href)="\/([^"]+)"/g)) {
    assert.ok(existsSync(new URL(file, dir)), `${target}: ${file} is named in the popup but was not built`);
  }

  // The popup and its host share one copy of the package, so a capture error is recognised in the popup.
  const scripts = [manifest.background.service_worker, ...[...popup.matchAll(/(?:src|href)="\/([^"]+\.js)"/g)].map(([, file]) => file)];
  const bundled = scripts.map((file) => readFileSync(new URL(file, dir), 'utf8')).join('\n');
  assert.equal(bundled.match(/class LinkCaptureError\b/g)?.length, 1, `${target}: link capture is bundled more than once, or not at all`);

  const calls = [];
  const raw = {
    runtime: {},
    contextMenus: {
      async remove(id) {
        calls.push(['contextMenus.remove', id]);
      },
      async create(properties) {
        calls.push(['contextMenus.create', properties.id, properties.contexts]);
        return properties.id;
      },
      onClicked: { addListener: () => calls.push(['contextMenus.onClicked.addListener']) }
    }
  };
  const scope = { chrome: globalThis.chrome, browser: globalThis.browser, location: globalThis.location };
  Object.assign(globalThis, { chrome: undefined, browser: undefined, [globalName]: raw });
  globalThis.location = { protocol: target === 'chromium-mv3' ? 'chrome-extension:' : 'moz-extension:', pathname: '/background.js' };
  try {
    await import(`${pathToFileURL(new URL(manifest.background.service_worker, dir).pathname).href}?${target}`);
    // An MV3 worker gets the click that woke it only if the listener was added during its first synchronous run.
    assert.deepEqual(calls[0], ['contextMenus.onClicked.addListener'], `${target}: the click listener is not added on start`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  } finally {
    Object.assign(globalThis, scope);
  }
  assert.deepEqual(calls, [
    ['contextMenus.onClicked.addListener'],
    ['contextMenus.remove', 'link-capture:save-link'],
    ['contextMenus.create', 'link-capture:save-link', ['link']]
  ], `${target}: the background did not register the link menu`);
  console.log(`${target}: manifest matches the snapshot, ${named.length} named files built, background registers the link menu`);
}
