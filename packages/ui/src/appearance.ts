// The appearance a Subset view lets people choose: a colour scheme family and light, dark or system. Typeface
// and shape are fixed for Subset (Twenty One Native, semi-rounded). Hosts keep the choice wherever suits them
// (the standalone hosts use localStorage); this module only parses, resolves and applies it.
import { DEFAULT_FAMILY, SCHEME_FAMILIES, type SchemeMode } from './schemes.js';

export const MODES = ['system', 'light', 'dark'] as const;
export type Mode = (typeof MODES)[number];

export interface Appearance {
  family: string;
  mode: Mode;
}

export const DEFAULT_APPEARANCE: Appearance = Object.freeze({ family: DEFAULT_FAMILY, mode: 'system' });

/** A known family id, or the default. */
export function familyOrDefault(value: unknown): string {
  return typeof value === 'string' && SCHEME_FAMILIES.some((family) => family.id === value) ? value : DEFAULT_FAMILY;
}

/** A known mode, or `system`. */
export function modeOrDefault(value: unknown): Mode {
  return MODES.includes(value as Mode) ? (value as Mode) : 'system';
}

/**
 * The appearance stored as JSON text by a host, with every unknown, missing or malformed field replaced by its
 * default, so a value written by another version never breaks a view.
 */
export function parseAppearance(text: string | null | undefined): Appearance {
  let value: unknown = null;
  try {
    value = text ? JSON.parse(text) : null;
  } catch {
    value = null;
  }
  const record = value && typeof value === 'object' ? (value as Record<string, unknown>) : {};
  return { family: familyOrDefault(record.family), mode: modeOrDefault(record.mode) };
}

export function serializeAppearance(appearance: Appearance): string {
  return JSON.stringify({ family: appearance.family, mode: appearance.mode });
}

/** Light or dark for `mode`, given whether the system prefers dark. */
export function resolveMode(mode: Mode, prefersDark: boolean): SchemeMode {
  return mode === 'system' ? (prefersDark ? 'dark' : 'light') : mode;
}

/** The attributes the scheme stylesheet reads, for a view's root element. */
export function appearanceAttributes(appearance: Appearance): { 'data-ui-scheme': string; 'data-ui-mode': Mode } {
  return { 'data-ui-scheme': familyOrDefault(appearance.family), 'data-ui-mode': modeOrDefault(appearance.mode) };
}
