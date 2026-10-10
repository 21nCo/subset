interface Env {
  MEDIA: R2Bucket;
  DB: D1Database;
  UPLOAD_TOKEN: string;
}

interface MediaRow {
  id: string;
  object_key: string;
  name: string;
  extension: string;
  content_type: string;
  byte_size: number;
  width: number | null;
  height: number | null;
  created_at: string;
  updated_at: string;
  expires_at: string | null;
  password_hash: string | null;
  tags: string;
  views: number;
  downloads: number;
}

interface CommentRow {
  id: string;
  media_id: string;
  author: string;
  body: string;
  created_at: string;
}

const encoder = new TextEncoder();
const allowedContentTypes = new Set([
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "video/mp4",
  "video/quicktime",
]);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }));
      if (url.pathname === "/health") {
        return json({ ok: true, service: "Subset Screenshot Share", time: new Date().toISOString() });
      }

      if (url.pathname === "/api/uploads" && request.method === "POST") {
        await requireAuthorization(request, env);
        return cors(await createUpload(request, env, url));
      }
      if (url.pathname === "/api/uploads" && request.method === "GET") {
        await requireAuthorization(request, env);
        return cors(await listUploads(env));
      }

      const uploadMatch = url.pathname.match(/^\/api\/uploads\/([a-zA-Z0-9_-]+)$/);
      if (uploadMatch) {
        await requireAuthorization(request, env);
        if (request.method === "PATCH") return cors(await updateUpload(request, env, uploadMatch[1]));
        if (request.method === "DELETE") return cors(await deleteUpload(env, uploadMatch[1]));
      }

      const shareAPIMatch = url.pathname.match(/^\/api\/share\/([a-zA-Z0-9_-]+)$/);
      if (shareAPIMatch && request.method === "GET") return cors(await shareMetadata(env, shareAPIMatch[1], url));

      const commentsMatch = url.pathname.match(/^\/api\/share\/([a-zA-Z0-9_-]+)\/comments$/);
      if (commentsMatch && request.method === "POST") return cors(await createComment(request, env, commentsMatch[1], url));

      const shareMatch = url.pathname.match(/^\/s\/([a-zA-Z0-9_-]+)$/);
      if (shareMatch && request.method === "GET") return await sharePage(env, shareMatch[1], url);

      const mediaMatch = url.pathname.match(/^\/(media|download)\/([a-zA-Z0-9_-]+)$/);
      if (mediaMatch && request.method === "GET") {
        return await serveMedia(request, env, mediaMatch[2], mediaMatch[1] === "download", url);
      }

      if (url.pathname === "/") return new Response(homePage(), { headers: htmlHeaders() });
      return json({ error: "Not found" }, 404);
    } catch (error) {
      const status = error instanceof HTTPError ? error.status : 500;
      const message = error instanceof Error ? error.message : "Internal error";
      return cors(json({ error: message }, status));
    }
  },
};

async function createUpload(request: Request, env: Env, url: URL): Promise<Response> {
  const contentType = (request.headers.get("content-type") || "application/octet-stream").split(";")[0];
  if (!allowedContentTypes.has(contentType)) throw new HTTPError(415, "Unsupported media type");
  const declaredLength = Number(request.headers.get("content-length") || "0");
  if (declaredLength > 1024 * 1024 * 1024) throw new HTTPError(413, "File exceeds 1 GB");
  if (!request.body) throw new HTTPError(400, "Missing upload body");

  const id = compactID();
  const extension = sanitizeExtension(request.headers.get("x-file-extension") || extensionFor(contentType));
  const name = sanitizeName(url.searchParams.get("name") || `Capture ${new Date().toISOString()}`);
  const objectKey = `media/${id}.${extension}`;
  const createdAt = new Date().toISOString();

  const object = await env.MEDIA.put(objectKey, request.body, {
    httpMetadata: { contentType },
    customMetadata: { id, name, createdAt },
  });
  await env.DB.prepare(
    `INSERT INTO media
      (id, object_key, name, extension, content_type, byte_size, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(id, objectKey, name, extension, contentType, object.size, createdAt, createdAt).run();

  return json({
    id,
    share_url: `${url.origin}/s/${id}`,
    download_url: `${url.origin}/download/${id}`,
  }, 201);
}

async function listUploads(env: Env): Promise<Response> {
  const rows = await env.DB.prepare(
    "SELECT id, name, content_type, byte_size, created_at, expires_at, tags, views, downloads FROM media ORDER BY created_at DESC LIMIT 250",
  ).all();
  return json({ items: rows.results });
}

async function updateUpload(request: Request, env: Env, id: string): Promise<Response> {
  const current = await getMedia(env, id);
  const payload = await request.json<{
    name?: string;
    password?: string | null;
    expiresAt?: string | null;
    tags?: string[];
  }>();
  const name = payload.name === undefined ? current.name : sanitizeName(payload.name);
  const passwordHash = payload.password === undefined
    ? current.password_hash
    : payload.password ? await hashPassword(payload.password) : null;
  const expiresAt = payload.expiresAt === undefined ? current.expires_at : payload.expiresAt;
  if (expiresAt && Number.isNaN(Date.parse(expiresAt))) throw new HTTPError(400, "Invalid expiration date");
  if (payload.tags !== undefined && (!Array.isArray(payload.tags) || payload.tags.some((tag) => typeof tag !== "string"))) {
    throw new HTTPError(400, "Tags must be an array of strings");
  }
  const tags = payload.tags === undefined ? current.tags : JSON.stringify(payload.tags.slice(0, 24).map(sanitizeName));
  const updatedAt = new Date().toISOString();
  await env.DB.prepare(
    "UPDATE media SET name = ?, password_hash = ?, expires_at = ?, tags = ?, updated_at = ? WHERE id = ?",
  ).bind(name, passwordHash, expiresAt, tags, updatedAt, id).run();
  return json({ ok: true, id, updated_at: updatedAt });
}

async function deleteUpload(env: Env, id: string): Promise<Response> {
  const row = await getMedia(env, id);
  await env.MEDIA.delete(row.object_key);
  await env.DB.prepare("DELETE FROM media WHERE id = ?").bind(id).run();
  return new Response(null, { status: 204 });
}

async function shareMetadata(env: Env, id: string, url: URL): Promise<Response> {
  const row = await getMedia(env, id);
  await verifyPublicAccess(row, url);
  const comments = await env.DB.prepare(
    "SELECT id, author, body, created_at FROM comments WHERE media_id = ? ORDER BY created_at ASC LIMIT 250",
  ).bind(id).all<CommentRow>();
  return json({
    id: row.id,
    name: row.name,
    content_type: row.content_type,
    byte_size: row.byte_size,
    created_at: row.created_at,
    expires_at: row.expires_at,
    tags: JSON.parse(row.tags),
    views: row.views,
    downloads: row.downloads,
    media_url: `/media/${id}${url.search}`,
    download_url: `/download/${id}${url.search}`,
    comments: comments.results,
  });
}

async function createComment(request: Request, env: Env, mediaID: string, url: URL): Promise<Response> {
  const row = await getMedia(env, mediaID);
  await verifyPublicAccess(row, url);
  const payload = await request.json<{ author?: string; body?: string }>();
  const author = sanitizeName(payload.author || "Guest").slice(0, 80);
  const body = (payload.body || "").trim().slice(0, 4000);
  if (!body) throw new HTTPError(400, "Comment is empty");
  const id = compactID();
  const createdAt = new Date().toISOString();
  await env.DB.prepare(
    "INSERT INTO comments (id, media_id, author, body, created_at) VALUES (?, ?, ?, ?, ?)",
  ).bind(id, mediaID, author, body, createdAt).run();
  return json({ id, author, body, created_at: createdAt }, 201);
}

async function sharePage(env: Env, id: string, url: URL): Promise<Response> {
  let row: MediaRow;
  try { row = await getMedia(env, id); }
  catch { return new Response(notFoundPage(), { status: 404, headers: htmlHeaders() }); }
  if (isExpired(row)) return new Response(expiredPage(), { status: 410, headers: htmlHeaders() });
  if (row.password_hash && !(await passwordMatches(row, url.searchParams.get("p")))) {
    return new Response(passwordPage(row.name), { status: 401, headers: htmlHeaders() });
  }
  await env.DB.prepare("UPDATE media SET views = views + 1 WHERE id = ?").bind(id).run();
  const comments = await env.DB.prepare(
    "SELECT id, author, body, created_at FROM comments WHERE media_id = ? ORDER BY created_at ASC LIMIT 250",
  ).bind(id).all<CommentRow>();
  return new Response(renderSharePage(row, comments.results, url.search), { headers: htmlHeaders() });
}

async function serveMedia(request: Request, env: Env, id: string, download: boolean, url: URL): Promise<Response> {
  const row = await getMedia(env, id);
  await verifyPublicAccess(row, url);
  const rangeHeader = request.headers.get("range");
  const range = rangeHeader ? parseRange(rangeHeader, row.byte_size) : undefined;
  const object = await env.MEDIA.get(row.object_key, range ? { range } : undefined);
  if (!object) throw new HTTPError(404, "Media not found");
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  // Access can change at any time (expiry, a new password, deletion), so shared caches must
  // never serve media without going back through verifyPublicAccess.
  headers.set("cache-control", row.password_hash || row.expires_at ? "private, no-store" : "private, no-cache");
  headers.set("content-security-policy", "default-src 'none'");
  headers.set("x-content-type-options", "nosniff");
  if (download) {
    headers.set("content-disposition", `attachment; filename="${asciiFileName(row.name)}.${row.extension}"`);
    await env.DB.prepare("UPDATE media SET downloads = downloads + 1 WHERE id = ?").bind(id).run();
  }
  if (range && object.range) {
    headers.set("content-range", `bytes ${range.offset}-${range.offset + range.length - 1}/${row.byte_size}`);
    headers.set("content-length", String(range.length));
    headers.set("accept-ranges", "bytes");
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("content-length", String(object.size));
  return new Response(object.body, { headers });
}

async function getMedia(env: Env, id: string): Promise<MediaRow> {
  const row = await env.DB.prepare("SELECT * FROM media WHERE id = ?").bind(id).first<MediaRow>();
  if (!row) throw new HTTPError(404, "Media not found");
  return row;
}

async function verifyPublicAccess(row: MediaRow, url: URL): Promise<void> {
  if (isExpired(row)) throw new HTTPError(410, "This link has expired");
  if (row.password_hash && !(await passwordMatches(row, url.searchParams.get("p")))) {
    throw new HTTPError(401, "Password required");
  }
}

async function requireAuthorization(request: Request, env: Env): Promise<void> {
  // Fail closed: a deployment without the secret must not accept `Bearer undefined`.
  if (typeof env.UPLOAD_TOKEN !== "string" || env.UPLOAD_TOKEN.length === 0) {
    throw new HTTPError(503, "Uploads are not configured");
  }
  const header = request.headers.get("authorization") || "";
  if (!(await constantTimeEqual(header, `Bearer ${env.UPLOAD_TOKEN}`))) throw new HTTPError(401, "Unauthorized");
}

async function passwordMatches(row: MediaRow, password: string | null): Promise<boolean> {
  if (!password || !row.password_hash) return false;
  const [scheme, iterations, salt, expected] = row.password_hash.split("$");
  if (scheme !== "pbkdf2" || !iterations || !salt || !expected) return false;
  const actual = await pbkdf2(password, hexToBytes(salt), Number(iterations));
  return timingSafeEqualBytes(encoder.encode(actual), encoder.encode(expected));
}

function isExpired(row: MediaRow): boolean {
  return Boolean(row.expires_at && Date.parse(row.expires_at) <= Date.now());
}

function parseRange(value: string, size: number): { offset: number; length: number } | undefined {
  const match = value.match(/^bytes=(\d*)-(\d*)$/);
  if (!match || (!match[1] && !match[2])) return undefined;
  // `bytes=-N` is a suffix range: the last N bytes (RFC 9110 section 14.1.1).
  const start = match[1] ? Number(match[1]) : Math.max(0, size - Number(match[2]));
  const end = match[1] && match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
  if (!Number.isFinite(start) || !Number.isFinite(end) || start > end || start >= size) return undefined;
  return { offset: start, length: end - start + 1 };
}

function renderSharePage(row: MediaRow, comments: CommentRow[], search: string): string {
  const media = row.content_type.startsWith("video/")
    ? `<video controls autoplay playsinline src="/media/${row.id}${escapeAttribute(search)}"></video>`
    : `<img src="/media/${row.id}${escapeAttribute(search)}" alt="${escapeAttribute(row.name)}">`;
  const tags = (JSON.parse(row.tags) as string[]).map((tag) => `<span class="tag">${escapeHTML(tag)}</span>`).join("");
  const commentMarkup = comments.length
    ? comments.map((comment) => `<article><strong>${escapeHTML(comment.author)}</strong><time>${escapeHTML(new Date(comment.created_at).toLocaleString())}</time><p>${escapeHTML(comment.body)}</p></article>`).join("")
    : `<p class="muted">No comments yet.</p>`;
  const commentEndpoint = inlineJSONString(`/api/share/${row.id}/comments${search}`);
  return pageShell(row.name, `
    <main>
      <header><a class="brand" href="/">Screenshot</a><a class="download" href="/download/${row.id}${escapeAttribute(search)}">Download</a></header>
      <section class="stage">${media}</section>
      <section class="details">
        <div><h1>${escapeHTML(row.name)}</h1><p class="muted">${formatBytes(row.byte_size)} · ${row.views + 1} views · ${escapeHTML(new Date(row.created_at).toLocaleString())}</p><div>${tags}</div></div>
      </section>
      <section class="comments"><h2>Comments</h2>${commentMarkup}
        <form id="comment-form"><input name="author" maxlength="80" placeholder="Your name"><textarea name="body" maxlength="4000" required placeholder="Leave a comment"></textarea><button>Post comment</button></form>
      </section>
    </main>
    <script>
      document.querySelector('#comment-form').addEventListener('submit', async (event) => {
        event.preventDefault();
        const form = new FormData(event.target);
        const response = await fetch(${commentEndpoint}, { method: 'POST', headers: {'content-type':'application/json'}, body: JSON.stringify({author: form.get('author'), body: form.get('body')}) });
        if (response.ok) location.reload(); else alert('Unable to post comment.');
      });
    </script>`);
}

function passwordPage(name: string): string {
  return pageShell("Password required", `<main class="center"><section class="card"><div class="lock">⌁</div><h1>${escapeHTML(name)}</h1><p class="muted">This capture is password protected.</p><form method="get"><input type="password" name="p" autofocus required placeholder="Password"><button>View capture</button></form></section></main>`);
}

function notFoundPage(): string {
  return pageShell("Not found", `<main class="center"><section class="card"><h1>Capture not found</h1><p class="muted">The link may have been removed.</p></section></main>`);
}

function expiredPage(): string {
  return pageShell("Expired", `<main class="center"><section class="card"><h1>This link has expired</h1><p class="muted">Ask the owner for a new capture link.</p></section></main>`);
}

function homePage(): string {
  return pageShell("Subset Screenshot Share", `<main class="center"><section class="card"><div class="logo">◎</div><h1>Subset Screenshot Share</h1><p class="muted">Fast, private screenshot and screen-recording links from the native macOS app.</p></section></main>`);
}

function pageShell(title: string, body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHTML(title)}</title><style>
    :root{color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif;background:#0a0a0d;color:#f5f5f7}*{box-sizing:border-box}body{margin:0;min-height:100vh;background:radial-gradient(circle at 20% 0,#35206755,transparent 34%),#0a0a0d}main{max-width:1240px;margin:auto;padding:28px}header{height:56px;display:flex;align-items:center;justify-content:space-between}.brand{font-weight:750;letter-spacing:-.02em;color:white;text-decoration:none}.download,button{border:0;border-radius:10px;padding:10px 16px;background:#7c4dff;color:white;font-weight:650;text-decoration:none;cursor:pointer}.stage{display:grid;place-items:center;min-height:400px;padding:24px;border:1px solid #ffffff18;border-radius:20px;background:#0008;box-shadow:0 28px 80px #0008}.stage img,.stage video{display:block;max-width:100%;max-height:72vh;border-radius:8px;box-shadow:0 18px 60px #000a}.details{padding:24px 4px}.details h1{margin:0 0 8px;font-size:25px}.muted{color:#a5a5ad}.tag{display:inline-block;padding:4px 9px;margin:6px 6px 0 0;border-radius:99px;background:#ffffff12;color:#c9b9ff;font-size:12px}.comments{max-width:720px;padding:20px 4px 60px}.comments article{padding:14px 0;border-bottom:1px solid #ffffff12}.comments time{margin-left:8px;color:#777;font-size:12px}.comments p{white-space:pre-wrap}.comments form,.card form{display:grid;gap:10px;margin-top:20px}input,textarea{width:100%;border:1px solid #ffffff20;border-radius:10px;padding:12px;background:#14141a;color:white;font:inherit}textarea{min-height:90px;resize:vertical}.center{min-height:100vh;display:grid;place-items:center}.card{width:min(460px,90vw);padding:42px;border:1px solid #ffffff18;border-radius:22px;background:#111116cc;text-align:center;box-shadow:0 30px 90px #000}.logo,.lock{font-size:54px;color:#9b7cff}
  </style></head><body>${body}</body></html>`;
}

function htmlHeaders(): Headers {
  return new Headers({
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "content-security-policy": "default-src 'self'; img-src 'self' data:; media-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
  });
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } });
}

function cors(response: Response): Response {
  const next = new Response(response.body, response);
  next.headers.set("access-control-allow-origin", "*");
  next.headers.set("access-control-allow-methods", "GET,POST,PATCH,DELETE,OPTIONS");
  next.headers.set("access-control-allow-headers", "authorization,content-type,x-file-extension");
  return next;
}

// Workers cap PBKDF2 at 100,000 iterations.
const passwordIterations = 100_000;

async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  return `pbkdf2$${passwordIterations}$${bytesToHex(salt)}$${await pbkdf2(password, salt, passwordIterations)}`;
}

async function pbkdf2(password: string, salt: Uint8Array<ArrayBuffer>, iterations: number): Promise<string> {
  if (!Number.isInteger(iterations) || iterations < 1 || iterations > passwordIterations) return "";
  const key = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, key, 256);
  return bytesToHex(new Uint8Array(bits));
}

async function constantTimeEqual(left: string, right: string): Promise<boolean> {
  // Hash both sides so the comparison runs over equal-length digests regardless of input length.
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);
  return timingSafeEqualBytes(new Uint8Array(a), new Uint8Array(b));
}

function timingSafeEqualBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.byteLength !== b.byteLength) return false;
  let difference = 0;
  for (let index = 0; index < a.byteLength; index += 1) difference |= a[index] ^ b[index];
  return difference === 0;
}

function bytesToHex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function hexToBytes(value: string): Uint8Array<ArrayBuffer> {
  const pairs = value.match(/^(?:[0-9a-f]{2})+$/i) ? value.match(/../g)! : [];
  return new Uint8Array(pairs.map((pair) => parseInt(pair, 16)));
}

/** Share IDs are bearer secrets for unprotected links, so keep all 122 random bits of the UUID. */
function compactID(): string {
  return crypto.randomUUID().replace(/-/g, "");
}

function sanitizeName(value: string): string {
  return value.replace(/[\u0000-\u001f<>]/g, "").trim().slice(0, 180) || "Untitled capture";
}

function sanitizeExtension(value: string): string {
  const cleaned = value.toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 8);
  return cleaned || "bin";
}

function extensionFor(contentType: string): string {
  return ({ "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "video/mp4": "mp4", "video/quicktime": "mov" } as Record<string, string>)[contentType] || "bin";
}

function asciiFileName(value: string): string {
  return value.normalize("NFKD").replace(/[^a-zA-Z0-9 ._-]/g, "").slice(0, 120) || "capture";
}

function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]!);
}

function escapeAttribute(value: string): string {
  return escapeHTML(value).replace(/`/g, "&#96;");
}

function inlineJSONString(value: string): string {
  return JSON.stringify(value).replace(/</g, "\\u003c").replace(/>/g, "\\u003e").replace(/&/g, "\\u0026");
}

function formatBytes(value: number): string {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`;
  return `${(value / 1024 / 1024 / 1024).toFixed(1)} GB`;
}

class HTTPError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}
