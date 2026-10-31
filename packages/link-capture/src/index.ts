export {
  captureActiveTab,
  captureLink,
  LinkCaptureError,
  MAX_LANG_LENGTH,
  MAX_SELECTION_LENGTH,
  readPage,
  type Capture,
  type CaptureOptions,
  type LinkCapture,
  type LinkCaptureErrorCode,
  type PageSnapshot,
  type TabCapture
} from './capture.js';
export {
  captureFromContextMenu,
  LINK_CONTEXT_MENU_ID,
  registerLinkContextMenu,
  saveFromContextMenu,
  type LinkContextMenuOptions,
  type LinkMenuClick,
  type LinkMenuOutcome
} from './context-menu.js';
export {
  hasServerAccess,
  LINK_CAPTURE_OPTIONAL_HOST_PERMISSIONS,
  LINK_CAPTURE_PERMISSIONS,
  linkCaptureManifest,
  removeServerAccess,
  requestServerAccess,
  serverOriginPattern
} from './permissions.js';
export {
  createCapturePopupController,
  type CapturePopupController,
  type CapturePopupControllerOptions,
  type CapturePopupProps
} from './popup-controller.js';
export {
  draftEdits,
  initialPopupState,
  parseTags,
  popupTransition,
  type Draft,
  type PopupError,
  type PopupEvent,
  type PopupState
} from './popup-state.js';
export { createTokenStore, serverUrl, type StoredToken, type TokenStore } from './storage.js';
export type { SaveEdits, SaveResult, SaveTarget, SaveTargetStatus } from './target.js';
