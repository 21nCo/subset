// Workspace naming rules (AGENTS.md). Every workspace, published or private, and the root package use the
// @subset.dev scope: we do not own @subset on npm, so a private @subset/* name could clash with someone else's
// published package. App hosts must remain private.
export const WORKSPACE_NAME = /^@subset\.dev\/[a-z0-9-]+$/;

/** Problems with a workspace manifest's name and privacy; `kind` is its folder, 'packages' or 'apps'. */
export function workspaceManifestProblems(kind, manifest) {
  const problems = [];
  if (typeof manifest.name !== 'string' || !WORKSPACE_NAME.test(manifest.name)) problems.push(`${manifest.name} must be named @subset.dev/<name>`);
  if (typeof manifest.private !== 'boolean') problems.push(`${manifest.name} must declare whether it is private`);
  else if (kind === 'apps' && !manifest.private) problems.push(`${manifest.name} is an app host and must remain private`);
  return problems;
}

const REPOSITORY_URL = 'git+https://github.com/21nCo/subset.git';
const EXACT_VERSION = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
// The versions a <slug>-v<version> release tag can name (scripts/resolve-release-tag.mjs).
const RELEASE_VERSION = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

/**
 * Problems with a public workspace's manifest for npm: what it ships, where it came from, and how it depends on
 * other workspaces. `path` is its folder (`packages/<name>`) and `workspaces` maps every workspace name to its
 * manifest. A private workspace is never published, so a published package bundles it (a devDependency, `*`). A
 * public one is published on its own, so a package may depend on it at runtime with `^<its version>`, which npm
 * links in the repository and resolves from the registry once that version is published.
 */
export function publishedManifestProblems(manifest, path, workspaces) {
  const name = manifest.name;
  const problems = [];
  if (manifest.private !== false) problems.push(`${name} must set "private": false`);
  if (typeof manifest.version !== 'string' || !RELEASE_VERSION.test(manifest.version)) {
    problems.push(`${name} must have a release version x.y.z (found ${manifest.version})`);
  }
  if (typeof manifest.license !== 'string' || !manifest.license) problems.push(`${name} must declare a license`);
  if (manifest.repository?.url !== REPOSITORY_URL || manifest.repository?.directory !== path) {
    problems.push(`${name} must name its repository ${REPOSITORY_URL} and directory ${path}`);
  }
  if (manifest.publishConfig?.access !== 'public') problems.push(`${name} must set publishConfig.access to public`);
  if (!Array.isArray(manifest.files) || manifest.files.length === 0) problems.push(`${name} must list its published files`);
  if (manifest.exports === undefined && manifest.bin === undefined) problems.push(`${name} must declare exports or bin`);
  for (const field of ['dependencies', 'optionalDependencies', 'peerDependencies']) {
    for (const [dependency, version] of Object.entries(manifest[field] ?? {})) {
      const workspace = workspaces.get(dependency);
      if (workspace === undefined) {
        // External runtime dependencies are pinned, so a release installs what was tested.
        if (field !== 'peerDependencies' && !EXACT_VERSION.test(String(version))) {
          problems.push(`${name} must pin ${dependency} to an exact version (found ${version})`);
        }
      } else if (workspace.private !== false) {
        problems.push(`${name} cannot depend at runtime on private workspace ${dependency}; bundle it instead`);
      } else if (version !== `^${workspace.version}`) {
        problems.push(`${name} must depend on ${dependency} as ^${workspace.version} (found ${version})`);
      }
    }
  }
  return problems;
}
