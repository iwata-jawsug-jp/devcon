# services/frontend — frontend SPA (TypeScript, Vite + Vue 3)

Loaded on demand when working in `services/frontend/`. Root rules still apply; see
`../../CLAUDE.md`. Full guide: `docs/app-development.md`.

## Stack & layout

Vite app (`package.json`, `vite.config.ts`, `tsconfig.json`, `src/`), built with **vite-ssg**
(`vite-ssg build`, not `vite build`) — every route is prerendered at build time (no cloaking:
all users get the same static HTML). SFCs use `<script setup lang="ts">`. Components in
`src/components/`, route views in `src/views/`, route records in `src/router/` (exports
`routes`, not a router instance), generated API client in `src/api/`, shared state via Pinia in
`src/stores/`.

## Commands

- `npm run dev` — Vite dev server (:5173); `/api/*` is proxied to uvicorn (:8000)
- `npm run typecheck` — **`vue-tsc --noEmit` (not `tsc`)** · `npm run lint` (eslint)
- `npm test` (Vitest unit) · `npm run test:e2e` (Playwright) · `npm run build`

## Conventions

- Composition API with `<script setup>`, `strict` mode, ESM.
- Type-check with **`vue-tsc`**, never `tsc`.
- **Fetch server state only through `useXxxQuery()` composables in `src/api/queries.ts`**
  (TanStack Query, wraps the generated `apiClient`) — no ad-hoc `fetch` or direct `apiClient`
  calls in components. Client-only state (not from the API) stays in Pinia (`src/stores/`);
  don't copy server data into a store.
- Frontend env vars MUST be `VITE_`-prefixed and non-secret — they ship to the browser.
  Backend secrets stay server-side (SSM / Secrets Manager).
- **`main.ts` exports `ViteSSG(App, { routes }, setup)`, not `createApp(App).mount(...)`.**
  Set per-page title/meta/OGP/JSON-LD with `useHead()` (`@unhead/vue`) inside each view; the
  site-wide title template lives in `App.vue`. See `docs/app-development.md` for why (#78).
- **PWA (`vite-plugin-pwa`, #80): don't add `workbox.runtimeCaching` for `/api/*`.** Only the
  built static shell is precached. This is deliberate — once authenticated routes exist (#41),
  caching API responses in the service worker risks serving another user's data. The service
  worker doesn't register under `npm run dev`; test it via `npm run test:e2e` (`chromium-pwa`
  project runs against `vite preview`).

## Generated API client

`src/api/schema.ts` is generated from the API's OpenAPI schema by `make gen-types` — never
edit it by hand. After the API contract changes, run `make gen-types` and commit the result;
don't hand-write request/response types.
