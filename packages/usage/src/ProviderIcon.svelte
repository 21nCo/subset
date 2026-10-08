<script lang="ts" module>
  let instance = 0;
</script>

<script lang="ts">
  import PiIcon from 'phosphor-svelte/lib/PiIcon';
  import RobotIcon from 'phosphor-svelte/lib/RobotIcon';
  import type { UsageProvider } from './index.js';
  import { providerLogos } from './provider-logos.js';

  /** `bare` renders only the logo, without the tile. */
  let { provider, size = 38, bare = false }: { provider: UsageProvider; size?: number; bare?: boolean } = $props();

  // Inline SVG IDs are document-global, so each rendered logo gets its own.
  const suffix = `-p${++instance}`;
  const logo = $derived(providerLogos[provider]);
  const body = $derived(logo ? logo.body.replace(/\bid="([^"]+)"/g, `id="$1${suffix}"`).replace(/url\(#([^)]+)\)/g, `url(#$1${suffix})`).replace(/href="#([^"]+)"/g, `href="#$1${suffix}"`) : '');
</script>

<span class="provider-icon" class:bare class:full={logo?.fullBleed && !bare} style={`--size:${size}px`} aria-hidden="true">
  {#if logo}
    {@const scale = bare || logo.fullBleed ? 1 : 0.52}
    <svg viewBox={logo.viewBox} width={Math.round(size * scale)} height={Math.round(size * scale)} focusable="false">{@html body}</svg>
  {:else}
    {#if provider === 'pi'}<PiIcon size={Math.round(size * (bare ? 1 : 0.55))} weight="bold" />{:else}<RobotIcon size={Math.round(size * (bare ? 1 : 0.55))} weight="bold" />{/if}
  {/if}
</span>

<style>
  .provider-icon { flex: none; width: var(--size); height: var(--size); border-radius: calc(var(--size) * .27); display: grid; place-items: center; border: 1px solid var(--line, #e3e1d9); background: var(--surface-2, #f0efe9); color: var(--text, #17181a); }
  .full { overflow: hidden; border-color: transparent; }
  .bare.full svg, .bare svg { border-radius: 3px; }
  .bare { width: auto; height: auto; border: 0; border-radius: 0; background: none; }
  svg { display: block; }
</style>
