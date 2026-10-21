// The MCP App build (SET-80): mcp-app.html as one self-contained file, every script and style inlined,
// written to packages/timer-cli/mcp-app/board.html for `subset-timer mcp` to serve as a ui:// resource.
// The host's iframe has no origin to load assets from, so nothing may stay a separate file.
import { defineConfig, type Plugin } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

const outDir = '../../packages/timer-cli/mcp-app';

/** Replaces the entry's script and stylesheet tags with their code and emits only board.html. */
function singleFile(): Plugin {
  return {
    name: 'subset-timer-single-file',
    enforce: 'post',
    generateBundle(_options, bundle) {
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
      delete bundle['mcp-app.html'];
      this.emitFile({ type: 'asset', fileName: 'board.html', source: html });
    }
  };
}

export default defineConfig({
  plugins: [svelte(), singleFile()],
  // public/ holds the web page's favicon, which the MCP App does not use.
  publicDir: false,
  build: {
    outDir,
    emptyOutDir: true,
    assetsInlineLimit: Number.MAX_SAFE_INTEGER,
    cssCodeSplit: false,
    modulePreload: false,
    rollupOptions: { input: 'mcp-app.html' }
  }
});
