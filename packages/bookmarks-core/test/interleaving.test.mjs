// Concurrent writers that read, pause and then write, and operations interrupted between their steps. Each
// writer has its own executor (and, on SQL, its own datafn server on the shared database), standing in for
// another request or process.
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';
import { canonicalizeUrl } from '@subset.dev/links';
import { BookmarkError, createBookmarkOperations } from '../dist/index.js';
import { hookedExecutor, pausePoint, recordingQueue, setup } from './support.mjs';

const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error instanceof BookmarkError && error.code === code);

/** A hook that throws once, on the first call `matches` accepts. */
function failOnce(matches) {
  let failed = false;
  return async (payload) => {
    if (failed || !matches(payload)) return;
    failed = true;
    throw new Error('injected failure');
  };
}

const pendingJobs = (queue, bookmarkId) => queue.jobs.filter((entry) => !entry.done && entry.job.bookmarkId === bookmarkId);

for (const backend of ['memory', 'sqlite', 'postgres']) {
  describe(`interleaving and interruption on ${backend}`, () => {
    let host;
    let ops;
    /** Operations on a second datafn server over the same database, with optional hooks. */
    let writer;
    before(async () => {
      host = await setup(backend);
      ops = host.ops;
      const second = await host.another();
      // Each writer wraps the second server's executor in a new object, so it shares no in-process write chain.
      writer = async (hooks, detailsQueue = recordingQueue()) =>
        createBookmarkOperations({ executor: hookedExecutor(second.executor, hooks), detailsQueue, context: { userId: 'owner' } });
    });
    after(() => host.close());

    if (backend !== 'memory') {
      // The memory adapter's insert overwrites an existing id, so it supports one executor per user only.
      test("a stale apiId claim is retried and never hands out a deleted bookmark's apiId", async () => {
        await ops.addBookmark('https://seed.example/');
        const point = pausePoint();
        const stale = await writer({ beforeMutate: () => point.pause() });
        const adding = stale.addBookmark('https://stale.example/');
        await point.reached;
        const other = (await ops.addBookmark('https://other.example/')).bookmark;
        await ops.deleteBookmarks([other.id]);
        point.release();
        const added = (await adding).bookmark;
        assert.ok(added.apiId > other.apiId, `apiId ${added.apiId} after deleted ${other.apiId}`);
        assert.ok((await ops.addBookmark('https://after.example/')).bookmark.apiId > added.apiId);
      });
    }

    test('a URL update computed from a stale read keeps url and canonicalUrl together', async () => {
      const { bookmark } = await ops.addBookmark('https://coherent.example/');
      const point = pausePoint();
      const queue = recordingQueue();
      const stale = await writer({ beforeMutate: () => point.pause() }, queue);
      const updating = stale.updateBookmark(bookmark.id, { url: 'https://coherent.example/?utm_source=x' });
      await point.reached;
      await ops.updateBookmark(bookmark.id, { url: 'https://moved.example/' });
      point.release();
      const updated = await updating;
      const stored = await ops.getBookmark(bookmark.id);
      assert.deepEqual(updated, stored);
      assert.equal(stored.url, 'https://coherent.example/?utm_source=x');
      assert.equal(stored.canonicalUrl, canonicalizeUrl(stored.url));
      assert.equal(stored.detailsState, 'pending');
      // Moving back from the other page is a new page for the stale writer, so it asks for its details.
      assert.deepEqual(
        pendingJobs(queue, bookmark.id).map((entry) => entry.job.url),
        ['https://coherent.example/?utm_source=x']
      );
    });

    test('a field that looked unchanged in a stale read is still written', async () => {
      const { bookmark } = await ops.addBookmark('https://unread.example/', { unread: true });
      const point = pausePoint();
      const stale = await writer({ afterQuery: (payload) => payload.resource === 'bookmarks' && point.pause() });
      const marking = stale.setUnread(bookmark.id, true);
      await point.reached;
      await ops.setUnread(bookmark.id, false);
      point.release();
      assert.equal((await marking).unread, true);
      assert.equal((await ops.getBookmark(bookmark.id)).unread, true);
    });

    test('a page change while the add-time job is still queued gets a job for the new URL', async () => {
      const { bookmark } = await ops.addBookmark('https://first.example/');
      assert.equal(pendingJobs(host.queue, bookmark.id).length, 1);
      const moved = await ops.updateBookmark(bookmark.id, { url: 'https://second.example/' });
      const jobs = pendingJobs(host.queue, bookmark.id);
      assert.deepEqual(
        jobs.map((entry) => entry.job.url),
        ['https://first.example/', 'https://second.example/']
      );
      assert.equal(moved.canonicalUrl, 'https://second.example/');
      assert.ok(jobs[1].options.dedupeKey.startsWith(`${bookmark.id}:`), jobs[1].options.dedupeKey);

      // The new page's job failed; a retry while the stale add-time job is still queued asks for the current URL.
      jobs[1].done = true;
      await ops.retryDetails(bookmark.id);
      assert.deepEqual(
        pendingJobs(host.queue, bookmark.id).map((entry) => entry.job.url),
        ['https://first.example/', 'https://second.example/']
      );
      // Retrying again while that job is queued adds nothing.
      await ops.retryDetails(bookmark.id);
      assert.equal(pendingJobs(host.queue, bookmark.id).length, 2);
    });

    test('an interrupted merge finishes when run again, and an unknown source still stops it', async () => {
      const one = (await ops.addBookmark('https://resume.example/1', { tags: ['m-one'] })).bookmark;
      const two = (await ops.addBookmark('https://resume.example/2', { tags: ['m-two'] })).bookmark;
      const three = (await ops.addBookmark('https://resume.example/3', { tags: ['m-target', 'm-four'] })).bookmark;
      const [s1, s2] = [one.tags[0], two.tags[0]];
      const target = three.tags.find((tag) => tag.name === 'm-target');
      const four = three.tags.find((tag) => tag.name === 'm-four');

      const broken = await writer({ beforeMutate: failOnce((payload) => payload.resource === 'tags' && payload.operation === 'delete' && payload.id === s2.id) });
      await assert.rejects(broken.mergeTags([s1.id, s2.id], target.id), /injected failure/);
      assert.equal(await ops.getBookmark(one.id).then((bookmark) => bookmark.tags[0].id), target.id);

      assert.deepEqual(await ops.mergeTags([s1.id, s2.id], target.id), target);
      for (const bookmark of [one, two]) assert.deepEqual((await ops.getBookmark(bookmark.id)).tags, [target]);
      // A source merged into another tag, or one that never existed, is not found and nothing moves.
      await rejectsWith(ops.mergeTags([s1.id], four.id), 'not-found');
      await rejectsWith(ops.mergeTags([four.id, 'never-a-tag'], target.id), 'not-found');
      assert.deepEqual(
        (await ops.getBookmark(three.id)).tags.map((tag) => tag.id),
        [four.id, target.id]
      );
    });

    test('a bookmark tagged with the source while a merge runs is moved to the target', async () => {
      const first = (await ops.addBookmark('https://mergerace.example/1', { tags: ['mr-source', 'mr-target'] })).bookmark;
      const late = (await ops.addBookmark('https://mergerace.example/2')).bookmark;
      const [source, target] = ['mr-source', 'mr-target'].map((name) => first.tags.find((tag) => tag.name === name));
      const point = pausePoint();
      // Pauses the merge right after it read the source's bookmarks.
      const merger = await writer({ afterQuery: (payload) => payload.filters?.['tags.id'] === source.id && point.pause() });
      const merging = merger.mergeTags([source.id], target.id);
      await point.reached;
      assert.deepEqual((await ops.addTags(late.id, ['mr-source'])).tags, [source]);
      point.release();
      assert.deepEqual(await merging, target);
      for (const bookmark of [first, late]) assert.deepEqual((await ops.getBookmark(bookmark.id)).tags, [target]);
    });

    test('concurrent renames to one name: one wins and the other is a tag conflict', async () => {
      const { bookmark } = await ops.addBookmark('https://renamerace.example/', { tags: ['rr-one', 'rr-two'] });
      const results = await Promise.allSettled(bookmark.tags.map((tag) => ops.renameTag(tag.id, 'rr-same')));
      assert.deepEqual(results.map((result) => result.status).sort(), ['fulfilled', 'rejected']);
      const winner = results.find((result) => result.status === 'fulfilled').value;
      const rejected = results.find((result) => result.status === 'rejected').reason;
      assert.ok(rejected instanceof BookmarkError && rejected.code === 'tag-conflict', String(rejected));
      assert.equal(rejected.existingId, winner.id);
      const loser = bookmark.tags.find((tag) => tag.id !== winner.id);
      assert.deepEqual((await ops.getBookmark(bookmark.id)).tags, [loser, winner].sort((a, b) => (a.nameKey < b.nameKey ? -1 : 1)));
    });

    test('a rename and a tag creation with one name leave one tag for it', async () => {
      const { bookmark } = await ops.addBookmark('https://renamecreate.example/', { tags: ['rc-old'] });
      const [renamed, tagged] = await Promise.allSettled([ops.renameTag(bookmark.tags[0].id, 'rc-fresh'), ops.addTags(bookmark.id, ['RC-FRESH'])]);
      assert.equal(tagged.status, 'fulfilled');
      const keys = (await ops.getBookmark(bookmark.id)).tags.map((tag) => tag.nameKey);
      assert.equal(new Set(keys).size, keys.length, keys.join());
      assert.equal(keys.filter((key) => key === 'rc-fresh').length, 1);
      if (renamed.status === 'rejected') assert.equal(renamed.reason.code, 'tag-conflict');
    });

    test('a tag a concurrent merge removes is created again with the spelling being added', async () => {
      const { bookmark } = await ops.addBookmark('https://addmerge.example/1');
      const tagged = (await ops.addBookmark('https://addmerge.example/2', { tags: ['am-source', 'am-target'] })).bookmark;
      const [source, target] = ['am-source', 'am-target'].map((name) => tagged.tags.find((tag) => tag.name === name));
      const point = pausePoint();
      const adder = await writer({ beforeMutate: (payload) => payload.operation === 'relate' && point.pause() });
      const adding = adder.addTags(bookmark.id, ['AM-SOURCE']);
      await point.reached;
      await ops.mergeTags([source.id], target.id);
      point.release();
      const added = await adding;
      assert.deepEqual(
        added.tags.map((tag) => tag.name),
        ['AM-SOURCE']
      );
      assert.notEqual(added.tags[0].id, source.id);
      assert.deepEqual(await ops.getBookmark(bookmark.id), added);
    });

    test('an interrupted delete finishes when run again and keeps the tags', async () => {
      const one = (await ops.addBookmark('https://del.example/1', { tags: ['d-tag'] })).bookmark;
      const two = (await ops.addBookmark('https://del.example/2', { tags: ['d-tag'] })).bookmark;
      const broken = await writer({ beforeMutate: failOnce((payload) => payload.operation === 'delete' && payload.id === two.id) });
      await assert.rejects(broken.deleteBookmarks([one.id, two.id]), /injected failure/);
      assert.equal(await ops.getBookmark(one.id), null);
      assert.deepEqual(await ops.deleteBookmarks([one.id, two.id]), { deleted: [two.id] });
      assert.equal(await ops.getBookmark(two.id), null);
      assert.deepEqual((await ops.addBookmark('https://del.example/3', { tags: ['D-TAG'] })).bookmark.tags, one.tags);
    });

    test('an add interrupted while tagging still has its details job, and adding again adds the tags', async () => {
      const queue = recordingQueue();
      const broken = await writer({ beforeMutate: failOnce((payload) => payload.operation === 'relate') }, queue);
      await assert.rejects(broken.addBookmark('https://tagfail.example/', { tags: ['late'] }), /injected failure/);
      assert.equal(queue.jobs.length, 1);
      const again = await ops.addBookmark('https://tagfail.example/', { tags: ['late'] });
      assert.equal(again.duplicate, true);
      assert.equal(again.bookmark.id, queue.jobs[0].job.bookmarkId);
      assert.deepEqual(
        again.bookmark.tags.map((tag) => tag.name),
        ['late']
      );
    });

    test('a failed enqueue leaves the bookmark pending, and retryDetails enqueues it', async () => {
      const queue = recordingQueue();
      const enqueue = queue.enqueue;
      queue.enqueue = async () => {
        queue.enqueue = enqueue;
        throw new Error('queue down');
      };
      const adder = await writer({}, queue);
      await assert.rejects(adder.addBookmark('https://queuefail.example/'), /queue down/);
      const again = await adder.addBookmark('https://queuefail.example/');
      assert.equal(again.duplicate, true);
      assert.equal(again.bookmark.detailsState, 'pending');
      assert.equal(queue.jobs.length, 0);
      await adder.retryDetails(again.bookmark.id);
      assert.deepEqual(
        queue.jobs.map((entry) => entry.job),
        [{ bookmarkId: again.bookmark.id, url: again.bookmark.url }]
      );
    });
  });
}
