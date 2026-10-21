// The MCP App entry (SET-80): the Timer board in an MCP host's iframe, built into one HTML file with
// every script and style inlined (vite.mcp-app.config.ts) and served by `subset-timer mcp` as
// `ui://subset-timer/board@1`. The bridge in mcp-bridge.ts talks to the host; this file wires it to
// the page: the host's theme, whether the view can be seen, and its size.
import './zod-jitless.js';
import { mount } from 'svelte';
import McpApp from './McpApp.svelte';
import { createBridge } from './mcp-bridge.js';

const bridge = createBridge({ host: window.parent, view: window, appInfo: { name: 'subset-timer-board', version: '1.0.0' } });
mount(McpApp, { target: document.getElementById('app')!, props: { bridge } });

// The host's theme when it gives one, else the system's through prefers-color-scheme.
const root = document.documentElement;
bridge.subscribe(({ theme }) => {
  if (theme) root.dataset.theme = theme;
  else delete root.dataset.theme;
  root.style.colorScheme = theme ?? '';
});

// Refresh runs only while the page is shown and the view is on screen.
let pageShown = document.visibilityState === 'visible';
let onScreen = true;
const visibility = () => bridge.setVisible(pageShown && onScreen);
document.addEventListener('visibilitychange', () => {
  pageShown = document.visibilityState === 'visible';
  visibility();
});
new IntersectionObserver((entries) => {
  onScreen = entries.some((entry) => entry.isIntersecting);
  visibility();
}).observe(root);

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
