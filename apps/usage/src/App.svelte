<script lang="ts">
  import '@21n/fonts/styles.css';
  import { onMount, tick } from 'svelte';
  import ArrowClockwiseIcon from 'phosphor-svelte/lib/ArrowClockwiseIcon';
  import ArrowSquareOutIcon from 'phosphor-svelte/lib/ArrowSquareOutIcon';
  import ChartBarIcon from 'phosphor-svelte/lib/ChartBarIcon';
  import GearSixIcon from 'phosphor-svelte/lib/GearSixIcon';
  import CheckCircleIcon from 'phosphor-svelte/lib/CheckCircleIcon';
  import CopyIcon from 'phosphor-svelte/lib/CopyIcon';
  import PlugsConnectedIcon from 'phosphor-svelte/lib/PlugsConnectedIcon';
  import GithubLogoIcon from 'phosphor-svelte/lib/GithubLogoIcon';
  import PencilSimpleIcon from 'phosphor-svelte/lib/PencilSimpleIcon';
  import PlusIcon from 'phosphor-svelte/lib/PlusIcon';
  import TrashIcon from 'phosphor-svelte/lib/TrashIcon';
  import WarningIcon from 'phosphor-svelte/lib/WarningIcon';
  import XIcon from 'phosphor-svelte/lib/XIcon';
  import UsageDashboard from '@subset/usage/view';
  import ProviderIcon from '@subset/usage/provider-icon';
  import BrandMark from './BrandMark.svelte';
  import { createUsageStatus, isUsageStatus, type UsageAccount, type UsageProvider, type UsageStatus } from '@subset/usage';
  import { emptyUsageHistory, isUsageHistory, type UsageHistory } from '@subset/usage/history';
  import { accountBadge, accountName, agoText, providerMeta, type PercentMode, type SortMode } from '@subset/usage/present';

  type ConnectedProfile = {
    id: string; label: string; provider: UsageProvider; managed: boolean; current: boolean; collectCommand?: string;
    claudeConfigDir?: string; defaultClaude?: boolean; claudeSettingsFile?: string; claudeLaunchCommand?: string;
    factoryHome?: string; apiKeyConfigured?: boolean; factoryLaunchCommand?: string;
    collector?: {
      state: 'installed' | 'not-installed' | 'replaced' | 'other-account' | 'missing-directory' | 'unreadable' | 'manual'; settingsFile: string | null; chained: boolean; existing?: boolean; otherAccount?: string;
      lastRun?: { at: string; result: 'saved' | 'no-quota' | 'wrong-directory' } | null; installedAt?: string | null;
    };
  };
  type Connection = { id: string; authUrl: string | null; state: string; error?: string | null };

  const embedded = new URLSearchParams(window.location.search).get('embedded') === '1';
  // usage.subset.dev is not deployed yet; per AGENTS.md it stays plain text until the site works.
  const USAGE_SITE_LIVE = false;
  const providers: Array<{ id: UsageProvider; title: string; detail: string }> = [
    { id: 'codex-chatgpt', title: 'ChatGPT', detail: 'ChatGPT plan usage, signed in through the Codex CLI' },
    { id: 'claude-code', title: 'Claude', detail: 'Claude plan usage through the Claude Code CLI' },
    { id: 'antigravity', title: 'Antigravity', detail: 'Quota from the Antigravity CLI status line' },
    { id: 'cursor-local', title: 'Cursor', detail: 'Plan usage and credits from the Cursor app sign-in' },
    { id: 'cursor', title: 'Cursor team', detail: 'Spending from the team Admin API' },
    { id: 'factory-droid', title: 'Factory Droid', detail: 'Rate limits from a local sign-in or API key' },
    { id: 'amp', title: 'Amp', detail: 'Credit balance from amp usage' },
    { id: 'devin', title: 'Devin', detail: 'Daily and weekly quota from a local sign-in or API key' },
    { id: 'pi', title: 'Pi', detail: 'ChatGPT or Claude login stored by Pi' },
    { id: 'opencode', title: 'OpenCode', detail: 'ChatGPT, Claude, or OpenCode Go login stored by OpenCode' },
    { id: 'omp', title: 'omp', detail: 'ChatGPT or Claude logins stored by omp' },
    { id: 'hermes', title: 'Hermes', detail: 'ChatGPT or Claude login stored by Hermes Agent' },
  ];
  const refreshChoices = [0, 5, 15, 30];

  let status = $state<UsageStatus>(createUsageStatus([]));
  let usageHistory = $state<UsageHistory>(emptyUsageHistory());
  let installing = $state<string | null>(null);
  let installNow = $state(true);
  let busy = $state(false);
  let statusError = $state('');
  let profiles = $state<ConnectedProfile[]>([]);
  let connection = $state<Connection | null>(null);
  let recoveringConnection = $state(!embedded);
  let actionBusy = $state(false);
  let toast = $state<{ text: string; tone: 'ok' | 'error' } | null>(null);
  let autoRefresh = $state(readNumber('subset.usage.autoRefresh', 5, refreshChoices));
  let percentMode = $state<PercentMode>(readMode());
  type Theme = 'system' | 'light' | 'dark';
  let theme = $state<Theme>(readTheme());
  let page = $state<'usage' | 'settings'>(location.hash === '#settings' ? 'settings' : 'usage');

  let addDialog = $state<HTMLDialogElement>();
  let accountDialog = $state<HTMLDialogElement>();
  let newProvider = $state<UsageProvider>('codex-chatgpt');
  let newLabel = $state('');
  let showTrends = $state(readFlag('subset.usage.showTrends', true));
  let showCredits = $state(readFlag('subset.usage.showCredits', true));
  let pinned = $state<string[]>(readList('subset.usage.pinned'));
  let sortMode = $state<SortMode>(readSort());
  let credentialEnv = $state('CURSOR_TEAM_ADMIN_KEY');
  let cursorUserId = $state('');
  let claudeConfigDir = $state('');
  let factoryHome = $state('');
  let factoryKeyEnv = $state('');
  let localCredentials = $state(false);
  // Null until the server answers; false shows the first-run local sign-ins question.
  let localCredentialsChosen = $state<boolean | null>(null);
  let loaded = $state(false);
  type Harness = 'pi' | 'opencode' | 'omp' | 'hermes';
  type StoredOption = { kind: string; entryId?: string; email?: string };
  const harnesses: Harness[] = ['pi', 'opencode', 'omp', 'hermes'];
  const isHarness = (provider: string): provider is Harness => (harnesses as string[]).includes(provider);
  let storedLogins = $state<Record<Harness, StoredOption[]>>({ pi: [], opencode: [], omp: [], hermes: [] });
  // A radio value of `kind` or `kind:entryId` (omp keeps several logins of one kind).
  const optionValue = (option: StoredOption) => option.entryId ? `${option.kind}:${option.entryId}` : option.kind;
  let storedLogin = $state('');
  const loginNames: Record<string, string> = { chatgpt: 'ChatGPT', claude: 'Claude', 'opencode-go': 'OpenCode Go' };
  let savingLocal = $state(false);
  let formError = $state('');
  let selectedId = $state<string | null>(null);
  let confirmingRemove = $state(false);
  let renaming = $state(false);
  let renameValue = $state('');

  const selectedProfile = $derived(profiles.find((profile) => profile.id === selectedId) ?? null);
  const selectedAccount = $derived(status.accounts.find((account) => account.id === selectedId) ?? null);
  const signInActive = $derived(!!connection && ['starting', 'pending', 'validating'].includes(connection.state));
  const statusLineJson = (command: string) => JSON.stringify({ statusLine: { type: 'command', command } }, null, 2);
  const wrapperScript = (command: string) => `#!/bin/sh\n# Sends the same status-line JSON to Subset and to your existing status line.\ninput=$(cat)\nprintf '%s' "$input" | ${command} >/dev/null 2>&1\nprintf '%s' "$input" | /path/to/your/existing-statusline`;

  // Display preferences are per-viewer conveniences, so browser storage is enough.
  function readNumber(key: string, fallback: number, allowed: number[]): number {
    try { const value = Number(localStorage.getItem(key) ?? fallback); return allowed.includes(value) ? value : fallback; }
    catch { return fallback; }
  }
  function readList(key: string): string[] {
    try { const value = JSON.parse(localStorage.getItem(key) ?? '[]'); return Array.isArray(value) ? value.filter((item) => typeof item === 'string').slice(-50) : []; }
    catch { return []; }
  }
  function readSort(): SortMode {
    try { const value = localStorage.getItem('subset.usage.sort'); return value === 'recent' || value === 'expiring' ? value : 'default'; }
    catch { return 'default'; }
  }
  function togglePin(id: string) {
    // At most 50 pins, like the stored list; a new pin replaces the oldest.
    pinned = pinned.includes(id) ? pinned.filter((item) => item !== id) : [...pinned.slice(-49), id];
    savePreference('subset.usage.pinned', JSON.stringify(pinned));
  }
  function setSortMode(mode: SortMode) { sortMode = mode; savePreference('subset.usage.sort', mode); }
  function readFlag(key: string, fallback: boolean): boolean {
    try { const value = localStorage.getItem(key); return value === null ? fallback : value === 'true'; }
    catch { return fallback; }
  }
  function setShowTrends(value: boolean) { showTrends = value; savePreference('subset.usage.showTrends', String(value)); }
  function setShowCredits(value: boolean) { showCredits = value; savePreference('subset.usage.showCredits', String(value)); }
  /** Name shown for a configured account: its own name, else the email it reports, else the provider. */
  function nameOf(profile: ConnectedProfile) {
    const account = status.accounts.find((item) => item.id === profile.id);
    return accountName({ label: profile.label, email: account?.email ?? null, provider: profile.provider });
  }
  const accountTag = (account: UsageAccount) => {
    const profile = profiles.find((item) => item.id === account.id);
    return profile?.current || profile?.defaultClaude ? 'Default' : null;
  };
  function readMode(): PercentMode {
    try { return localStorage.getItem('subset.usage.percentMode') === 'remaining' ? 'remaining' : 'used'; }
    catch { return 'used'; }
  }
  function savePreference(key: string, value: string | number) { try { localStorage.setItem(key, String(value)); } catch { /* per-viewer convenience only */ } }
  function readTheme(): Theme {
    try { const value = localStorage.getItem('subset.usage.theme'); return value === 'light' || value === 'dark' ? value : 'system'; }
    catch { return 'system'; }
  }
  function setTheme(value: Theme) { theme = value; savePreference('subset.usage.theme', value); }
  $effect(() => {
    const root = document.documentElement;
    if (theme === 'system') delete root.dataset.theme; else root.dataset.theme = theme;
  });
  function setAutoRefresh(value: number) { autoRefresh = value; savePreference('subset.usage.autoRefresh', value); }
  function setPercentMode(value: PercentMode) { percentMode = value; savePreference('subset.usage.percentMode', value); }
  function go(next: 'usage' | 'settings') {
    page = next;
    history.replaceState(null, '', next === 'settings' ? '#settings' : location.pathname + location.search);
  }

  let toastTimer: ReturnType<typeof setTimeout> | undefined;
  function notify(text: string, tone: 'ok' | 'error' = 'ok') {
    toast = { text, tone };
    clearTimeout(toastTimer);
    if (tone === 'ok') toastTimer = setTimeout(() => { toast = null; }, 4000);
  }
  const message = (cause: unknown, fallback: string) => cause instanceof Error ? cause.message : fallback;

  async function api(path: string, method = 'GET', body?: object) {
    const response = await fetch(path, {
      method, cache: 'no-store',
      // The server refuses API calls without this header, which other sites cannot send.
      headers: { 'X-Subset-Request': '1', ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    // Rejected requests (403/404/405) have empty bodies.
    const data = await response.json().catch(() => null);
    if (!response.ok || data === null) throw new Error(data?.error ?? 'Account service is unavailable.');
    return data;
  }

  async function loadProfiles() {
    try { profiles = (await api('/api/profiles')).profiles; }
    catch { notify('Could not load connected accounts.', 'error'); }
  }

  // A refresh requested while one runs (for example after a settings change) runs once more
  // afterwards, so callers always see results that reflect their change.
  let running: Promise<void> | null = null;
  let queued: Promise<void> | null = null;
  function refresh(): Promise<void> {
    if (running) {
      queued ??= running.then(() => { queued = null; return refresh(); });
      return queued;
    }
    running = readStatus().finally(() => { running = null; });
    return running;
  }

  async function readStatus() {
    busy = true;
    try {
      const response = await fetch('/api/status', { cache: 'no-store', headers: { 'X-Subset-Request': '1' } });
      if (!response.ok) throw new Error('Status service is unavailable.');
      const data = await response.json();
      if (!isUsageStatus(data)) throw new Error('Status response is invalid.');
      status = data;
      loaded = true;
      statusError = '';
      void loadHistory();
    } catch (cause) { statusError = message(cause, 'Status service is unavailable.'); }
    finally { busy = false; }
  }

  async function loadHistory() {
    try {
      const data = await api('/api/history');
      if (isUsageHistory(data)) usageHistory = data;
    } catch { /* trends are optional */ }
  }

  const automatable = (profile: ConnectedProfile | undefined) => !!profile?.collector && ['not-installed', 'replaced'].includes(profile.collector.state);

  async function installCollector(id: string, quiet = false) {
    installing = id; formError = '';
    try {
      await api(`/api/profiles/${id}/collector`, 'POST');
      await loadProfiles();
      if (!quiet) notify('Collector installed. Quota appears after the next response in a CLI session.');
    } catch (cause) {
      if (quiet) throw cause;
      const text = message(cause, 'Could not install the collector.');
      if (accountDialog?.open) formError = text; else notify(text, 'error');
    } finally { installing = null; }
  }

  async function uninstallCollector(id: string) {
    installing = id; formError = '';
    try {
      await api(`/api/profiles/${id}/collector`, 'DELETE');
      await loadProfiles();
      notify('Collector removed. The previous status line was restored.');
    } catch (cause) { formError = message(cause, 'Could not remove the collector.'); }
    finally { installing = null; }
  }

  async function loadPreferences() {
    try {
      const preferences = await api('/api/preferences');
      localCredentials = preferences.localCredentials === true;
      localCredentialsChosen = preferences.localCredentialsChosen === true;
    } catch { /* keeps the default, off */ }
  }

  async function setLocalCredentials(value: boolean) {
    savingLocal = true;
    try {
      const preferences = await api('/api/preferences', 'PUT', { localCredentials: value });
      localCredentials = preferences.localCredentials === true;
      localCredentialsChosen = preferences.localCredentialsChosen === true;
      notify(value ? 'Local sign-ins turned on. Refreshing…' : 'Local sign-ins turned off.');
      await refresh();
    } catch (cause) { notify(message(cause, 'Could not save this setting.'), 'error'); }
    finally { savingLocal = false; }
  }

  async function clearHistory() {
    try { await api('/api/history', 'DELETE'); usageHistory = emptyUsageHistory(); notify('Usage history cleared.'); }
    catch (cause) { notify(message(cause, 'Could not clear usage history.'), 'error'); }
  }

  /** Explains why a snapshot account has no quota yet, using the collector's last recorded run. */
  function accountHint(account: UsageAccount) {
    const profile = profiles.find((item) => item.id === account.id);
    const collector = profile?.collector;
    if (!profile || !collector) return null;
    const cli = providerMeta[profile.provider].name;
    const settings = { label: 'Settings', run: () => void openAccount(account.id) };
    if (automatable(profile)) {
      return { message: collector.state === 'replaced' ? `Another tool replaced this account's collector in ${cli} settings.` : `Install the collector so ${cli} can report this account's quota.`,
        action: { label: installing === account.id ? 'Installing…' : collector.state === 'replaced' ? 'Reinstall' : 'Install collector', run: () => void installCollector(account.id), busy: installing === account.id } };
    }
    if (collector.state === 'other-account') {
      const other = profiles.find((item) => item.id === collector.otherAccount);
      return { message: `${cli} has one status line, and ${other ? nameOf(other) || 'another account' : 'another account'} collects through it. Only one ${cli} account can collect at a time.`, action: settings };
    }
    if (collector.state === 'installed') {
      const run = collector.lastRun;
      if (!run) return { message: `Collector installed${collector.installedAt ? ` ${agoText(collector.installedAt, Date.now())}` : ''} but hasn't run yet. Restart ${cli} sessions opened before that, then send a message.` };
      if (run.result === 'wrong-directory') return { message: `The collector ran ${agoText(run.at, Date.now())} from a different config directory and was ignored.`, action: settings };
      if (run.result === 'no-quota') return { message: `The collector ran ${agoText(run.at, Date.now())}, but ${cli} sent no subscription quota${profile.provider === 'claude-code' ? '. Claude Code sends it for Pro and Max plans after a response' : ''}.` };
      return null;
    }
    return { message: collector.state === 'missing-directory' ? `${cli} settings were not found for this account.` : 'Set up the collector to read this account\'s quota.', action: settings };
  }

  async function reloadAll() { await Promise.all([loadProfiles(), refresh()]); }

  async function recoverConnection(expectedId?: string) {
    try {
      const recovered = (await api('/api/connections/active')).connection;
      if (!expectedId || connection?.id === expectedId) connection = recovered;
    } catch { notify('Could not recover sign-in progress. Reload to retry before starting another sign-in.', 'error'); }
    finally { recoveringConnection = false; }
  }

  async function pollConnection() {
    if (!connection || !['starting', 'pending', 'validating'].includes(connection.state)) return;
    const id = connection.id;
    try {
      const next = await api(`/api/connections/${id}`);
      if (connection?.id !== id) return;
      connection = { ...connection, ...next };
      if (next.state === 'pending' && !connection?.authUrl) await recoverConnection(id);
      if (next.state === 'connected') { connection = null; await reloadAll(); notify('ChatGPT account connected.'); }
      if (next.state === 'cancelled') connection = null;
    } catch (cause) {
      // The server keeps sign-ins in memory only, so a restart forgets them.
      if (message(cause, '') === 'Sign-in was not found.') {
        if (connection?.id === id) connection = null;
        notify('The sign-in was interrupted because the usage server restarted. Start it again.', 'error');
      } else notify('Could not check sign-in progress.', 'error');
    }
  }

  async function run(action: () => Promise<void>, fallback: string) {
    actionBusy = true; formError = '';
    try { await action(); }
    catch (cause) { formError = message(cause, fallback); }
    finally { actionBusy = false; }
  }

  // A retry of the same reset reuses its idempotency key until a response arrives, so a reset
  // that succeeded but whose response was lost is never spent twice.
  const resetKeys = new Map<string, { key: string; at: number }>();
  async function redeemReset(accountId: string): Promise<string> {
    const pending = resetKeys.get(accountId);
    const key = pending && Date.now() - pending.at < 10 * 60_000 ? pending.key : crypto.randomUUID();
    resetKeys.set(accountId, { key, at: pending?.key === key ? pending.at : Date.now() });
    const { outcome } = await api(`/api/profiles/${accountId}/reset`, 'POST', { idempotencyKey: key });
    resetKeys.delete(accountId);
    await refresh();
    return ({ reset: 'Reset used. The ChatGPT usage windows were cleared.', nothingToReset: 'Nothing to reset right now; no reset was used.', noCredit: 'No banked resets are available.', alreadyRedeemed: 'This reset was already used.' } as Record<string, string>)[outcome] ?? 'ChatGPT responded to the reset.';
  }

  /** Closes a modal dialog when its backdrop, not its content, is clicked. */
  const closeOnBackdrop = (dialog: HTMLDialogElement | undefined) => (event: MouseEvent) => { if (event.target === dialog) dialog?.close(); };

  function openAdd() {
    void api('/api/stored-logins').then((value) => { storedLogins = value; }).catch(() => {});
    formError = ''; newLabel = ''; cursorUserId = ''; claudeConfigDir = ''; factoryHome = ''; factoryKeyEnv = ''; storedLogin = ''; installNow = true;
    addDialog?.showModal();
  }

  const quickAdd = (path: string, done: string) => run(async () => {
    await api(path, 'POST');
    await reloadAll();
    addDialog?.close();
    notify(done);
  }, 'Could not add this account.');

  const submitAdd = () => run(async () => {
    if (newProvider === 'codex-chatgpt') {
      connection = await api('/api/connections', 'POST', { label: newLabel });
      addDialog?.close();
      return;
    }
    const added = await api('/api/profiles', 'POST', {
      provider: newProvider, label: newLabel,
      ...(newProvider === 'cursor' ? { credentialEnv, cursorUserId } : {}),
      ...(newProvider === 'claude-code' && claudeConfigDir.trim() ? { claudeConfigDir: claudeConfigDir.trim() } : {}),
      ...(newProvider === 'factory-droid' ? { ...(factoryHome.trim() ? { factoryHome: factoryHome.trim() } : {}), ...(factoryKeyEnv.trim() ? { credentialEnv: factoryKeyEnv.trim() } : {}) } : {}),
      ...((newProvider === 'amp' || newProvider === 'devin') && factoryKeyEnv.trim() ? { credentialEnv: factoryKeyEnv.trim() } : {}),
      ...(isHarness(newProvider) ? { login: storedLogin.split(':')[0], ...(storedLogin.includes(':') ? { entryId: storedLogin.split(':')[1] } : {}) } : {}),
    });
    await reloadAll();
    addDialog?.close();
    if (newProvider === 'cursor') { notify('Cursor team account added. The server reads its key from the named environment variable.'); return; }
    if (['factory-droid', 'amp', 'devin', 'cursor-local', ...harnesses].includes(newProvider)) { notify(`${providerMeta[newProvider].name} account added.`); return; }
    const canInstall = newProvider === 'antigravity' || !!claudeConfigDir.trim();
    if (installNow && canInstall) {
      try { await installCollector(added.id, true); notify(`${newLabel.trim() || 'Account'} added and its collector installed.`); return; }
      catch (cause) { notify(`Account added, but the collector was not installed: ${message(cause, 'unknown error')}`, 'error'); }
    }
    await openAccount(added.id);
  }, 'Could not add this account.');

  async function cancelConnection() {
    if (!connection) return;
    try { await api(`/api/connections/${connection.id}/cancel`, 'POST'); connection = null; notify('Sign-in cancelled.'); }
    catch (cause) { notify(message(cause, 'Could not cancel sign-in.'), 'error'); }
  }

  async function openAccount(id: string) {
    selectedId = id; confirmingRemove = false; formError = '';
    await tick();
    if (!accountDialog?.open) accountDialog?.showModal();
  }

  const saveName = () => run(async () => {
    if (!selectedProfile) return;
    await api(`/api/profiles/${selectedProfile.id}`, 'PATCH', { label: renameValue.trim() });
    renaming = false;
    await reloadAll();
    notify(renameValue.trim() ? 'Account renamed.' : 'Name cleared; the card shows the account email.');
  }, 'Could not rename this account.');

  const removeSelected = () => run(async () => {
    if (!selectedProfile) return;
    const label = nameOf(selectedProfile);
    await api(`/api/profiles/${selectedProfile.id}`, 'DELETE', { confirmation: selectedProfile.id });
    accountDialog?.close();
    await reloadAll();
    notify(`${label} removed.`);
  }, 'Could not remove this account.');

  async function copy(text: string) {
    try { await navigator.clipboard.writeText(text); notify('Copied to clipboard.'); }
    catch { notify('Clipboard access is unavailable. Select the text to copy it.', 'error'); }
  }

  function removalDetail(profile: ConnectedProfile) {
    if (profile.provider === 'codex-chatgpt') return profile.managed ? 'Its Subset-managed ChatGPT sign-in will be deleted from this computer.' : 'Its existing ChatGPT sign-in stays on this computer.';
    if (profile.provider === 'cursor') return 'The environment credential is not changed.';
    return `Its collected snapshot is deleted and an installed collector is removed from the CLI settings, restoring the previous status line. The upstream sign-in is not changed.${profile.defaultClaude ? ' The default Claude Code account will no longer be added automatically.' : ''}`;
  }

  onMount(() => {
    if (embedded) {
      const parentOrigin = (() => { try { return new URL(document.referrer).origin; } catch { return ''; } })();
      if (!/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(parentOrigin)) return;
      const receive = (event: MessageEvent) => {
        if (event.source !== window.parent || event.origin !== parentOrigin) return;
        const data = event.data;
        if (data?.viewId !== 'subset.usage.dashboard@1') return;
        if (!isUsageStatus(data?.status)) { statusError = 'The host sent invalid usage status. The last valid observation is retained.'; return; }
        status = data.status;
        statusError = '';
      };
      window.addEventListener('message', receive);
      return () => window.removeEventListener('message', receive);
    }
    void reloadAll();
    void loadPreferences();
    void recoverConnection();
    const poller = window.setInterval(pollConnection, 2000);
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (event.key !== 'r' || event.metaKey || event.ctrlKey || event.altKey || target?.closest('input, textarea, select, dialog')) return;
      event.preventDefault();
      void refresh();
    };
    window.addEventListener('keydown', onKey);
    return () => { window.clearInterval(poller); window.removeEventListener('keydown', onKey); };
  });

  $effect(() => {
    if (embedded || !autoRefresh) return;
    // Reading autoRefresh here re-arms the timer when the setting changes.
    const timer = window.setInterval(() => { if (!document.hidden) void refresh(); }, autoRefresh * 60_000);
    return () => window.clearInterval(timer);
  });
</script>

<svelte:head><meta name="theme-color" content="#f5f4f0" media="(prefers-color-scheme: light)" /><meta name="theme-color" content="#141414" media="(prefers-color-scheme: dark)" /></svelte:head>


{#snippet notice()}
  {#if localCredentialsChosen === false}
    <div class="banner" role="region" aria-label="Local sign-ins">
      <div>
        <strong>Read the sign-ins already on this computer?</strong>
        <p>Subset can show live usage from the logins Claude, Factory Droid, Cursor, Devin, Pi, OpenCode, omp, and Hermes keep locally, and the Antigravity account email. Tokens are read, never changed, and sent only to the usage endpoints those tools use. Their makers do not document these endpoints, so they may change or stop working. You can change this in Settings.</p>
      </div>
      <div class="banner-actions">
        <button type="button" class="btn primary" disabled={savingLocal} onclick={() => setLocalCredentials(true)}>Use local sign-ins</button>
        <button type="button" class="btn" disabled={savingLocal} onclick={() => setLocalCredentials(false)}>Not now</button>
      </div>
    </div>
  {/if}
  {#if statusError}<div class="banner error" role="alert"><p>{statusError}</p><button type="button" class="btn" onclick={refresh}>Retry</button></div>{/if}
  {#if connection}
    <div class="banner" class:error={connection.state === 'error'} role="status">
      <div>
        <strong>{connection.state === 'error' ? 'Sign-in failed' : connection.state === 'validating' ? 'Finishing sign-in…' : connection.state === 'starting' ? 'Preparing ChatGPT sign-in…' : 'Waiting for ChatGPT sign-in'}</strong>
        <p>{connection.state === 'error' ? connection.error ?? 'Try again.' : 'Sign in with the ChatGPT account you want to add. This page updates when the sign-in completes.'}</p>
      </div>
      <div class="banner-actions">
        {#if connection.state === 'pending' && connection.authUrl}<a class="btn primary" href={connection.authUrl} target="_blank" rel="noopener noreferrer">Continue with ChatGPT <ArrowSquareOutIcon size={15} weight="bold" /></a>{/if}
        {#if ['starting', 'pending'].includes(connection.state)}<button type="button" class="btn" onclick={cancelConnection}>Cancel</button>{/if}
        {#if connection.state === 'error'}<button type="button" class="btn" onclick={() => { connection = null; }}>Dismiss</button>{/if}
      </div>
    </div>
  {/if}
{/snippet}

{#snippet emptyAction()}
  <button type="button" class="btn primary" onclick={openAdd} disabled={signInActive || recoveringConnection}>Add your first account</button>
{/snippet}

<main>
  {#if embedded}
    <UsageDashboard {status} notice={statusError ? notice : undefined} />
  {:else}
    <div class="appbar-wrap">
    <header class="appbar">
      <div class="brand">
        <BrandMark size={26} />
        <span class="name">Usage</span>
        {#if loaded}<span class="count" aria-label={`${status.accounts.length} accounts`}>{status.accounts.length}</span>{/if}
      </div>
      <nav class="tabs" aria-label="Sections">
        <button type="button" aria-current={page === 'usage' ? 'page' : undefined} onclick={() => go('usage')}><ChartBarIcon size={15} weight="bold" />Dashboard</button>
        <button type="button" aria-current={page === 'settings' ? 'page' : undefined} onclick={() => go('settings')}><GearSixIcon size={15} weight="bold" />Settings</button>
      </nav>
      <div class="bar-actions">
        {#if loaded}<span class="synced" title={new Date(status.generatedAt).toLocaleString()}>Refreshed {new Date(status.generatedAt).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}</span>{/if}
        <button type="button" class="btn icon-only" onclick={refresh} disabled={busy} aria-keyshortcuts="r" aria-label={busy ? 'Checking usage' : 'Refresh usage'} title="Refresh (R)"><span class:spin={busy} class="i"><ArrowClockwiseIcon size={16} weight="bold" /></span></button>
        <button type="button" class="btn primary" onclick={openAdd} disabled={signInActive || recoveringConnection}><PlusIcon size={15} weight="bold" />Add account</button>
      </div>
    </header>
    </div>
    {#if page === 'usage'}
      <UsageDashboard {status} {busy} header={false} loading={!loaded && !statusError} {redeemReset} {percentMode} {openAccount} {notice} {emptyAction} history={usageHistory} {accountHint} {accountTag} {showTrends} {pinned} {togglePin} {sortMode} {setSortMode} {setShowTrends} {showCredits} {setShowCredits} />
    {:else}
      <section class="settings" aria-labelledby="settings-title">
        <h1 id="settings-title">Settings</h1>
        <div class="panel">
          <div class="row">
            <div><h2>Percentage display</h2><p>Show how much of each limit is used or how much is left.</p></div>
            <div class="segmented" role="radiogroup" aria-label="Percentage display">
              {#each [['used', 'Used'], ['remaining', 'Remaining']] as [value, label] (value)}
                <button type="button" role="radio" aria-checked={percentMode === value} onclick={() => setPercentMode(value as PercentMode)}>{label}</button>
              {/each}
            </div>
          </div>
          <div class="row">
            <div><h2>Theme</h2><p>Follow the system appearance or always use light or dark.</p></div>
            <div class="segmented" role="radiogroup" aria-label="Theme">
              {#each [['system', 'System'], ['light', 'Light'], ['dark', 'Dark']] as [value, label] (value)}
                <button type="button" role="radio" aria-checked={theme === value} onclick={() => setTheme(value as Theme)}>{label}</button>
              {/each}
            </div>
          </div>
          <div class="row">
            <div><h2>Trend charts</h2><p>Show each account's usage over the last days on the dashboard once enough history exists.</p></div>
            <button type="button" role="switch" class="switch" aria-checked={showTrends} aria-label="Show trend charts" onclick={() => setShowTrends(!showTrends)}><span></span></button>
          </div>
          <div class="row">
            <div><h2>Credits and extra usage</h2><p>Show paid credits, extra usage, spending, and balances at the bottom of each card when a provider reports them.</p></div>
            <button type="button" role="switch" class="switch" aria-checked={showCredits} aria-label="Show credits and extra usage" onclick={() => setShowCredits(!showCredits)}><span></span></button>
          </div>
          <div class="row">
            <div><h2>Auto-refresh</h2><p>Reads every account on an interval while this tab is visible. ChatGPT, Cursor, and Factory Droid are read live. Claude is read live with local sign-ins on; otherwise it and Antigravity reload their last collected snapshot.</p></div>
            <div class="segmented" role="radiogroup" aria-label="Auto-refresh interval">
              {#each refreshChoices as minutes (minutes)}
                <button type="button" role="radio" aria-checked={autoRefresh === minutes} onclick={() => setAutoRefresh(minutes)}>{minutes ? `${minutes} min` : 'Off'}</button>
              {/each}
            </div>
          </div>
        </div>

        <div class="panel">
          <div class="panel-head"><h2>Accounts</h2><button type="button" class="btn small primary" onclick={openAdd} disabled={signInActive || recoveringConnection}><PlusIcon size={14} weight="bold" />Add</button></div>
          {#each profiles as profile (profile.id)}
            {@const account = status.accounts.find((item) => item.id === profile.id)}
            <div class="account-row">
              <ProviderIcon provider={profile.provider} size={32} />
              <div class="account-text">
                <strong>{nameOf(profile)}{#if profile.current || profile.defaultClaude}<span class="tag">Default</span>{/if}</strong>
                <span>{providerMeta[profile.provider].name}{account?.email && account.email !== nameOf(profile) ? ` · ${account.email}` : ''}{profile.collector ? ` · Collector ${profile.collector.state === 'installed' ? 'installed' : profile.collector.state === 'manual' ? 'set up manually' : 'not installed'}` : ''}</span>
              </div>
              <button type="button" class="btn small" onclick={() => openAccount(profile.id)}>Manage</button>
            </div>
          {:else}
            <p class="hint">No accounts yet.</p>
          {/each}
        </div>

        <div class="panel">
          <div class="row">
            <div>
              <h2>Use local sign-ins</h2>
              <p>Reads the sign-ins Claude, Factory Droid, the Cursor app, Devin, Pi, OpenCode, omp, and Hermes already store on this computer, and the Antigravity account email, to show live usage without a collector or API key. Subset reads the stored tokens without changing or refreshing them, and calls the usage endpoints those tools use, which their makers do not document and may change. macOS may ask to allow keychain access; choose Always Allow. ChatGPT accounts use the Codex CLI's own app-server either way.</p>
            </div>
            <button type="button" role="switch" class="switch" aria-checked={localCredentials} aria-label="Use local sign-ins" disabled={savingLocal} onclick={() => setLocalCredentials(!localCredentials)}><span></span></button>
          </div>
        </div>

        <div class="panel">
          <div class="row">
            <div><h2>Usage history</h2><p>Trend charts use up to eight days of times and percentages stored only on this computer. Labels, emails, and provider data are not kept in history.</p></div>
            <button type="button" class="btn small" onclick={clearHistory}>Clear history</button>
          </div>
          <div class="row">
            <div><h2>Keyboard</h2><p>Press <kbd>R</kbd> on the Usage page to refresh.</p></div>
          </div>
        </div>
      </section>
    {/if}
    <footer class="site-footer">
      <span>Built at <a href="https://21n.co" target="_blank" rel="noopener noreferrer">21n.co</a></span>
      <span class="dot" aria-hidden="true">·</span>
      {#if USAGE_SITE_LIVE}<a href="https://usage.subset.dev" target="_blank" rel="noopener noreferrer">usage.subset.dev</a>{:else}<span title="Not live yet">usage.subset.dev</span>{/if}
      <span class="dot" aria-hidden="true">·</span>
      <a href="https://github.com/21nCo/subset" target="_blank" rel="noopener noreferrer" class="star"><GithubLogoIcon size={15} weight="fill" />Star on GitHub</a>
    </footer>
  {/if}
</main>

{#if !embedded}
  <dialog bind:this={addDialog} aria-labelledby="add-title" onclose={() => { formError = ''; }} onclick={closeOnBackdrop(addDialog)}>
    <form method="dialog" class="sheet" onsubmit={(event) => { event.preventDefault(); void submitAdd(); }}>
      <header>
        <h2 id="add-title">Add account</h2>
        <button type="button" class="close" onclick={() => addDialog?.close()} aria-label="Close"><XIcon size={18} weight="bold" /></button>
      </header>
      {#if !profiles.some((profile) => profile.current) || !profiles.some((profile) => profile.defaultClaude)}
        <div class="quick">
          <p class="label">Already signed in on this computer</p>
          {#if !profiles.some((profile) => profile.current)}<button type="button" class="btn" disabled={actionBusy} onclick={() => quickAdd('/api/profiles/current', 'Current ChatGPT account added.')}>Use current ChatGPT sign-in</button>{/if}
          {#if !profiles.some((profile) => profile.defaultClaude)}<button type="button" class="btn" disabled={actionBusy} onclick={() => quickAdd('/api/profiles/claude-default', 'Default Claude account added.')}>Use default Claude sign-in</button>{/if}
        </div>
      {/if}
      <fieldset class="providers">
        <legend class="label">Provider</legend>
        {#each providers as provider (provider.id)}
          <label class="provider" class:selected={newProvider === provider.id}>
            <input type="radio" name="provider" value={provider.id} bind:group={newProvider} onchange={() => { storedLogin = ''; }} />
            <ProviderIcon provider={provider.id} size={34} />
            <span><strong>{provider.title}</strong><small>{provider.detail}</small></span>
          </label>
        {/each}
      </fieldset>
      <label class="field">
        <span class="label">Account name <em>optional</em></span>
        <input bind:value={newLabel} maxlength="80" placeholder="Uses the account's email when empty" />
      </label>
      {#if newProvider === 'claude-code'}
        <label class="field">
          <span class="label">Config directory <em>optional</em></span>
          <input bind:value={claudeConfigDir} maxlength="1024" placeholder="~/.claude-work" aria-describedby="claude-help" />
          <small id="claude-help">Each Claude Code account lives in its own <code>CLAUDE_CONFIG_DIR</code>. When set, only snapshots from that directory are accepted.</small>
        </label>
        {#if claudeConfigDir.trim()}
          <label class="check"><input type="checkbox" bind:checked={installNow} /> <span>Install the collector in this directory's <code>settings.json</code>. Your existing status line keeps working.</span></label>
        {/if}
      {:else if newProvider === 'cursor-local'}
        <p class="hint">{localCredentials ? 'Reads the account signed in to the Cursor app on this computer.' : 'Turn on local sign-ins in Settings to read the Cursor app sign-in.'} For team spending across members, use Cursor team instead.</p>
      {:else if newProvider === 'amp' || newProvider === 'devin'}
        <label class="field">
          <span class="label">API key environment variable <em>{newProvider === 'amp' || localCredentials ? 'optional' : 'required while local sign-ins are off'}</em></span>
          <input bind:value={factoryKeyEnv} maxlength="128" pattern="[A-Za-z_][A-Za-z0-9_]*" placeholder={newProvider === 'amp' ? 'AMP_WORK_API_KEY' : 'DEVIN_WORK_API_KEY'} aria-describedby="tool-help" />
          <small id="tool-help">{newProvider === 'amp' ? 'Leave empty to use the account amp is signed in to. For another saved account, set its Amp API key in the usage server environment and enter the variable name.' : localCredentials ? 'Leave empty to use the key stored by devin auth login. For another account, enter the name of a variable holding its key.' : 'Local sign-ins are off, so enter the name of a variable holding a Devin API key.'}</small>
        </label>
      {:else if isHarness(newProvider)}
        <fieldset class="field logins">
          <legend class="label">Stored login</legend>
          {#if !localCredentials}<p class="hint">Turn on local sign-ins in Settings to read logins stored by {providerMeta[newProvider].name}.</p>{/if}
          {#each storedLogins[newProvider] as option (optionValue(option))}
            <label class="check"><input type="radio" name="stored-login" value={optionValue(option)} bind:group={storedLogin} /> <span>{loginNames[option.kind] ?? option.kind}{option.email ? ` · ${option.email}` : ''}</span></label>
          {:else}
            <p class="hint">{providerMeta[newProvider].name} has no ChatGPT, Claude{newProvider === 'opencode' ? ', or OpenCode Go' : ''} login stored on this computer. Sign in from {providerMeta[newProvider].name} first.</p>
          {/each}
          <small>The quota shown is the subscription that login belongs to, read with the token {providerMeta[newProvider].name} keeps. {providerMeta[newProvider].name} refreshes it; Subset never does.</small>
        </fieldset>
      {:else if newProvider === 'factory-droid'}
        <label class="field">
          <span class="label">Factory home <em>optional</em></span>
          <input bind:value={factoryHome} maxlength="1024" placeholder="~ (default) or ~/.droid-work" aria-describedby="factory-help" />
        </label>
        <label class="field">
          <span class="label">API key environment variable <em>{localCredentials ? 'optional' : 'required while local sign-ins are off'}</em></span>
          <input bind:value={factoryKeyEnv} maxlength="128" pattern="[A-Za-z_][A-Za-z0-9_]*" placeholder="FACTORY_WORK_API_KEY" aria-describedby="factory-help" />
          <small id="factory-help">{localCredentials ? 'Leave empty to read the Droid sign-in in this Factory home; a key variable, if entered, is used instead. ' : 'Local sign-ins are off, so Subset needs a Factory API key: set it in the usage server environment and enter only the variable name. '}Use a separate Factory home per account, started with <code>FACTORY_HOME_OVERRIDE</code>.</small>
        </label>
      {:else if newProvider === 'cursor'}
        <label class="field">
          <span class="label">API key environment variable</span>
          <input bind:value={credentialEnv} maxlength="128" pattern="[A-Za-z_][A-Za-z0-9_]*" required aria-describedby="cursor-help" />
        </label>
        <label class="field">
          <span class="label">Team member ID</span>
          <input bind:value={cursorUserId} maxlength="256" pattern="user_[A-Za-z0-9_-]+" placeholder="user_…" required aria-describedby="cursor-help" />
          <small id="cursor-help">Set the team key in the server environment and enter only its variable name. Use the member ID from the team's <code>/teams/members</code> API. Personal Cursor plans are not supported.</small>
        </label>
      {:else if newProvider === 'antigravity'}
        <p class="hint">Creates a separate snapshot slot for the signed-in Antigravity CLI.</p>
        <label class="check"><input type="checkbox" bind:checked={installNow} /> <span>Install the collector in <code>~/.gemini/antigravity-cli/settings.json</code>. Your existing status line keeps working.</span></label>
      {:else}
        <p class="hint">Opens ChatGPT sign-in. Each connection gets its own isolated Codex CLI home.</p>
      {/if}
      {#if formError}<p class="form-error" role="alert">{formError}</p>{/if}
      <footer>
        <button type="button" class="btn" onclick={() => addDialog?.close()}>Cancel</button>
        <button type="submit" class="btn primary" disabled={actionBusy || (newProvider === 'cursor' && (!credentialEnv.trim() || !cursorUserId.trim())) || (newProvider === 'factory-droid' && !localCredentials && !factoryKeyEnv.trim()) || (newProvider === 'devin' && !localCredentials && !factoryKeyEnv.trim()) || (isHarness(newProvider) && (!localCredentials || !storedLogin)) || (newProvider === 'cursor-local' && !localCredentials)}>
          {newProvider === 'codex-chatgpt' ? 'Continue to sign-in' : 'Add account'}
        </button>
      </footer>
    </form>
  </dialog>

  <dialog bind:this={accountDialog} aria-labelledby="account-title" onclose={() => { selectedId = null; confirmingRemove = false; renaming = false; formError = ''; }} onclick={closeOnBackdrop(accountDialog)}>
    {#if selectedProfile}
      {@const badge = selectedAccount ? accountBadge(selectedAccount, Date.now()) : null}
      <div class="sheet">
        <header>
          <ProviderIcon provider={selectedProfile.provider} size={38} />
          <div class="title">
            {#if renaming}
              <form class="rename" onsubmit={(event) => { event.preventDefault(); void saveName(); }}>
                <input bind:value={renameValue} maxlength="80" placeholder="Uses the account's email when empty" aria-label="Account name" />
                <button type="submit" class="btn small primary" disabled={actionBusy}>Save</button>
                <button type="button" class="btn small" onclick={() => { renaming = false; }}>Cancel</button>
              </form>
            {:else}
              <button type="button" class="title-button" onclick={() => { renameValue = selectedProfile.label; renaming = true; }} title="Rename">
                <h2 id="account-title">{nameOf(selectedProfile)}</h2><PencilSimpleIcon size={15} />
              </button>
            {/if}
            <p>{providerMeta[selectedProfile.provider].name}{selectedProfile.current ? ' · Current ChatGPT sign-in' : ''}{selectedProfile.defaultClaude ? ' · Default Claude sign-in' : ''}</p>
          </div>
          <button type="button" class="close" onclick={() => accountDialog?.close()} aria-label="Close"><XIcon size={18} weight="bold" /></button>
        </header>

        {#if selectedAccount}
          <dl class="facts">
            <div><dt>Status</dt><dd>{badge?.label}</dd></div>
            <div><dt>Plan</dt><dd>{selectedAccount.plan ? `${selectedAccount.plan.charAt(0).toUpperCase()}${selectedAccount.plan.slice(1)}` : 'Unavailable'}</dd></div>
            <div><dt>Source</dt><dd>{selectedAccount.source}</dd></div>
            <div><dt>Last refreshed</dt><dd>{selectedAccount.observedAt ? new Date(selectedAccount.observedAt).toLocaleString() : 'Never'}</dd></div>
            {#if selectedAccount.email}<div class="wide"><dt>Email</dt><dd>{selectedAccount.email}</dd></div>{/if}
            {#if selectedProfile.claudeConfigDir}<div class="wide"><dt>Config directory</dt><dd><code>{selectedProfile.claudeConfigDir}</code></dd></div>{/if}
          </dl>
          {@const issues = selectedAccount.errors.filter((error) => !(selectedProfile.collectCommand && ['claude_awaiting_snapshot', 'snapshot_read_failed'].includes(error.code)))}
          {#if issues.length}
            <ul class="errors">{#each issues as error (error.code)}<li>{error.message}</li>{/each}</ul>
          {/if}
        {/if}

        {#if selectedProfile.provider === 'factory-droid'}
          <section class="setup" aria-labelledby="factory-title">
            <h3 id="factory-title">Sign-in</h3>
            <div class="state"><PlugsConnectedIcon size={18} weight="bold" /><div>
              <strong>{selectedProfile.apiKeyConfigured ? 'API key' : localCredentials ? 'Local sign-in' : 'Needs an API key or local sign-ins'}</strong>
              <p>{selectedProfile.apiKeyConfigured ? 'Reads rate limits with the Factory API key from the configured variable.' : localCredentials ? `Reads the Droid sign-in stored in ${selectedProfile.factoryHome}/.factory.` : selectedProfile.apiKeyConfigured ? 'Reads rate limits with the Factory API key from the configured variable.' : 'Turn on local sign-ins in Settings, or add this account again with an API key variable.'}</p>
              {#if selectedProfile.factoryLaunchCommand}
                <p>Sign in to this account by starting Droid with its Factory home and running <code>/login</code>:</p>
                <div class="code"><code>{selectedProfile.factoryLaunchCommand}</code><button type="button" class="btn small" onclick={() => copy(selectedProfile.factoryLaunchCommand!)} aria-label="Copy launch command"><CopyIcon size={14} /></button></div>
              {/if}
            </div></div>
            <p class="hint">Factory does not document this rate-limit endpoint; it is the one Droid's <code>/limits</code> view uses.</p>
          </section>
        {/if}
        {#if selectedProfile.collectCommand}
          {@const collector = selectedProfile.collector}
          {@const signedOut = selectedAccount?.state === 'unauthorized'}
          <section class="setup" aria-labelledby="setup-title">
            <h3 id="setup-title">Quota collector</h3>
            {#if signedOut && selectedProfile.claudeLaunchCommand}
              <div class="state warn"><WarningIcon size={18} weight="bold" /><div><strong>Sign in first</strong><p>This config directory is not signed in. Start Claude Code with it and run <code>/login</code>.</p>
                <div class="code"><code>{selectedProfile.claudeLaunchCommand}</code><button type="button" class="btn small" onclick={() => copy(selectedProfile.claudeLaunchCommand!)} aria-label="Copy launch command"><CopyIcon size={14} /></button></div></div></div>
            {/if}
            {#if collector?.state === 'installed'}
              <div class="state ok">
                <CheckCircleIcon size={18} weight="fill" />
                <div><strong>Installed</strong><p>In <code>{collector.settingsFile}</code>{collector.chained ? '. Your previous status line still renders after each capture.' : '.'}</p>
                  <p>{!collector.lastRun ? 'Not run yet. Restart sessions opened before installing, then send a message.' : collector.lastRun.result === 'saved' ? `Last captured quota ${agoText(collector.lastRun.at, Date.now())}.` : collector.lastRun.result === 'no-quota' ? `Last ran ${agoText(collector.lastRun.at, Date.now())}; the CLI sent no subscription quota${selectedProfile.provider === 'claude-code' ? ' (Claude Code sends it for Pro and Max plans after a response)' : ''}.` : `Last ran ${agoText(collector.lastRun.at, Date.now())} from a different config directory and was ignored.`}</p></div>
                <button type="button" class="btn small" disabled={installing === selectedProfile.id} onclick={() => uninstallCollector(selectedProfile.id)}>Uninstall</button>
              </div>
            {:else if collector && ['not-installed', 'replaced'].includes(collector.state)}
              <div class={`state ${collector.state === 'replaced' ? 'warn' : ''}`}>
                <PlugsConnectedIcon size={18} weight="bold" />
                <div>
                  <strong>{collector.state === 'replaced' ? 'Replaced by another tool' : 'Not installed'}</strong>
                  <p>{collector.state === 'replaced' ? 'Something rewrote the status line in ' : 'Adds the collector to '}<code>{collector.settingsFile}</code>. A backup is saved as <code>settings.json.subset-backup</code>{collector.existing ? ', and your current status line keeps rendering' : ''}. Uninstalling or removing this account restores it.</p>
                </div>
                <button type="button" class="btn small primary" disabled={installing === selectedProfile.id} onclick={() => installCollector(selectedProfile.id)}>{installing === selectedProfile.id ? 'Installing…' : collector.state === 'replaced' ? 'Reinstall' : 'Install'}</button>
              </div>
            {:else if collector?.state === 'other-account'}
              <div class="state warn"><WarningIcon size={18} weight="bold" /><div><strong>Used by another account</strong><p><code>{collector.settingsFile}</code> holds one status line, and another {providerMeta[selectedProfile.provider].name} account's collector is installed there. Uninstall it from that account to collect for this one instead.</p></div></div>
            {:else if collector?.state === 'missing-directory'}
              <div class="state warn"><WarningIcon size={18} weight="bold" /><div><strong>CLI settings not found</strong><p>Start the CLI once with this account so <code>{collector.settingsFile}</code> can be created, then reopen this dialog.</p></div></div>
            {:else if collector?.state === 'unreadable'}
              <div class="state warn"><WarningIcon size={18} weight="bold" /><div><strong>Settings file can't be updated</strong><p><code>{collector.settingsFile}</code> is not valid JSON. Fix it, or set up the collector manually below.</p></div></div>
            {:else}
              <div class="state"><PlugsConnectedIcon size={18} weight="bold" /><div><strong>Manual setup</strong><p>This account has no config directory, so Subset can't tell which <code>settings.json</code> belongs to it. Add the account again with its config directory to install automatically.</p></div></div>
            {/if}
            <details open={collector?.state === 'manual' || collector?.state === 'unreadable'}>
              <summary>Set up manually</summary>
              <p>Add this to {#if selectedProfile.claudeSettingsFile}<code>{selectedProfile.claudeSettingsFile}</code>{:else if selectedProfile.provider === 'antigravity'}<code>~/.gemini/antigravity-cli/settings.json</code>{:else}the <code>settings.json</code> of the Claude Code config directory signed in to this account{/if}:</p>
              <div class="code"><pre>{statusLineJson(selectedProfile.collectCommand)}</pre><button type="button" class="btn small" onclick={() => copy(statusLineJson(selectedProfile.collectCommand!))} aria-label="Copy settings JSON"><CopyIcon size={14} /></button></div>
              <p>To keep an existing status line, point <code>statusLine.command</code> at this script and replace its last line with your current command:</p>
              <div class="code"><pre>{wrapperScript(selectedProfile.collectCommand)}</pre><button type="button" class="btn small" onclick={() => copy(wrapperScript(selectedProfile.collectCommand!))} aria-label="Copy wrapper script"><CopyIcon size={14} /></button></div>
            </details>
            <p class="hint">The collector stores only quota fields and never reads credentials. Subset changes CLI settings only when you install or uninstall here.</p>
          </section>
        {/if}

        {#if formError}<p class="form-error" role="alert">{formError}</p>{/if}
        <footer>
          {#if confirmingRemove}
            <p class="confirm">{removalDetail(selectedProfile)}</p>
            <button type="button" class="btn" onclick={() => { confirmingRemove = false; }}>Keep</button>
            <button type="button" class="btn danger" disabled={actionBusy} onclick={removeSelected}><TrashIcon size={15} weight="bold" />Remove account</button>
          {:else}
            <button type="button" class="btn danger-ghost" onclick={() => { confirmingRemove = true; }}>Remove…</button>
            <button type="button" class="btn primary" onclick={() => accountDialog?.close()}>Done</button>
          {/if}
        </footer>
      </div>
    {/if}
  </dialog>

  {#if toast}
    <div class="toast" class:error={toast.tone === 'error'} role={toast.tone === 'error' ? 'alert' : 'status'}>
      <p>{toast.text}</p>
      <button type="button" class="close" onclick={() => { toast = null; }} aria-label="Dismiss"><XIcon size={16} weight="bold" /></button>
    </div>
  {/if}
{/if}

<style>
  :global(:root) {
    --good: #2f9e5a; --warn: #c88c0a;
    --bg: #f5f4f0; --surface: #ffffff; --surface-2: #f0efe9; --line: #e3e1d9; --line-strong: #d3d0c5;
    --text: #17181a; --text-2: #5c5f63; --text-3: #8a8d91; --accent: #4b3ff2; --bad: #d6453d; --bad-bg: #fbe7e5;
    color-scheme: light dark;
  }
  :global(html[data-theme='dark']) {
    color-scheme: dark;
    --bg: #141414; --surface: #1b1b1c; --surface-2: #222224; --line: #2a2a2d; --line-strong: #37373b;
    --text: #f2f2f0; --text-2: #a4a5a8; --text-3: #75767a; --accent: #5b4ff7; --bad: #f0645b; --bad-bg: #3a1c1a;
    --good: #43c06f; --warn: #e9b23a;
  }
  :global(html[data-theme='light']) { color-scheme: light; }
  @media (prefers-color-scheme: dark) {
    :global(html:not([data-theme='light'])) {
      --bg: #141414; --surface: #1b1b1c; --surface-2: #222224; --line: #2a2a2d; --line-strong: #37373b;
      --text: #f2f2f0; --text-2: #a4a5a8; --text-3: #75767a; --accent: #5b4ff7; --bad: #f0645b; --bad-bg: #3a1c1a;
      --good: #43c06f; --warn: #e9b23a;
    }
  }
  :global(body) { margin: 0; background: var(--bg); color: var(--text); font-family: 'Twenty One Native', ui-sans-serif, system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
  main { min-height: 100vh; }
  /* Reserve the scrollbar's space so switching between short and long pages does not shift the layout. */
  :global(html) { scrollbar-gutter: stable; }
  .btn.icon-only { width: 36px; padding: 0; }
  .site-footer { max-width: 1140px; width: calc(100% - 40px); margin: 0 auto; padding: 18px 0 32px; border-top: 1px solid var(--line); display: flex; flex-wrap: wrap; align-items: center; justify-content: center; gap: 8px; font-size: .82rem; color: var(--text-3); box-sizing: border-box; }
  .site-footer a { color: var(--text-2); text-decoration: none; }
  .site-footer a:hover { color: var(--text); text-decoration: underline; }
  .site-footer a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: 4px; }
  .site-footer .star { display: inline-flex; align-items: center; gap: 6px; }
  /* The bar stays in view while the page scrolls; the full-width wrapper hides content scrolling beneath it. */
  .appbar-wrap { position: sticky; top: 0; z-index: 5; background: color-mix(in srgb, var(--bg) 92%, transparent); backdrop-filter: blur(8px); }
  .appbar { width: calc(100% - 40px); max-width: 1140px; margin: 0 auto; padding: 20px 0 16px; display: flex; align-items: center; gap: 20px; flex-wrap: wrap; border-bottom: 1px solid var(--line); box-sizing: border-box; }
  .brand { display: flex; align-items: center; gap: 10px; }
  .brand .name { font-size: 1.35rem; font-weight: 600; letter-spacing: -.02em; }
  .count { font-size: .78rem; font-weight: 500; color: var(--text-2); background: var(--surface-2); border: 1px solid var(--line); border-radius: 99px; padding: 1px 8px; }
  .brand :global(.brand-mark) { flex: none; color: var(--text); }
  .tabs { display: flex; gap: 4px; padding: 3px; border-radius: 11px; background: var(--surface-2); border: 1px solid var(--line); }
  .tabs button { display: inline-flex; align-items: center; gap: 6px; height: 30px; padding: 0 12px; border: 0; border-radius: 8px; background: transparent; color: var(--text-2); font: inherit; font-size: .88rem; font-weight: 500; cursor: pointer; }
  .tabs button[aria-current='page'] { background: var(--surface); color: var(--text); box-shadow: 0 1px 2px rgb(0 0 0 / .08); }
  .tabs button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  .bar-actions { display: flex; align-items: center; gap: 8px; margin-left: auto; flex-wrap: wrap; }
  .synced { font-size: .82rem; color: var(--text-3); margin-right: 4px; }
  .i { display: inline-flex; }
  .spin { animation: spin .9s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) { .spin { animation: none; } }

  .settings { max-width: 760px; margin: 0 auto; padding: 24px 20px 48px; display: grid; gap: 16px; box-sizing: border-box; }
  .settings h1 { margin: 0 0 4px; font-size: 1.5rem; font-weight: 600; letter-spacing: -.02em; }
  .panel { background: var(--surface); border: 1px solid var(--line); border-radius: 14px; overflow: hidden; }
  .panel h2 { margin: 0; font-size: .98rem; font-weight: 600; }
  .panel p { margin: 3px 0 0; font-size: .85rem; color: var(--text-2); line-height: 1.45; }
  .row { display: flex; align-items: center; justify-content: space-between; gap: 20px; padding: 16px 18px; }
  .row + .row { border-top: 1px solid var(--line); }
  .panel-head { display: flex; align-items: center; justify-content: space-between; padding: 14px 18px; border-bottom: 1px solid var(--line); }
  .segmented { flex: none; display: inline-flex; padding: 3px; gap: 2px; border-radius: 10px; background: var(--surface-2); border: 1px solid var(--line); }
  .segmented button { height: 30px; padding: 0 12px; border: 0; border-radius: 7px; background: transparent; color: var(--text-2); font: inherit; font-size: .86rem; font-weight: 500; cursor: pointer; white-space: nowrap; }
  .segmented button[aria-checked='true'] { background: var(--surface); color: var(--text); box-shadow: 0 1px 2px rgb(0 0 0 / .08); }
  .segmented button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  .account-row { display: flex; align-items: center; gap: 12px; padding: 12px 18px; }
  .account-row + .account-row { border-top: 1px solid var(--line); }
  .account-text { flex: 1; min-width: 0; display: grid; }
  .account-text strong { display: flex; align-items: center; gap: 8px; font-size: .92rem; font-weight: 600; }
  .tag { font-size: .72rem; font-weight: 500; padding: 1px 8px; border-radius: 6px; border: 1px solid var(--line-strong); color: var(--text-2); background: var(--surface-2); }
  .account-text span { font-size: .8rem; color: var(--text-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .panel > .hint { padding: 16px 18px; }
  .switch { flex: none; position: relative; width: 44px; height: 26px; border-radius: 99px; border: 1px solid var(--line-strong); background: var(--surface-2); cursor: pointer; padding: 0; }
  .switch span { position: absolute; top: 2px; left: 2px; width: 20px; height: 20px; border-radius: 50%; background: var(--surface); box-shadow: 0 1px 2px rgb(0 0 0 / .2); transition: transform .15s; }
  .switch[aria-checked='true'] { background: var(--accent); border-color: var(--accent); }
  .switch[aria-checked='true'] span { transform: translateX(18px); }
  .switch:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  @media (prefers-reduced-motion: reduce) { .switch span { transition: none; } }
  kbd { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .8em; padding: 1px 6px; border: 1px solid var(--line-strong); border-bottom-width: 2px; border-radius: 5px; background: var(--surface-2); }
  @media (max-width: 640px) {
    .appbar { width: calc(100% - 28px); padding: 14px 0; gap: 12px; }
    .bar-actions { margin-left: 0; width: 100%; }
    .row { flex-direction: column; align-items: flex-start; }
  }
  .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }

  .btn { display: inline-flex; align-items: center; justify-content: center; gap: 7px; height: 36px; padding: 0 14px; border-radius: 10px; border: 1px solid var(--line-strong); background: var(--surface); color: var(--text); font: inherit; font-size: .9rem; font-weight: 500; cursor: pointer; text-decoration: none; white-space: nowrap; }
  .btn:hover:not(:disabled) { background: var(--surface-2); }
  .btn.primary { background: var(--accent); border-color: transparent; color: #fff; }
  .btn.primary:hover:not(:disabled) { background: color-mix(in srgb, var(--accent) 88%, #000); }
  .btn.danger { background: var(--bad); border-color: transparent; color: #fff; }
  .btn.danger-ghost { color: var(--bad); margin-right: auto; }
  .btn.small { height: 28px; padding: 0 10px; font-size: .8rem; }
  .btn:disabled { opacity: .55; cursor: not-allowed; }
  .btn:focus-visible, .close:focus-visible, input:focus-visible, summary:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

  .banner { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-top: 16px; padding: 14px 16px; border-radius: 14px; border: 1px solid color-mix(in srgb, var(--accent) 35%, var(--line)); background: color-mix(in srgb, var(--accent) 7%, var(--surface)); }
  .banner.error { border-color: color-mix(in srgb, var(--bad) 40%, var(--line)); background: var(--bad-bg); }
  .banner strong { font-weight: 600; }
  .banner p { margin: 2px 0 0; font-size: .87rem; color: var(--text-2); }
  .banner.error p { color: var(--bad); }
  .banner-actions { display: flex; gap: 8px; flex-wrap: wrap; }

  dialog { width: min(560px, calc(100vw - 24px)); max-height: calc(100vh - 48px); padding: 0; border: 1px solid var(--line); border-radius: 18px; background: var(--surface); color: var(--text); box-shadow: 0 24px 64px rgb(0 0 0 / .22); }
  dialog::backdrop { background: rgb(10 10 12 / .45); backdrop-filter: blur(2px); }
  .sheet { display: grid; gap: 18px; padding: 22px; margin: 0; }
  .sheet > header { display: flex; align-items: center; gap: 12px; }
  .sheet h2 { margin: 0; font-size: 1.2rem; font-weight: 600; letter-spacing: -.01em; flex: 1; }
  .title { flex: 1; min-width: 0; }
  .title p { margin: 2px 0 0; font-size: .85rem; color: var(--text-2); }
  .title-button { display: inline-flex; align-items: center; gap: 8px; max-width: 100%; padding: 2px 6px; margin: -2px -6px; border: 0; border-radius: 8px; background: none; color: var(--text-3); font: inherit; cursor: text; text-align: left; }
  .title-button h2 { color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .title-button:hover { background: var(--surface-2); }
  .title-button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  .rename { display: flex; gap: 6px; align-items: center; }
  .rename input { flex: 1; min-width: 0; height: 34px; border: 1px solid var(--line-strong); border-radius: 9px; padding: 0 10px; background: var(--surface); color: var(--text); font: inherit; font-size: .95rem; }
  .rename input:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
  .close { width: 32px; height: 32px; border: 0; border-radius: 8px; background: transparent; color: var(--text-3); font-size: 1.4rem; line-height: 1; cursor: pointer; }
  .close:hover { background: var(--surface-2); color: var(--text); }
  .label { display: block; font-size: .78rem; font-weight: 500; color: var(--text-3); text-transform: uppercase; letter-spacing: .08em; margin-bottom: 8px; }
  .label em { font-style: normal; text-transform: none; letter-spacing: 0; color: var(--text-3); font-weight: 400; }
  .quick { display: flex; flex-wrap: wrap; gap: 8px; padding-bottom: 18px; border-bottom: 1px solid var(--line); }
  .quick .label { width: 100%; margin-bottom: 0; }
  .providers { border: 0; padding: 0; margin: 0; display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
  .providers legend { padding: 0; }
  .provider { position: relative; display: flex; align-items: center; gap: 10px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 12px; cursor: pointer; background: var(--surface); }
  .provider:hover { border-color: var(--line-strong); }
  .provider.selected { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
  .provider input { position: absolute; opacity: 0; pointer-events: none; }
  .provider:has(input:focus-visible) { outline: 2px solid var(--accent); outline-offset: 2px; }
  .provider strong { display: block; font-size: .92rem; font-weight: 600; }
  .provider small { display: block; font-size: .76rem; color: var(--text-2); line-height: 1.35; margin-top: 1px; }
  .field { display: grid; gap: 0; }
  .logins { border: 0; padding: 0; margin: 0; gap: 8px; }
  .logins legend { padding: 0; }
  .field input:not([type='radio']):not([type='checkbox']) { height: 40px; border: 1px solid var(--line-strong); border-radius: 10px; padding: 0 12px; background: var(--surface); color: var(--text); font: inherit; font-size: .95rem; }
  .field small, .hint { font-size: .8rem; color: var(--text-2); line-height: 1.45; margin: 8px 0 0; }
  .hint { margin: 0; }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .85em; background: var(--surface-2); border-radius: 5px; padding: 1px 5px; overflow-wrap: anywhere; }
  .form-error { margin: 0; padding: 10px 12px; border-radius: 10px; background: var(--bad-bg); color: var(--bad); font-size: .87rem; }
  .sheet footer { display: flex; justify-content: flex-end; align-items: center; gap: 8px; flex-wrap: wrap; padding-top: 16px; border-top: 1px solid var(--line); }
  .confirm { flex-basis: 100%; margin: 0 0 4px; font-size: .85rem; color: var(--text-2); line-height: 1.45; }

  .facts { display: grid; grid-template-columns: 1fr 1fr; gap: 1px; margin: 0; background: var(--line); border: 1px solid var(--line); border-radius: 12px; overflow: hidden; }
  .facts div { background: var(--surface); padding: 10px 12px; min-width: 0; }
  .facts .wide { grid-column: 1 / -1; }
  .facts dt { font-size: .74rem; color: var(--text-3); text-transform: uppercase; letter-spacing: .07em; }
  .facts dd { margin: 3px 0 0; font-size: .9rem; overflow-wrap: anywhere; }
  .errors { margin: 0; padding: 0 0 0 18px; font-size: .85rem; color: var(--text-2); line-height: 1.5; }
  .state { display: flex; align-items: flex-start; gap: 10px; padding: 12px; border-radius: 12px; border: 1px solid var(--line); background: var(--surface-2); margin-bottom: 12px; color: var(--text-2); }
  .state > :global(svg) { flex: none; margin-top: 2px; }
  .state > div { flex: 1; min-width: 0; }
  .state strong { color: var(--text); font-weight: 600; font-size: .9rem; }
  .state p { margin: 2px 0 0; font-size: .84rem; line-height: 1.45; }
  .state .code { margin-top: 8px; }
  .state.ok { color: var(--good, #2f9e5a); }
  .state.warn { color: var(--warn, #d39a12); }
  .check { display: flex; align-items: flex-start; gap: 10px; font-size: .86rem; color: var(--text-2); line-height: 1.45; cursor: pointer; }
  .check { align-items: center; }
  .check input { flex: none; margin: 0; width: 16px; height: 16px; accent-color: var(--accent); }
  .setup h3 { margin: 0 0 10px; font-size: 1rem; font-weight: 600; }
  .code { position: relative; display: flex; align-items: flex-start; gap: 8px; background: var(--surface-2); border: 1px solid var(--line); border-radius: 10px; padding: 10px 10px 10px 12px; }
  .code pre, .code > code { flex: 1; margin: 0; padding: 0; background: none; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .78rem; line-height: 1.5; white-space: pre-wrap; overflow-wrap: anywhere; }
  details { font-size: .86rem; margin-bottom: 12px; }
  summary { cursor: pointer; color: var(--accent); font-weight: 500; }
  details p { color: var(--text-2); line-height: 1.5; }

  .toast { position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%); display: flex; align-items: center; gap: 10px; max-width: min(560px, calc(100vw - 24px)); padding: 10px 10px 10px 16px; border-radius: 12px; background: var(--text); color: var(--bg); box-shadow: 0 12px 32px rgb(0 0 0 / .25); font-size: .9rem; z-index: 10; }
  .toast p { margin: 0; }
  .toast.error { background: var(--bad); color: #fff; }
  .toast .close { color: inherit; opacity: .8; }

  @media (max-width: 560px) {
    .providers { grid-template-columns: 1fr; }
    .facts { grid-template-columns: 1fr; }
    .sheet { padding: 18px; }
  }
</style>
