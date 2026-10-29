// Test hosts for the operations: datafn's server executor over the @superfunctions/db memory adapter, and over
// the drizzle adapter on better-sqlite3 and on PGlite (Postgres in WebAssembly), each with the checked-in
// migration applied. The drizzle tables are built from bookmarksTables, so they cannot drift from the migrations.
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';
import { createDatafnServer } from '@datafn/server';
import { drizzleAdapter } from '@superfunctions/db/adapters/drizzle';
import { memoryAdapter } from '@superfunctions/db/adapters';
import Database from 'better-sqlite3';
import { drizzle as drizzleSqlite } from 'drizzle-orm/better-sqlite3';
import { drizzle as drizzlePglite } from 'drizzle-orm/pglite';
import { bigint, boolean, jsonb, pgTable, text as pgText } from 'drizzle-orm/pg-core';
import { integer, sqliteTable, text } from 'drizzle-orm/sqlite-core';
import { bookmarksSchema, bookmarksTables, createBookmarkOperations } from '../dist/index.js';

export const migrationSql = (dialect) => readFileSync(new URL(`../migrations/${dialect}/0001_initial.sql`, import.meta.url), 'utf8');

const sqliteColumn = (name, field) => {
  const column =
    field.type === 'boolean'
      ? integer(name, { mode: 'boolean' })
      : field.type === 'json'
        ? text(name, { mode: 'json' })
        : field.type === 'string'
          ? text(name)
          : integer(name);
  return field.required ? column.notNull() : column;
};

const postgresColumn = (name, field) => {
  const column =
    field.type === 'boolean'
      ? boolean(name)
      : field.type === 'json'
        ? jsonb(name)
        : field.type === 'string'
          ? pgText(name)
          : bigint(name, { mode: 'number' });
  return field.required ? column.notNull() : column;
};

function drizzleTables(makeTable, makeColumn) {
  return Object.fromEntries(
    Object.entries(bookmarksTables).map(([model, table]) => [
      model,
      makeTable(model, Object.fromEntries(Object.entries(table.fields).map(([name, field]) => [name, makeColumn(name, field)])))
    ])
  );
}

const silent = { info() {}, warn() {}, debug() {}, error() {} };

async function server(database) {
  return createDatafnServer({
    schema: bookmarksSchema,
    database,
    // The host's authorization decides who may act; these tests act as the owner.
    allowUnknownResources: true,
    namespaceProvider: { getNamespace: (context) => context.userId },
    observability: { logger: silent }
  });
}

/**
 * `another(beforeUpsert)` is a second datafn server on the same database; `beforeUpsert(args)` runs before each
 * adapter upsert (how datafn writes a join row, after it checked that both ends exist).
 */
function hostOn(db, extra) {
  const another = (beforeUpsert) =>
    server(
      beforeUpsert
        ? new Proxy(db, {
            get: (target, key) =>
              key === 'upsert' ? async (args) => (await beforeUpsert(args), target.upsert(args)) : typeof target[key] === 'function' ? target[key].bind(target) : target[key]
          })
        : db
    );
  return server(db).then((main) => ({ server: main, another, ...extra }));
}

export const BACKENDS = {
  async memory() {
    return hostOn(memoryAdapter(), { close: async () => {} });
  },
  async sqlite() {
    const sqlite = new Database(':memory:');
    // better-sqlite3 and D1 enforce foreign keys by default; set here so the tests do not depend on that.
    sqlite.pragma('foreign_keys = ON');
    sqlite.exec(migrationSql('sqlite'));
    const db = drizzleAdapter({ db: drizzleSqlite(sqlite, { schema: drizzleTables(sqliteTable, sqliteColumn) }), dialect: 'sqlite' });
    return hostOn(db, { raw: sqlite, close: async () => sqlite.close() });
  },
  async postgres() {
    const pglite = new PGlite();
    await pglite.exec(migrationSql('postgres'));
    const db = drizzleAdapter({ db: drizzlePglite(pglite, { schema: drizzleTables(pgTable, postgresColumn) }), dialect: 'postgres' });
    return hostOn(db, { pglite, close: async () => pglite.close() });
  }
};

/** Minimal `LinkDetailsV1` for `url`. */
export const sampleDetails = (url, title) => ({
  version: 1,
  url,
  title,
  icons: [{ url: new URL('/favicon.ico', url).href, rel: 'icon' }],
  contentType: 'text/html'
});

/**
 * Stores fetched details through the executor the way the details runner (SET-175) does: only while the bookmark is
 * still on the job's page with the job's request. Given a bookmark instead of a job, it stores for that bookmark's
 * page and the request the bookmark has now.
 */
export async function storeDetails(executor, target, fields, userId = 'owner') {
  let job = target;
  if (!('bookmarkId' in target)) {
    const { data } = await executor.query({ version: 1, resource: 'bookmarks', select: ['detailsRequest'], filters: { id: target.id }, limit: 1 }, { userId });
    job = { bookmarkId: target.id, canonicalUrl: target.canonicalUrl, detailsRequest: data[0].detailsRequest };
  }
  const result = await executor.mutate(
    {
      version: 1,
      resource: 'bookmarks',
      operation: 'merge',
      id: job.bookmarkId,
      record: { detailsState: 'ready', detailsError: null, ...fields },
      if: { id: job.bookmarkId, detailsRequest: job.detailsRequest, canonicalUrl: job.canonicalUrl }
    },
    { userId }
  );
  if (result?.ok !== true) throw new Error(`storing details failed: ${JSON.stringify(result?.errors)}`);
}

/** A DetailsQueue that records jobs and, like @superfunctions/queue, ignores the dedupeKey of a job not yet done. */
export function recordingQueue() {
  const jobs = [];
  return {
    jobs,
    async enqueue(job, options) {
      if (jobs.some((entry) => entry.options.dedupeKey === options.dedupeKey && !entry.done)) return { deduplicated: true };
      jobs.push({ job, options, done: false });
      return { deduplicated: false };
    }
  };
}

export async function setup(backend, userId = 'owner') {
  const host = await BACKENDS[backend]();
  const queue = recordingQueue();
  const ops = createBookmarkOperations({ executor: host.server.executor, detailsQueue: queue, context: { userId } });
  const forUser = (otherUserId, detailsQueue = recordingQueue()) =>
    createBookmarkOperations({ executor: host.server.executor, detailsQueue, context: { userId: otherUserId } });
  return { ...host, ops, queue, forUser };
}

/**
 * Wraps an executor so a test can pause or fail chosen calls. `beforeQuery` and `beforeMutate` run before the call
 * and `afterQuery` and `afterMutate` after it; a hook that throws fails the call as a broken database or network
 * would.
 */
export function hookedExecutor(executor, { beforeQuery, afterQuery, beforeMutate, afterMutate } = {}) {
  return {
    async query(payload, context) {
      await beforeQuery?.(payload);
      const result = await executor.query(payload, context);
      await afterQuery?.(payload, result);
      return result;
    },
    async mutate(payload, context) {
      await beforeMutate?.(payload);
      const result = await executor.mutate(payload, context);
      await afterMutate?.(payload, result);
      return result;
    }
  };
}

/** Holds the first caller of `pause()` until `release()`; `reached` resolves once it is held. Later callers pass. */
export function pausePoint() {
  let release;
  let reach;
  const released = new Promise((resolve) => (release = resolve));
  const reached = new Promise((resolve) => (reach = resolve));
  let used = false;
  return {
    reached,
    release,
    async pause() {
      if (used) return;
      used = true;
      reach();
      await released;
    }
  };
}
