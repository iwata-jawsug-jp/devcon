#!/usr/bin/env node
// Regenerates the @theme block in src/main.css from docs/frontend-design.md (DESIGN.md), via
// `designmd export --format css-tailwind` — same "single source, generated, never hand-edit"
// pattern as gen-types/schema.ts (#264). Run via `make gen-design-tokens`.
//
// The exporter wraps every `--font-*` value in double quotes, which is correct for a single
// family name but breaks a comma-separated fallback list (the browser sees one literal quoted
// name instead of a fallback chain) — so those quotes are stripped back out below.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const designMdPath = fileURLToPath(new URL('../../../docs/frontend-design.md', import.meta.url));
const mainCssPath = fileURLToPath(new URL('../src/main.css', import.meta.url));

const generated = execFileSync(
  'npx',
  ['designmd', 'export', '--format', 'css-tailwind', designMdPath],
  { encoding: 'utf-8' },
)
  .trim()
  .replace(/(--font-[\w-]+:\s*)"([^"]*)"/g, '$1$2');

const START = '/* design-tokens:start */';
const END = '/* design-tokens:end */';
const css = readFileSync(mainCssPath, 'utf-8');
const startIdx = css.indexOf(START);
const endIdx = css.indexOf(END);
if (startIdx === -1 || endIdx === -1) {
  console.error(`Missing ${START} / ${END} markers in ${mainCssPath}`);
  process.exit(1);
}

const before = css.slice(0, startIdx + START.length);
const after = css.slice(endIdx);
writeFileSync(mainCssPath, `${before}\n${generated}\n${after}`);
console.log(`Regenerated ${mainCssPath} from ${designMdPath}`);
