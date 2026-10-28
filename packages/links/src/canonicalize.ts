/** Why `canonicalizeUrl` rejected its input. */
export type UrlRejection = 'invalid-url' | 'unsupported-scheme';

/** Thrown by `canonicalizeUrl` for input that is not an absolute http or https URL. */
export class LinkUrlError extends TypeError {
  readonly reason: UrlRejection;

  constructor(reason: UrlRejection, message: string) {
    super(message);
    this.name = 'LinkUrlError';
    this.reason = reason;
  }
}

// Click and campaign identifiers removed from the query. This is the closed set from SET-171: every other
// parameter, including ones that look like tracking, is kept.
const TRACKING_PARAMETERS = new Set([
  'fbclid',
  'gclid',
  'dclid',
  'gbraid',
  'wbraid',
  'msclkid',
  'yclid',
  'mc_cid',
  'mc_eid',
  'igshid',
  '_hsenc',
  '_hsmi',
  'ref_src'
]);

/** Whether a query parameter name (already decoded) is one `canonicalizeUrl` removes. Names are case-sensitive. */
export function isTrackingParameter(name: string): boolean {
  return name.startsWith('utm_') || TRACKING_PARAMETERS.has(name);
}

/** Parses an absolute http or https URL, or throws `LinkUrlError`. */
export function parseHttpUrl(input: string | URL, base?: string | URL): URL {
  let url: URL;
  try {
    url = new URL(input, base);
  } catch {
    throw new LinkUrlError('invalid-url', 'Expected an absolute URL');
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new LinkUrlError('unsupported-scheme', `Only http and https URLs are supported, not ${url.protocol}`);
  }
  return url;
}

/**
 * The canonical form of an http or https URL, used to recognize the same link saved twice.
 *
 * The WHATWG URL parser lowercases the scheme and host, converts an IDN host to punycode, removes the
 * scheme's default port and turns an empty path into `/`. On top of that the fragment is dropped unless it
 * is a client-side route (`#!` or `#/`), and tracking parameters are removed without reordering or
 * re-encoding the others. http and https stay distinct. Throws `LinkUrlError` for anything else.
 */
export function canonicalizeUrl(input: string | URL): string {
  if (typeof input !== 'string' && !(input instanceof URL)) throw new LinkUrlError('invalid-url', 'Expected a URL string');
  const url = parseHttpUrl(input instanceof URL ? input.href : input);

  if (!url.hash.startsWith('#!') && !url.hash.startsWith('#/')) url.hash = '';

  // Work on the raw query so the kept parameters are byte-for-byte unchanged; URLSearchParams would
  // re-encode them (for example `%20` becomes `+` and a bare `flag` becomes `flag=`).
  if (url.search) {
    const pairs = url.search.slice(1).split('&');
    const kept = pairs.filter((pair) => !isTrackingParameter(decodeParameterName(pair)));
    if (kept.length !== pairs.length) url.search = kept.length ? `?${kept.join('&')}` : '';
  }
  return url.href;
}

function decodeParameterName(pair: string): string {
  const separator = pair.indexOf('=');
  const name = (separator === -1 ? pair : pair.slice(0, separator)).replaceAll('+', ' ');
  try {
    return decodeURIComponent(name);
  } catch {
    // A malformed escape is not a tracking parameter name; keep the parameter.
    return name;
  }
}
