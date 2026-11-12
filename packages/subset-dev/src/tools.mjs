// The Subset command-line tools `subset <tool>` runs. Each entry names a published @subset.dev package and the bin it
// runs; scripts/check-workspaces.mjs checks that this list matches the repository's published CLIs.
export const TOOLS = Object.freeze({
  minutes: Object.freeze({ package: '@subset.dev/minutes', bin: 'subset-minutes', summary: 'Send a notetaker bot to a Google Meet or Zoom meeting and keep the audio locally' }),
  timer: Object.freeze({ package: '@subset.dev/timer', bin: 'subset-timer', summary: 'Multi-timers and interval workouts with sound and notifications' }),
  usage: Object.freeze({ package: '@subset.dev/usage', bin: 'subset-usage', summary: 'Local dashboard and CLI for AI subscription usage' })
});

// A dist-tag (latest, beta) or exact version (0.2.0, 0.2.0-beta.3). Ranges and other specs are refused, so an
// argument can never become an npm option or a URL, file or git dependency.
const VERSION_SPEC = /^(?:[a-z][a-z0-9-]*|\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$/;

/**
 * Resolves `usage` or `usage@<version>` to the package spec and bin to run, or returns { error }.
 */
export function resolveTool(argument) {
  const at = argument.indexOf('@');
  const name = at === -1 ? argument : argument.slice(0, at);
  const version = at === -1 ? 'latest' : argument.slice(at + 1);
  if (!Object.hasOwn(TOOLS, name)) return { error: `Unknown tool "${name}". Run "subset --help" to list the tools.` };
  if (!VERSION_SPEC.test(version)) return { error: `"${version}" is not a dist-tag or exact version (for example latest, beta or 0.2.0).` };
  const tool = TOOLS[name];
  return { name, spec: `${tool.package}@${version}`, bin: tool.bin };
}

/** The npm arguments that run a resolved tool with the user's arguments. */
export function npmExecArgs({ spec, bin }, args) {
  return ['exec', '--yes', `--package=${spec}`, '--', bin, ...args];
}
