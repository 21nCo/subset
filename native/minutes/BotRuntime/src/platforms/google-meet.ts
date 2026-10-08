import type { Page } from 'playwright-core';
import { status } from '../status.js';

/**
 * Google Meet pre-join and join flow.
 *
 * Selector strategy: prefer stable jsname / aria attributes. Multiple
 * candidates are tried in order; we bail early on first success.
 */

export async function joinGoogleMeet(page: Page, displayName: string): Promise<void> {
  status('Waiting for Google Meet pre-join screen…');

  // Allow React to fully mount. networkidle can time out on slow networks so
  // we also cap it with a short timeout.
  await Promise.race([
    page.waitForLoadState('networkidle'),
    page.waitForTimeout(12_000),
  ]);

  await throwIfMeetRejected(page);

  // Dismiss cookie consent / GDPR banners.
  await dismissBanners(page);

  // Guest name input — visible when the bot is not signed into a Google account.
  await fillGuestName(page, displayName);

  // Mute camera and microphone before joining so the bot is silent.
  await disableMediaDevice(page, 'camera');
  await disableMediaDevice(page, 'microphone');

  // Click the join button.
  await clickJoin(page);

  // Confirm we entered the call.
  await waitForCallUI(page);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function dismissBanners(page: Page): Promise<void> {
  const candidates = [
    'button:has-text("Accept all")',
    'button:has-text("Reject all")',
    'button:has-text("I agree")',
    'button:has-text("Got it")',
    '[aria-label="Close"]',
    '[aria-label="Dismiss"]',
  ];
  for (const sel of candidates) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 800 })) {
        await el.click();
        await page.waitForTimeout(300);
      }
    } catch { /* ignore */ }
  }
}

async function fillGuestName(page: Page, displayName: string): Promise<void> {
  // These jsname values correspond to the name input on the pre-join screen.
  const candidates = [
    'input[jsname="YPqjbf"]',
    'input[placeholder*="name" i]',
    'input[aria-label*="name" i]',
    '[data-placeholder*="name" i]',
  ];
  for (const sel of candidates) {
    try {
      const el = page.locator(sel).first();
        if (await el.isVisible({ timeout: 2_000 })) {
        await el.fill(displayName);
        status(`Entered display name: ${displayName}`);
        await page.waitForTimeout(400);
        return;
      }
    } catch { /* no guest input — already signed in */ }
  }
}

async function disableMediaDevice(page: Page, device: 'camera' | 'microphone'): Promise<void> {
  // The button is present and "active" (device ON) → we click it to turn OFF.
  // data-is-muted="false"  means device is currently ON (not muted).
  const label = device === 'camera' ? 'camera' : 'microphone';
  const jsnameOn = device === 'camera' ? 'R3Eqzd' : 'BOHaEe';

  const candidates = [
    `[jsname="${jsnameOn}"][data-is-muted="false"]`,
    `button[aria-label*="${label}" i][aria-pressed="false"]`,
    `button[aria-label*="Turn off ${label}" i]`,
    `[data-is-muted="false"][aria-label*="${label}" i]`,
  ];

  for (const sel of candidates) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 1_500 })) {
        await el.click();
        status(`Turned off ${device}`);
        return;
      }
    } catch { /* ignore */ }
  }
  status(`${device} toggle not found — may already be off`);
}

async function clickJoin(page: Page): Promise<void> {
  await throwIfMeetRejected(page);

  // Ordered by reliability. "Join now" appears when the signed-in user is a
  // meeting host/member; "Ask to join" appears for guests.
  const candidates = [
    // jsname attributes (stable internal IDs)
    'button[jsname="Qx7uuf"]',   // "Join now"
    'button[jsname="V67aGc"]',   // "Ask to join"
    // data attribute
    'button[data-premeeting-action="join-button"]',
    // text-based fallbacks via Playwright's :has-text pseudo
    'button:has-text("Join now")',
    'button:has-text("Ask to join")',
  ];

  for (const sel of candidates) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 3_000 })) {
        await el.click();
        status('Clicked join button');
        return;
      }
    } catch { /* next */ }
  }

  // Final fallback: getByRole which uses ARIA semantics — most resilient.
  await throwIfMeetRejected(page);
  const btn = page.getByRole('button', { name: /join now|ask to join/i }).first();
  await btn.click({ timeout: 15_000 });
  status('Clicked join button (ARIA fallback)');
}

async function throwIfMeetRejected(page: Page): Promise<void> {
  const text = await page.locator('body').innerText({ timeout: 2_000 }).catch(() => '');
  const normalized = text.replace(/\s+/g, ' ').trim();

  if (/you can.?t join this video call/i.test(normalized)) {
    throw new Error(
      'Google Meet rejected the bot before pre-join: "You can’t join this video call". ' +
      'Invite/admit the dedicated bot account or allow external guests for this meeting.'
    );
  }

  if (/this meeting code is invalid|meeting doesn.?t exist|meeting has ended/i.test(normalized)) {
    throw new Error(`Google Meet rejected the URL: ${normalized.slice(0, 240)}`);
  }
}

async function waitForCallUI(page: Page): Promise<void> {
  status('Confirming we are inside the call…');

  // Any of these selectors indicate the in-call UI is active.
  const inCallSelectors = [
    '[jsname="CQylAd"]',         // participant list button
    '[jsname="A5il2e"]',         // bottom control bar
    '[aria-label*="Leave call" i]',
    '[data-call-ended="false"]',
    '[aria-label*="Participants" i]',
  ];

  await Promise.race([
    ...inCallSelectors.map((sel) =>
      page.waitForSelector(sel, { timeout: 45_000 }).catch(() => null)
    ),
    page.waitForTimeout(45_000),
  ]);

  status('Inside Google Meet call');
}
