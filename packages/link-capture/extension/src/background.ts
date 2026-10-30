import { getRuntime } from '@extfn/core';
import { captureFromContextMenu, registerLinkContextMenu, type LinkMenuClick } from '@subset.dev/link-capture';
import { createLocalTarget } from './local-target.js';

const { browser } = getRuntime();
const target = createLocalTarget(browser);

// Registered while the worker's first run is still synchronous, so a click that starts the worker is delivered.
void browser.call('contextMenus.onClicked.addListener', (info: LinkMenuClick) => {
  const capture = captureFromContextMenu(info);
  if (capture) void target.save(capture, {});
});

void registerLinkContextMenu(browser, { title: 'Save link on this device' });
