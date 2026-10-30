import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { captureActiveTab, createCapturePopupController, LinkCaptureError } from '../dist/index.js';
import { createFakeBrowser, fakePage } from './fake-browser.mjs';

const capture = {
  source: 'link',
  url: 'https://example.com/a',
  canonicalUrl: 'https://example.com/a',
  title: 'A page',
  selectionText: 'A quote',
  capturedAt: '2026-10-31T12:00:00.000Z'
};

/** A target whose answers the test sets; it records every save. */
function fakeTarget({ status = { state: 'connected' }, save = { ok: true }, suggest } = {}) {
  const saves = [];
  return {
    saves,
    id: 'test',
    label: 'Test target',
    status: async () => (typeof status === 'function' ? status() : status),
    save: async (...args) => {
      saves.push(args);
      return typeof save === 'function' ? save(saves.length) : save;
    },
    ...(suggest ? { suggestTags: suggest } : {})
  };
}

async function started(target, captureFn = async () => capture) {
  const controller = createCapturePopupController({ target, capture: captureFn });
  const names = [];
  controller.subscribe((state) => names.push(state.name));
  await controller.start();
  return { controller, names };
}

describe('createCapturePopupController', () => {
  it('captures the current tab, edits and saves it to the target', async () => {
    const { browser } = createFakeBrowser({
      tabs: [{ id: 1, url: 'https://example.com/a' }],
      page: fakePage({ url: 'https://example.com/a', title: 'A page', selection: 'A quote' })
    });
    const target = fakeTarget({ save: { ok: true, openUrl: 'https://bookmarks.example.com/b/1' } });
    const { controller, names } = await started(target, () => captureActiveTab(browser));
    assert.equal(controller.state.name, 'editing');
    assert.deepEqual(controller.state.draft, { title: 'A page', notes: 'A quote', tags: '' });

    controller.edit({ tags: 'reading, dev' });
    await controller.save();
    assert.deepEqual(names, ['capturing', 'editing', 'editing', 'saving', 'saved']);
    assert.equal(target.saves.length, 1);
    const [savedCapture, edits] = target.saves[0];
    assert.equal(savedCapture.url, 'https://example.com/a');
    assert.deepEqual(edits, { title: 'A page', notes: 'A quote', tags: ['reading', 'dev'] });
    assert.deepEqual(controller.state, { name: 'saved', capture: savedCapture, draft: { title: 'A page', notes: 'A quote', tags: 'reading, dev' }, existing: false, openUrl: 'https://bookmarks.example.com/b/1' });
  });

  it('saves cleared notes as cleared, so a target never restores the selected text', async () => {
    // Even a target that wrongly falls back to the selection for omitted notes keeps them cleared: they are sent empty.
    const stored = [];
    const target = fakeTarget({
      save: (count) => {
        const [saved, edits] = target.saves[count - 1];
        stored.push({ title: edits.title ?? saved.title, notes: edits.notes ?? saved.selectionText, tags: edits.tags ?? [] });
        return { ok: true };
      }
    });
    const { controller } = await started(target);
    assert.equal(controller.state.draft.notes, 'A quote');
    controller.edit({ title: ' ', notes: '' });
    await controller.save();
    assert.deepEqual(target.saves[0][1], { notes: '', tags: [] });
    assert.deepEqual(stored, [{ title: 'A page', notes: '', tags: [] }]);
  });

  it('shows an existing bookmark as already saved', async () => {
    const { controller } = await started(fakeTarget({ save: { ok: true, existing: true } }));
    await controller.save();
    assert.equal(controller.state.name, 'saved');
    assert.equal(controller.state.existing, true);
  });

  it('saves once when save is pressed again while saving', async () => {
    let finish;
    const target = fakeTarget({ save: () => new Promise((resolve) => (finish = resolve)) });
    const { controller } = await started(target);
    const first = controller.save();
    await controller.save();
    finish({ ok: true });
    await first;
    assert.equal(target.saves.length, 1);
    assert.equal(controller.state.name, 'saved');
  });

  it('keeps the draft through a refused save, then retries or goes back to the form', async () => {
    const target = fakeTarget({ save: (count) => (count === 1 ? { ok: false, error: 'Token expired' } : { ok: true }) });
    const { controller } = await started(target);
    controller.edit({ title: 'Edited' });
    await controller.save();
    assert.deepEqual(controller.state.error, { stage: 'save', message: 'Token expired' });
    assert.equal(controller.state.draft.title, 'Edited');

    controller.back();
    assert.equal(controller.state.name, 'editing');
    assert.equal(controller.state.draft.title, 'Edited');
    await controller.save();
    assert.equal(controller.state.name, 'saved');
    assert.equal(target.saves[1][1].title, 'Edited');
  });

  it('retries a failed save directly', async () => {
    const target = fakeTarget({ save: (count) => (count === 1 ? Promise.reject(new TypeError('Failed to fetch')) : { ok: true }) });
    const { controller } = await started(target);
    await controller.save();
    assert.deepEqual(controller.state.error, { stage: 'save', message: 'Failed to fetch' });
    await controller.retry();
    assert.equal(controller.state.name, 'saved');
    assert.equal(target.saves.length, 2);
  });

  it('uses a default message for a save error without one', async () => {
    for (const save of [{ ok: false, error: '' }, () => Promise.reject('no Error')]) {
      const { controller } = await started(fakeTarget({ save }));
      await controller.save();
      assert.equal(controller.state.error.message, 'The link was not saved.');
    }
  });

  it('stops before editing when the target needs setup, even though the page was read', async () => {
    const { controller, names } = await started(fakeTarget({ status: { state: 'needs-setup', message: 'Add your server in Options.' } }));
    assert.deepEqual(names, ['capturing', 'error']);
    assert.deepEqual(controller.state.error, { stage: 'target', message: 'Add your server in Options.', needsSetup: true });
    const bare = await started(fakeTarget({ status: { state: 'needs-setup', message: 7 } }));
    assert.deepEqual(bare.controller.state.error, { stage: 'target', message: 'Connect this extension before saving.', needsSetup: true });
  });

  it('reports a target whose status fails, throws or is malformed as a target error', async () => {
    const cases = [
      [{ state: 'error', message: 'Server unreachable' }, 'Server unreachable'],
      [() => Promise.reject(new Error('boom')), 'boom'],
      [() => {
        throw new Error('sync boom');
      }, 'sync boom'],
      [undefined, 'Test target is unavailable.'],
      [{ state: 'online' }, 'Test target is unavailable.'],
      [{ state: 'error' }, 'Test target is unavailable.'],
      [{ state: 'error', message: { html: '<b>x</b>' } }, 'Test target is unavailable.']
    ];
    for (const [status, message] of cases) {
      const target = fakeTarget();
      target.status = typeof status === 'function' ? status : async () => status;
      const { controller } = await started(target);
      assert.deepEqual(controller.state.error, { stage: 'target', message }, message);
    }
  });

  it('explains each capture failure, then captures again on retry', async () => {
    const messages = {
      'no-active-tab': 'There is no tab to save.',
      'unsupported-page': 'Only web pages (http and https) can be saved.',
      'page-unavailable': 'This page could not be read. Reload it and try again.'
    };
    for (const [code, message] of Object.entries(messages)) {
      const { controller } = await started(fakeTarget(), async () => {
        throw new LinkCaptureError(code);
      });
      assert.deepEqual(controller.state.error, { stage: 'capture', message });
    }
    // An error from another copy of the package (the popup and its host bundle it separately) is recognised too.
    const copy = Object.assign(new Error('Link capture failed: unsupported-page'), { name: 'LinkCaptureError', code: 'unsupported-page' });
    const fromCopy = await started(fakeTarget(), async () => Promise.reject(copy));
    assert.equal(fromCopy.controller.state.error.message, messages['unsupported-page']);
    for (const code of ['toString', '__proto__', 'other']) {
      const odd = Object.assign(new Error('x'), { name: 'LinkCaptureError', code });
      const { controller } = await started(fakeTarget(), async () => Promise.reject(odd));
      assert.equal(controller.state.error.message, messages['page-unavailable'], code);
    }
    let attempts = 0;
    const { controller } = await started(fakeTarget(), async () => {
      if (++attempts === 1) throw new Error('unexpected');
      return capture;
    });
    assert.equal(controller.state.error.message, messages['page-unavailable']);
    await controller.retry();
    assert.equal(controller.state.name, 'editing');
  });

  it('starts once', async () => {
    let captures = 0;
    const { controller } = await started(fakeTarget(), async () => (captures++, capture));
    await controller.start();
    assert.equal(captures, 1);
  });

  it('passes tag suggestions through and treats a missing or failing suggester as none', async () => {
    const suggest = async (prefix) => [`${prefix}one`, '', 3, ' ', `${prefix}two`];
    assert.deepEqual(await (await started(fakeTarget({ suggest }))).controller.suggestTags('re'), ['reone', 'retwo']);
    assert.deepEqual(await (await started(fakeTarget())).controller.suggestTags('re'), []);
    // The popup keys its list by tag, so a repeat (also one that differs only in spaces) is returned once.
    const repeating = async () => ['reading', ' reading ', 'research', 'reading'];
    assert.deepEqual(await (await started(fakeTarget({ suggest: repeating }))).controller.suggestTags('re'), ['reading', 'research']);
    const failing = async () => {
      throw new Error('offline');
    };
    assert.deepEqual(await (await started(fakeTarget({ suggest: failing }))).controller.suggestTags('re'), []);
  });

  it('stops notifying after unsubscribe', async () => {
    const controller = createCapturePopupController({ target: fakeTarget(), capture: async () => capture });
    const seen = [];
    const unsubscribe = controller.subscribe((state) => seen.push(state.name));
    unsubscribe();
    await controller.start();
    assert.deepEqual(seen, []);
    assert.equal(controller.state.name, 'editing');
  });
});
