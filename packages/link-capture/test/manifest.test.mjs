import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { buildManifest, createTargetBuildOutputs, loadExtensionConfig } from '@extfn/vite';
import {
  hasServerAccess,
  LINK_CAPTURE_OPTIONAL_HOST_PERMISSIONS,
  LINK_CAPTURE_PERMISSIONS,
  removeServerAccess,
  requestServerAccess,
  serverOriginPattern
} from '../dist/index.js';
import { createFakeBrowser } from './fake-browser.mjs';

const configPath = fileURLToPath(new URL('../extension/extfn.config.ts', import.meta.url));
const snapshot = (target) => JSON.parse(readFileSync(new URL(`manifest.${target}.json`, import.meta.url), 'utf8'));

describe('the declared permissions', () => {
  it('are activeTab, contextMenus, scripting and storage, with only optional host access', () => {
    assert.deepEqual([...LINK_CAPTURE_PERMISSIONS], ['activeTab', 'contextMenus', 'scripting', 'storage']);
    assert.deepEqual([...LINK_CAPTURE_OPTIONAL_HOST_PERMISSIONS], ['http://*/*', 'https://*/*']);
  });

  // The snapshots are reviewed: a change to a permission, host access or content script fails here and in the build.
  for (const target of ['chromium-mv3', 'firefox-mv3']) {
    it(`build the reviewed ${target} manifest`, async () => {
      const { resolvedConfig } = await loadExtensionConfig(configPath);
      const manifest = JSON.parse(JSON.stringify(buildManifest(resolvedConfig, target, createTargetBuildOutputs(resolvedConfig))));
      assert.deepEqual(manifest, snapshot(target));
      assert.deepEqual(manifest.permissions, [...LINK_CAPTURE_PERMISSIONS]);
      for (const key of ['host_permissions', 'optional_permissions', 'content_scripts', 'externally_connectable', 'web_accessible_resources']) {
        assert.equal(key in manifest, false, key);
      }
    });
  }
});

describe('server access', () => {
  it('asks for, checks and gives back only the server origin', async () => {
    const { browser, calls } = createFakeBrowser();
    const url = 'https://bookmarks.example.com:8443/app/?q=1';
    assert.equal(await hasServerAccess(browser, url), false);
    assert.equal(await requestServerAccess(browser, url), true);
    assert.equal(await hasServerAccess(browser, url), true);
    assert.equal(await removeServerAccess(browser, url), true);
    const origins = { origins: ['https://bookmarks.example.com/*'] };
    assert.deepEqual(calls, [
      ['permissions.contains', origins],
      ['permissions.request', origins],
      ['permissions.contains', origins],
      ['permissions.remove', origins]
    ]);
  });

  it('builds match patterns for http, IP and IPv6 servers', () => {
    assert.equal(serverOriginPattern('http://localhost:3000/'), 'http://localhost/*');
    assert.equal(serverOriginPattern('http://192.168.1.5:8080'), 'http://192.168.1.5/*');
    assert.equal(serverOriginPattern('http://[::1]:8080/'), 'http://[::1]/*');
  });

  it('refuses another scheme or credentials before asking the browser', async () => {
    const { browser, calls } = createFakeBrowser();
    for (const url of ['ftp://example.com', 'https://u:p@example.com', 'example.com', '*://*/*']) {
      await assert.rejects(requestServerAccess(browser, url), TypeError, url);
    }
    assert.deepEqual(calls, []);
  });

  it('refuses a wildcard host, which would grant more than the server', async () => {
    const { browser, calls } = createFakeBrowser();
    for (const url of ['https://*/', 'https://*.example.com/', 'http://*:8080/', 'https://%2A.example.com/', 'https://bookmarks*.example.com/']) {
      assert.throws(() => serverOriginPattern(url), TypeError, url);
      await assert.rejects(requestServerAccess(browser, url), TypeError, url);
      await assert.rejects(hasServerAccess(browser, url), TypeError, url);
      await assert.rejects(removeServerAccess(browser, url), TypeError, url);
    }
    assert.deepEqual(calls, []);
  });
});
