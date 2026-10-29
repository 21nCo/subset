import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';
import { BookmarkError, createBookmarkOperations } from '../dist/index.js';
import { recordingQueue, sampleDetails, setup, storeDetails } from './support.mjs';

const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error instanceof BookmarkError && error.code === code);
const tagNames = (bookmark) => bookmark.tags.map((tag) => tag.name);

for (const backend of ['memory', 'sqlite', 'postgres']) {
  describe(`operations on ${backend}`, () => {
    let host;
    let ops;
    before(async () => {
      host = await setup(backend);
      ops = host.ops;
    });
    after(() => host.close());

    test('add saves a pending bookmark and enqueues its details', async () => {
      const { bookmark, duplicate } = await ops.addBookmark('  HTTPS://Example.com/guide?utm_source=feed&id=7#intro ', {
        title: ' A guide ',
        notes: 'Read later',
        tags: ['Docs'],
        unread: true
      });
      assert.equal(duplicate, false);
      assert.equal(bookmark.url, 'https://example.com/guide?utm_source=feed&id=7#intro');
      assert.equal(bookmark.canonicalUrl, 'https://example.com/guide?id=7');
      assert.equal(bookmark.userTitle, 'A guide');
      assert.equal(bookmark.notes, 'Read later');
      assert.equal(bookmark.unread, true);
      assert.equal(bookmark.archived, false);
      assert.equal(bookmark.detailsState, 'pending');
      assert.equal(bookmark.details, null);
      assert.ok(Number.isInteger(bookmark.apiId) && bookmark.apiId >= 1);
      assert.ok(bookmark.createdAt > 0 && bookmark.updatedAt >= bookmark.createdAt);
      assert.deepEqual(tagNames(bookmark), ['Docs']);
      assert.deepEqual(await ops.getBookmark(bookmark.id), bookmark);
      const job = host.queue.jobs.at(-1);
      assert.deepEqual(job.job, { bookmarkId: bookmark.id, url: bookmark.url, canonicalUrl: bookmark.canonicalUrl, detailsRequest: null });
      assert.deepEqual(job.options, { dedupeKey: bookmark.id });
    });

    test('a duplicate add returns the saved bookmark, adds only new tags and enqueues nothing', async () => {
      const first = await ops.addBookmark('https://dup.example/page', { title: 'Mine', notes: 'keep', tags: ['a'], unread: false });
      const jobs = host.queue.jobs.length;
      const again = await ops.addBookmark('https://DUP.example:443/page?fbclid=1', {
        title: 'Other',
        notes: 'replace',
        tags: ['A', 'b'],
        unread: true
      });
      assert.equal(again.duplicate, true);
      assert.equal(again.bookmark.id, first.bookmark.id);
      assert.equal(again.bookmark.apiId, first.bookmark.apiId);
      assert.equal(again.bookmark.url, first.bookmark.url);
      assert.equal(again.bookmark.userTitle, 'Mine');
      assert.equal(again.bookmark.notes, 'keep');
      assert.equal(again.bookmark.unread, false);
      assert.deepEqual(tagNames(again.bookmark), ['a', 'b']);
      assert.equal(host.queue.jobs.length, jobs);
    });

    test('tags fold case: one tag per lowercased name, keeping its first spelling', async () => {
      const { bookmark } = await ops.addBookmark('https://fold.example/1', { tags: ['Rust', 'rust', 'RUST'] });
      assert.deepEqual(tagNames(bookmark), ['Rust']);
      const other = await ops.addTags((await ops.addBookmark('https://fold.example/2')).bookmark.id, ['rUsT']);
      assert.deepEqual(other.tags, bookmark.tags);
      assert.equal((await ops.removeTags(other.id, ['RUST'])).tags.length, 0);
      assert.deepEqual(tagNames(await ops.getBookmark(bookmark.id)), ['Rust']);
    });

    test('apiId is unique, only grows and is not reused after the newest bookmark is deleted', async () => {
      const ids = [];
      for (const n of [1, 2, 3]) ids.push((await ops.addBookmark(`https://seq.example/${n}`)).bookmark.apiId);
      assert.ok(ids[0] < ids[1] && ids[1] < ids[2]);
      const newest = (await ops.addBookmark('https://seq.example/3')).bookmark;
      await ops.deleteBookmarks([newest.id]);
      const next = (await ops.addBookmark('https://seq.example/4')).bookmark.apiId;
      assert.equal(next, ids[2] + 1);

      const concurrent = await Promise.all(Array.from({ length: 8 }, (_, n) => ops.addBookmark(`https://seq.example/c${n}`)));
      const apiIds = concurrent.map((result) => result.bookmark.apiId);
      assert.equal(new Set(apiIds).size, apiIds.length);
      assert.ok(apiIds.every((apiId) => apiId > next));
    });

    test('delete is hard, skips unknown ids and keeps the tags', async () => {
      const { bookmark } = await ops.addBookmark('https://gone.example/', { tags: ['kept'] });
      assert.deepEqual(await ops.deleteBookmarks([bookmark.id, 'missing-id', bookmark.id]), { deleted: [bookmark.id] });
      assert.equal(await ops.getBookmark(bookmark.id), null);
      if (host.raw) assert.equal(host.raw.prepare('SELECT count(*) AS n FROM bookmark_tags WHERE "from" = ?').get(bookmark.id).n, 0);
      const again = await ops.addBookmark('https://gone.example/', { tags: ['KEPT'] });
      assert.equal(again.duplicate, false);
      assert.notEqual(again.bookmark.id, bookmark.id);
      assert.ok(again.bookmark.apiId > bookmark.apiId);
      assert.deepEqual(again.bookmark.tags, bookmark.tags);
    });

    test('a sparse id list is rejected before anything is deleted', async () => {
      const { bookmark } = await ops.addBookmark('https://sparse.example/');
      // The second entry is a hole, which Array.map skips.
      await rejectsWith(ops.deleteBookmarks([bookmark.id, ,]), 'invalid-input');
      assert.equal((await ops.getBookmark(bookmark.id))?.id, bookmark.id);
    });

    test('rename changes the name everywhere and refuses a name another tag has', async () => {
      const a = (await ops.addBookmark('https://rename.example/a', { tags: ['js'] })).bookmark;
      const b = (await ops.addBookmark('https://rename.example/b', { tags: ['js', 'web'] })).bookmark;
      const tag = a.tags[0];
      assert.deepEqual(await ops.renameTag(tag.id, 'JS'), { id: tag.id, name: 'JS', nameKey: 'js' });
      assert.deepEqual(await ops.renameTag(tag.id, 'javascript'), { id: tag.id, name: 'javascript', nameKey: 'javascript' });
      assert.deepEqual(tagNames(await ops.getBookmark(b.id)), ['javascript', 'web']);
      const web = b.tags.find((entry) => entry.name === 'web');
      await assert.rejects(ops.renameTag(tag.id, 'WEB'), (error) => error.code === 'tag-conflict' && error.existingId === web.id);
      await rejectsWith(ops.renameTag(tag.id, 'two words'), 'invalid-input');
      await rejectsWith(ops.renameTag('missing-tag', 'x'), 'not-found');
    });

    test('merge moves every bookmark to the target tag once and deletes the sources', async () => {
      const one = (await ops.addBookmark('https://merge.example/1', { tags: ['py', 'python'] })).bookmark;
      const two = (await ops.addBookmark('https://merge.example/2', { tags: ['Py3'] })).bookmark;
      const three = (await ops.addBookmark('https://merge.example/3', { tags: ['python'] })).bookmark;
      const python = one.tags.find((tag) => tag.nameKey === 'python');
      const sources = [one.tags.find((tag) => tag.nameKey === 'py').id, two.tags[0].id];
      await rejectsWith(ops.mergeTags([...sources, 'missing-tag'], python.id), 'not-found');
      assert.deepEqual(await ops.mergeTags(sources, python.id), python);
      for (const bookmark of [one, two, three]) assert.deepEqual((await ops.getBookmark(bookmark.id)).tags, [python]);
      // The merged names are free again.
      const reused = await ops.addTags(three.id, ['py']);
      assert.ok(!sources.includes(reused.tags.find((tag) => tag.nameKey === 'py').id));
    });

    test("update edits fields, refetches for a new page and refuses another bookmark's URL", async () => {
      const { bookmark } = await ops.addBookmark('https://edit.example/old', { title: 'Old', notes: 'n' });
      const taken = (await ops.addBookmark('https://edit.example/taken')).bookmark;
      host.queue.jobs.forEach((entry) => (entry.done = true));
      await storeDetails(host.server.executor, bookmark, { details: sampleDetails(bookmark.url, 'Old page'), detailsFetchedAt: 1700000000000 });
      const jobs = host.queue.jobs.length;

      const sameCanonical = await ops.updateBookmark(bookmark.id, { url: 'https://edit.example/old?utm_medium=x', title: '', notes: null });
      assert.equal(sameCanonical.url, 'https://edit.example/old?utm_medium=x');
      assert.equal(sameCanonical.userTitle, null);
      assert.equal(sameCanonical.notes, null);
      // The same page: its details stay and nothing is fetched.
      assert.equal(sameCanonical.detailsState, 'ready');
      assert.equal(sameCanonical.details.title, 'Old page');
      assert.equal(host.queue.jobs.length, jobs);

      await assert.rejects(
        ops.updateBookmark(bookmark.id, { url: 'https://EDIT.example/taken#top' }),
        (error) => error.code === 'duplicate-url' && error.existingId === taken.id
      );
      const moved = await ops.updateBookmark(bookmark.id, { url: 'https://edit.example/new', unread: true, archived: true });
      assert.equal(moved.canonicalUrl, 'https://edit.example/new');
      assert.equal(moved.detailsState, 'pending');
      assert.equal(moved.apiId, bookmark.apiId);
      assert.equal(moved.unread, true);
      assert.equal(moved.archived, true);
      const { detailsRequest, ...job } = host.queue.jobs.at(-1).job;
      assert.deepEqual(job, { bookmarkId: bookmark.id, url: 'https://edit.example/new', canonicalUrl: 'https://edit.example/new' });
      assert.match(detailsRequest, / https:\/\/edit\.example\/new$/);

      assert.equal((await ops.setUnread(bookmark.id, false)).unread, false);
      assert.equal((await ops.setArchived(bookmark.id, false)).archived, false);
      await rejectsWith(ops.setUnread(bookmark.id, 'yes'), 'invalid-input');
      await rejectsWith(ops.updateBookmark('missing-id', { unread: true }), 'not-found');
      await rejectsWith(ops.updateBookmark(bookmark.id, { url: 'ftp://edit.example/' }), 'invalid-url');
    });

    test('retryDetails marks the bookmark pending again and enqueues a new request for its URL', async () => {
      const { bookmark } = await ops.addBookmark('https://retry.example/');
      host.queue.jobs.forEach((entry) => (entry.done = true));
      await storeDetails(host.server.executor, bookmark, { detailsState: 'failed', detailsError: 'timeout' });
      const retried = await ops.retryDetails(bookmark.id);
      assert.equal(retried.detailsState, 'pending');
      assert.equal(retried.detailsError, null);
      const job = host.queue.jobs.at(-1);
      const { detailsRequest, ...fields } = job.job;
      assert.deepEqual(fields, { bookmarkId: bookmark.id, url: bookmark.url, canonicalUrl: bookmark.canonicalUrl });
      assert.match(detailsRequest, / https:\/\/retry\.example\/$/);
      assert.equal(job.done, false);
      assert.ok(job.options.dedupeKey.startsWith(`${bookmark.id}:`), job.options.dedupeKey);
      await rejectsWith(ops.retryDetails('missing-id'), 'not-found');
    });

    test('invalid input is rejected before anything is written', async () => {
      const jobs = host.queue.jobs.length;
      await rejectsWith(ops.addBookmark('javascript:alert(1)'), 'invalid-url');
      await rejectsWith(ops.addBookmark('not a url'), 'invalid-url');
      await rejectsWith(ops.addBookmark(`https://long.example/${'a'.repeat(2048)}`), 'invalid-url');
      await rejectsWith(ops.addBookmark('https://bad-tag.example/', { tags: ['ok', 'a,b'] }), 'invalid-input');
      await rejectsWith(ops.addBookmark('https://bad-tag.example/', { tags: [''] }), 'invalid-input');
      await rejectsWith(ops.addBookmark('https://bad-tag.example/', { tags: ['x'.repeat(65)] }), 'invalid-input');
      await rejectsWith(ops.addBookmark('https://bad-tag.example/', { title: 7 }), 'invalid-input');
      await rejectsWith(ops.addBookmark('https://bad-tag.example/', { unread: 'yes' }), 'invalid-input');
      await rejectsWith(ops.addBookmark('https://bad-tag.example/', null), 'invalid-input');
      await rejectsWith(ops.addBookmark('https://bad-tag.example/', 'tags'), 'invalid-input');
      assert.equal(host.queue.jobs.length, jobs);
      assert.equal((await ops.addBookmark('https://bad-tag.example/')).duplicate, false);
    });

    test('concurrent adds of one URL save it once', async () => {
      const results = await Promise.all(Array.from({ length: 6 }, (_, n) => ops.addBookmark('https://race.example/', { tags: [`t${n}`] })));
      assert.equal(results.filter((result) => !result.duplicate).length, 1);
      assert.equal(new Set(results.map((result) => result.bookmark.id)).size, 1);
      const saved = await ops.getBookmark(results[0].bookmark.id);
      assert.deepEqual(tagNames(saved), ['t0', 't1', 't2', 't3', 't4', 't5']);
    });

    test('concurrent moves and adds onto one URL leave one bookmark with it', async () => {
      const others = await Promise.all(['1', '2'].map(async (n) => (await ops.addBookmark(`https://moverace.example/${n}`)).bookmark));
      const results = await Promise.allSettled([
        ...others.map((bookmark) => ops.updateBookmark(bookmark.id, { url: 'https://moverace.example/same' })),
        ops.addBookmark('https://moverace.example/same')
      ]);
      const holders = [];
      for (const bookmark of others) if ((await ops.getBookmark(bookmark.id)).url === 'https://moverace.example/same') holders.push(bookmark.id);
      const added = results[2].value;
      if (!added.duplicate) holders.push(added.bookmark.id);
      assert.equal(holders.length, 1, JSON.stringify(results.map((result) => result.status)));
      assert.equal(added.bookmark.id, holders[0]);
      for (const result of results.slice(0, 2)) if (result.status === 'rejected') assert.equal(result.reason.code, 'duplicate-url');
    });

    if (backend !== 'memory') {
      // The memory adapter keys rows by id across namespaces, so it holds one user; the migrations key by (__ns, id).
      test('each user has their own bookmarks, tags and apiId sequence', async () => {
        const mine = (await ops.addBookmark('https://shared.example/', { tags: ['shared'] })).bookmark;
        const theirs = host.forUser('someone-else');
        assert.equal(await theirs.getBookmark(mine.id), null);
        const added = await theirs.addBookmark('https://shared.example/', { tags: ['Shared'] });
        assert.equal(added.duplicate, false);
        assert.equal(added.bookmark.apiId, 1);
        assert.deepEqual(tagNames(added.bookmark), ['Shared']);
        assert.notEqual(added.bookmark.tags[0].id, mine.tags[0].id);
        assert.deepEqual(await theirs.deleteBookmarks([mine.id]), { deleted: [] });
        await rejectsWith(theirs.setUnread(mine.id, true), 'not-found');
        await rejectsWith(theirs.addTags(mine.id, ['x']), 'not-found');
        assert.ok(await ops.getBookmark(mine.id));
      });

      test('apiId goes past the last 32-bit value', async () => {
        const seed = 'INSERT INTO bookmark_api_ids (id, __ns, value) VALUES (';
        if (host.raw) host.raw.prepare(`${seed}?, ?, ?)`).run('2147483647', 'wide', 2147483647);
        else await host.pglite.query(`${seed}$1, $2, $3)`, ['2147483647', 'wide', 2147483647]);
        const wide = host.forUser('wide');
        assert.equal((await wide.addBookmark('https://wide.example/a')).bookmark.apiId, 2147483648);
        const { bookmark } = await wide.addBookmark('https://wide.example/b');
        assert.equal(bookmark.apiId, 2147483649);
        assert.deepEqual(await wide.getBookmark(bookmark.id), bookmark);
      });

      // Two servers on one database stand in for two processes: only the unique indexes coordinate them.
      test('two hosts on one database save a URL once, never share an apiId and share tags', async () => {
        const other = createBookmarkOperations({ executor: (await host.another()).executor, detailsQueue: recordingQueue(), context: { userId: 'owner' } });
        const writers = [ops, other];
        const results = await Promise.all(
          Array.from({ length: 8 }, (_, n) => writers[n % 2].addBookmark(`https://hosts.example/${n % 4}`, { tags: [`Host${n % 3}`] }))
        );
        const saved = results.filter((result) => !result.duplicate).map((result) => result.bookmark);
        assert.equal(saved.length, 4);
        assert.equal(new Set(saved.map((bookmark) => bookmark.apiId)).size, 4);
        for (let n = 0; n < 4; n++) assert.equal(new Set(results.filter((_, i) => i % 4 === n).map((result) => result.bookmark.id)).size, 1);
        const tagIds = new Map();
        for (const result of results) {
          for (const tag of (await ops.getBookmark(result.bookmark.id)).tags) {
            assert.equal(tagIds.get(tag.nameKey) ?? tag.id, tag.id);
            tagIds.set(tag.nameKey, tag.id);
          }
        }
        assert.equal(tagIds.size, 3);
      });
    }
  });
}
