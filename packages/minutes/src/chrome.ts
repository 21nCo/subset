import { mkdir } from 'node:fs/promises';
import { chromium, type Browser, type BrowserContext, type Page } from 'playwright-core';
import type { Platform } from './contract.js';
import { findChrome, systemProbe } from './doctor.js';
import { MinutesError, type EndSignal, type MeetingDriver, type MeetingPage, type OpenOptions } from './driver.js';
import type { MeetingLink } from './link.js';
import { installAudioCapture, type AudioCapture } from './audio/capture.js';
import type { PlatformAdapter } from './platforms/adapter.js';
import { googleMeet } from './platforms/google-meet.js';
import { zoom } from './platforms/zoom.js';

export const platformAdapters: Record<Platform, PlatformAdapter> = { 'google-meet': googleMeet, zoom };

/** Chrome flags: auto-accept media prompts (the bot mutes itself), allow audio without a gesture, hide automation hints. */
export const chromeArguments = [
  '--use-fake-ui-for-media-stream',
  '--autoplay-policy=no-user-gesture-required',
  '--disable-blink-features=AutomationControlled',
  '--no-first-run',
  '--no-default-browser-check',
  '--window-size=1280,800',
];

export interface ChromeDriverOptions {
  /** Defaults to `findChrome()`. */
  executablePath?: string;
  headless?: boolean;
}

/** Drives the system Google Chrome with playwright-core. No browser is downloaded. */
export function createChromeDriver(options: ChromeDriverOptions = {}): MeetingDriver {
  return {
    async open({ platform, profileDirectory, log }: OpenOptions): Promise<MeetingPage> {
      const executablePath = options.executablePath ?? (await findChrome(systemProbe()));
      if (!executablePath) {
        throw new MinutesError('chrome_not_found', 'Google Chrome or Chromium was not found. Install Chrome or set SUBSET_MINUTES_CHROME_PATH.');
      }
      const adapter = platformAdapters[platform];
      const launch = {
        executablePath,
        headless: options.headless ?? false,
        args: chromeArguments,
        ignoreDefaultArgs: ['--enable-automation'],
        // The CLI owns signals: it stops the recorder and closes Chrome itself. Playwright's own
        // handlers would kill Chrome first and lose the final audio slice.
        handleSIGINT: false,
        handleSIGTERM: false,
        handleSIGHUP: false,
      };
      log(`Starting Chrome (${executablePath}).`);

      let browser: Browser | undefined;
      let context: BrowserContext;
      if (adapter.usesPersistentProfile) {
        await mkdir(profileDirectory, { recursive: true, mode: 0o700 });
        try {
          context = await chromium.launchPersistentContext(profileDirectory, launch);
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          if (/ProcessSingleton|SingletonLock|already in use|profile.*in use/i.test(message)) {
            throw new MinutesError('profile_in_use', `Chrome already has the bot profile open (${profileDirectory}). Quit that Chrome window and try again.`);
          }
          throw error;
        }
      } else {
        browser = await chromium.launch(launch);
        context = await browser.newContext();
      }

      const page = context.pages()[0] ?? (await context.newPage());
      page.setDefaultTimeout(30_000);
      return new ChromeMeetingPage(adapter, page, context, browser, log);
    },
  };
}

class ChromeMeetingPage implements MeetingPage {
  private capture: AudioCapture | null = null;

  constructor(
    private readonly adapter: PlatformAdapter,
    private readonly page: Page,
    private readonly context: BrowserContext,
    private readonly browser: Browser | undefined,
    private readonly log: (message: string) => void,
  ) {}

  async startCapture(outputPath: string): Promise<void> {
    this.capture = await installAudioCapture(this.page, outputPath);
  }

  async join(link: MeetingLink, displayName: string, signal: AbortSignal): Promise<void> {
    if (signal.aborted) return;
    await this.context.grantPermissions(['microphone', 'camera'], { origin: new URL(link.joinUrl).origin }).catch(() => {});
    await this.adapter.join(this.page, link, displayName, this.log);
    if (!this.capture) return;
    await this.capture.begin();
    this.log('Recording started.');
    // The recorder lives in this document. A later reload of the meeting page cannot append a second
    // WebM stream to the same file, so audio after it is not recorded; say so instead of failing silently.
    const meetingDocument = this.page.mainFrame();
    let warned = false;
    this.page.on('framenavigated', (frame) => {
      if (frame !== meetingDocument || warned) return;
      warned = true;
      this.log('The meeting page reloaded; audio after this point is not in the recording.');
    });
  }

  async waitForEnd(signal: AbortSignal): Promise<EndSignal> {
    if (signal.aborted) return 'aborted';
    const controller = new AbortController();
    const watchers: Array<Promise<EndSignal | null>> = [
      ...this.adapter.endSelectors.map((selector) =>
        this.page.waitForSelector(selector, { timeout: 0 }).then(() => 'meeting_ended' as const, () => null)),
      this.page.waitForEvent('close', { timeout: 0 }).then(() => 'page_closed' as const, () => null),
      new Promise<EndSignal>((resolve) => {
        signal.addEventListener('abort', () => resolve('aborted'), { once: true, signal: controller.signal });
      }),
    ];
    // A watcher that fails (for example on navigation) yields null; keep waiting for a real signal.
    const result = await new Promise<EndSignal>((resolve) => {
      let pending = watchers.length;
      for (const watcher of watchers) {
        watcher.then((value) => {
          if (value) resolve(value);
          else if (--pending === 0) resolve('page_closed');
        });
      }
    });
    controller.abort();
    return result;
  }

  async stopCapture(): Promise<number> {
    return this.capture ? this.capture.stop() : 0;
  }

  async leave(): Promise<void> {
    if (this.page.isClosed()) return;
    for (const selector of this.adapter.leaveSelectors) {
      const button = this.page.locator(selector).first();
      if (await button.isVisible({ timeout: 1_000 }).catch(() => false)) {
        await button.click({ timeout: 2_000 }).catch(() => {});
        await this.page.waitForTimeout(500);
        return;
      }
    }
  }

  async close(): Promise<void> {
    await this.context.close().catch(() => {});
    await this.browser?.close().catch(() => {});
  }
}
