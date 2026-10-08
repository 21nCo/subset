import type { CursorProfile, UsageAccount } from './index.js';

const ENDPOINT = 'https://api.cursor.com/teams/spend';
const PAGE_SIZE = 100;
const MAX_PAGES = 20;
const MAX_PAGE_BYTES = 1024 * 1024;
const MAX_TOTAL_BYTES = 4 * MAX_PAGE_BYTES;
const object = (value: unknown): Record<string, unknown> | null => value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
const amount = (value: unknown): number | null => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER ? value : null;
const timestamp = (value: unknown): string | null => {
  if (amount(value) === null || !Number.isInteger(value)) return null;
  const date = new Date(value as number);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
};
const validProfile = (profile: CursorProfile): boolean => profile.provider === 'cursor'
  && typeof profile.id === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(profile.id)
  && typeof profile.label === 'string' && profile.label.length <= 120 && !/[\x00-\x1f\x7f]/.test(profile.label)
  && typeof profile.credentialEnv === 'string' && /^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(profile.credentialEnv)
  && typeof profile.cursorUserId === 'string' && /^user_[A-Za-z0-9_-]{1,251}$/.test(profile.cursorUserId);

const messages: Record<string, string> = {
  invalid_profile: 'Invalid Cursor team profile configuration.',
  missing_credentials: 'The configured Cursor team API key is unavailable.',
  invalid_credentials: 'The configured Cursor team API key is invalid.',
  unauthorized: 'Cursor team API authorization failed.',
  forbidden: 'Cursor team API access is not permitted.',
  rate_limited: 'Cursor team API rate limit reached. Try again later.',
  request_failed: 'Could not read Cursor team spending.',
  redirect_rejected: 'Cursor team API redirects are not permitted.',
  timeout: 'Cursor team spending read timed out.',
  response_too_large: 'Cursor team API response exceeded the read limit.',
  malformed_response: 'Cursor team API returned an unreadable spending response.',
  pagination_limit: 'Cursor team spending exceeds the bounded pagination limit.',
  missing_user: 'The configured team member was not found in Cursor spending data.',
  ambiguous_user: 'Cursor returned duplicate spending records for the configured team member.',
  malformed_spend: 'Some Cursor team spending fields are missing or invalid.'
};

function empty(profile: CursorProfile): UsageAccount {
  return {
    id: profile.id, label: profile.label, provider: 'cursor', source: 'Cursor team Admin API',
    plan: null, observedAt: null, state: 'ok', windows: [], resetCredits: null, errors: []
  };
}

function failure(profile: CursorProfile, code: string, state: UsageAccount['state'] = 'unavailable'): UsageAccount {
  return { ...empty(profile), state, errors: [{ code, message: messages[code] }] };
}

export function normalizeCursorSpend(profile: CursorProfile, input: unknown, observedAt: Date): UsageAccount {
  if (!validProfile(profile)) return failure(profile, 'invalid_profile');
  const result = object(input);
  if (!result || !Array.isArray(result.teamMemberSpend) || result.teamMemberSpend.length > PAGE_SIZE) return failure(profile, 'malformed_response');
  const matches = result.teamMemberSpend.map(object).filter((row) => row?.userId === profile.cursorUserId);
  if (matches.length !== 1) {
    return { ...failure(profile, matches.length ? 'ambiguous_user' : 'missing_user', 'partial'), observedAt: observedAt.toISOString() };
  }
  const row = matches[0]!;
  const usedCents = amount(row.spendCents);
  const overallCents = amount(row.overallSpendCents);
  // Only the reported effective cap is authoritative. The override's zero is not a $0 cap.
  const limit = amount(row.effectivePerUserLimitDollars);
  const periodStart = timestamp(result.subscriptionCycleStart);
  const invalidOptional = (value: unknown, parsed: unknown) => value !== undefined && value !== null && parsed === null;
  const malformed = usedCents === null
    || invalidOptional(row.overallSpendCents, overallCents)
    || (usedCents !== null && overallCents !== null && overallCents < usedCents)
    || invalidOptional(row.effectivePerUserLimitDollars, limit)
    || invalidOptional(result.subscriptionCycleStart, periodStart);
  return {
    ...empty(profile), observedAt: observedAt.toISOString(), state: malformed ? 'partial' : 'ok',
    spend: {
      kind: 'provider-reported-spend', currency: 'USD', used: usedCents === null ? null : usedCents / 100,
      includedUsed: usedCents !== null && overallCents !== null && overallCents >= usedCents ? (overallCents - usedCents) / 100 : null,
      limit, periodStart, periodEnd: null
    },
    errors: malformed ? [{ code: 'malformed_spend', message: messages.malformed_spend }] : []
  };
}

export async function readCursorProfile(profile: CursorProfile, options: {
  fetch?: typeof globalThis.fetch;
  env?: NodeJS.ProcessEnv;
  timeoutMs?: number;
} = {}): Promise<UsageAccount> {
  if (!validProfile(profile)) return failure(profile, 'invalid_profile');
  const env = options.env ?? process.env;
  const key = Object.hasOwn(env, profile.credentialEnv) ? env[profile.credentialEnv] : undefined;
  if (!key) return failure(profile, 'missing_credentials', 'unauthorized');
  if (key.length > 8192 || !/^[\x21-\x39\x3b-\x7e]+$/.test(key)) return failure(profile, 'invalid_credentials', 'unauthorized');
  const timeoutMs = options.timeoutMs ?? 15000;
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > 120000) return failure(profile, 'invalid_profile');
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  const timedOut = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      void reader?.cancel().catch(() => {});
      reject(new Error('timeout'));
    }, timeoutMs);
  });
  const read = async (): Promise<UsageAccount> => {
    let totalBytes = 0;
    let totalRows = 0;
    let expectedPages: number | undefined;
    let expectedMembers: number | undefined;
    let matched: UsageAccount | undefined;
    for (let page = 1; page <= MAX_PAGES; page++) {
      controller.signal.throwIfAborted();
      const response = await (options.fetch ?? globalThis.fetch)(ENDPOINT, {
        method: 'POST', redirect: 'error', credentials: 'omit', signal: controller.signal,
        headers: { Authorization: `Basic ${Buffer.from(`${key}:`).toString('base64')}`, 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ page, pageSize: PAGE_SIZE })
      });
      const discard = () => { void response.body?.cancel().catch(() => {}); };
      if (controller.signal.aborted) { discard(); controller.signal.throwIfAborted(); }
      if (response.redirected || (response.status >= 300 && response.status < 400)) { discard(); throw new Error('redirect_rejected'); }
      if (!response.ok) {
        discard();
        throw new Error(response.status === 401 ? 'unauthorized' : response.status === 403 ? 'forbidden' : response.status === 429 ? 'rate_limited' : 'request_failed');
      }
      const declaredLength = Number(response.headers.get('content-length'));
      if (declaredLength > MAX_PAGE_BYTES || declaredLength + totalBytes > MAX_TOTAL_BYTES) { discard(); throw new Error('response_too_large'); }
      if (!response.body) throw new Error('malformed_response');
      reader = response.body.getReader();
      const decoder = new TextDecoder('utf-8', { fatal: true });
      let text = '';
      let pageBytes = 0;
      try {
        while (true) {
          const chunk = await reader.read();
          controller.signal.throwIfAborted();
          if (chunk.done) break;
          pageBytes += chunk.value.byteLength;
          totalBytes += chunk.value.byteLength;
          if (pageBytes > MAX_PAGE_BYTES || totalBytes > MAX_TOTAL_BYTES) throw new Error('response_too_large');
          text += decoder.decode(chunk.value, { stream: true });
        }
        text += decoder.decode();
      } finally {
        void reader.cancel().catch(() => {});
        reader.releaseLock();
        reader = undefined;
      }
      let result: Record<string, unknown> | null;
      try { result = object(JSON.parse(text)); } catch { throw new Error('malformed_response'); }
      if (!result || !Array.isArray(result.teamMemberSpend) || result.teamMemberSpend.length > PAGE_SIZE) throw new Error('malformed_response');
      totalRows += result.teamMemberSpend.length;
      const pages = result.totalPages;
      const members = result.totalMembers;
      if (typeof pages !== 'number' || !Number.isSafeInteger(pages) || pages < 0 || (pages === 0 && result.teamMemberSpend.length > 0)) throw new Error('malformed_response');
      if (pages > MAX_PAGES || totalRows > PAGE_SIZE * MAX_PAGES || (typeof members === 'number' && members > PAGE_SIZE * MAX_PAGES)) throw new Error('pagination_limit');
      if ((expectedPages !== undefined && expectedPages !== pages) || (pages !== 0 && pages < page)
        || (members !== undefined && (typeof members !== 'number' || !Number.isSafeInteger(members) || members < totalRows || (expectedMembers !== undefined && members !== expectedMembers)))) throw new Error('malformed_response');
      expectedPages = pages;
      expectedMembers = members as number | undefined;
      // Retain only normalized data and finish pagination to detect ambiguous identity.
      const matchingRows = result.teamMemberSpend.filter((row) => object(row)?.userId === profile.cursorUserId);
      if (matchingRows.length > 1 || (matchingRows.length && matched)) return failure(profile, 'ambiguous_user', 'partial');
      if (matchingRows.length) matched = normalizeCursorSpend(profile, result, new Date());
      if (page >= pages) return matched ?? normalizeCursorSpend(profile, result, new Date());
    }
    throw new Error('pagination_limit');
  };
  try {
    return await Promise.race([read(), timedOut]);
  } catch (error) {
    const code = controller.signal.aborted ? 'timeout' : error instanceof Error && Object.hasOwn(messages, error.message) ? error.message : 'request_failed';
    return failure(profile, code, code === 'unauthorized' || code === 'forbidden' ? 'unauthorized' : 'unavailable');
  } finally {
    clearTimeout(timer);
    controller.abort();
    void reader?.cancel().catch(() => {});
  }
}
