// Colour schemes for every Subset view. The colours are Nucleum's scheme data (`schemes/nucleum.json`), mapped
// onto uifn-style semantic token names so Subset views never name a raw palette slot and can move onto uifn
// later without renaming anything.
import nucleum from './schemes/nucleum.json' with { type: 'json' };

/** Every colour token a scheme defines, as the CSS custom property `--ui-color-<token>`. */
export const COLOR_TOKENS = [
  'surface-canvas', 'surface-raised', 'surface-sunken', 'surface-overlay', 'surface-hover',
  'text-primary', 'text-secondary', 'text-muted', 'text-disabled',
  'border-subtle', 'border-default', 'border-strong',
  'accent-solid', 'accent-subtle', 'accent-soft', 'accent-contrast', 'accent-on-soft', 'accent-text',
  'secondary-solid', 'secondary-subtle', 'secondary-contrast', 'secondary-text',
  'success-solid', 'success-subtle', 'success-contrast', 'success-on-subtle', 'success-text',
  'danger-solid', 'danger-subtle', 'danger-contrast', 'danger-on-subtle', 'danger-text',
  'frame-surface', 'frame-text', 'frame-border', 'frame-accent'
] as const;
export type ColorToken = (typeof COLOR_TOKENS)[number];

type NucleumScheme = { label: string; isDark: boolean; hasFramePalette: boolean; colors: Record<string, string> };
const SOURCE = nucleum.schemes as Record<string, NucleumScheme>;

/** Text colours computed for readability on a tinted background, rather than taken from a Nucleum slot. */
export const COMPUTED_TOKENS = [
  'accent-contrast', 'accent-on-soft', 'accent-text',
  'secondary-contrast', 'secondary-text',
  'success-contrast', 'success-on-subtle', 'success-text',
  'danger-contrast', 'danger-on-subtle', 'danger-text'
] as const;
type ComputedToken = (typeof COMPUTED_TOKENS)[number];

/**
 * Which Nucleum palette slot each token takes, in order of preference. Frame tokens use Nucleum's frame palette
 * (TIDY-511) when the scheme has one, else the content colours. The `COMPUTED_TOKENS` have no slot.
 */
export const NUCLEUM_MAPPING: Record<Exclude<ColorToken, ComputedToken>, string[]> = {
  // Nucleum's bgs1 is a scheme's base background and each higher slot is one level of nesting deeper
  // (`bg(parentBgIndex)` in @21n/ui), so cards on the page take bgs2.
  'surface-canvas': ['bgs1'],
  'surface-raised': ['bgs2'],
  'surface-sunken': ['bgs3'],
  'surface-overlay': ['bgs1'],
  'surface-hover': ['bgs4'],
  'text-primary': ['fgs1'],
  'text-secondary': ['fgs2'],
  'text-muted': ['fgs3'],
  'text-disabled': ['fgs4'],
  'border-subtle': ['brs2'],
  'border-default': ['brs3'],
  'border-strong': ['brs4'],
  'accent-solid': ['aps1'],
  'accent-subtle': ['aps2'],
  'accent-soft': ['aps3'],
  'secondary-solid': ['ass1'],
  'secondary-subtle': ['ass2'],
  'success-solid': ['ags1'],
  'success-subtle': ['ags2'],
  'danger-solid': ['ars1'],
  'danger-subtle': ['ars2'],
  'frame-surface': ['fbgs1', 'bgs1'],
  'frame-text': ['ffgs1', 'fgs1'],
  'frame-border': ['fbrs3', 'brs3'],
  'frame-accent': ['faps1', 'aps1']
};

/** Surfaces that text can sit on, directly or as a nested control (hover holds primary text only). */
export const TEXT_SURFACES = ['surface-canvas', 'surface-raised', 'surface-sunken', 'surface-hover', 'surface-overlay'] as const;

/** The contrast Subset requires for body text and tone-coloured text (4.5:1), and for muted hints (3:1). */
export const TEXT_CONTRAST = 4.5;
export const MUTED_CONTRAST = 3;

/** A token whose Nucleum colour was moved to reach Subset's contrast; `schemeAdjustments()` lists them. */
export interface SchemeAdjustment {
  source: string;
  token: ColorToken;
  from: string;
  to: string;
}

export type SchemeMode = 'light' | 'dark';

export interface Scheme {
  /** The Nucleum scheme it comes from, such as `clean_tidyblue_light`. */
  source: string;
  label: string;
  mode: SchemeMode;
  colors: Record<ColorToken, string>;
}

/** A scheme family pairs a light and a dark scheme, as Nucleum's scheme families do (TIDY-513). */
export interface SchemeFamily {
  id: string;
  label: string;
  light: Scheme;
  dark: Scheme;
}

// --- Colour arithmetic, for the accent contrast token and the contrast tests ----------------------------------

/** sRGB channels 0-1 of an `hsl()` colour. */
export function hslToRgb(value: string): [number, number, number] {
  const [hue, saturation, lightness] = hslParts(value);
  const h = hue / 360;
  const s = saturation / 100;
  const l = lightness / 100;
  const k = (n: number) => (n + h * 12) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) => l - a * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1));
  return [f(0), f(8), f(4)];
}

/** WCAG relative luminance of an `hsl()` colour. */
export function luminance(value: string): number {
  const [r, g, b] = hslToRgb(value).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** WCAG contrast ratio between two `hsl()` colours. */
export function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

function hslParts(value: string): [number, number, number] {
  // Nucleum writes both the space-separated and the older comma-separated form.
  const match = /^hsl\(\s*([\d.]+)[\s,]+([\d.]+)%[\s,]+([\d.]+)%\s*\)$/.exec(value.trim());
  if (!match) throw new Error(`Not an hsl() colour: ${value}`);
  return [Number(match[1]), Number(match[2]), Number(match[3])];
}

/**
 * `color`, or the nearest colour of the same hue and saturation that reaches `min` contrast against every one of
 * `backgrounds`: lightness moves away from the backgrounds (darker on light surfaces, lighter on dark ones) one
 * percentage point at a time.
 */
export function ensureContrast(color: string, backgrounds: string[], min: number): string {
  const passes = (candidate: string) => backgrounds.every((background) => contrast(candidate, background) >= min);
  if (passes(color)) return color;
  const [h, s, l] = hslParts(color);
  const darkSurfaces = backgrounds.reduce((sum, background) => sum + luminance(background), 0) / backgrounds.length < 0.18;
  const step = darkSurfaces ? 1 : -1;
  for (let lightness = Math.round(l) + step; lightness >= 0 && lightness <= 100; lightness += step) {
    const candidate = `hsl(${h} ${s}% ${lightness}%)`;
    if (passes(candidate)) return candidate;
  }
  return darkSurfaces ? 'hsl(0 0% 100%)' : 'hsl(0 0% 0%)';
}

// --- Schemes -------------------------------------------------------------------------------------------------

function pick(colors: Record<string, string>, slots: string[], source: string, token: string): string {
  for (const slot of slots) if (colors[slot]) return colors[slot];
  throw new Error(`Nucleum scheme ${source} has none of ${slots.join(', ')} for ${token}`);
}

const ADJUSTMENTS = new Map<string, SchemeAdjustment[]>();

/** Every text token Subset moved away from Nucleum's colour to reach its contrast targets, scheme by scheme. */
export function schemeAdjustments(): SchemeAdjustment[] {
  return SCHEME_FAMILIES.flatMap((family) => [family.light, family.dark])
    .filter((scheme, index, all) => all.findIndex((other) => other.source === scheme.source) === index)
    .flatMap((scheme) => ADJUSTMENTS.get(scheme.source) ?? []);
}

/** The Subset scheme for the Nucleum scheme `source`. */
export function schemeFrom(source: string): Scheme {
  const entry = SOURCE[source];
  if (!entry) throw new Error(`Unknown Nucleum scheme ${source}`);
  const colors = {} as Record<ColorToken, string>;
  for (const [token, slots] of Object.entries(NUCLEUM_MAPPING)) colors[token as ColorToken] = pick(entry.colors, slots, source, token);
  const adjustments: SchemeAdjustment[] = [];
  const surfaces = TEXT_SURFACES.map((surface) => colors[surface]);
  // Hovered controls switch to primary text, so secondary and muted text only need the resting surfaces.
  const resting = TEXT_SURFACES.filter((surface) => surface !== 'surface-hover').map((surface) => colors[surface]);
  const settle = (token: ColorToken, value: string, min: number, on = surfaces) => {
    const settled = ensureContrast(value, on, min);
    if (settled !== value) adjustments.push({ source, token, from: value, to: settled });
    colors[token] = settled;
  };
  // Text must read on every surface it can sit on, including nested controls and hover states.
  settle('text-primary', colors['text-primary'], TEXT_CONTRAST);
  settle('text-secondary', colors['text-secondary'], TEXT_CONTRAST, resting);
  settle('text-muted', colors['text-muted'], MUTED_CONTRAST, resting);
  // Tone colours are fills; text in a tone (a Remove label, a phase name) takes the tone moved until it reads.
  for (const tone of ['accent', 'secondary', 'success', 'danger'] as const) {
    colors[`${tone}-text`] = ensureContrast(colors[`${tone}-solid`], surfaces, TEXT_CONTRAST);
  }
  // Text on a filled or tinted background: the first candidate that reaches 4.5:1 (for the soft and subtle tones
  // the scheme's primary text first, then white, near-black and black), else the best of them. In some dark
  // schemes the "subtle" tones are light, so primary text fails there. Solid fills have no scheme candidate:
  // Nucleum's data has no on-accent slot for content (only the frame palette's fonaps3).
  const readableOn = (background: string, preferred: (string | undefined)[]) => {
    const candidates = [...preferred, 'hsl(0 0% 100%)', 'hsl(0 0% 7%)', 'hsl(0 0% 0%)'].filter(Boolean) as string[];
    return candidates.find((candidate) => contrast(candidate, background) >= TEXT_CONTRAST)
      ?? candidates.reduce((best, next) => (contrast(next, background) > contrast(best, background) ? next : best));
  };
  colors['accent-contrast'] = readableOn(colors['accent-solid'], []);
  colors['secondary-contrast'] = readableOn(colors['secondary-solid'], []);
  colors['success-contrast'] = readableOn(colors['success-solid'], []);
  colors['danger-contrast'] = readableOn(colors['danger-solid'], []);
  colors['accent-on-soft'] = readableOn(colors['accent-soft'], [colors['text-primary']]);
  colors['success-on-subtle'] = readableOn(colors['success-subtle'], [colors['text-primary']]);
  colors['danger-on-subtle'] = readableOn(colors['danger-subtle'], [colors['text-primary']]);
  ADJUSTMENTS.set(source, adjustments);
  return { source, label: entry.label, mode: entry.isDark ? 'dark' : 'light', colors };
}

/** The scheme families Subset offers, Default first (Nucleum's default family: blue light, Oxide dark). */
export const SCHEME_FAMILIES: readonly SchemeFamily[] = [
  { id: 'default', label: 'Default', light: schemeFrom('clean_tidyblue_light'), dark: schemeFrom('clean_tidyoxide_dark') },
  { id: 'mono', label: 'Mono', light: schemeFrom('clean_tidymono_light'), dark: schemeFrom('clean_tidyoxide_dark') },
  { id: 'graphite', label: 'Graphite', light: schemeFrom('clean_graphite_light'), dark: schemeFrom('clean_graphite_dark') },
  { id: 'solarized', label: 'Solarized', light: schemeFrom('clean_solarized_light'), dark: schemeFrom('clean_solarized_dark') }
];

export const DEFAULT_FAMILY = 'default';

// --- CSS -----------------------------------------------------------------------------------------------------

function declarations(scheme: Scheme, indent: string): string {
  const lines = [`${indent}color-scheme: ${scheme.mode};`];
  for (const token of COLOR_TOKENS) lines.push(`${indent}--ui-color-${token}: ${scheme.colors[token]};`);
  return lines.join('\n');
}

/**
 * The stylesheet for every family: `[data-ui-scheme="<id>"][data-ui-mode="light|dark"]` picks a scheme, and
 * `data-ui-mode="system"` follows `prefers-color-scheme`. The element without either attribute gets Default.
 */
export function schemesCss(families: readonly SchemeFamily[] = SCHEME_FAMILIES): string {
  const out = ['/* Generated by packages/ui/scripts/generate-schemes.mjs from src/schemes.ts. Do not edit. */'];
  for (const family of families) {
    const isDefault = family.id === DEFAULT_FAMILY;
    const light = [`[data-ui-scheme='${family.id}'][data-ui-mode='light']`, `[data-ui-scheme='${family.id}'][data-ui-mode='system']`];
    if (isDefault) light.push(`.ui-root:not([data-ui-scheme])`);
    out.push(`${light.join(',\n')} {\n${declarations(family.light, '  ')}\n}`);
    out.push(`[data-ui-scheme='${family.id}'][data-ui-mode='dark'] {\n${declarations(family.dark, '  ')}\n}`);
    const system = [`[data-ui-scheme='${family.id}'][data-ui-mode='system']`];
    if (isDefault) system.push(`.ui-root:not([data-ui-scheme])`);
    out.push(`@media (prefers-color-scheme: dark) {\n  ${system.join(',\n  ')} {\n${declarations(family.dark, '    ')}\n  }\n}`);
  }
  return `${out.join('\n\n')}\n`;
}
