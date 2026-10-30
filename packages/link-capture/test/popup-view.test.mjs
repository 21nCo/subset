import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import { parse } from 'svelte/compiler';

const source = readFileSync(new URL('../src/popup/CapturePopup.svelte', import.meta.url), 'utf8');
const ast = parse(source, { modern: true });

function attribute(node, name) {
  return node.attributes?.find((attr) => attr.type === 'Attribute' && attr.name === name);
}

// Every element with a live role, with the elements around it.
function liveRegions(node, ancestors = [], found = []) {
  if (node.type === 'RegularElement') {
    const role = attribute(node, 'role');
    const value = Array.isArray(role?.value) ? role.value.map((part) => part.data).join('') : undefined;
    if (value === 'status' || value === 'alert') found.push({ role: value, ancestors });
    ancestors = [...ancestors, node];
  }
  for (const child of node.fragment?.nodes ?? node.nodes ?? []) liveRegions(child, ancestors, found);
  for (const key of ['consequent', 'alternate', 'body', 'fallback']) if (node[key]) liveRegions(node[key], ancestors, found);
  return found;
}

describe('the capture popup view', () => {
  it('keeps one status and one alert region, neither inside an aria-busy element', () => {
    const regions = liveRegions(ast.fragment);
    assert.deepEqual(regions.map((region) => region.role).sort(), ['alert', 'status']);
    for (const region of regions) {
      assert.equal(region.ancestors.length > 0, true);
      assert.deepEqual(region.ancestors.filter((node) => attribute(node, 'aria-busy')).map((node) => node.name), []);
    }
  });
});
