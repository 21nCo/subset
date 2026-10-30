import type { Capture, LinkCaptureErrorCode } from './capture.js';
import { draftEdits, initialPopupState, popupTransition, type Draft, type PopupEvent, type PopupState } from './popup-state.js';
import type { SaveTarget, SaveTargetStatus } from './target.js';

export interface CapturePopupControllerOptions {
  target: SaveTarget;
  /** Reads what to save, for example `() => captureActiveTab(browser)`. */
  capture: () => Promise<Capture>;
}

export interface CapturePopupController {
  readonly state: PopupState;
  /** Calls `listener` with every new state; returns the unsubscribe function. */
  subscribe(listener: (state: PopupState) => void): () => void;
  /** From `idle`: checks the target and captures at the same time. */
  start(): Promise<void>;
  edit(draft: Partial<Draft>): void;
  /** From `editing`: saves once; a second call while saving does nothing. */
  save(): Promise<void>;
  retry(): Promise<void>;
  back(): void;
  /** The target's suggestions, trimmed and without repeats, or none when it has no `suggestTags` or it fails. */
  suggestTags(prefix: string): Promise<string[]>;
}

const CAPTURE_MESSAGES: Record<LinkCaptureErrorCode, string> = {
  'no-active-tab': 'There is no tab to save.',
  'unsupported-page': 'Only web pages (http and https) can be saved.',
  'page-unavailable': 'This page could not be read. Reload it and try again.'
};

/** Runs the popup state machine against a target: the effects of `popupTransition`, kept out of the view. */
export function createCapturePopupController(options: CapturePopupControllerOptions): CapturePopupController {
  let state = initialPopupState;
  const listeners = new Set<(state: PopupState) => void>();

  function dispatch(event: PopupEvent): boolean {
    const next = popupTransition(state, event);
    if (next === state) return false;
    state = next;
    for (const listener of listeners) listener(state);
    return true;
  }

  async function captureAndCheck(): Promise<void> {
    const [status, captured] = await Promise.all([
      // Through then(), so a target or capture that throws instead of rejecting is handled the same way.
      Promise.resolve().then(() => options.target.status()).then(
        (value) => checkedStatus(value, options.target.label),
        (error: unknown) => ({ state: 'error' as const, message: errorMessage(error, `${options.target.label} is unavailable.`) })
      ),
      Promise.resolve().then(() => options.capture()).then(
        (capture) => ({ capture }),
        (error: unknown) => ({ error })
      )
    ]);
    // The target decides first: there is no point editing a capture that cannot be saved.
    if (status.state !== 'connected') dispatch({ type: 'targetUnavailable', status });
    else if ('error' in captured) dispatch({ type: 'captureFailed', message: captureMessage(captured.error) });
    else dispatch({ type: 'captured', capture: captured.capture });
  }

  async function runSave(): Promise<void> {
    if (state.name !== 'saving') return;
    const { capture, draft } = state;
    let message: string;
    try {
      const result = await options.target.save(capture, draftEdits(draft));
      if (result.ok) {
        dispatch({ type: 'saved', result });
        return;
      }
      message = typeof result.error === 'string' && result.error ? result.error : 'The link was not saved.';
    } catch (error) {
      message = errorMessage(error, 'The link was not saved.');
    }
    dispatch({ type: 'saveFailed', message });
  }

  return {
    get state() {
      return state;
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    async start() {
      if (dispatch({ type: 'start' })) await captureAndCheck();
    },
    edit(draft) {
      dispatch({ type: 'edit', draft });
    },
    async save() {
      if (dispatch({ type: 'save' })) await runSave();
    },
    async retry() {
      if (!dispatch({ type: 'retry' })) return;
      if (state.name === 'saving') await runSave();
      else await captureAndCheck();
    },
    back() {
      dispatch({ type: 'back' });
    },
    async suggestTags(prefix) {
      if (!options.target.suggestTags) return [];
      try {
        const tags = await options.target.suggestTags(prefix);
        if (!Array.isArray(tags)) return [];
        // Trimmed and each once, in the target's order: the popup keys its list by tag.
        const found = tags.filter((tag): tag is string => typeof tag === 'string').map((tag) => tag.trim());
        return [...new Set(found)].filter((tag) => tag !== '');
      } catch {
        return [];
      }
    }
  };
}

function checkedStatus(value: SaveTargetStatus, label: string): SaveTargetStatus {
  const { state, message } = (value ?? {}) as { state?: unknown; message?: unknown };
  const text = typeof message === 'string' && message ? message : undefined;
  if (state === 'connected') return { state };
  if (state === 'needs-setup') return text ? { state, message: text } : { state };
  return { state: 'error', message: state === 'error' && text ? text : `${label} is unavailable.` };
}

/** By name and code rather than `instanceof`, so an error from another copy of this package is still recognised. */
function captureMessage(error: unknown): string {
  const { name, code } = (error ?? {}) as { name?: unknown; code?: unknown };
  const known = name === 'LinkCaptureError' && typeof code === 'string' && Object.hasOwn(CAPTURE_MESSAGES, code);
  return CAPTURE_MESSAGES[known ? (code as LinkCaptureErrorCode) : 'page-unavailable'];
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback;
}
