// The reference extension: the smallest host of link capture, built for both targets by `npm run build` so CI
// proves the core, the popup and the manifest build for Chromium and Firefox. Products ship their own host
// (Bookmarks: apps/bookmarks-extension, SET-183).
import { defineExtension } from '@extfn/core';
import { linkCaptureManifest } from '@subset.dev/link-capture';

export default defineExtension({
  name: 'Link capture reference',
  version: '0.1.0',
  description: 'Reference host for @subset.dev/link-capture. Saves links on this device only.',
  targets: ['chromium-mv3', 'firefox-mv3'],
  background: { serviceWorker: './src/background.ts' },
  popup: { entry: './popup.html', title: 'Save this page' },
  manifest: linkCaptureManifest()
});
