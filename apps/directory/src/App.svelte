<script lang="ts">
  import { capabilities } from '@subset/catalog';
  import type { CapabilityListing, Surface } from '@subset/catalog';

  const surfaceLabels: Record<Surface, string> = {
    web: 'web',
    macos: 'macOS',
    ios: 'iOS',
    embed: 'embedded view',
    'agent-cli': 'agent CLI/skill',
    'agent-view': 'agent view'
  };

  // Surfaces still in progress: proposed surfaces that have no verified release yet.
  const pendingSurfaces = (capability: CapabilityListing) =>
    capability.proposedSurfaces.filter((surface) => !capability.availableSurfaces.some((release) => release.surface === surface));

  const anyAvailable = capabilities.some((capability: CapabilityListing) => capability.availableSurfaces.length > 0);
</script>

<svelte:head>
  <meta name="theme-color" content="#f4f3ef" />
</svelte:head>

<div class="min-h-screen bg-[#f4f3ef] text-[#1d2420]">
  <div class="mx-auto max-w-6xl px-6 py-8 md:px-10">
    <header class="flex items-center justify-between border-b border-[#d4d8d0] pb-6">
      <a class="text-xl font-semibold tracking-tight" href="/">subset<span class="text-[#52775b]">.</span></a>
      <span class="rounded-full border border-[#c9d0c5] px-3 py-1 text-xs font-medium uppercase tracking-[0.16em] text-[#4b6551]">Early preview</span>
    </header>

    <main>
      <section class="max-w-3xl pb-16 pt-20 md:pb-24 md:pt-28">
        <p class="mb-5 text-sm font-semibold uppercase tracking-[0.22em] text-[#52775b]">Focused tools, built to travel</p>
        <h1 class="text-5xl font-semibold leading-[1.05] tracking-[-0.055em] md:text-7xl">Small apps.<br />Useful everywhere.</h1>
        <p class="mt-7 max-w-2xl text-lg leading-8 text-[#57635b]">Subset makes focused apps that stand on their own and can also work inside larger products and agent interfaces.</p>
      </section>

      <section aria-labelledby="catalog-heading" class="pb-24">
        <div class="mb-7 flex items-end justify-between gap-4 border-b border-[#d4d8d0] pb-4">
          <h2 id="catalog-heading" class="text-2xl font-semibold tracking-tight">{anyAvailable ? 'Apps' : 'In the works'}</h2>
          <p class="text-sm text-[#667168]">{anyAvailable ? 'Downloads link to verified releases' : 'Pilots are in development'}</p>
        </div>
        <div class="grid gap-4 md:grid-cols-2">
          {#each capabilities as capability (capability.id)}
            <article class="flex min-h-60 flex-col rounded-2xl border border-[#d7dbd4] bg-white p-7 shadow-[0_8px_30px_rgba(23,41,25,0.03)]">
              <span class="mb-auto w-fit rounded-full bg-[#eaf0e8] px-3 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-[#45684c]">{capability.state}</span>
              <h3 class="mt-10 text-2xl font-semibold tracking-tight">{capability.name}</h3>
              <p class="mt-3 max-w-md leading-7 text-[#5b665e]">{capability.summary}</p>
              {#if capability.availableSurfaces.length > 0}
                <ul class="mt-6 space-y-2" aria-label="Available for {capability.name}">
                  {#each capability.availableSurfaces as release (release.surface)}
                    <li class="flex flex-wrap items-baseline gap-x-3 gap-y-1 text-sm">
                      <a class="rounded-full bg-[#1d2420] px-4 py-2 font-semibold text-white hover:bg-[#33413a] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#52775b]" href={release.url}>Download {capability.name} for {surfaceLabels[release.surface]}</a>
                      <span class="text-[#5b665e]">v{release.version}{release.requirements ? ` · ${release.requirements}` : ''}</span>
                      <a class="text-[#45684c] underline underline-offset-2 hover:text-[#1d2420]" href={release.releaseUrl}>Release notes and checksums<span class="sr-only"> for {capability.name} {release.version} on {surfaceLabels[release.surface]}</span></a>
                    </li>
                  {/each}
                </ul>
              {/if}
              {#if pendingSurfaces(capability).length > 0}
                <p class="mt-6 text-sm text-[#6c786f]">{capability.availableSurfaces.length > 0 ? 'Also proposed' : 'Proposed'}: {pendingSurfaces(capability).map((surface) => surfaceLabels[surface]).join(' · ')}</p>
              {/if}
            </article>
          {/each}
        </div>
      </section>
    </main>

    <footer class="border-t border-[#d4d8d0] py-7 text-sm text-[#667168]">Subset is a 21n project.{anyAvailable ? '' : ' No apps are available for download yet.'}</footer>
  </div>
</div>
