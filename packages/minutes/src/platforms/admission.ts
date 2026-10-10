import type { Page } from 'playwright-core';

export type AdmissionResult = 'admitted' | 'closed' | 'timeout';

/**
 * Waits until one of `selectors` appears (the bot is in the meeting), the page closes, or `timeoutMs`
 * passes. While waiting it calls `check` every few seconds, so a rejection shown on screen fails the
 * join promptly instead of after the full timeout; `check` throws to reject.
 */
export async function waitForAdmission(
  page: Page,
  selectors: readonly string[],
  timeoutMs: number,
  check?: () => Promise<void>,
): Promise<AdmissionResult> {
  let settled = false;
  let timer: NodeJS.Timeout | undefined;
  try {
    return await new Promise<AdmissionResult>((resolve, reject) => {
      const finish = (result: AdmissionResult) => { if (!settled) { settled = true; resolve(result); } };
      for (const selector of selectors) {
        page.waitForSelector(selector, { timeout: timeoutMs }).then(() => finish('admitted'), () => {});
      }
      page.waitForEvent('close', { timeout: timeoutMs }).then(() => finish('closed'), () => {});
      timer = setTimeout(() => finish('timeout'), timeoutMs);
      if (check) {
        void (async () => {
          while (!settled) {
            await new Promise((wait) => setTimeout(wait, 3_000));
            if (settled || page.isClosed()) return;
            try {
              await check();
            } catch (error) {
              if (!settled) { settled = true; reject(error); }
            }
          }
        })();
      }
    });
  } finally {
    settled = true;
    clearTimeout(timer);
  }
}
