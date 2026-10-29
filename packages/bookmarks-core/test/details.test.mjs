// The details lifecycle as the details runner (SET-175) sees it: stored details read back, page changes, retries,
// and a details request that must survive a failed enqueue or a revisited page.
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';
import { createBookmarkOperations, displayTitle } from '../dist/index.js';
import { recordingQueue, sampleDetails, setup, storeDetails } from './support.mjs';

const pendingUrls = (queue, bookmarkId) => queue.jobs.filter((entry) => !entry.done && entry.job.bookmarkId === bookmarkId).map((entry) => entry.job.url);
const finishJobs = (queue) => queue.jobs.forEach((entry) => (entry.done = true));

for (const backend of ['memory', 'sqlite', 'postgres']) {
  describe(`details on ${backend}`, () => {
    let host;
    let ops;
    let queue;
    before(async () => {
      host = await setup(backend);
      ops = host.ops;
      queue = host.queue;
    });
    after(() => host.close());

    test('stored details read back unchanged, and a retry or a new page clears them', async () => {
      const { bookmark } = await ops.addBookmark('https://read.example/article');
      const details = { ...sampleDetails(bookmark.url, 'An article'), description: 'About it', siteName: 'Read' };
      await storeDetails(host.server.executor, bookmark, { details, detailsFetchedAt: 1767225600123, faviconKey: 'favicons/read.ico' });
      const ready = await ops.getBookmark(bookmark.id);
      assert.deepEqual(ready.details, details);
      assert.equal(ready.detailsState, 'ready');
      assert.equal(ready.detailsFetchedAt, 1767225600123);
      assert.equal(ready.faviconKey, 'favicons/read.ico');
      assert.equal(displayTitle(ready), 'An article');

      const retried = await ops.retryDetails(bookmark.id);
      assert.equal(retried.detailsState, 'pending');
      assert.equal(retried.details, null);
      assert.equal(retried.detailsFetchedAt, null);
      assert.equal(retried.faviconKey, null);

      const moved = await ops.updateBookmark(bookmark.id, { url: 'https://read.example/other' });
      assert.equal(moved.details, null);
      assert.equal(moved.detailsFetchedAt, null);
      assert.equal(moved.faviconKey, null);
      assert.equal(displayTitle(moved), 'read.example/other');
    });

    test('a repeated retry asks once per request, and again once the job is done', async () => {
      const { bookmark } = await ops.addBookmark('https://again.example/');
      finishJobs(queue);
      await storeDetails(host.server.executor, bookmark, { detailsState: 'failed', detailsError: 'timeout' });
      await ops.retryDetails(bookmark.id);
      await ops.retryDetails(bookmark.id);
      assert.deepEqual(pendingUrls(queue, bookmark.id), [bookmark.url]);
      finishJobs(queue);
      await ops.retryDetails(bookmark.id);
      assert.deepEqual(pendingUrls(queue, bookmark.id), [bookmark.url]);
    });

    test('repeating a page change whose enqueue failed enqueues the new page', async () => {
      const failing = recordingQueue();
      const enqueue = failing.enqueue;
      let fail = false;
      failing.enqueue = async (job, options) => {
        if (!fail) return enqueue(job, options);
        fail = false;
        throw new Error('queue down');
      };
      const editor = createBookmarkOperations({ executor: host.server.executor, detailsQueue: failing, context: { userId: 'owner' } });
      const { bookmark } = await editor.addBookmark('https://enqueuefail.example/a');
      finishJobs(failing);
      await storeDetails(host.server.executor, bookmark, { details: sampleDetails(bookmark.url, 'A') });
      fail = true;
      await assert.rejects(editor.updateBookmark(bookmark.id, { url: 'https://enqueuefail.example/b' }), /queue down/);
      assert.equal((await ops.getBookmark(bookmark.id)).detailsState, 'pending');
      const repeated = await editor.updateBookmark(bookmark.id, { url: 'https://enqueuefail.example/b' });
      assert.equal(repeated.detailsState, 'pending');
      assert.deepEqual(pendingUrls(failing, bookmark.id), ['https://enqueuefail.example/b']);
      // Repeating it again while that job is queued adds nothing.
      await editor.updateBookmark(bookmark.id, { url: 'https://enqueuefail.example/b' });
      assert.deepEqual(pendingUrls(failing, bookmark.id), ['https://enqueuefail.example/b']);
    });

    test('returning to a page whose earlier job is still running asks for it again', async () => {
      const { bookmark } = await ops.addBookmark('https://revisit.example/c');
      finishJobs(queue);
      await ops.updateBookmark(bookmark.id, { url: 'https://revisit.example/d' });
      await ops.updateBookmark(bookmark.id, { url: 'https://revisit.example/e' });
      // The first D job may already have stored D's details and been discarded by the move to E; D needs a new one.
      await ops.updateBookmark(bookmark.id, { url: 'https://revisit.example/d' });
      assert.deepEqual(pendingUrls(queue, bookmark.id), ['https://revisit.example/d', 'https://revisit.example/e', 'https://revisit.example/d']);
    });

    test('a same-page URL edit while the add-time job is queued adds no job', async () => {
      const { bookmark } = await ops.addBookmark('https://samepage.example/x');
      await ops.updateBookmark(bookmark.id, { url: 'https://samepage.example/x?utm_source=mail' });
      assert.deepEqual(pendingUrls(queue, bookmark.id), [bookmark.url]);
    });
  });
}
