import type { Page } from 'playwright-core';
import { MinutesError } from '../driver.js';
import type { MeetingLink } from '../link.js';
import type { PlatformAdapter } from './adapter.js';

type Log = (message: string) => void;

/**
 * Google Meet pre-join and join flow (ported from the MeetingRecordingPOC bot runtime).
 * Selectors prefer stable jsname and aria attributes; several candidates are tried in order.
 */
export const googleMeet: PlatformAdapter = {
  platform: 'google-meet',
  usesPersistentProfile: true,
  endSelectors: ['[data-call-ended="true"]', 'div:has-text("You left the meeting")', 'div:has-text("The call has ended")'],
  leaveSelectors: ['button[aria-label*="Leave call" i]', '[jsname="CQylAd"][aria-label*="Leave" i]'],
  join: joinGoogleMeet,
};

async function joinGoogleMeet(page: Page, link: MeetingLink, displayName: string, log: Log): Promise<void> {
  await page.goto(link.joinUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });
  log('Waiting for the Google Meet pre-join screen…');

  // Let the page mount. networkidle can hang on slow networks, so cap it.
  await Promise.race([page.waitForLoadState('networkidle'), page.waitForTimeout(12_000)]);

  await throwIfMeetRejected(page);
  await dismissBanners(page);
  // The guest name input appears only when the bot profile is not signed in.
  await fillGuestName(page, displayName, log);
  // Mute camera and microphone before joining so the bot is silent.
  await disableMediaDevice(page, 'camera', log);
  await disableMediaDevice(page, 'microphone', log);
  await clickJoin(page, log);
  await waitForCallUI(page, log);
}

async function dismissBanners(page: Page): Promise<void> {
  const candidates = [
    'button:has-text("Accept all")',
    'button:has-text("Reject all")',
    'button:has-text("I agree")',
    'button:has-text("Got it")',
    '[aria-label="Close"]',
    '[aria-label="Dismiss"]',
  ];
  for (const selector of candidates) {
    try {
      const element = page.locator(selector).first();
      if (await element.isVisible({ timeout: 800 })) {
        await element.click();
        await page.waitForTimeout(300);
      }
    } catch { /* not shown */ }
  }
}

async function fillGuestName(page: Page, displayName: string, log: Log): Promise<void> {
  const candidates = [
    'input[jsname="YPqjbf"]',
    'input[placeholder*="name" i]',
    'input[aria-label*="name" i]',
    '[data-placeholder*="name" i]',
  ];
  for (const selector of candidates) {
    try {
      const element = page.locator(selector).first();
      if (await element.isVisible({ timeout: 2_000 })) {
        await element.fill(displayName);
        log(`Entered the display name "${displayName}".`);
        await page.waitForTimeout(400);
        return;
      }
    } catch { /* no guest input: already signed in */ }
  }
}

async function disableMediaDevice(page: Page, device: 'camera' | 'microphone', log: Log): Promise<void> {
  // data-is-muted="false" means the device is currently on, so clicking turns it off.
  const jsnameOn = device === 'camera' ? 'R3Eqzd' : 'BOHaEe';
  const candidates = [
    `[jsname="${jsnameOn}"][data-is-muted="false"]`,
    `button[aria-label*="${device}" i][aria-pressed="false"]`,
    `button[aria-label*="Turn off ${device}" i]`,
    `[data-is-muted="false"][aria-label*="${device}" i]`,
  ];
  for (const selector of candidates) {
    try {
      const element = page.locator(selector).first();
      if (await element.isVisible({ timeout: 1_500 })) {
        await element.click();
        log(`Turned off the ${device}.`);
        return;
      }
    } catch { /* next */ }
  }
  log(`No ${device} toggle found; it may already be off.`);
}

async function clickJoin(page: Page, log: Log): Promise<void> {
  await throwIfMeetRejected(page);
  // "Join now" appears for a signed-in member; "Ask to join" for a guest.
  const candidates = [
    'button[jsname="Qx7uuf"]',
    'button[jsname="V67aGc"]',
    'button[data-premeeting-action="join-button"]',
    'button:has-text("Join now")',
    'button:has-text("Ask to join")',
  ];
  for (const selector of candidates) {
    try {
      const element = page.locator(selector).first();
      if (await element.isVisible({ timeout: 3_000 })) {
        await element.click();
        log('Clicked the join button.');
        return;
      }
    } catch { /* next */ }
  }

  await throwIfMeetRejected(page);
  try {
    await page.getByRole('button', { name: /join now|ask to join/i }).first().click({ timeout: 15_000 });
  } catch {
    throw new MinutesError('join_failed', 'Google Meet showed no join button. The page layout may have changed, or the meeting is not open yet.');
  }
  log('Clicked the join button (ARIA fallback).');
}

async function throwIfMeetRejected(page: Page): Promise<void> {
  const text = await page.locator('body').innerText({ timeout: 2_000 }).catch(() => '');
  const normalized = text.replace(/\s+/g, ' ').trim();
  if (/you can.?t join this video call/i.test(normalized)) {
    throw new MinutesError(
      'join_rejected',
      'Google Meet rejected the bot ("You can\'t join this video call"). Invite or admit the bot\'s account, or allow external guests for this meeting.',
    );
  }
  if (/this meeting code is invalid|meeting doesn.?t exist|meeting has ended/i.test(normalized)) {
    throw new MinutesError('join_rejected', 'Google Meet says this meeting code is invalid or the meeting has ended.');
  }
}

async function waitForCallUI(page: Page, log: Log): Promise<void> {
  log('Waiting to be admitted to the call…');
  const inCallSelectors = [
    '[aria-label*="Leave call" i]',
    '[jsname="A5il2e"]',
    '[data-call-ended="false"]',
  ];
  const found = await Promise.race([
    ...inCallSelectors.map((selector) => page.waitForSelector(selector, { timeout: 10 * 60_000 }).then(() => true, () => false)),
    page.waitForEvent('close', { timeout: 10 * 60_000 }).then(() => false, () => false),
  ]);
  if (!found) {
    await throwIfMeetRejected(page);
    throw new MinutesError('join_failed', 'The bot was not admitted to the Google Meet call within 10 minutes.');
  }
  log('Inside the Google Meet call.');
}
