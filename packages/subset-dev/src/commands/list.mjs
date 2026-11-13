// subset list [--beta] [--json] [--refresh]: every Subset Mac app and tool in the catalog feed, with what is installed
// (Mac apps, on macOS only) and the live version of each, plus the beta with --beta. --json prints the subset.list@1
// document described in the README, which always has both channels.
import { ApplicationsFoldersError, applicationsFolders, detectApps, PLUTIL } from '../macos/apps.mjs';
import { CatalogInvalidError, CatalogUnavailableError, loadCatalog } from '../feed.mjs';

export const LIST_SCHEMA = 'subset.list@1';
const OPTIONS = { '--beta': 'beta', '--json': 'json', '--refresh': 'refresh' };

/** The options of `subset list`: { beta, json, refresh }, or { error } for anything else. */
export function parseListArgs(args) {
  const options = { beta: false, json: false, refresh: false };
  for (const arg of args) {
    if (!Object.hasOwn(OPTIONS, arg)) {
      const what = arg.startsWith('-') ? `option "${arg}"` : `argument "${arg}"`;
      return { error: `subset list does not take the ${what}. Usage: subset list [--beta] [--json] [--refresh]` };
    }
    options[OPTIONS[arg]] = true;
  }
  return options;
}

const betaVersion = (beta) => (beta ? `${beta.version}-beta.${beta.build}` : null);

/** The subset.list@1 document for a loaded catalog and the installed copies of its apps (null when not detected). */
export function listDocument(catalog, installed, platform) {
  const supported = installed !== null;
  return {
    schema: LIST_SCHEMA,
    catalog: { url: catalog.url, generatedAt: catalog.feed.generatedAt, fetchedAt: new Date(catalog.fetchedAt).toISOString(), cached: catalog.cached },
    platform,
    appDetection: supported ? 'supported' : 'unsupported',
    apps: catalog.feed.apps.map((app, index) => ({
      id: app.id,
      name: app.name,
      appName: app.appName,
      bundleId: app.bundleId,
      installed: supported ? installed[index] : null,
      live: app.channels.live ? { version: app.channels.live.version } : null,
      beta: app.channels.beta ? { version: app.channels.beta.version, build: app.channels.beta.build, label: betaVersion(app.channels.beta) } : null
    })),
    tools: catalog.feed.tools.map((tool) => ({ id: tool.id, package: tool.package, bin: tool.bin, live: tool.distTags.latest ?? null, beta: tool.distTags.beta ?? null }))
  };
}

// One installed copy as the INSTALLED column shows it: 0.1.0 (/Applications), or with a receipt 0.1.0 (live,
// /Applications) and 0.1.0-beta.2 (beta, ~/Applications).
function installedText(copy) {
  const version = copy.channel === 'beta' ? `${copy.version}-beta.${copy.build}` : (copy.version ?? 'unknown version');
  return `${version} (${copy.channel ? `${copy.channel}, ` : ''}${copy.folder})`;
}

// Text as it is safe to print in a table cell, whatever its source (an installed app's Info.plist is not validated):
// each control character (C0, DEL, C1) and line or paragraph separator becomes a visible \xNN or \uNNNN, so it can
// neither send a terminal escape sequence nor start another row. --json keeps the values as they are.
const UNPRINTABLE = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g;
export const printable = (text) =>
  text.replace(UNPRINTABLE, (character) => {
    const code = character.charCodeAt(0);
    return code < 0x100 ? `\\x${code.toString(16).padStart(2, '0')}` : `\\u${code.toString(16)}`;
  });

// Rows as left-aligned columns two spaces apart, without trailing spaces. Every cell is made printable.
function table(unsafeRows) {
  const rows = unsafeRows.map((row) => row.map(printable));
  const widths = rows[0].map((_, column) => Math.max(...rows.map((row) => row[column].length)));
  return rows.map((row) => row.map((cell, column) => (column === row.length - 1 ? cell : cell.padEnd(widths[column]))).join('  ').trimEnd()).join('\n');
}

/** The text `subset list` prints for a subset.list@1 document. */
export function listText(document, { beta }) {
  const sections = [];
  if (document.apps.length > 0) {
    const rows = document.apps.map((app) => {
      let installed = 'unsupported';
      if (app.installed !== null) installed = app.installed.length > 0 ? app.installed.map(installedText).join(', ') : '-';
      const row = [app.id, installed, app.live?.version ?? '-'];
      return beta ? [...row, app.beta?.label ?? '-'] : row;
    });
    sections.push(table([beta ? ['APP', 'INSTALLED', 'LIVE', 'BETA'] : ['APP', 'INSTALLED', 'LIVE'], ...rows]));
  }
  if (document.tools.length > 0) {
    const rows = document.tools.map((tool) => (beta ? [tool.id, tool.live ?? '-', tool.beta ?? '-'] : [tool.id, tool.live ?? '-']));
    sections.push(table([beta ? ['TOOL', 'LIVE', 'BETA'] : ['TOOL', 'LIVE'], ...rows]));
  }
  if (sections.length === 0) return 'The catalog lists no apps or tools.\n';
  const note = document.appDetection === 'unsupported' && document.apps.length > 0 ? '\n\nMac apps can be installed only on macOS.' : '';
  return `${sections.join('\n\n')}${note}\n`;
}

/**
 * Runs `subset list <args>`, writing to `stdout` and `stderr`, and returns the exit code: 0, 1 when the catalog
 * cannot be used, or 2 for a usage error.
 */
export async function runList(args, { env, platform, home, stdout, stderr, fetch, now, plutil = PLUTIL }) {
  const options = parseListArgs(args);
  if (options.error) {
    stderr.write(`subset: ${options.error}\n`);
    return 2;
  }
  let folders;
  let catalog;
  try {
    // Apps are detected on macOS only; elsewhere their installation is unsupported.
    if (platform === 'darwin') folders = applicationsFolders({ env, home });
    catalog = await loadCatalog({ env, platform, home, refresh: options.refresh, now, fetch });
  } catch (error) {
    if (!(error instanceof CatalogInvalidError || error instanceof CatalogUnavailableError || error instanceof ApplicationsFoldersError)) throw error;
    stderr.write(`subset: ${error.message}\n`);
    return 1;
  }
  const installed = folders ? await detectApps(catalog.feed.apps, { folders, home, plutil }) : null;
  if (catalog.warning) stderr.write(`subset: ${catalog.warning}\n`);
  const document = listDocument(catalog, installed, platform);
  stdout.write(options.json ? `${JSON.stringify(document, null, 2)}\n` : listText(document, options));
  return 0;
}
