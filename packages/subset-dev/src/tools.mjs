import { isVerb } from './commands.mjs';

// The Subset command-line tools `subset <tool>` runs. Each entry names a published @subset.dev package and the bin it
// runs; scripts/check-workspaces.mjs checks that this list matches the repository's published CLIs. A tool may not take
// the name of a command (commands.mjs).
export const TOOLS = Object.freeze({
  minutes: Object.freeze({ package: '@subset.dev/minutes', bin: 'subset-minutes', summary: 'Send a notetaker bot to a Google Meet or Zoom meeting and keep the audio locally' }),
  timer: Object.freeze({ package: '@subset.dev/timer', bin: 'subset-timer', summary: 'Multi-timers and interval workouts with sound and notifications' }),
  usage: Object.freeze({ package: '@subset.dev/usage', bin: 'subset-usage', summary: 'Local dashboard and CLI for AI subscription usage' })
});

// The dist-tags the release workflow publishes, or an exact version (0.2.0, 0.2.0-beta.3). Ranges and other specs
// are refused (npm would read a tag-like `x` or `v1` as a range), so an argument can never become an npm option or a
// URL, file or git dependency.
const VERSION_SPEC = /^(?:latest|beta|next|\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$/;

/**
 * Resolves `usage` or `usage@<version>` to the tool's package, bin and npm spec, or returns { error }.
 */
export function resolveTool(argument) {
  const at = argument.indexOf('@');
  const name = at === -1 ? argument : argument.slice(0, at);
  const version = at === -1 ? 'latest' : argument.slice(at + 1);
  if (isVerb(name)) return { error: `"${name}" is a subset command, not a tool. Run "subset help ${name}" for its usage.` };
  if (!Object.hasOwn(TOOLS, name)) return { error: `Unknown tool "${name}". Run "subset --help" to list the tools.` };
  if (!VERSION_SPEC.test(version)) return { error: `"${version}" is not latest, beta, next or an exact version such as 0.2.0.` };
  const tool = TOOLS[name];
  return { name, package: tool.package, bin: tool.bin, version, spec: `${tool.package}@${version}` };
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
 * fetch the tool, to say why.
 */
export function npmDistTagsArgs({ package: name }) {
  return ['view', name, 'dist-tags', '--json'];
}

/**
 * Why npm could not fetch a resolved tool, from the result ({ status, stdout }) of `npm view <package> dist-tags
 * --json`: the registry has no such package, the tool has no live release but a beta (when the default `latest` was
 * asked for), or, for anything else (a network failure, an unreadable answer, a missing version), the fetch failure.
 */
export function fetchFailureMessage(tool, probe) {
  let answer;
  try {
    answer = JSON.parse(probe?.stdout ?? '');
  } catch {
    answer = undefined;
  }
  const isObject = (value) => typeof value === 'object' && value !== null && !Array.isArray(value);
  if (probe?.status !== 0 && isObject(answer) && answer.error?.code === 'E404') return `${tool.name} is not on npm yet.`;
  if (probe?.status === 0 && isObject(answer) && tool.version === 'latest' && !Object.hasOwn(answer, 'latest') && typeof answer.beta === 'string') {
    return `${tool.name} has no live release yet; try subset ${tool.name}@beta`;
  }
  return `npm could not fetch ${tool.spec}.`;
}
