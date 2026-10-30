import { getRuntime } from '@extfn/core';
import { mountSveltePage } from '@extfn/svelte';
import { captureActiveTab } from '@subset.dev/link-capture';
import CapturePopup from '@subset.dev/link-capture/popup';
import { createLocalTarget } from './local-target.js';

const { browser } = getRuntime();

mountSveltePage(CapturePopup, {
  props: { target: createLocalTarget(browser), capture: () => captureActiveTab(browser) }
});
