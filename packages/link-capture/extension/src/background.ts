import { getRuntime } from '@extfn/core';
import { registerLinkContextMenu, saveFromContextMenu, type LinkMenuClick } from '@subset.dev/link-capture';
import { createLocalTarget } from './local-target.js';

const { browser } = getRuntime();
const target = createLocalTarget(browser);

// Registered while the worker's first run is still synchronous, so a click that starts the worker is delivered.
// saveFromContextMenu never rejects: it reports the outcome on the toolbar button.
void browser.call('contextMenus.onClicked.addListener', (info: LinkMenuClick) => {
  void saveFromContextMenu(browser, target, info);
});

void registerLinkContextMenu(browser, { title: 'Save link on this device' });
