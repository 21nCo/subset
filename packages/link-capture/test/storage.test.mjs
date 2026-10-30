import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { createTokenStore } from '../dist/index.js';
import { createFakeBrowser } from './fake-browser.mjs';

describe('createTokenStore', () => {
  it('keeps the token in storage.local and never touches storage.sync', async () => {
    const { browser, paths, local } = createFakeBrowser();
    const store = createTokenStore(browser, 'bookmarks');
    assert.equal(await store.get(), undefined);
    await store.set({ serverUrl: 'https://bookmarks.example.com/app/?x=1#y', token: 'secret-token' });
    assert.deepEqual(await store.get(), { serverUrl: 'https://bookmarks.example.com/app/', token: 'secret-token' });
    assert.deepEqual([...local.keys()], ['link-capture:token:bookmarks']);
    await store.clear();
    assert.equal(await store.get(), undefined);
    assert.deepEqual(paths(), ['storage.local.get', 'storage.local.set', 'storage.local.get', 'storage.local.remove', 'storage.local.get']);
  });

  it('keeps each target apart', async () => {
    const { browser } = createFakeBrowser();
    const bookmarks = createTokenStore(browser, 'bookmarks');
    const memotron = createTokenStore(browser, 'memotron');
    await bookmarks.set({ serverUrl: 'https://b.example.com', token: 'b' });
    await memotron.set({ serverUrl: 'https://m.example.com', token: 'm' });
    await bookmarks.clear();
    assert.equal(await bookmarks.get(), undefined);
    assert.deepEqual(await memotron.get(), { serverUrl: 'https://m.example.com/', token: 'm' });
  });

  it('refuses a token it could not use, writing nothing', async () => {
    const { browser, paths } = createFakeBrowser();
    const store = createTokenStore(browser, 'bookmarks');
    for (const value of [
      { serverUrl: 'https://user:pw@example.com', token: 't' },
      { serverUrl: 'ftp://example.com', token: 't' },
      { serverUrl: 'example.com', token: 't' },
      { serverUrl: 'https://example.com', token: ' ' },
      { serverUrl: 'https://example.com' },
      null
    ]) {
      await assert.rejects(store.set(value), TypeError, JSON.stringify(value));
    }
    assert.deepEqual(paths(), []);
  });

  it('reads a malformed stored value as no token', async () => {
    const { browser, local } = createFakeBrowser();
    const store = createTokenStore(browser, 'bookmarks');
    for (const value of ['secret', { token: 'secret' }, { serverUrl: 'javascript:alert(1)', token: 'secret' }, { serverUrl: 'https://example.com', token: 5 }]) {
      local.set('link-capture:token:bookmarks', value);
      assert.equal(await store.get(), undefined, JSON.stringify(value));
    }
  });

  it('needs a target id', () => {
    const { browser } = createFakeBrowser();
    for (const id of ['', '  ', undefined]) assert.throws(() => createTokenStore(browser, id), TypeError);
  });
});
