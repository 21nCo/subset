# Screenshot share Worker (not deployed)

This Cloudflare Worker is the optional hosted-sharing backend for the Screenshot macOS app. It stores uploaded media in R2 and share metadata and comments in D1, and serves the upload API and public share pages. It was ported from the ScreenshotPOC `Backend/` directory; see [../README.md](../README.md) for provenance.

Subset has **no deployment** of this Worker. The POC's custom domain route and its account-specific D1 database ID were removed. The app ships with an empty share URL, so uploads stay disabled until a user enters the URL and upload token of a Worker they deployed themselves.

This directory is intentionally not an npm workspace: adding it under `apps/` would pull Wrangler and workerd into the root lockfile and CI before Subset has decided on a Cloudflare deployment, data residency, auth, cost, and rollback plan (see [docs/architecture.md](../../../docs/architecture.md)). Promote it to `apps/screenshot-share` when such a deployment is authorized.

## Resources (names only; none are provisioned)

- Worker: `subset-screenshot-share`
- R2 bucket: `subset-screenshot-media`
- D1 database: `subset-screenshot-share`

## Self-hosted deploy

Wrangler 4 requires Node.js 22 or newer. Run these from this directory only on an account you control.

```sh
npm install
npx wrangler r2 bucket create subset-screenshot-media
npx wrangler d1 create subset-screenshot-share
# Copy the printed database ID into wrangler.jsonc.
npx wrangler d1 execute subset-screenshot-share --remote --file schema.sql
npx wrangler secret put UPLOAD_TOKEN
npx wrangler deploy
```

Uploads use `Authorization: Bearer <UPLOAD_TOKEN>` and send media bytes directly to `POST /api/uploads?name=...`. Share endpoints apply the password and expiration rules to pages, media, downloads, metadata, and comments.

## Known gaps (carried over from the POC, not fixed in this port)

- Share passwords are hashed with unsalted SHA-256 and passed as a `?p=` query parameter, so they can appear in browser history, referrers to the same origin, and request logs. A production version should use a salted KDF and a POST-based unlock that sets a short-lived cookie.
- The upload token comparison is a plain string comparison, not constant-time.
- A single shared `UPLOAD_TOKEN` authorizes every upload, listing, update, and deletion; there are no per-user accounts.
- Public comment posting has no rate limiting or abuse controls.
- There are no automated tests for the Worker; only `tsc --noEmit` has been run.
