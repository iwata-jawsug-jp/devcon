# services/web — frontend SPA (TypeScript, Vite + Vue 3)

Loaded on demand when working in `services/web/`. Root rules still apply; see
`../../CLAUDE.md`. Full guide: `docs/app-development.md`.

## Stack & layout

Vite app (`package.json`, `vite.config.ts`, `tsconfig.json`, `src/`). SFCs use
`<script setup lang="ts">`. Components in `src/components/`, route views in `src/views/`,
router in `src/router/`, generated API client in `src/api/`, shared state via Pinia in
`src/stores/`.

## Commands

- `npm run dev` — Vite dev server (:5173); `/api/*` is proxied to uvicorn (:8000)
- `npm run typecheck` — **`vue-tsc --noEmit` (not `tsc`)** · `npm run lint` (eslint)
- `npm test` (Vitest unit) · `npm run test:e2e` (Playwright) · `npm run build`

## Conventions

- Composition API with `<script setup>`, `strict` mode, ESM.
- Type-check with **`vue-tsc`**, never `tsc`.
- **Call the API only through the generated client in `src/api/`** — no ad-hoc `fetch` in
  components.
- Frontend env vars MUST be `VITE_`-prefixed and non-secret — they ship to the browser.
  Backend secrets stay server-side (SSM / Secrets Manager).

## Generated API client

`src/api/schema.ts` is generated from the API's OpenAPI schema by `make gen-types` — never
edit it by hand. After the API contract changes, run `make gen-types` and commit the result;
don't hand-write request/response types.
