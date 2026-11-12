import { existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

/**
 * The npm-cli.js to run as `node <npm-cli.js>`, with no shell, so arguments reach the tool unchanged (cmd.exe would
 * expand %VAR% and reparse quotes and backslashes); undefined when none is found. Prefers the npm that launched this
 * command (npx and npm exec set npm_execpath). On Windows, npm is npm.cmd, a shim for node_modules\npm\bin\npm-cli.js
 * in its own folder, so it then takes the first npm.cmd on PATH, as a shell would, and finally the npm installed with
 * Node.js. Elsewhere the caller runs `npm` from PATH, an executable script that needs no shell.
 */
export function findNpmCli({ env = process.env, platform = process.platform, execPath = process.execPath, exists = existsSync } = {}) {
  const paths = platform === 'win32' ? path.win32 : path.posix;
  const launcher = env.npm_execpath;
  if (launcher && /(?:^|[\\/])np[mx]-cli\.js$/.test(launcher)) {
    const npmCli = paths.join(paths.dirname(launcher), 'npm-cli.js');
    if (exists(npmCli)) return npmCli;
  }
  if (platform !== 'win32') return undefined;
  const cliIn = (folder) => paths.join(folder, 'node_modules', 'npm', 'bin', 'npm-cli.js');
  for (const folder of (env.PATH ?? env.Path ?? '').split(';').filter(Boolean)) {
    if (exists(paths.join(folder, 'npm.cmd')) && exists(cliIn(folder))) return cliIn(folder);
  }
  const bundled = cliIn(paths.dirname(execPath));
  return exists(bundled) ? bundled : undefined;
}
