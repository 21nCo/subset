// The commands of `subset` other than its tools: `subset <verb> [arguments...]`. Their names are reserved, so no tool
// can take one (test/cli.test.mjs). cli.mjs runs them.
export const VERBS = Object.freeze({
  list: Object.freeze({
    usage: 'subset list [--beta] [--json] [--refresh]',
    summary: 'List the Subset tools and Mac apps, installed and available',
    details: 'Shows each Subset Mac app with its installed and live versions, and each tool with its live version.\n--beta adds the beta versions, --json prints JSON and --refresh skips the cached catalog.\nInstalled apps are found on macOS only, in /Applications and ~/Applications.'
  }),
  install: Object.freeze({
    usage: 'subset install <app> [--beta] [--user] [--dir <folder>]',
    summary: 'Install a Subset Mac app',
    details: 'Downloads the app, checks its checksum, signature, team, notarization, bundle ID and version, and installs it in\n/Applications (or ~/Applications when /Applications is not writable). --user installs it in ~/Applications,\n--dir in another folder, and --beta installs the beta. An app that is already there is left alone (subset update).'
  }),
  update: Object.freeze({
    usage: 'subset update [<app>...] [--beta] [--quit]',
    summary: 'Update the installed Subset Mac apps',
    details: 'Updates the named apps, or every installed Subset Mac app, to the newest version of the live channel, with the\nchecks of subset install; the old copy goes to the Trash. --beta updates to the beta. A running app is not\nreplaced: --quit quits it first and reopens it afterwards. With no apps, also says when a newer subset.dev is out.'
  }),
  uninstall: Object.freeze({
    usage: 'subset uninstall <app> [--quit]',
    summary: 'Move a Subset Mac app to the Trash',
    details: "Moves the app to the Trash and deletes its receipt. The app's data stays. A running app is not moved: --quit\nquits it first."
  }),
  help: Object.freeze({
    usage: 'subset help [<command>]',
    summary: 'Show this help, or the usage of a command',
    details: 'With a command, shows its usage. A tool\'s own help is "subset <tool> --help".'
  }),
  version: Object.freeze({
    usage: 'subset version',
    summary: 'Show the subset.dev version',
    details: 'Prints the version of subset.dev, as --version does.'
  })
});

// Names no tool may take, because `subset <name>` runs the command.
export const RESERVED_NAMES = Object.freeze(Object.keys(VERBS));

export const isVerb = (name) => Object.hasOwn(VERBS, name);

/** The usage text of a verb, as `subset help <verb>` and `subset <verb> --help` print it. */
export function verbHelp(name) {
  const verb = VERBS[name];
  return `Usage: ${verb.usage}\n\n${verb.summary}.\n${verb.details}\n`;
}

/**
 * What `subset <arguments>` does, decided from the arguments alone:
 *   { action: 'help' }                          the launcher's help
 *   { action: 'version' }                       the launcher's version
 *   { action: 'usage', verb }                   a verb's usage (`subset help <verb>`, `subset <verb> --help`)
 *   { action: 'tool-help', tool }               where a tool's help is (`subset help <tool>`)
 *   { action: 'command', verb, args }           run the verb (`subset list --json`) with `args`
 *   { action: 'tool', argument, args }          run the tool `argument` (`usage`, `usage@beta`) with `args`
 *   { action: 'error', message }                an unknown command (exit 2)
 * `isTool(name)` says whether `name` is a tool.
 */
export function route(argv, { isTool }) {
  const [first, ...rest] = argv;
  if (first === undefined || first === '-h' || first === '--help') return { action: 'help' };
  if (first === '-v' || first === '--version') return { action: 'version' };
  if (!isVerb(first)) return { action: 'tool', argument: first, args: rest };
  if (first === 'help') {
    const [topic] = rest;
    if (topic === undefined || topic === '-h' || topic === '--help') return { action: 'help' };
    if (isVerb(topic)) return { action: 'usage', verb: topic };
    if (isTool(topic)) return { action: 'tool-help', tool: topic };
    return { action: 'error', message: `Unknown command "${topic}". Run "subset --help" to list the tools and commands.` };
  }
  // Options and operands before a `--` only: after it, `--help` would be an operand.
  const end = rest.indexOf('--');
  const options = end === -1 ? rest : rest.slice(0, end);
  if (options.includes('-h') || options.includes('--help')) return { action: 'usage', verb: first };
  if (first === 'version') return { action: 'version' };
  return { action: 'command', verb: first, args: rest };
}
