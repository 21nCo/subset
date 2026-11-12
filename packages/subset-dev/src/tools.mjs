// The Subset command-line tools `subset <tool>` runs. Each entry names a published @subset.dev package and the bin it
// runs; scripts/check-workspaces.mjs checks that this list matches the repository's published CLIs.
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
  if (!Object.hasOwn(TOOLS, name)) return { error: `Unknown tool "${name}". Run "subset --help" to list the tools.` };
  if (!VERSION_SPEC.test(version)) return { error: `"${version}" is not latest, beta, next or an exact version such as 0.2.0.` };
  const tool = TOOLS[name];
  return { name, package: tool.package, bin: tool.bin, version, spec: `${tool.package}@${version}` };
}

/**
 * The npm arguments that fetch a resolved tool (into npm's cache, or from a local install that satisfies it) and
 * print the PATH npm would run it with, whose first matching node_modules/.bin folder holds it. The launcher then
 * starts the tool itself, so signals reach it directly instead of stopping at npm and the shell npm runs commands in.
 */
export function npmLocateArgs({ spec }) {
  return ['exec', '--yes', `--package=${spec}`, '--', 'node', '-p', 'process.env.PATH'];
}
