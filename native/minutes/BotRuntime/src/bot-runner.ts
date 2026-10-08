import { existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium, type Browser, type BrowserContext, type Page } from 'playwright-core';
import { setupAudioCapture } from './audio/capture.js';
import { joinGoogleMeet } from './platforms/google-meet.js';
import { joinZoom, normaliseZoomUrl } from './platforms/zoom.js';
import { ended, error, joined, status } from './status.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export type Platform = 'google-meet' | 'zoom' | 'auto';

export interface BotOptions {
  url: string;
  displayName?: string;
  platform?: Platform;
  recordingDir?: string;
  headless?: boolean;
}

export async function runBot(opts: BotOptions): Promise<void> {
  const {
    url,
    displayName = 'Recording Bot',
    platform = 'auto',
    recordingDir = path.join(process.cwd(), 'recordings'),
    headless = false,
  } = opts;

  const resolvedPlatform = platform === 'auto' ? detectPlatform(url) : platform;
  status(`Starting ${resolvedPlatform} bot for: ${url}`);

  const execPath = findChromePath();
  status(`Using Chrome: ${execPath}`);

  const userDataDir = resolveBotProfileDir();
  status(`Profile: ${userDataDir}`);

  let context: BrowserContext | undefined;
  let browser: Browser | undefined;

  // For persistent context (reuses login cookies) use launchPersistentContext.
  // For Zoom we don't need a persistent profile so we use a regular launch.
  if (resolvedPlatform === 'google-meet') {
    try {
      context = await chromium.launchPersistentContext(userDataDir, {
        executablePath: execPath,
        headless,
        args: chromiumArgs(),
        permissions: ['microphone', 'camera'],
        ignoreDefaultArgs: ['--enable-automation'],
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      if (/ProcessSingleton|profile.*already.*use|profile directory.*already in use/i.test(message)) {
        throw new Error(
          `Bot Chrome profile is already open: ${userDataDir}. ` +
          'Close the setup/login Chrome window and retry Start Bot.'
        );
      }
      throw err;
    }
  } else {
    browser = await chromium.launch({
      executablePath: execPath,
      headless,
      args: chromiumArgs(),
      ignoreDefaultArgs: ['--enable-automation'],
    });
    context = await browser.newContext({
      permissions: ['microphone', 'camera'],
    });
  }

  const page = await context.newPage();
  page.setDefaultTimeout(30_000);

  // Grant microphone/camera inside the page context.
  await context.grantPermissions(['microphone', 'camera'], {
    origin: resolvedPlatform === 'google-meet'
      ? 'https://meet.google.com'
      : 'https://zoom.us',
  });

  // Set up audio capture before navigating so the init script is injected.
  const { stop: stopAudio } = await setupAudioCapture(page, recordingDir, url);

  // Navigate and join.
  await page.goto(
    resolvedPlatform === 'zoom' ? normaliseZoomUrl(url) : url,
    { waitUntil: 'domcontentloaded', timeout: 30_000 }
  );

  if (resolvedPlatform === 'google-meet') {
    await joinGoogleMeet(page, displayName);
  } else {
    await joinZoom(page, url, displayName);
  }

  joined(resolvedPlatform, url);
  status('Bot is live in the meeting. Waiting for meeting end or SIGINT…');

  // Keep alive until SIGINT or the meeting ends.
  await waitForEnd(page, resolvedPlatform);

  stopAudio();
  ended('meeting_ended');

  await context.close();
  if (browser) await browser.close();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function detectPlatform(url: string): 'google-meet' | 'zoom' {
  if (url.includes('meet.google.com')) return 'google-meet';
  if (url.includes('zoom.us')) return 'zoom';
  throw new Error(`Cannot auto-detect platform from URL: ${url}`);
}

function chromiumArgs(): string[] {
  return [
    '--no-sandbox',
    '--disable-setuid-sandbox',
    '--use-fake-ui-for-media-stream',       // auto-approve camera/mic dialogs
    '--disable-blink-features=AutomationControlled',
    '--disable-infobars',
    '--window-size=1280,800',
    '--disable-dev-shm-usage',
    '--disable-gpu',
  ];
}

function findChromePath(): string {
  const candidates = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ];
  const found = candidates.find(existsSync);
  if (!found) {
    throw new Error(
      'Google Chrome or Chromium not found. Install Chrome from https://google.com/chrome'
    );
  }
  return found;
}

function resolveBotProfileDir(): string {
  if (process.env.MEETING_BOT_PROFILE_DIR) {
    return path.resolve(process.env.MEETING_BOT_PROFILE_DIR);
  }

  if (process.platform === 'darwin') {
    return path.join(
      os.homedir(),
      'Library',
      'Application Support',
      'Subset Minutes',
      'google-meet-bot-profile',
    );
  }

  return path.resolve(process.cwd(), '.profiles/google-meet-bot');
}

async function waitForEnd(page: Page, platform: Platform): Promise<void> {
  const leaveSelectors =
    platform === 'google-meet'
      ? [
          '[jsname="CYnFNe"]',              // "Leave call" confirmation
          'button:has-text("Leave call")',
          '[data-call-ended="true"]',
        ]
      : [
          '[data-testid="meeting-ended"]',
          '.meeting-ended-container',
          'div:has-text("This meeting has ended")',
        ];

  const detected = await Promise.race([
    // Meeting ended on its own.
    ...leaveSelectors.map((sel) =>
      page.waitForSelector(sel, { timeout: 4 * 60 * 60 * 1_000 }).then(() => 'ended').catch(() => null)
    ),
    // Page was closed / crashed.
    page.waitForEvent('close', { timeout: 4 * 60 * 60 * 1_000 }).then(() => 'closed').catch(() => null),
    // SIGINT from parent process.
    new Promise<string>((resolve) => {
      process.once('SIGINT', () => resolve('sigint'));
      process.once('SIGTERM', () => resolve('sigterm'));
    }),
  ]);

  status(`Meeting end detected: ${detected ?? 'timeout'}`);
}
