import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { COLOR_TOKENS, COMPUTED_TOKENS, NUCLEUM_MAPPING, SCHEME_FAMILIES, SUBSET_ADJUSTMENTS, contrast, schemeFrom, schemesCss } from '../dist/index.js';

const nucleum = JSON.parse(readFileSync(new URL('../src/schemes/nucleum.json', import.meta.url), 'utf8'));
const schemes = SCHEME_FAMILIES.flatMap((family) => [['light', family.light, family], ['dark', family.dark, family]]);

test('every family has a light and a dark scheme that define every token', () => {
  assert.deepEqual(SCHEME_FAMILIES.map((family) => family.id), ['default', 'mono', 'graphite', 'solarized']);
  for (const [mode, scheme, family] of schemes) {
    assert.equal(scheme.mode, mode, `${family.id} ${mode} is a ${scheme.mode} scheme`);
    assert.deepEqual(Object.keys(scheme.colors).sort(), [...COLOR_TOKENS].sort(), `${family.id} ${mode}`);
    for (const value of Object.values(scheme.colors)) assert.match(value, /^hsl\(/);
  }
});

test('the mapping covers every token except the computed accent contrast, and every ported scheme has its slots', () => {
  assert.deepEqual(Object.keys(NUCLEUM_MAPPING).sort(), COLOR_TOKENS.filter((token) => !COMPUTED_TOKENS.includes(token)).sort());
  for (const source of Object.keys(nucleum.schemes)) assert.doesNotThrow(() => schemeFrom(source), source);
  // Graphite has Nucleum's frame palette (TIDY-511); the others fall back to their content colours.
  const graphite = schemeFrom('clean_graphite_light');
  assert.equal(graphite.colors['frame-surface'], nucleum.schemes.clean_graphite_light.colors.fbgs1);
  const blue = schemeFrom('clean_tidyblue_light');
  assert.equal(blue.colors['frame-surface'], nucleum.schemes.clean_tidyblue_light.colors.bgs1);
  assert.throws(() => schemeFrom('nope'), /Unknown Nucleum scheme/);
  // The only departures from Nucleum are the listed contrast adjustments.
  assert.deepEqual(Object.keys(SUBSET_ADJUSTMENTS), ['clean_solarized_dark']);
  assert.equal(schemeFrom('clean_solarized_dark').colors['text-secondary'], SUBSET_ADJUSTMENTS.clean_solarized_dark.fgs2);
});

test('text and accent pairs are readable in every scheme', () => {
  const failures = [];
  const check = (label, fg, bg, min) => {
    const ratio = contrast(fg, bg);
    if (ratio < min) failures.push(`${label}: ${ratio.toFixed(2)} < ${min}`);
  };
  for (const [mode, { colors }, family] of schemes) {
    const name = `${family.id} ${mode}`;
    for (const surface of ['surface-canvas', 'surface-raised']) {
      check(`${name} text-primary on ${surface}`, colors['text-primary'], colors[surface], 4.5);
      check(`${name} text-secondary on ${surface}`, colors['text-secondary'], colors[surface], 4.5);
      check(`${name} text-muted on ${surface}`, colors['text-muted'], colors[surface], 3);
    }
    check(`${name} accent-contrast on accent-solid`, colors['accent-contrast'], colors['accent-solid'], 4.5);
    check(`${name} accent-on-soft on accent-soft`, colors['accent-on-soft'], colors['accent-soft'], 4.5);
    check(`${name} success-on-subtle on success-subtle`, colors['success-on-subtle'], colors['success-subtle'], 4.5);
    check(`${name} danger-on-subtle on danger-subtle`, colors['danger-on-subtle'], colors['danger-subtle'], 4.5);
    check(`${name} frame-text on frame-surface`, colors['frame-text'], colors['frame-surface'], 4.5);
  }
  assert.deepEqual(failures, []);
});

test('contrast() matches known WCAG ratios', () => {
  assert.equal(contrast('hsl(0 0% 100%)', 'hsl(0 0% 0%)').toFixed(1), '21.0');
  assert.equal(contrast('hsl(0 0% 50%)', 'hsl(0 0% 100%)').toFixed(2), '3.98');
});

test('the checked-in schemes.css is what the generator writes', () => {
  const css = readFileSync(new URL('../src/styles/schemes.css', import.meta.url), 'utf8');
  assert.equal(css, schemesCss(), 'Run npm run schemes --workspace=@subset.dev/ui');
  assert.match(css, /\[data-ui-scheme='graphite'\]\[data-ui-mode='dark'\] \{\n {2}color-scheme: dark;/);
  assert.match(css, /@media \(prefers-color-scheme: dark\) \{\n {2}\[data-ui-scheme='default'\]\[data-ui-mode='system'\],\n {2}\.ui-root:not\(\[data-ui-scheme\]\)/);
});
