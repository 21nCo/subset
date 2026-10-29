import assert from 'node:assert/strict';
import { test } from 'node:test';
import { BookmarkError, displayTitle, normalizeTagName } from '../dist/index.js';

test('displayTitle prefers the user title, then the page title, then host and path', () => {
  const url = 'https://Example.com:8443/docs/a?b=1#c';
  assert.equal(displayTitle({ url, userTitle: 'Mine', details: { title: 'Page' } }), 'Mine');
  assert.equal(displayTitle({ url, userTitle: '  ', details: { title: ' Page ' } }), 'Page');
  assert.equal(displayTitle({ url, userTitle: null, details: { title: '' } }), 'example.com:8443/docs/a');
  assert.equal(displayTitle({ url: 'https://example.com/', userTitle: null, details: null }), 'example.com');
  assert.equal(displayTitle({ url: 'https://example.com/a/' }), 'example.com/a/');
  assert.equal(displayTitle({ url: 'not a url' }), 'not a url');
});

test('normalizeTagName trims, NFC-normalizes and folds case for the key', () => {
  assert.deepEqual(normalizeTagName('  Café '), { name: 'Café', nameKey: 'café' });
  assert.deepEqual(normalizeTagName('Café'), { name: 'Café', nameKey: 'café' });
  assert.deepEqual(normalizeTagName('C++'), { name: 'C++', nameKey: 'c++' });
  for (const bad of ['', '   ', 'two words', 'a,b', 'tab\there', 'bell\u0007', 'x'.repeat(65), 7, null]) {
    assert.throws(() => normalizeTagName(bad), (error) => error instanceof BookmarkError && error.code === 'invalid-input', String(bad));
  }
  assert.equal(normalizeTagName('é'.repeat(64)).name.length, 64);
});
