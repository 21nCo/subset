# @subset.dev/links (SET-171, SET-172)

`@subset.dev/links` turns a URL into its canonical form, reads a versioned `LinkDetails` record (title, description, preview image, icons and a few more fields) from an HTML document, and fetches untrusted URLs without reaching private addresses or hanging the host. It uses only web-standard APIs (`URL`, `TextDecoder`, `fetch`, streams and timers) and the portable [htmlparser2](https://github.com/fb55/htmlparser2) tokenizer, so the same code runs on Node, Bun, Cloudflare Workers and in a browser extension. Bookmarks, the Bookmarks browser extension and Memotron in Nucleum share it. It imports no Bookmarks or product code; `scripts/check-workspaces.mjs` enforces that it depends on no other workspace.

oEmbed, site-specific or social-post parsers, readable full text, JSON-LD, robots.txt, caching and JavaScript rendering are out of scope.

## Install

```sh
npm install @subset.dev/links
```

The package is ES modules only (no CommonJS build) with TypeScript declarations, and its one dependency is `htmlparser2`. It is tested on Node 22 and in workerd, the Cloudflare Workers runtime; any runtime with `URL`, `TextDecoder`, `fetch`, web streams and timers should work. It is published from this repository by a `links-v<version>` tag (`.github/workflows/publish-tag.yml`); until the owner's first release (SET-194) it is not on npm.

## Usage

```ts
import { canonicalizeUrl, isLinkDetailsV1, parseLinkDetails } from '@subset.dev/links';

canonicalizeUrl('HTTPS://Example.com:443/a?utm_source=x&id=7#top'); // 'https://example.com/a?id=7'

const response = await fetch(url);
const details = parseLinkDetails(await response.arrayBuffer(), {
  url: response.url,
  contentType: response.headers.get('content-type') ?? undefined
});
```

## `canonicalizeUrl(input)`

Returns the canonical string for an absolute `http` or `https` URL (string or `URL`) and throws `LinkUrlError` (a `TypeError` with `reason` `invalid-url` or `unsupported-scheme`) for anything else. The rules are a closed set:

- The scheme and host are lowercased, an IDN host becomes punycode, the default port is removed and an empty path becomes `/` (all from the WHATWG URL parser).
- The fragment is dropped unless it starts with `#!` or `#/` (client-side routes).
- The query keeps its order and encoding. Only these parameters are removed: `utm_*`, `fbclid`, `gclid`, `dclid`, `gbraid`, `wbraid`, `msclkid`, `yclid`, `mc_cid`, `mc_eid`, `igshid`, `_hsenc`, `_hsmi` and `ref_src`. Names are matched case-sensitively after percent-decoding. When removal leaves no parameter, the query is removed with any empty pairs, so `?utm_source=x&` leaves no `?`.
- `http` and `https` stay distinct. Nothing else changes: path case, trailing slashes, `www.`, credentials and other parameters are kept.

The function is idempotent. `isTrackingParameter(name)` exposes the parameter rule.

## `parseLinkDetails(html, { url, contentType })`

`html` is the document as a string, `ArrayBuffer` or typed array. `url` is the document's absolute http(s) URL after redirects; anything else throws `LinkUrlError`. `contentType` is the response's `Content-Type` header and defaults to `text/html`; a value without a valid `type/subtype` is treated as missing. For a type other than `text/html` or `application/xhtml+xml`, the document is not parsed and the record holds only `url`, `contentType` and the fallback icon.

Only the first 512 KB (`MAX_DOCUMENT_BYTES`) is parsed: 524,288 bytes, counting a string as its UTF-8 encoding, so a string and its UTF-8 bytes give the same record unless the bytes declare another charset. The cut never splits a character. Bytes are decoded with the first of a byte order mark, the `Content-Type` charset, a `<meta charset>` or `<meta http-equiv="Content-Type">` in the first 1,024 bytes, or UTF-8. A label the runtime's `TextDecoder` does not support is skipped, and a `<meta>` UTF-16 label means UTF-8, as in the HTML standard.

| Field | Sources, highest first |
| --- | --- |
| `title` | `og:title`, `twitter:title`, the first `<title>` (not one inside SVG or MathML); at most 500 characters |
| `description` | `og:description`, `twitter:description`, `<meta name="description">`; at most 2,000 characters |
| `image` | `og:image:secure_url`, `og:image`, `twitter:image`; the first of each, absolute http(s) only |
| `icons` | `<link rel>` `icon`, then `shortcut icon`, then `apple-touch-icon`, each in document order with `sizes` and `type`; deduplicated, http(s) only, at most 16; otherwise `/favicon.ico` at the site root |
| `canonicalUrl` | `<link rel="canonical">`, http(s) only, canonicalized with `canonicalizeUrl` |
| `siteName` | `og:site_name` |
| `language` | `<html lang>`, when it has the shape of a BCP 47 tag |
| `type` | `og:type` |
| `author` | `<meta name="author">`, then `article:author` |
| `publishedTime` | `article:published_time` as written, when it is an ISO 8601 date or extended-format date-time with valid fields; a leap second (`:60`) is rejected |

Open Graph, Twitter and `article:` keys are read from either the `property` or `name` attribute; `description` and `author` only from `name`. A source whose value is empty after cleanup, or whose URL is not http(s), falls through to the next. Entities are decoded, whitespace runs collapse to one space and values are trimmed. Relative URLs resolve against the document URL; `<base href>` is ignored. Tags may appear anywhere in the document, so a page without `<head>` still works. Script, style and comment content is ignored, and malformed markup is recovered the way a browser's tokenizer does (an unterminated tag absorbs what follows it).

Fields are omitted when absent. Text fields other than `title` and `description` are bounded only by the 512 KB input.

The tokenizer is used without htmlparser2's `Parser`, whose open-element stack is quadratic on deeply nested markup, so parsing is linear in the input. On the test fixtures a 512 KB document parses in well under 100 ms.

## `LinkDetailsV1` and `isLinkDetailsV1(value)`

```ts
interface LinkDetailsV1 {
  version: 1;
  url: string;
  canonicalUrl?: string;
  title?: string;
  description?: string;
  siteName?: string;
  language?: string;
  type?: string;
  image?: string;
  icons: { url: string; rel: 'icon' | 'shortcut icon' | 'apple-touch-icon'; sizes?: string; type?: string }[];
  author?: string;
  publishedTime?: string;
  contentType: string; // media type without parameters, for example 'text/html'
}
```

`isLinkDetailsV1` checks an untrusted value (from storage, a queue or another process) against this shape: no unknown keys, http(s) URLs, non-empty strings, the length and icon caps, a language-tag shape, an ISO 8601 `publishedTime` and a parameter-free media type. A later incompatible change gets a new `version`.

## Versioning

`LinkDetailsV1` is stable within 0.x minor versions: no release changes its fields, what they hold or what `isLinkDetailsV1` accepts, because records are stored and read back by other versions of this package, and `isLinkDetailsV1` rejects unknown keys. A breaking change to the record, adding a field included, bumps the record version: a `LinkDetailsV2` with `version: 2`, never an edit to `LinkDetailsV1`. Parser fixes that read a better value from the same document are not breaking. Everything else follows semver for 0.x: a patch release (`0.1.x`) only fixes bugs, and a minor release (`0.2.0`) may change other exports and says how in its release notes. Depend on `^0.1.0`.

## `fetchLinkDetails(url, options)` and `fetchResource(url, options)`

```ts
import { fetchLinkDetails, fetchResource, LinkFetchError } from '@subset.dev/links';
import { lookup } from 'node:dns/promises';

// On Node, pass resolveHost so a name that resolves to a private address before the request is refused too.
// It is not a DNS rebinding defense: see the note on pinning the connection below.
const resolveHost = async (hostname: string) => (await lookup(hostname, { all: true })).map((entry) => entry.address);

try {
  const details = await fetchLinkDetails('https://example.com/post', { resolveHost });
  const icon = await fetchResource(details.icons[0].url, { resolveHost, accept: ['image/*'], maxBytes: 256 * 1024 });
} catch (error) {
  if (error instanceof LinkFetchError) console.log(error.code, error.status);
}
```

`fetchLinkDetails` resolves to a `LinkDetailsV1`. `fetchResource` resolves to `{ url, contentType, bytes }` for icons and other small files. Both reject with `LinkFetchError` (`code`, `status` for `http_status`, and the `url` being fetched), or with a `TypeError` or `RangeError` for invalid options, before any request.

| Option | Default | Meaning |
| --- | --- | --- |
| `fetch` | the global `fetch` | Any function with the web `fetch` signature, called without a receiver, so `globalThis.fetch` can be passed as is. It must honour `redirect: 'manual'`: a response it reached by following a redirect itself (`redirected`, or a `url` other than the requested one) is refused with `network` |
| `resolveHost` | none | `(hostname) => addresses[]`, sync or async; every address is checked before the hop is requested. A check before the request only, not a DNS rebinding defense (see below) |
| `timeoutMs` | 5,000 | One limit for the whole operation: every hop, resolution and the body, including a body or redirect chain whose every step is ready at once. At most 2,147,483,647 (`RangeError` above) |
| `maxBytes` | 2,000,000 | Most body bytes kept. The stream is cancelled once the bound is reached; the last read may have received part of a chunk beyond it, which is dropped. `fetchLinkDetails` keeps HTML only up to the smaller of `maxBytes` and `MAX_DOCUMENT_BYTES` (524,288), the part `parseLinkDetails` parses, and stops once the body fills that bound, without waiting for more. `fetchResource` keeps up to `maxBytes`. Memory follows the bytes kept, not the number of reads |
| `maxRedirects` | 5 | Most redirects followed |
| `userAgent` | `DEFAULT_USER_AGENT`, `SubsetLinks/0.1.0 (+https://subset.dev)` | Sent as `User-Agent` |
| `allowPorts` | none | Ports allowed besides 80 and 443 |
| `accept` (`fetchResource` only) | `['*/*']` | Media ranges such as `image/png` or `image/*`; sent as `Accept` and matched against the response type |

Security rules, a closed set checked on the first URL and again on every redirect hop before it is requested:

- Only `http` and `https` (`invalid_url` otherwise, including a redirect to another scheme), on port 80 or 443 unless `allowPorts` lists the port (`blocked_port`).
- `blocked_address` for the hostnames `localhost`, `local`, `internal` and `home.arpa` and any name ending in `.` plus one of them (case and trailing dots ignored); IPv4 literals in 0.0.0.0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12, 192.168/16, 198.18/15, 224/4 and 240/4, in any form the URL parser accepts (`http://2130706433/` is 127.0.0.1); IPv6 literals `::`, `::1`, fc00::/7, fe80::/10, and IPv4-mapped addresses (`::ffff:a.b.c.d`) in a blocked IPv4 range. With `resolveHost`, a hostname is blocked when any address it returns is blocked or is not an IP address string (a hole in the list counts); a failed or empty resolution is `network`. IP literals are not passed to `resolveHost`.
- Redirects (301, 302, 303, 307 and 308 with a `Location`) are followed manually with `redirect: 'manual'`, resolving the location against the current hop. More than `maxRedirects` is `too_many_redirects`.
- Requests are `GET` with only `Accept` and `User-Agent` headers and `credentials: 'omit'`. Credentials in a URL (`user:pass@`) are removed before the request and from the returned URLs; cookies from a response are never sent back.
- Nothing else is blocked: NAT64 (64:ff9b::/96), 6to4, IPv4-compatible IPv6 and single-label names are allowed by decision. `isBlockedAddress` and `isBlockedHostname` expose the rules.

Decisions and limits:

- Without `resolveHost` (Workers, browser extensions) a public name that resolves to a private address is not detected. This is a non-goal: a Worker's egress cannot reach its host's private network, and an extension fetches what its user's browser can already open.
- `resolveHost` checks the addresses before the request, and `fetch` resolves the name again, so it does not stop DNS rebinding between the two. This portable package uses no Node networking, so it cannot pin the connection itself. A Node host that must stop rebinding passes a `fetch` whose connector checks the address it connects to on every hop, for example an undici `Agent` with a `connect.lookup` that rejects any address for which `isBlockedAddress` is true.
- When the timeout wins over a `fetch` that ignores the abort signal, a response that arrives later is cancelled unread.
- The time limit is judged by the clock before every hop and body read, again when each request, resolution or read settles, and once more before a result is returned, not only by its timer, so work that finishes after `timeoutMs` ends with `timeout` (a late response or body is cancelled). A request, resolution or read that fails after the limit never surfaces as an unhandled rejection. The fetcher also yields to the event loop every 16 hops or reads, so a body or redirect chain that is always ready neither outlasts `timeoutMs` nor holds the host's other work.
- A browser's `fetch` returns an opaque response for `redirect: 'manual'`, so the next hop cannot be checked: that is `network`. As a result, in a browser or extension any URL that redirects fails with `network`, and a `fetch` that follows redirects itself is refused with `network` too. How the extension handles redirecting links is decided by SET-191. Workers and Node expose the `Location`.
- An injected `fetch` that follows redirects itself skips the per-hop checks, so its response is cancelled unread and refused with `network` when it reports `redirected` or a `url` other than the requested one (the fragment aside).

Content handling in `fetchLinkDetails`: a `2xx` response with `text/html`, `application/xhtml+xml`, or a missing or malformed `Content-Type` (read as HTML, as `parseLinkDetails` does) is read up to the smaller of `maxBytes` and `MAX_DOCUMENT_BYTES` and parsed with `parseLinkDetails`; bytes past `MAX_DOCUMENT_BYTES` would never be parsed, so no read is made for them, and the part of the last chunk past the bound is dropped. Reading stops as soon as the body fills that bound, without waiting for another chunk or the end of the stream, so a body of exactly that size counts as cut: no further read can tell it from a larger one. The stream is cancelled at the cut, and the charset comes from a byte order mark, the header, the `<meta>` tag, then UTF-8. Any other type gives `{ version, url, title, icons, contentType }` without reading the body: `title` is the URL's last path segment, percent-decoded, omitted when empty (`/feed/`), and `icons` is the `/favicon.ico` fallback. `url` is always the final URL after redirects.

| Code | When |
| --- | --- |
| `invalid_url` | The input or a redirect target is not an absolute http(s) URL |
| `blocked_address` | A blocked hostname or address, literal or resolved |
| `blocked_port` | A port other than 80, 443 or one in `allowPorts` |
| `timeout` | `timeoutMs` passed, whether or not `fetch` or `resolveHost` honours the abort signal |
| `too_many_redirects` | More than `maxRedirects` redirects |
| `http_status` | The final response is not 2xx, including a 3xx without `Location`; `status` holds it |
| `too_large` | `fetchLinkDetails`: the body filled the smaller of `maxBytes` and `MAX_DOCUMENT_BYTES` and those bytes gave no details beyond the URL, type and fallback icon. `fetchResource`: the body, or its declared `Content-Length`, passed `maxBytes` |
| `network` | `fetch`, the body stream or `resolveHost` failed, `resolveHost` returned no address, the runtime hid a redirect, or `fetch` followed one itself |
| `unsupported_type` | `fetchResource` only: the response type matches no `accept` range (a missing type counts as `application/octet-stream`) |

## Risk and evidence

| Boundary | Failure mode | Evidence |
| --- | --- | --- |
| Canonicalization | Duplicate links not recognized, or distinct links merged; unsafe schemes accepted | One test per rule in `test/canonicalize.test.mjs`, including kept parameters, encoding preservation and idempotence |
| Source precedence | A lower source wins, or an empty or non-http(s) value blocks the next source | For each source, a document holding it and every lower source in reverse order (`test/parse.test.mjs`) |
| Hostile or large input | Quadratic parsing, unbounded output, wrong charset | 3 MB document cut at 512 KB (string and bytes), a multi-byte string cut at the same byte as its UTF-8 bytes, a character straddling the cut, seven 512 KB adversarial fixtures under 100 ms, a linearity ratio check, caps, windows-1251, ISO-8859-1 and BOM decoding (`test/limits.test.mjs`, `test/parse.test.mjs`) |
| Portability | A Node built-in or global slips in | `tsconfig.json` has no Node types; `test/workerd.test.mjs` bundles the package, fails on any Node built-in import and runs it in workerd, comparing its output with Node's |
| Stored records | Corrupt or foreign data accepted as `LinkDetailsV1` | `test/validator.test.mjs` |
| Fetching untrusted URLs | A request reaches a private address, directly, by redirect or by resolution | One vector per blocked hostname pattern, IPv4 range and IPv6 form, with public neighbours outside each prefix; public-to-private redirects; private `resolveHost` results on the first hop and a redirect hop, and for `fetchResource`; malformed results (a hole, a non-string, `127.0.0.1::`) blocked; a `fetch` that requires no receiver called correctly on every hop; a response the `fetch` reached by following a redirect itself refused unread, for both operations. The fake `fetch` serves only listed URLs and every case asserts the exact requests made (`test/fetch-cases.mjs`) |
| Fetch limits | The host hangs, or reads or holds unbounded data | Memory held while reading stays flat over 15,000 always-ready empty or 1-byte reads, for both operations (Node, in a child process with `--expose-gc`); a body of about 200 KB in small and empty chunks kept byte for byte and in order, by two reads at once, at exactly `maxBytes` and cut one byte short; timeouts with a `fetch` that ignores the signal, one that honours it, a stalled `resolveHost`, a stalled body and a slow redirect chain; endless always-ready empty and 1-byte bodies and an instant endless redirect chain, for both operations, ending at the limit and cancelled while other timers still run; reads that each take 10 ms stopped by the clock (Node); a request, resolution, last read or limit-filling read that finishes after the limit ends with `timeout` and its response or body cancelled, and one that fails after it leaves no unhandled rejection, for both operations (Node, in a child process with default rejection handling); a hostname with 200,000 dots checked in linear time; an endless body cut at `maxBytes` and cancelled; an endless HTML body read only to `MAX_DOCUMENT_BYTES` (8 chunks of 64 KiB) with the default and a larger `maxBytes`; a body filling `maxBytes` parsed without another read when the next read stalls; a response arriving after the timeout cancelled; `timeoutMs` above 2^31 - 1 refused; the redirect limit at 5, 6 and 0 |
| Fetch results | Wrong type handling, charset or error code | Each content type, header and meta charset and their order, every error code, the default and custom user agent, credential removal and `fetchResource` type and size checks |
| Packaging (SET-186) | The published tarball misses a file, export, type or dependency, or ships tests or sources | `scripts/check-workspaces.mjs` checks the publication metadata (`publishedManifestProblems`, unit-tested in `scripts/workspace-names.test.mjs`). `scripts/packed-packages.test.mjs` (`npm run test:packed`, after `npm run build`; CI runs it) checks the `npm pack --dry-run` listing, installs the local packed tarball (`.tgz`, not a registry release; only its dependencies come from npm's registry) into a project outside the repository, imports it on Node, bundles it from there into workerd with the same results, and type-checks a strict TypeScript consumer. The tag workflow runs the same suite before it packs `links` or `link-capture`. Installing a release from the registry is SET-194 |

Run `npm test --workspace=@subset.dev/links`; the root `npm run check` runs it too. The fetcher cases run under Node (`test/fetch.test.mjs`) and unchanged inside workerd (`test/workerd.test.mjs`). Live sites and live fetching are not tested here: they are deferred to SET-190. Railway Postgres, Cloudflare Preview, connected provider sandboxes and Aside Browser have no runtime boundary in this package; the workerd test runs the Workers runtime locally and is not a Cloudflare deployment.

## Superfunctions reuse

Parsing needs no Superfunctions package. The closest one is `browsefn` (npm `0.1.0`, alpha, Apache-2.0; read from the local Superfunctions checkout, as it is not on that repository's `origin/dev`). Its page metadata helper builds a full cheerio DOM inside a fetching SDK, prefers `<title>` over `og:title`, returns relative image and icon URLs unresolved, and has no charset handling, length caps, canonical URL or URL canonicalization, so it cannot meet this issue's closed rules or run as a small dependency of a browser extension. No other Superfunctions package covers link metadata or URL canonicalization. For the fetcher (SET-172), `browsefn`'s image download guard blocks only `localhost`, `::1`, 127/8, 10/8, 172.16/12 and 192.168/16 by hostname prefix, reads the whole body before checking its size, has no timeout and imports Node's file system. `@superfunctions/webhooks` (npm `0.1.0`) has a pinned-address delivery guard, but it is not exported and needs `node:dns`, `node:net` and `undici`. `langfn`'s outbound policy refuses every hostname that is not allowlisted. None fits a portable fetcher with this issue's closed rules, so the fetcher is local and uses only web `fetch`, streams and timers. Used Superfunctions packages: none. Runtime dependency: `htmlparser2` 12.0.0 (MIT). Test-only: `workerd` and `rolldown`.
