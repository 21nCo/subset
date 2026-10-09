import type { Platform } from './contract.js';

export interface MeetingLink {
  platform: Platform;
  /** The link as given, normalized by the URL parser. Keep it out of logs: it may hold a passcode. */
  url: string;
  /** The page the bot opens. For Zoom this is the web client, never the native-app launcher. */
  joinUrl: string;
  /** Origin and path only, safe to print and store. */
  redacted: string;
}

export type MeetingLinkResult =
  | { ok: true; link: MeetingLink }
  | { ok: false; message: string };

const MAX_LINK_LENGTH = 2_048;
const MEET_CODE = /^\/[a-z]{3}-[a-z]{4}-[a-z]{3}\/?$/i;
const MEET_LOOKUP = /^\/lookup\/[A-Za-z0-9_-]+\/?$/;
const ZOOM_PATHS: Array<[RegExp, (id: string) => string]> = [
  [/^\/j\/(\d{9,12})\/?$/, (id) => `/wc/join/${id}`],
  [/^\/s\/(\d{9,12})\/?$/, (id) => `/wc/join/${id}`],
  [/^\/wc\/join\/(\d{9,12})\/?$/, (id) => `/wc/join/${id}`],
  [/^\/wc\/(\d{9,12})\/join\/?$/, (id) => `/wc/join/${id}`],
];

/** Validates a Google Meet or Zoom web link. Only `https` links on the platforms' own hosts are accepted. */
export function parseMeetingLink(raw: string): MeetingLinkResult {
  const text = typeof raw === 'string' ? raw.trim() : '';
  if (!text) return { ok: false, message: 'No meeting link was given.' };
  if (text.length > MAX_LINK_LENGTH) return { ok: false, message: 'The meeting link is too long.' };

  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return { ok: false, message: 'The meeting link is not a valid URL.' };
  }
  if (url.protocol !== 'https:') return { ok: false, message: 'The meeting link must use https.' };
  if (url.username || url.password) return { ok: false, message: 'The meeting link must not contain credentials.' };
  if (url.port) return { ok: false, message: 'The meeting link must not set a port.' };

  const host = url.hostname.toLowerCase();
  const redacted = `${url.origin}${url.pathname}`;

  if (host === 'meet.google.com') {
    if (!MEET_CODE.test(url.pathname) && !MEET_LOOKUP.test(url.pathname)) {
      return { ok: false, message: 'This Google Meet link has no meeting code (expected meet.google.com/abc-defg-hij).' };
    }
    return { ok: true, link: { platform: 'google-meet', url: url.toString(), joinUrl: url.toString(), redacted } };
  }

  if (host === 'zoom.us' || host.endsWith('.zoom.us')) {
    for (const [pattern, toWebClient] of ZOOM_PATHS) {
      const match = url.pathname.match(pattern);
      if (!match) continue;
      const joinUrl = new URL(url.toString());
      joinUrl.pathname = toWebClient(match[1]);
      joinUrl.hash = '';
      return { ok: true, link: { platform: 'zoom', url: url.toString(), joinUrl: joinUrl.toString(), redacted } };
    }
    return { ok: false, message: 'This Zoom link has no meeting number (expected zoom.us/j/<number>).' };
  }

  return { ok: false, message: 'Only Google Meet (meet.google.com) and Zoom (zoom.us) links are supported.' };
}

/** Removes the query and fragment from any URL-like string, for logs. Returns a placeholder if it does not parse. */
export function redactUrl(raw: string): string {
  try {
    const url = new URL(raw);
    return `${url.origin}${url.pathname}`;
  } catch {
    return '(unparsed link)';
  }
}
