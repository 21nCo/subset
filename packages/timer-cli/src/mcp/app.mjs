// The Timer MCP App (SET-80): the board view as a `ui://` resource for hosts with the MCP Apps
// extension (io.modelcontextprotocol/ui), and the tool metadata that links timer_start, timer_list
// and timer_get to it. The HTML is the single-file build of apps/timer/mcp-app.html, which inlines
// every script and style, so the view loads nothing from anywhere. Hosts without the extension ignore
// both and keep the tools' text and structured results.
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createMcpAppResource, mcpAppToolMetadata } from '@mcpfn/core';

/** Versioned: a breaking change to the view's props is board@2, and this URI keeps serving. */
export const BOARD_URI = 'ui://subset-timer/board@1';
/** The tools whose results the board renders; the other tools return no view. */
export const BOARD_TOOLS = ['timer_start', 'timer_list', 'timer_get'];

/**
 * `_meta` for a tool that renders the board: `ui.resourceUri` (visible to the model and the view), and
 * the earlier flat `ui/resourceUri` key, which `@modelcontextprotocol/ext-apps` also sets for hosts
 * that read only that one.
 */
export const boardToolMetadata = () => ({ ...mcpAppToolMetadata(BOARD_URI), 'ui/resourceUri': BOARD_URI });

/** The built board in the installed package: `mcp-app/board.html`, read on each `resources/read`. */
export const boardHtmlFile = (packageRoot) => () => readFile(join(packageRoot, 'mcp-app', 'board.html'), 'utf8');

/**
 * The board resource. Its CSP metadata lists no connect, resource or frame domains: the view reaches
 * the server only through the host's `tools/call`.
 * @param {() => string | Promise<string>} html
 */
export function boardResource(html) {
  return createMcpAppResource({
    uri: BOARD_URI,
    name: 'timer-board',
    title: 'Timer board',
    description: 'The Timer board: live countdowns and controls for the timers in the subset-timer daemon on this computer.',
    html,
    ui: { csp: { connectDomains: [], resourceDomains: [], frameDomains: [] }, prefersBorder: true }
  });
}
