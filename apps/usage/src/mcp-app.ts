// The MCP App entry (SET-105): the Usage dashboard in an MCP host's iframe, built into one HTML file with
// every script and style inlined, the ECharts trend chunk included (vite.mcp-app.config.ts), and served by
// `subset-usage mcp` as `ui://subset-usage/dashboard@1`. The bridge in mcp-bridge.ts talks to the host;
// this file wires it to the page: the host's theme and the view's size.
import { mount } from 'svelte';
import McpApp from './McpApp.svelte';
import { createBridge } from './mcp-bridge.js';

const bridge = createBridge({ host: window.parent, view: window, appInfo: { name: 'subset-usage-dashboard', version: '1.0.0' } });
mount(McpApp, { target: document.getElementById('app')!, props: { bridge } });

// The host's theme when it gives one, else the system's through prefers-color-scheme.
const root = document.documentElement;
bridge.subscribe(({ theme }) => {
  if (theme) root.dataset.theme = theme;
  else delete root.dataset.theme;
  root.style.colorScheme = theme ?? '';
});

// The host sizes the iframe to the content's height, measured as ext-apps does.
let measuring = false;
new ResizeObserver(() => {
  if (measuring) return;
  measuring = true;
  requestAnimationFrame(() => {
    measuring = false;
    const height = root.style.height;
    root.style.height = 'max-content';
    const measured = Math.ceil(root.getBoundingClientRect().height);
    root.style.height = height;
    bridge.sizeChanged(Math.ceil(window.innerWidth), measured);
  });
}).observe(document.body);

void bridge.connect().catch(() => {
  // No host answered ui/initialize (the page was opened outside an MCP host); the view stays waiting.
});
