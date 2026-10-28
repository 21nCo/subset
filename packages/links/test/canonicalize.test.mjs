import assert from 'node:assert/strict';
import { test } from 'node:test';
import { canonicalizeUrl, isTrackingParameter, LinkUrlError } from '../dist/index.js';

const rejects = (input, reason) =>
  assert.throws(() => canonicalizeUrl(input), (error) => error instanceof LinkUrlError && error.reason === reason);

test('accepts http and https only', () => {
  assert.equal(canonicalizeUrl('http://example.com/a'), 'http://example.com/a');
  assert.equal(canonicalizeUrl('https://example.com/a'), 'https://example.com/a');
  for (const input of ['ftp://example.com/', 'javascript:alert(1)', 'data:text/html,hi', 'file:///etc/hosts', 'mailto:a@example.com']) {
    rejects(input, 'unsupported-scheme');
  }
  for (const input of ['', 'example.com/a', '/relative', 'https://', 'http://exa mple.com/']) rejects(input, 'invalid-url');
  rejects(42, 'invalid-url');
});

test('lowercases the scheme and host', () => {
  assert.equal(canonicalizeUrl('HTTPS://WWW.Example.COM/Path/Case'), 'https://www.example.com/Path/Case');
});

test('converts an IDN host to punycode', () => {
  assert.equal(canonicalizeUrl('https://Bücher.example/straße'), 'https://xn--bcher-kva.example/stra%C3%9Fe');
});

test('removes the default port and keeps any other port', () => {
  assert.equal(canonicalizeUrl('http://example.com:80/a'), 'http://example.com/a');
  assert.equal(canonicalizeUrl('https://example.com:443/a'), 'https://example.com/a');
  assert.equal(canonicalizeUrl('https://example.com:80/a'), 'https://example.com:80/a');
  assert.equal(canonicalizeUrl('http://example.com:8080/a'), 'http://example.com:8080/a');
});

test('gives an empty path the root path', () => {
  assert.equal(canonicalizeUrl('https://example.com'), 'https://example.com/');
  assert.equal(canonicalizeUrl('https://example.com?q=1'), 'https://example.com/?q=1');
  assert.equal(canonicalizeUrl('https://example.com/a/'), 'https://example.com/a/');
});

test('drops the fragment unless it is a #! or #/ route', () => {
  assert.equal(canonicalizeUrl('https://example.com/a#section'), 'https://example.com/a');
  assert.equal(canonicalizeUrl('https://example.com/a#'), 'https://example.com/a');
  assert.equal(canonicalizeUrl('https://example.com/a?q=1#top'), 'https://example.com/a?q=1');
  assert.equal(canonicalizeUrl('https://example.com/#!/inbox/1'), 'https://example.com/#!/inbox/1');
  assert.equal(canonicalizeUrl('https://example.com/app#/settings?tab=2'), 'https://example.com/app#/settings?tab=2');
});

test('keeps query order and encoding', () => {
  assert.equal(canonicalizeUrl('https://example.com/?z=1&a=2&m=3'), 'https://example.com/?z=1&a=2&m=3');
  // Duplicates, bare flags, empty pairs, + and %20 survive untouched, including when a parameter is removed.
  const query = 'b=2&a=1&b=1&flag&&q=a+b&r=a%20b&s=%E2%9C%93';
  assert.equal(canonicalizeUrl(`https://example.com/?${query}`), `https://example.com/?${query}`);
  assert.equal(canonicalizeUrl(`https://example.com/?utm_source=x&${query}&gclid=1`), `https://example.com/?${query}`);
  assert.equal(canonicalizeUrl('https://example.com/p?a=1&&utm_source=x&&b=2'), 'https://example.com/p?a=1&&&b=2');
});

test('removes a query that removal leaves without parameters', () => {
  for (const query of ['utm_source=x&', '&gclid=1', '&utm_source=x&&fbclid=1&', 'utm_source=x&&']) {
    assert.equal(canonicalizeUrl(`https://example.com/p?${query}`), 'https://example.com/p', query);
  }
  assert.equal(canonicalizeUrl('https://example.com/p?utm_source=x&#!/route'), 'https://example.com/p#!/route');
});

test('removes each listed tracking parameter', () => {
  const removed = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content', 'utm_id', 'utm_anything', 'fbclid', 'gclid', 'dclid', 'gbraid', 'wbraid', 'msclkid', 'yclid', 'mc_cid', 'mc_eid', 'igshid', '_hsenc', '_hsmi', 'ref_src'];
  for (const name of removed) {
    assert.equal(canonicalizeUrl(`https://example.com/p?keep=1&${name}=x`), 'https://example.com/p?keep=1', name);
    assert.equal(canonicalizeUrl(`https://example.com/p?${name}=x`), 'https://example.com/p', name);
    assert.equal(canonicalizeUrl(`https://example.com/p?${name}`), 'https://example.com/p', `${name} without a value`);
  }
  // Encoded names are matched after decoding.
  assert.equal(canonicalizeUrl('https://example.com/p?utm%5Fsource=x&a=1'), 'https://example.com/p?a=1');
});

test('keeps every parameter outside the closed list', () => {
  const kept = 'ref=hn&source=x&utm=1&xutm_source=1&UTM_SOURCE=1&Fbclid=1&si=abc&fbclid_x=1&s=1&%E0%A4%A=1';
  assert.equal(canonicalizeUrl(`https://example.com/?${kept}`), `https://example.com/?${kept}`);
  assert.equal(isTrackingParameter('ref'), false);
  assert.equal(isTrackingParameter('utm_'), true);
});

test('keeps http and https distinct', () => {
  assert.notEqual(canonicalizeUrl('http://example.com/a'), canonicalizeUrl('https://example.com/a'));
  assert.equal(canonicalizeUrl('http://example.com/a'), 'http://example.com/a');
});

test('accepts a URL object and is idempotent', () => {
  const inputs = ['HTTPS://Example.com:443?utm_source=a&b=1#x', 'http://bücher.example/#!/a', 'https://example.com/a?b&c=%20'];
  for (const input of inputs) {
    const once = canonicalizeUrl(input);
    assert.equal(canonicalizeUrl(once), once);
    assert.equal(canonicalizeUrl(new URL(input)), once);
  }
});
