---
applyTo: 'services/web/**'
---

# Frontend (TypeScript / Vite + Vue 3)

Details: `docs/app-development.md`, `services/web/CLAUDE.md`.

- SFCs use `<script setup lang="ts">` (Composition API, strict, ESM).
- Type-check with `vue-tsc --noEmit`, never `tsc` (it can't resolve Vue types).
- Call the API only through the generated client in `src/api/`. No ad-hoc
  `fetch` in components.
- `src/api/schema.ts` is generated from OpenAPI by `make gen-types` — never edit
  it by hand. Regenerate and commit it after the API contract changes.
- Frontend env vars MUST be `VITE_`-prefixed and non-secret (they ship to the
  browser). Don't put secrets in the frontend.
