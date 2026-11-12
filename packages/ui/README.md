# @subset.dev/ui

The shared UI foundation for Subset's web views: design tokens as CSS custom properties, colour schemes, the fixed Subset typeface and shape, an appearance model, and a small set of Svelte 5 primitives. The rules for using it are in [AGENTS.md](../../AGENTS.md#web-ui-conventions). It is a private workspace; views import its Svelte components from source and hosts import its stylesheets.

## Use

In a host (an `apps/*` entry, or a view's MCP App entry):

```ts
import '@21n/fonts/styles.css';      // Twenty One Native, bundled
import '@subset.dev/ui/base.css';    // fixed type, spacing and shape tokens
import '@subset.dev/ui/schemes.css'; // colour tokens for every scheme family, light and dark
```

On the view's root element:

```svelte
<script lang="ts">
  import { appearanceAttributes, parseAppearance } from '@subset.dev/ui';
  let appearance = $state(parseAppearance(storedText));
</script>

<div class="ui-root" {...appearanceAttributes(appearance)}>…</div>
```

Components: `import Button from '@subset.dev/ui/components/Button.svelte'` (also `IconButton`, `Card`, `Pill`, `SegmentedControl`, `Menu`, `MenuItem`, `Dialog`, `Icon`, `AppearancePicker`).

`npm run gallery --workspace=@subset.dev/ui` serves a page with every primitive, the appearance picker, and every scheme family in light and dark (development only; never built or shipped).

## Tokens

| Group | Custom properties |
| --- | --- |
| Surfaces | `--ui-color-surface-canvas`, `-raised`, `-sunken`, `-overlay`, `-hover` |
| Text | `--ui-color-text-primary`, `-secondary`, `-muted`, `-disabled` |
| Borders | `--ui-color-border-subtle`, `-default`, `-strong` |
| Accent | `--ui-color-accent-solid`, `-subtle`, `-soft`, `-contrast` (text on solid), `-on-soft` (text on soft), `-text` (accent-coloured text) |
| Tones | `--ui-color-secondary-*`, `--ui-color-success-*`, `--ui-color-danger-*`: `solid` and `subtle` fills, `contrast` (text on solid), `text` (tone-coloured text); success and danger also `on-subtle` |
| App chrome | `--ui-color-frame-surface`, `-text`, `-border`, `-accent` |
| Type | `--ui-font-family`, `--ui-font-size-xs…xl`, `--ui-font-weight-light|regular|medium|bold` |
| Space and shape | `--ui-space-1…8`, `--ui-radius-control` (0.375rem), `--ui-radius-panel` (0.75rem), `--ui-radius-tab`, `--ui-radius-pill`, `--ui-shell-gap`, `--ui-control-height` |
| Effects | `--ui-focus-ring`, `--ui-shadow-raised`, `--ui-shadow-overlay` |

Names follow uifn's semantic vocabulary (`color.surface.*`, `color.text.*`, `color.border.*`, `color.accent.*`, `radius.*`) with a `--ui-` prefix, so a later move onto uifn's tokens is a prefix change rather than a redesign.

## Colour schemes

`src/schemes/nucleum.json` is Nucleum's scheme data (`21nCo/nucleum` `client/theme/colorschemes.json` at `453e627`, PR #637 / TIDY-511) for the schemes Subset uses, copied without changes. `src/schemes.ts` maps Nucleum's palette slots onto the tokens:

| Token | Nucleum slot |
| --- | --- |
| `surface-canvas` / `-raised` / `-sunken` / `-hover` | `bgs1` / `bgs2` / `bgs3` / `bgs4` (bgs1 is the base; each higher slot is one level of nesting, as Nucleum's `bg(parentBgIndex)`) |
| `text-primary` / `-secondary` / `-muted` / `-disabled` | `fgs1` / `fgs2` / `fgs3` / `fgs4` |
| `border-subtle` / `-default` / `-strong` | `brs2` / `brs3` / `brs4` |
| `accent-solid` / `-subtle` / `-soft` | `aps1` / `aps2` / `aps3`; `accent-contrast` is `onaps3` or whichever of white and near-black reads best on `aps1`; the `on-*` text tokens are the scheme's primary text, white or near-black, whichever reads best on their tone (in Oxide and Solarized dark the subtle tones are light) |
| `secondary-*`, `success-*`, `danger-*` | `ass1–2`, `ags1–2`, `ars1–2` |
| `frame-*` | Nucleum's frame palette (`fbgs1`, `ffgs1`, `fbrs3`, `faps1`) when the scheme has one (Graphite), else the content slots |

Families pair a light and a dark scheme, as Nucleum's scheme families do (PR #638 / TIDY-513): **Default** (blue, Oxide), **Mono** (mono, Oxide), **Graphite** and **Solarized**.

**Contrast.** Nucleum's slots are kept as they are, except where text would be hard to read:

* `text-primary` must reach 4.5:1 on every surface (canvas, raised, sunken, hover, overlay); `text-secondary` 4.5:1 and `text-muted` 3:1 on every resting surface (hovered controls switch to primary text). A slot that falls short keeps its hue and saturation and moves in lightness, away from the surfaces, until it passes (`ensureContrast`). `schemeAdjustments()` lists every such change, and the tests pin the list. Today only Solarized dark changes (its three text slots), which should be raised upstream.
* Tone fills (`-solid`) are never used as text. `-text` tokens are the tone moved until it reaches 4.5:1 on every surface; `-contrast`, `-on-soft` and `-on-subtle` are the first of the scheme's own choice (`onaps3`), white, near-black and black that reaches 4.5:1 on that fill.

`npm run schemes --workspace=@subset.dev/ui` regenerates `src/styles/schemes.css`; the tests fail when the checked-in file is stale. `data-ui-mode="system"` follows `prefers-color-scheme` in CSS, with no script.

## Appearance

Subset fixes the typeface (Twenty One Native) and the shape (Nucleum's semi-rounded app style, TIDY-492). People choose a scheme family and `system`, `light` or `dark`. `parseAppearance` reads a stored value and replaces anything unknown or malformed with the defaults (Default, system); `serializeAppearance` writes one. Hosts decide where to keep it (the standalone hosts use `localStorage`, guarded by try/catch); the package never touches storage.

## Superfunctions and Nucleum reuse review

Reviewed on 2026-11-12:

- **uifn** (`21nCo/superfunctions` `dev` at `f7ef86f3d`; npm `@uifn/tokens@0.0.1`, `@uifn/theme@0.0.1`, `@uifn/components-svelte@0.0.1`, `@uifn/svelte@0.0.3`). The web packages are Svelte 5 and CSP-safe, but they are pre-1.0, unchanged since their 2026-09-02 publish, untried inside MCP App iframes, and style through one whole-catalog stylesheet; current uifn work is the SwiftUI layer (UIF-21…28). uifn ships no font or icon set and has no shape or typeface axis outside its React-only registry presets, which load fonts from Google. **Package/version used: none.** Subset adopts uifn's token vocabulary only; revisit when UIF-3 (web primitives for production) and UIF-8 (tree-shakable core) ship.
- **Nucleum** (`21nCo/nucleum` `dev` at `6e7ebfd0f`, open PRs #636, #637, #638). Its theming runs through Tailwind 3 and `tailwindcss-themer` and its `@21n/ui` components are Tailwind-class based, so neither is reusable as code here. Reused as data and design: the colour schemes, the scheme families, the semi-rounded shape values and the token nesting model.

## Verification

`npm test --workspace=@subset.dev/ui` builds the module and checks that every scheme defines every token, that every text colour reaches its contrast target on every surface it can sit on and on every tone it is drawn over, that the list of departures from Nucleum's colours is the expected one, that the mapping covers every token, that appearance parsing falls back to defaults, and that `schemes.css` is current. `npm run check --workspace=@subset.dev/ui` type-checks the module and every component with `svelte-check --fail-on-warnings`.
