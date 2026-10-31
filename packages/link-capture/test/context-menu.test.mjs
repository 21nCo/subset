import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { captureFromContextMenu, captureLink, LINK_CONTEXT_MENU_ID, LinkCaptureError, registerLinkContextMenu, saveFromContextMenu } from '../dist/index.js';
import { createFakeBrowser } from './fake-browser.mjs';

const now = () => new Date('2026-10-31T12:00:00.000Z');

describe('the link context menu', () => {
  it('adds one item on http(s) links, and can be registered again on every start', async () => {
    const { browser, calls, menus } = createFakeBrowser();
    await registerLinkContextMenu(browser, { title: 'Save link to Bookmarks' });
    await registerLinkContextMenu(browser, { title: 'Save link to Bookmarks' });
    const item = { id: LINK_CONTEXT_MENU_ID, title: 'Save link to Bookmarks', contexts: ['link'], targetUrlPatterns: ['http://*/*', 'https://*/*'] };
    assert.deepEqual(calls, [
      ['contextMenus.remove', LINK_CONTEXT_MENU_ID],
      ['contextMenus.create', item],
      ['contextMenus.remove', LINK_CONTEXT_MENU_ID],
      ['contextMenus.create', item]
    ]);
    assert.deepEqual([...menus], [LINK_CONTEXT_MENU_ID]);
  });

  it('keeps an item that survived a service worker restart and leaves other items alone', async () => {
    const { browser, menus } = createFakeBrowser({ menuItems: ['host:other', 'memotron:save'] });
    await registerLinkContextMenu(browser, { id: 'memotron:save', title: 'Save to Memotron' });
    assert.deepEqual([...menus].sort(), ['host:other', 'memotron:save']);
  });

  it('captures the clicked link from the click data alone: no tab query, no injection', () => {
    const { calls } = createFakeBrowser();
    const capture = captureFromContextMenu(
      { menuItemId: LINK_CONTEXT_MENU_ID, linkUrl: 'https://Example.com:443/post?fbclid=1#comments', linkText: '  A\n post ' },
      { now }
    );
    assert.deepEqual(capture, {
      source: 'link',
      url: 'https://example.com/post?fbclid=1#comments',
      canonicalUrl: 'https://example.com/post',
      title: 'A post',
      capturedAt: '2026-10-31T12:00:00.000Z'
    });
    assert.equal('details' in capture, false);
    assert.deepEqual(calls, []);
  });

  it('titles a link by its URL when the browser gives no link text (Chromium)', () => {
    const capture = captureFromContextMenu({ menuItemId: LINK_CONTEXT_MENU_ID, linkUrl: 'https://example.com/a' }, { now });
    assert.equal(capture.title, 'https://example.com/a');
  });

  it('drops half a surrogate pair from the link text', () => {
    const capture = captureLink('https://example.com/a', ` \uDC00A\uD83D post 😀\uD83D`);
    assert.equal(capture.title, 'A post 😀');
    assert.ok(capture.title.isWellFormed());
  });

  it('ignores another menu item and honours a custom id', () => {
    assert.equal(captureFromContextMenu({ menuItemId: 'host:other', linkUrl: 'https://example.com/' }), undefined);
    const capture = captureFromContextMenu({ menuItemId: 'memotron:save', linkUrl: 'https://example.com/' }, { id: 'memotron:save' });
    assert.equal(capture.url, 'https://example.com/');
  });

  it('refuses a link that is not http(s), and drops credentials from one that is', () => {
    for (const url of ['javascript:alert(1)', 'mailto:a@example.com', 'ftp://example.com/f', 'not a url', '', undefined]) {
      assert.throws(
        () => captureFromContextMenu({ menuItemId: LINK_CONTEXT_MENU_ID, linkUrl: url }),
        (error) => error instanceof LinkCaptureError && error.code === 'unsupported-page',
        String(url)
      );
    }
    assert.equal(captureLink('https://me:pw@example.com/x').url, 'https://example.com/x');
  });

  describe('saving a clicked link', () => {
    const click = { menuItemId: LINK_CONTEXT_MENU_ID, linkUrl: 'https://example.com/a', linkText: 'A' };
    const target = (save) => ({ id: 't', label: 'Bookmarks', status: async () => ({ state: 'connected' }), save });
    const reported = (calls) => calls.filter(([path]) => path.startsWith('action.')).map(([, details]) => details.text ?? details.title);

    for (const [name, save, outcome] of [
      ['saved', async () => ({ ok: true }), { state: 'saved', existing: false, message: 'Saved to Bookmarks.' }],
      ['already saved', async () => ({ ok: true, existing: true }), { state: 'saved', existing: true, message: 'Already in Bookmarks.' }],
      ['refused before writing', async () => ({ ok: false, error: 'No room.' }), { state: 'not-saved', message: 'No room.' }],
      ['a malformed result', async () => undefined, { state: 'not-saved', message: 'The link was not saved.' }],
      ['a rejected save', async () => { throw new Error('connection reset'); }, { state: 'unknown', message: 'The link may not have been saved to Bookmarks: connection reset' }],
      ['a save that throws', () => { throw new Error('boom'); }, { state: 'unknown', message: 'The link may not have been saved to Bookmarks: boom' }]
    ]) {
      it(`reports ${name} on the toolbar button and never rejects`, async () => {
        const { browser, calls } = createFakeBrowser();
        assert.deepEqual(await saveFromContextMenu(browser, target(save), click), outcome);
        assert.deepEqual(reported(calls), [{ saved: '✓', 'not-saved': '!', unknown: '?' }[outcome.state], outcome.message]);
      });
    }

    for (const failing of ['setBadgeText', 'setTitle']) {
      it(`still reports each outcome when action.${failing} is refused`, async () => {
        for (const [save, badge, message] of [
          [async () => ({ ok: true }), '✓', 'Saved to Bookmarks.'],
          [async () => ({ ok: false, error: 'No room.' }), '!', 'No room.'],
          [async () => { throw new Error('reset'); }, '?', 'The link may not have been saved to Bookmarks: reset']
        ]) {
          const { browser, calls } = createFakeBrowser();
          browser.raw.action[failing] = async () => { throw new Error('No tab with id'); };
          const outcome = await saveFromContextMenu(browser, target(save), click);
          assert.equal(outcome.message, message);
          // The facade records only the call that went through: the other channel was still set.
          assert.deepEqual(reported(calls), failing === 'setBadgeText' ? [message] : [badge]);
        }
      });
    }

    it('reports a non-http link as not saved without calling the target, and ignores other items', async () => {
      const { browser, calls } = createFakeBrowser();
      const saves = [];
      const outcome = await saveFromContextMenu(browser, target(async (capture) => saves.push(capture)), { ...click, linkUrl: 'javascript:x' });
      assert.equal(outcome.state, 'not-saved');
      assert.equal(await saveFromContextMenu(browser, target(async (capture) => saves.push(capture)), { ...click, menuItemId: 'other' }), undefined);
      assert.deepEqual([saves, reported(calls)], [[], ['!', 'Only web pages (http and https) can be saved.']]);
    });
  });
});
