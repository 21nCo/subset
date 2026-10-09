import assert from 'node:assert/strict';
import { test } from 'node:test';
import { defaultDataDirectory, defaultProfileDirectory, isMinutesDoctor, runDoctor } from '../dist/index.js';

const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

function probe(overrides = {}) {
  const files = new Set(overrides.files ?? []);
  return {
    nodeVersion: '22.13.0', platform: 'darwin', home: '/Users/me', env: {},
    isExecutable: async (file) => file === chrome && !overrides.noChrome,
    exists: async (file) => files.has(file) || file === '/' || file === '/Users' || file === '/Users/me',
    isWritable: async () => !overrides.readOnly,
    readText: async (file) => overrides.texts?.[file] ?? null,
    ...overrides.probe,
  };
}

const directories = { profileDirectory: '/Users/me/profile', outputDirectory: '/Users/me/Documents/Minutes Recordings' };

test('passes when Node, Chrome, and the output folder are usable; sign-in is advice', async () => {
  const result = await runDoctor(directories, probe());
  assert.equal(isMinutesDoctor(result), true);
  assert.equal(result.ok, true);
  assert.equal(result.chromePath, chrome);
  const profile = result.checks.find((check) => check.id === 'profile');
  assert.deepEqual([profile.ok, profile.required], [false, false]);
});

test('fails on old Node, missing Chrome, or an unwritable folder', async () => {
  for (const overrides of [{ probe: { nodeVersion: '20.11.0' } }, { noChrome: true }, { readOnly: true }]) {
    const result = await runDoctor(directories, probe(overrides));
    assert.equal(isMinutesDoctor(result), true);
    assert.equal(result.ok, false, JSON.stringify(overrides));
  }
});

test('reports a signed-in profile without revealing the account, and a profile lock', async () => {
  const localState = JSON.stringify({ profile: { info_cache: { Default: { user_name: 'bot@example.com' } } } });
  const result = await runDoctor(directories, probe({
    files: ['/Users/me/profile', '/Users/me/profile/SingletonLock'],
    texts: { '/Users/me/profile/Local State': localState },
  }));
  assert.equal(result.checks.find((check) => check.id === 'profile').ok, true);
  assert.equal(result.checks.find((check) => check.id === 'profile_lock').ok, false);
  assert.equal(JSON.stringify(result).includes('bot@example.com'), false);
});

test('honours the Chrome override and data-directory environment', async () => {
  const override = await runDoctor(directories, probe({ probe: { env: { SUBSET_MINUTES_CHROME_PATH: '/opt/chrome' }, isExecutable: async (file) => file === '/opt/chrome' } }));
  assert.equal(override.chromePath, '/opt/chrome');
  assert.equal(defaultDataDirectory({ platform: 'darwin', home: '/Users/me', env: {} }), '/Users/me/Library/Application Support/Subset Minutes');
  assert.equal(defaultDataDirectory({ platform: 'linux', home: '/home/me', env: {} }), '/home/me/.local/share/subset/minutes');
  assert.equal(defaultProfileDirectory({ platform: 'darwin', home: '/Users/me', env: { SUBSET_MINUTES_DATA_DIR: '/data' } }), '/data/google-meet-bot-profile');
  assert.equal(defaultProfileDirectory({ platform: 'darwin', home: '/Users/me', env: { SUBSET_MINUTES_PROFILE_DIR: '/p' } }), '/p');
});
