---
applyTo: 'services/frontend/**'
---

# Frontend (TypeScript / Vite + Vue 3)

Details: `docs/app-development.md`, `services/frontend/CLAUDE.md`.

- SFCs use `<script setup lang="ts">` (Composition API, strict, ESM).
- Type-check with `vue-tsc --noEmit`, never `tsc` (it can't resolve Vue types).
- Fetch server state only through `useXxxQuery()` composables in
  `src/api/queries.ts` (TanStack Query, wraps the generated `apiClient`). No
  ad-hoc `fetch` or direct `apiClient` calls in components. Client-only state
  stays in Pinia (`src/stores/`) — don't copy server data into a store.
- `src/api/schema.ts` is generated from OpenAPI by `make gen-types` — never edit
  it by hand. Regenerate and commit it after the API contract changes.
- Frontend env vars MUST be `VITE_`-prefixed and non-secret (they ship to the
  browser). Don't put secrets in the frontend.
- `main.ts` exports `ViteSSG(App, { routes }, setup)`, not `createApp(App).mount(...)`
  — every route is prerendered at build time. Set per-page title/meta/OGP/JSON-LD
  with `useHead()` (`@unhead/vue`) in each view.
- PWA (`vite-plugin-pwa`): don't add `workbox.runtimeCaching` for `/api/*` — only
  the static shell is precached, to avoid serving another user's cached API data
  once authenticated routes exist. The service worker doesn't register under
  `npm run dev`; the `chromium-pwa` Playwright project tests it against
  `vite preview`.
