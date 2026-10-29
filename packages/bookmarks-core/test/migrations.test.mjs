import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PGlite } from '@electric-sql/pglite';
import Database from 'better-sqlite3';
import { bookmarksTables } from '../dist/index.js';
import { DIALECTS, INITIAL_MIGRATION, renderMigration } from '../scripts/generate-migrations.mjs';
import { migrationSql } from './support.mjs';

const tableNames = Object.keys(bookmarksTables).sort();
const columnsOf = (model) => Object.entries(bookmarksTables[model].fields);
const uniqueIndexes = Object.values(bookmarksTables).flatMap((table) =>
  (table.indexes ?? []).filter((index) => index.unique).map((index) => ({ table: table.modelName, ...index }))
);

test('the checked-in migrations are the generator output', () => {
  assert.equal(INITIAL_MIGRATION, '0001_initial.sql');
  for (const dialect of DIALECTS) {
    assert.equal(migrationSql(dialect), renderMigration(bookmarksTables, dialect), `migrations/${dialect} is stale: run npm run migrations`);
  }
});

test('the generator refuses what it cannot render', () => {
  const table = (fields) => ({ t: { modelName: 't', fields: { id: { type: 'string', required: true }, __ns: { type: 'string', required: true }, ...fields } } });
  assert.throws(() => renderMigration(table({ n: { type: 'datetime' } }), 'sqlite'), /no SQL type/);
  assert.throws(() => renderMigration(table({ n: { type: 'string', unique: true } }), 'sqlite'), /index/);
  assert.throws(() => renderMigration(table({ 'bad name': { type: 'string' } }), 'postgres'), /Unsafe SQL identifier/);
  assert.throws(() => renderMigration({ t: { modelName: 't', fields: { id: { type: 'string', required: true } } } }, 'sqlite'), /__ns/);
  assert.throws(() => renderMigration(table({}), 'mysql'), /Unknown dialect/);
  assert.throws(() => renderMigration(table({ r: { type: 'string', references: { model: 't', field: 'id', onDelete: 'restrict' } } }), 'sqlite'), /onDelete cascade/);
  assert.throws(() => renderMigration(table({ r: { type: 'string', references: { model: 'gone', field: 'id', onDelete: 'cascade' } } }), 'sqlite'), /onDelete cascade/);
});

/** The join-row references: each end goes with its bookmark or tag in the same namespace. */
const joinReferences = [
  ['from', 'bookmarks'],
  ['to', 'tags']
];

/** Inserts a bookmark row with only the required columns. */
function bookmarkRow(overrides) {
  return {
    id: 'b1',
    __ns: 'u1',
    apiId: 1,
    url: 'https://a.example/',
    canonicalUrl: 'https://a.example/',
    unread: false,
    archived: false,
    detailsState: 'pending',
    createdAt: 1,
    updatedAt: 1,
    ...overrides
  };
}

test('SQLite: the migration builds every table, column, key and index on an empty database', () => {
  const db = new Database(':memory:');
  db.exec(migrationSql('sqlite'));
  const tables = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all().map((row) => row.name);
  assert.deepEqual(tables, tableNames);
  for (const model of tableNames) {
    const info = db.prepare(`PRAGMA table_info("${model}")`).all();
    assert.deepEqual(
      info.map((column) => [column.name, column.notnull === 1 || column.pk > 0]),
      columnsOf(model).map(([name, field]) => [name, field.required === true]),
      model
    );
    assert.deepEqual(info.filter((column) => column.pk > 0).sort((a, b) => a.pk - b.pk).map((column) => column.name), ['__ns', 'id'], model);
  }
  for (const index of uniqueIndexes) {
    const row = db.prepare("SELECT tbl_name FROM sqlite_master WHERE type = 'index' AND name = ?").get(index.name);
    assert.equal(row?.tbl_name, index.table, index.name);
    assert.deepEqual(db.prepare(`PRAGMA index_info("${index.name}")`).all().map((column) => column.name), index.fields);
  }

  const insert = (row) => {
    const values = { ...row, unread: row.unread ? 1 : 0, archived: row.archived ? 1 : 0 };
    const names = Object.keys(values);
    db.prepare(`INSERT INTO bookmarks (${names.map((name) => `"${name}"`).join(', ')}) VALUES (${names.map((name) => `@${name}`).join(', ')})`).run(values);
  };
  insert(bookmarkRow({}));
  assert.throws(() => insert(bookmarkRow({ id: 'b2', apiId: 2 })), /UNIQUE constraint failed: bookmarks.__ns, bookmarks.canonicalUrl/);
  assert.throws(() => insert(bookmarkRow({ id: 'b2', canonicalUrl: 'https://b.example/' })), /UNIQUE constraint failed: bookmarks.__ns, bookmarks.apiId/);
  assert.throws(() => insert(bookmarkRow({ id: 'b2', apiId: 2, canonicalUrl: 'https://b.example/', detailsState: 'done' })), /CHECK constraint failed/);
  // Another user may hold the same id, URL and apiId.
  insert(bookmarkRow({ __ns: 'u2' }));
  db.prepare(`INSERT INTO tags (id, __ns, name, "nameKey") VALUES ('t1', 'u1', 'Rust', 'rust')`).run();
  assert.throws(() => db.prepare(`INSERT INTO tags (id, __ns, name, "nameKey") VALUES ('t2', 'u1', 'RUST', 'rust')`).run(), /UNIQUE/);

  const keys = db.prepare('PRAGMA foreign_key_list("bookmark_tags")').all();
  for (const [column, table] of joinReferences) {
    const key = keys.filter((row) => row.table === table).sort((a, b) => a.seq - b.seq);
    assert.deepEqual(key.map((row) => [row.from, row.to, row.on_delete]), [['__ns', '__ns', 'CASCADE'], [column, 'id', 'CASCADE']], table);
  }
  db.pragma('foreign_keys = ON');
  const link = (id, from, to, ns = 'u1') => db.prepare('INSERT INTO bookmark_tags (id, __ns, "from", "to") VALUES (?, ?, ?, ?)').run(id, ns, from, to);
  const links = () => db.prepare('SELECT count(*) AS n FROM bookmark_tags').get().n;
  assert.throws(() => link('x:t1', 'x', 't1'), /FOREIGN KEY constraint failed/);
  assert.throws(() => link('b1:x', 'b1', 'x'), /FOREIGN KEY constraint failed/);
  // Another user's bookmark with the same id is not this user's.
  assert.throws(() => link('b1:t1', 'b1', 't1', 'u2'), /FOREIGN KEY constraint failed/);
  link('b1:t1', 'b1', 't1');
  db.prepare("DELETE FROM bookmarks WHERE id = 'b1' AND __ns = 'u1'").run();
  assert.equal(links(), 0);
  insert(bookmarkRow({}));
  link('b1:t1', 'b1', 't1');
  db.prepare("DELETE FROM tags WHERE id = 't1'").run();
  assert.equal(links(), 0);
  db.close();
});

test('Postgres (PGlite): the migration builds every table, column type, key and index on an empty database', async () => {
  const pg = new PGlite();
  try {
    await pg.exec(migrationSql('postgres'));
    const { rows: tables } = await pg.query("SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name");
    assert.deepEqual(
      tables.map((row) => row.table_name),
      tableNames
    );
    const expectedType = { string: 'text', number: 'bigint', boolean: 'boolean', json: 'jsonb', date: 'bigint' };
    for (const model of tableNames) {
      const { rows } = await pg.query(
        'SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = $1 ORDER BY ordinal_position',
        [model]
      );
      assert.deepEqual(
        rows.map((row) => [row.column_name, row.data_type, row.is_nullable === 'NO']),
        columnsOf(model).map(([name, field]) => [name, expectedType[field.type], field.required === true]),
        model
      );
      const { rows: key } = await pg.query(
        `SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
         WHERE i.indrelid = $1::regclass AND i.indisprimary ORDER BY array_position(i.indkey, a.attnum)`,
        [`"${model}"`]
      );
      assert.deepEqual(
        key.map((row) => row.attname),
        ['__ns', 'id'],
        model
      );
    }
    for (const index of uniqueIndexes) {
      const { rows } = await pg.query('SELECT tablename, indexdef FROM pg_indexes WHERE indexname = $1', [index.name]);
      assert.equal(rows[0]?.tablename, index.table, index.name);
      assert.match(rows[0].indexdef, new RegExp(`^CREATE UNIQUE INDEX .* \\(${index.fields.map((field) => `"?${field}"?`).join(', ')}\\)$`));
    }

    const insert = (row) => {
      const names = Object.keys(row);
      return pg.query(
        `INSERT INTO bookmarks (${names.map((name) => `"${name}"`).join(', ')}) VALUES (${names.map((_, n) => `$${n + 1}`).join(', ')})`,
        Object.values(row)
      );
    };
    await insert(bookmarkRow({ details: { version: 1 } }));
    await assert.rejects(insert(bookmarkRow({ id: 'b2', apiId: 2 })), /bookmarks_ns_canonical_url/);
    await assert.rejects(insert(bookmarkRow({ id: 'b2', canonicalUrl: 'https://b.example/' })), /bookmarks_ns_api_id/);
    await assert.rejects(insert(bookmarkRow({ id: 'b2', apiId: 2, canonicalUrl: 'https://b.example/', detailsState: 'done' })), /bookmarks_details_state/);
    await insert(bookmarkRow({ __ns: 'u2', createdAt: 1_800_000_000_000 }));
    await pg.query(`INSERT INTO tags (id, __ns, name, "nameKey") VALUES ('t1', 'u1', 'Rust', 'rust')`);
    await assert.rejects(pg.query(`INSERT INTO tags (id, __ns, name, "nameKey") VALUES ('t2', 'u1', 'RUST', 'rust')`), /tags_ns_name_key/);

    const { rows: keys } = await pg.query(
      `SELECT confrelid::regclass::text AS "table", confdeltype, ARRAY(SELECT attname FROM unnest(conkey) WITH ORDINALITY k(n, o) JOIN pg_attribute a
         ON a.attrelid = conrelid AND a.attnum = k.n ORDER BY k.o)::text AS columns
       FROM pg_constraint WHERE conrelid = 'bookmark_tags'::regclass AND contype = 'f' ORDER BY 1`
    );
    assert.deepEqual(
      keys.map((row) => [row.table, row.columns, row.confdeltype]),
      joinReferences.map(([column, table]) => [table, `{__ns,${column}}`, 'c'])
    );
    const link = (id, from, to, ns = 'u1') => pg.query('INSERT INTO bookmark_tags (id, __ns, "from", "to") VALUES ($1, $2, $3, $4)', [id, ns, from, to]);
    const links = async () => (await pg.query('SELECT count(*)::int AS n FROM bookmark_tags')).rows[0].n;
    await assert.rejects(link('x:t1', 'x', 't1'), /foreign key/);
    await assert.rejects(link('b1:x', 'b1', 'x'), /foreign key/);
    await assert.rejects(link('b1:t1', 'b1', 't1', 'u2'), /foreign key/);
    await link('b1:t1', 'b1', 't1');
    await pg.query("DELETE FROM bookmarks WHERE id = 'b1' AND __ns = 'u1'");
    assert.equal(await links(), 0);
    await insert(bookmarkRow({}));
    await link('b1:t1', 'b1', 't1');
    await pg.query("DELETE FROM tags WHERE id = 't1'");
    assert.equal(await links(), 0);
    // apiId and its claims are 64-bit, past the last 32-bit value.
    await insert(bookmarkRow({ id: 'b3', apiId: 2 ** 31, canonicalUrl: 'https://c.example/' }));
    await pg.query("INSERT INTO bookmark_api_ids (id, __ns, value) VALUES ('2147483648', 'u1', 2147483648)");
  } finally {
    await pg.close();
  }
});
