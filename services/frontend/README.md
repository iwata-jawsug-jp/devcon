# frontend (Vite + Vue 3 + TypeScript SPA)

Single-page app built with **Vite**, **Vue 3** (Composition API, `<script setup>`),
**vue-router**, and **Pinia**. Type-checked with `vue-tsc`, unit-tested with
**Vitest**, end-to-end tested with **Playwright**.

## Quick start

```bash
npm install        # install deps
npm run dev        # Vite dev server (http://localhost:5173)
```

The dev server proxies `/api/*` to the backend at `http://localhost:8000`
(see `vite.config.ts`), so run `services/backend/python` alongside it.

## Scripts

```bash
npm run dev         # start the Vite dev server
npm run build       # vue-tsc --noEmit && vite build  -> dist/
npm run preview     # preview the production build
npm run typecheck   # vue-tsc --noEmit (type-check only)
npm run lint        # eslint .
npm run format      # prettier --write .
npm test            # vitest run (unit tests)
npm run test:e2e    # playwright test (requires `npx playwright install`)
npm run gen-types   # regenerate src/api/schema.ts from the backend OpenAPI doc
```

## API access

All backend calls go through the single typed client in `src/api/`:

- `src/api/client.ts` — typed `fetch` wrapper against `/api` (e.g. `getHealth()`).
- `src/api/schema.ts` — **generated** by `make gen-types` /
  `npm run gen-types` (openapi-typescript). Do not edit by hand.
- `src/api/index.ts` — public re-exports.

Components import `apiClient` from `src/api` rather than calling `fetch` directly.

## Configuration

Copy `.env.example` to `.env`. Only `VITE_`-prefixed, non-secret variables are
exposed to the client bundle (e.g. `VITE_API_BASE`).

## End-to-end tests

Playwright specs live in `e2e/` (`playwright.config.ts`). Browsers are not
installed by default; run `npx playwright install` before `npm run test:e2e`.
