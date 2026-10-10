import type { Page } from 'playwright-core';
import { MinutesError } from '../driver.js';
import type { MeetingLink } from '../link.js';
import type { PlatformAdapter } from './adapter.js';
import { waitForAdmission } from './admission.js';

type Log = (message: string) => void;

/**
 * Zoom web client join flow (ported from the MeetingRecordingPOC bot runtime). The link is opened as
 * `/wc/join/<id>` (see `parseMeetingLink`) so the native Zoom app is never launched.
 */
export const zoom: PlatformAdapter = {
  platform: 'zoom',
  usesPersistentProfile: false,
  endSelectors: ['[data-testid="meeting-ended"]', '.meeting-ended-container', 'div:has-text("This meeting has been ended")', 'div:has-text("This meeting has ended")'],
  leaveSelectors: ['button[aria-label="Leave"]', 'button:has-text("Leave")', 'button:has-text("Leave Meeting")'],
  join: joinZoom,
};

async function joinZoom(page: Page, link: MeetingLink, displayName: string, log: Log): Promise<void> {
  log('Opening the Zoom web client…');
  await page.goto(link.joinUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });
  await dismissNativeAppPrompt(page, log);
  await fillDisplayName(page, displayName, log);
  await dismissBanners(page);
  await clickJoin(page, log);
  await waitForMeetingRoom(page, log);
  await handleAudioDialog(page, log);
}

async function dismissNativeAppPrompt(page: Page, log: Log): Promise<void> {
  const candidates = [
    'a:has-text("Join from your Browser")',
    'button:has-text("Join from Your Browser")',
    '[data-testid="join-from-browser"]',
  ];
  for (const selector of candidates) {
    try {
      const element = page.locator(selector).first();
      if (await element.isVisible({ timeout: 4_000 })) {
        await element.click();
        log('Dismissed the native-app prompt; using the browser.');
        await page.waitForLoadState('domcontentloaded');
        return;
      }
    } catch { /* not shown */ }
  }
}

async function fillDisplayName(page: Page, displayName: string, log: Log): Promise<void> {
  const candidates = [
    '#input-for-name',
    'input[id*="name" i]',
    'input[placeholder*="name" i]',
    'input[aria-label*="name" i]',
    '[data-testid="name-input"]',
  ];
  for (const selector of candidates) {
    try {
      const element = page.locator(selector).first();
      if (await element.isVisible({ timeout: 5_000 })) {
        await element.fill(displayName);
        log(`Entered the display name "${displayName}".`);
        return;
      }
    } catch { /* next */ }
  }
  log('No name field found.');
}

async function dismissBanners(page: Page): Promise<void> {
  const candidates = ['button:has-text("Accept")', 'button:has-text("I Accept")', 'button:has-text("Got it")', '[aria-label="Close"]'];
  for (const selector of candidates) {
    try {
      const element = page.locator(selector).first();
      if (await element.isVisible({ timeout: 1_000 })) {
        await element.click();
        await page.waitForTimeout(300);
      }
    } catch { /* ignore */ }
  }
}

async function clickJoin(page: Page, log: Log): Promise<void> {
  const candidates = ['[data-testid="join-btn"]', '#join-btn', 'button:has-text("Join")', '.join-btn'];
  for (const selector of candidates) {
    try {
      const element = page.locator(selector).first();
      if (await element.isVisible({ timeout: 5_000 })) {
        await element.click();
        log('Clicked the join button.');
        return;
      }
    } catch { /* next */ }
  }
  try {
    await page.getByRole('button', { name: /^join$/i }).first().click({ timeout: 15_000 });
  } catch {
    throw new MinutesError('join_failed', 'The Zoom web client showed no join button. The meeting may require sign-in, or the page layout changed.');
  }
  log('Clicked the join button (ARIA fallback).');
}

async function waitForMeetingRoom(page: Page, log: Log): Promise<void> {
  log('Waiting for the Zoom meeting room…');
  const inRoomSelectors = ['#wc-footer', '.meeting-client-inner', '[data-testid="meeting-info-container"]', 'button[aria-label="Leave"]'];
  const result = await waitForAdmission(page, inRoomSelectors, 10 * 60_000);
  if (result === 'closed') throw new MinutesError('join_failed', 'The Zoom page closed before the bot reached the meeting room.');
  if (result === 'timeout') throw new MinutesError('join_failed', 'The bot did not reach the Zoom meeting room within 10 minutes.');
  log('Inside the Zoom meeting room.');
}

async function handleAudioDialog(page: Page, log: Log): Promise<void> {
  // Zoom asks how to join audio on entry: use computer audio so remote tracks arrive. The prompt can mount
  // after the room, so wait for it (isVisible() checks only once and ignores its timeout).
  const appears = (selector: string, timeout: number) =>
    page.locator(selector).first().waitFor({ state: 'visible', timeout }).then(() => true, () => false);
  try {
    const joinAudio = '[data-testid="join-audio-by-voip"], button:has-text("Join Audio by Computer")';
    if (await appears(joinAudio, 10_000)) {
      await page.locator(joinAudio).first().click();
      log('Joined computer audio.');
    } else {
      log('No "Join Audio by Computer" prompt appeared; participant audio may not be recorded.');
    }
  } catch { /* not shown */ }
  // Prefix matches only: "Unmute" and "Start video" labels must never be clicked.
  try {
    const muteMic = 'button[aria-label^="mute" i]';
    if (await appears(muteMic, 3_000)) {
      await page.locator(muteMic).first().click();
      log('Muted the microphone.');
    }
  } catch { /* already muted */ }
  try {
    const stopVideo = 'button[aria-label^="stop video" i], button[aria-label^="stop my video" i]';
    if (await appears(stopVideo, 3_000)) {
      await page.locator(stopVideo).first().click();
      log('Turned off the camera.');
    }
  } catch { /* already off */ }
}
