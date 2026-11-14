import { isVerb } from './commands.mjs';

// The Subset command-line tools `subset <tool>` runs. An entry names the published @subset.dev package and the bin it
// runs, the Subset Mac app that bundles the command (its `helpers` declaration in native/<id>/macos-release.json), or
// both; helpers.mjs runs an installed app's command. scripts/check-workspaces.mjs checks that this list matches the
// repository's published CLIs and the apps' helper declarations, so running a helper needs no network. A tool may not
// take the name of a command (commands.mjs).
//   app: { id, appName, bundleId, helper, kind }   the catalog app ID (`subset install <id>`), the app's name and
//        bundle ID, the helper's path inside the .app, and its kind: native (an executable) or node (an ES module).
const app = (id, appName, bundleId, helper, kind) => Object.freeze({ id, appName, bundleId, helper, kind });
export const TOOLS = Object.freeze({
  minutes: Object.freeze({
    package: '@subset.dev/minutes',
    bin: 'subset-minutes',
    app: app('minutes', 'Minutes', 'dev.subset.minutes', 'Contents/Resources/minutes-cli/dist/cli.mjs', 'node'),
    summary: 'Send a notetaker bot to a Google Meet or Zoom meeting and keep the audio locally'
  }),
  'point-in-time': Object.freeze({
    app: app('point-in-time', 'pointInTime', 'dev.subset.point-in-time', 'Contents/Helpers/point-in-time', 'native'),
    summary: 'Where your day went: the apps, windows and sites you worked in'
  }),
  system: Object.freeze({
    app: app('system', 'Subset System', 'dev.subset.system', 'Contents/Helpers/subset-system', 'native'),
    summary: "Where your Mac's CPU, memory and disk space go"
  }),
  timer: Object.freeze({
    package: '@subset.dev/timer',
    bin: 'subset-timer',
    app: app('timer', 'Timer', 'dev.subset.timer', 'Contents/Resources/timer-cli/dist/cli.mjs', 'node'),
    summary: 'Multi-timers and interval workouts with sound and notifications'
  }),
  usage: Object.freeze({ package: '@subset.dev/usage', bin: 'subset-usage', summary: 'Local dashboard and CLI for AI subscription usage' })
});

/** Where a tool comes from, for the help: its npm package, its app, or both. */
export function toolSource(tool) {
  const sources = [tool.package, tool.app && `the ${tool.app.appName} app`].filter(Boolean);
  return sources.join(' or ');
}

// The dist-tags the release workflow publishes, or an exact version (0.2.0, 0.2.0-beta.3). Ranges and other specs
// are refused (npm would read a tag-like `x` or `v1` as a range), so an argument can never become an npm option or a
// URL, file or git dependency.
const VERSION_SPEC = /^(?:latest|beta|next|\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$/;

/**
 * Resolves `usage` or `usage@<version>` to the tool's package, bin and npm spec, or returns { error }. `explicit` says
 * whether a version was given: it always runs the npm package, never an installed app's command. `app` is the tool's
 * app (tools.mjs), when it has one; a tool with no package has no `spec`, and takes no version.
 */
export function resolveTool(argument) {
  const at = argument.indexOf('@');
  const name = at === -1 ? argument : argument.slice(0, at);
  const version = at === -1 ? 'latest' : argument.slice(at + 1);
  if (isVerb(name)) return { error: `"${name}" is a subset command, not a tool. Run "subset help ${name}" for its usage.` };
  if (!Object.hasOwn(TOOLS, name)) return { error: `Unknown tool "${name}". Run "subset --help" to list the tools.` };
  if (!VERSION_SPEC.test(version)) return { error: `"${version}" is not latest, beta, next or an exact version such as 0.2.0.` };
  const tool = TOOLS[name];
  const explicit = at !== -1;
  if (tool.package === undefined) {
    if (explicit) return { error: `${name} comes with the ${tool.app.appName} app and has no npm versions. Run "subset ${name}" instead.` };
    return { name, app: tool.app, explicit };
  }
  return { name, package: tool.package, bin: tool.bin, version, spec: `${tool.package}@${version}`, explicit, ...(tool.app && { app: tool.app }) };
}

/**
 * The npm arguments that fetch a resolved tool (into npm's cache, or from a local install that satisfies it) and
 * print the PATH npm would run it with, whose first matching node_modules/.bin folder holds it. The launcher then
 * runs the tool in its own process, rather than through npm and the shell npm runs commands in, which would stand
 * between the tool and the signals sent to the launcher.
 */
export function npmLocateArgs({ spec }) {
  return ['exec', '--yes', `--package=${spec}`, '--', 'node', '-p', 'process.env.PATH'];
}

/**
 * The npm arguments that ask the registry for a tool's dist-tags. The launcher runs them only after npm could not
 * fetch the tool, to say why. `npm dist-tag ls` reads the registry's dist-tags of the package directly; `npm view
 * <package> dist-tags` would first pick the `latest` version, and so prints nothing for a package with only a beta.
 * With --json, npm prints an error (E404 for no such package) as JSON on stdout; the tags it prints as `tag: version`
 * lines.
 */
export function npmDistTagsArgs({ package: name }) {
  return ['dist-tag', 'ls', name, '--json'];
}

// The dist-tags in the answer of `npm dist-tag ls --json`: `tag: version` lines, or a JSON object of them.
function distTags(stdout) {
  try {
    const answer = JSON.parse(stdout);
    return typeof answer === 'object' && answer !== null && !Array.isArray(answer) ? answer : undefined;
  } catch {
    const lines = stdout.split(/\r?\n/).filter((line) => line.trim() !== '');
    const entries = lines.map((line) => /^([^\s:]+): (\S+)$/.exec(line.trim()));
    return lines.length > 0 && entries.every(Boolean) ? Object.fromEntries(entries.map(([, tag, version]) => [tag, version])) : undefined;
  }
}

/**
 * Why npm could not fetch a resolved tool, from the result ({ status, stdout }) of npmDistTagsArgs: the registry has
 * no such package, the tool has no live release but a beta (when the default `latest` was asked for), or, for
 * anything else (a network failure, an unreadable answer, a missing version), the fetch failure.
 */
export function fetchFailureMessage(tool, probe) {
  const tags = typeof probe?.stdout === 'string' ? distTags(probe.stdout) : undefined;
  if (probe?.status !== 0 && tags?.error?.code === 'E404') return `${tool.name} is not on npm yet.`;
  if (probe?.status === 0 && tags && tool.version === 'latest' && !Object.hasOwn(tags, 'latest') && typeof tags.beta === 'string') {
    return `${tool.name} has no live release yet; try subset ${tool.name}@beta`;
  }
  return `npm could not fetch ${tool.spec}.`;
}
