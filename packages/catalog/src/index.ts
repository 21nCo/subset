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
    id: 'pdf-review',
    name: 'PDF annotation and review',
    summary: 'Annotate a PDF and review marked passages in a focused workspace.',
    state: 'planned',
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
    state: 'building',
    proposedSurfaces: ['macos', 'ios'],
    availableSurfaces: []
  }
] as const satisfies readonly CapabilityListing[];
