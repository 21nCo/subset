#!/usr/bin/env node
// Checks the feed file the catalog-feed workflow is about to hand to its deploy job, as a reader would receive it:
// size, JSON, the closed subset.catalog@1 schema and the uniqueness rules (packages/catalog/README.md, Reader rules).
//   node apps/catalog-feed/check-feed.mjs <feed.json>
// Exits 1, listing the problems, when the feed would be refused, so the workflow stops before deploying it; otherwise
// prints a one-line summary of what the feed lists.
import { readFileSync } from 'node:fs';
import process from 'node:process';
import { CATALOG_SCHEMA, catalogFeedProblems } from '../../scripts/catalog-feed.mjs';

const [file, ...rest] = process.argv.slice(2);
if (!file || rest.length > 0) {
  console.error('Usage: node apps/catalog-feed/check-feed.mjs <feed.json>');
  process.exit(2);
}
let bytes;
let problems;
try {
  bytes = readFileSync(file);
  problems = catalogFeedProblems(bytes);
} catch (error) {
  problems = [`cannot read ${file}: ${error.message}`];
}
if (problems.length > 0) {
  console.error(`${file} is not a valid ${CATALOG_SCHEMA} feed:\n  ${problems.join('\n  ')}`);
  process.exit(1);
}
const feed = JSON.parse(bytes.toString('utf8'));
const ids = (entries) => entries.map((entry) => entry.id).join(', ') || 'none';
console.log(`${CATALOG_SCHEMA} generated ${feed.generatedAt}: ${feed.apps.length} apps (${ids(feed.apps)}), ${feed.tools.length} tools (${ids(feed.tools)}), ${bytes.byteLength} bytes`);
