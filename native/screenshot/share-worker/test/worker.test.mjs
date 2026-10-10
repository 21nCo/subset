// Runs the compiled Worker against in-memory R2 and D1 stand-ins. `npm test` compiles first.
import assert from "node:assert/strict";
import { test } from "node:test";
import worker from "../.test-build/index.js";

function makeEnv({ token = "secret-token" } = {}) {
  const media = new Map();
  const objects = new Map();
  const DB = {
    prepare(sql) {
      let args = [];
      const statement = {
        bind(...values) { args = values; return statement; },
        async first() {
          if (sql.startsWith("SELECT * FROM media WHERE id = ?")) return media.get(args[0]) ?? null;
          throw new Error(`Unexpected first(): ${sql}`);
        },
        async all() {
          if (sql.includes("FROM comments")) return { results: [] };
          if (sql.includes("FROM media")) return { results: [...media.values()] };
          throw new Error(`Unexpected all(): ${sql}`);
        },
        async run() {
          if (sql.includes("INSERT INTO media")) {
            const [id, object_key, name, extension, content_type, byte_size, created_at, updated_at] = args;
            media.set(id, { id, object_key, name, extension, content_type, byte_size, width: null, height: null, created_at, updated_at, expires_at: null, password_hash: null, tags: "[]", views: 0, downloads: 0 });
          } else if (sql.startsWith("UPDATE media SET name")) {
            const [name, password_hash, expires_at, tags, updated_at, id] = args;
            Object.assign(media.get(id), { name, password_hash, expires_at, tags, updated_at });
          } else if (sql.startsWith("DELETE FROM media")) {
            media.delete(args[0]);
          }
          return { success: true };
        },
      };
      return statement;
    },
  };
  const MEDIA = {
    async put(key, body, options) {
      const bytes = new Uint8Array(await new Response(body).arrayBuffer());
      objects.set(key, { bytes, options });
      return { size: bytes.byteLength };
    },
    async get(key, options) {
      const stored = objects.get(key);
      if (!stored) return null;
      const range = options?.range;
      const bytes = range ? stored.bytes.slice(range.offset, range.offset + range.length) : stored.bytes;
      return {
        body: bytes,
        size: stored.bytes.byteLength,
        range,
        httpEtag: '"etag"',
        writeHttpMetadata(headers) { headers.set("content-type", stored.options.httpMetadata.contentType); },
      };
    },
    async delete(key) { objects.delete(key); },
  };
  return { env: { DB, MEDIA, UPLOAD_TOKEN: token }, media };
}

const call = (env, path, init = {}) => worker.fetch(new Request(`https://share.test${path}`, init), env);
const auth = (token = "secret-token") => ({ authorization: `Bearer ${token}` });

async function upload(env, bytes = new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])) {
  const response = await call(env, "/api/uploads?name=Shot", {
    method: "POST",
    headers: { ...auth(), "content-type": "image/png" },
    body: bytes,
  });
  assert.equal(response.status, 201);
  return response.json();
}

test("rejects every authenticated route when UPLOAD_TOKEN is missing", async () => {
  const { env } = makeEnv({ token: "" });
  for (const [path, method] of [["/api/uploads", "GET"], ["/api/uploads", "POST"], ["/api/uploads/abc", "DELETE"]]) {
    const response = await call(env, path, { method, headers: { authorization: "Bearer undefined", "content-type": "image/png" }, body: method === "POST" ? "x" : undefined });
    assert.equal(response.status, 503, `${method} ${path}`);
  }
});

test("rejects a wrong upload token", async () => {
  const { env } = makeEnv();
  assert.equal((await call(env, "/api/uploads", { headers: auth("wrong") })).status, 401);
  assert.equal((await call(env, "/api/uploads", { headers: auth() })).status, 200);
});

test("issues share IDs with the full UUID entropy", async () => {
  const { env } = makeEnv();
  const { id } = await upload(env);
  assert.match(id, /^[0-9a-f]{32}$/);
});

test("serves suffix byte ranges from the end of the file", async () => {
  const { env } = makeEnv();
  const { id } = await upload(env);
  const response = await call(env, `/media/${id}`, { headers: { range: "bytes=-3" } });
  assert.equal(response.status, 206);
  assert.equal(response.headers.get("content-range"), "bytes 7-9/10");
  assert.deepEqual([...new Uint8Array(await response.arrayBuffer())], [7, 8, 9]);
});

test("never lets shared caches store media", async () => {
  const { env } = makeEnv();
  const { id } = await upload(env);
  const open = await call(env, `/media/${id}`);
  assert.equal(open.headers.get("cache-control"), "private, no-cache");
  await call(env, `/api/uploads/${id}`, { method: "PATCH", headers: auth(), body: JSON.stringify({ expiresAt: "2999-01-01T00:00:00Z" }) });
  assert.equal((await call(env, `/media/${id}`)).headers.get("cache-control"), "private, no-store");
});

test("stores salted password hashes and verifies them", async () => {
  const { env, media } = makeEnv();
  const { id } = await upload(env);
  await call(env, `/api/uploads/${id}`, { method: "PATCH", headers: auth(), body: JSON.stringify({ password: "hunter2" }) });
  const stored = media.get(id).password_hash;
  assert.match(stored, /^pbkdf2\$100000\$[0-9a-f]{32}\$[0-9a-f]{64}$/);
  assert.equal((await call(env, `/api/share/${id}`)).status, 401);
  assert.equal((await call(env, `/api/share/${id}?p=wrong`)).status, 401);
  assert.equal((await call(env, `/api/share/${id}?p=hunter2`)).status, 200);
});

test("PATCH without password or expiresAt keeps existing restrictions", async () => {
  const { env, media } = makeEnv();
  const { id } = await upload(env);
  await call(env, `/api/uploads/${id}`, { method: "PATCH", headers: auth(), body: JSON.stringify({ password: "pw", expiresAt: "2999-01-01T00:00:00Z" }) });
  const before = { ...media.get(id) };
  await call(env, `/api/uploads/${id}`, { method: "PATCH", headers: auth(), body: JSON.stringify({ tags: ["a"] }) });
  assert.equal(media.get(id).password_hash, before.password_hash);
  assert.equal(media.get(id).expires_at, before.expires_at);
  assert.equal(media.get(id).tags, '["a"]');
});
