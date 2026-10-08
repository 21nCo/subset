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
  }
] as const satisfies readonly CapabilityListing[];
