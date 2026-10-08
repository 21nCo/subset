import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, readFile, realpath, rename, rm, stat, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, resolve, sep } from 'node:path';
import { createInterface } from 'node:readline';
import { readCodexProfile } from '@subset/usage/codex';
import { readClaudeAuthStatus } from '@subset/usage/claude';
import { sanitizeSnapshot, normalizeSnapshot } from '@subset/usage/snapshots';

const validId = /^[a-zA-Z0-9_-]{1,64}$/;
const validEnv = /^[a-zA-Z_][a-zA-Z0-9_]{0,127}$/;
const snapshotProviders = new Set(['claude-code', 'antigravity']);
const maxProfiles = 20;
// Names are optional: '' means "show the account's email". null marks an invalid name.
const labelOf = (value) => value === undefined || value === null ? '' : typeof value === 'string' && value.trim().length <= 80 && !/[\x00-\x1f\x7f]/.test(value) ? value.trim() : null;
// Earlier versions named default accounts; those names now come from the Default tag and email.
const legacyDefaultLabels = new Set(['Current Codex account', 'Claude Code (default)']);
const object = (value) => value && typeof value === 'object' && !Array.isArray(value) ? value : null;
// Providers read with the tool's own sign-in, optionally another account's key (Amp, Devin only).
const keyedProviders = new Set(['amp', 'devin', 'cursor-local']);
const keyOptionProviders = new Set(['amp', 'devin']);
const storedLoginKinds = { pi: ['chatgpt', 'claude'], opencode: ['chatgpt', 'claude', 'opencode-go'], omp: ['chatgpt', 'claude'], hermes: ['chatgpt', 'claude'] };
const validEntryId = (value) => value === undefined || (typeof value === 'string' && /^\d{1,12}$/.test(value));
/** The account a Subset collector command collects for, or null for any other status line. */
export const collectorAccountId = (command) => {
  const match = /(?: collect|subset-usage-collect(?:-[0-9a-f]{10})?'?) --account '?([a-zA-Z0-9_-]{1,64})'?\s*$/.exec(command);
  return match ? match[1] : null;
};
const validCursorUserId = (value) => typeof value === 'string' && /^user_[a-zA-Z0-9_-]{1,251}$/.test(value);
// A Claude Code config directory (CLAUDE_CONFIG_DIR) is the documented boundary for side-by-side accounts.
const configDirOf = (value) => {
  if (typeof value !== 'string' || !value.trim() || value.length > 1024 || /[\x00-\x1f\x7f]/.test(value)) return null;
  const trimmed = value.trim();
  const expanded = trimmed === '~' ? homedir() : trimmed.startsWith('~/') ? join(homedir(), trimmed.slice(2)) : trimmed;
  return isAbsolute(expanded) ? resolve(expanded) : null;
};
const canonical = async (path) => { try { return await realpath(path); } catch { return resolve(path); } };
// Claude Code stores session transcripts under <config dir>/projects/<project>/<session>.jsonl.
const transcriptConfigDir = (input) => {
  const path = object(input)?.transcript_path;
  if (typeof path !== 'string' || !isAbsolute(path)) return null;
  const parts = resolve(path).split(sep);
  const index = parts.length - 3;
  return index >= 1 && parts[index] === 'projects' ? parts.slice(0, index).join(sep) || sep : null;
};

export function createAccounts({
  profilesFile = resolve(homedir(), '.config/subset/codex-profiles.json'),
  managedRoot = resolve(homedir(), '.local/share/subset/codex-accounts'),
  snapshotRoot = resolve(homedir(), '.local/share/subset/usage-snapshots'),
  currentHome = resolve(process.env.CODEX_HOME ?? join(homedir(), '.codex')),
  codexBinary = 'codex',
  loginTimeoutMs = 15 * 60_000,
  defaultClaudeConfigDir = resolve(process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude')),
  preferencesFile = join(dirname(profilesFile), 'usage-preferences.json'),
  // The reader decides itself whether a directory is Claude Code's built-in one (~/.claude).
  readClaudeAuth = (configDir) => readClaudeAuthStatus(configDir),
  antigravitySettingsFile = join(homedir(), '.gemini', 'antigravity-cli', 'settings.json'),
} = {}) {
  snapshotRoot = resolve(snapshotRoot);
  // Last collector run per account (time and outcome only), so the dashboard can explain missing quota.
  const runRoot = join(dirname(snapshotRoot), 'collector-runs');
  const runFile = (id) => join(runRoot, `${id}.json`);
  async function recordRun(id, result) {
    try {
      await mkdir(runRoot, { recursive: true, mode: 0o700 });
      const temporary = `${runFile(id)}.${randomUUID()}.tmp`;
      await writeFile(temporary, JSON.stringify({ schemaVersion: 1, at: new Date().toISOString(), result }), { mode: 0o600, flag: 'wx' });
      await rename(temporary, runFile(id)).catch(async () => { await rm(temporary, { force: true }); });
    } catch { /* diagnostics are best effort */ }
  }
  async function lastRun(id) {
    try {
      const value = object(JSON.parse(await readFile(runFile(id), 'utf8')));
      return value && typeof value.at === 'string' && Number.isFinite(Date.parse(value.at)) && ['saved', 'no-quota', 'wrong-directory'].includes(value.result)
        ? { at: value.at, result: value.result } : null;
    } catch { return null; }
  }
  defaultClaudeConfigDir = resolve(defaultClaudeConfigDir);
  const connections = new Map();
  let writeQueue = Promise.resolve();
  // Preference writes are read-modify-write too; they get their own queue because profile
  // mutations (account removal) also update preferences.
  let preferenceQueue = Promise.resolve();
  function updatePreferences(change) {
    const operation = preferenceQueue.then(async () => writePreferences(change(await preferences())));
    preferenceQueue = operation.catch(() => {});
    return operation;
  }

  async function profiles() {
    let value;
    try { value = JSON.parse(await readFile(profilesFile, 'utf8')); }
    catch (error) {
      if (error?.code === 'ENOENT') return [];
      throw new Error('Could not read usage profiles configuration.');
    }
    if (!Array.isArray(value) || value.length > maxProfiles) throw new Error('Usage profiles configuration must contain at most 20 profiles.');
    const ids = new Set();
    const sources = new Set();
    const cursorAccounts = new Set();
    const claudeConfigDirs = new Set();
    const connectionKeys = new Set();
    return value.map((item) => {
      if (!object(item) || typeof item.id !== 'string' || !validId.test(item.id) || labelOf(item.label) === null) throw new Error('Invalid usage profile configuration.');
      const provider = item.provider === undefined ? 'codex-chatgpt' : item.provider;
      const profile = { id: item.id, label: legacyDefaultLabels.has(labelOf(item.label)) && (item.id === 'current' || item.id.startsWith('claude_default')) ? '' : labelOf(item.label), provider, managed: item.managed === true };
      let source;
      let cursorAccount;
      if (provider === 'codex-chatgpt') {
        if (typeof item.codexHome !== 'string' || !isAbsolute(item.codexHome)) throw new Error('Invalid usage profile configuration.');
        profile.codexHome = source = resolve(item.codexHome);
      } else if (snapshotProviders.has(provider)) {
        if (typeof item.snapshotFile !== 'string' || !isAbsolute(item.snapshotFile)) throw new Error('Invalid usage profile configuration.');
        profile.snapshotFile = source = resolve(item.snapshotFile);
        if (item.claudeConfigDir !== undefined) {
          const configDir = provider === 'claude-code' && typeof item.claudeConfigDir === 'string' && isAbsolute(item.claudeConfigDir) ? resolve(item.claudeConfigDir) : null;
          if (!configDir) throw new Error('Invalid usage profile configuration.');
          if (claudeConfigDirs.has(configDir)) throw new Error('Duplicate usage profile configuration.');
          claudeConfigDirs.add(configDir);
          profile.claudeConfigDir = configDir;
        }
      } else if (keyedProviders.has(provider)) {
        if (item.credentialEnv !== undefined && (typeof item.credentialEnv !== 'string' || !validEnv.test(item.credentialEnv))) throw new Error('Invalid usage profile configuration.');
        if (item.credentialEnv) profile.credentialEnv = item.credentialEnv;
        profile.managed = false;
        const key = JSON.stringify([provider, item.credentialEnv ?? null]);
        if (connectionKeys.has(key)) throw new Error('Duplicate usage profile configuration.');
        connectionKeys.add(key);
      } else if (Object.hasOwn(storedLoginKinds, provider)) {
        if (!storedLoginKinds[provider].includes(item.login) || !validEntryId(item.entryId) || (item.dataDir !== undefined && (typeof item.dataDir !== 'string' || !isAbsolute(item.dataDir)))) throw new Error('Invalid usage profile configuration.');
        profile.login = item.login;
        if (item.entryId) profile.entryId = item.entryId;
        if (item.dataDir) profile.dataDir = resolve(item.dataDir);
        profile.managed = false;
        const key = JSON.stringify([provider, item.login, profile.dataDir ?? null, item.entryId ?? null]);
        if (connectionKeys.has(key)) throw new Error('Duplicate usage profile configuration.');
        connectionKeys.add(key);
      } else if (provider === 'factory-droid') {
        if (typeof item.factoryHome !== 'string' || !isAbsolute(item.factoryHome) || (item.credentialEnv !== undefined && (typeof item.credentialEnv !== 'string' || !validEnv.test(item.credentialEnv)))) throw new Error('Invalid usage profile configuration.');
        profile.factoryHome = resolve(item.factoryHome);
        if (item.credentialEnv) profile.credentialEnv = item.credentialEnv;
        profile.managed = false;
        const key = JSON.stringify([profile.factoryHome, item.credentialEnv ?? null]);
        if (connectionKeys.has(key)) throw new Error('Duplicate usage profile configuration.');
        connectionKeys.add(key);
      } else if (provider === 'cursor') {
        if (typeof item.credentialEnv !== 'string' || !validEnv.test(item.credentialEnv) || !validCursorUserId(item.cursorUserId)) throw new Error('Invalid usage profile configuration.');
        profile.credentialEnv = item.credentialEnv;
        profile.cursorUserId = item.cursorUserId;
        profile.managed = false;
        cursorAccount = JSON.stringify([item.credentialEnv, item.cursorUserId]);
      } else throw new Error('Invalid usage profile configuration.');
      if (ids.has(item.id) || (source && sources.has(source)) || (cursorAccount && cursorAccounts.has(cursorAccount))) throw new Error('Duplicate usage profile configuration.');
      ids.add(item.id);
      if (source) sources.add(source);
      if (cursorAccount) cursorAccounts.add(cursorAccount);
      return profile;
    });
  }

  async function save(next) {
    const directory = dirname(profilesFile);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const temporary = `${profilesFile}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporary, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
      await rename(temporary, profilesFile);
    } finally { await rm(temporary, { force: true }); }
  }

  function mutate(change) {
    const operation = writeQueue.then(async () => {
      const existing = await profiles();
      const { next, result } = await change(existing);
      if (next) await save(next);
      return result;
    });
    writeQueue = operation.catch(() => {});
    return operation;
  }

  async function list() {
    return (await profiles()).map((profile) => ({ id: profile.id, label: profile.label, provider: profile.provider, managed: profile.managed, current: profile.provider === 'codex-chatgpt' && profile.codexHome === currentHome,
      ...(profile.claudeConfigDir ? { claudeConfigDir: profile.claudeConfigDir, defaultClaude: profile.claudeConfigDir === defaultClaudeConfigDir } : {}),
      ...(profile.provider === 'factory-droid' ? { factoryHome: profile.factoryHome, apiKeyConfigured: !!profile.credentialEnv } : {}),
      ...(keyedProviders.has(profile.provider) ? { apiKeyConfigured: !!profile.credentialEnv } : {}),
      ...(profile.login ? { login: profile.login } : {}), ...(profile.entryId ? { entryId: profile.entryId } : {}) }));
  }

  async function addCurrent() {
    const profile = { id: 'current', label: '', provider: 'codex-chatgpt', codexHome: currentHome, managed: false };
    const account = await readCodexProfile(profile, { codexBinary });
    if (!['ok', 'partial'].includes(account.state)) throw new Error('The current Codex home is not signed in with a ChatGPT account.');
    return mutate((existing) => {
      const found = existing.find((item) => item.codexHome === currentHome);
      if (found) return { result: { id: found.id, label: found.label } };
      if (existing.some((item) => item.snapshotFile === currentHome)) throw new Error('Duplicate usage profile configuration.');
      if (existing.length >= maxProfiles) throw new Error('The dashboard already has 20 accounts.');
      const id = existing.some((item) => item.id === profile.id) ? `current_${randomUUID().slice(0, 8)}` : profile.id;
      const added = { ...profile, id };
      return { next: [...existing, added], result: { id, label: added.label } };
    });
  }

  /** Renames an account; an empty name shows the account's email instead. */
  async function renameProfile(id, rawLabel) {
    if (typeof id !== 'string' || !validId.test(id)) throw new Error('Invalid account ID.');
    const label = labelOf(rawLabel);
    if (label === null) throw new Error('Enter an account name of at most 80 characters.');
    return mutate((existing) => {
      if (!existing.some((item) => item.id === id)) throw new Error('Account was not found.');
      return { next: existing.map((item) => item.id === id ? { ...item, label } : item), result: { id, label } };
    });
  }

  async function removeProfile(id) {
    if (typeof id !== 'string' || !validId.test(id)) throw new Error('Invalid account ID.');
    return mutate(async (existing) => {
      const profile = existing.find((item) => item.id === id);
      if (!profile) throw new Error('Account was not found.');
      // Restore the CLI's previous status line before forgetting the account.
      // Keep the account when its collector can't be removed, so no status line runs a collector for a forgotten account.
      try { await uninstallCollector(id); }
      catch { throw new Error('Could not restore the CLI status line for this account. Fix its settings.json, then remove the account again.'); }
      await rm(runFile(id), { force: true }).catch(() => {});
      await save(existing.filter((item) => item.id !== id));
      if (profile.claudeConfigDir === defaultClaudeConfigDir) await setDefaultClaudeDismissed(true);
      if (profile.managed && profile.provider === 'codex-chatgpt' && profile.codexHome === join(managedRoot, profile.id)) {
        await rm(profile.codexHome, { recursive: true, force: true });
      } else if (profile.managed && snapshotProviders.has(profile.provider) && profile.snapshotFile === join(snapshotRoot, `${profile.id}.json`)) {
        await rm(profile.snapshotFile, { force: true });
      }
      return { result: { id } };
    });
  }

  async function addProvider(input) {
    if (!object(input) || Object.keys(input).some((key) => !['provider', 'label', 'credentialEnv', 'cursorUserId', 'claudeConfigDir', 'factoryHome', 'login', 'entryId'].includes(key))) throw new Error('Invalid usage account configuration.');
    if (input.provider === 'factory-droid') return addFactory(input);
    if (keyedProviders.has(input.provider) || Object.hasOwn(storedLoginKinds, input.provider)) return addLocalTool(input);
    const { provider, credentialEnv, cursorUserId } = input;
    const claudeConfigDir = input.claudeConfigDir === undefined || input.claudeConfigDir === '' ? undefined : configDirOf(input.claudeConfigDir);
    if (claudeConfigDir === null || (claudeConfigDir !== undefined && provider !== 'claude-code')) throw new Error('Enter the Claude Code config directory as an absolute or ~/ path.');
    const label = labelOf(input.label);
    if (label === null) throw new Error('Enter an account name of at most 80 characters.');
    if (!snapshotProviders.has(provider) && provider !== 'cursor') throw new Error('Unsupported usage provider.');
    if (provider === 'cursor') {
      if (typeof credentialEnv !== 'string' || !validEnv.test(credentialEnv) || !validCursorUserId(cursorUserId)) throw new Error('Invalid usage account configuration.');
    } else if (credentialEnv !== undefined || cursorUserId !== undefined) throw new Error('Invalid usage account configuration.');
    return mutate((existing) => {
      if (existing.length >= maxProfiles) throw new Error('The dashboard already has 20 accounts.');
      if (provider === 'cursor' && existing.some((profile) => profile.provider === provider && profile.credentialEnv === credentialEnv && profile.cursorUserId === cursorUserId)) throw new Error('Duplicate usage profile configuration.');
      if (claudeConfigDir && existing.some((profile) => profile.claudeConfigDir === claudeConfigDir)) throw new Error('Another Claude Code account already uses this config directory.');
      const id = `${provider}_${randomUUID()}`;
      const added = provider === 'cursor'
        ? { id, label, provider, managed: false, credentialEnv, cursorUserId }
        : { id, label, provider, managed: true, snapshotFile: join(snapshotRoot, `${id}.json`), ...(claudeConfigDir ? { claudeConfigDir } : {}) };
      if (existing.some((profile) => profile.id === id || (added.snapshotFile && (profile.snapshotFile === added.snapshotFile || profile.codexHome === added.snapshotFile)))) throw new Error('Duplicate usage profile configuration.');
      return { next: [...existing, added], result: { id, label, provider } };
    });
  }

  async function preferences() {
    try { return object(JSON.parse(await readFile(preferencesFile, 'utf8'))) ?? {}; }
    catch { return {}; }
  }

  async function setDefaultClaudeDismissed(dismissed) {
    await updatePreferences((current) => ({ ...current, defaultClaudeDismissed: dismissed }));
  }

  async function writePreferences(next) {
    await mkdir(dirname(preferencesFile), { recursive: true, mode: 0o700 });
    const temporary = `${preferencesFile}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporary, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
      await rename(temporary, preferencesFile);
    } finally { await rm(temporary, { force: true }); }
  }

  /**
   * The default Claude Code account as it would be added, without saving it: read-only commands
   * such as `status` show it transiently. Null when dismissed, already configured, or signed out.
   */
  async function defaultClaudeCandidate() {
    if ((await preferences()).defaultClaudeDismissed === true) return null;
    const configured = await profiles();
    if (configured.some((profile) => profile.claudeConfigDir === defaultClaudeConfigDir) || configured.length >= maxProfiles) return null;
    if (!(await readClaudeAuth(defaultClaudeConfigDir))?.loggedIn) return null;
    const id = configured.some((profile) => profile.id === 'claude_default') ? null : 'claude_default';
    return id ? { id, label: '', provider: 'claude-code', managed: true, snapshotFile: join(snapshotRoot, `${id}.json`), claudeConfigDir: defaultClaudeConfigDir } : null;
  }

  // Shows the default Claude Code sign-in without setup unless the user removed it.
  async function ensureDefaultClaude({ force = false } = {}) {
    if (!force && (await preferences()).defaultClaudeDismissed === true) return null;
    const configured = await profiles();
    const found = configured.find((profile) => profile.claudeConfigDir === defaultClaudeConfigDir);
    if (found) return { id: found.id, label: found.label, provider: found.provider };
    const auth = await readClaudeAuth(defaultClaudeConfigDir);
    if (!auth?.loggedIn) {
      if (force) throw new Error('The default Claude Code config directory is not signed in.');
      return null;
    }
    const result = await mutate((existing) => {
      const current = existing.find((profile) => profile.claudeConfigDir === defaultClaudeConfigDir);
      if (current) return { result: { id: current.id, label: current.label, provider: current.provider } };
      if (existing.length >= maxProfiles) {
        if (force) throw new Error('The dashboard already has 20 accounts.');
        return { result: null };
      }
      const id = existing.some((profile) => profile.id === 'claude_default') ? `claude_default_${randomUUID().slice(0, 8)}` : 'claude_default';
      const added = { id, label: '', provider: 'claude-code', managed: true, snapshotFile: join(snapshotRoot, `${id}.json`), claudeConfigDir: defaultClaudeConfigDir };
      return { next: [...existing, added], result: { id, label: added.label, provider: added.provider } };
    });
    if (force) await setDefaultClaudeDismissed(false);
    return result;
  }

  async function addLocalTool(input) {
    const { provider } = input;
    const label = labelOf(input.label);
    if (label === null) throw new Error('Enter an account name of at most 80 characters.');
    if (input.cursorUserId !== undefined || input.claudeConfigDir !== undefined || input.factoryHome !== undefined) throw new Error('Invalid usage account configuration.');
    const credentialEnv = input.credentialEnv === undefined || input.credentialEnv === '' ? undefined : input.credentialEnv;
    if (credentialEnv !== undefined && (!keyOptionProviders.has(provider) || typeof credentialEnv !== 'string' || !validEnv.test(credentialEnv))) throw new Error('Invalid usage account configuration.');
    const login = storedLoginKinds[provider] ? input.login : undefined;
    if (storedLoginKinds[provider] ? !storedLoginKinds[provider].includes(login) : input.login !== undefined) throw new Error('Choose which stored login to read.');
    const entryId = storedLoginKinds[provider] && input.entryId ? input.entryId : undefined;
    if (!validEntryId(input.entryId) || (input.entryId !== undefined && !storedLoginKinds[provider])) throw new Error('Choose which stored login to read.');
    return mutate((existing) => {
      if (existing.length >= maxProfiles) throw new Error('The dashboard already has 20 accounts.');
      if (existing.some((profile) => profile.provider === provider && (profile.credentialEnv ?? null) === (credentialEnv ?? null) && (profile.login ?? null) === (login ?? null) && (profile.entryId ?? null) === (entryId ?? null))) throw new Error('Duplicate usage profile configuration.');
      const id = `${provider}_${randomUUID()}`;
      const added = { id, label, provider, managed: false, ...(credentialEnv ? { credentialEnv } : {}), ...(login ? { login } : {}), ...(entryId ? { entryId } : {}) };
      return { next: [...existing, added], result: { id, label, provider } };
    });
  }

  async function addFactory(input) {
    const label = labelOf(input.label);
    if (label === null) throw new Error('Enter an account name of at most 80 characters.');
    if (input.cursorUserId !== undefined || input.claudeConfigDir !== undefined) throw new Error('Invalid usage account configuration.');
    const factoryHome = input.factoryHome === undefined || input.factoryHome === '' ? homedir() : configDirOf(input.factoryHome);
    if (!factoryHome) throw new Error('Enter the Factory home as an absolute or ~/ path.');
    const credentialEnv = input.credentialEnv === undefined || input.credentialEnv === '' ? undefined : input.credentialEnv;
    if (credentialEnv !== undefined && (typeof credentialEnv !== 'string' || !validEnv.test(credentialEnv))) throw new Error('Invalid usage account configuration.');
    return mutate((existing) => {
      if (existing.length >= maxProfiles) throw new Error('The dashboard already has 20 accounts.');
      if (existing.some((profile) => profile.provider === 'factory-droid' && profile.factoryHome === factoryHome && (profile.credentialEnv ?? null) === (credentialEnv ?? null))) throw new Error('Duplicate usage profile configuration.');
      const id = `factory-droid_${randomUUID()}`;
      const added = { id, label, provider: 'factory-droid', managed: false, factoryHome, ...(credentialEnv ? { credentialEnv } : {}) };
      return { next: [...existing, added], result: { id, label, provider: 'factory-droid' } };
    });
  }

  /**
   * Server-side settings. Local sign-ins stay off until the user answers the first-run question,
   * which the dashboard shows while `localCredentialsChosen` is false.
   */
  async function usagePreferences() {
    const value = await preferences();
    return { localCredentials: value.localCredentials === true, localCredentialsChosen: typeof value.localCredentials === 'boolean' };
  }

  async function setUsagePreferences(input) {
    if (!object(input) || Object.keys(input).some((key) => key !== 'localCredentials') || typeof input.localCredentials !== 'boolean') throw new Error('Invalid settings.');
    await updatePreferences((current) => ({ ...current, localCredentials: input.localCredentials }));
    return usagePreferences();
  }

  async function captureSnapshot(id, input, { env } = {}) {
    if (typeof id !== 'string' || !validId.test(id)) throw new Error('Invalid account ID.');
    return mutate(async (existing) => {
      const profile = existing.find((item) => item.id === id);
      if (!profile) throw new Error('Account was not found.');
      if (!snapshotProviders.has(profile.provider)) throw new Error('This account does not support quota snapshots.');
      if (profile.claudeConfigDir) {
        // The transcript path survives Claude Code's subprocess env scrub; CLAUDE_CONFIG_DIR may not.
        const envDir = typeof env?.CLAUDE_CONFIG_DIR === 'string' && env.CLAUDE_CONFIG_DIR ? configDirOf(env.CLAUDE_CONFIG_DIR) : null;
        const observed = transcriptConfigDir(input) ?? envDir;
        if (observed && await canonical(observed) !== await canonical(profile.claudeConfigDir)) {
          await recordRun(id, 'wrong-directory');
          throw new Error('This collector ran under a different Claude Code config directory than its account.');
        }
      }
      const observedAt = new Date();
      const data = sanitizeSnapshot(profile, input);
      const normalized = normalizeSnapshot(profile, data, observedAt);
      // Startup statusline payloads have no quota; keep the last useful observation.
      if (!normalized.windows.some((window) => window.usedPercent !== null || window.remainingPercent !== null)) {
        await recordRun(id, 'no-quota');
        return { result: { id, state: normalized.state } };
      }
      const envelope = { schemaVersion: 1, provider: profile.provider, accountId: id, observedAt: observedAt.toISOString(), data };
      const temporary = `${profile.snapshotFile}.${randomUUID()}.tmp`;
      try {
        await mkdir(dirname(profile.snapshotFile), { recursive: true, mode: 0o700 });
        await writeFile(temporary, `${JSON.stringify(envelope)}\n`, { mode: 0o600, flag: 'wx' });
        await rename(temporary, profile.snapshotFile);
        // CLI collectors run in separate processes from account removal.
        const current = (await profiles()).find((item) => item.id === id);
        if (!current || current.provider !== profile.provider || current.snapshotFile !== profile.snapshotFile) {
          if (profile.managed && profile.snapshotFile === join(snapshotRoot, `${id}.json`)) await rm(profile.snapshotFile, { force: true });
          throw new Error('Account changed during quota collection.');
        }
      } catch {
        throw new Error('Could not save usage quota snapshot.');
      } finally { await rm(temporary, { force: true }).catch(() => {}); }
      await recordRun(id, 'saved');
      return { result: { id, state: normalized.state } };
    });
  }

  // Collector installation edits one provider settings file, only on an explicit request.
  // The replaced statusLine is kept in a Subset-owned file so the collector can keep running it and removal can restore it.
  const chainFile = (id) => join(snapshotRoot, `${id}.statusline.json`);
  const maxSettingsBytes = 1024 * 1024;

  function settingsFileFor(profile) {
    if (profile.provider === 'claude-code') return profile.claudeConfigDir ? join(profile.claudeConfigDir, 'settings.json') : null;
    if (profile.provider === 'antigravity') return antigravitySettingsFile;
    return null;
  }

  async function readSettings(file) {
    let text;
    try { text = await readFile(file, 'utf8'); }
    catch (error) {
      if (error?.code === 'ENOENT') return {};
      throw new Error('Could not read the CLI settings file.');
    }
    if (text.length > maxSettingsBytes) throw new Error('The CLI settings file is too large to update safely.');
    if (!text.trim()) return {};
    let value;
    try { value = JSON.parse(text); } catch { throw new Error('The CLI settings file is not valid JSON. Fix it or set up the collector manually.'); }
    if (!object(value)) throw new Error('The CLI settings file is not valid JSON. Fix it or set up the collector manually.');
    return value;
  }

  async function writeSettings(path, value) {
    // Write through a symlink (for example a settings.json managed in a dotfiles repository)
    // instead of replacing the link with a regular file.
    const file = await canonical(path);
    let mode = 0o600;
    try { mode = (await stat(file)).mode & 0o777; } catch { /* new file */ }
    const temporary = `${file}.subset-${randomUUID()}.tmp`;
    try {
      await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode, flag: 'wx' });
      await rename(temporary, file);
    } finally { await rm(temporary, { force: true }).catch(() => {}); }
  }

  async function readChain(id) {
    try {
      const value = object(JSON.parse(await readFile(chainFile(id), 'utf8')));
      if (!value || typeof value.command !== 'string' || typeof value.settingsFile !== 'string') return null;
      const previous = object(value.previous);
      return { command: value.command, settingsFile: value.settingsFile, installedAt: typeof value.installedAt === 'string' ? value.installedAt : null, previous: previous && typeof previous.command === 'string' && previous.command.length <= 65536 ? previous : null };
    } catch { return null; }
  }

  async function collectorStatus(profile, command) {
    const settingsFile = settingsFileFor(profile);
    if (!settingsFile) return { state: 'manual', settingsFile: null, chained: false };
    const chain = await readChain(profile.id);
    let settings;
    try { settings = await readSettings(settingsFile); }
    catch { return { state: 'unreadable', settingsFile, chained: false }; }
    const current = object(settings.statusLine);
    if (current?.command === command) return { state: 'installed', settingsFile, chained: !!chain?.previous, lastRun: await lastRun(profile.id), installedAt: chain?.installedAt ?? null };
    // Accounts sharing one settings file (Antigravity) can't both collect: report the owner instead of offering a swap.
    const owner = typeof current?.command === 'string' ? collectorAccountId(current.command) : null;
    if (owner && owner !== profile.id && (await profiles()).some((item) => item.id === owner)) return { state: 'other-account', settingsFile, chained: false, otherAccount: owner };
    try { if (!(await stat(dirname(settingsFile))).isDirectory()) throw new Error(); }
    catch { return { state: 'missing-directory', settingsFile, chained: false }; }
    return { state: chain ? 'replaced' : 'not-installed', settingsFile, chained: false, existing: !!current };
  }

  async function installCollector(id, command) {
    if (typeof id !== 'string' || !validId.test(id)) throw new Error('Invalid account ID.');
    const profile = (await profiles()).find((item) => item.id === id);
    if (!profile) throw new Error('Account was not found.');
    const settingsFile = settingsFileFor(profile);
    if (!settingsFile) throw new Error('Set a Claude Code config directory for this account to install its collector automatically.');
    try { if (!(await stat(dirname(settingsFile))).isDirectory()) throw new Error(); }
    catch { throw new Error('The CLI settings directory was not found. Start the CLI once with this account, then try again.'); }
    const settings = await readSettings(settingsFile);
    const current = object(settings.statusLine);
    if (current?.command === command) return { id, state: 'installed' };
    // Keep the status line another tool or the user configured, and keep rendering it. When the
    // current line is another Subset collector (accounts can share one settings file), inherit
    // the line that collector itself replaced.
    const replacedId = current && typeof current.command === 'string' ? collectorAccountId(current.command) : null;
    if (replacedId && replacedId !== id && (await profiles()).some((item) => item.id === replacedId)) throw new Error('Another account\'s collector uses this CLI\'s status line. Uninstall it from that account first.');
    const previous = current && typeof current.command === 'string' && !replacedId ? current
      : (replacedId ? (await readChain(replacedId))?.previous : null) ?? (await readChain(id))?.previous ?? null;
    await mkdir(snapshotRoot, { recursive: true, mode: 0o700 });
    await writeFile(chainFile(id), `${JSON.stringify({ schemaVersion: 1, command, settingsFile, previous, installedAt: new Date().toISOString() })}\n`, { mode: 0o600 });
    // The first backup holds the settings from before any collector; later installs keep it.
    try { await writeFile(`${settingsFile}.subset-backup`, await readFile(settingsFile), { mode: 0o600, flag: 'wx' }); }
    catch (error) { if (error?.code !== 'ENOENT' && error?.code !== 'EEXIST') throw new Error('Could not back up the CLI settings file.'); }
    const { command: _command, type: _type, ...rest } = current ?? {};
    await writeSettings(settingsFile, { ...settings, statusLine: { ...rest, type: 'command', command } });
    return { id, state: 'installed' };
  }

  async function uninstallCollector(id) {
    if (typeof id !== 'string' || !validId.test(id)) throw new Error('Invalid account ID.');
    const chain = await readChain(id);
    if (!chain) return { id, state: 'not-installed' };
    const settings = await readSettings(chain.settingsFile);
    // Leave settings alone when another tool has since replaced the collector.
    if (object(settings.statusLine)?.command === chain.command) {
      const next = { ...settings };
      if (chain.previous) next.statusLine = chain.previous; else delete next.statusLine;
      await writeSettings(chain.settingsFile, next);
    }
    await rm(chainFile(id), { force: true });
    return { id, state: 'not-installed' };
  }

  /**
   * Points installed collectors at the current collect command, for example after the CLI moved.
   * Only settings whose status line is still the recorded collector are changed.
   */
  async function migrateCollectors(commandFor) {
    const migrated = [];
    for (const profile of await profiles()) {
      const chain = await readChain(profile.id);
      const command = commandFor(profile.id);
      if (!chain || chain.command === command) continue;
      try {
        const settings = await readSettings(chain.settingsFile);
        const current = object(settings.statusLine);
        if (current?.command !== chain.command) continue;
        await writeSettings(chain.settingsFile, { ...settings, statusLine: { ...current, command } });
        await writeFile(chainFile(profile.id), `${JSON.stringify({ schemaVersion: 1, command, settingsFile: chain.settingsFile, previous: chain.previous, installedAt: chain.installedAt })}\n`, { mode: 0o600 });
        migrated.push(profile.id);
      } catch { /* leave unreadable settings for the user to fix */ }
    }
    return migrated;
  }

  /** The status line the collector replaced, run after capture so the CLI keeps its existing display. */
  async function chainedStatusLine(id) {
    if (typeof id !== 'string' || !validId.test(id)) return null;
    return (await readChain(id))?.previous?.command ?? null;
  }

  function publicConnection(record) {
    return { id: record.id, state: record.state, error: record.error ?? null };
  }

  function session(home, onNotification, onExit) {
    const env = { ...process.env, CODEX_HOME: home };
    delete env.OPENAI_API_KEY;
    delete env.CODEX_ACCESS_TOKEN;
    const child = spawn(codexBinary, ['app-server', '--listen', 'stdio://'], { env, stdio: ['pipe', 'pipe', 'ignore'] });
    const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
    const waiting = new Map();
    let nextId = 1;
    let closed = false;
    const fail = () => {
      for (const waiter of waiting.values()) { clearTimeout(waiter.timer); waiter.reject(new Error('Codex sign-in service stopped.')); }
      waiting.clear();
      if (!closed) onExit();
    };
    child.on('error', fail);
    child.on('exit', fail);
    child.stdin.on('error', fail);
    lines.on('line', (line) => {
      if (line.length > 1024 * 1024) { child.kill(); return; }
      let message;
      try { message = object(JSON.parse(line)); } catch { return; }
      if (!message) return;
      if (typeof message.id === 'number' && message.method === undefined) {
        const waiter = waiting.get(message.id);
        if (!waiter) return;
        waiting.delete(message.id);
        clearTimeout(waiter.timer);
        if (message.error) waiter.reject(new Error('Codex sign-in request failed.'));
        else waiter.resolve(message.result);
      } else if (typeof message.method === 'string') onNotification(message);
    });
    return {
      request(method, params) {
        return new Promise((resolveRequest, reject) => {
          const id = nextId++;
          const timer = setTimeout(() => { waiting.delete(id); reject(new Error('Codex sign-in request timed out.')); }, 15000);
          waiting.set(id, { resolve: resolveRequest, reject, timer });
          child.stdin.write(`${JSON.stringify({ id, method, ...(params ? { params } : {}) })}\n`);
        });
      },
      notify(method, params = {}) { child.stdin.write(`${JSON.stringify({ method, params })}\n`); },
      close() { closed = true; lines.close(); child.kill(); },
    };
  }

  async function startLogin(rawLabel) {
    const label = labelOf(rawLabel);
    if (label === null) throw new Error('Enter an account name of at most 80 characters.');
    if ([...connections.values()].some((item) => item.state === 'starting' || item.state === 'pending' || item.state === 'validating')) throw new Error('Finish or cancel the current sign-in first.');
    // Only one sign-in is active at a time; earlier finished records are no longer polled.
    for (const [key, item] of connections) if (['connected', 'cancelled', 'error'].includes(item.state)) connections.delete(key);
    const id = `chatgpt_${randomUUID()}`;
    const home = join(managedRoot, id);
    const record = { id, label, home, state: 'starting', error: null, loginId: null, authUrl: null, client: null, timer: null, finalization: null };
    // Reserve the slot before any await, so a concurrent request sees this sign-in.
    connections.set(id, record);
    try {
      if ((await profiles()).length >= maxProfiles) throw new Error('The dashboard already has 20 accounts.');
    } catch (error) { connections.delete(id); throw error; }
    let notification = null;
    let finishing = false;
    const cleanup = async (message) => {
      if (['connected', 'cancelled', 'error'].includes(record.state)) return;
      record.state = 'error'; record.error = message;
      clearTimeout(record.timer); record.client?.close();
      await rm(home, { recursive: true, force: true }).catch(() => {});
    };
    const finish = async () => {
      if (!notification || !record.loginId || finishing || record.state !== 'pending') return;
      if (notification.params?.loginId !== record.loginId) return;
      finishing = true;
      if (notification.params?.success !== true) { await cleanup('ChatGPT sign-in did not finish.'); return; }
      record.state = 'validating';
      clearTimeout(record.timer);
      try {
        const result = await record.client.request('account/read', { refreshToken: false });
        if (object(result)?.account?.type !== 'chatgpt') throw new Error('The account was not signed in with ChatGPT.');
        await mutate((existing) => {
          if (record.state !== 'validating') throw new Error('Sign-in was cancelled.');
          if (existing.length >= maxProfiles) throw new Error('The dashboard already has 20 accounts.');
          if (existing.some((profile) => profile.id === id || profile.codexHome === home || profile.snapshotFile === home)) throw new Error('Duplicate usage profile configuration.');
          return { next: [...existing, { id, label, provider: 'codex-chatgpt', codexHome: home, managed: true }], result: null };
        });
        record.state = 'connected';
        clearTimeout(record.timer); record.client.close();
      } catch { await cleanup('Could not finish connecting this ChatGPT account.'); }
    };
    const ensureStarting = () => { if (record.state !== 'starting') throw new Error('Sign-in was cancelled.'); };
    try {
      await mkdir(managedRoot, { recursive: true, mode: 0o700 });
      await mkdir(home, { mode: 0o700 });
      ensureStarting();
      record.client = session(home, (message) => {
        if (message.method === 'account/login/completed') { notification = message; record.finalization = finish(); }
      }, () => { void cleanup('Codex sign-in service stopped.'); });
      await record.client.request('initialize', { clientInfo: { name: 'subset_usage', title: 'Subset Usage', version: '0.0.0' } });
      ensureStarting();
      record.client.notify('initialized');
      const response = object(await record.client.request('account/login/start', { type: 'chatgpt', useHostedLoginSuccessPage: true, appBrand: 'chatgpt' }));
      ensureStarting();
      const url = new URL(response?.authUrl ?? '');
      if (response?.type !== 'chatgpt' || typeof response.loginId !== 'string' || url.protocol !== 'https:' || !['chatgpt.com', 'auth.openai.com'].includes(url.hostname)) throw new Error('Codex returned an unsupported sign-in flow.');
      record.loginId = response.loginId;
      record.authUrl = url.href;
      record.state = 'pending';
      record.timer = setTimeout(() => { void cleanup('ChatGPT sign-in timed out.'); }, loginTimeoutMs);
      record.finalization = finish();
      return { id, authUrl: record.authUrl, state: record.state };
    } catch {
      if (record.state === 'cancelled') {
        // Cancellation may race directory creation; remove anything created after it.
        record.client?.close();
        await rm(home, { recursive: true, force: true }).catch(() => {});
        throw new Error('Sign-in was cancelled.');
      }
      await cleanup('Could not start ChatGPT sign-in.');
      throw new Error('Could not start ChatGPT sign-in.');
    }
  }

  function connection(id) {
    const record = connections.get(id);
    if (!record) throw new Error('Sign-in was not found.');
    return publicConnection(record);
  }

  function activeConnection() {
    const record = [...connections.values()].find((item) => ['starting', 'pending', 'validating'].includes(item.state));
    return record ? { ...publicConnection(record), authUrl: record.authUrl } : null;
  }

  async function cancelLogin(id) {
    const record = connections.get(id);
    if (!record || !['starting', 'pending'].includes(record.state)) throw new Error('No active sign-in was found.');
    record.state = 'cancelled';
    clearTimeout(record.timer);
    if (record.loginId) await record.client?.request('account/login/cancel', { loginId: record.loginId }).catch(() => {});
    record.client?.close();
    await rm(record.home, { recursive: true, force: true });
    return publicConnection(record);
  }

  async function close() {
    for (const record of connections.values()) {
      clearTimeout(record.timer);
      if (record.state === 'validating') await record.finalization;
      if (['starting', 'pending'].includes(record.state)) {
        record.state = 'cancelled';
        record.client?.close();
        await rm(record.home, { recursive: true, force: true });
      }
    }
  }

  return { profiles, list, addCurrent, addProvider, renameProfile, usagePreferences, setUsagePreferences, ensureDefaultClaude, defaultClaudeConfigDir, defaultClaudeCandidate, collectorStatus, installCollector, uninstallCollector, migrateCollectors, chainedStatusLine, captureSnapshot, removeProfile, startLogin, connection, activeConnection, cancelLogin, close };
}
