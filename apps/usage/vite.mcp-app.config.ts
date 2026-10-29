// The MCP App build (SET-105): mcp-app.html as one self-contained file, every script and style inlined,
// including the lazily loaded ECharts trend chunk, written to dist/mcp-app/dashboard.html. The
// @subset.dev/usage build copies it to packages/usage-cli/mcp-app/ for `subset-usage mcp` to serve as a
// ui:// resource. The host's iframe has no origin to load assets from, so nothing may stay a separate file.
import { defineConfig, type Plugin } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

/** Replaces the entry's script and stylesheet tags with their code and emits only dashboard.html. */
function singleFile(): Plugin {
  return {
    name: 'subset-usage-single-file',
    enforce: 'post',
    // After Vite's own generateBundle, which fills in the dynamic import's `__VITE_PRELOAD__` list.
    generateBundle: {
      order: 'post',
      handler(_options, bundle) {
        const page = bundle['mcp-app.html'];
        if (!page || page.type !== 'asset') throw new Error('The MCP App build produced no mcp-app.html.');
        let html = String(page.source);
        for (const [fileName, file] of Object.entries(bundle)) {
          if (fileName === 'mcp-app.html') continue;
          const escaped = fileName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
          if (file.type === 'chunk') {
            // A script's text ends at the first `</script`, so none may appear inside it.
            const code = file.code.replace(/<\/(script)/gi, '<\\/$1');
            html = html.replace(new RegExp(`<script type="module" crossorigin src="/${escaped}"></script>`), () => `<script type="module">${code}</script>`);
          } else if (fileName.endsWith('.css')) {
            html = html.replace(new RegExp(`<link rel="stylesheet" crossorigin href="/${escaped}">`), () => `<style>${String(file.source)}</style>`);
          } else {
            throw new Error(`The MCP App build emitted ${fileName}, which cannot be inlined.`);
          }
          delete bundle[fileName];
        }
        if (/<script[^>]*\ssrc=|<link[^>]*\shref=/i.test(html)) throw new Error('The MCP App HTML still loads a file.');
        if (/\bimport\s*\(|__VITE_[A-Z_]+__/.test(html)) throw new Error('The MCP App HTML still has a dynamic import or a Vite placeholder.');
        delete bundle['mcp-app.html'];
        this.emitFile({ type: 'asset', fileName: 'dashboard.html', source: html });
      }
    }
  };
}

export default defineConfig({
  plugins: [svelte(), singleFile()],
  // public/ holds the web page's icons, which the MCP App does not use.
  publicDir: false,
  build: {
    // Inside dist/, which the main build empties first; the @subset.dev/usage build leaves it out of web/.
    outDir: 'dist/mcp-app',
    emptyOutDir: true,
    assetsInlineLimit: Number.MAX_SAFE_INTEGER,
    cssCodeSplit: false,
    modulePreload: false,
    rollupOptions: {
      input: 'mcp-app.html',
      // The trend chart's dynamic import becomes part of the one script, so nothing loads later.
      output: { codeSplitting: false }
    }
  }
});
