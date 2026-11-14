// The commands bundled in installed Subset Mac apps (SET-232). A tool in tools.mjs whose `app` names a helper is run
// from the installed app when there is one: `subset system status` runs Subset System.app/Contents/Helpers/subset-system,
// and `subset timer` loads Timer.app's embedded cli.mjs. The app is the first `<appName>.app` at the top level of
// /Applications, then ~/Applications, whose Info.plist has the tool's bundle ID (decision D2 of SET-224). The helper
// runs only when codesign accepts its signature, reports the Subset team and finds it issued by Apple to that team as a
// Developer ID: a native helper's own signature, or for a node helper (a resource with no signature of its own) the
// app's, whose seal covers the file.
import { spawn } from 'node:child_process';
import { lstatSync, realpathSync, statSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { applicationsFolders, PLUTIL, readInfoPlist } from './macos/apps.mjs';
import { runTool, TEAM_ID } from './macos/verify.mjs';

/** The tools the lookup asks. Tests replace them with stand-ins. */
export const HELPER_TOOLS = Object.freeze({ codesign: '/usr/bin/codesign', plutil: PLUTIL });
const CODESIGN_TIMEOUT_MS = 60_000;

/**
 * The code requirement a helper's signature must satisfy: a Developer ID Application certificate (leaf marker
 * 1.2.840.113635.100.6.1.13) issued by Apple's Developer ID CA (intermediate marker 1.2.840.113635.100.6.2.6) to the
 * Subset team. An ad-hoc signature can claim any TeamIdentifier (codesign --team-identifier), so the team alone is not
 * enough.
 */
export const DEVELOPER_ID_REQUIREMENT = `anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "${TEAM_ID}"`;

/** The signals `subset` passes on to a native helper. */
export const FORWARDED_SIGNALS = Object.freeze(['SIGINT', 'SIGTERM', 'SIGHUP']);

// The last line a tool wrote, for a refusal message.
const lastLine = (text) => text.trim().split('\n').at(-1)?.trim() || 'no output';

// The helper's file with its links resolved, { file }, when it is a regular file inside the bundle's Contents folder
// (a link may point only within it); undefined when the app has no entry at the helper's path, or at one of its
// folders, which are all folders inside Contents up to there (an older app); { problem } otherwise: a broken link or a
// file where a folder should be is a damaged app, not an older one.
function helperFile(bundle, relative) {
  const notInside = (detail) => ({ problem: `its ${relative} is not a file inside the app${detail ? ` (${detail})` : ''}` });
  try {
    let real = realpathSync(bundle);
    const contents = path.join(real, 'Contents') + path.sep;
    const parts = relative.split('/');
    for (const [index, part] of parts.entries()) {
      const shown = parts.slice(0, index + 1).join('/');
      const last = index === parts.length - 1;
      const entry = path.join(real, part);
      // Each folder before it is a real folder inside Contents, so only an absent entry gives ENOENT here.
      try {
        lstatSync(entry);
      } catch (error) {
        if (error.code === 'ENOENT') return undefined;
        throw error;
      }
      // A link that leads nowhere, through a file or in a loop.
      try {
        real = realpathSync(entry);
      } catch (error) {
        if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR' && error.code !== 'ELOOP') throw error;
        return last ? { problem: `its ${relative} is a broken link` } : notInside(`${shown} is a broken link`);
      }
      if (!`${real}${path.sep}`.startsWith(contents)) return notInside();
      if (!last && !statSync(real).isDirectory()) return notInside(`${shown} is not a folder`);
    }
    if (!statSync(real).isFile()) return notInside();
    return { file: real };
  } catch (error) {
    return { problem: `its ${relative} cannot be read (${error.code ?? error.message})` };
  }
}

/**
 * Why codesign refuses `target`, or undefined when it accepts its signature as the Subset team's:
 * `codesign --verify --strict` must pass, `codesign -d --verbose=2` must report TeamIdentifier=SAZVPX4CAA, and
 * `codesign --verify --strict -R=<DEVELOPER_ID_REQUIREMENT>` must pass.
 */
export async function signatureProblem(target, { codesign = HELPER_TOOLS.codesign } = {}) {
  const verify = await runTool(codesign, ['--verify', '--strict', target], { timeout: CODESIGN_TIMEOUT_MS });
  if (verify.code !== 0) return `its code signature is not valid (codesign: ${lastLine(verify.stderr)})`;
  const details = await runTool(codesign, ['-d', '--verbose=2', target], { timeout: CODESIGN_TIMEOUT_MS });
  const teams = [...`${details.stderr}\n${details.stdout}`.matchAll(/^TeamIdentifier=(.*)$/gm)].map((match) => match[1].trim());
  if (details.code !== 0 || teams.length !== 1 || teams[0] !== TEAM_ID) {
    return `it is not signed by the Subset team ${TEAM_ID} (TeamIdentifier: ${teams.length === 1 ? teams[0] : 'not reported'})`;
  }
  const anchored = await runTool(codesign, ['--verify', '--strict', `-R=${DEVELOPER_ID_REQUIREMENT}`, target], { timeout: CODESIGN_TIMEOUT_MS });
  if (anchored.code !== 0) return `it is not signed with the Subset team's Developer ID certificate (codesign: ${lastLine(anchored.stderr)})`;
  return undefined;
}

/**
 * Looks for the installed app of a tool (`tool.app` from tools.mjs: { id, appName, bundleId, helper, kind }) and checks
 * its helper. Resolves one of:
 *   { status: 'none' }                              no such app in /Applications or ~/Applications
 *   { status: 'missing', bundle }                   nothing is at the helper's path or one of its folders (an older version)
 *   { status: 'refused', bundle, reason }           the helper is not a file inside the app (a broken link, a file for a
 *                                                   folder, a link out of the app), or fails the signature check
 *   { status: 'found', bundle, file, kind }         the helper to run (`file` with its links resolved)
 * Throws ApplicationsFoldersError when SUBSET_APPLICATIONS_DIRS is malformed.
 */
export async function findAppHelper(app, { env, home, tools = HELPER_TOOLS }) {
  for (const folder of applicationsFolders({ env, home })) {
    const bundle = path.join(folder.dir, `${app.appName}.app`);
    const info = await readInfoPlist(bundle, tools.plutil);
    if (info?.CFBundleIdentifier !== app.bundleId) continue;
    const found = helperFile(bundle, app.helper);
    if (found === undefined) return { status: 'missing', bundle };
    if (found.problem) return { status: 'refused', bundle, reason: found.problem };
    // A node helper is a resource of the app, sealed by the app's signature; a native helper is signed itself.
    const problem = await signatureProblem(app.kind === 'native' ? found.file : bundle, tools).catch((error) => `codesign could not check it (${error.message})`);
    if (problem) return { status: 'refused', bundle, reason: `${app.kind === 'native' ? app.helper : 'the app'}: ${problem}` };
    return { status: 'found', bundle, file: found.file, kind: app.kind };
  }
  return { status: 'none' };
}

/**
 * Runs a native helper with `args`, its standard input, output and error being this process's, and resolves
 * { code, signal } when it exits; rejects when it cannot be started.
 *
 * The helper runs in its own process group, and this process passes each SIGINT, SIGTERM and SIGHUP it gets on to the
 * helper, so the helper gets each signal exactly once, whether it was sent to this process or to its process group (as
 * Ctrl-C at a terminal does). The helper is then not in the terminal's foreground group: Subset's helpers write to the
 * terminal but do not read it.
 */
export function runNativeHelper(file, args, { env = process.env, signals = process } = {}) {
  return new Promise((resolve, reject) => {
    let child;
    // Installed before the helper starts; a signal is handled on a later turn of the event loop, once `child` is set.
    const handlers = FORWARDED_SIGNALS.map((name) => [
      name,
      () => {
        if (child?.pid !== undefined && child.exitCode === null && child.signalCode === null) child.kill(name);
      }
    ]);
    for (const [name, handler] of handlers) signals.on(name, handler);
    const done = () => {
      for (const [name, handler] of handlers) signals.off(name, handler);
    };
    try {
      child = spawn(file, args, { stdio: 'inherit', env, detached: true });
    } catch (error) {
      done();
      reject(error);
      return;
    }
    child.once('error', (error) => {
      done();
      reject(error);
    });
    child.once('exit', (code, signal) => {
      done();
      resolve({ code, signal });
    });
  });
}

/**
 * What keeps the launcher's tool table (tools.mjs) and the apps' helper declarations (`helpers` in each
 * native/<app-id>/macos-release.json, given as { appId, manifest }) from agreeing, as messages; empty when they agree.
 * Every declared helper must be a tool whose `app` names that app (id, appName, bundleId) and that helper (path, kind),
 * every tool with an `app` must be declared by its app, and a tool with no npm package must have an app.
 * scripts/check-workspaces.mjs (npm run check) runs it on the repository.
 */
export function helperDeclarationProblems(tools, manifests) {
  const problems = [];
  const declared = new Map();
  for (const { appId, manifest } of manifests) {
    for (const helper of manifest.helpers ?? []) {
      declared.set(helper.command, { appId, manifest, helper });
      const file = `native/${appId}/macos-release.json`;
      const tool = Object.hasOwn(tools, helper.command) ? tools[helper.command] : undefined;
      if (tool?.app === undefined) {
        problems.push(`${file} declares the helper ${helper.command}, which is not a subset.dev launcher tool with an app in packages/subset-dev/src/tools.mjs`);
        continue;
      }
      const expected = { id: appId, appName: manifest.app, bundleId: manifest.bundleId, helper: helper.path, kind: helper.kind };
      for (const [key, value] of Object.entries(expected)) {
        if (tool.app[key] !== value) problems.push(`subset ${helper.command} has app.${key} ${JSON.stringify(tool.app[key])}, but ${file} declares ${JSON.stringify(value)}`);
      }
    }
  }
  for (const [name, tool] of Object.entries(tools)) {
    if (tool.app !== undefined && !declared.has(name)) problems.push(`subset ${name} runs a helper of the ${tool.app.appName} app, but no native/*/macos-release.json declares the helper ${name}`);
    if (tool.package === undefined && tool.app === undefined) problems.push(`subset ${name} has neither an npm package nor an app`);
  }
  return problems;
}
