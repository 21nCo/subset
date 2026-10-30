import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { draftEdits, initialPopupState, parseTags, popupTransition } from '../dist/index.js';

const capture = {
  source: 'tab',
  url: 'https://example.com/a',
  canonicalUrl: 'https://example.com/a',
  title: 'A page',
  selectionText: 'A quote',
  details: { version: 1, url: 'https://example.com/a', icons: [], contentType: 'text/html' },
  capturedAt: '2026-10-31T12:00:00.000Z'
};
const draft = { title: 'A page', notes: 'A quote', tags: '' };
const editing = { name: 'editing', capture, draft };
const saving = { name: 'saving', capture, draft };
const saveError = { name: 'error', error: { stage: 'save', message: 'Server said no' }, capture, draft };
const captureError = { name: 'error', error: { stage: 'capture', message: 'Could not read' } };
const targetError = { name: 'error', error: { stage: 'target', message: 'Connect first', needsSetup: true } };
const saved = { name: 'saved', capture, draft, existing: false };

const ALL_EVENTS = [
  { type: 'start' },
  { type: 'captured', capture },
  { type: 'captureFailed', message: 'x' },
  { type: 'targetUnavailable', status: { state: 'error', message: 'x' } },
  { type: 'edit', draft: { title: 'x' } },
  { type: 'save' },
  { type: 'saved', result: { ok: true } },
  { type: 'saveFailed', message: 'x' },
  { type: 'retry' },
  { type: 'back' }
];

// Every transition the flow allows; any other (state, event) pair must leave the state untouched.
const TRANSITIONS = [
  [initialPopupState, { type: 'start' }, { name: 'capturing' }],
  [{ name: 'capturing' }, { type: 'captured', capture }, editing],
  [{ name: 'capturing' }, { type: 'captureFailed', message: 'Could not read' }, captureError],
  [{ name: 'capturing' }, { type: 'targetUnavailable', status: { state: 'needs-setup', message: 'Connect first' } }, targetError],
  [{ name: 'capturing' }, { type: 'targetUnavailable', status: { state: 'error', message: 'Server down' } }, { name: 'error', error: { stage: 'target', message: 'Server down' } }],
  [editing, { type: 'edit', draft: { title: 'x' } }, { ...editing, draft: { ...draft, title: 'x' } }],
  [editing, { type: 'save' }, saving],
  [saving, { type: 'saved', result: { ok: true } }, saved],
  [saving, { type: 'saveFailed', message: 'Server said no' }, saveError],
  [saveError, { type: 'retry' }, saving],
  [saveError, { type: 'back' }, editing],
  [captureError, { type: 'retry' }, { name: 'capturing' }],
  [targetError, { type: 'retry' }, { name: 'capturing' }]
];

describe('popupTransition', () => {
  for (const [state, event, expected] of TRANSITIONS) {
    it(`${state.name}${state.error ? `(${state.error.stage})` : ''} + ${event.type} → ${expected.name}`, () => {
      assert.deepEqual(popupTransition(state, event), expected);
    });
  }

  it('ignores every other event, returning the same state object', () => {
    const states = [initialPopupState, { name: 'capturing' }, editing, saving, saved, saveError, captureError, targetError];
    let ignored = 0;
    for (const state of states) {
      for (const event of ALL_EVENTS) {
        if (TRANSITIONS.some(([from, on]) => from === state && on.type === event.type)) continue;
        if (state.name === 'capturing' && ['captured', 'captureFailed', 'targetUnavailable'].includes(event.type)) continue;
        assert.equal(popupTransition(state, event), state, `${state.name} + ${event.type}`);
        ignored++;
      }
    }
    assert.ok(ignored > 60);
  });

  it('saves once: a second save while saving, or a late result after it settled, changes nothing', () => {
    assert.equal(popupTransition(saving, { type: 'save' }), saving);
    assert.equal(popupTransition(saved, { type: 'saveFailed', message: 'late' }), saved);
    assert.equal(popupTransition(editing, { type: 'saved', result: { ok: true } }), editing);
  });

  it('reports an existing bookmark and keeps only an http(s) link to it', () => {
    assert.deepEqual(popupTransition(saving, { type: 'saved', result: { ok: true, existing: true, openUrl: 'https://bookmarks.example.com/b/1' } }), {
      ...saved,
      existing: true,
      openUrl: 'https://bookmarks.example.com/b/1'
    });
    for (const openUrl of ['javascript:alert(1)', 'data:text/html,x', 'not a url', 42]) {
      assert.deepEqual(popupTransition(saving, { type: 'saved', result: { ok: true, openUrl } }), saved, String(openUrl));
    }
  });

  it('starts the draft from the capture, with the selection as notes', () => {
    const { selectionText, ...withoutSelection } = capture;
    assert.deepEqual(popupTransition({ name: 'capturing' }, { type: 'captured', capture: withoutSelection }).draft, { title: 'A page', notes: '', tags: '' });
  });

  it('edits only the draft fields', () => {
    const next = popupTransition(editing, { type: 'edit', draft: { tags: 'a, b', notes: 'n', title: undefined, url: 'https://evil.example/' } });
    assert.deepEqual(next.draft, { title: 'A page', notes: 'n', tags: 'a, b' });
    assert.equal(next.capture, capture);
  });

  it('uses a default message when a target needing setup gives none', () => {
    const next = popupTransition({ name: 'capturing' }, { type: 'targetUnavailable', status: { state: 'needs-setup' } });
    assert.deepEqual(next.error, { stage: 'target', message: 'Connect this extension before saving.', needsSetup: true });
  });
});

describe('draftEdits and parseTags', () => {
  it('trims fields and omits empty ones', () => {
    assert.deepEqual(draftEdits({ title: '  A \n title ', notes: '\n note \n', tags: ' read later, Dev ,, dev ' }), {
      title: 'A title',
      notes: 'note',
      tags: ['read later', 'Dev']
    });
    assert.deepEqual(draftEdits({ title: ' ', notes: '', tags: ' , ' }), {});
  });

  it('splits on commas, collapses whitespace and keeps the first spelling of a repeated tag', () => {
    assert.deepEqual(parseTags('Rust,  web   dev ,RUST, ,web dev'), ['Rust', 'web dev']);
    assert.deepEqual(parseTags(''), []);
  });
});
