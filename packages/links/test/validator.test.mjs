import assert from 'node:assert/strict';
import { test } from 'node:test';
import { isLinkDetailsV1 } from '../dist/index.js';

const minimal = { version: 1, url: 'https://example.com/', icons: [], contentType: 'text/html' };
const full = {
  version: 1,
  url: 'https://example.com/a',
  canonicalUrl: 'https://example.com/a',
  title: 'Title',
  description: 'Description',
  siteName: 'Example',
  language: 'en-GB',
  type: 'article',
  image: 'https://example.com/i.png',
  icons: [{ url: 'https://example.com/favicon.ico', rel: 'icon', sizes: '16x16', type: 'image/x-icon' }],
  author: 'Ada',
  publishedTime: '2024-01-02T03:04:05Z',
  contentType: 'text/html'
};

test('accepts minimal and complete records', () => {
  assert.equal(isLinkDetailsV1(minimal), true);
  assert.equal(isLinkDetailsV1(full), true);
  assert.equal(isLinkDetailsV1({ ...minimal, icons: Array(16).fill(full.icons[0]) }), true);
  assert.equal(isLinkDetailsV1({ ...minimal, title: '😀'.repeat(500), description: 'd'.repeat(2000) }), true);
});

test('rejects records that do not match version 1', () => {
  const invalid = {
    'not an object': 'https://example.com/',
    null: null,
    array: [],
    'version 2': { ...minimal, version: 2 },
    'missing version': { url: minimal.url, icons: [], contentType: 'text/html' },
    'missing url': { version: 1, icons: [], contentType: 'text/html' },
    'relative url': { ...minimal, url: '/a' },
    'non-http url': { ...minimal, url: 'ftp://example.com/' },
    'javascript canonical': { ...minimal, canonicalUrl: 'javascript:alert(1)' },
    'data image': { ...minimal, image: 'data:image/png;base64,AA' },
    'unknown key': { ...minimal, html: '<p>' },
    'empty title': { ...minimal, title: '' },
    'numeric title': { ...minimal, title: 1 },
    'title over 500 characters': { ...minimal, title: 't'.repeat(501) },
    'description over 2000 characters': { ...minimal, description: 'd'.repeat(2001) },
    'invalid language': { ...minimal, language: 'en us' },
    'non-ISO published time': { ...minimal, publishedTime: 'Jan 1 2024' },
    'impossible date': { ...minimal, publishedTime: '2024-02-30' },
    'missing icons': { version: 1, url: minimal.url, contentType: 'text/html' },
    '17 icons': { ...minimal, icons: Array(17).fill(full.icons[0]) },
    'icon with unknown rel': { ...minimal, icons: [{ url: 'https://example.com/i.png', rel: 'mask-icon' }] },
    'icon with relative url': { ...minimal, icons: [{ url: '/i.png', rel: 'icon' }] },
    'icon with unknown key': { ...minimal, icons: [{ url: 'https://example.com/i.png', rel: 'icon', color: 'red' }] },
    'missing content type': { version: 1, url: minimal.url, icons: [] },
    'content type with parameters': { ...minimal, contentType: 'text/html; charset=utf-8' }
  };
  for (const [name, value] of Object.entries(invalid)) assert.equal(isLinkDetailsV1(value), false, name);
});
