// SET-174's scale check: a 50,000-item synthetic Netscape file imports on SQLite within 120 seconds (the owner-revised
// budget of 2026-10-30). Every bookmark is one datafn insert and every tag link one join-row write, which with
// @datafn/server 0.2.0 over the @superfunctions/db 0.3.0 drizzle adapter take about 0.35 ms and 0.2 ms each on an
// Apple M-series laptop and about twice that on CI (see the README); SFNS-52 tracks a datafn bulk write.
// It is opt-in: it runs only with BOOKMARKS_IMPORT_SCALE=1, through `npm run test:scale`, which CI runs in a step of its
// own on Linux and Node 22 (.github/workflows/verify.yml), so no other suite competes with it for the CPU.
// It then exports the 50,000 bookmarks and imports the export into a new database: the round trip SET-174 promises
// within the import limits (the owner decision of 2026-10-31), so the export stays under 20 MB and reproduces them.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { MAX_IMPORT_BYTES, MAX_IMPORT_ITEMS, parseImport } from '../../dist/index.js';
import { setup } from '../support.mjs';

const BUDGET_MS = 120_000;

/** 50 folders of 1,000 links; every tenth link also has two TAGS, every fifth has no title, every seventh a note. */
function syntheticFile() {
  const lines = ['<!DOCTYPE NETSCAPE-Bookmark-file-1>', '<TITLE>Bookmarks</TITLE>', '<H1>Bookmarks</H1>', '<DL><p>'];
  for (let folder = 0; folder < 50; folder++) {
    lines.push(`<DT><H3 ADD_DATE="1700000000">Folder ${folder}</H3>`, '<DL><p>');
    for (let index = folder; index < MAX_IMPORT_ITEMS; index += 50) {
      const tags = index % 10 === 0 ? ' TAGS="reading,later"' : '';
      lines.push(`<DT><A HREF="https://site${index % 997}.example/articles/${index}?utm_source=feed" ADD_DATE="${1_700_000_000 + index}"${tags}>${index % 5 === 0 ? '' : `Article ${index}`}</A>`);
      if (index % 7 === 0) lines.push(`<DD>Note for article ${index}`);
    }
    lines.push('</DL><p>');
  }
  lines.push('</DL><p>');
  return lines.join('\n');
}

test(
  `a ${MAX_IMPORT_ITEMS.toLocaleString('en-US')}-item file imports on SQLite within ${BUDGET_MS / 1000} s, and its export imports back the same`,
  { timeout: 10 * 60_000, skip: process.env.BOOKMARKS_IMPORT_SCALE === '1' ? false : 'set BOOKMARKS_IMPORT_SCALE=1 to run it' },
  async () => {
    const file = syntheticFile();
    const host = await setup('sqlite');
    try {
      const started = performance.now();
      const result = await host.ops.importBookmarks(parseImport(file, 'netscape-html'));
      const elapsed = performance.now() - started;
      console.log(`imported ${result.added} bookmarks from ${(file.length / 1e6).toFixed(1)} MB in ${(elapsed / 1000).toFixed(1)} s`);
      assert.deepEqual(result, { added: MAX_IMPORT_ITEMS, merged: 0, skipped: 0, warnings: [] });
      assert.equal(host.raw.prepare('select count(*) as count from bookmarks').get().count, MAX_IMPORT_ITEMS);
      assert.equal(host.queue.jobs.length, MAX_IMPORT_ITEMS / 5);
      assert.ok(elapsed < BUDGET_MS, `took ${(elapsed / 1000).toFixed(1)} s`);

      const exported = await host.ops.exportNetscape();
      assert.ok(Buffer.byteLength(exported) <= MAX_IMPORT_BYTES, `the export is ${Buffer.byteLength(exported)} bytes`);
      const target = await setup('sqlite');
      try {
        const started = performance.now();
        assert.deepEqual(await target.ops.importBookmarks(parseImport(exported, 'netscape-html')), result);
        console.log(`imported the ${(exported.length / 1e6).toFixed(1)} MB export in ${((performance.now() - started) / 1000).toFixed(1)} s`);
        // Exporting the copy gives the same file (URLs, titles, notes, unread, archived, dates and tags, in order),
        // apart from LAST_MODIFIED, the time of each write.
        const lastModified = / LAST_MODIFIED="\d+"/g;
        assert.equal((await target.ops.exportNetscape()).replace(lastModified, ''), exported.replace(lastModified, ''));
      } finally {
        await target.close();
      }
    } finally {
      await host.close();
    }
  }
);
