#!/usr/bin/env node
// Enforces the resourceSizes budgets in budget.json against the gzip size of
// the built dist/assets output. Lighthouse's own "performance-budget" audit
// was removed upstream, so this reimplements just enough of that check.
import { gzipSync } from 'node:zlib';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const distAssets = join(root, 'dist', 'assets');
const budgets = JSON.parse(readFileSync(join(root, 'budget.json'), 'utf8'))[0].resourceSizes;

const TYPE_BY_EXT = { '.js': 'script', '.css': 'stylesheet' };

function gzipSizeOf(path) {
  return gzipSync(readFileSync(path)).byteLength;
}

const totals = { script: 0, stylesheet: 0, total: 0 };
for (const file of readdirSync(distAssets)) {
  const path = join(distAssets, file);
  if (!statSync(path).isFile()) continue;
  const size = gzipSizeOf(path);
  const type = TYPE_BY_EXT[extname(file)];
  if (type) totals[type] += size;
  totals.total += size;
}

let failed = false;
for (const { resourceType, budget } of budgets) {
  const actualKb = (totals[resourceType] ?? 0) / 1024;
  const ok = actualKb <= budget;
  console.log(
    `${ok ? 'OK  ' : 'FAIL'} ${resourceType}: ${actualKb.toFixed(1)} KB (budget: ${budget} KB, gzip)`,
  );
  if (!ok) failed = true;
}

if (failed) {
  console.error('\nBundle size budget exceeded — see budget.json.');
  process.exit(1);
}
