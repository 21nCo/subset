// The catalog-feed workflow's security and publishing contract (docs/catalog-feed.md), read from the files CI and
// Cloudflare use: the generate job holds no secret, only the deploy job reaches the Cloudflare token and only after
// generate, a dry run never deploys, and an invalid feed stops the run.
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';

const appDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = path.resolve(appDir, '../..');
const workflow = parse(readFileSync(path.join(repoRoot, '.github/workflows/catalog-feed.yml'), 'utf8'));
const { generate, deploy } = workflow.jobs;
const fixtures = path.join(repoRoot, 'packages/catalog/feed/fixtures');
const checkFeed = path.join(appDir, 'check-feed.mjs');
const FEED_PATH = 'apps/catalog-feed/public/catalog/v1.json';

const text = (value) => JSON.stringify(value);
const stepIndex = (job, predicate, label) => {
  const index = job.steps.findIndex(predicate);
  assert.notEqual(index, -1, `missing step: ${label}`);
  return index;
};
const runs = (fragment) => (step) => typeof step.run === 'string' && step.run.includes(fragment);
const uses = (action) => (step) => typeof step.uses === 'string' && step.uses.startsWith(`${action}@`);

test('runs on catalog changes to dev and main, releases, macOS release runs, a daily schedule, by hand, and as a dry run for pull requests', () => {
  const on = workflow.on;
  assert.deepEqual(on.push.branches, ['dev', 'main']);
  for (const required of ['packages/catalog/**', 'native/*/macos-release.json', 'release-packages.json']) {
    assert.ok(on.push.paths.includes(required), `push paths include ${required}`);
  }
  assert.deepEqual(on.release.types, ['published', 'edited', 'deleted']);
  // Beta pre-releases are created with release-macos.yml's workflow token, which fires no release event.
  const releaseWorkflow = parse(readFileSync(path.join(repoRoot, '.github/workflows/release-macos.yml'), 'utf8'));
  assert.deepEqual(on.workflow_run, { workflows: [releaseWorkflow.name], types: ['completed'] });
  assert.equal(generate.if, "github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success'");
  assert.equal(on.schedule.length, 1);
  assert.match(on.schedule[0].cron, /^\d+ \d+ \* \* \*$/, 'once a day');
  assert.equal(on.workflow_dispatch.inputs.dry_run.type, 'boolean');
  assert.deepEqual(on.pull_request.paths, on.push.paths);
  assert.equal(on.pull_request_target, undefined, 'no pull request run gets the base repository\'s secrets');
});

test('the generate job has no secrets, environment or write access', () => {
  assert.doesNotMatch(text(generate), /secrets\./, 'generate references no secret');
  assert.doesNotMatch(text(generate), /CLOUDFLARE/);
  assert.equal(generate.environment, undefined);
  assert.deepEqual(generate.permissions, { contents: 'read' });
  assert.deepEqual(workflow.permissions, { contents: 'read' });
  assert.equal(workflow.env, undefined, 'no workflow-level env reaches generate');
  assert.equal(generate.env, undefined);
  for (const step of generate.steps.filter(uses('actions/checkout'))) assert.equal(step.with['persist-credentials'], false);
});

test('only the deploy job gets the Cloudflare token, after generate and never in a dry run', () => {
  assert.deepEqual([deploy.needs].flat(), ['generate']);
  assert.equal(deploy.environment.name, 'catalog-feed');
  assert.equal(deploy.if, "github.event_name != 'pull_request' && !inputs.dry_run");
  assert.deepEqual(deploy.permissions, { contents: 'read' });
  const tokenSteps = deploy.steps.filter((step) => /secrets\./.test(text(step)));
  assert.equal(tokenSteps.length, 1, 'one step sees a secret');
  assert.deepEqual(tokenSteps[0].env.CLOUDFLARE_API_TOKEN, '${{ secrets.CLOUDFLARE_API_TOKEN }}');
  assert.match(tokenSteps[0].run, /wrangler deploy\s*$/);
  assert.doesNotMatch(tokenSteps[0].run, /--dry-run/);
  const otherJobs = Object.entries(workflow.jobs).filter(([name]) => name !== 'deploy');
  for (const [name, job] of otherJobs) assert.doesNotMatch(text(job), /secrets\./, `${name} references no secret`);
});

test('the deploy job deploys exactly the feed generate validated, installing no build code', () => {
  const steps = deploy.steps;
  const checkout = steps[stepIndex(deploy, uses('actions/checkout'), 'checkout')];
  assert.equal(checkout.with.ref, '${{ needs.generate.outputs.commit }}');
  assert.equal(checkout.with['persist-credentials'], false);
  const download = stepIndex(deploy, uses('actions/download-artifact'), 'download');
  assert.equal(`${steps[download].with.path}/v1.json`, FEED_PATH);
  const verify = stepIndex(deploy, runs('sha256sum --check'), 'sha256 check');
  assert.equal(steps[verify].env.EXPECTED_SHA256, '${{ needs.generate.outputs.sha256 }}');
  const install = stepIndex(deploy, runs('npm ci'), 'install');
  assert.match(steps[install].run, /--workspace=@subset\.dev\/catalog-feed/);
  assert.match(steps[install].run, /--ignore-scripts/);
  assert.match(steps[install].run, /--include-workspace-root=false/);
  const release = stepIndex(deploy, (step) => /secrets\./.test(text(step)), 'deploy');
  assert.ok(download < verify && verify < release && install < release, 'the checks come before the deploy');
  assert.equal(steps.slice(0, release).some((step) => /npm run|catalog-feed\.mjs/.test(text(step))), false);
});

test('the generate job validates the feed and builds the Worker before handing the feed on', () => {
  const steps = generate.steps;
  const build = stepIndex(generate, runs('scripts/catalog-feed.mjs --out'), 'generate');
  const feedStep = steps[build];
  assert.match(feedStep.run, new RegExp(`feed=${FEED_PATH.replaceAll('.', '\\.')}\\n`));
  const check = feedStep.run.indexOf('check-feed.mjs "$feed"');
  assert.ok(check > feedStep.run.indexOf('scripts/catalog-feed.mjs --out'), 'checked after it is written');
  assert.ok(check < feedStep.run.indexOf('sha256sum'), 'hashed after it is checked');
  assert.equal(feedStep.id, 'feed');
  assert.equal(generate.outputs.sha256, '${{ steps.feed.outputs.sha256 }}');
  assert.equal(generate.outputs.commit, '${{ steps.feed.outputs.commit }}');
  const dryRun = stepIndex(generate, runs('wrangler deploy --dry-run'), 'wrangler dry run');
  assert.equal(steps[dryRun]['working-directory'], 'apps/catalog-feed');
  const upload = stepIndex(generate, uses('actions/upload-artifact'), 'upload');
  assert.equal(steps[upload].with.path, FEED_PATH);
  assert.ok(build < dryRun && dryRun < upload);
});

// Evaluates the subset of GitHub's expression syntax the workflow's run conditions and concurrency group use:
// context properties, string literals, ==, !=, !, &&, || and format(). GitHub compares strings case-insensitively;
// the cases below differ by more than case.
const evaluate = (expression, { event, ref = 'refs/heads/dev', conclusion, dryRun }) => {
  const js = expression
    .replace(/\s+/g, ' ')
    .replace(/'[^']*'|==|!=/g, (token) => (token === '==' ? '===' : token === '!=' ? '!==' : token));
  assert.doesNotMatch(js.replace(/'[^']*'/g, "''"), /[^\w\s.'()!=&|,]/, `unexpected syntax in ${expression}`);
  const github = { event_name: event, ref, run_id: '42', sha: 'abc', event: { workflow_run: { conclusion } } };
  const inputs = event === 'workflow_dispatch' ? { dry_run: dryRun ?? false } : {};
  const format = (pattern, ...args) => pattern.replace(/\{(\d+)\}/g, (_, index) => String(args[Number(index)]));
  return new Function('github', 'inputs', 'format', `return (${js});`)(github, inputs, format);
};
const inside = (template) => {
  const match = /^([^$]*)\$\{\{(.*)\}\}$/s.exec(template);
  assert.ok(match, `one expression in ${template}`);
  return [match[1], match[2]];
};

test('only a run that can deploy joins the deploy group; the rest never wait for or replace a pending deploy', () => {
  const [prefix, groupExpression] = inside(workflow.concurrency.group);
  assert.equal(workflow.concurrency['cancel-in-progress'], false, 'a running deploy is never cancelled');
  assert.equal(generate.concurrency, undefined, 'the group is workflow-wide, so an older generate never deploys last');
  assert.equal(deploy.concurrency, undefined);
  const guard = generate.steps[0];
  assert.match(guard.run, /exit 1/);
  const cases = [
    { event: 'push', ref: 'refs/heads/dev' },
    { event: 'push', ref: 'refs/heads/main' },
    { event: 'release', ref: 'refs/tags/v1' },
    { event: 'schedule' },
    { event: 'workflow_run', conclusion: 'success' },
    { event: 'workflow_run', conclusion: 'failure' },
    { event: 'workflow_run', conclusion: 'cancelled' },
    { event: 'workflow_dispatch', ref: 'refs/heads/dev' },
    { event: 'workflow_dispatch', ref: 'refs/heads/main' },
    { event: 'workflow_dispatch', ref: 'refs/heads/linear/set-228' },
    { event: 'workflow_dispatch', ref: 'refs/heads/dev', dryRun: true },
    { event: 'workflow_dispatch', ref: 'refs/heads/linear/set-228', dryRun: true },
    { event: 'pull_request', ref: 'refs/pull/9/merge' },
  ];
  let deploying = 0;
  for (const run of cases) {
    const canDeploy = Boolean(evaluate(generate.if, run) && !evaluate(guard.if, run) && evaluate(deploy.if, run));
    const group = prefix + evaluate(groupExpression, run);
    assert.equal(group, canDeploy ? 'catalog-feed-deploy' : 'catalog-feed-run-42', JSON.stringify(run));
    if (canDeploy) deploying += 1;
  }
  assert.equal(deploying, 7, 'push to dev and main, release, schedule, a successful release run and dispatch on dev and main');
});

test('deploys build dev; a dry run builds its own commit', () => {
  const dryRun = "(github.event_name == 'pull_request' || inputs.dry_run)";
  const checkout = generate.steps.find(uses('actions/checkout'));
  assert.equal(checkout.with.ref, `\${{ ${dryRun} && github.sha || 'dev' }}`);
  assert.equal(workflow['run-name'], `Catalog feed\${{ ${dryRun} && ' (dry run)' || '' }}`);
  const [, ref] = inside(checkout.with.ref);
  assert.equal(evaluate(ref, { event: 'push', ref: 'refs/heads/main' }), 'dev');
  assert.equal(evaluate(ref, { event: 'workflow_dispatch', ref: 'refs/heads/x', dryRun: true }), 'abc');
  assert.equal(evaluate(ref, { event: 'pull_request' }), 'abc');
});

test('the Worker serves the feed from the 21n-dev account at subset.21n.dev with a 5-minute cache', () => {
  // wrangler.jsonc has only whole-line comments.
  const jsonc = readFileSync(path.join(appDir, 'wrangler.jsonc'), 'utf8');
  const config = JSON.parse(jsonc.split('\n').filter((line) => !/^\s*\/\//.test(line)).join('\n'));
  assert.equal(config.account_id, 'c801efc2879825babdb9b2534199c4dd');
  assert.equal(config.main, undefined, 'static assets only');
  assert.equal(config.assets.directory, './public');
  assert.equal(path.join('apps/catalog-feed', config.assets.directory, 'catalog/v1.json'), FEED_PATH);
  assert.deepEqual(config.routes, [{ pattern: 'subset.21n.dev', custom_domain: true }]);
  assert.equal(config.workers_dev, false);

  const headers = readFileSync(path.join(appDir, 'public/_headers'), 'utf8').trim().split('\n');
  assert.equal(headers[0], '/catalog/v1.json');
  assert.deepEqual(headers.slice(1).map((line) => line.trim()).sort(), ['Cache-Control: max-age=300', 'Content-Type: application/json']);
});

test('check-feed accepts every valid fixture and refuses every invalid one, so an invalid feed stops the run', () => {
  const files = readdirSync(fixtures).filter((name) => name.startsWith('catalog-'));
  assert.ok(files.some((name) => name.startsWith('catalog-valid-')) && files.some((name) => name.startsWith('catalog-invalid-')));
  for (const name of files) {
    const result = spawnSync(process.execPath, [checkFeed, path.join(fixtures, name)], { encoding: 'utf8' });
    if (name.startsWith('catalog-valid-')) {
      assert.equal(result.status, 0, `${name}: ${result.stderr}`);
      assert.match(result.stdout, /^subset\.catalog@1 generated \S+: \d+ apps \(.*\), \d+ tools \(.*\), \d+ bytes\n$/);
    } else {
      assert.equal(result.status, 1, `${name} is refused`);
      assert.match(result.stderr, /is not a valid subset\.catalog@1 feed/);
      assert.equal(result.stdout, '');
    }
  }
});

test('check-feed refuses a missing, empty or non-JSON file and needs exactly one argument', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'catalog-feed-'));
  try {
    const empty = path.join(dir, 'empty.json');
    const html = path.join(dir, 'html.json');
    writeFileSync(empty, '');
    writeFileSync(html, '<html></html>');
    for (const file of [path.join(dir, 'missing.json'), empty, html]) {
      assert.equal(spawnSync(process.execPath, [checkFeed, file]).status, 1, file);
    }
    assert.equal(spawnSync(process.execPath, [checkFeed]).status, 2);
    assert.equal(spawnSync(process.execPath, [checkFeed, empty, html]).status, 2);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the public folder commits only the headers file; the feed itself is generated', () => {
  const tracked = execFileSync('git', ['ls-files', 'public'], { cwd: appDir, encoding: 'utf8' }).trim().split('\n');
  assert.deepEqual(tracked, ['public/_headers']);
});
