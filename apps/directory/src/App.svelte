<script lang="ts">
  import { capabilities } from '@subset/catalog';
  import type { Surface } from '@subset/catalog';

  const surfaceLabels: Record<Surface, string> = {
    web: 'web',
    macos: 'macOS',
    ios: 'iOS',
    embed: 'embedded view',
    'agent-cli': 'agent CLI/skill',
    'agent-view': 'agent view'
  };
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
          <h2 id="catalog-heading" class="text-2xl font-semibold tracking-tight">In the works</h2>
          <p class="text-sm text-[#667168]">Pilots are in development</p>
        </div>
        <div class="grid gap-4 md:grid-cols-2">
          {#each capabilities as capability (capability.id)}
            <article class="flex min-h-60 flex-col rounded-2xl border border-[#d7dbd4] bg-white p-7 shadow-[0_8px_30px_rgba(23,41,25,0.03)]">
              <span class="mb-auto w-fit rounded-full bg-[#eaf0e8] px-3 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-[#45684c]">{capability.state}</span>
              <h3 class="mt-10 text-2xl font-semibold tracking-tight">{capability.name}</h3>
              <p class="mt-3 max-w-md leading-7 text-[#5b665e]">{capability.summary}</p>
              <p class="mt-6 text-sm text-[#6c786f]">Proposed: {capability.proposedSurfaces.map((surface) => surfaceLabels[surface]).join(' · ')}</p>
            </article>
          {/each}
        </div>
      </section>
    </main>

    <footer class="border-t border-[#d4d8d0] py-7 text-sm text-[#667168]">Subset is a 21n project. No apps are available for download yet.</footer>
  </div>
</div>
