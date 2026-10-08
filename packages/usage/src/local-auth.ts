import { execFile } from 'node:child_process';
import { constants } from 'node:fs';
import { open } from 'node:fs/promises';
import { homedir } from 'node:os';

/**
 * Read-only access to sign-ins that another CLI stored on this computer. Used only when the
 * user turns on local credential reading. Nothing here refreshes, writes, or logs a credential,
 * and child-process errors are never surfaced because they can contain the secret.
 */
export type SecretReader = (service: string, account?: string) => Promise<string | null>;

/** macOS login keychain lookup through the system `security` tool. Other platforms return null. */
export const readKeychainSecret: SecretReader = (service, account) => {
  if (process.platform !== 'darwin') return Promise.resolve(null);
  const args = ['find-generic-password', '-s', service, ...(account ? ['-a', account] : []), '-w'];
  return new Promise((resolve) => {
    // A first read can show a macOS access prompt, so allow time for the user to answer it.
    const child = execFile('/usr/bin/security', args, {
      env: { HOME: homedir(), PATH: '/usr/bin:/bin' }, encoding: 'utf8', timeout: 60_000, killSignal: 'SIGKILL', maxBuffer: 64 * 1024,
    }, (error, stdout) => resolve(error ? null : stdout.trim() || null));
    child.stdin?.end();
  });
};

/** Reads a small regular file without following links or blocking on special files. */
export async function readSmallFile(path: string, maxBytes = 64 * 1024): Promise<string | null> {
  let handle;
  try {
    handle = await open(path, constants.O_RDONLY | constants.O_NONBLOCK | (constants.O_NOFOLLOW ?? 0));
    const info = await handle.stat();
    if (!info.isFile() || info.size > maxBytes) return null;
    const buffer = Buffer.alloc(maxBytes + 1);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    return bytesRead > maxBytes ? null : buffer.subarray(0, bytesRead).toString('utf8');
  } catch { return null; }
  finally { await handle?.close().catch(() => {}); }
}

export async function fileExists(path: string): Promise<boolean> {
  let handle;
  try { handle = await open(path, constants.O_RDONLY | constants.O_NONBLOCK); return true; }
  catch (error) { return (error as NodeJS.ErrnoException)?.code !== 'ENOENT'; }
  finally { await handle?.close().catch(() => {}); }
}

/** Unverified JWT claims, used only to read expiry and the signed-in email for display. */
export function jwtClaims(token: string): Record<string, unknown> | null {
  const part = token.split('.')[1];
  if (!part || part.length > 16_384) return null;
  try {
    const value = JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  } catch { return null; }
}

/** Fetches JSON from a fixed HTTPS origin with a timeout, no redirects, and a response size bound. */
export async function fetchJson(url: string, init: { headers: Record<string, string>; method?: string; body?: string },
  options: { fetch?: typeof globalThis.fetch; timeoutMs?: number; maxBytes?: number } = {}): Promise<{ status: number; json: unknown; retryAfterMs: number | null }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? 15_000);
  try {
    const response = await (options.fetch ?? globalThis.fetch)(url, { ...init, redirect: 'error', credentials: 'omit', signal: controller.signal });
    const retryAfter = response.headers.get('retry-after');
    const seconds = retryAfter && /^\d{1,6}$/.test(retryAfter.trim()) ? Number(retryAfter) : NaN;
    const retryAfterMs = Number.isFinite(seconds) ? Math.min(seconds * 1000, 3_600_000) : null;
    const text = await response.text();
    if (text.length > (options.maxBytes ?? 512 * 1024)) return { status: response.status, json: null, retryAfterMs };
    let json: unknown = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = null; }
    return { status: response.status, json, retryAfterMs };
  } finally { clearTimeout(timer); }
}

/**
 * The email of the Antigravity CLI sign-in, from the `email` claim of the id_token it stores.
 * Only that claim is read; tokens are never used or returned. Opt-in local sign-ins only.
 */
export async function readAntigravityEmail(home = homedir()): Promise<string | null> {
  try {
    const store = JSON.parse((await readSmallFile(`${home}/.gemini/antigravity-cli/antigravity-oauth-token`)) ?? 'null');
    const email = typeof store?.id_token === 'string' ? jwtClaims(store.id_token)?.email : null;
    return typeof email === 'string' && email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? email : null;
  } catch { return null; }
}
