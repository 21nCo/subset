// Concurrent writers that read, pause and then write, and operations interrupted between their steps. Each
// writer has its own executor (and, on SQL, its own datafn server on the shared database), standing in for
// another request or process.
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';
import { canonicalizeUrl } from '@subset.dev/links';
import { BookmarkError, createBookmarkOperations, displayTitle } from '../dist/index.js';
import { hookedExecutor, pausePoint, recordingQueue, sampleDetails, setup, storeDetails } from './support.mjs';

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

    test("a URL write datafn lets past a move whose page details were stored does not keep that page's details", async () => {
      const { bookmark } = await ops.addBookmark('https://own.example/page');
      const point = pausePoint();
      const queue = recordingQueue();
      // datafn reads the guard and then writes; the write pauses as if its guard read happened before the move.
      const late = await writer({ beforeMutate: (payload) => payload.record?.url !== undefined && point.pause().then(() => delete payload.if) }, queue);
      const updating = late.updateBookmark(bookmark.id, { url: 'https://own.example/page?utm_source=x' });
      await point.reached;
      const moved = await ops.updateBookmark(bookmark.id, { url: 'https://foreign.example/' });
      await storeDetails(host.server.executor, moved, { details: sampleDetails(moved.url, 'Foreign page'), faviconKey: 'favicons/foreign.ico' });
      point.release();
      const updated = await updating;
      assert.deepEqual(updated, await ops.getBookmark(bookmark.id));
      assert.equal(updated.canonicalUrl, bookmark.canonicalUrl);
      assert.equal(updated.detailsState, 'pending');
      assert.equal(updated.details, null);
      assert.equal(updated.faviconKey, null);
      assert.notEqual(displayTitle(updated), 'Foreign page');
      assert.deepEqual(
        pendingJobs(queue, bookmark.id).map((entry) => entry.job.url),
        ['https://own.example/page?utm_source=x']
      );
    });

    test("repeating a URL write that datafn let past a move, interrupted before it settled, clears that page's details", async () => {
      const { bookmark } = await ops.addBookmark('https://own.example/interrupted');
      const point = pausePoint();
      const crash = failOnce((payload) => payload.record?.url !== undefined);
      const late = await writer({
        beforeMutate: (payload) => payload.record?.url !== undefined && point.pause().then(() => delete payload.if),
        afterMutate: crash
      });
      const updating = late.updateBookmark(bookmark.id, { url: 'https://own.example/interrupted?utm_source=x' });
      await point.reached;
      const moved = await ops.updateBookmark(bookmark.id, { url: 'https://foreign.example/interrupted' });
      await storeDetails(host.server.executor, moved, { details: sampleDetails(moved.url, 'Foreign page'), faviconKey: 'favicons/foreign.ico' });
      point.release();
      await assert.rejects(updating, /injected failure/);
      const queue = recordingQueue();
      const repeated = await (await writer({}, queue)).updateBookmark(bookmark.id, { url: 'https://own.example/interrupted?utm_source=x' });
      assert.deepEqual(repeated, await ops.getBookmark(bookmark.id));
      assert.equal(repeated.detailsState, 'pending');
      assert.equal(repeated.details, null);
      assert.equal(repeated.faviconKey, null);
      assert.notEqual(displayTitle(repeated), 'Foreign page');
      assert.deepEqual(pendingJobs(queue, bookmark.id).map((entry) => entry.job.url), ['https://own.example/interrupted?utm_source=x']);
    });

    test('a same-page URL edit with nothing in between writes only the URL and keeps the details', async () => {
      // One bookmark still has its add-time request; the other's request is the one its page change wrote.
      const added = (await ops.addBookmark('https://kept.example/added')).bookmark;
      const moved = await ops.updateBookmark((await ops.addBookmark('https://kept.example/old')).bookmark.id, { url: 'https://kept.example/moved' });
      for (const current of [added, moved]) {
        await storeDetails(host.server.executor, current, { details: sampleDetails(current.url, `Title of ${current.url}`) });
        const writes = [];
        const queue = recordingQueue();
        const editor = await writer({ beforeMutate: (payload) => void writes.push(payload.record) }, queue);
        const edited = await editor.updateBookmark(current.id, { url: `${current.url}?utm_source=x` });
        assert.deepEqual(writes, [{ url: `${current.url}?utm_source=x`, canonicalUrl: current.canonicalUrl }]);
        assert.equal(edited.detailsState, 'ready');
        assert.equal(displayTitle(edited), `Title of ${current.url}`);
        assert.equal(queue.jobs.length, 0);
      }
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
      // The merge journaled the source before reading it, so the bookmark gets the target as well.
      assert.deepEqual((await ops.addTags(late.id, ['mr-source'])).tags, [source, target]);
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

    test('a tag a concurrent merge removes before it is linked is followed to the merge target', async () => {
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
      assert.deepEqual(added.tags, [target]);
      assert.deepEqual(await ops.getBookmark(bookmark.id), added);
    });

    test('a requested tag deleted with no merge before it is linked is created again, and the other tags are linked', async () => {
      const { bookmark } = await ops.addBookmark('https://add-deleted.example/1');
      const other = (await ops.addBookmark('https://add-deleted.example/2', { tags: ['ad-gone', 'ad-kept'] })).bookmark;
      const [gone, kept] = other.tags;
      await ops.removeTags(other.id, ['ad-gone']);
      const point = pausePoint();
      const adder = await writer({ beforeMutate: (payload) => payload.operation === 'relate' && point.pause() });
      const adding = adder.addTags(bookmark.id, ['ad-gone', 'ad-kept']);
      await point.reached;
      const removed = await host.server.executor.mutate({ version: 1, resource: 'tags', operation: 'delete', id: gone.id }, { userId: 'owner' });
      assert.equal(removed.ok, true);
      point.release();
      const [again, keptAfter] = (await adding).tags;
      assert.deepEqual(keptAfter, kept);
      assert.equal(again.name, 'ad-gone');
      assert.notEqual(again.id, gone.id);
    });

    /** A bookmark tagged with a source and the target, a second bookmark to tag, and a merge writer. */
    async function mergeRace(prefix) {
      const first = (await ops.addBookmark(`https://${prefix}.example/1`, { tags: [`${prefix}-source`, `${prefix}-target`] })).bookmark;
      const late = (await ops.addBookmark(`https://${prefix}.example/2`)).bookmark;
      const [source, target] = ['source', 'target'].map((name) => first.tags.find((tag) => tag.name === `${prefix}-${name}`));
      return { first, late, source, target };
    }

    // Pauses the merge after a read of the source's bookmarks that found none, just before it deletes the source.
    const afterEmptyMemberRead = (source, point) => (payload, result) =>
      payload.filters?.['tags.id'] === source.id && result.data.length === 0 && point.pause();

    test('addTags completing after the merge last read the source leaves the bookmark with the target', async () => {
      const { first, late, source, target } = await mergeRace('mf');
      const point = pausePoint();
      const merger = await writer({ afterQuery: afterEmptyMemberRead(source, point) });
      const merging = merger.mergeTags([source.id], target.id);
      await point.reached;
      assert.ok((await ops.addTags(late.id, ['mf-source'])).tags.some((tag) => tag.id === source.id));
      point.release();
      assert.deepEqual(await merging, target);
      for (const bookmark of [first, late]) assert.deepEqual((await ops.getBookmark(bookmark.id)).tags, [target]);
      // Repeating the merge is a no-op and the source name is free again.
      assert.deepEqual(await ops.mergeTags([source.id], target.id), target);
    });

    test('a merge completing while addTags is between its link and its journal read leaves the target', async () => {
      const { late, source, target } = await mergeRace('ml');
      const point = pausePoint();
      const adder = await writer({ afterMutate: (payload) => payload.operation === 'relate' && payload.id === late.id && point.pause() });
      const adding = adder.addTags(late.id, ['ml-source']);
      await point.reached;
      assert.deepEqual(await ops.mergeTags([source.id], target.id), target);
      point.release();
      assert.deepEqual((await adding).tags, [target]);
      assert.deepEqual((await ops.getBookmark(late.id)).tags, [target]);
    });

    test('a source tagged after an interrupted merge journaled it ends on the target when the merge is repeated', async () => {
      const { first, late, source, target } = await mergeRace('mj');
      const broken = await writer({ beforeMutate: failOnce((payload) => payload.resource === 'tags' && payload.operation === 'delete') });
      await assert.rejects(broken.mergeTags([source.id], target.id), /injected failure/);
      assert.deepEqual((await ops.addTags(late.id, ['mj-source'])).tags, [source, target]);
      assert.deepEqual(await ops.mergeTags([source.id], target.id), target);
      for (const bookmark of [first, late]) assert.deepEqual((await ops.getBookmark(bookmark.id)).tags, [target]);
    });

    test('a merge back into a tag recorded as merging into the source fails with conflict, and records are followed once', async () => {
      const { bookmark } = await ops.addBookmark('https://mergecycle.example/', { tags: ['mc-a', 'mc-b'] });
      const [a, b] = bookmark.tags;
      // A is recorded as merged into B but the merge stops before deleting A.
      const broken = await writer({ beforeMutate: failOnce((payload) => payload.resource === 'tags' && payload.operation === 'delete') });
      await assert.rejects(broken.mergeTags([a.id], b.id), /injected failure/);
      // Merging B back into A would leave the bookmarks on neither: it fails and withdraws its record.
      await rejectsWith(ops.mergeTags([b.id], a.id), 'conflict');
      assert.deepEqual((await ops.getBookmark(bookmark.id)).tags, [a, b]);
      // When that withdrawal is interrupted too, both records stay, and tagging with A follows each once.
      const stuck = await writer({ beforeMutate: failOnce((payload) => payload.resource === 'tag_merges' && payload.operation === 'delete') });
      await assert.rejects(stuck.mergeTags([b.id], a.id), /injected failure/);
      const other = (await ops.addBookmark('https://mergecycle.example/2', { tags: ['MC-A'] })).bookmark;
      assert.deepEqual(other.tags, [a, b]);
      // Each merge withdraws its own record on conflict, so after one does the other completes.
      await rejectsWith(ops.mergeTags([a.id], b.id), 'conflict');
      assert.deepEqual(await ops.mergeTags([b.id], a.id), a);
      for (const id of [bookmark.id, other.id]) assert.deepEqual((await ops.getBookmark(id)).tags, [a]);
    });

    // Pauses a merge after a read of the tag's bookmarks that found some, before it moves them.
    const afterMemberRead = (tag, point) => (payload, result) => payload.filters?.['tags.id'] === tag.id && result.data.length > 0 && point.pause();

    test('crossed merges of two tags: at most one succeeds and the bookmark keeps a live tag', async () => {
      const { bookmark } = await ops.addBookmark('https://crossed.example/', { tags: ['cx-a', 'cx-b'] });
      const [a, b] = bookmark.tags;
      const [pointA, pointB] = [pausePoint(), pausePoint()];
      const intoB = (await writer({ afterQuery: afterMemberRead(a, pointA) })).mergeTags([a.id], b.id);
      await pointA.reached;
      const intoA = (await writer({ afterQuery: afterMemberRead(b, pointB) })).mergeTags([b.id], a.id);
      await pointB.reached;
      pointA.release();
      pointB.release();
      const results = await Promise.allSettled([intoB, intoA]);
      for (const result of results) if (result.status === 'rejected') assert.equal(result.reason.code, 'conflict', String(result.reason));
      const won = results.filter((result) => result.status === 'fulfilled').map((result) => result.value);
      assert.ok(won.length <= 1, 'both merges succeeded');
      const tags = (await ops.getBookmark(bookmark.id)).tags;
      if (won.length === 1) {
        assert.deepEqual(tags, won);
      } else {
        assert.deepEqual(tags, [a, b]);
        // Both withdrew their records, so the merge can be run again.
        assert.deepEqual(await ops.mergeTags([a.id], b.id), b);
        assert.deepEqual((await ops.getBookmark(bookmark.id)).tags, [b]);
      }
    });

    test('crossed merges of two tags with no bookmarks: at most one succeeds and a bookmark tagged meanwhile keeps a live tag', async () => {
      const seed = (await ops.addBookmark('https://crossed-empty.example/1', { tags: ['ce-a', 'ce-b'] })).bookmark;
      const [a, b] = seed.tags;
      await ops.removeTags(seed.id, ['ce-a', 'ce-b']);
      const [pointA, pointB] = [pausePoint(), pausePoint()];
      const intoB = (await writer({ afterQuery: afterEmptyMemberRead(a, pointA) })).mergeTags([a.id], b.id);
      await pointA.reached;
      const intoA = (await writer({ afterQuery: afterEmptyMemberRead(b, pointB) })).mergeTags([b.id], a.id);
      await pointB.reached;
      // Both are recorded, so tagging with A follows both records.
      const tagged = await ops.addTags(seed.id, ['ce-a']);
      assert.deepEqual(tagged.tags, [a, b]);
      pointA.release();
      pointB.release();
      const results = await Promise.allSettled([intoB, intoA]);
      for (const result of results) if (result.status === 'rejected') assert.equal(result.reason.code, 'conflict', String(result.reason));
      const won = results.filter((result) => result.status === 'fulfilled').map((result) => result.value);
      assert.ok(won.length <= 1, 'both merges succeeded');
      const tags = (await ops.getBookmark(seed.id)).tags;
      if (won.length === 1) {
        assert.deepEqual(tags, won);
      } else {
        assert.deepEqual(tags, [a, b]);
        assert.deepEqual(await ops.mergeTags([a.id], b.id), b);
        assert.deepEqual((await ops.getBookmark(seed.id)).tags, [b]);
      }
    });

    // Pauses the merge once the walk after an empty read of the source found the target live, just before it reads
    // its record again and deletes the source.
    const afterFinalWalk = (source, target, point) => {
      let empty = false;
      return (payload, result) => {
        if (payload.filters?.['tags.id'] === source.id) empty = result.data.length === 0;
        else if (empty && payload.resource === 'tags' && payload.filters?.id === target.id) return point.pause();
      };
    };

    for (const interrupted of [false, true]) {
      const p = interrupted ? 'wi' : 'wp';
      test(`a merge whose record was withdrawn after its last walk does not delete a source tagged meanwhile${interrupted ? ' (merge back interrupted)' : ''}`, { timeout: 60_000 }, async () => {
        const seed = (await ops.addBookmark(`https://${p}.example/seed`, { tags: [`${p}-a`, `${p}-b`] })).bookmark;
        const [a, b] = seed.tags;
        await ops.removeTags(seed.id, [a.name, b.name]);
        const x = (await ops.addBookmark(`https://${p}.example/x`)).bookmark;
        const [walked, withdrawing] = [pausePoint(), pausePoint()];
        const intoB = (await writer({ afterQuery: afterFinalWalk(a, b, walked) })).mergeTags([a.id], b.id);
        await walked.reached;
        // A merge back sees the cycle and stops before withdrawing its record (or fails there).
        const beforeWithdraw = (payload) => {
          if (payload.resource !== 'tag_merges' || payload.operation !== 'delete' || payload.id !== b.id) return undefined;
          if (interrupted) throw new Error('injected failure');
          return withdrawing.pause();
        };
        const intoA = (await writer({ beforeMutate: beforeWithdraw })).mergeTags([b.id], a.id);
        if (interrupted) await assert.rejects(intoA, /injected failure/);
        else await withdrawing.reached;
        // Repeating the first merge sees the record back and withdraws the first record, so A is a plain tag again.
        await rejectsWith(ops.mergeTags([a.id], b.id), 'conflict');
        assert.deepEqual((await ops.addTags(x.id, [a.name])).tags, [a]);
        if (interrupted) {
          walked.release();
          await rejectsWith(intoB, 'conflict');
          assert.deepEqual((await ops.getBookmark(x.id)).tags, [a, b]);
          await rejectsWith(ops.mergeTags([a.id], b.id), 'conflict');
          assert.deepEqual((await ops.getBookmark(x.id)).tags, [a, b]);
          assert.deepEqual(await ops.mergeTags([b.id], a.id), a);
          assert.deepEqual((await ops.getBookmark(x.id)).tags, [a]);
        } else {
          withdrawing.release();
          await rejectsWith(intoA, 'conflict');
          walked.release();
          assert.deepEqual(await intoB, b);
          assert.deepEqual((await ops.getBookmark(x.id)).tags, [b]);
        }
      });
    }

    test('a merge whose target is gone with no merge record keeps its source and fails with conflict', async () => {
      const seed = (await ops.addBookmark('https://gone-target.example/', { tags: ['gt-s', 'gt-t'] })).bookmark;
      const [s, t] = seed.tags;
      await ops.removeTags(seed.id, ['gt-s']);
      const point = pausePoint();
      const merging = (await writer({ afterQuery: afterEmptyMemberRead(s, point) })).mergeTags([s.id], t.id);
      await point.reached;
      await ops.removeTags(seed.id, ['gt-t']);
      const removed = await host.server.executor.mutate({ version: 1, resource: 'tags', operation: 'delete', id: t.id }, { userId: 'owner' });
      assert.equal(removed.ok, true);
      point.release();
      await rejectsWith(merging, 'conflict');
      assert.deepEqual((await ops.addTags(seed.id, ['GT-S'])).tags, [s]);
    });

    test('a merge into a tag whose own merge is finishing ends on the last target', async () => {
      const tagged = (await ops.addBookmark('https://chained.example/1', { tags: ['ch-s'] })).bookmark;
      const other = (await ops.addBookmark('https://chained.example/2', { tags: ['ch-t', 'ch-u'] })).bookmark;
      const s = tagged.tags[0];
      const [t, u] = other.tags;
      await ops.removeTags(other.id, ['ch-t']);
      const point = pausePoint();
      // T into U pauses after reading that T has no bookmarks, before deleting T; S into T then completes.
      const merging = (await writer({ afterQuery: afterEmptyMemberRead(t, point) })).mergeTags([t.id], u.id);
      await point.reached;
      assert.deepEqual(await ops.mergeTags([s.id], t.id), t);
      point.release();
      assert.deepEqual(await merging, u);
      assert.deepEqual((await ops.getBookmark(tagged.id)).tags, [u]);
    });

    // An add that failed right after linking the source, while the merge waited after its last (empty) read, is
    // repeated with the same tag: the repeat finds the source linked and must still follow its merge record.
    for (const [label, repeat] of [
      ['addTags', (bookmark, name) => ops.addTags(bookmark.id, [name])],
      ['a duplicate add', async (bookmark, name) => (await ops.addBookmark(bookmark.url, { tags: [name] })).bookmark]
    ]) {
      test(`${label} repeated after it failed past linking a source the merge last read empty leaves the target`, async () => {
        const prefix = label === 'addTags' ? 'rt' : 'rd';
        const { late, source, target } = await mergeRace(prefix);
        const point = pausePoint();
        const merging = (await writer({ afterQuery: afterEmptyMemberRead(source, point) })).mergeTags([source.id], target.id);
        await point.reached;
        const failing = await writer({ afterMutate: failOnce((payload) => payload.operation === 'relate' && payload.id === late.id) });
        const tagging = label === 'addTags' ? failing.addTags(late.id, [`${prefix}-source`]) : failing.addBookmark(late.url, { tags: [`${prefix}-source`] });
        await assert.rejects(tagging, /injected failure/);
        assert.deepEqual((await repeat(late, `${prefix}-source`)).tags, [source, target]);
        point.release();
        assert.deepEqual(await merging, target);
        assert.deepEqual((await ops.getBookmark(late.id)).tags, [target]);
      });
    }

    test('repeating addTags of a linked tag no merge recorded writes nothing', async () => {
      const { bookmark } = await ops.addBookmark('https://linked-tag.example/', { tags: ['lt-tag'] });
      const mutations = [];
      const counting = await writer({ beforeMutate: (payload) => mutations.push(payload) });
      assert.deepEqual(await counting.addTags(bookmark.id, ['LT-TAG']), bookmark);
      assert.deepEqual(await counting.addBookmark(bookmark.url, { tags: ['lt-tag'] }), { bookmark, duplicate: true });
      assert.deepEqual(mutations, []);
    });

    test('a linked tag whose merge record leads to a deleted tag no merge recorded stays linked', async () => {
      const { bookmark } = await ops.addBookmark('https://dead-end.example/', { tags: ['de-tag'] });
      const [tag] = bookmark.tags;
      // What a withdrawn record of a deleted target leaves (see the README's merge windows).
      const record = { version: 1, resource: 'tag_merges', operation: 'insert', id: tag.id, record: { targetId: crypto.randomUUID() } };
      assert.equal((await host.server.executor.mutate(record, { userId: 'owner' }))?.ok, true);
      assert.deepEqual((await ops.addTags(bookmark.id, ['de-tag'])).tags, [tag]);
    });

    /** Records `tag` as merged into `targetId`, as an interrupted merge (or a withdrawn one's dead target) leaves it. */
    const recordMerge = async (tag, targetId) => {
      const record = { version: 1, resource: 'tag_merges', operation: 'insert', id: tag.id, record: { targetId } };
      assert.equal((await host.server.executor.mutate(record, { userId: 'owner' }))?.ok, true);
    };

    // X's record leads to a deleted tag no merge recorded; S's record leads to the live tag T.
    const deadAndLive = async (prefix) => {
      const { bookmark } = await ops.addBookmark(`https://${prefix}.example/`, { tags: [`${prefix}-x`, `${prefix}-s`] });
      const [s, x] = bookmark.tags;
      const t = (await ops.addBookmark(`https://${prefix}.example/t`, { tags: [`${prefix}-t`] })).bookmark.tags[0];
      await recordMerge(x, crypto.randomUUID());
      await recordMerge(s, t.id);
      return { bookmark, s, t, x };
    };

    for (const [label, add] of [
      ['addTags', (bookmark, names) => ops.addTags(bookmark.id, names)],
      ['a duplicate add', async (bookmark, names) => (await ops.addBookmark(bookmark.url, { tags: names })).bookmark]
    ]) {
      test(`${label} of a linked tag whose records end at a deleted tag still links a new tag`, async () => {
        const prefix = label === 'addTags' ? 'dn' : 'dd';
        const { bookmark } = await ops.addBookmark(`https://${prefix}.example/`, { tags: [`${prefix}-x`] });
        const [x] = bookmark.tags;
        await recordMerge(x, crypto.randomUUID());
        const tags = (await add(bookmark, [`${prefix}-x`, `${prefix}-fresh`])).tags;
        assert.deepEqual(tags.map((tag) => tag.name), [`${prefix}-fresh`, `${prefix}-x`]);
        assert.deepEqual((await add(bookmark, [`${prefix}-x`, `${prefix}-fresh`])).tags, tags);
      });
    }

    test('a dead end in one linked tag records does not stop another linked tag reaching its merge target', async () => {
      const { bookmark, s, t, x } = await deadAndLive('dl');
      assert.deepEqual((await ops.addTags(bookmark.id, ['dl-x', 'dl-s'])).tags, [s, t, x]);
    });

    test('a new bookmark given a dead-ended tag and a recorded tag gets the recorded tag merge target', async () => {
      const { s, t, x } = await deadAndLive('dw');
      assert.deepEqual((await ops.addBookmark('https://dw.example/new', { tags: ['dw-x', 'dw-s'] })).bookmark.tags, [s, t, x]);
    });

    if (backend === 'sqlite') {
      test('crossed merges of a tag with no bookmarks and a tag with some: at most one succeeds and the bookmarks keep a live tag', async () => {
        const { bookmark } = await ops.addBookmark('https://crossed-mixed.example/', { tags: ['cm-a', 'cm-b'] });
        const [a, b] = bookmark.tags;
        await ops.removeTags(bookmark.id, ['cm-a']);
        const [pointA, pointB] = [pausePoint(), pausePoint()];
        const intoB = (await writer({ afterQuery: afterEmptyMemberRead(a, pointA) })).mergeTags([a.id], b.id);
        await pointA.reached;
        const intoA = (await writer({ afterQuery: afterMemberRead(b, pointB) })).mergeTags([b.id], a.id);
        await pointB.reached;
        pointA.release();
        pointB.release();
        const results = await Promise.allSettled([intoB, intoA]);
        for (const result of results) if (result.status === 'rejected') assert.equal(result.reason.code, 'conflict', String(result.reason));
        const won = results.filter((result) => result.status === 'fulfilled').map((result) => result.value);
        assert.ok(won.length <= 1, 'both merges succeeded');
        // Reads skip deleted tags, so the bookmark has a live tag: the winner, or B (and A, linked by the loser).
        const tags = (await ops.getBookmark(bookmark.id)).tags;
        if (won.length === 1) assert.deepEqual(tags, won);
        else assert.ok(tags.some((tag) => tag.id === b.id), JSON.stringify(tags));
      });

      test("a duplicate add's tags completing after the merge last read the source leave the target", async () => {
        const { late, source, target } = await mergeRace('md');
        const point = pausePoint();
        const merger = await writer({ afterQuery: afterEmptyMemberRead(source, point) });
        const merging = merger.mergeTags([source.id], target.id);
        await point.reached;
        const again = await ops.addBookmark(late.url, { tags: ['MD-SOURCE'] });
        assert.equal(again.duplicate, true);
        point.release();
        await merging;
        assert.deepEqual((await ops.getBookmark(late.id)).tags, [target]);
      });
    }

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
