// The Usage MCP App (SET-105): the dashboard as a `ui://` resource for hosts with the MCP Apps extension
// (io.modelcontextprotocol/ui), and the tool metadata that links usage_status to it. The HTML is the
// single-file build of apps/usage/mcp-app.html, which inlines every script, style and the trend chart,
// so the view loads nothing from anywhere. Hosts without the extension ignore both and keep the tools'
// text and structured results.
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createMcpAppResource, mcpAppToolMetadata } from '@mcpfn/core';

/** Versioned: a breaking change to the view's props is dashboard@2, and this URI keeps serving. */
export const DASHBOARD_URI = 'ui://subset-usage/dashboard@1';

/**
 * `_meta` for usage_status: `ui.resourceUri` (visible to the model and the view), and the earlier flat
 * `ui/resourceUri` key, which `@modelcontextprotocol/ext-apps` also sets for hosts that read only that one.
 */
export const dashboardToolMetadata = () => ({ ...mcpAppToolMetadata(DASHBOARD_URI), 'ui/resourceUri': DASHBOARD_URI });

/** The built dashboard in the installed package: `mcp-app/dashboard.html`, read on each `resources/read`. */
export const dashboardHtmlFile = (packageRoot) => () => readFile(join(packageRoot, 'mcp-app', 'dashboard.html'), 'utf8');

const NO_DASHBOARD = () => {
  throw new Error('The usage dashboard view is not available from this server.');
};

/**
 * The dashboard resource. Its CSP metadata lists no connect, resource or frame domains: the view reaches
 * the server only through the host's `tools/call`.
 * @param {() => string | Promise<string>} [html]
 */
export function dashboardResource(html = NO_DASHBOARD) {
  return createMcpAppResource({
    uri: DASHBOARD_URI,
    name: 'usage-dashboard',
    title: 'Usage dashboard',
    description: 'The Usage dashboard: quota windows, reset times, freshness and 48-hour trends for the accounts subset-usage reads on this computer. Read-only.',
    html,
    ui: { csp: { connectDomains: [], resourceDomains: [], frameDomains: [] }, prefersBorder: true },
  });
}
