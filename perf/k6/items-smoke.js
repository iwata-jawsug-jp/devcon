// Load/perf smoke test for the items API (Issue #43).
//
// Run against services/backend/python/perf/app.py (NOT the real production
// app) via .github/workflows/perf.yml, or locally with `make perf-test`.
// Auth is bypassed server-side there (see perf/app.py's docstring), so this
// script sends no Authorization header -- it measures our own API's
// performance (FastAPI routing, Pydantic validation, repository/DB layer),
// not Cognito's JWT-verification latency.
//
// Thresholds mirror the p95-latency alarm already codified for the real ALB
// in infra/variables.tf (`alarm_alb_latency_seconds`, default 1s) as the
// closest existing stand-in for a formal SLO -- reconcile with #42's SLO/SLI
// definition (phase 4) once that lands.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.PERF_BASE_URL || 'http://127.0.0.1:8000';

export const options = {
  scenarios: {
    smoke: {
      executor: 'constant-vus',
      vus: Number(__ENV.PERF_VUS || 10),
      duration: __ENV.PERF_DURATION || '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'], // <1% errors
    'http_req_duration{endpoint:health}': ['p(95)<200'],
    'http_req_duration{endpoint:list}': ['p(95)<1000'],
    'http_req_duration{endpoint:get}': ['p(95)<1000'],
    'http_req_duration{endpoint:create}': ['p(95)<1000'],
  },
};

// Runs once before the VUs start: seed one item so `get`/`list` have real
// data to read, and hand its id to the per-VU default function.
export function setup() {
  const res = http.post(
    `${BASE_URL}/api/items`,
    JSON.stringify({
      name: 'k6-seed-item',
      description: 'seeded by perf/k6/items-smoke.js setup()',
    }),
    { headers: { 'Content-Type': 'application/json' }, tags: { endpoint: 'create' } },
  );
  check(res, { 'setup: seed item created (201)': (r) => r.status === 201 });
  return { seedItemId: res.json('id') };
}

export default function (data) {
  const health = http.get(`${BASE_URL}/api/health`, { tags: { endpoint: 'health' } });
  check(health, { 'health: 200': (r) => r.status === 200 });

  const list = http.get(`${BASE_URL}/api/items`, { tags: { endpoint: 'list' } });
  check(list, { 'list: 200': (r) => r.status === 200 });

  const get = http.get(`${BASE_URL}/api/items/${data.seedItemId}`, { tags: { endpoint: 'get' } });
  check(get, { 'get: 200': (r) => r.status === 200 });

  const create = http.post(
    `${BASE_URL}/api/items`,
    JSON.stringify({ name: `k6-item-${__VU}-${__ITER}`, description: null }),
    { headers: { 'Content-Type': 'application/json' }, tags: { endpoint: 'create' } },
  );
  check(create, { 'create: 201': (r) => r.status === 201 });

  sleep(1);
}
