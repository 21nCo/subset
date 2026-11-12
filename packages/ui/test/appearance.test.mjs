import assert from 'node:assert/strict';
import test from 'node:test';
import { DEFAULT_APPEARANCE, appearanceAttributes, parseAppearance, resolveMode, serializeAppearance } from '../dist/index.js';

test('parseAppearance keeps known values and replaces anything else with defaults', () => {
  assert.deepEqual(parseAppearance(serializeAppearance({ family: 'graphite', mode: 'dark' })), { family: 'graphite', mode: 'dark' });
  for (const text of [null, undefined, '', 'not json', '42', '[]', 'null', '{"family":7,"mode":"sepia"}', '{"family":"neon"}']) {
    assert.deepEqual(parseAppearance(text), DEFAULT_APPEARANCE, String(text));
  }
  assert.deepEqual(parseAppearance('{"family":"mono","mode":"bright","extra":true}'), { family: 'mono', mode: 'system' });
});

test('resolveMode follows the system only in system mode', () => {
  assert.equal(resolveMode('system', true), 'dark');
  assert.equal(resolveMode('system', false), 'light');
  assert.equal(resolveMode('light', true), 'light');
  assert.equal(resolveMode('dark', false), 'dark');
});

test('appearanceAttributes names a known scheme and mode', () => {
  assert.deepEqual(appearanceAttributes({ family: 'solarized', mode: 'light' }), { 'data-ui-scheme': 'solarized', 'data-ui-mode': 'light' });
  assert.deepEqual(appearanceAttributes({ family: 'neon', mode: 'sepia' }), { 'data-ui-scheme': 'default', 'data-ui-mode': 'system' });
});
