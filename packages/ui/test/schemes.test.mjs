import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { COLOR_TOKENS, COMPUTED_TOKENS, NUCLEUM_MAPPING, SCHEME_FAMILIES, TEXT_SURFACES, contrast, ensureContrast, schemeAdjustments, schemeFrom, schemesCss } from '../dist/index.js';

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
  // The only departures from Nucleum's colours are text lightened or darkened to reach Subset's contrast. A change
  // here means a ported scheme changed: check the new values read well before updating the list.
  assert.deepEqual(schemeAdjustments().map(({ source, token, from, to }) => `${source} ${token} ${from} -> ${to}`), [
    'clean_solarized_dark text-primary hsl(180 7% 60%) -> hsl(180 7% 74%)',
    'clean_solarized_dark text-secondary hsl(186 8% 55%) -> hsl(186 8% 68%)',
    'clean_solarized_dark text-muted hsl(196 13% 45%) -> hsl(196 13% 55%)'
  ]);
});

test('every text colour is readable on every surface it can sit on, in every scheme', () => {
  const failures = [];
  const check = (label, fg, bg, min) => {
    const ratio = contrast(fg, bg);
    if (ratio < min) failures.push(`${label}: ${ratio.toFixed(2)} < ${min}`);
  };
  for (const [mode, { colors }, family] of schemes) {
    const name = `${family.id} ${mode}`;
    for (const surface of TEXT_SURFACES) {
      check(`${name} text-primary on ${surface}`, colors['text-primary'], colors[surface], 4.5);
      for (const tone of ['accent', 'secondary', 'success', 'danger']) check(`${name} ${tone}-text on ${surface}`, colors[`${tone}-text`], colors[surface], 4.5);
      // Hovered controls switch to primary text.
      if (surface === 'surface-hover') continue;
      check(`${name} text-secondary on ${surface}`, colors['text-secondary'], colors[surface], 4.5);
      check(`${name} text-muted on ${surface}`, colors['text-muted'], colors[surface], 3);
    }
    for (const tone of ['accent', 'secondary', 'success', 'danger']) check(`${name} ${tone}-contrast on ${tone}-solid`, colors[`${tone}-contrast`], colors[`${tone}-solid`], 4.5);
    check(`${name} accent-on-soft on accent-soft`, colors['accent-on-soft'], colors['accent-soft'], 4.5);
    check(`${name} success-on-subtle on success-subtle`, colors['success-on-subtle'], colors['success-subtle'], 4.5);
    check(`${name} danger-on-subtle on danger-subtle`, colors['danger-on-subtle'], colors['danger-subtle'], 4.5);
    check(`${name} frame-text on frame-surface`, colors['frame-text'], colors['frame-surface'], 4.5);
  }
  assert.deepEqual(failures, []);
});

test('ensureContrast keeps hue and saturation and moves lightness away from the surfaces', () => {
  assert.equal(ensureContrast('hsl(0 0% 20%)', ['hsl(0 0% 100%)'], 4.5), 'hsl(0 0% 20%)');
  const darkened = ensureContrast('hsl(0 89% 71%)', ['hsl(0 0% 100%)', 'hsl(228 26% 98%)'], 4.5);
  assert.match(darkened, /^hsl\(0 89% (\d+)%\)$/);
  assert.ok(contrast(darkened, 'hsl(228 26% 98%)') >= 4.5);
  const lightened = ensureContrast('hsl(0 70% 40%)', ['hsl(0 0% 8%)'], 4.5);
  assert.ok(Number(/(\d+)%\)$/.exec(lightened)[1]) > 40 && contrast(lightened, 'hsl(0 0% 8%)') >= 4.5);
  assert.equal(ensureContrast('hsl(37, 72%, 52%)', ['hsl(0 0% 100%)'], 1), 'hsl(37, 72%, 52%)');
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
