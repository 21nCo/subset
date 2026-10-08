import { execFile } from 'node:child_process';
import { isEmail, type UsageAccount } from './index.js';

/**
 * Amp credit balance from the documented `amp usage` command. The Amp CLI owns its sign-in;
 * another saved account can be read by naming an environment variable holding that account's
 * AMP_API_KEY. The CLI prints text, so parsing is limited to the signed-in email and dollar amounts.
 */
export interface AmpProfile { id: string; label: string; provider: 'amp'; credentialEnv?: string }

const money = (value: string | undefined): number | null => {
  if (!value) return null;
  const amount = Number(value.replace(/,/g, ''));
  return Number.isFinite(amount) && amount >= 0 ? Math.round(amount * 100) / 100 : null;
};

export function normalizeAmpUsage(profile: AmpProfile, output: string, observedAt: Date): UsageAccount {
  const text = output.slice(0, 16_384);
  const email = /Signed in as\s+(\S+@\S+?)[\s(]/.exec(`${text} `)?.[1];
  const credits = money(/credits:?\**\s*\$([\d,]+(?:\.\d+)?)\s+remaining/i.exec(text)?.[1]);
  const free = money(/\$([\d,]+(?:\.\d+)?)\s+Amp Free remaining today/i.exec(text)?.[1]);
  const balances: NonNullable<UsageAccount['balances']> = [];
  if (credits !== null) balances.push({ kind: 'provider-reported-balance', currency: 'USD', amount: credits, label: 'Credits remaining', ...(free !== null ? { note: 'Includes Amp Free' } : {}) });
  if (free !== null) balances.push({ kind: 'provider-reported-balance', currency: 'USD', amount: free, label: 'Amp Free left today', note: 'Resets daily' });
  return {
    id: profile.id, label: profile.label, provider: 'amp', source: 'amp usage', plan: null, email: isEmail(email) ? email : null,
    observedAt: observedAt.toISOString(), state: balances.length ? 'ok' : 'partial', windows: [], resetCredits: null, balances,
    errors: balances.length ? [] : [{ code: 'amp_unreadable', message: 'amp usage did not report a credit balance this dashboard can read.' }],
  };
}

export function readAmpProfile(profile: AmpProfile, options: { ampBinary?: string; env?: NodeJS.ProcessEnv; timeoutMs?: number } = {}): Promise<UsageAccount> {
  const fail = (code: string, message: string, state: UsageAccount['state'] = 'unavailable'): UsageAccount => ({
    id: profile.id, label: profile.label, provider: 'amp', source: 'amp usage', plan: null, observedAt: null, state, windows: [], resetCredits: null, errors: [{ code, message }],
  });
  const base = options.env ?? process.env;
  const env: NodeJS.ProcessEnv = { ...base };
  if (profile.credentialEnv) {
    const key = Object.hasOwn(base, profile.credentialEnv) ? base[profile.credentialEnv] : undefined;
    if (!key) return Promise.resolve(fail('amp_missing_key', 'The configured Amp API key variable is not set for the usage server.', 'unauthorized'));
    env.AMP_API_KEY = key;
  }
  return new Promise((resolve) => {
    execFile(options.ampBinary ?? 'amp', ['usage'], { env, encoding: 'utf8', timeout: options.timeoutMs ?? 20_000, maxBuffer: 64 * 1024, killSignal: 'SIGKILL' }, (error, stdout) => {
      if (error) {
        // Never surface CLI output: it can include account details.
        resolve((error as NodeJS.ErrnoException).code === 'ENOENT'
          ? fail('amp_missing_cli', 'The amp CLI is not installed for the usage server.')
          : /not (signed|logged) in|login/i.test(String(stdout)) ? fail('amp_signed_out', 'Amp is not signed in. Run amp login.', 'unauthorized')
            : fail('amp_failed', 'amp usage did not finish successfully.'));
        return;
      }
      resolve(normalizeAmpUsage(profile, stdout, new Date()));
    });
  });
}
