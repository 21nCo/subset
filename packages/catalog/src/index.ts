export type Surface = 'web' | 'macos' | 'ios' | 'embed' | 'agent-cli' | 'agent-view';
export type ReleaseState = 'planned' | 'building' | 'available';

export interface CapabilityListing {
  id: string;
  name: string;
  summary: string;
  state: ReleaseState;
  proposedSurfaces: readonly Surface[];
  availableSurfaces: readonly Surface[];
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
    id: 'breaks',
    name: 'Breaks',
    summary: 'Take well-timed screen breaks on Mac, iPhone, and iPad, with a menu bar timer, smart pause, optional Screen Time shields, and on-device history.',
    state: 'building',
    proposedSurfaces: ['macos', 'ios'],
    availableSurfaces: []
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
