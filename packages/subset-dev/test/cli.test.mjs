import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { findToolBin } from '../src/bin.mjs';
import { findNpmCli } from '../src/npm.mjs';
import { RESERVED_NAMES, route, VERBS } from '../src/commands.mjs';
import { fetchFailureMessage, npmDistTagsArgs, npmLocateArgs, resolveTool, TOOLS, toolSource } from '../src/tools.mjs';

const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
const { version } = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));

// A stand-in npm and an installed @subset.dev/usage. The npm appends its arguments to the npm log, one JSON line per
// run. `npm dist-tag` prints FAKE_TAGS_OUT and exits with FAKE_TAGS_EXIT; anything else prints a PATH whose
// node_modules/.bin folder holds the tool, and exits with FAKE_NPM_EXIT. The tool prints its arguments as JSON and
// exits with TOOL_EXIT; with TOOL_PRINT_ENV it prints that environment variable instead; with TOOL_WAIT it prints
// `ready <pid>`, then reports each signal it gets.
const root = mkdtempSync(path.join(tmpdir(), 'subset-dev-test-'));
after(() => rmSync(root, { recursive: true, force: true }));
const npmLog = path.join(root, 'npm-args.json');
const modules = path.join(root, 'prefix', 'node_modules');
mkdirSync(path.join(modules, '.bin'), { recursive: true });
mkdirSync(path.join(modules, '@subset.dev', 'usage'), { recursive: true });
writeFileSync(path.join(modules, '@subset.dev', 'usage', 'package.json'), JSON.stringify({ name: '@subset.dev/usage', version: '0.2.0', bin: { 'subset-usage': 'cli.mjs' } }));
writeFileSync(
  path.join(modules, '@subset.dev', 'usage', 'cli.mjs'),
  `if (process.env.TOOL_WAIT) {
     // Reports every signal it gets, and exits 0 a moment after the first.
     for (const s of ['SIGTERM', 'SIGHUP', 'SIGINT']) {
       process.on(s, () => {
         process.stdout.write(' ' + s);
         setTimeout(() => process.exit(0), 200);
       });
     }
     process.stdout.write('ready ' + process.pid);
     setTimeout(() => process.exit(9), 5000);
   } else {
     if (process.env.TOOL_PRINT_ENV) process.stdout.write(String(process.env[process.env.TOOL_PRINT_ENV]));
     else process.stdout.write(JSON.stringify(process.argv.slice(2)));
     process.exitCode = Number(process.env.TOOL_EXIT ?? 0);
   }`
);
mkdirSync(path.join(root, 'npm'));
writeFileSync(
  path.join(root, 'npm', 'npm-cli.js'),
  `require('node:fs').appendFileSync(${JSON.stringify(npmLog)}, JSON.stringify(process.argv.slice(2)) + '\\n');
   if (process.argv[2] === 'dist-tag') {
     process.stdout.write(process.env.FAKE_TAGS_OUT ?? '');
     process.exit(Number(process.env.FAKE_TAGS_EXIT ?? 0));
   }
   process.stdout.write('some npm output\\n' + ${JSON.stringify(`/elsewhere/node_modules/.bin${path.delimiter}${path.join(modules, '.bin')}${path.delimiter}/usr/bin`)} + '\\n');
   process.exit(Number(process.env.FAKE_NPM_EXIT ?? 0));`
);
// Empty folders stand in for /Applications and ~/Applications, so on macOS no installed app's command runs instead of
// the npm package (app-helpers.test.mjs tests that).
mkdirSync(path.join(root, 'Applications'));
mkdirSync(path.join(root, 'user-Applications'));
const env = {
  ...process.env,
  npm_execpath: path.join(root, 'npm', 'npx-cli.js'),
  SUBSET_APPLICATIONS_DIRS: `${path.join(root, 'Applications')}${path.delimiter}${path.join(root, 'user-Applications')}`
};

const subset = (args, extra = {}) => spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8', env: { ...env, ...extra } });
// The npm runs since the last call: the arguments of each.
function npmCalls() {
  let lines = '';
  try {
    lines = readFileSync(npmLog, 'utf8');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  rmSync(npmLog, { force: true });
  return lines.split('\n').filter(Boolean).map((line) => JSON.parse(line));
}

test('resolves a tool to its package at latest, a dist-tag or an exact version', () => {
  assert.deepEqual(resolveTool('usage'), { name: 'usage', package: '@subset.dev/usage', bin: 'subset-usage', version: 'latest', spec: '@subset.dev/usage@latest', explicit: false });
  assert.equal(resolveTool('timer@beta').spec, '@subset.dev/timer@beta');
  assert.equal(resolveTool('minutes@0.1.0').spec, '@subset.dev/minutes@0.1.0');
  assert.equal(resolveTool('usage@0.2.0-beta.3').spec, '@subset.dev/usage@0.2.0-beta.3');
});

test('refuses unknown tools, and versions that are not a published dist-tag or exact version', () => {
  for (const argument of ['nope', 'Usage', '__proto__', 'toString', '@subset.dev/usage', '-x', '']) {
    assert.match(resolveTool(argument).error, /^Unknown tool/, argument);
  }
  for (const argument of ['usage@', 'usage@x', 'usage@v1', 'usage@other', 'usage@^0.2.0', 'usage@>=0', 'usage@file:../x', 'usage@git+https://x', 'usage@--registry=x', 'usage@0.2']) {
    assert.match(resolveTool(argument).error, /is not latest, beta, next or an exact version/, argument);
  }
});

test('asks npm for the tool, then runs its bin with the arguments unchanged, asking the registry nothing more', () => {
  npmCalls();
  const result = subset(['usage', 'status', '--help', 'two words', '%PATH%', 'trailing\\']);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), ['status', '--help', 'two words', '%PATH%', 'trailing\\']);
  assert.deepEqual(npmCalls(), [npmLocateArgs(resolveTool('usage'))]);
  assert.deepEqual(npmLocateArgs(resolveTool('usage')), ['exec', '--yes', '--package=@subset.dev/usage@latest', '--', 'node', '-p', 'process.env.PATH']);
});

test('runs the tool with the PATH npm reported', () => {
  const result = subset(['usage'], { TOOL_PRINT_ENV: 'PATH' });
  assert.equal(result.stdout, `/elsewhere/node_modules/.bin${path.delimiter}${path.join(modules, '.bin')}${path.delimiter}/usr/bin`);
});

test("exits with the tool's exit code, and fails when npm or the tool's bin does", () => {
  assert.equal(subset(['usage'], { TOOL_EXIT: '3' }).status, 3);
  const npmFailed = subset(['usage'], { FAKE_NPM_EXIT: '7', FAKE_TAGS_OUT: 'latest: 0.2.0\n' });
  assert.equal(npmFailed.status, 1);
  assert.match(npmFailed.stderr, /npm could not fetch @subset\.dev\/usage@latest/);
  // The fake prefix holds usage 0.2.0 only.
  assert.match(subset(['usage@0.1.0']).stderr, /its subset-usage command was not found/);
  assert.match(subset(['timer']).stderr, /its subset-timer command was not found/);
});

test('a tool that comes only with a Mac app says where to get it, without asking npm', () => {
  npmCalls();
  const result = subset(['system', 'status']);
  assert.equal(result.status, 1);
  const expected =
    process.platform === 'darwin'
      ? 'subset: system comes with the Subset System app. Install it with: subset install system\n'
      : 'subset: system comes with the Subset System app, which runs only on macOS.\n';
  assert.equal(result.stderr, expected);
  assert.deepEqual(npmCalls(), []);
});

test('prints help listing every tool and command, and its version', () => {
  for (const args of [[], ['--help'], ['-h'], ['help']]) {
    const result = subset(args);
    assert.equal(result.status, 0);
    for (const [name, tool] of Object.entries(TOOLS)) assert.match(result.stdout, new RegExp(`^  ${name}\\s.*\\(${toolSource(tool).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\)$`, 'm'));
    for (const name of RESERVED_NAMES) assert.match(result.stdout, new RegExp(`^  ${name}\\s+${VERBS[name].summary}$`, 'm'), name);
    assert.doesNotMatch(result.stdout, /not available yet/);
  }
  assert.equal(subset(['--version']).stdout.trim(), version);
});

test('fails with exit code 2 and starts nothing for an unknown tool', () => {
  npmCalls();
  const result = subset(['nope']);
  assert.equal(result.status, 2);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /Unknown tool "nope"/);
  assert.deepEqual(npmCalls(), []);
});

test('reserves the command names: no tool takes one, and resolving one as a tool is refused', () => {
  assert.deepEqual([...RESERVED_NAMES].sort(), ['help', 'install', 'list', 'uninstall', 'update', 'version']);
  for (const name of Object.keys(TOOLS)) assert.ok(!RESERVED_NAMES.includes(name), `the tool "${name}" takes a reserved command name`);
  for (const name of RESERVED_NAMES) {
    assert.match(resolveTool(name).error, /is a subset command, not a tool/, name);
    assert.match(resolveTool(`${name}@beta`).error, /is a subset command, not a tool/, name);
  }
});

// `subset list`, install, update and uninstall run in test/list.test.mjs, test/install.test.mjs and
// test/update.test.mjs; here, only that a usage error starts no npm.
test('runs update and uninstall as commands: a usage error exits 2, starting no npm', () => {
  npmCalls();
  const update = 'Usage: subset update [<app>...] [--beta] [--quit]';
  const uninstall = 'Usage: subset uninstall <app> [--quit]';
  for (const [args, message] of [
    [['update', '--force'], `subset update does not take the option "--force". ${update}`],
    [['uninstall'], `subset uninstall needs an app; subset list shows them. ${uninstall}`],
    [['uninstall', 'breaks', 'timer'], `subset uninstall takes one app, not "breaks" and "timer". ${uninstall}`],
    [['update', '--', '--help'], `subset update does not take the option "--". ${update}`]
  ]) {
    const result = subset(args);
    assert.equal(result.status, 2, args.join(' '));
    assert.equal(result.stdout, '', args.join(' '));
    assert.equal(result.stderr, `subset: ${message}\n`, args.join(' '));
  }
  assert.deepEqual(npmCalls(), []);
});

test("prints a command's usage for subset help <command> and subset <command> --help", () => {
  npmCalls();
  for (const verb of RESERVED_NAMES) {
    // `subset help --help` is the launcher's help, and `subset help <tool>` points to the tool's.
    for (const args of verb === 'help' ? [['help', 'help']] : [['help', verb], [verb, '--help'], [verb, 'timer', '-h']]) {
      const result = subset(args);
      assert.equal(result.status, 0, args.join(' '));
      assert.equal(result.stderr, '', args.join(' '));
      assert.ok(result.stdout.startsWith(`Usage: ${VERBS[verb].usage}\n`), args.join(' '));
      assert.equal(result.stdout.includes('Not available yet'), false, args.join(' '));
    }
  }
  assert.ok(subset(['help', 'install']).stdout.startsWith('Usage: subset install <app> [--beta] [--user] [--dir <folder>]\n'));
  assert.deepEqual(npmCalls(), []);
});

test('subset help points to a tool\'s own help, and refuses an unknown topic with exit code 2', () => {
  const tool = subset(['help', 'usage']);
  assert.equal(tool.status, 0);
  assert.match(tool.stdout, /"subset usage --help" shows the help of usage \(@subset\.dev\/usage\)/);
  const unknown = subset(['help', 'nope']);
  assert.equal(unknown.status, 2);
  assert.equal(unknown.stdout, '');
  assert.match(unknown.stderr, /Unknown command "nope"/);
  assert.equal(subset(['version']).stdout.trim(), version);
});

test('routes arguments to help, version, a command or a tool', () => {
  const isTool = (name) => Object.hasOwn(TOOLS, name);
  assert.deepEqual(route([], { isTool }), { action: 'help' });
  assert.deepEqual(route(['help', '--help'], { isTool }), { action: 'help' });
  assert.deepEqual(route(['version', 'x'], { isTool }), { action: 'version' });
  assert.deepEqual(route(['list', '--json'], { isTool }), { action: 'command', verb: 'list', args: ['--json'] });
  assert.deepEqual(route(['list', '--', '--help'], { isTool }), { action: 'command', verb: 'list', args: ['--', '--help'] });
  assert.deepEqual(route(['install', 'breaks'], { isTool }), { action: 'command', verb: 'install', args: ['breaks'] });
  assert.deepEqual(route(['update', 'breaks', '--quit'], { isTool }), { action: 'command', verb: 'update', args: ['breaks', '--quit'] });
  assert.deepEqual(route(['uninstall', 'breaks'], { isTool }), { action: 'command', verb: 'uninstall', args: ['breaks'] });
  // A tool's arguments, --help included, go to the tool.
  assert.deepEqual(route(['usage', 'list', '--help'], { isTool }), { action: 'tool', argument: 'usage', args: ['list', '--help'] });
  assert.deepEqual(route(['install@beta'], { isTool }), { action: 'tool', argument: 'install@beta', args: [] });
});

test('says why npm could not fetch a tool, asking the registry once', () => {
  const cases = [
    // No such package on npm: with --json, npm prints the E404 error on stdout.
    [{ FAKE_TAGS_EXIT: '1', FAKE_TAGS_OUT: JSON.stringify({ error: { code: 'E404', summary: 'Not Found' } }) }, 'subset: usage is not on npm yet.\n'],
    // Only a beta.
    [{ FAKE_TAGS_OUT: 'beta: 0.2.0-beta.1\n' }, 'subset: usage has no live release yet; try subset usage@beta\n'],
    // The registry cannot be reached.
    [{ FAKE_TAGS_EXIT: '1', FAKE_TAGS_OUT: JSON.stringify({ error: { code: 'ENOTFOUND', summary: 'request failed' } }) }, 'subset: npm could not fetch @subset.dev/usage@latest.\n']
  ];
  for (const [extra, stderr] of cases) {
    npmCalls();
    const result = subset(['usage', 'status'], { FAKE_NPM_EXIT: '1', ...extra });
    assert.equal(result.status, 1, stderr);
    assert.equal(result.stdout, '', stderr);
    assert.equal(result.stderr, stderr);
    assert.deepEqual(npmCalls(), [npmLocateArgs(resolveTool('usage')), npmDistTagsArgs(resolveTool('usage'))], stderr);
  }
  assert.deepEqual(npmDistTagsArgs(resolveTool('timer@beta')), ['dist-tag', 'ls', '@subset.dev/timer', '--json']);
});

test('reports the fetch failure when the registry answer does not explain it', () => {
  const usage = resolveTool('usage');
  const failure = 'npm could not fetch @subset.dev/usage@latest.';
  // A live release exists, the answer is empty (what `npm view <package> dist-tags` prints for a package with only a
  // beta), unreadable or not an object, or the probe did not run or timed out.
  for (const probe of [
    { status: 0, stdout: 'beta: 0.3.0-beta.1\nlatest: 0.2.0\n' },
    { status: 0, stdout: '{"latest":"0.2.0","beta":"0.3.0-beta.1"}' },
    { status: 0, stdout: '' },
    { status: 0, stdout: 'oops' },
    { status: 0, stdout: 'beta: 0.2.0-beta.1\noops\n' },
    { status: 0, stdout: '["beta"]' },
    { status: 0, stdout: 'null' },
    { status: 1, stdout: '' },
    { status: null, stdout: '' },
    undefined
  ]) {
    assert.equal(fetchFailureMessage(usage, probe), failure, JSON.stringify(probe));
  }
  // The tags as `tag: version` lines (what npm prints) or as a JSON object.
  const hint = 'usage has no live release yet; try subset usage@beta';
  assert.equal(fetchFailureMessage(usage, { status: 0, stdout: 'beta: 0.2.0-beta.1\r\nnext: 0.3.0-alpha.1\r\n' }), hint);
  assert.equal(fetchFailureMessage(usage, { status: 0, stdout: '{"beta":"0.2.0-beta.1"}' }), hint);
  // Only the default version is told to try the beta; a missing exact version or tag is the fetch failure.
  assert.equal(fetchFailureMessage(resolveTool('usage@0.9.0'), { status: 0, stdout: 'beta: 0.2.0-beta.1\n' }), 'npm could not fetch @subset.dev/usage@0.9.0.');
  assert.equal(fetchFailureMessage(resolveTool('usage@next'), { status: 1, stdout: '{"error":{"code":"E404"}}' }), 'usage is not on npm yet.');
});

// A registry on 127.0.0.1 that serves @subset.dev/usage with the given dist-tags (no package at all for null), and
// whose tarballs are missing, so npm can never fetch the tool. Counts the dist-tags requests.
async function startRegistry(tags) {
  const name = '@subset.dev/usage';
  const requests = { distTags: 0 };
  const server = createServer((request, response) => {
    const url = decodeURIComponent(request.url ?? '');
    const json = (status, body) => {
      response.writeHead(status, { 'content-type': 'application/json' });
      response.end(JSON.stringify(body));
    };
    if (url === `/-/package/${name}/dist-tags`) {
      requests.distTags += 1;
      return tags ? json(200, tags) : json(404, { error: 'Not found' });
    }
    if (url === `/${name}` && tags) {
      const { port } = server.address();
      const versions = Object.fromEntries(
        Object.values(tags).map((version) => [version, { name, version, bin: { 'subset-usage': 'cli.mjs' }, dist: { tarball: `http://127.0.0.1:${port}/${name}/-/usage-${version}.tgz` } }])
      );
      return json(200, { name, 'dist-tags': tags, versions });
    }
    return json(404, { error: 'Not found' });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return { url: `http://127.0.0.1:${server.address().port}/`, requests, close: () => server.close() };
}

// Runs the launcher with the real npm (the one running the tests, or npm from PATH) against a registry, from a folder
// outside the repository, with no user or global npm configuration.
async function subsetWithRealNpm(args, registry) {
  const folder = mkdtempSync(path.join(root, 'real-npm-'));
  for (const file of ['user.npmrc', 'global.npmrc']) writeFileSync(path.join(folder, file), '');
  const realEnv = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^npm_config_/i.test(key)));
  const child = spawn(process.execPath, [cli, ...args], {
    cwd: folder,
    env: {
      ...realEnv,
      npm_config_registry: registry.url,
      npm_config_cache: path.join(folder, 'cache'),
      npm_config_userconfig: path.join(folder, 'user.npmrc'),
      npm_config_globalconfig: path.join(folder, 'global.npmrc'),
      npm_config_fetch_retries: '0',
      npm_config_update_notifier: 'false',
      npm_config_audit: 'false',
      npm_config_fund: 'false'
    }
  });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => (stdout += chunk));
  child.stderr.on('data', (chunk) => (stderr += chunk));
  const [status] = await once(child, 'close');
  return { status, stdout, stderr };
}

test('says why the real npm could not fetch a tool, from a local registry', { timeout: 120_000 }, async () => {
  const cases = [
    // Only a beta: npm finds no `latest` to fetch, and `npm view <package> dist-tags` would print nothing.
    [{ beta: '0.2.0-beta.1' }, 'subset: usage has no live release yet; try subset usage@beta\n'],
    // No such package.
    [null, 'subset: usage is not on npm yet.\n'],
    // A live release whose tarball cannot be fetched, with or without a beta.
    [{ latest: '0.1.0' }, 'subset: npm could not fetch @subset.dev/usage@latest.\n'],
    [{ latest: '0.1.0', beta: '0.2.0-beta.1' }, 'subset: npm could not fetch @subset.dev/usage@latest.\n']
  ];
  for (const [tags, message] of cases) {
    const registry = await startRegistry(tags);
    try {
      const result = await subsetWithRealNpm(['usage', 'status'], registry);
      assert.equal(result.status, 1, `${message}${result.stderr}`);
      assert.equal(result.stdout, '', message);
      assert.ok(result.stderr.endsWith(message), `${message}${result.stderr}`);
      assert.equal(registry.requests.distTags, 1, message);
    } finally {
      registry.close();
    }
  }
});

test('tells the tool it was started as subset <tool>', () => {
  const result = subset(['usage'], { TOOL_PRINT_ENV: 'SUBSET_COMMAND', SUBSET_COMMAND: 'something else' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'subset usage');
  assert.equal(subset(['usage@0.2.0'], { TOOL_PRINT_ENV: 'SUBSET_COMMAND' }).stdout, 'subset usage');
});

test("finds a tool's bin in the first node_modules/.bin folder that holds its package", () => {
  const files = {
    '/a/node_modules/@subset.dev/usage/package.json': JSON.stringify({ name: '@subset.dev/usage', version: '0.1.0', bin: { 'subset-usage': 'dist/cli.mjs' } }),
    '/b/node_modules/@subset.dev/usage/package.json': JSON.stringify({ name: '@subset.dev/usage', version: '0.2.0', bin: { 'subset-usage': 'dist/cli.mjs' } }),
    '/c/node_modules/@subset.dev/usage/package.json': JSON.stringify({ name: '@subset.dev/usage', version: '0.3.0', bin: { 'subset-usage': '../../../escape.mjs' } }),
    '/d/node_modules/@subset.dev/usage/package.json': JSON.stringify({ name: '@subset.dev/usage', version: '0.4.0', bin: { 'subset-usage': '..cli.mjs' } }),
    '/e/node_modules/@subset.dev/usage/package.json': 'null'
  };
  const readFile = (file) => {
    if (!(file in files)) throw Object.assign(new Error('missing'), { code: 'ENOENT' });
    return files[file];
  };
  const find = (pathValue, argument) => findToolBin(pathValue, resolveTool(argument), { platform: 'linux', readFile });
  const pathValue = '/usr/bin:/x/node_modules/.bin:/a/node_modules/.bin:/b/node_modules/.bin';
  assert.equal(find(pathValue, 'usage'), '/a/node_modules/@subset.dev/usage/dist/cli.mjs');
  assert.equal(find(pathValue, 'usage@0.2.0'), '/b/node_modules/@subset.dev/usage/dist/cli.mjs');
  assert.equal(find(pathValue, 'usage@0.9.0'), undefined);
  // A bin that points outside its package is ignored.
  assert.equal(find('/c/node_modules/.bin', 'usage'), undefined);
  // A file whose name starts with `..` is still inside the package; a package.json that is not an object is skipped.
  assert.equal(find('/d/node_modules/.bin', 'usage'), '/d/node_modules/@subset.dev/usage/..cli.mjs');
  assert.equal(find('/e/node_modules/.bin:/b/node_modules/.bin', 'usage'), '/b/node_modules/@subset.dev/usage/dist/cli.mjs');
  assert.equal(
    findToolBin('C:\\p\\node_modules\\.bin;C:\\Windows', resolveTool('usage'), {
      platform: 'win32',
      readFile: (file) => {
        assert.equal(file, 'C:\\p\\node_modules\\@subset.dev\\usage\\package.json');
        return JSON.stringify({ name: '@subset.dev/usage', version: '0.2.0', bin: { 'subset-usage': 'dist/cli.mjs' } });
      }
    }),
    'C:\\p\\node_modules\\@subset.dev\\usage\\dist\\cli.mjs'
  );
});

test('finds the npm to run without a shell', () => {
  const only = (...files) => (file) => files.includes(file);
  // The npm that launched the command, from npx-cli.js or npm-cli.js.
  assert.equal(
    findNpmCli({ env: { npm_execpath: '/n/lib/node_modules/npm/bin/npx-cli.js' }, platform: 'darwin', exists: only('/n/lib/node_modules/npm/bin/npm-cli.js') }),
    '/n/lib/node_modules/npm/bin/npm-cli.js'
  );
  // Not launched by npm on macOS and Linux: the caller runs npm from PATH.
  assert.equal(findNpmCli({ env: { npm_execpath: '/x/yarn.js' }, platform: 'linux', exists: () => true }), undefined);
  // On Windows, the first PATH folder with npm.cmd and its npm-cli.js, then the npm installed with Node.js.
  const execPath = 'C:\\Program Files\\nodejs\\node.exe';
  const roaming = 'C:\\Users\\a\\AppData\\Roaming\\npm';
  const bundled = 'C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\npm-cli.js';
  const winEnv = { PATH: `C:\\Windows;${roaming};C:\\Program Files\\nodejs` };
  assert.equal(
    findNpmCli({ env: winEnv, platform: 'win32', execPath, exists: only(`${roaming}\\npm.cmd`, `${roaming}\\node_modules\\npm\\bin\\npm-cli.js`, bundled) }),
    `${roaming}\\node_modules\\npm\\bin\\npm-cli.js`
  );
  assert.equal(findNpmCli({ env: winEnv, platform: 'win32', execPath, exists: only(`${roaming}\\node_modules\\npm\\bin\\npm-cli.js`, bundled) }), bundled);
  assert.equal(findNpmCli({ env: winEnv, platform: 'win32', execPath, exists: () => false }), undefined);
});

// Starts the launcher on the waiting tool, in its own process group, and sends `signal` once the tool is running: to
// the launcher's process, or with `group` to its whole process group, as a terminal does for Ctrl-C or a hangup.
// Resolves with the tool's process ID, the signals it reported and how the launcher ended.
async function signalLauncher(signal, { group = false } = {}) {
  const child = spawn(process.execPath, [cli, 'usage'], { env: { ...env, TOOL_WAIT: '1' }, detached: true });
  let stdout = '';
  child.stdout.on('data', (chunk) => {
    const first = !stdout;
    stdout += chunk;
    if (first) process.kill(group ? -child.pid : child.pid, signal);
  });
  const [code, endSignal] = await once(child, 'close');
  const [, pid, ...signals] = stdout.split(' ');
  return { sameProcess: Number(pid) === child.pid, signals, code, endSignal };
}

test('runs the tool in its own process, so each signal reaches the tool exactly once', { skip: process.platform === 'win32' }, async () => {
  for (const signal of ['SIGTERM', 'SIGHUP', 'SIGINT']) {
    for (const group of [false, true]) {
      assert.deepEqual(await signalLauncher(signal, { group }), { sameProcess: true, signals: [signal], code: 0, endSignal: null }, `${signal}${group ? ' to the group' : ''}`);
    }
  }
});
