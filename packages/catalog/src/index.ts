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
    name: 'Annotate',
    summary: 'Mark up a PDF with ink, highlights, notes, shapes, and links, then export an annotated copy while the original stays untouched.',
    state: 'building',
    proposedSurfaces: ['web', 'macos', 'ios', 'embed', 'agent-view'],
    availableSurfaces: []
  }
] as const satisfies readonly CapabilityListing[];
