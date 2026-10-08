<script lang="ts">
  import { onMount, tick, type Snippet } from 'svelte';
  import ArrowClockwiseIcon from 'phosphor-svelte/lib/ArrowClockwiseIcon';
  import ArrowRightIcon from 'phosphor-svelte/lib/ArrowRightIcon';
  import ClockIcon from 'phosphor-svelte/lib/ClockIcon';
  import ClockCountdownIcon from 'phosphor-svelte/lib/ClockCountdownIcon';
  import DotsThreeIcon from 'phosphor-svelte/lib/DotsThreeIcon';
  import GaugeIcon from 'phosphor-svelte/lib/GaugeIcon';
  import InfoIcon from 'phosphor-svelte/lib/InfoIcon';
  import PushPinIcon from 'phosphor-svelte/lib/PushPinIcon';
  import GearSixIcon from 'phosphor-svelte/lib/GearSixIcon';
  import SlidersHorizontalIcon from 'phosphor-svelte/lib/SlidersHorizontalIcon';
  import CheckIcon from 'phosphor-svelte/lib/CheckIcon';
  import TrendUpIcon from 'phosphor-svelte/lib/TrendUpIcon';
  import FireIcon from 'phosphor-svelte/lib/FireIcon';
  import WarningIcon from 'phosphor-svelte/lib/WarningIcon';
  import XIcon from 'phosphor-svelte/lib/XIcon';
  import ProviderIcon from './ProviderIcon.svelte';
  import { historyWindowKey, type UsageHistory } from './history.js';
  import { createUsageStatus, usageFreshness, type UsageAccount, type UsageProvider, type UsageStatus, type UsageWindow } from './index.js';
  import {
    accountBadge, accountName, accountService, activityGrid, agoText, DAY_PARTS, limitAlerts, windowGroups, type LimitItem, compactDuration, displayPercent, isSnapshotProvider, planName, providerMeta, resetDetails, spanLabel, summarize,
    sortAccounts, usedTone, windowPace, windowResetText, windowTitle, type PercentMode, type SortMode,
  } from './present.js';

  type Hint = { message?: string; action?: { label: string; run: () => void; busy?: boolean } } | null;

  interface Props {
    status: UsageStatus;
    busy?: boolean;
    refresh?: () => void;
    /** Show the built-in header. Hosts with their own app bar pass false. */
    header?: boolean;
    /** Whether percentages show the used or the remaining share of each window. */
    percentMode?: PercentMode;
    /** Opens the host's account settings for one account. */
    openAccount?: (id: string) => void;
    /** Legacy entry point for hosts that manage accounts in their own section. */
    manageAccounts?: () => void;
    /** Host controls rendered beside Refresh, such as an Add account button. */
    toolbar?: Snippet;
    /** Host notices rendered above the accounts, such as sign-in progress. */
    notice?: Snippet;
    /** Shown in the empty state; omitted when the host cannot add accounts. */
    emptyAction?: Snippet;
    /** Local observation history for trend charts. */
    history?: UsageHistory;
    /** Host explanation and one-step fix for an account that is waiting for data. */
    accountHint?: (account: UsageAccount) => Hint;
    /** A neutral tag shown beside the account name, such as "Default". */
    accountTag?: (account: UsageAccount) => string | null;
    /** Show trend charts when enough history exists. */
    showTrends?: boolean;
    /** True until the first status arrives, so the view shows placeholders instead of an empty state. */
    loading?: boolean;
    /** Redeems a banked reset for an account; resolves to a message for the user. */
    redeemReset?: (accountId: string) => Promise<string>;
    /** Pinned account IDs, shown under the Pinned filter. */
    pinned?: string[];
    togglePin?: (accountId: string) => void;
    sortMode?: SortMode;
    setSortMode?: (mode: SortMode) => void;
    setShowTrends?: (value: boolean) => void;
    /** Show credits, extra usage, and spending amounts. */
    showCredits?: boolean;
    setShowCredits?: (value: boolean) => void;
  }

  let {
    status, busy = false, refresh, header = true, percentMode = 'used', openAccount, manageAccounts, toolbar, notice, emptyAction, history, accountHint,
    accountTag, showTrends = true, loading = false, redeemReset, pinned = [], togglePin, sortMode = 'default', setSortMode,
    setShowTrends, showCredits = true, setShowCredits,
  }: Props = $props();

  let now = $state(Date.now());
  onMount(() => {
    const timer = setInterval(() => { now = Date.now(); }, 30_000);
    // Menus close on any press outside them.
    const outside = (event: PointerEvent) => {
      if (!(event.target as Element | null)?.closest?.('.card-menu, .sort')) { menuFor = null; sortOpen = false; }
    };
    document.addEventListener('pointerdown', outside);
    return () => { clearInterval(timer); document.removeEventListener('pointerdown', outside); };
  });

  const SEGMENTS = 20;
  // Provider filter chips; the summary follows the filtered accounts.
  let filter = $state<UsageProvider | 'all' | 'pinned'>('all');
  // Harness accounts (Pi, OpenCode, …) count under the service whose subscription they read.
  const providerCounts = $derived(status.accounts.reduce((counts, account) => counts.set(accountService(account), (counts.get(accountService(account)) ?? 0) + 1), new Map<UsageProvider, number>()));
  const pinnedCount = $derived(status.accounts.filter((account) => pinned.includes(account.id)).length);
  const activeFilter = $derived(filter === 'pinned' ? (pinnedCount ? 'pinned' : 'all') : filter !== 'all' && providerCounts.has(filter) ? filter : 'all');
  const filtered = $derived(activeFilter === 'all' ? status.accounts : activeFilter === 'pinned' ? status.accounts.filter((account) => pinned.includes(account.id)) : status.accounts.filter((account) => accountService(account) === activeFilter));
  const activity = $derived(activityGrid(history, filtered, now));
  const dayName = (start: number) => new Intl.DateTimeFormat(undefined, { weekday: 'short' }).format(new Date(start));
  const hourLabel = (hour: number) => new Intl.DateTimeFormat(undefined, { hour: 'numeric' }).format(new Date(2000, 0, 1, hour % 24));
  let hovered = $state<{ part: number; day: number } | null>(null);
  // One continuous line from the first dot to the last, measured after layout.
  let resetsList: HTMLElement | undefined = $state();
  let timelineStyle = $state('');
  function placeTimeline() {
    const dots = resetsList ? [...resetsList.querySelectorAll<HTMLElement>('.rail i')] : [];
    if (!resetsList || dots.length < 2) { timelineStyle = ''; return; }
    const box = resetsList.getBoundingClientRect();
    const first = dots[0].getBoundingClientRect();
    const last = dots[dots.length - 1].getBoundingClientRect();
    const center = (rect: DOMRect) => rect.top + rect.height / 2 - box.top;
    timelineStyle = `left:${first.left + first.width / 2 - box.left - 1}px;top:${center(first)}px;height:${center(last) - center(first)}px`;
  }
  $effect(() => {
    void summary.nextResets.length;
    if (!resetsList) return;
    placeTimeline();
    const observer = new ResizeObserver(placeTimeline);
    observer.observe(resetsList);
    return () => observer.disconnect();
  });
  /** Clock time of a reset: time only for today, weekday and time otherwise. */
  const resetClock = (at: string) => {
    const date = new Date(at);
    const today = new Date(now).toDateString() === date.toDateString();
    return new Intl.DateTimeFormat(undefined, today ? { hour: 'numeric', minute: '2-digit' } : { weekday: 'short', hour: 'numeric', minute: '2-digit' }).format(date);
  };
  const dayLong = (start: number) => new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric' }).format(new Date(start));
  const visible = $derived(sortAccounts(filtered, sortMode, history, now));
  let sortOpen = $state(false);
  let menuFor = $state<string | null>(null);
  // Accounts that report limit groups side by side (Factory standard/Core, Antigravity Gemini/third-party) show one group per tab.
  let windowGroup = $state<Record<string, string>>({});
  const activeGroup = (account: UsageAccount) => {
    const groups = windowGroups(account);
    return groups ? groups.find((group) => group.id === windowGroup[account.id]) ?? groups[0] : null;
  };
  const shownWindows = (account: UsageAccount) => activeGroup(account)?.windows ?? account.windows;

  const alerts = $derived(limitAlerts(filtered));
  let alertDialog: HTMLDialogElement | undefined = $state();
  let alertKind = $state<'exhausted' | 'low'>('exhausted');
  /** Alert windows grouped by account, keeping the list's order. */
  const groupedAlerts = (items: LimitItem[]) => [...items.reduce((groups, item) => {
    const group = groups.get(item.accountId) ?? { accountId: item.accountId, account: item.account, provider: item.provider, items: [] as LimitItem[] };
    group.items.push(item);
    return groups.set(item.accountId, group);
  }, new Map<string, { accountId: string; account: string; provider: string; items: LimitItem[] }>()).values()];
  const alertList = (items: LimitItem[]) => items.map((item) => `${item.account} · ${item.window}`).join('\n');
  async function showAlerts(kind: 'exhausted' | 'low') {
    alertKind = kind;
    await tick();
    alertDialog?.showModal();
  }
  /** Scrolls to an account's card and briefly highlights it. */
  function jumpTo(accountId: string) {
    alertDialog?.close();
    const card = document.getElementById(`card-${accountId}`);
    card?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    card?.classList.add('flash');
    setTimeout(() => card?.classList.remove('flash'), 1600);
  }
  const sortLabels: Record<SortMode, string> = { default: 'Default order', recent: 'Recently used first', expiring: 'Expiring first' };
  const amountText = (balance: NonNullable<UsageAccount['balances']>[number]) => balance.currency === 'credits'
    ? balance.note === 'Unlimited' ? 'Unlimited' : `${new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 }).format(balance.amount)} credits`
    : dollars(balance.amount);
  // Codex credits list at $40 per 1,000; the dollar figure is an estimate at that price.
  const creditValue = (balance: NonNullable<UsageAccount['balances']>[number]) => balance.currency === 'credits' && balance.note !== 'Unlimited' && balance.amount > 0
    ? `about ${dollars(balance.amount * 0.04)} at list price` : balance.note ?? '';
  /** The credit Codex is asked to use: the one that expires first. */
  const nextCredit = (credits: NonNullable<NonNullable<UsageAccount['resetCredits']>['credits']>) =>
    [...credits].sort((a, b) => (a.expiresAt ? Date.parse(a.expiresAt) : Infinity) - (b.expiresAt ? Date.parse(b.expiresAt) : Infinity))[0] ?? null;
  const summary = $derived(summarize(createUsageStatus(filtered, new Date(status.generatedAt)), now));
  const exactTime = (value: string | null) => value && Number.isFinite(Date.parse(value))
    ? new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value)) : 'Unavailable';
  /** Time only for today, otherwise date and time. */
  const stamp = (value: string | null) => {
    if (!value || !Number.isFinite(Date.parse(value))) return 'Never';
    const date = new Date(value);
    const today = new Date(now).toDateString() === date.toDateString();
    return new Intl.DateTimeFormat(undefined, today ? { timeStyle: 'short' } : { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(date);
  };
  const dollars = (value: number | null) => value === null ? 'Unavailable' : new Intl.NumberFormat(undefined, { style: 'currency', currency: 'USD' }).format(value);
  const percent = (value: number) => `${Math.round(value * 10) / 10}%`;
  const filled = (share: number) => Math.min(SEGMENTS, Math.max(share > 0 ? 1 : 0, Math.round(share / 100 * SEGMENTS)));
  const notices = (account: UsageAccount) => account.errors.filter((error) => !['partial_limits', 'partial_quota'].includes(error.code) || account.windows.length === 0);
  const issueTone = (account: UsageAccount) => account.state === 'blocked' || account.state === 'unauthorized' ? 'bad' : 'warn';

  let trendModule: Promise<typeof import('./UsageTrend.svelte')> | undefined;
  const loadTrend = () => (trendModule ??= import('./UsageTrend.svelte'));

  // A trend needs at least three observations across 30 minutes to say anything.
  function trendSeries(account: UsageAccount) {
    const windows = showTrends ? history?.series[account.id] : undefined;
    if (!windows) return [];
    return shownWindows(account)
      .map((window) => ({
        name: windowTitle(account, window),
        points: (windows[historyWindowKey(window)] ?? []).map(([time, used]): [number, number] => [time, percentMode === 'used' ? used : Math.round((100 - used) * 100) / 100]),
      }))
      .filter((item) => item.points.length >= 3 && item.points.at(-1)![0] - item.points[0][0] >= 30 * 60_000)
      .slice(0, 4);
  }

  function permissionLine(account: UsageAccount) {
    if (account.provider !== 'codex-chatgpt' || account.ordinaryUsageAllowed === true || account.ordinaryUsageAllowed === undefined) return null;
    return account.ordinaryUsageAllowed === false
      ? 'ChatGPT reports included usage is blocked. Quota percentages do not override this.'
      : 'ChatGPT did not report whether included usage is allowed. Do not infer it from quota.';
  }

  // Reset details dialog
  let resetDialog: HTMLDialogElement | undefined = $state();
  let resetFocus = $state<{ accountId: string; key: string } | null>(null);
  const resetAccount = $derived(resetFocus ? status.accounts.find((account) => account.id === resetFocus!.accountId) ?? null : null);
  let confirmReset = $state(false);
  let redeeming = $state(false);
  let resetMessage = $state('');
  async function useReset(accountId: string) {
    if (!redeemReset) return;
    redeeming = true;
    try { resetMessage = await redeemReset(accountId); }
    catch (cause) { resetMessage = cause instanceof Error ? cause.message : 'Could not use a reset.'; }
    finally { redeeming = false; confirmReset = false; }
  }
  async function showResets(account: UsageAccount, window?: UsageWindow) {
    resetFocus = { accountId: account.id, key: window ? historyWindowKey(window) : '' };
    await tick();
    if (!resetDialog?.open) resetDialog?.showModal();
  }
</script>

<section class="usage" aria-labelledby={header ? 'usage-title' : undefined} aria-label={header ? undefined : 'Account usage'} aria-busy={busy}>
  {#if header}
    <header class="bar">
      <div class="brand">
        <span class="logo" aria-hidden="true"><i></i><i></i><i></i></span>
        <h1 id="usage-title">Usage</h1>
        <span class="count" aria-label={`${status.accounts.length} accounts`}>{status.accounts.length}</span>
      </div>
      <div class="actions">
        <span class="synced" title={exactTime(status.generatedAt)}>Refreshed {stamp(status.generatedAt)}</span>
        {#if refresh}
          <button type="button" class="ghost" onclick={refresh} disabled={busy} aria-keyshortcuts="r">
            <span class:spin={busy} class="i"><ArrowClockwiseIcon size={16} weight="bold" /></span>
            {busy ? 'Checking' : 'Refresh'}
          </button>
        {/if}
        {#if toolbar}{@render toolbar()}{:else if manageAccounts}<button type="button" class="primary" onclick={manageAccounts}>Manage accounts</button>{/if}
      </div>
    </header>
  {/if}

  {#if notice}{@render notice()}{/if}

  {#if loading && status.accounts.length === 0}
    <div class="skeleton" aria-busy="true" aria-label="Loading accounts">
      <div class="sk-summary">{#each { length: 3 } as _}<div class="sk-block"></div>{/each}</div>
      <div class="sk-grid">{#each { length: 3 } as _}<div class="sk-card"><div class="sk-line w40"></div><div class="sk-line w70"></div><div class="sk-bar"></div><div class="sk-line w55"></div><div class="sk-bar"></div></div>{/each}</div>
    </div>
  {:else if status.accounts.length === 0}
    <div class="empty">
      <span class="logo large" aria-hidden="true"><i></i><i></i><i></i></span>
      <h2>No accounts yet</h2>
      <p>Add ChatGPT, Claude, Cursor, Factory Droid, or another account to see limits, reset times, and spending in one place.</p>
      {#if emptyAction}{@render emptyAction()}{/if}
    </div>
  {:else}
    {#if providerCounts.size > 1 || pinnedCount || setSortMode}
      <div class="filter-bar">
      <div class="filters" role="toolbar" aria-label="Filter by provider">
        <button type="button" class="chip" aria-pressed={activeFilter === 'all'} onclick={() => { filter = 'all'; }}>All <span>{status.accounts.length}</span></button>
        {#if pinnedCount}
          <button type="button" class="chip" aria-pressed={activeFilter === 'pinned'} onclick={() => { filter = 'pinned'; }}><PushPinIcon size={14} weight="fill" />Pinned <span>{pinnedCount}</span></button>
        {/if}
        {#each providerCounts.size > 1 ? [...providerCounts] : [] as [provider, count] (provider)}
          <button type="button" class="chip" aria-pressed={activeFilter === provider} onclick={() => { filter = provider; }}>
            <ProviderIcon {provider} size={15} bare />{providerMeta[provider].name} <span>{count}</span>
          </button>
        {/each}
      </div>
        {#if setSortMode}
          <div class="sort">
            <button type="button" class="sort-button" class:active={sortMode !== 'default' || !showTrends || !showCredits} aria-haspopup="menu" aria-expanded={sortOpen} aria-label="View options" title="View options"
              onclick={() => { sortOpen = !sortOpen; }} onkeydown={(event) => { if (event.key === 'Escape') sortOpen = false; }}><SlidersHorizontalIcon size={17} weight="bold" /></button>
            {#if sortOpen}
              <div class="menu" role="menu" tabindex="-1" onfocusout={(event) => { if (!event.currentTarget.contains(event.relatedTarget as Node | null)) sortOpen = false; }}
                onkeydown={(event) => { if (event.key === 'Escape') sortOpen = false; }}>
                <span class="menu-heading">Sort</span>
                {#each Object.entries(sortLabels) as [mode, label] (mode)}
                  <button type="button" role="menuitemradio" aria-checked={sortMode === mode} onclick={() => { setSortMode(mode as SortMode); }}>
                    <span class="menu-check">{#if sortMode === mode}<CheckIcon size={14} weight="bold" />{/if}</span>{label}
                  </button>
                {/each}
                {#if setShowTrends || setShowCredits}
                  <span class="menu-heading">Show</span>
                  {#if setShowTrends}
                    <button type="button" role="menuitemcheckbox" aria-checked={showTrends} onclick={() => setShowTrends(!showTrends)}>
                      <span class="menu-check">{#if showTrends}<CheckIcon size={14} weight="bold" />{/if}</span>Trend charts
                    </button>
                  {/if}
                  {#if setShowCredits}
                    <button type="button" role="menuitemcheckbox" aria-checked={showCredits} onclick={() => setShowCredits(!showCredits)}>
                      <span class="menu-check">{#if showCredits}<CheckIcon size={14} weight="bold" />{/if}</span>Credits and extra usage
                    </button>
                  {/if}
                {/if}
              </div>
            {/if}
          </div>
        {/if}
      </div>
    {/if}

    <dl class="summary">
      <div class="activity-card">
        <dt><FireIcon size={14} weight="bold" />Activity<span class="dt-aside">Last 7 days</span></dt>
        <dd class="activity-dd">
          <span class="heatmap" role="group" aria-label="Usage added per part of day over the last 7 days" onmouseleave={() => { hovered = null; }}>
            <span></span>
            {#each activity.dayStarts as start (start)}<span class="hm-label hm-day">{dayName(start)}</span>{/each}
            {#each activity.cells as row, part (part)}
              <span class="hm-label">{DAY_PARTS[part].label}</span>
              {#each row as cell, day (day)}
                <button type="button" class="hm-cell" class:on={hovered?.part === part && hovered?.day === day} style={`--level:${cell.value > 0 && activity.max > 0 ? Math.max(0.2, cell.value / activity.max) : 0}`}
                  aria-label={`${dayLong(activity.dayStarts[day])}, ${DAY_PARTS[part].label.toLowerCase()}: ${cell.value > 0 ? `${cell.value} points of usage added` : 'no recorded usage'}`}
                  onmouseenter={() => { hovered = { part, day }; }} onfocus={() => { hovered = { part, day }; }} onblur={() => { hovered = null; }}></button>
              {/each}
            {/each}
          </span>
          {#if hovered}
            {@const cell = activity.cells[hovered.part][hovered.day]}
            <span class="hm-tip" role="status">
              <strong>{dayLong(activity.dayStarts[hovered.day])} · {DAY_PARTS[hovered.part].label} ({hourLabel(DAY_PARTS[hovered.part].from)}–{hourLabel(DAY_PARTS[hovered.part].to)})</strong>
              {#if cell.value > 0}
                <span>{cell.value} points of usage added across {cell.top.length === 1 ? '1 account' : `${cell.top.length}${cell.top.length === 3 ? '+' : ''} accounts`}</span>
                {#each cell.top as item (item.account)}<span class="hm-row"><em>{item.account}</em>+{item.points}</span>{/each}
              {:else}<span>No recorded usage</span>{/if}
            </span>
          {:else if activity.max === 0}
            <span class="activity-empty">Activity appears as usage history builds up.</span>
          {/if}
        </dd>
      </div>
      <div>
        <dt><GaugeIcon size={14} weight="bold" />Limits</dt>
        <dd class="limits-dd">
          {#each [['low', 'Running low', '85%+ used', alerts.low], ['exhausted', 'Exhausted', '0% left', alerts.exhausted]] as [kind, label, hint, items] (kind)}
            {@const list = items as LimitItem[]}
            <button type="button" class={`limit-row ${kind}`} disabled={!list.length} title={list.length ? alertList(list) : `No ${String(label).toLowerCase()} limits`} onclick={() => showAlerts(kind as 'exhausted' | 'low')}>
              <strong>{list.length}</strong>
              <span class="limit-text"><span class="limit-label">{label}<small>{hint}</small></span><span class="limit-names">{list.length ? [...new Set(list.map((item) => item.account))].slice(0, 2).join(', ') + (new Set(list.map((item) => item.account)).size > 2 ? ` +${new Set(list.map((item) => item.account)).size - 2}` : '') : 'None'}</span></span>
            </button>
          {/each}
        </dd>
      </div>
      <div>
        <dt><ClockIcon size={14} weight="bold" />Upcoming resets</dt>
        <dd class="resets-dd" bind:this={resetsList}>
          {#if summary.nextResets.length > 1}<span class="timeline-line" aria-hidden="true" style={timelineStyle}></span>{/if}
          {#each summary.nextResets as reset (`${reset.accountId}-${reset.window}`)}
            <button type="button" class="reset-row" onclick={() => jumpTo(reset.accountId)} title={`${reset.account} · ${reset.provider} · ${reset.window}\n${exactTime(reset.at)}`}>
              <strong>{compactDuration(Date.parse(reset.at) - now)}</strong>
              <span class="rail" aria-hidden="true"><i></i></span>
              <span class="reset-text"><span><time datetime={reset.at}>{resetClock(reset.at)}</time> · {reset.account}</span><small>{reset.provider} · {reset.window}</small></span>
            </button>
          {:else}
            <span class="none-text">No reset times reported</span>
          {/each}
        </dd>
      </div>
    </dl>

    <ul class="grid" role="list">
      {#each visible as account (account.id)}
        {@const badge = accountBadge(account, now)}
        {@const meta = providerMeta[account.provider]}
        {@const permission = permissionLine(account)}
        {@const stale = usageFreshness(account.observedAt, now) === 'Stale'}
        {@const name = accountName(account)}
        {@const tag = accountTag?.(account) ?? null}
        <li>
          <article class="card" id={`card-${account.id}`} class:issue={badge.tone === 'bad'} aria-labelledby={`account-${account.id}`}>
            <header class="card-head">
              <ProviderIcon provider={account.provider} />
              <div class="who">
                <div class="name-row">
                  <h2 id={`account-${account.id}`} title={name}>{name}</h2>
                  {#if tag}<span class="tag">{tag}</span>{/if}
                </div>
                <p class="meta-row">
                  {#if account.email && account.email !== name}<span class="meta-email" title={account.email}>{account.email}</span><span class="sep" aria-hidden="true">·</span>{/if}
                  {#each account.alsoIn ?? [] as harness (harness)}
                    <span class="harness" role="img" aria-label={`Also used in ${providerMeta[harness].name}`}><span class="harness-icon"><ProviderIcon provider={harness} size={13} bare /></span><span class="harness-tip">Also in {providerMeta[harness].name}</span></span>
                  {/each}
                  <span class="meta-text">{meta.name}{account.service ? ` · ${providerMeta[account.service].name}${account.plan ? ` ${planName(account.plan)}` : ''}` : account.plan ? ` · ${planName(account.plan)}` : ''}</span>
                </p>
              </div>
              {#if togglePin || openAccount}
                <div class="card-menu">
                  <button type="button" class="icon" aria-haspopup="menu" aria-expanded={menuFor === account.id} aria-label={`Options for ${name}`} title="Options"
                    onclick={() => { menuFor = menuFor === account.id ? null : account.id; }} onkeydown={(event) => { if (event.key === 'Escape') menuFor = null; }}>
                    <DotsThreeIcon size={20} weight="bold" />
                  </button>
                  {#if menuFor === account.id}
                    <div class="menu" role="menu" tabindex="-1" onfocusout={(event) => { if (!event.currentTarget.parentElement?.contains(event.relatedTarget as Node | null)) menuFor = null; }}
                      onkeydown={(event) => { if (event.key === 'Escape') menuFor = null; }}>
                      {#if togglePin}
                        <button type="button" role="menuitem" onclick={() => { togglePin(account.id); menuFor = null; }}>
                          <span class="menu-check"><PushPinIcon size={14} weight={pinned.includes(account.id) ? 'fill' : 'regular'} /></span>{pinned.includes(account.id) ? 'Unpin' : 'Pin'}
                        </button>
                      {/if}
                      {#if openAccount}
                        <button type="button" role="menuitem" onclick={() => { menuFor = null; openAccount(account.id); }}>
                          <span class="menu-check"><GearSixIcon size={14} /></span>Account settings
                        </button>
                      {/if}
                    </div>
                  {/if}
                </div>
              {/if}
            </header>

            <div class="body">
              {#if windowGroups(account)}
                <div class="tabs" role="tablist" aria-label="Limit group">
                  {#each windowGroups(account) ?? [] as group (group.id)}
                    <button type="button" role="tab" aria-selected={activeGroup(account)?.id === group.id} onclick={() => { windowGroup = { ...windowGroup, [account.id]: group.id }; }}>{group.label}</button>
                  {/each}
                </div>
              {/if}
              {#if account.windows.length}
                <ul class="windows" role="list">
                  {#each shownWindows(account) as window (historyWindowKey(window))}
                    {@const title = windowTitle(account, window)}
                    {@const pace = windowPace(window, now)}
                    {@const shown = displayPercent(window, percentMode)}
                    <li class="window">
                      <span class="w-title">{title}</span>
                      {#if shown.value === null}
                        <span class="meter" aria-hidden="true">{#each { length: SEGMENTS } as _}<i></i>{/each}</span>
                        <span class="value muted">Unknown</span>
                      {:else}
                        <span class="meter" role="meter" aria-valuemin="0" aria-valuemax="100" aria-valuenow={shown.value} aria-label={`${title}: ${percent(shown.value)} ${percentMode}`}>
                          {#each { length: SEGMENTS } as _, index}<i class={index < filled(shown.value) ? `on tone-${shown.tone}` : ''}></i>{/each}
                        </span>
                        <span class="value" title={shown.calculated ? `100% minus the provider-reported ${percentMode === 'used' ? 'remaining' : 'usage'}` : 'Provider-reported'}>{percent(shown.value)}<small>{percentMode === 'used' ? 'used' : 'left'}</small></span>
                      {/if}
                      <span class="w-meta">
                        {#if pace && pace.beforeReset && pace.exhaustsInMs > 0}
                          <span class="pace tone-bad" title="Estimate from the average rate since this window started"><TrendUpIcon size={13} weight="bold" />Runs out in {compactDuration(pace.exhaustsInMs)}</span>
                        {:else if pace && pace.exhaustsInMs === 0}
                          <span class="pace tone-bad">Limit reached</span>
                        {:else if pace}
                          <span class="pace" title="Estimate from the average rate since this window started">On pace · {Math.min(pace.projectedPercent, 100)}% by reset</span>
                        {/if}
                        <button type="button" class="reset" onclick={() => showResets(account, window)} title={exactTime(window.resetsAt)}>{windowResetText(window, now)}</button>
                      </span>
                    </li>
                  {/each}
                </ul>
              {/if}

              {#if trendSeries(account).length}
                {@const trend = trendSeries(account)}
                <div class="trend-block">
                  <span class="trend-label">Trend · last {compactDuration(now - Math.min(...trend.map((item) => item.points[0][0])))} · {percentMode}</span>
                  {#await loadTrend() then { default: UsageTrend }}
                    <UsageTrend series={trend} label={`${name} ${percentMode} trend`} remainingMode={percentMode === 'remaining'} />
                  {:catch}
                    <span class="trend-label">Trend chart unavailable.</span>
                  {/await}
                </div>
              {/if}



              {#if !account.windows.length && !account.spend && !account.balances?.length && !notices(account).length}
                <p class="placeholder">No usage windows reported.</p>
              {/if}

              {#if permission}<p class={`callout tone-${account.ordinaryUsageAllowed === false ? 'bad' : 'muted'}`}>{permission}</p>{/if}
              {#each account.limitAccess ?? [] as limit (limit.limitId)}
                {#if limit.rateLimitReachedType || limit.spendControlReached === true}
                  <p class="callout tone-bad">{limit.label}: {limit.rateLimitReachedType?.replaceAll('_', ' ') ?? 'limit reached'}{limit.spendControlReached === true ? ' · spend control reached' : ''}</p>
                {/if}
              {/each}
              {#each notices(account) as error (error.code)}
                {@const waiting = error.code === 'claude_awaiting_snapshot' || error.code === 'snapshot_read_failed'}
                {@const hint = waiting ? accountHint?.(account) ?? null : null}
                <div class={`callout tone-${waiting ? 'muted' : issueTone(account)}`}>
                  <span class="callout-icon">{#if waiting}<InfoIcon size={16} weight="bold" />{:else}<WarningIcon size={16} weight="bold" />{/if}</span>
                  <p>{!waiting ? error.message : hint?.message ?? `Quota appears after this account's status-line collector runs in ${meta.name}.`}</p>
                  {#if hint?.action}
                    <button type="button" class="link" onclick={hint.action.run} disabled={hint.action.busy}>{hint.action.label}<ArrowRightIcon size={14} weight="bold" /></button>
                  {:else if !hint && openAccount && (waiting || account.state === 'unauthorized')}
                    <button type="button" class="link" onclick={() => openAccount(account.id)}>{waiting ? 'Set up' : 'Fix'}<ArrowRightIcon size={14} weight="bold" /></button>
                  {/if}
                </div>
              {/each}
              <!-- Balances are the only data for accounts without usage windows (Amp), so they always show there. -->
              {#if (showCredits || !account.windows.length) && (account.spend || account.balances?.length)}
                <div class="money">
              {#if account.spend}
                <div class="spend">
                  <div>
                    <span class="w-title">{account.spend.label ?? 'On-demand spend this cycle'}</span>
                    <strong>{dollars(account.spend.used)}</strong>
                  </div>
                  {#if account.spend.used !== null && account.spend.limit}
                    {@const share = Math.min(100, account.spend.used / account.spend.limit * 100)}
                    <span class="meter" role="meter" aria-valuemin="0" aria-valuemax="100" aria-valuenow={share} aria-label={`${percent(share)} of spending cap`}>
                      {#each { length: SEGMENTS } as _, index}<i class={index < filled(share) ? `on tone-${usedTone(share)}` : ''}></i>{/each}
                    </span>
                  {/if}
                  <p>{account.spend.limit !== null ? `Limit ${dollars(account.spend.limit)}` : 'No limit reported'}{account.spend.includedUsed !== null ? ` · Included usage ${dollars(account.spend.includedUsed)}` : ''}{account.spend.periodStart ? ` · Cycle from ${exactTime(account.spend.periodStart)}` : ''}</p>
                </div>
              {/if}

              {#each account.balances ?? [] as balance (balance.label)}
                <p class="balance"><span>{balance.label}{#if creditValue(balance)}<small>{creditValue(balance)}</small>{/if}</span><strong>{amountText(balance)}</strong></p>
              {/each}
                </div>
              {/if}
            </div>

            <footer class="card-foot">
              <span class="foot-start">
                {#if pinned.includes(account.id)}<span class="pin-mark" title="Pinned" aria-label="Pinned"><PushPinIcon size={14} weight="fill" /></span>{/if}
                {#if badge.tone !== 'good'}<span class={`pill tone-${badge.tone}`}><i aria-hidden="true"></i>{badge.label}</span>{/if}
                {#if account.resetCredits}
                  <button type="button" class="reset" onclick={() => showResets(account)}>{account.resetCredits.availableCount} banked reset{account.resetCredits.availableCount === 1 ? '' : 's'}</button>
                {/if}
              </span>
              <time class:stale datetime={account.observedAt ?? undefined} title={account.observedAt ? `Refreshed ${exactTime(account.observedAt)} (${agoText(account.observedAt, now)}${stale ? ', older than 5 minutes' : ''})` : 'Not refreshed yet'}>
                <ClockCountdownIcon size={13} weight="bold" />{stamp(account.observedAt)}
              </time>
            </footer>
          </article>
        </li>
      {/each}
    </ul>
  {/if}

  <p class="footnote">Usage, limits, and reset times are reported by each provider; remaining is 100% minus used. Pace, run-out times, window start, and credit dollar values are estimates. Session tokens and context-window size are not subscription quota.</p>

  <dialog bind:this={resetDialog} class="resets" aria-labelledby="reset-title" onclose={() => { resetFocus = null; confirmReset = false; resetMessage = ''; }}
    onclick={(event) => { if (event.target === resetDialog) resetDialog?.close(); }}>
    {#if resetAccount}
      <div class="sheet">
        <header>
          <ProviderIcon provider={resetAccount.provider} size={34} />
          <div class="sheet-title">
            <h2 id="reset-title">Resets · {accountName(resetAccount)}</h2>
            <p>{providerMeta[resetAccount.provider].name}{resetAccount.plan ? ` · ${planName(resetAccount.plan)}` : ''}</p>
          </div>
          <button type="button" class="icon" onclick={() => resetDialog?.close()} aria-label="Close"><XIcon size={18} weight="bold" /></button>
        </header>
        {#each resetAccount.windows as window (historyWindowKey(window))}
          {@const details = resetDetails(window, now)}
          {@const pace = windowPace(window, now)}
          <section class="reset-window" class:focus={resetFocus?.key === historyWindowKey(window)}>
            <h3>{windowTitle(resetAccount, window)}</h3>
            <dl>
              <div><dt>Resets</dt><dd>{exactTime(details.resetsAt)}{details.remainingMs !== null ? ` · ${details.remainingMs > 0 ? `in ${compactDuration(details.remainingMs)}` : 'due'}` : ''}</dd></div>
              <div><dt>Window started</dt><dd>{details.windowStart ? exactTime(details.windowStart) : 'Unavailable'}</dd></div>
              <div class="wide"><dt>Usage</dt><dd>{window.usedPercent === null ? 'Unknown' : `${percent(window.usedPercent)} used · ${percent(window.remainingPercent ?? 100 - window.usedPercent)} left`}</dd></div>
              <div class="wide"><dt>At this pace</dt><dd>{!pace ? 'Not enough of the window has passed to estimate.' : pace.exhaustsInMs === 0 ? 'Limit reached.' : pace.beforeReset ? `Runs out in ${compactDuration(pace.exhaustsInMs)}, before the reset.` : `${Math.min(pace.projectedPercent, 100)}% used by the reset.`}</dd></div>
            </dl>
          </section>
        {:else}
          <p class="muted-text">This account has not reported any reset times.</p>
        {/each}
        {#if resetAccount.resetCredits}
          {@const upcoming = resetAccount.resetCredits.credits?.length ? nextCredit(resetAccount.resetCredits.credits) : null}
          <section class="reset-window">
            <h3>Banked resets</h3>
            <dl>
              <div><dt>Available</dt><dd>{resetAccount.resetCredits.availableCount}</dd></div>
              <div><dt>Earliest expiry</dt><dd>{resetAccount.resetCredits.earliestExpiry ? exactTime(resetAccount.resetCredits.earliestExpiry) : 'Not reported'}</dd></div>
            </dl>
            {#if resetAccount.resetCredits.credits?.length}
              <ul class="credits">
                {#each resetAccount.resetCredits.credits as credit, index (index)}
                  <li>
                    <strong>{credit.title ?? `Reset ${index + 1}`}{#if credit === nextCredit(resetAccount.resetCredits.credits)}<span class="next-tag">Used next</span>{/if}</strong>
                    <small>{credit.grantedAt ? `Granted ${exactTime(credit.grantedAt)}` : 'Grant date not reported'} · {credit.expiresAt ? `expires ${exactTime(credit.expiresAt)}` : 'no expiry'}</small>
                  </li>
                {/each}
              </ul>
            {/if}
            <div class="redeem">
              <p class="muted-text">A banked reset clears the current ChatGPT usage windows right away.{#if upcoming}{' '}Uses <strong>{upcoming.title ?? 'the next reset'}</strong>{upcoming.expiresAt ? `, which expires ${exactTime(upcoming.expiresAt)}` : ''}.{/if}</p>
              {#if redeemReset && resetAccount.resetCredits.availableCount > 0}
                {#if confirmReset}
                  <button type="button" class="ghost" onclick={() => { confirmReset = false; }}>Keep</button>
                  <button type="button" class="primary" disabled={redeeming} onclick={() => useReset(resetAccount!.id)}>{redeeming ? 'Resetting…' : 'Use 1 reset now'}</button>
                {:else}
                  <button type="button" class="primary" onclick={() => { confirmReset = true; resetMessage = ''; }}>Use a reset…</button>
                {/if}
              {/if}
            </div>
            {#if resetMessage}<p class="reset-message" role="status">{resetMessage}</p>{/if}
          </section>
        {/if}
        <p class="muted-text">Window start and pace are estimates from the reported reset time and window length.</p>
      </div>
    {/if}
  </dialog>

  <dialog bind:this={alertDialog} class="resets" aria-labelledby="alerts-title" onclick={(event) => { if (event.target === alertDialog) alertDialog?.close(); }}>
    <div class="sheet">
      <header>
        <div class="sheet-title">
          <h2 id="alerts-title">{alertKind === 'exhausted' ? 'Exhausted limits' : 'Running low'}</h2>
          <p>{alertKind === 'exhausted' ? 'No quota left until these windows reset.' : 'At least 85% of these windows is used.'}</p>
        </div>
        <button type="button" class="icon" onclick={() => alertDialog?.close()} aria-label="Close"><XIcon size={18} weight="bold" /></button>
      </header>
      <ul class="alert-list">
        {#each groupedAlerts(alertKind === 'exhausted' ? alerts.exhausted : alerts.low) as group (group.accountId)}
          <li class="alert-group">
            <button type="button" class="alert-account" onclick={() => jumpTo(group.accountId)} title="Show this account's card">
              <strong>{group.account}</strong><small>{group.provider} · {group.items.length} {group.items.length === 1 ? 'window' : 'windows'}</small>
            </button>
            <ul>
              {#each group.items as item (item.window)}
                <li>
                  <span>{item.window}</span>
                  <span class="alert-side"><b class={alertKind === 'exhausted' ? 'tone-bad' : 'tone-warn'}>{percent(Math.max(0, 100 - item.used))} left</b><small>{windowResetText({ usedPercent: item.used, resetsAt: item.resetsAt } as UsageWindow, now)}</small></span>
                </li>
              {/each}
            </ul>
          </li>
        {:else}
          <li class="muted-text">Nothing here right now.</li>
        {/each}
      </ul>
    </div>
  </dialog>
</section>

<style>
  .usage {
    --bg: #f5f4f0; --surface: #ffffff; --surface-2: #f0efe9; --line: #e3e1d9; --line-strong: #d3d0c5;
    --text: #17181a; --text-2: #5c5f63; --text-3: #8a8d91;
    --good: #2f9e5a; --warn: #c88c0a; --bad: #d6453d; --accent: #4b3ff2; --accent-ink: #ffffff;
    --good-bg: #e6f4ea; --warn-bg: #fbf1d9; --bad-bg: #fbe7e5; --muted-bg: #f2f1ec; --seg-off: #e7e5de;
    --trend-2: #d6862f; --trend-3: #2f9e8f; --trend-4: #a04fd6;
    --radius: 14px;
    font-family: var(--subset-font, 'Twenty One Native', ui-sans-serif, system-ui, sans-serif);
    color: var(--text); max-width: 1180px; margin: 0 auto; padding: 20px 20px 40px; box-sizing: border-box;
    -webkit-font-smoothing: antialiased; font-feature-settings: 'tnum' 1;
  }
  :global(html[data-theme='dark']) .usage {
    --bg: #141414; --surface: #1b1b1c; --surface-2: #222224; --line: #2a2a2d; --line-strong: #37373b;
    --text: #f2f2f0; --text-2: #a4a5a8; --text-3: #75767a;
    --good: #43c06f; --warn: #e9b23a; --bad: #f0645b; --accent: #5b4ff7;
    --good-bg: #183222; --warn-bg: #352a12; --bad-bg: #3a1c1a; --muted-bg: #222225; --seg-off: #2d2d31;
  }
  @media (prefers-color-scheme: dark) {
    :global(html:not([data-theme='light'])) .usage {
      --bg: #141414; --surface: #1b1b1c; --surface-2: #222224; --line: #2a2a2d; --line-strong: #37373b;
      --text: #f2f2f0; --text-2: #a4a5a8; --text-3: #75767a;
      --good: #43c06f; --warn: #e9b23a; --bad: #f0645b; --accent: #5b4ff7;
      --good-bg: #183222; --warn-bg: #352a12; --bad-bg: #3a1c1a; --muted-bg: #222225; --seg-off: #2d2d31;
    }
  }
  .usage *, .usage *::before, .usage *::after { box-sizing: border-box; }
  h1, h2, h3, p, dl, dd, ul { margin: 0; padding: 0; }
  ul { list-style: none; }
  button { font: inherit; color: inherit; cursor: pointer; }
  button:disabled { cursor: progress; opacity: .65; }
  button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

  .bar { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; padding: 6px 0 18px; border-bottom: 1px solid var(--line); }
  .brand { display: flex; align-items: center; gap: 10px; }
  .brand h1 { font-size: 1.35rem; font-weight: 600; letter-spacing: -.02em; }
  .count { font-size: .78rem; font-weight: 500; color: var(--text-2); background: var(--surface-2); border: 1px solid var(--line); border-radius: 99px; padding: 1px 8px; }
  .logo { display: inline-flex; align-items: flex-end; gap: 3px; height: 20px; }
  .logo i { width: 5px; border-radius: 2px; background: var(--accent); }
  .logo i:nth-child(1) { height: 45%; } .logo i:nth-child(2) { height: 100%; } .logo i:nth-child(3) { height: 70%; }
  .logo.large { height: 40px; gap: 5px; } .logo.large i { width: 10px; border-radius: 3px; }
  .actions { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .synced { font-size: .82rem; color: var(--text-3); margin-right: 4px; }
  .ghost { display: inline-flex; align-items: center; gap: 7px; height: 36px; padding: 0 14px; border-radius: 10px; border: 1px solid var(--line-strong); background: var(--surface); font-size: .9rem; font-weight: 500; }
  .ghost:hover:not(:disabled) { background: var(--surface-2); }
  .primary { height: 36px; padding: 0 14px; border-radius: 10px; border: 1px solid transparent; background: var(--accent); color: var(--accent-ink); font-size: .9rem; font-weight: 500; }
  .i { display: inline-flex; }
  .spin { animation: spin 0.9s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) { .spin { animation: none; } }

  .summary { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; margin: 20px 0 16px; }
  .summary > div { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: 14px 16px; min-width: 0; }
  .summary dt { display: flex; align-items: center; gap: 6px; font-size: .78rem; color: var(--text-3); text-transform: uppercase; letter-spacing: .08em; font-weight: 500; }
  .summary dd { font-size: 1.6rem; font-weight: 600; letter-spacing: -.02em; margin-top: 6px; display: flex; flex-direction: column; }
  .summary dd span { font-size: .82rem; font-weight: 400; letter-spacing: 0; color: var(--text-2); margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  /* Cards in a row share a height; the footer stays at the bottom. */
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 14px; align-items: stretch; }
  .grid > li { display: flex; min-width: 0; }
  .card { flex: 1; min-width: 0; background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: 18px; display: flex; flex-direction: column; gap: 14px; }
  .card.issue { border-color: color-mix(in srgb, var(--bad) 45%, var(--line)); }
  .card-head { display: flex; align-items: flex-start; gap: 12px; padding-bottom: 14px; border-bottom: 1px solid var(--line); }
  .who { min-width: 0; flex: 1; }
  .name-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .card h2 { font-size: 1.02rem; font-weight: 600; letter-spacing: -.01em; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .name-row { flex-wrap: nowrap; }
  .tag { flex: none; font-size: .72rem; font-weight: 500; padding: 1px 8px; border-radius: 6px; border: 1px solid var(--line-strong); color: var(--text-2); background: var(--surface-2); }
  .foot-start { display: inline-flex; align-items: center; gap: 10px; min-width: 0; flex-wrap: wrap; }
  .who p { font-size: .85rem; color: var(--text-2); margin-top: 2px; }
  .pill { display: inline-flex; align-items: center; gap: 6px; font-size: .75rem; font-weight: 500; padding: 2px 9px 2px 8px; border-radius: 99px; background: var(--muted-bg); color: var(--text-2); white-space: nowrap; }
  .pill i { width: 6px; height: 6px; border-radius: 50%; background: currentColor; }
  .pill.tone-good { background: var(--good-bg); color: var(--good); }
  .pill.tone-warn { background: var(--warn-bg); color: var(--warn); }
  .pill.tone-bad { background: var(--bad-bg); color: var(--bad); }
  .card-head .icon { margin-top: 2px; }
  .icon { flex: none; width: 32px; height: 32px; border-radius: 8px; border: 1px solid transparent; background: transparent; display: grid; place-items: center; color: var(--text-3); }
  .icon:hover { background: var(--surface-2); color: var(--text); }
  .body { display: flex; flex-direction: column; gap: 14px; flex: 1; }

  .windows { display: grid; gap: 14px; }
  .window { display: grid; grid-template-columns: minmax(0, 1fr) auto; grid-template-areas: 'title value' 'meter meter' 'meta meta'; align-items: baseline; column-gap: 12px; row-gap: 6px; }
  .w-title { grid-area: title; font-size: .92rem; color: var(--text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .meter { grid-area: meter; display: grid; grid-template-columns: repeat(20, minmax(0, 1fr)); gap: 3px; height: 16px; padding: 3px; border-radius: 6px; background: var(--surface-2); border: 1px solid var(--line); }
  .spend .meter { width: 100%; grid-area: auto; }
  .meter i { border-radius: 1.5px; background: var(--seg-off); }
  .meter i.on.tone-good { background: var(--good); } .meter i.on.tone-warn { background: var(--warn); } .meter i.on.tone-bad { background: var(--bad); }
  .value { grid-area: value; text-align: right; font-weight: 600; font-size: .95rem; white-space: nowrap; }
  .value small { font-size: .7rem; font-weight: 400; color: var(--text-3); margin-left: 3px; }
  .value.muted { color: var(--text-3); font-weight: 400; font-size: .85rem; }
  .w-meta { grid-area: meta; display: flex; justify-content: space-between; align-items: center; gap: 12px; font-size: .78rem; color: var(--text-3); }
  .w-meta > :last-child { margin-left: auto; }
  .pace { display: inline-flex; align-items: center; gap: 4px; color: var(--text-3); }
  .pace.tone-bad { color: var(--bad); }
  .reset { border: 0; background: none; padding: 0; color: var(--text-3); font-size: .78rem; text-decoration: underline dotted; text-underline-offset: 3px; }
  .reset:hover { color: var(--text); }
  .trend-block { display: grid; gap: 2px; }
  .filter-bar { display: flex; align-items: center; gap: 10px; margin-top: 18px; }
  /* Chips scroll sideways instead of wrapping; the sort button stays in view. */
  .filters { display: flex; flex-wrap: nowrap; gap: 8px; overflow-x: auto; min-width: 0; flex: 1; scrollbar-width: none; }
  .filters::-webkit-scrollbar { display: none; }
  .filters .chip { flex: none; }
  .chip { display: inline-flex; align-items: center; gap: 7px; height: 34px; padding: 0 12px; border-radius: 99px; border: 1px solid var(--line); background: var(--surface); color: var(--text-2); font-size: .86rem; font-weight: 500; }
  .chip span { font-size: .76rem; color: var(--text-3); }
  .chip:hover { border-color: var(--line-strong); color: var(--text); }
  .chip[aria-pressed='true'] { background: var(--text); border-color: var(--text); color: var(--bg); }
  .chip[aria-pressed='true'] span { color: color-mix(in srgb, var(--bg) 70%, transparent); }
  .chip[aria-pressed='true'] :global(.provider-icon) { color: var(--bg); }
  .trend-label { font-size: .74rem; color: var(--text-3); text-transform: uppercase; letter-spacing: .07em; }

  .spend { display: grid; gap: 8px; }
  .spend > div { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; }
  .spend strong { font-size: 1.35rem; font-weight: 600; }
  .spend p { font-size: .8rem; color: var(--text-2); }
  .placeholder { font-size: .88rem; color: var(--text-3); }
  .balance { display: flex; justify-content: space-between; align-items: baseline; font-size: .86rem; color: var(--text-2); }
  .balance strong { color: var(--text); font-weight: 600; }
  .balance > span { display: grid; gap: 1px; }
  .balance small { font-size: .74rem; color: var(--text-3); }

  .callout { display: flex; align-items: flex-start; gap: 10px; font-size: .84rem; line-height: 1.45; padding: 10px 12px; border-radius: 10px; background: var(--muted-bg); color: var(--text-2); }
  .callout p { flex: 1; }
  .callout-icon { flex: none; display: inline-flex; margin-top: 2px; color: var(--text-3); }
  .callout.tone-bad { background: var(--bad-bg); color: var(--bad); }
  .callout.tone-bad .callout-icon, .callout.tone-warn .callout-icon { color: inherit; }
  .callout.tone-warn { background: var(--warn-bg); color: color-mix(in srgb, var(--warn) 70%, var(--text)); }
  .link { flex: none; display: inline-flex; align-items: center; gap: 4px; border: 0; background: none; padding: 0; font-weight: 600; color: var(--accent); white-space: nowrap; align-self: center; }
  :global(html[data-theme='dark']) .link { color: #9d95ff; }
  @media (prefers-color-scheme: dark) { :global(html:not([data-theme='light'])) .link { color: #9d95ff; } }
  .link:hover { text-decoration: underline; }

  .card-foot { display: flex; justify-content: space-between; align-items: center; gap: 12px; font-size: .78rem; color: var(--text-3); padding-top: 12px; border-top: 1px solid var(--line); margin-top: auto; }
  .card-foot time { display: inline-flex; align-items: center; gap: 5px; }
  .card-foot time.stale { color: var(--warn); }

  .empty { text-align: center; padding: 64px 24px; margin-top: 20px; border: 1px dashed var(--line-strong); border-radius: var(--radius); display: grid; justify-items: center; gap: 12px; }
  .empty h2 { font-size: 1.3rem; font-weight: 600; }
  .empty p { color: var(--text-2); max-width: 440px; line-height: 1.5; }
  .footnote { margin-top: 24px; font-size: .78rem; color: var(--text-3); line-height: 1.5; }

  .resets { width: min(560px, calc(100vw - 24px)); max-height: calc(100vh - 48px); padding: 0; border: 1px solid var(--line); border-radius: 18px; background: var(--surface); color: var(--text); box-shadow: 0 24px 64px rgb(0 0 0 / .22); }
  .resets::backdrop { background: rgb(10 10 12 / .45); backdrop-filter: blur(2px); }
  .sheet { display: grid; gap: 16px; padding: 22px; }
  .sheet > header { display: flex; align-items: center; gap: 12px; }
  .sheet-title { flex: 1; min-width: 0; }
  .sheet h2 { font-size: 1.15rem; font-weight: 600; }
  .sheet-title p { font-size: .85rem; color: var(--text-2); margin-top: 2px; }
  .reset-window { border: 1px solid var(--line); border-radius: 12px; overflow: hidden; }
  .reset-window.focus { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
  .reset-window h3 { font-size: .92rem; font-weight: 600; padding: 10px 12px; background: var(--surface-2); border-bottom: 1px solid var(--line); }
  .reset-window dl { display: grid; grid-template-columns: 1fr 1fr; gap: 1px; background: var(--line); }
  .reset-window dl div { background: var(--surface); padding: 9px 12px; min-width: 0; }
  .reset-window dl .wide { grid-column: 1 / -1; }
  .reset-window dt { font-size: .72rem; color: var(--text-3); text-transform: uppercase; letter-spacing: .07em; }
  .reset-window dd { font-size: .88rem; margin-top: 2px; overflow-wrap: anywhere; }
  .reset-window .muted-text { padding: 10px 12px; }
  .muted-text { font-size: .8rem; color: var(--text-3); line-height: 1.5; }
  .credits { display: grid; border-top: 1px solid var(--line); }
  .credits li { display: grid; gap: 2px; padding: 9px 12px; border-bottom: 1px solid var(--line); font-size: .86rem; }
  .credits strong { display: flex; align-items: center; gap: 8px; }
  .next-tag { font-size: .7rem; font-weight: 500; padding: 1px 7px; border-radius: 6px; background: color-mix(in srgb, var(--accent) 12%, var(--surface)); color: var(--accent); }
  .redeem .muted-text strong { color: var(--text-2); font-weight: 600; }
  .icon.pinned { color: var(--accent); }
  .sort { position: relative; flex: none; }
  .menu-heading { padding: 8px 10px 4px; font-size: .7rem; font-weight: 600; text-transform: uppercase; letter-spacing: .08em; color: var(--text-3); }
  .tabs { display: inline-flex; align-self: flex-start; gap: 2px; padding: 3px; border-radius: 9px; background: var(--surface-2); border: 1px solid var(--line); }
  .tabs button { height: 26px; padding: 0 12px; border: 0; border-radius: 6px; background: transparent; color: var(--text-2); font-size: .8rem; font-weight: 500; }
  .tabs button[aria-selected='true'] { background: var(--surface); color: var(--text); box-shadow: 0 1px 2px rgb(0 0 0 / .08); }
  .tabs { align-self: center; }
  .summary dd.resets-dd { display: grid; gap: 0; margin-top: 6px; font-size: inherit; letter-spacing: 0; }
  /* Timeline: countdown, a dot on a connecting rail, then the exact time and account. */
  .reset-row { display: grid; grid-template-columns: 7.5ch 12px minmax(0, 1fr); align-items: center; gap: 10px; width: 100%; padding: 6px 8px; margin: 0 -8px; border: 0; border-radius: 10px; background: none; text-align: left; cursor: pointer; }
  .reset-row:hover { background: var(--surface-2); }
  .rail { position: relative; z-index: 1; align-self: stretch; display: grid; place-items: center; }
  .summary dd.resets-dd { position: relative; }
  .timeline-line { position: absolute; width: 2px; background: var(--line-strong); margin: 0 !important; pointer-events: none; }
  .rail i { position: relative; width: 10px; height: 10px; border-radius: 50%; background: var(--surface); border: 2px solid var(--accent); }
  .reset-row:first-of-type .rail i { background: var(--accent); }
  .summary dd .reset-text time { font-weight: 600; color: var(--text); }
  .reset-row strong { font-size: .98rem; font-weight: 600; color: var(--text); white-space: nowrap; font-variant-numeric: tabular-nums; }
  .summary dd .reset-text { display: grid; min-width: 0; margin: 0; overflow: hidden; }
  .summary dd .reset-text > span { font-size: .82rem; color: var(--text); margin: 0; }
  .summary dd .reset-text small { font-size: .72rem; color: var(--text-3); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .summary dd .none-text { font-size: .82rem; color: var(--text-3); }
  .summary dd.limits-dd { display: grid; gap: 6px; margin-top: 8px; font-size: inherit; letter-spacing: 0; }
  /* Fixed first columns keep the text aligned whatever the number's width. */
  .limit-row { display: grid; grid-template-columns: 3ch minmax(0, 1fr); align-items: center; gap: 12px; width: 100%; padding: 6px 8px; margin: 0 -8px; border: 0; border-radius: 10px; background: none; text-align: left; cursor: pointer; }
  .limit-row:hover:not(:disabled) { background: var(--surface-2); }
  .limit-row:disabled { cursor: default; opacity: 1; }
  .limit-row strong { font-size: 1.7rem; font-weight: 600; line-height: 1; text-align: center; color: var(--text-3); font-variant-numeric: tabular-nums; }
  .limit-row.exhausted:not(:disabled) strong { color: var(--bad); }
  .limit-row.low:not(:disabled) strong { color: var(--warn); }
  .summary dd .limit-text { display: grid; min-width: 0; margin: 0; overflow: visible; }
  .summary dd .limit-label { font-size: .85rem; font-weight: 600; color: var(--text); margin: 0; display: flex; gap: 6px; align-items: baseline; }
  .summary dd .limit-label small { font-size: .72rem; font-weight: 400; color: var(--text-3); }
  .summary dd .limit-names { font-size: .76rem; margin: 0; color: var(--text-2); }
  .alert-list { display: grid; gap: 8px; max-height: 60vh; overflow: auto; }
  .alert-group { border: 1px solid var(--line); border-radius: 12px; overflow: hidden; }
  .alert-group ul { display: grid; }
  .alert-group li { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 9px 12px; border-top: 1px solid var(--line); font-size: .86rem; }
  .alert-list .alert-account { display: grid; gap: 2px; width: 100%; padding: 10px 12px; border: 0; border-radius: 0; background: var(--surface-2); text-align: left; }
  .alert-list .alert-account:hover { background: color-mix(in srgb, var(--surface-2) 70%, var(--line)); }
  .alert-list span { display: grid; gap: 2px; min-width: 0; }
  .alert-list strong { font-size: .9rem; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .alert-list small { font-size: .76rem; color: var(--text-3); }
  .alert-side { text-align: right; flex: none; }
  .alert-side b { font-size: .9rem; }
  .alert-side .tone-bad { color: var(--bad); } .alert-side .tone-warn { color: var(--warn); }
  :global(.card.flash) { box-shadow: 0 0 0 2px var(--accent); transition: box-shadow .3s; }
  .dt-aside { margin-left: auto; text-transform: none; letter-spacing: 0; font-weight: 400; font-size: .76rem; }
  .summary dd.activity-dd { gap: 8px; font-size: inherit; margin-top: 8px; }
  .heatmap { display: grid; grid-template-columns: auto repeat(7, minmax(0, 1fr)); gap: 3px; align-items: center; margin: 0 !important; overflow: visible !important; }
  .summary dd .hm-label { font-size: .62rem !important; color: var(--text-3); margin: 0 !important; white-space: nowrap; padding-right: 4px; overflow: visible !important; }
  .summary dd .hm-day { text-align: center; padding: 0; }
  .hm-cell { height: 100%; min-height: 10px; padding: 0; border: 0; border-radius: 3px; cursor: default; background: color-mix(in srgb, var(--accent) calc(var(--level) * 100%), var(--seg-off)); }
  .hm-cell.on, .hm-cell:focus-visible { outline: 2px solid var(--text-2); outline-offset: 1px; }
  .activity-card { position: relative; display: flex; flex-direction: column; }
  .summary dd.activity-dd { flex: 1; display: flex; flex-direction: column; }
  .activity-dd .heatmap { flex: 1; grid-template-rows: auto repeat(4, minmax(10px, 1fr)); align-items: stretch; }
  .activity-dd .hm-label:not(.hm-day) { align-self: center; }
  .summary dd .hm-tip { position: absolute; left: 12px; right: 12px; top: calc(100% - 6px); z-index: 6; display: grid; gap: 3px; padding: 10px 12px; margin: 0; border-radius: 10px; border: 1px solid var(--line); background: var(--surface);
    box-shadow: 0 12px 28px rgb(0 0 0 / .14); font-size: .78rem; font-weight: 400; letter-spacing: 0; color: var(--text-2); white-space: normal; overflow: visible; }
  .summary dd .hm-tip span { margin: 0; white-space: normal; overflow: visible; font-size: .78rem; }
  .hm-tip strong { color: var(--text); font-weight: 600; font-size: .8rem; }
  .summary dd .hm-tip .hm-row { display: flex; justify-content: space-between; gap: 10px; }
  .hm-row em { font-style: normal; color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .summary dd .activity-empty { font-size: .76rem; color: var(--text-3); margin: 0; white-space: normal; }
  .meta-row { display: flex; align-items: center; gap: 6px; min-width: 0; }
  .meta-text { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .meta-email { min-width: 0; flex: 0 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sep { flex: none; }
  .meta-text { flex: 0 0 auto; }
  /* Opacity sits on the icon only, so the tooltip stays fully opaque. */
  .harness { position: relative; display: inline-flex; flex: none; }
  .harness-icon { display: inline-flex; opacity: .85; }
  .harness-tip { position: absolute; bottom: calc(100% + 6px); left: 50%; transform: translateX(-50%); padding: 4px 8px; border-radius: 6px; background: var(--text); color: var(--bg); font-size: .72rem; white-space: nowrap; visibility: hidden; pointer-events: none; z-index: 5; box-shadow: 0 4px 12px rgb(0 0 0 / .2); }
  .harness:hover .harness-tip { visibility: visible; }
  .card-menu { position: relative; flex: none; }
  .card-menu .menu { min-width: 190px; }
  .pin-mark { display: inline-flex; color: var(--text-3); }
  .money { margin-top: auto; display: grid; gap: 12px; padding-top: 4px; }
  .sort-button { width: 34px; height: 34px; border-radius: 99px; border: 1px solid var(--line); background: var(--surface); color: var(--text-2); display: grid; place-items: center; }
  .sort-button:hover, .sort-button.active { color: var(--text); border-color: var(--line-strong); }
  .menu { position: absolute; right: 0; top: calc(100% + 6px); z-index: 4; min-width: 210px; padding: 4px; border-radius: 12px; border: 1px solid var(--line); background: var(--surface); box-shadow: 0 12px 32px rgb(0 0 0 / .14); display: grid; }
  .menu button { display: flex; align-items: center; gap: 8px; padding: 8px 10px; border: 0; border-radius: 8px; background: none; text-align: left; font-size: .88rem; }
  .menu button:hover, .menu button:focus-visible { background: var(--surface-2); }
  .menu-check { width: 14px; display: inline-flex; color: var(--text-3); }
  .credits small { color: var(--text-3); font-size: .76rem; }
  .redeem { display: flex; align-items: center; justify-content: flex-end; gap: 8px; flex-wrap: wrap; padding: 10px 12px; }
  .redeem .muted-text { flex: 1 1 220px; padding: 0; }
  .reset-message { margin: 0 12px 12px; padding: 9px 12px; border-radius: 10px; background: var(--muted-bg); font-size: .85rem; color: var(--text); }
  .skeleton { margin-top: 20px; display: grid; gap: 16px; }
  .sk-summary { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
  .sk-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 14px; }
  .sk-block { height: 92px; border-radius: var(--radius); background: var(--surface); border: 1px solid var(--line); }
  .sk-card { display: grid; gap: 14px; padding: 18px; border-radius: var(--radius); background: var(--surface); border: 1px solid var(--line); }
  .sk-line, .sk-bar, .sk-block { position: relative; overflow: hidden; }
  .sk-line { height: 12px; border-radius: 6px; background: var(--surface-2); }
  .sk-bar { height: 16px; border-radius: 6px; background: var(--surface-2); }
  .w40 { width: 40%; } .w55 { width: 55%; } .w70 { width: 70%; }
  .sk-line::after, .sk-bar::after, .sk-block::after { content: ''; position: absolute; inset: 0; background: linear-gradient(90deg, transparent, color-mix(in srgb, var(--text) 6%, transparent), transparent); transform: translateX(-100%); animation: shimmer 1.4s infinite; }
  @keyframes shimmer { to { transform: translateX(100%); } }
  @media (prefers-reduced-motion: reduce) { .sk-line::after, .sk-bar::after, .sk-block::after { animation: none; } }

  @media (max-width: 720px) {
    .usage { padding: 14px 14px 32px; }
    .summary { grid-template-columns: 1fr; }
    .grid { grid-template-columns: 1fr; }
    .sk-summary, .sk-grid { grid-template-columns: 1fr; }
    .synced { width: 100%; order: 3; }
    .reset-window dl { grid-template-columns: 1fr; }
  }
</style>
