// importBookmarks and exportNetscape through the datafn executor: what an import saves, how it merges with saved
// bookmarks, the export -> import round trip, apiIds, merge records and a concurrent writer.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, describe, test } from 'node:test';
import { BookmarkError, MAX_IMPORT_ITEMS, MAX_IMPORT_WARNINGS, createBookmarkOperations, parseImport } from '../dist/index.js';
import { hookedExecutor, pausePoint, recordingQueue, setup } from './support.mjs';

const fixture = (name) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url));
const FIXTURES = [
  ['chrome.html', 'netscape-html'],
  ['firefox.html', 'netscape-html'],
  ['safari.html', 'netscape-html'],
  ['linkding.html', 'netscape-html'],
  ['raindrop.html', 'netscape-html'],
  ['pocket.csv', 'pocket-csv']
];
const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error instanceof BookmarkError && error.code === code);

/** Every bookmark of the owner, oldest first, in the shape an export keeps. */
async function saved(host) {
  const ids = [];
  for (let after = 0; ; ) {
    const { data } = await host.server.executor.query(
      { version: 1, resource: 'bookmarks', select: ['id', 'apiId'], filters: { apiId: { $gt: after } }, sort: ['apiId'], limit: 100 },
      { userId: 'owner' }
    );
    ids.push(...data.map((row) => row.id));
    if (data.length < 100) break;
    after = Number(data.at(-1).apiId);
  }
  const bookmarks = await Promise.all(ids.map((id) => host.ops.getBookmark(id)));
  // The date an export writes: addedAt, else createdAt, in whole seconds.
  return bookmarks.map(({ url, userTitle, notes, unread, archived, tags, addedAt, createdAt }) => ({
    url,
    userTitle,
    notes,
    unread,
    archived,
    tags: tags.map((tag) => tag.name),
    added: addedAt ?? Math.floor(createdAt / 1000) * 1000
  }));
}

async function byUrl(host, url) {
  const { data } = await host.server.executor.query(
    { version: 1, resource: 'bookmarks', select: ['id'], filters: { url }, limit: 1 },
    { userId: 'owner' }
  );
  return data[0] ? host.ops.getBookmark(data[0].id) : null;
}

for (const backend of ['memory', 'sqlite', 'postgres']) {
  describe(`import and export on ${backend}`, () => {
    let host;
    before(async () => {
      host = await setup(backend);
    });
    after(() => host.close());

    test('every exporter fixture imports, skipping links that are not http(s)', async () => {
      const expected = {
        'chrome.html': { added: 5, merged: 0, skipped: 2 },
        'firefox.html': { added: 3, merged: 1, skipped: 1 },
        'safari.html': { added: 4, merged: 0, skipped: 0 },
        'linkding.html': { added: 3, merged: 0, skipped: 0 },
        'raindrop.html': { added: 3, merged: 0, skipped: 0 },
        'pocket.csv': { added: 3, merged: 0, skipped: 1 }
      };
      for (const [name, kind] of FIXTURES) {
        const { warnings, ...counts } = await host.ops.importBookmarks(parseImport(fixture(name), kind));
        assert.deepEqual(counts, expected[name], name);
        assert.equal(warnings.length, counts.skipped, name);
      }
      const chrome = await host.ops.importBookmarks(parseImport(fixture('chrome.html'), 'netscape-html'));
      assert.deepEqual(chrome.warnings, [
        { item: 5, url: 'javascript:void(document.title)', message: 'Skipped: Only http and https URLs are supported, not javascript:' },
        { item: 7, url: 'chrome://settings/', message: 'Skipped: Only http and https URLs are supported, not chrome:' }
      ]);

      const rust = await byUrl(host, 'https://doc.rust-lang.org/book/');
      assert.equal(rust.userTitle, 'The Rust Programming Language');
      assert.deepEqual(rust.tags.map((tag) => tag.name), ['Dev-Tools', 'Rust-Go']);
      // Firefox's second copy of the article (another spelling of its URL) only adds its tags. Its Other Bookmarks
      // folder is the tag Chrome's Other bookmarks folder made, which keeps its first spelling.
      const article = await byUrl(host, 'https://www.example.org/article');
      assert.equal(article.userTitle, 'An article');
      assert.equal(article.notes, 'Saved for the weekend.\nSecond line > first.');
      assert.deepEqual(article.tags.map((tag) => tag.name), ['long-read', 'notes', 'Other-bookmarks', 'reading']);
      const django = await byUrl(host, 'https://www.djangoproject.com/');
      assert.equal(django.archived, true);
      assert.deepEqual(django.tags.map((tag) => tag.name), ['python']);
      const linkding = await byUrl(host, 'https://github.com/sissbruecker/linkding');
      assert.equal(linkding.unread, true);
      const quotes = await byUrl(host, 'https://example.org/q');
      assert.equal(quotes.archived, true);
      assert.equal(quotes.unread, false);
      assert.equal(quotes.userTitle, 'Quotes, "commas" and line breaks');
      // Pocket's status=unread stays unread, and its time_added is kept apart from the import time.
      const pocket = await byUrl(host, 'https://example.com/nothing?utm_medium=social');
      assert.equal(pocket.unread, true);
      assert.equal(pocket.addedAt, 1_700_000_000_000);
      assert.equal(rust.addedAt, 1_700_000_240_000);
      assert.ok(rust.createdAt > rust.addedAt + 1_000_000);
      // Safari writes no ADD_DATE.
      assert.equal((await byUrl(host, 'https://www.apple.com/')).addedAt, null);
    });

    test('a link in 40 nested folders is saved with every folder as a tag', async () => {
      const names = Array.from({ length: 40 }, (_, at) => `nested-${String(at).padStart(2, '0')}`);
      const html = `<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n${names.map((name) => `<DT><H3>${name}</H3>\n<DL><p>\n`).join('')}<DT><A HREF="https://nested.example/">n</A>\n`;
      const result = await host.ops.importBookmarks(parseImport(html, 'netscape-html'));
      assert.deepEqual(result, { added: 1, merged: 0, skipped: 0, warnings: [] });
      const nested = await byUrl(host, 'https://nested.example/');
      assert.deepEqual(nested.tags.map((tag) => tag.name).sort(), names);
    });

    test('only an untitled import is pending details, with the job an add enqueues', async () => {
      const queue = recordingQueue();
      const ops = createBookmarkOperations({ executor: host.server.executor, detailsQueue: queue, context: { userId: 'owner' } });
      const result = await ops.importBookmarks([
        { url: 'https://details.example/titled', title: 'Has a title' },
        { url: 'https://details.example/untitled?utm_source=x', title: '  ' }
      ]);
      assert.equal(result.added, 2);
      const titled = await byUrl(host, 'https://details.example/titled');
      const untitled = await byUrl(host, 'https://details.example/untitled?utm_source=x');
      assert.equal(titled.detailsState, 'ready');
      assert.equal(titled.details, null);
      assert.equal(untitled.detailsState, 'pending');
      assert.equal(untitled.userTitle, null);
      assert.deepEqual(
        queue.jobs.map(({ job, options }) => ({ job, options })),
        [
          {
            job: { bookmarkId: untitled.id, url: untitled.url, canonicalUrl: 'https://details.example/untitled', detailsRequest: null },
            options: { dedupeKey: untitled.id }
          }
        ]
      );
    });

    test('an item whose URL is saved, here or earlier in the file, only adds its new tags', async () => {
      const { bookmark } = await host.ops.addBookmark('https://merge.example/page', { title: 'Mine', notes: 'keep', tags: ['kept'] });
      const queue = recordingQueue();
      const ops = createBookmarkOperations({ executor: host.server.executor, detailsQueue: queue, context: { userId: 'owner' } });
      const result = await ops.importBookmarks([
        { url: 'https://MERGE.example/page?fbclid=1', title: 'Theirs', notes: 'replace', tags: ['KEPT', 'new'], unread: true, archived: true },
        { url: 'https://merge.example/other', title: 'First copy', tags: ['one'] },
        { url: 'https://merge.example/other#again', title: 'Second copy', tags: ['two', 'ONE'] }
      ]);
      assert.deepEqual(result, { added: 1, merged: 2, skipped: 0, warnings: [] });
      const merged = await host.ops.getBookmark(bookmark.id);
      assert.deepEqual(
        { url: merged.url, userTitle: merged.userTitle, notes: merged.notes, unread: merged.unread, archived: merged.archived, apiId: merged.apiId },
        { url: bookmark.url, userTitle: 'Mine', notes: 'keep', unread: false, archived: false, apiId: bookmark.apiId }
      );
      assert.deepEqual(merged.tags.map((tag) => tag.name), ['kept', 'new']);
      const other = await byUrl(host, 'https://merge.example/other');
      assert.equal(other.userTitle, 'First copy');
      assert.deepEqual(other.tags.map((tag) => tag.name), ['one', 'two']);
      assert.equal(queue.jobs.length, 0);
      // Importing the same items again changes nothing.
      const again = await ops.importBookmarks([{ url: 'https://merge.example/other', tags: ['one'] }]);
      assert.deepEqual(again, { added: 0, merged: 1, skipped: 0, warnings: [] });
    });

    test('a new tag takes its first spelling in the file, also when a later item repeats an earlier URL', async () => {
      const result = await host.ops.importBookmarks([
        { url: 'https://spelling.example/a' },
        { url: 'https://spelling.example/b', tags: ['Spelled'] },
        { url: 'https://spelling.example/a', tags: ['SPELLED'] }
      ]);
      assert.deepEqual(result, { added: 2, merged: 1, skipped: 0, warnings: [] });
      for (const url of ['https://spelling.example/a', 'https://spelling.example/b']) {
        assert.deepEqual((await byUrl(host, url)).tags.map((tag) => tag.name), ['Spelled'], url);
      }
    });

    test('export then import reproduces the same bookmarks and tags', async () => {
      const source = await setup(backend);
      const target = await setup(backend);
      try {
        for (const [name, kind] of FIXTURES) await source.ops.importBookmarks(parseImport(fixture(name), kind));
        const { bookmark } = await source.ops.addBookmark('https://notes.example/', { notes: 'Multi-line\n  notes <b>&amp;</b>', tags: ['Café'], unread: true });
        await source.ops.setArchived(bookmark.id, true);
        const exported = await source.ops.exportNetscape();
        const result = await target.ops.importBookmarks(parseImport(exported, 'netscape-html'));
        const original = await saved(source);
        assert.deepEqual(result, { added: original.length, merged: 0, skipped: 0, warnings: [] });
        assert.deepEqual(await saved(target), original);
        // The date travels as the exporter's, not the time of either import.
        const rust = await byUrl(target, 'https://doc.rust-lang.org/book/');
        assert.equal(rust.addedAt, 1_700_000_240_000);
        assert.ok(rust.createdAt > rust.addedAt + 1_000_000);
        const added = await byUrl(target, 'https://notes.example/');
        assert.equal(added.addedAt, Math.floor(bookmark.createdAt / 1000) * 1000);
        // The archived marker is not a tag, and importing the export where it came from changes nothing.
        assert.ok(!original.some((entry) => entry.tags.includes('linkding:bookmarks.archived')));
        assert.deepEqual(await source.ops.importBookmarks(parseImport(exported, 'netscape-html')), { added: 0, merged: original.length, skipped: 0, warnings: [] });
        assert.deepEqual(await saved(source), original);
      } finally {
        await source.close();
        await target.close();
      }
    });

    test('a URL saved twice keeps the earliest date it was added', async () => {
      const result = await host.ops.importBookmarks([
        { url: 'https://dates.example/a', title: 'A', addedAt: 1_600_000_000_000 },
        { url: 'https://dates.example/a#again', addedAt: 1_500_000_000_000 },
        { url: 'https://dates.example/a?utm_source=x', addedAt: 1_550_000_000_000 },
        { url: 'https://dates.example/b', title: 'B', addedAt: 0 }
      ]);
      assert.deepEqual(result, { added: 2, merged: 2, skipped: 0, warnings: [] });
      const a = await byUrl(host, 'https://dates.example/a');
      assert.equal(a.addedAt, 1_500_000_000_000);
      assert.equal((await byUrl(host, 'https://dates.example/b')).addedAt, null);
      // A later date leaves a saved bookmark as it is; an earlier one, also than an added bookmark's createdAt, is kept.
      await host.ops.importBookmarks([{ url: 'https://dates.example/a', addedAt: 1_700_000_000_000 }]);
      assert.equal((await host.ops.getBookmark(a.id)).addedAt, 1_500_000_000_000);
      await host.ops.importBookmarks([{ url: 'https://dates.example/a', addedAt: 1_400_000_000_000 }]);
      assert.equal((await host.ops.getBookmark(a.id)).addedAt, 1_400_000_000_000);
      const { bookmark } = await host.ops.addBookmark('https://dates.example/added', { title: 'Added' });
      assert.equal(bookmark.addedAt, null);
      await host.ops.importBookmarks([{ url: 'https://dates.example/added', addedAt: bookmark.createdAt + 60_000 }]);
      assert.equal((await host.ops.getBookmark(bookmark.id)).addedAt, null);
      await host.ops.importBookmarks([{ url: 'https://dates.example/added', addedAt: 1_300_000_000_000 }]);
      assert.equal((await host.ops.getBookmark(bookmark.id)).addedAt, 1_300_000_000_000);
    });

    test('a tag deleted without a merge after the import linked it is given again', async () => {
      const doomed = (await host.ops.addBookmark('https://doomed.example/seed', { tags: ['Doomed'] })).bookmark.tags[0];
      const importer = createBookmarkOperations({
        executor: hookedExecutor(host.server.executor, {
          afterMutate: async (payload) => {
            if (payload.resource === 'tags' && payload.operation === 'relate' && payload.id === doomed.id) {
              await host.server.executor.mutate({ version: 1, resource: 'tags', operation: 'delete', id: doomed.id }, { userId: 'owner' });
            }
          }
        }),
        detailsQueue: recordingQueue(),
        context: { userId: 'owner' }
      });
      const result = await importer.importBookmarks([{ url: 'https://doomed.example/imported', title: 'Imported', tags: ['doomed'] }]);
      assert.deepEqual(result, { added: 1, merged: 0, skipped: 0, warnings: [] });
      const imported = await byUrl(host, 'https://doomed.example/imported');
      assert.deepEqual(imported.tags.map((tag) => tag.name), ['doomed']);
      assert.notEqual(imported.tags[0].id, doomed.id);
    });

    test('an import claims consecutive apiIds after the last one, which later adds continue', async () => {
      const first = (await host.ops.addBookmark('https://ids.example/first')).bookmark.apiId;
      await host.ops.importBookmarks(['a', 'b', 'c'].map((name) => ({ url: `https://ids.example/${name}`, title: name })));
      const imported = await Promise.all(['a', 'b', 'c'].map((name) => byUrl(host, `https://ids.example/${name}`)));
      assert.deepEqual(imported.map((bookmark) => bookmark.apiId), [first + 1, first + 2, first + 3]);
      await host.ops.deleteBookmarks([imported[2].id]);
      assert.equal((await host.ops.addBookmark('https://ids.example/next')).bookmark.apiId, first + 4);
    });

    test('bad items are skipped or trimmed with warnings, and warnings are capped', async () => {
      const long = 'x'.repeat(600);
      const result = await host.ops.importBookmarks([
        { url: 'https://warn.example/long', title: long, tags: ['ok', 'has space', ''] },
        { url: 42 },
        null,
        ...Array.from({ length: MAX_IMPORT_WARNINGS }, (_, index) => ({ url: `mailto:${index}@example.com` }))
      ]);
      assert.equal(result.added, 1);
      assert.equal(result.skipped, MAX_IMPORT_WARNINGS + 2);
      assert.equal(result.warnings.length, MAX_IMPORT_WARNINGS + 1);
      assert.deepEqual(result.warnings.slice(0, 3), [
        { item: 1, url: 'https://warn.example/long', message: 'Tag dropped: Tag name "has space" contains whitespace, a comma or a control character' },
        { item: 1, url: 'https://warn.example/long', message: 'Tag dropped: A tag name cannot be empty' },
        { item: 1, url: 'https://warn.example/long', message: 'The title was cut to 512 characters' }
      ]);
      assert.deepEqual(result.warnings.at(-1), { message: '5 more warnings not shown' });
      const saved = await byUrl(host, 'https://warn.example/long');
      assert.equal(saved.userTitle, 'x'.repeat(512));
      assert.deepEqual(saved.tags.map((tag) => tag.name), ['ok']);
    });

    test('more than 50,000 items or input that is not items fail before anything is saved', async () => {
      const before = (await saved(host)).length;
      await rejectsWith(host.ops.importBookmarks(Array.from({ length: MAX_IMPORT_ITEMS + 1 }, () => ({ url: 'https://too.example/' }))), 'too-large');
      await rejectsWith(host.ops.importBookmarks({ items: 'nope' }), 'invalid-input');
      await rejectsWith(host.ops.importBookmarks(null), 'invalid-input');
      assert.equal((await saved(host)).length, before);
    });

    test('a tag a merge has recorded also gives its merge target, as an add does', async () => {
      const source = (await host.ops.addBookmark('https://merging.example/seed', { tags: ['Before'] })).bookmark.tags[0];
      const target = (await host.ops.addBookmark('https://merging.example/seed2', { tags: ['After'] })).bookmark.tags[0];
      // A merge interrupted after its record and its move, before the source is deleted.
      const interrupted = createBookmarkOperations({
        executor: hookedExecutor(host.server.executor, {
          beforeMutate: (payload) => {
            if (payload.resource === 'tags' && payload.operation === 'delete') throw new Error('interrupted');
          }
        }),
        detailsQueue: recordingQueue(),
        context: { userId: 'owner' }
      });
      await assert.rejects(interrupted.mergeTags([source.id], target.id), /interrupted/);
      await host.ops.importBookmarks([{ url: 'https://merging.example/imported', tags: ['before'] }]);
      const imported = await byUrl(host, 'https://merging.example/imported');
      assert.deepEqual(imported.tags.map((tag) => tag.name), ['After', 'Before']);
      // Repeating the merge finishes it, and the imported bookmark keeps the target.
      await host.ops.mergeTags([source.id], target.id);
      assert.deepEqual((await host.ops.getBookmark(imported.id)).tags.map((tag) => tag.name), ['After']);
    });

    test('a tag merged away while the import links it is followed to its target, not created again', async () => {
      const source = (await host.ops.addBookmark('https://paused-merge.example/seed', { tags: ['PausedSource'] })).bookmark.tags[0];
      const target = (await host.ops.addBookmark('https://paused-merge.example/seed2', { tags: ['PausedTarget'] })).bookmark.tags[0];
      const point = pausePoint();
      const importer = createBookmarkOperations({
        executor: hookedExecutor(host.server.executor, { beforeMutate: (payload) => payload.operation === 'relate' && point.pause() }),
        detailsQueue: recordingQueue(),
        context: { userId: 'owner' }
      });
      // The import has found the source tag and pauses before linking it; the merge then deletes it.
      const importing = importer.importBookmarks([{ url: 'https://paused-merge.example/imported', title: 'Imported', tags: ['pausedsource'] }]);
      await point.reached;
      await host.ops.mergeTags([source.id], target.id);
      point.release();
      assert.deepEqual(await importing, { added: 1, merged: 0, skipped: 0, warnings: [] });
      const imported = await byUrl(host, 'https://paused-merge.example/imported');
      assert.deepEqual(imported.tags.map((tag) => tag.id), [target.id]);
      const { data } = await host.server.executor.query(
        { version: 1, resource: 'tags', select: ['id'], filters: { nameKey: 'pausedsource' }, limit: 1 },
        { userId: 'owner' }
      );
      assert.deepEqual(data, []);
    });

    test('the export pages through every bookmark', async () => {
      const items = Array.from({ length: 250 }, (_, index) => ({ url: `https://pages.example/${index}`, title: `Page ${index}` }));
      await host.ops.importBookmarks(items);
      const exported = parseImport(await host.ops.exportNetscape(), 'netscape-html').items;
      assert.equal(exported.length, (await saved(host)).length);
      assert.deepEqual(exported.filter((item) => item.url.startsWith('https://pages.example/')).map((item) => item.url), items.map((item) => item.url));
    });

    if (backend !== 'memory') {
      // The memory adapter has no unique index, so it supports one executor per user only.
      test('an import whose apiId range another import claimed first claims the next range', async () => {
        const second = await host.another();
        const point = pausePoint();
        const stale = createBookmarkOperations({
          executor: hookedExecutor(second.executor, { beforeMutate: (payload) => payload.resource === 'bookmark_api_ids' && point.pause() }),
          detailsQueue: recordingQueue(),
          context: { userId: 'owner' }
        });
        const urls = (prefix) => ['a', 'b', 'c'].map((name) => `https://ranges.example/${prefix}/${name}`);
        const importing = stale.importBookmarks(urls('stale').map((url) => ({ url, title: url })));
        await point.reached;
        await host.ops.importBookmarks(urls('first').map((url) => ({ url, title: url })));
        point.release();
        assert.deepEqual(await importing, { added: 3, merged: 0, skipped: 0, warnings: [] });
        const first = await Promise.all(urls('first').map((url) => byUrl(host, url)));
        const late = await Promise.all(urls('stale').map((url) => byUrl(host, url)));
        const firstIds = first.map((bookmark) => bookmark.apiId);
        assert.deepEqual(late.map((bookmark) => bookmark.apiId), firstIds.map((id) => id + 3));
      });

      test('an import that fails part way saves the rest when repeated', async () => {
        const { bookmark: taken } = await host.ops.addBookmark('https://partial.example/taken');
        const failing = createBookmarkOperations({
          executor: hookedExecutor(host.server.executor, {
            // The second insert of the batch reuses a saved bookmark's id, so the database refuses that one alone.
            beforeMutate: (payload) => {
              if (Array.isArray(payload)) payload[1].id = taken.id;
            }
          }),
          detailsQueue: recordingQueue(),
          context: { userId: 'owner' }
        });
        const items = ['a', 'b', 'c'].map((name) => ({ url: `https://partial.example/${name}`, title: name, tags: ['partial'] }));
        await assert.rejects(failing.importBookmarks(items), /Saving the bookmark for https:\/\/partial\.example\/b failed/);
        assert.deepEqual(await host.ops.importBookmarks(items), { added: 1, merged: 2, skipped: 0, warnings: [] });
        for (const { url } of items) assert.deepEqual((await byUrl(host, url)).tags.map((tag) => tag.name), ['partial'], url);
      });

      // The memory adapter has no unique index, so it supports one executor per user only.
      test('a URL another process saves while the import inserts it is merged, not failed', async () => {
        const second = await host.another();
        const point = pausePoint();
        const importer = createBookmarkOperations({
          executor: hookedExecutor(second.executor, { beforeMutate: (payload) => Array.isArray(payload) && point.pause() }),
          detailsQueue: recordingQueue(),
          context: { userId: 'owner' }
        });
        const importing = importer.importBookmarks([
          { url: 'https://race.example/a', title: 'A', tags: ['imported'] },
          { url: 'https://race.example/b', title: 'B', tags: ['imported'] }
        ]);
        await point.reached;
        const { bookmark } = await host.ops.addBookmark('https://race.example/b', { title: 'Theirs' });
        point.release();
        assert.deepEqual(await importing, { added: 1, merged: 1, skipped: 0, warnings: [] });
        const raced = await host.ops.getBookmark(bookmark.id);
        assert.equal(raced.userTitle, 'Theirs');
        assert.deepEqual(raced.tags.map((tag) => tag.name), ['imported']);
        assert.equal((await byUrl(host, 'https://race.example/a')).userTitle, 'A');
      });
    }
  });
}
