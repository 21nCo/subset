export type Surface = 'web' | 'macos' | 'ios' | 'embed' | 'agent-cli' | 'agent-view';
export type ReleaseState = 'planned' | 'building' | 'available';
export type HttpsUrl = `https://${string}`;

/**
 * A surface whose artifact and route have been verified (AGENTS.md rule 4). Add one only after the
 * release check passes; `scripts/check-workspaces.mjs` validates the shape.
 */
export interface AvailableSurface {
  surface: Surface;
  /** Released version, for example `0.1.0`. */
  version: string;
  /** Direct link to the verified artifact (download, store listing, or hosted app). */
  url: HttpsUrl;
  /** Release page with notes and checksums. */
  releaseUrl: HttpsUrl;
  /** SHA-256 of the artifact at `url`, when it is a file. */
  sha256?: string;
  /** Short system requirements, for example `macOS 14 or later`. */
  requirements?: string;
}

export interface CapabilityListing {
  id: string;
  name: string;
  summary: string;
  /** `available` once at least one surface is available; other proposed surfaces may still be in progress. */
  state: ReleaseState;
  /** Every surface intended for this capability, including the available ones. */
  proposedSurfaces: readonly Surface[];
  availableSurfaces: readonly AvailableSurface[];
}

export const capabilities = [
  {
    id: 'usage',
    name: 'Usage dashboard',
    summary: 'See supported usage sources, limits, reset times, and freshness in one focused view.',
    state: 'building',
    proposedSurfaces: ['web', 'embed', 'agent-cli', 'agent-view'],
    availableSurfaces: []
  },
  {
    id: 'launcher',
    name: 'Launcher',
    summary: 'Open apps and files, run shortcuts, arrange windows, pick emoji, calculate, and jot quick notes from one keyboard bar on the Mac.',
    state: 'building',
    proposedSurfaces: ['macos'],
    availableSurfaces: []
  },
  {
    id: 'clipboard',
    name: 'Clipboard',
    summary: 'Keep a private, searchable history of everything you copy, and paste any earlier item back on the Mac or from an iPhone keyboard.',
    state: 'building',
    proposedSurfaces: ['macos', 'ios'],
    availableSurfaces: []
  },
  {
    id: 'screenshot',
    name: 'Screenshot',
    summary: 'Capture, record, annotate, and pin what is on screen from the macOS menu bar, with optional self-hosted share links.',
    state: 'building',
    proposedSurfaces: ['macos'],
    availableSurfaces: []
  },
  {
    id: 'pdf-review',
    name: 'Annotate',
    summary: 'Mark up a PDF with ink, highlights, notes, shapes, and links, then export an annotated copy while the original stays untouched.',
    state: 'building',
    proposedSurfaces: ['web', 'macos', 'ios', 'embed', 'agent-view'],
    availableSurfaces: []
  },
  {
    id: 'dictate',
    name: 'Dictate',
    summary: 'Hold fn, speak, and insert locally transcribed text into the app where your cursor is.',
    state: 'building',
    proposedSurfaces: ['macos'],
    availableSurfaces: []
  },
  {
    id: 'breaks',
    name: 'Breaks',
    summary: 'Take well-timed screen breaks on Mac, iPhone, and iPad, with a menu bar timer, smart pause, optional Screen Time shields, and on-device history.',
    state: 'available',
    proposedSurfaces: ['macos', 'ios'],
    availableSurfaces: [
      {
        surface: 'macos',
        version: '0.1.0',
        url: 'https://github.com/21nCo/subset/releases/download/macos/breaks/v0.1.0/Breaks-0.1.0.dmg',
        releaseUrl: 'https://github.com/21nCo/subset/releases/tag/macos/breaks/v0.1.0',
        sha256: '5ce3e8c78fcb273a738cdc72eec829716b5da3e945ad5ce45fe26f10d4fbd92e',
        requirements: 'macOS 14 or later, Apple silicon or Intel'
      }
    ]
  },
  {
    id: 'minutes',
    name: 'Minutes',
    summary: 'Send a visible notetaker bot to a Google Meet or Zoom call and keep the meeting audio locally.',
    state: 'building',
    proposedSurfaces: ['macos', 'agent-cli'],
    availableSurfaces: []
  },
  {
    id: 'record',
    name: 'Record',
    summary: 'Record audio with a live waveform, keep clips on your device, and see the timer from anywhere.',
    state: 'building',
    proposedSurfaces: ['macos', 'ios'],
    availableSurfaces: []
  }
] as const satisfies readonly CapabilityListing[];
