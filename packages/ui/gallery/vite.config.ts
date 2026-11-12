import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig } from 'vite';

// The component gallery, for development and review only; it is never built or shipped.
export default defineConfig({
  root: new URL('.', import.meta.url).pathname,
  plugins: [svelte()],
  server: { host: '127.0.0.1', port: 4190, strictPort: false }
});
