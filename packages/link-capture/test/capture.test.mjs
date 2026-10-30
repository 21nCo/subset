import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { MAX_DOCUMENT_BYTES, MAX_TITLE_LENGTH } from '@subset.dev/links';
import { captureActiveTab, LinkCaptureError, MAX_LANG_LENGTH, MAX_SELECTION_LENGTH, readPage } from '../dist/index.js';
import { createFakeBrowser, fakePage, runInPage } from './fake-browser.mjs';

const now = () => new Date('2026-10-31T12:00:00.000Z');
const HEAD = `<head>
  <title>Ignored when the tab has a title</title>
  <meta property="og:title" content="The article">
  <meta name="description" content="What it is about">
  <link rel="icon" href="/icon.png" sizes="32x32">
  <link rel="canonical" href="https://example.com/article?utm_medium=feed">
</head>`;

function articleBrowser(overrides = {}, target) {
  return createFakeBrowser({
    target,
    tabs: [{ id: 7, url: 'https://example.com/article?utm_source=x&id=3#top' }],
    page: fakePage({
      url: 'https://example.com/article?utm_source=x&id=3#top',
      title: '  The   article\n— Example ',
      head: HEAD,
      lang: 'en-GB',
      selection: '  A quoted line.\n',
      ...overrides
    })
  });
}

const rejectsWith = (code) => (error) => error instanceof LinkCaptureError && error.code === code;

describe('captureActiveTab', () => {
  for (const target of ['chromium-mv3', 'firefox-mv3']) {
    it(`reads the active tab on ${target} and parses its <head> in the extension`, async () => {
      const { browser, calls } = articleBrowser({}, target);
      const capture = await captureActiveTab(browser, { now });

      assert.deepEqual(capture, {
        source: 'tab',
        url: 'https://example.com/article?utm_source=x&id=3#top',
        canonicalUrl: 'https://example.com/article?id=3',
        title: 'The article — Example',
        selectionText: 'A quoted line.',
        details: {
          version: 1,
          url: 'https://example.com/article?utm_source=x&id=3#top',
          canonicalUrl: 'https://example.com/article',
          title: 'The article',
          description: 'What it is about',
          language: 'en-GB',
          icons: [{ url: 'https://example.com/icon.png', rel: 'icon', sizes: '32x32' }],
          contentType: 'text/html'
        },
        capturedAt: '2026-10-31T12:00:00.000Z'
      });
      // Only the active tab of this window, one injection into it, and nothing else.
      assert.deepEqual(calls, [
        ['tabs.query', { active: true, currentWindow: true }],
        ['scripting.executeScript', { target: { tabId: 7 }, args: [MAX_DOCUMENT_BYTES, MAX_SELECTION_LENGTH, MAX_LANG_LENGTH] }]
      ]);
    });
  }

  it('sends at most 512 KB of <head> from the page, cut between characters', () => {
    // 'a' then four-byte characters, so the byte limit falls inside one unless the cut respects them.
    const head = `<head><meta name="description" content="a${'😀'.repeat(140_000)}"></head>`;
    const snapshot = runInPage(fakePage({ url: 'https://example.com/', head }), readPage, [MAX_DOCUMENT_BYTES, MAX_SELECTION_LENGTH, MAX_LANG_LENGTH]);
    assert.equal(Buffer.byteLength(snapshot.html), MAX_DOCUMENT_BYTES - 3);
    assert.ok(head.startsWith(snapshot.html));
    assert.ok(snapshot.html.isWellFormed());

    const small = runInPage(fakePage({ url: 'https://example.com/', head: HEAD }), readPage, [MAX_DOCUMENT_BYTES, MAX_SELECTION_LENGTH, MAX_LANG_LENGTH]);
    assert.equal(small.html, HEAD);
  });

  it('does not read a tag past 512 KB of <head>', async () => {
    const head = `<head><meta name="description" content="${'x'.repeat(MAX_DOCUMENT_BYTES)}"><meta property="og:title" content="Too late"></head>`;
    const capture = await captureActiveTab(articleBrowser({ head, title: '' }).browser, { now });
    assert.equal(capture.details.title, undefined);
    assert.equal(capture.title, capture.url);
  });

  it('bounds <html lang>, so a long one cannot push the head out of the parsed 512 KB', async () => {
    const lang = 'x'.repeat(600 * 1024);
    const snapshot = runInPage(fakePage({ url: 'https://example.com/', head: HEAD, lang }), readPage, [MAX_DOCUMENT_BYTES, MAX_SELECTION_LENGTH, MAX_LANG_LENGTH]);
    assert.equal(snapshot.lang.length, MAX_LANG_LENGTH + 1);

    // Even a page that ignores the bound and sends it all: the lang is dropped and the head is still read.
    const { browser } = articleBrowser();
    const snapshot600 = { url: 'https://example.com/', title: '', selectionText: '', html: HEAD, lang, contentType: 'text/html' };
    browser.raw.scripting.executeScript = async () => [{ frameId: 0, result: snapshot600 }];
    const capture = await captureActiveTab(browser, { now });
    assert.equal(capture.details.title, 'The article');
    assert.equal(capture.details.description, 'What it is about');
    assert.equal(capture.details.language, undefined);
    assert.equal(capture.title, 'The article');

    const fits = await captureActiveTab(articleBrowser({ lang: `en-${'a1b2c3d4-'.repeat(6)}x` }).browser, { now });
    assert.equal(fits.details.language, `en-${'a1b2c3d4-'.repeat(6)}x`);
  });

  it('keeps <html lang> safe when it holds markup', async () => {
    const { browser } = articleBrowser({ lang: '"><meta property="og:title" content="Injected' });
    const capture = await captureActiveTab(browser, { now });
    assert.equal(capture.details.title, 'The article');
    assert.equal(capture.details.language, undefined);
  });

  it('uses the document address, without credentials, rather than the tab address', async () => {
    const { browser } = articleBrowser({ url: 'https://user:secret@example.com/moved' });
    const capture = await captureActiveTab(browser, { now });
    assert.equal(capture.url, 'https://example.com/moved');
    assert.equal(capture.canonicalUrl, 'https://example.com/moved');
    assert.equal(capture.details.url, 'https://example.com/moved');
  });

  it('falls back from the tab title to the page details, then to the URL, and caps it', async () => {
    assert.equal((await captureActiveTab(articleBrowser({ title: ' \n ' }).browser, { now })).title, 'The article');
    const bare = articleBrowser({ title: '', head: '<head></head>' });
    assert.equal((await captureActiveTab(bare.browser, { now })).title, 'https://example.com/article?utm_source=x&id=3#top');
    const long = articleBrowser({ title: '𝒜'.repeat(MAX_TITLE_LENGTH + 10) });
    assert.equal((await captureActiveTab(long.browser, { now })).title, '𝒜'.repeat(MAX_TITLE_LENGTH));
  });

  it('omits an empty selection and caps a long one at whole characters', async () => {
    const empty = await captureActiveTab(articleBrowser({ selection: ' \n\t ' }).browser, { now });
    assert.equal('selectionText' in empty, false);
    const none = await captureActiveTab(articleBrowser({ selection: null }).browser, { now });
    assert.equal('selectionText' in none, false);
    const long = await captureActiveTab(articleBrowser({ selection: '𝒜'.repeat(MAX_SELECTION_LENGTH * 3) }).browser, { now });
    assert.equal(long.selectionText, '𝒜'.repeat(MAX_SELECTION_LENGTH));
  });

  it('reads a document without <head> and does not parse a non-HTML one', async () => {
    const headless = await captureActiveTab(articleBrowser({ head: null, title: 'Feed' }).browser, { now });
    assert.equal(headless.title, 'Feed');
    assert.deepEqual(headless.details.icons, [{ url: 'https://example.com/favicon.ico', rel: 'icon' }]);

    const image = await captureActiveTab(articleBrowser({ url: 'https://example.com/a.png', contentType: 'image/png', title: 'a.png (PNG Image)' }).browser, { now });
    assert.deepEqual(image.details, {
      version: 1,
      url: 'https://example.com/a.png',
      icons: [{ url: 'https://example.com/favicon.ico', rel: 'icon' }],
      contentType: 'image/png'
    });
  });

  it('refuses a browser or file tab without injecting into it', async () => {
    for (const url of ['chrome://newtab/', 'about:addons', 'file:///Users/me/notes.html', 'view-source:https://example.com/']) {
      const { browser, paths } = createFakeBrowser({ tabs: [{ id: 1, url }], page: fakePage({ url }) });
      await assert.rejects(captureActiveTab(browser), rejectsWith('unsupported-page'), url);
      assert.deepEqual(paths(), ['tabs.query'], url);
    }
  });

  it('refuses a page whose document is not http(s) when the tab URL is hidden', async () => {
    const { browser } = createFakeBrowser({ tabs: [{ id: 1 }], page: fakePage({ url: 'data:text/html,<p>hi' }) });
    await assert.rejects(captureActiveTab(browser), rejectsWith('unsupported-page'));
  });

  it('reports no active tab', async () => {
    await assert.rejects(captureActiveTab(createFakeBrowser({ tabs: [] }).browser), rejectsWith('no-active-tab'));
    await assert.rejects(captureActiveTab(createFakeBrowser({ tabs: [{ url: 'https://example.com/' }] }).browser), rejectsWith('no-active-tab'));
  });

  it('reports a page the browser will not inject into, keeping the cause', async () => {
    const refusal = new Error('Cannot access contents of the page. Extension manifest must request permission to access the respective host.');
    const { browser } = createFakeBrowser({ tabs: [{ id: 3, url: 'https://chromewebstore.google.com/' }], injectError: refusal });
    await assert.rejects(captureActiveTab(browser), (error) => rejectsWith('page-unavailable')(error) && error.cause === refusal);
  });

  it('reports a result that is not a page snapshot', async () => {
    for (const result of [undefined, null, 'html', { url: 'https://example.com/', title: 'x' }, { ...fakePage({ url: 'https://example.com/' }), html: 3 }]) {
      const { browser } = createFakeBrowser({ tabs: [{ id: 3, url: 'https://example.com/' }] });
      const raw = browser.raw;
      raw.scripting.executeScript = async () => [{ frameId: 0, result }];
      await assert.rejects(captureActiveTab(browser), rejectsWith('page-unavailable'), JSON.stringify(result));
    }
    const { browser } = createFakeBrowser({ tabs: [{ id: 3, url: 'https://example.com/' }] });
    browser.raw.scripting.executeScript = async () => [];
    await assert.rejects(captureActiveTab(browser), rejectsWith('page-unavailable'));
  });
});
