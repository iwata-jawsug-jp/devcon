---
name: Origin Devcon Frontend
description: >
  Minimal brand layer on top of Tailwind v4 defaults. Only the brand color ramp and the sans
  font stack are project-specific (#81); spacing, radius, and type scale intentionally use
  Tailwind's built-in defaults until a real design need justifies overriding them.
colors:
  brand-50: 'oklch(0.97 0.02 250)'
  brand-500: 'oklch(0.55 0.18 250)'
  brand-600: 'oklch(0.48 0.18 250)'
  brand-700: 'oklch(0.4 0.18 250)'
typography:
  sans:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
---

## Overview

This is `services/frontend/`'s [DESIGN.md](https://github.com/google-labs-code/design.md): a
token + prose description of the brand so coding agents apply the right colors/fonts without
guessing. It's the source of truth; `services/frontend/CLAUDE.md` `@`-imports this file (see
`docs/ai-instructions.md` for the docs → CLAUDE.md sync rule this repo follows for area-specific
guidance).

The `@theme` block in `services/frontend/src/main.css` is **generated** from the YAML front
matter above via `make gen-design-tokens` (`@google/design.md`'s `export --format css-tailwind`,
#264) — the same "single source, generated, never hand-edit" pattern as `make gen-types` /
`schema.ts`. Token names here must match `main.css`'s custom-property names 1:1 (a `typography`
key becomes `--font-<key>`, a `colors` key becomes `--color-<key>`) so the generator's output
lines up with what components actually reference. After editing this file's front matter, run
`make gen-design-tokens` and commit both files together.

A utility-first Tailwind v4 setup with a single brand color ramp layered on top of Tailwind's
defaults. There is no separate design system yet — deliberately: this repo adds tokens only
when a real screen needs them (see `src/main.css`'s own comment to that effect).

## Colors

`brand-*` is an OKLCH ramp (constant hue/chroma, varying lightness), not a Material-style
`primary`/`secondary`/`tertiary` palette. Today only two steps are actually consumed by
components:

- **`brand-50`** — tint background for status badges (`HealthBadge.vue`, `AuthStatusBadge.vue`).
- **`brand-700`** — text color on that same badge background.
- **`brand-500` / `brand-600`** — defined but not yet used by any component; reserved for a
  future primary action color (button/link) and its hover state, in that order.

Don't invent a `primary`/`secondary`/`accent` alias for these — `make gen-design-tokens` derives
the CSS custom property name directly from the token name (`brand-50` → `--color-brand-50`), so
an alias here would just produce an extra, unused CSS variable.

Colors are authored here in OKLCH for perceptual uniformity across the ramp; `designmd export`
normalizes them to hex in the generated `main.css` (its `css-tailwind` output format always
emits hex) — this is expected, not a lossy mistake to "fix" by hand-editing the generated file.

## Typography

Only the sans-serif font stack is project-specific (`typography.sans` → `--font-sans` in
`main.css`); the type _scale_ (sizes, weights, line-heights) is Tailwind's default and is not
overridden here. The `fontFamily` value holds the full comma-separated fallback stack, not a
single family name — the generator strips the quotes `designmd export` wraps it in so the
fallback list stays a real CSS list rather than one opaque quoted string (see
`services/frontend/scripts/gen-design-tokens.mjs`).

## Do's and Don'ts

- **Do** add a new `brand-*` step (and re-run `make gen-design-tokens`) only once a real screen
  needs it — don't pre-build a full ramp speculatively.
- **Do** run `make gen-design-tokens` and commit the regenerated `main.css` together with any
  change to this file's front matter.
- **Don't** hand-edit the generated block in `main.css` (between the `design-tokens:start`/`:end`
  markers) — edits there are overwritten by the next `make gen-design-tokens` run.
- **Don't** reach for `bg-brand-500`/`bg-brand-600` yet — nothing in the app uses them today;
  confirm the actual primary-action color with design before wiring them into a component.
- **Don't** add sections below (Layout, Elevation & Depth, Shapes, Components) until this repo
  actually overrides Tailwind's defaults for them — an empty section is worse than an absent one.
- **Don't** run `npx @google/design.md lint` against `main.css` — the linter validates
  `docs/frontend-design.md`'s DESIGN.md front matter, not the generated CSS.
