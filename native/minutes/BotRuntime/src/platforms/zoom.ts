import type { Page } from 'playwright-core';
import { status } from '../status.js';

/**
 * Zoom Web Client join flow.
 *
 * Converts any zoom.us/j/{id} link to the web-client URL so we never
 * trigger the native Zoom app install prompt.
 */

export function normaliseZoomUrl(rawUrl: string): string {
  const url = new URL(rawUrl);

  // Already a web-client URL → return as-is.
  if (url.pathname.startsWith('/wc/')) return rawUrl;

  // /j/{id}?pwd={pwd} → /wc/join/{id}?pwd={pwd}
  const match = url.pathname.match(/^\/j\/(\d+)/);
  if (match) {
    url.pathname = `/wc/join/${match[1]}`;
    return url.toString();
  }

  return rawUrl;
}

export async function joinZoom(page: Page, rawUrl: string, displayName: string): Promise<void> {
  const webUrl = normaliseZoomUrl(rawUrl);
  status(`Navigating to Zoom Web Client: ${webUrl}`);
  await page.goto(webUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });

  // Zoom sometimes shows an interstitial asking to open the native app.
  await dismissNativeAppPrompt(page);

  // Fill the display name.
  await fillDisplayName(page, displayName);

  // Agree to any ToS / cookie dialogs.
  await dismissBanners(page);

  // Click join.
  await clickJoin(page);

  // Wait for the meeting room UI.
  await waitForMeetingRoom(page);

  // Handle the audio join dialog that appears after entry.
  await handleAudioDialog(page);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function dismissNativeAppPrompt(page: Page): Promise<void> {
  const candidates = [
    'a:has-text("Join from your Browser")',
    'button:has-text("Join from Your Browser")',
    '[data-testid="join-from-browser"]',
    'a[href*="browser"]',
  ];
  for (const sel of candidates) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 4_000 })) {
        await el.click();
        status('Dismissed native-app prompt — using browser');
        await page.waitForLoadState('domcontentloaded');
        return;
      }
    } catch { /* no prompt shown */ }
  }
}

async function fillDisplayName(page: Page, displayName: string): Promise<void> {
  const candidates = [
    '#input-for-name',
    'input[id*="name" i]',
    'input[placeholder*="name" i]',
    'input[aria-label*="name" i]',
    '[data-testid="name-input"]',
  ];
  for (const sel of candidates) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 5_000 })) {
        await el.fill(displayName);
        status(`Entered display name: ${displayName}`);
        return;
      }
    } catch { /* next */ }
  }
  status('Name input not found');
}

async function dismissBanners(page: Page): Promise<void> {
  const candidates = [
    'button:has-text("Accept")',
    'button:has-text("I Accept")',
    'button:has-text("Got it")',
    '[aria-label="Close"]',
  ];
  for (const sel of candidates) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 1_000 })) {
        await el.click();
        await page.waitForTimeout(300);
      }
    } catch { /* ignore */ }
  }
}

async function clickJoin(page: Page): Promise<void> {
  const candidates = [
    '[data-testid="join-btn"]',
    '#join-btn',
    'button:has-text("Join")',
    'button[type="submit"]:has-text("Join")',
    '.join-btn',
  ];
  for (const sel of candidates) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 5_000 })) {
        await el.click();
        status('Clicked join button');
        return;
      }
    } catch { /* next */ }
  }
  // ARIA fallback
  const btn = page.getByRole('button', { name: /^join$/i }).first();
  await btn.click({ timeout: 15_000 });
  status('Clicked join button (ARIA fallback)');
}

async function waitForMeetingRoom(page: Page): Promise<void> {
  status('Waiting for Zoom meeting room…');
  const inRoomSelectors = [
    '[aria-label*="Leave" i]',
    '[aria-label*="End" i]',
    '#wc-footer',
    '.meeting-client-inner',
    '[data-testid="meeting-info-container"]',
  ];
  await Promise.race([
    ...inRoomSelectors.map((sel) =>
      page.waitForSelector(sel, { timeout: 60_000 }).catch(() => null)
    ),
    page.waitForTimeout(60_000),
  ]);
  status('Inside Zoom meeting room');
}

async function handleAudioDialog(page: Page): Promise<void> {
  // Zoom shows an "Audio" dialog on entry — join computer audio.
  try {
    const joinAudio = page.locator(
      '[data-testid="join-audio-by-voip"], button:has-text("Join Audio by Computer")'
    ).first();
    if (await joinAudio.isVisible({ timeout: 5_000 })) {
      await joinAudio.click();
      status('Joined computer audio');
    }
  } catch { /* dialog not shown */ }

  // Mute microphone if it's active.
  try {
    const muteMic = page.locator(
      '[aria-label*="mute" i][aria-pressed="false"], [data-testid="microphone-btn"][aria-pressed="false"]'
    ).first();
    if (await muteMic.isVisible({ timeout: 3_000 })) {
      await muteMic.click();
      status('Muted microphone');
    }
  } catch { /* already muted */ }

  // Turn off camera.
  try {
    const stopCam = page.locator(
      '[aria-label*="stop video" i], [data-testid="video-btn"][aria-pressed="false"]'
    ).first();
    if (await stopCam.isVisible({ timeout: 3_000 })) {
      await stopCam.click();
      status('Turned off camera');
    }
  } catch { /* already off */ }
}
