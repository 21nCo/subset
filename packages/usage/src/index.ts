export const USAGE_SCHEMA_VERSION = 1 as const;
export const USAGE_VIEW_ID = 'subset.usage.dashboard@1' as const;

export type UsageProvider = 'codex-chatgpt' | 'claude-code' | 'antigravity' | 'cursor' | 'cursor-local' | 'factory-droid' | 'amp' | 'devin' | 'pi' | 'opencode' | 'omp' | 'hermes';
export const USAGE_PROVIDERS: readonly UsageProvider[] = ['codex-chatgpt', 'claude-code', 'antigravity', 'cursor', 'cursor-local', 'factory-droid', 'amp', 'devin', 'pi', 'opencode', 'omp', 'hermes'];
/** Agent harnesses that read another service's subscription through a login they store. */
export const HARNESS_PROVIDERS: readonly UsageProvider[] = ['pi', 'opencode', 'omp', 'hermes'];

export const CODEX_LIMIT_REASONS = [
  'rate_limit_reached', 'workspace_owner_credits_depleted', 'workspace_member_credits_depleted',
  'workspace_owner_usage_limit_reached', 'workspace_member_usage_limit_reached',
] as const;
export type CodexLimitReason = typeof CODEX_LIMIT_REASONS[number];

export interface UsageWindow {
  limitId: string;
  label: string;
  kind: 'provider-reported-quota';
  usedPercent: number | null;
  usedKind?: 'provider-reported-quota' | 'calculated-estimate';
  remainingPercent: number | null;
  remainingKind: 'calculated-estimate' | 'provider-reported-quota';
  durationMinutes: number | null;
  resetsAt: string | null;
}

export interface UsageAccount {
  id: string;
  label: string;
  provider: UsageProvider;
  /** For harness accounts, the service whose subscription the quota belongs to. */
  service?: UsageProvider;
  /** Other harnesses signed in to this same account; their cards are merged into this one. */
  alsoIn?: UsageProvider[];
  source: string;
  plan: string | null;
  /** Sign-in email when the provider's local tool reports one. Omitted from the agent text fallback. */
  email?: string | null;
  observedAt: string | null;
  state: 'ok' | 'partial' | 'blocked' | 'unauthorized' | 'unavailable' | 'unsupported';
  windows: UsageWindow[];
  resetCredits: {
    availableCount: number;
    earliestExpiry: string | null;
    /** Available credits, when the provider lists them. Opaque credit IDs are never included. */
    credits?: Array<{ title: string | null; description: string | null; grantedAt: string | null; expiresAt: string | null }>;
  } | null;
  ordinaryUsageAllowed?: boolean | null;
  limitAccess?: Array<{
    limitId: string;
    label: string;
    rateLimitReachedType: CodexLimitReason | null;
    spendControlReached: boolean | null;
  }>;
  spend?: {
    kind: 'provider-reported-spend';
    /** Heading such as "Extra usage"; hosts show a generic heading when absent. */
    label?: string;
    currency: 'USD';
    used: number | null;
    limit: number | null;
    includedUsed: number | null;
    periodStart: string | null;
    periodEnd: string | null;
  };
  /** Prepaid credit or allowance reported by the provider, such as Factory's extra usage balance. */
  balances?: Array<{ kind: 'provider-reported-balance' | 'provider-reported-amount'; currency: 'USD' | 'credits'; amount: number; label: string; note?: string }>;
  errors: Array<{ code: string; message: string }>;
}

export interface UsageStatus {
  schemaVersion: typeof USAGE_SCHEMA_VERSION;
  viewId: typeof USAGE_VIEW_ID;
  generatedAt: string;
  accounts: UsageAccount[];
}

export interface UsageProfile {
  id: string;
  label: string;
  codexHome: string;
  provider?: 'codex-chatgpt';
}

export interface SnapshotProfile {
  id: string;
  label: string;
  provider: 'claude-code' | 'antigravity';
  snapshotFile: string;
}

export interface CursorProfile {
  id: string;
  label: string;
  provider: 'cursor';
  credentialEnv: string;
  cursorUserId: string;
}

export interface FactoryDroidProfile {
  id: string;
  label: string;
  provider: 'factory-droid';
  factoryHome: string;
  credentialEnv?: string;
}

export type ProviderProfile = UsageProfile | SnapshotProfile | CursorProfile | FactoryDroidProfile;

export const isEmail = (value: unknown): value is string => typeof value === 'string' && value.length <= 254 && /^[^\s@<>()\x00-\x1f]+@[^\s@<>()\x00-\x1f]+\.[^\s@<>()\x00-\x1f]+$/.test(value);

export function isUsageStatus(value: unknown): value is UsageStatus {
  const record = (item: unknown): item is Record<string, unknown> => !!item && typeof item === 'object' && !Array.isArray(item);
  const text = (item: unknown, max = 160): item is string => typeof item === 'string' && item.length <= max;
  const date = (item: unknown) => item === null || (text(item, 40) && Number.isFinite(Date.parse(item)));
  const amount = (item: unknown) => item === null || (typeof item === 'number' && Number.isFinite(item) && item >= 0);
  const percent = (item: unknown) => amount(item) && (item === null || (item as number) <= 100);
  const metricKind = (item: unknown) => item === 'provider-reported-quota' || item === 'calculated-estimate';
  if (!record(value) || value.schemaVersion !== USAGE_SCHEMA_VERSION || value.viewId !== USAGE_VIEW_ID
    || value.generatedAt === null || !date(value.generatedAt) || !Array.isArray(value.accounts) || value.accounts.length > 20) return false;
  const ids = new Set<string>();
  return value.accounts.every((account) => {
    if (!record(account) || !text(account.id, 64) || !/^[a-zA-Z0-9_-]+$/.test(account.id) || ids.has(account.id)
      || !text(account.label, 80) || !text(account.provider, 32) || !USAGE_PROVIDERS.includes(account.provider as UsageProvider)
      || !text(account.source) || !(account.plan === null || text(account.plan, 80)) || !date(account.observedAt)
      || !text(account.state, 32) || !['ok', 'partial', 'blocked', 'unauthorized', 'unavailable', 'unsupported'].includes(account.state)
      || !Array.isArray(account.windows) || account.windows.length > 100 || !Array.isArray(account.errors) || account.errors.length > 20) return false;
    if (!(account.service === undefined || USAGE_PROVIDERS.includes(account.service as UsageProvider))) return false;
    if (!(account.alsoIn === undefined || (Array.isArray(account.alsoIn) && account.alsoIn.length <= 10 && account.alsoIn.every((item) => USAGE_PROVIDERS.includes(item as UsageProvider))))) return false;
    if (!(account.email === undefined || account.email === null || (text(account.email, 254) && isEmail(account.email)))) return false;
    ids.add(account.id);
    const windows = new Set<string>();
    if (!account.windows.every((window) => {
      if (!record(window) || !text(window.limitId) || !text(window.label) || window.kind !== 'provider-reported-quota'
        || !percent(window.usedPercent) || !percent(window.remainingPercent)
        || !(window.usedKind === undefined || metricKind(window.usedKind)) || !metricKind(window.remainingKind)
        || !amount(window.durationMinutes) || !date(window.resetsAt)) return false;
      const key = JSON.stringify([window.limitId, window.label]);
      if (windows.has(key)) return false;
      windows.add(key);
      return true;
    })) return false;
    if (!account.errors.every((error) => record(error) && text(error.code, 80) && text(error.message, 500))) return false;
    if (!(account.ordinaryUsageAllowed === undefined || account.ordinaryUsageAllowed === null || typeof account.ordinaryUsageAllowed === 'boolean')) return false;
    if (account.limitAccess !== undefined) {
      if (!Array.isArray(account.limitAccess) || account.limitAccess.length > 50) return false;
      const limits = new Set<string>();
      if (!account.limitAccess.every((limit) => {
        if (!record(limit) || !text(limit.limitId) || !text(limit.label) || limits.has(limit.limitId)
          || !(limit.rateLimitReachedType === null || (typeof limit.rateLimitReachedType === 'string' && CODEX_LIMIT_REASONS.includes(limit.rateLimitReachedType as CodexLimitReason)))
          || !(limit.spendControlReached === null || typeof limit.spendControlReached === 'boolean')) return false;
        limits.add(limit.limitId);
        return true;
      })) return false;
    }
    if (!(account.balances === undefined || (Array.isArray(account.balances) && account.balances.length <= 10 && account.balances.every((balance) => record(balance)
      && (balance.kind === 'provider-reported-balance' || balance.kind === 'provider-reported-amount') && (balance.currency === 'USD' || balance.currency === 'credits') && typeof balance.amount === 'number' && amount(balance.amount)
      && text(balance.label, 80) && (balance.note === undefined || text(balance.note, 160)))))) return false;
    const credits = account.resetCredits;
    const validCredit = (credit: unknown) => record(credit) && (credit.title === null || text(credit.title, 120))
      && (credit.description === null || text(credit.description, 300)) && date(credit.grantedAt) && date(credit.expiresAt);
    if (credits !== null && (!record(credits) || !Number.isInteger(credits.availableCount)
      || (credits.availableCount as number) < 0 || !date(credits.earliestExpiry)
      || !(credits.credits === undefined || (Array.isArray(credits.credits) && credits.credits.length <= 20 && credits.credits.every(validCredit))))) return false;
    const spend = account.spend;
    return spend === undefined || (record(spend) && spend.kind === 'provider-reported-spend' && spend.currency === 'USD' && (spend.label === undefined || text(spend.label, 60))
      && amount(spend.used) && amount(spend.limit) && amount(spend.includedUsed) && date(spend.periodStart) && date(spend.periodEnd));
  });
}

export function createUsageStatus(accounts: UsageAccount[], now = new Date()): UsageStatus {
  return { schemaVersion: USAGE_SCHEMA_VERSION, viewId: USAGE_VIEW_ID, generatedAt: now.toISOString(), accounts };
}

export function usageFreshness(observedAt: string | null, now = Date.now()): 'No observation' | 'Stale' | 'Current' {
  if (!observedAt || !Number.isFinite(Date.parse(observedAt))) return 'No observation';
  return now - Date.parse(observedAt) > 5 * 60_000 ? 'Stale' : 'Current';
}

export function usageText(status: UsageStatus, now = new Date()): string {
  if (status.accounts.length === 0) return 'No usage accounts are configured.';
  return status.accounts.map((account) => {
    const windows = account.windows.map((window) => `${window.label}: ${window.remainingPercent === null ? 'remaining unknown' : `${window.remainingKind === 'calculated-estimate' ? '~' : ''}${window.remainingPercent}% remaining (${window.remainingKind === 'calculated-estimate' ? 'calculated from provider-reported usage' : 'provider-reported quota'})`}, resets ${window.resetsAt ?? 'unavailable'}`);
    const spend = account.spend ? `USD ${account.spend.used ?? 'unknown'} on-demand spend${account.spend.limit === null ? '; limit unavailable' : ` of ${account.spend.limit} limit`}; spending cap is not remaining subscription quota` : '';
    const errors = account.errors.map((error) => `${error.code}: ${error.message}`);
    const permission = account.ordinaryUsageAllowed === undefined ? '' : `ordinary included usage ${account.ordinaryUsageAllowed === null ? 'permission unavailable' : account.ordinaryUsageAllowed ? 'allowed by provider' : 'blocked by provider (quota percentages do not override this denial)'}`;
    const limits = (account.limitAccess ?? []).map((limit) => `${limit.label}: reached-limit reason ${limit.rateLimitReachedType ?? 'unavailable'}; spend control ${limit.spendControlReached === null ? 'unavailable' : limit.spendControlReached ? 'reached' : 'not reached'}`);
    const freshness = usageFreshness(account.observedAt, now.getTime());
    const snapshot = account.provider === 'claude-code' || account.provider === 'antigravity' ? '; last collected CLI snapshot, not a live provider read' : '';
    return `${account.label || `${account.provider} account`} (${account.provider}; ${account.state}; source ${account.source}; observed ${account.observedAt ?? 'never'}; ${freshness}${freshness === 'Stale' ? ' (older than 5 minutes)' : ''}${snapshot}): ${[permission, ...limits, ...windows, spend, ...errors].filter(Boolean).join('; ') || 'usage unavailable'}`;
  }).join('\n');
}

export function agentUsageResult(status: UsageStatus) {
  return { structuredContent: status, text: usageText(status), viewId: USAGE_VIEW_ID };
}
