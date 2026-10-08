import { spawn } from 'node:child_process';
import { stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { isAbsolute, resolve } from 'node:path';
import { isEmail, type UsageAccount } from './index.js';

const MAX_BYTES = 64 * 1024;
const safeName = (value: unknown): string | null => typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,63}$/.test(value) ? value : null;

/** Sign-in state reported by `claude auth status --json`. Organization IDs are discarded. */
export interface ClaudeAuthStatus {
  loggedIn: boolean;
  email: string | null;
  authMethod: string | null;
  subscriptionType: string | null;
  configDirectory: string | null;
}

export function normalizeClaudeAuthStatus(input: unknown): ClaudeAuthStatus | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const value = input as Record<string, unknown>;
  if (typeof value.loggedIn !== 'boolean') return null;
  const configDirectory = typeof value.configDirectory === 'string' && value.configDirectory.length <= 1024 && isAbsolute(value.configDirectory) ? resolve(value.configDirectory) : null;
  return { loggedIn: value.loggedIn, email: value.loggedIn && isEmail(value.email) ? value.email : null, authMethod: safeName(value.authMethod), subscriptionType: safeName(value.subscriptionType), configDirectory };
}

/** Claude Code's built-in config directory, used when CLAUDE_CONFIG_DIR is unset. Its keychain item has no directory suffix. */
export const claudeBuiltInConfigDir = (): string => resolve(homedir(), '.claude');

/**
 * Reads the documented Claude Code CLI sign-in status for one config directory.
 * The CLI owns credentials; Subset never reads them. A missing directory is not probed,
 * because the CLI creates the directory it is pointed at.
 */
export async function readClaudeAuthStatus(configDir: string, options: { claudeBinary?: string; timeoutMs?: number; builtInConfigDir?: string } = {}): Promise<ClaudeAuthStatus | null> {
  const directory = resolve(configDir);
  try { if (!(await stat(directory)).isDirectory()) return null; } catch { return null; }
  const env: NodeJS.ProcessEnv = { ...process.env };
  // Token variables would report their own account instead of the directory's stored sign-in.
  for (const key of ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN']) delete env[key];
  // Only Claude Code's own default (~/.claude) runs without the variable; any other directory,
  // including a default the host took from CLAUDE_CONFIG_DIR, is passed through explicitly.
  if (directory === resolve(options.builtInConfigDir ?? claudeBuiltInConfigDir())) delete env.CLAUDE_CONFIG_DIR;
  else env.CLAUDE_CONFIG_DIR = directory;
  return new Promise((resolveStatus) => {
    let output = '';
    let settled = false;
    const done = (value: ClaudeAuthStatus | null) => { if (!settled) { settled = true; clearTimeout(timer); child.kill(); resolveStatus(value); } };
    const child = spawn(options.claudeBinary ?? 'claude', ['auth', 'status', '--json'], { env, stdio: ['ignore', 'pipe', 'ignore'] });
    const timer = setTimeout(() => done(null), options.timeoutMs ?? 10_000);
    child.on('error', () => done(null));
    child.stdout.on('data', (chunk: Buffer) => {
      output += chunk.toString('utf8');
      if (output.length > MAX_BYTES) done(null);
    });
    child.on('close', () => {
      try { done(normalizeClaudeAuthStatus(JSON.parse(output))); } catch { done(null); }
    });
  });
}

/** Adds live sign-in state to a Claude Code quota snapshot account. */
export function withClaudeAuth(account: UsageAccount, auth: ClaudeAuthStatus | null): UsageAccount {
  if (!auth) return account;
  const next: UsageAccount = { ...account, plan: account.plan ?? auth.subscriptionType, ...(auth.email ? { email: auth.email } : {}), errors: [...account.errors] };
  if (!auth.loggedIn) {
    next.state = 'unauthorized';
    next.errors.unshift({ code: 'claude_signed_out', message: 'Claude Code is not signed in for this config directory. Run claude and use /login.' });
  } else if (auth.authMethod !== 'claude.ai') {
    next.state = 'unsupported';
    next.errors.unshift({ code: 'claude_not_subscription', message: 'This Claude Code config directory does not use a claude.ai subscription sign-in, so subscription quota is unavailable.' });
  } else if (account.observedAt === null) {
    // Signed in, but no collector has delivered quota yet; replace the generic read error.
    next.errors = [{ code: 'claude_awaiting_snapshot', message: 'Signed in to Claude Code. Quota appears after this account\'s status-line collector runs during a Claude Code session.' }];
  }
  return next;
}
