# @subset.dev/links (SET-171)

`@subset.dev/links` turns a URL into its canonical form and reads a versioned `LinkDetails` record (title, description, preview image, icons and a few more fields) from an HTML document. It uses only web-standard APIs (`URL`, `TextDecoder`) and the portable [htmlparser2](https://github.com/fb55/htmlparser2) tokenizer, so the same code runs on Node, Bun, Cloudflare Workers and in a browser extension. Bookmarks, the Bookmarks browser extension and Memotron in Nucleum share it. It imports no Bookmarks or product code; `scripts/check-workspaces.mjs` enforces that it depends on no other workspace.

The package is private (`0.1.0`) until its npm release in SET-186. It does not fetch anything: the fetcher is SET-172. oEmbed, site-specific or social-post parsers, readable full text and JSON-LD are out of scope.

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
- The query keeps its order and encoding. Only these parameters are removed: `utm_*`, `fbclid`, `gclid`, `dclid`, `gbraid`, `wbraid`, `msclkid`, `yclid`, `mc_cid`, `mc_eid`, `igshid`, `_hsenc`, `_hsmi` and `ref_src`. Names are matched case-sensitively after percent-decoding. A query left empty is removed.
- `http` and `https` stay distinct. Nothing else changes: path case, trailing slashes, `www.`, credentials and other parameters are kept.

The function is idempotent. `isTrackingParameter(name)` exposes the parameter rule.

## `parseLinkDetails(html, { url, contentType })`

`html` is the document as a string, `ArrayBuffer` or typed array. `url` is the document's absolute http(s) URL after redirects; anything else throws `LinkUrlError`. `contentType` is the response's `Content-Type` header and defaults to `text/html`; a value without a valid `type/subtype` is treated as missing. For a type other than `text/html` or `application/xhtml+xml`, the document is not parsed and the record holds only `url`, `contentType` and the fallback icon.

Only the first 512 KB (`MAX_DOCUMENT_BYTES`) is parsed: 524,288 bytes of binary input, or 524,288 UTF-16 code units of a string, without splitting a character. Bytes are decoded with the first of a byte order mark, the `Content-Type` charset, a `<meta charset>` or `<meta http-equiv="Content-Type">` in the first 1,024 bytes, or UTF-8. A label the runtime's `TextDecoder` does not support is skipped, and a `<meta>` UTF-16 label means UTF-8, as in the HTML standard.

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
| `publishedTime` | `article:published_time` as written, when it is an ISO 8601 date or extended-format date-time with valid fields |

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

## Risk and evidence

| Boundary | Failure mode | Evidence |
| --- | --- | --- |
| Canonicalization | Duplicate links not recognized, or distinct links merged; unsafe schemes accepted | One test per rule in `test/canonicalize.test.mjs`, including kept parameters, encoding preservation and idempotence |
| Source precedence | A lower source wins, or an empty or non-http(s) value blocks the next source | For each source, a document holding it and every lower source in reverse order (`test/parse.test.mjs`) |
| Hostile or large input | Quadratic parsing, unbounded output, wrong charset | 3 MB document cut at 512 KB (string and bytes), seven 512 KB adversarial fixtures under 100 ms, a linearity ratio check, caps, windows-1251, ISO-8859-1 and BOM decoding (`test/limits.test.mjs`, `test/parse.test.mjs`) |
| Portability | A Node built-in or global slips in | `tsconfig.json` has no Node types; `test/workerd.test.mjs` bundles the package, fails on any Node built-in import and runs it in workerd, comparing its output with Node's |
| Stored records | Corrupt or foreign data accepted as `LinkDetailsV1` | `test/validator.test.mjs` |

Run `npm test --workspace=@subset.dev/links`; the root `npm run check` runs it too. Live sites are not tested here: they are deferred to SET-190. Railway Postgres, Cloudflare Preview, connected provider sandboxes and Aside Browser have no runtime boundary in this package; the workerd test runs the Workers runtime locally and is not a Cloudflare deployment.

## Superfunctions reuse

Parsing needs no Superfunctions package. The closest one is `browsefn` (npm `0.1.0`, alpha, Apache-2.0; read from the local Superfunctions checkout, as it is not on that repository's `origin/dev`). Its page metadata helper builds a full cheerio DOM inside a fetching SDK, prefers `<title>` over `og:title`, returns relative image and icon URLs unresolved, and has no charset handling, length caps, canonical URL or URL canonicalization, so it cannot meet this issue's closed rules or run as a small dependency of a browser extension. No other Superfunctions package covers link metadata or URL canonicalization. The fetcher in SET-172 is where `browsefn` and other `@superfunctions/*` reuse is evaluated again. Used Superfunctions packages: none. Runtime dependency: `htmlparser2` 12.0.0 (MIT). Test-only: `workerd` and `rolldown`.
