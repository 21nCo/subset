import type { Capture, LinkCaptureErrorCode } from './capture.js';
import { draftEdits, initialPopupState, popupTransition, type Draft, type PopupEvent, type PopupState } from './popup-state.js';
import type { SaveResult, SaveTarget, SaveTargetStatus } from './target.js';

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
  /**
   * The target's suggestions, trimmed and without repeats, or none when it has no `suggestTags` or it fails. Resolves
   * `undefined` when the answer is stale: a later `suggestTags` call or an edit of the tags came first.
   */
  suggestTags(prefix: string): Promise<string[] | undefined>;
  /**
   * From `editing`: replaces the tag being typed (after the last comma) with `tag`, if `tag` is in the latest current
   * `suggestTags` answer. Returns false and changes nothing for a suggestion that a newer request or a tags edit made
   * stale, so a click on a list still on screen cannot apply an answer for an older prefix.
   */
  acceptTag(tag: string): boolean;
}

const CAPTURE_MESSAGES: Record<LinkCaptureErrorCode, string> = {
  'no-active-tab': 'There is no tab to save.',
  'unsupported-page': 'Only web pages (http and https) can be saved.',
  'page-unavailable': 'This page could not be read. Reload it and try again.'
};

/** Runs the popup state machine against a target: the effects of `popupTransition`, kept out of the view. */
export function createCapturePopupController(options: CapturePopupControllerOptions): CapturePopupController {
  let state = initialPopupState;
  // Counts suggestion requests and tag edits: an answer is shown only if nothing changed the tags since it was asked.
  let suggestionRequest = 0;
  // The latest answer still current, with the request it answered.
  let offered: { request: number; tags: string[] } | undefined;
  const listeners = new Set<(state: PopupState) => void>();

  function dispatch(event: PopupEvent): boolean {
    const next = popupTransition(state, event);
    if (next === state) return false;
    state = next;
    // A throwing listener must not stop the others or the transition's effect (the save after `saving`).
    for (const listener of listeners) {
      try {
        listener(state);
      } catch (error) {
        report(error);
      }
    }
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

  // A closure, like every operation, so a method taken off the controller (`const { acceptTag } = controller`) works.
  function edit(draft: Partial<Draft>): void {
    if (draft.tags !== undefined) {
      suggestionRequest++;
      offered = undefined;
    }
    dispatch({ type: 'edit', draft });
  }

  async function runSave(): Promise<void> {
    if (state.name !== 'saving') return;
    const { capture, draft } = state;
    let message: string;
    try {
      const result: unknown = await options.target.save(capture, draftEdits(draft));
      // A target that resolves nothing or a non-object has not saved: a refusal, not a TypeError shown to the user.
      const { ok, error } = (typeof result === 'object' && result !== null ? result : {}) as { ok?: unknown; error?: unknown };
      if (ok === true) {
        dispatch({ type: 'saved', result: result as SaveResult & { ok: true } });
        return;
      }
      message = typeof error === 'string' && error ? error : 'The link was not saved.';
    } catch (error) {
      // A rejection leaves the outcome unknown: the target may have saved before failing. Retrying is safe because
      // `save` is idempotent for the same capture and edits (the `SaveTarget` contract).
      const reason = error instanceof Error && error.message ? `: ${error.message}` : '.';
      message = `The link may not have been saved to ${options.target.label}${reason}`;
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
    edit,
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
      const request = ++suggestionRequest;
      offered = undefined;
      let tags: unknown = [];
      try {
        if (options.target.suggestTags) tags = await options.target.suggestTags(prefix);
      } catch {
        // A failing suggester offers nothing.
      }
      if (request !== suggestionRequest) return undefined;
      // Trimmed and each once, in the target's order: the popup keys its list by tag.
      const found = (Array.isArray(tags) ? tags : []).filter((tag): tag is string => typeof tag === 'string').map((tag) => tag.trim());
      offered = { request, tags: [...new Set(found)].filter((tag) => tag !== '') };
      return offered.tags;
    },
    acceptTag(tag) {
      if (state.name !== 'editing' || offered?.request !== suggestionRequest || !offered.tags.includes(tag)) return false;
      const tags = state.draft.tags;
      const kept = tags.slice(0, tags.lastIndexOf(',') + 1);
      edit({ tags: `${kept}${kept ? ' ' : ''}${tag}, ` });
      return true;
    }
  };
}

/** Hands a listener's error to the page's error reporting (an `error` event), or the console where there is none. */
function report(error: unknown): void {
  const reportError = (globalThis as { reportError?: (error: unknown) => void }).reportError;
  if (typeof reportError === 'function') reportError(error);
  else console.error(error);
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
