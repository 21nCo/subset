import { spawn } from 'node:child_process';
import { stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { CODEX_LIMIT_REASONS, isEmail, type CodexLimitReason, type UsageAccount, type UsageProfile, type UsageWindow } from './index.js';

type RecordValue = Record<string, unknown>;
const object = (value: unknown): RecordValue | null => value && typeof value === 'object' && !Array.isArray(value) ? value as RecordValue : null;
const number = (value: unknown): number | null => typeof value === 'number' && Number.isFinite(value) ? value : null;
const string = (value: unknown, max = 128): string | null => typeof value === 'string' && value.length > 0 && value.length <= max && !/[\x00-\x1f\x7f]/.test(value) ? value : null;
const timestamp = (value: unknown): string | null => {
  const seconds = number(value);
  if (seconds === null || seconds < 0 || seconds > 253402300799) return null;
  const date = new Date(seconds * 1000);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
};
const limitMessages: Record<CodexLimitReason, string> = {
  rate_limit_reached: 'Codex reports that a bucket rate limit has been reached.',
  workspace_owner_credits_depleted: 'Codex reports that workspace owner credits are depleted.',
  workspace_member_credits_depleted: 'Codex reports that workspace member credits are depleted.',
  workspace_owner_usage_limit_reached: 'Codex reports that the workspace owner usage limit has been reached.',
  workspace_member_usage_limit_reached: 'Codex reports that the workspace member usage limit has been reached.'
};

export function normalizeCodexRead(profile: UsageProfile, accountResult: unknown, limitResult: unknown, observedAt: Date): UsageAccount {
  const account = object(object(accountResult)?.account);
  const base: UsageAccount = {
    id: profile.id, label: profile.label, provider: 'codex-chatgpt', source: 'Codex app-server',
    plan: string(account?.planType, 80), email: isEmail(account?.email) ? account.email : null, observedAt: observedAt.toISOString(), state: 'ok', windows: [], resetCredits: null,
    ordinaryUsageAllowed: null, limitAccess: [], errors: []
  };
  const workspaceId = string(object(object(accountResult)?.workspaceRouting)?.chatgptAccountId, 128);
  if (workspaceId) base.workspaceId = workspaceId;
  if (!account || account.type !== 'chatgpt') {
    base.state = account ? 'unsupported' : 'unauthorized';
    base.errors.push({ code: base.state, message: account ? 'Profile is not signed in with ChatGPT.' : 'Profile is not signed in.' });
    return base;
  }
  const result = object(limitResult);
  const permission = result?.ordinaryUsageAllowed;
  base.ordinaryUsageAllowed = typeof permission === 'boolean' ? permission : null;
  const buckets = object(result?.rateLimitsByLimitId);
  const entries: Array<[string, unknown]> = buckets && Object.keys(buckets).length ? Object.entries(buckets) : [['codex', result?.rateLimits]];
  let incomplete = entries.length > 50 || (permission !== undefined && permission !== null && typeof permission !== 'boolean');
  let bucketBlocked = false;
  const addError = (code: string, message: string) => {
    if (base.errors.length < 20 && !base.errors.some((error) => error.code === code)) base.errors.push({ code, message });
  };
  if (permission === false) addError('ordinary_usage_denied', 'Codex reports that ordinary included usage is blocked; quota percentages and reset times do not override this permission.');
  const bucketIds = new Map<string, number>();
  for (const [key, raw] of entries.slice(0, 50)) {
    const bucket = object(raw);
    const id = bucket && (string(bucket.limitId) ?? string(key));
    if (id) bucketIds.set(id, (bucketIds.get(id) ?? 0) + 1);
  }
  const windowKeys = new Set<string>();
  for (const [key, raw] of entries.slice(0, 50)) {
    const bucket = object(raw);
    if (!bucket) { incomplete = true; continue; }
    const id = string(bucket.limitId) ?? string(key);
    if (!id) { incomplete = true; continue; }
    // Neither conflicting bucket is authoritative when the same ID appears more than once.
    if (bucketIds.get(id)! > 1) { incomplete = true; continue; }
    const label = string(bucket.limitName) ?? id;
    const rawReason = bucket.rateLimitReachedType;
    const reason = typeof rawReason === 'string' && CODEX_LIMIT_REASONS.includes(rawReason as CodexLimitReason) ? rawReason as CodexLimitReason : null;
    const rawSpendControl = bucket.spendControlReached;
    const spendControlReached = typeof rawSpendControl === 'boolean' ? rawSpendControl : null;
    if ((rawReason !== undefined && rawReason !== null && reason === null)
      || (rawSpendControl !== undefined && rawSpendControl !== null && spendControlReached === null)) incomplete = true;
    base.limitAccess!.push({ limitId: id, label, rateLimitReachedType: reason, spendControlReached });
    if (reason !== null) { bucketBlocked = true; addError(reason, limitMessages[reason]); }
    if (spendControlReached === true) {
      bucketBlocked = true;
      addError('spend_control_reached', 'Codex reports that a bucket spend-control limit has been reached.');
    }
    for (const [slot, rawWindow] of [['primary', bucket.primary], ['secondary', bucket.secondary]] as const) {
      const window = object(rawWindow);
      if (!window) continue;
      const used = number(window.usedPercent);
      const normalizedUsed = used !== null && used >= 0 && used <= 100 ? used : null;
      const duration = number(window.windowDurationMins);
      const item: UsageWindow = {
        limitId: id, label: `${label} · ${slot}`,
        kind: 'provider-reported-quota', usedPercent: normalizedUsed, usedKind: 'provider-reported-quota', remainingKind: 'calculated-estimate',
        remainingPercent: normalizedUsed === null ? null : Math.round((100 - normalizedUsed) * 10) / 10,
        durationMinutes: duration !== null && duration >= 0 && duration <= Number.MAX_SAFE_INTEGER ? duration : null, resetsAt: timestamp(window.resetsAt)
      };
      if (item.usedPercent === null || item.resetsAt === null || (duration !== null && item.durationMinutes === null)) incomplete = true;
      const windowKey = JSON.stringify([item.limitId, item.label]);
      if (windowKeys.has(windowKey)) { incomplete = true; continue; }
      windowKeys.add(windowKey);
      base.windows.push(item);
    }
  }
  const resetCredits = object(result?.rateLimitResetCredits);
  const availableCount = number(resetCredits?.availableCount);
  if (availableCount !== null && Number.isSafeInteger(availableCount) && availableCount >= 0) {
    // Only available credits count, matching the listed credits and the one a reset redeems.
    const expiry = Array.isArray(resetCredits?.credits) ? resetCredits.credits.map(object)
      .filter((item): item is RecordValue => !!item && (item.status === undefined || item.status === 'available'))
      .map((item) => timestamp(item.expiresAt)).filter((item): item is string => item !== null)
      .sort((a, b) => Date.parse(a) - Date.parse(b))[0] ?? null : null;
    // Display details only; opaque credit IDs stay out of the status.
    const credits = Array.isArray(resetCredits?.credits) ? resetCredits.credits.slice(0, 20).map(object).filter((item) => item && (item.status === undefined || item.status === 'available')).map((item) => ({
      title: string(item!.title, 120), description: string(item!.description, 300), grantedAt: timestamp(item!.grantedAt), expiresAt: timestamp(item!.expiresAt),
    })) : undefined;
    base.resetCredits = { availableCount, earliestExpiry: expiry, ...(credits ? { credits } : {}) };
  }
  // Paid Codex credits are a count, not dollars.
  const paid = object(object(result?.rateLimits)?.credits) ?? entries.map(([, raw]) => object(object(raw)?.credits)).find(Boolean) ?? null;
  const paidBalance = typeof paid?.balance === 'string' && /^\d+(\.\d+)?$/.test(paid.balance) ? Number(paid.balance) : null;
  if (paid?.unlimited === true) base.balances = [{ kind: 'provider-reported-balance', currency: 'credits', amount: 0, label: 'Credits', note: 'Unlimited' }];
  else if (paidBalance !== null && (paid?.hasCredits !== false || paidBalance > 0)) base.balances = [{ kind: 'provider-reported-balance', currency: 'credits', amount: Math.round(paidBalance * 100) / 100, label: 'Credits' }];
  if (!base.windows.length) {
    base.state = 'partial';
    addError('missing_limits', 'Codex did not return a readable usage window.');
  }
  if (incomplete) {
    base.state = 'partial';
    addError('partial_limits', 'Some Codex quota or access values are unavailable or ambiguous; at most 50 buckets and 100 windows are retained.');
  }
  if (bucketBlocked) base.state = 'partial';
  if (permission === false) base.state = 'blocked';
  return base;
}

/** The available credit that expires first; credits without an expiry come last. */
export function nextResetCredit<T>(credits: unknown): (T & { id?: string }) | null {
  if (!Array.isArray(credits)) return null;
  const available = credits.map(object).filter((credit): credit is RecordValue => !!credit && (credit.status === undefined || credit.status === 'available'));
  const expiry = (credit: RecordValue) => typeof credit.expiresAt === 'number' ? credit.expiresAt : typeof credit.expiresAt === 'string' ? Date.parse(credit.expiresAt) / 1000 : Infinity;
  return (available.sort((a, b) => expiry(a) - expiry(b))[0] as (T & { id?: string }) | undefined) ?? null;
}

export type CodexResetOutcome = 'reset' | 'nothingToReset' | 'noCredit' | 'alreadyRedeemed';

/**
 * Redeems the next available banked reset through the documented app-server method
 * `account/rateLimitResetCredit/consume` for the available credit that expires first (the
 * backend chooses when the read lists no IDs); the idempotency key makes a retried request safe.
 */
export async function consumeCodexResetCredit(profile: UsageProfile, options: { codexBinary?: string; idempotencyKey: string; timeoutMs?: number }): Promise<CodexResetOutcome> {
  const home = resolve(profile.codexHome);
  if (!(await stat(home).then((info) => info.isDirectory(), () => false))) throw new Error('Codex profile directory is missing.');
  const env: NodeJS.ProcessEnv = { ...process.env, CODEX_HOME: home };
  delete env.OPENAI_API_KEY;
  delete env.CODEX_ACCESS_TOKEN;
  const child = spawn(options.codexBinary ?? 'codex', ['app-server', '--listen', 'stdio://'], { env, stdio: ['pipe', 'pipe', 'ignore'] });
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const waiting = new Map<number, { resolve: (message: RecordValue) => void; reject: (error: Error) => void }>();
  let closed: Error | null = null;
  // Every pending request settles when the process fails to start, exits, or times out.
  const failAll = (error: Error) => {
    closed ??= error;
    for (const waiter of waiting.values()) waiter.reject(closed);
    waiting.clear();
  };
  let nextId = 1;
  lines.on('line', (line) => {
    let message: RecordValue | null = null;
    try { message = object(JSON.parse(line)); } catch { return; }
    const id = message && message.method === undefined ? number(message.id) : null;
    if (id === null) return;
    const waiter = waiting.get(id);
    waiting.delete(id);
    waiter?.resolve(message!);
  });
  const request = (method: string, params?: RecordValue) => new Promise<RecordValue>((resolveRequest, reject) => {
    if (closed) { reject(closed); return; }
    const id = nextId++;
    waiting.set(id, { resolve: resolveRequest, reject });
    child.stdin.write(`${JSON.stringify({ id, method, ...(params ? { params } : {}) })}\n`, (error) => { if (error) failAll(new Error('Codex app-server closed.')); });
  });
  const timer = setTimeout(() => { failAll(new Error('Codex app-server timed out.')); child.kill(); }, options.timeoutMs ?? 30_000);
  child.on('error', () => failAll(new Error('Codex app-server could not start.')));
  child.on('exit', () => failAll(new Error('Codex app-server closed.')));
  child.stdin.on('error', () => failAll(new Error('Codex app-server closed.')));
  try {
    await request('initialize', { clientInfo: { name: 'subset_usage', title: 'Subset Usage', version: '0.0.0' } });
    child.stdin.write(`${JSON.stringify({ method: 'initialized', params: {} })}\n`);
    // Use the credit that expires first, the same one the dashboard names, instead of the backend's choice.
    // If the credits can't be read, stop: redeeming without an ID would let the backend pick another credit.
    const limits = await request('account/rateLimits/read');
    if (limits.error !== undefined || !object(limits.result)) throw new Error('Codex could not use a reset.');
    // When the read lists no credit IDs, the documented method picks the credit itself.
    const creditId = nextResetCredit(object(object(limits.result)?.rateLimitResetCredits)?.credits)?.id ?? null;
    const response = await request('account/rateLimitResetCredit/consume', { idempotencyKey: options.idempotencyKey, ...(creditId ? { creditId } : {}) });
    const outcome = object(response.result)?.outcome;
    if (response.error !== undefined || !['reset', 'nothingToReset', 'noCredit', 'alreadyRedeemed'].includes(outcome as string)) throw new Error('Codex could not use a reset.');
    return outcome as CodexResetOutcome;
  } finally {
    clearTimeout(timer);
    lines.close();
    child.kill();
  }
}

export async function readCodexProfile(profile: UsageProfile, options: { codexBinary?: string; timeoutMs?: number } = {}): Promise<UsageAccount> {
  const empty = (code: UsageAccount['state'], message: string): UsageAccount => ({
    id: profile.id, label: profile.label, provider: 'codex-chatgpt', source: 'Codex app-server', plan: null,
    observedAt: null, state: code, windows: [], resetCredits: null, ordinaryUsageAllowed: null, limitAccess: [], errors: [{ code, message }]
  });
  if (!/^[a-zA-Z0-9_-]{1,64}$/.test(profile.id) || typeof profile.label !== 'string') return empty('unavailable', 'Invalid profile configuration.');
  const home = resolve(profile.codexHome);
  try { if (!(await stat(home)).isDirectory()) return empty('unavailable', 'Codex profile directory is missing.'); }
  catch { return empty('unavailable', 'Codex profile directory is missing.'); }

  const env: NodeJS.ProcessEnv = { ...process.env, CODEX_HOME: home };
  delete env.OPENAI_API_KEY;
  delete env.CODEX_ACCESS_TOKEN;
  const child = spawn(options.codexBinary ?? 'codex', ['app-server', '--listen', 'stdio://'], { env, stdio: ['pipe', 'pipe', 'ignore'] });
  const timeoutMs = options.timeoutMs ?? 15000;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let nextId = 1;
  const pending = new Map<number, { resolve: (value: unknown) => void; reject: (reason: Error) => void }>();
  let transportError: Error | undefined;
  const rejectResponses = (error: Error) => { for (const waiter of pending.values()) waiter.reject(error); pending.clear(); };
  const fail = (error: Error) => {
    transportError ??= error;
    rejectResponses(transportError);
  };
  child.on('error', fail);
  child.on('exit', () => fail(new Error('Codex app-server closed.')));
  child.stdin.on('error', fail);
  child.stdin.on('close', () => fail(new Error('Codex app-server closed.')));
  child.stdout.on('error', fail);
  child.stdout.on('end', () => fail(new Error('Codex app-server closed.')));
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  lines.on('error', fail);
  lines.on('line', (line) => {
    if (line.length > 1024 * 1024) { fail(new Error('Codex response too large.')); child.kill(); return; }
    let message: RecordValue | null;
    try { message = object(JSON.parse(line)); }
    catch { rejectResponses(new Error('Codex app-server response malformed.')); return; }
    if (!message) { rejectResponses(new Error('Codex app-server response malformed.')); return; }
    // Server-initiated requests share the id field but are not responses to this client.
    const id = message.method === undefined ? number(message.id) : null;
    if (id === null) return;
    const waiter = pending.get(id);
    if (!waiter) return;
    pending.delete(id);
    if (message.error !== undefined) waiter.reject(new Error('Codex app-server request failed.'));
    else if (!Object.hasOwn(message, 'result')) waiter.reject(new Error('Codex app-server response malformed.'));
    else waiter.resolve(message.result);
  });
  const write = (message: RecordValue): Promise<void> => new Promise((resolveWrite, reject) => {
    if (!transportError && (child.stdin.destroyed || child.stdin.writableEnded)) fail(new Error('Codex app-server closed.'));
    if (transportError) { reject(transportError); return; }
    try {
      child.stdin.write(`${JSON.stringify(message)}\n`, (error) => {
        if (error) fail(error);
        if (transportError) reject(transportError);
        else resolveWrite();
      });
    } catch (error) {
      fail(error instanceof Error ? error : new Error('Codex app-server closed.'));
      reject(transportError ?? new Error('Codex app-server closed.'));
    }
  });
  const request = (method: string, params?: RecordValue): Promise<unknown> => {
    if (transportError) return Promise.reject(transportError);
    const id = nextId++;
    const response = new Promise<unknown>((resolveRequest, reject) => {
      pending.set(id, { resolve: resolveRequest, reject });
    });
    return Promise.all([write({ id, method, ...(params ? { params } : {}) }), response]).then(([, result]) => result);
  };
  timer = setTimeout(() => { fail(new Error('Codex app-server timed out.')); child.kill(); }, timeoutMs);
  try {
    await request('initialize', { clientInfo: { name: 'subset_usage', title: 'Subset Usage', version: '0.0.0' } });
    await write({ method: 'initialized', params: {} });
    const account = await request('account/read', { refreshToken: false });
    if (object(object(account)?.account)?.type !== 'chatgpt') return normalizeCodexRead(profile, account, null, new Date());
    const limits = await request('account/rateLimits/read');
    return normalizeCodexRead(profile, account, limits, new Date());
  } catch (error) {
    const safe = error instanceof Error && /^Codex app-server (closed|request failed|timed out|response malformed)\.$/.test(error.message) ? error.message : 'Could not read Codex usage from this profile.';
    return empty('unavailable', safe);
  } finally {
    if (timer) clearTimeout(timer);
    lines.close();
    child.kill();
  }
}
