# Catalog feed publishing

The `subset.catalog@1` feed (contract and reader rules: [packages/catalog/README.md](../packages/catalog/README.md#catalog-feed-subsetcatalog1)) is served at:

```text
https://subset.21n.dev/catalog/v1.json
content-type: application/json
cache-control: max-age=300
```

`subset` and the Subset manager app for Mac read it (`SUBSET_CATALOG_URL` overrides the address). The **Catalog feed** workflow ([`.github/workflows/catalog-feed.yml`](../.github/workflows/catalog-feed.yml)) builds it with `scripts/catalog-feed.mjs` and deploys it as the one static asset of the `subset-catalog-feed` Worker ([`apps/catalog-feed`](../apps/catalog-feed)) on the 21n-dev Cloudflare account. A reader that fetches it at most every five minutes sees a change within about five minutes of the deploy.

## When it runs

| Trigger | What it does |
| --- | --- |
| Push to `dev` or `main` touching `packages/catalog/**`, `native/*/macos-release.json`, `release-packages.json`, the generator, `apps/catalog-feed/**` or the workflow | Builds and deploys |
| `release` `published`, `edited` or `deleted` (beta channels come from GitHub pre-releases) | Builds and deploys |
| A successful **Release macOS app** run (`workflow_run`): its beta pre-releases are created with the workflow's token, which fires no `release` event | Builds and deploys |
| Daily at 05:17 UTC (tools' versions come from npm dist-tags, which change without a commit here) | Builds and deploys |
| `workflow_dispatch` from `dev` or `main` | Builds and deploys; from another branch it fails unless `dry_run` is set |
| `workflow_dispatch` with `dry_run` | Dry run of the branch it was started on |
| Pull request touching the paths above | Dry run of the pull request |

Every deploy builds `dev`'s head, whatever started the run: `main` and release tags trail `dev`, and building them would deploy an older catalog than the last `dev` deploy. Deploys run one at a time; GitHub replaces a pending deploy with a newer one, so the last deploy is the newest build. A dry run builds the commit it was started on, validates the feed, builds the Worker with `wrangler deploy --dry-run`, uploads the feed as the run's `catalog-feed` artifact, and deploys nothing. It needs no Cloudflare credentials:

```sh
gh workflow run catalog-feed.yml --ref <branch> -f dry_run=true
```

## Jobs and credentials

- **generate** has no environment and no secret, and only the run's read-only token (`contents: read`), which the generator sends to `api.github.com` so the releases list is not rate limited on a shared runner address. It runs `npm ci`, builds `@subset.dev/catalog`, runs the generator, checks the written file with `apps/catalog-feed/check-feed.mjs` (size, schema, uniqueness: the reader rules), runs `wrangler deploy --dry-run`, and hands the feed on as an artifact with its SHA-256 and commit. A feed that fails any check fails this job, so nothing is deployed and the hosted feed stays as it was.
- **deploy** needs `generate`, is skipped for dry runs, and runs in the `catalog-feed` GitHub environment, which holds `CLOUDFLARE_API_TOKEN`. It checks out the commit the feed was built from, checks the downloaded feed against `generate`'s SHA-256, installs only wrangler and its dependencies from the lockfile with install scripts off (no repository build or install code runs next to the token), and runs `wrangler deploy`. The account ID is pinned in `wrangler.jsonc` (`c801efc2879825babdb9b2534199c4dd`, 21n-dev), so the token cannot deploy the feed anywhere else.

`apps/catalog-feed/test/catalog-feed.test.mjs` (in `npm run check`) holds this contract: no secret, environment or write permission in `generate`; the one step with the token is the deploy in `deploy`, after the checksum check and the scriptless install; the dry-run conditions; the Worker's account, route and headers; and `check-feed.mjs` refusing every invalid feed fixture.

## The Worker

`apps/catalog-feed/wrangler.jsonc` describes a Worker with static assets only, no script, bindings or storage. `public/_headers` sets `Content-Type: application/json` and `Cache-Control: max-age=300` on `/catalog/v1.json`; `public/catalog/v1.json` is written by the workflow and never committed. Every other path is a 404. The custom domain `subset.21n.dev` is the only route: there is no `workers.dev` or preview URL. To serve it locally:

```sh
npm run build --workspace=@subset.dev/catalog
node scripts/catalog-feed.mjs --out apps/catalog-feed/public/catalog/v1.json
cd apps/catalog-feed && npx wrangler dev
```

Data and cost: the feed is public metadata (names, versions, download URLs and checksums of public releases), with no user data, served from Cloudflare's edge. A static-assets Worker on the 21n-dev account's plan has no per-request script cost. No Superfunctions package applies: there is no auth, storage, upload or API client to share.

## Setup (owner)

The first live deploy needs, in GitHub and Cloudflare (SET-236 item 1):

1. A GitHub environment `catalog-feed` with the secret `CLOUDFLARE_API_TOKEN`: a Cloudflare API token limited to the 21n-dev account that can deploy Workers and attach a custom domain on the `21n.dev` zone (Workers Scripts: Edit on the account; Workers Routes: Edit, DNS: Edit and Zone: Read on the zone; SET-236 confirms the set).
2. Deployment rules for that environment allowing the branches `dev` and `main` and the tags `macos/*/v*`: a `release` event runs from its release's tag (only macOS apps have GitHub releases); schedule and `workflow_run` runs are on `dev`.

Until then a deploy fails at `wrangler deploy` and the dry runs still pass. The live deploy and the hostname are proven in SET-237.

## Rollback

`wrangler rollback` in `apps/catalog-feed` (with a token) restores the Worker's previous version, and with it the previous feed. Re-running only the `deploy` job of an earlier run redeploys that run's feed while its artifact is kept (7 days); re-running the whole run builds `dev`'s head again. To withdraw a bad entry for good, fix its source (catalog, release or dist-tag) and dispatch the workflow on `dev`; the next scheduled run would otherwise restore it.
