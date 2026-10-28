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
