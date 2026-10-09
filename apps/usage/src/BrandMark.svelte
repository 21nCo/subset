<script lang="ts">
  // The Usage mark from the usage landing page (21n subset-landing/usage BrandMark): stacked
  // account meters at three levels on a 12x8 pixel grid. The top meter follows the text colour
  // so the mark reads in both themes; the landing page uses #ecece7 on its dark background.
  let { size = 24 }: { size?: number } = $props();
</script>

<svg class="brand-mark" width={size} height={(size * 8) / 12} viewBox="0 0 12 8" shape-rendering="crispEdges" aria-hidden="true">
  <rect x="0" y="0" width="4" height="2" fill="currentColor" />
  <rect x="5" y="0" width="7" height="2" fill="currentColor" />
  <rect x="0" y="3" width="3" height="2" fill="#6b6bff" />
  <rect x="4" y="3" width="6" height="2" fill="#6b6bff" />
  <rect x="0" y="6" width="2" height="2" fill="#c6f36b" />
  <rect x="3" y="6" width="4" height="2" fill="#c6f36b" />
</svg>
