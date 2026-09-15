import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { SharedArray } from 'k6/data';

const fleet = JSON.parse(open('/fixtures/fleet.json'));
const tokens = new SharedArray('device tokens', () => fleet.tokens);
const base = __ENV.BASE_URL;
const rate = Number(__ENV.RATE || 2000);

export const options = {
  scenarios: {
    changes: {
      executor: 'constant-arrival-rate', rate, timeUnit: '1s',
      // Reserve headroom for scheduler/GC pauses before measurement; allocating
      // VUs mid-run can drop arrivals even when server latency is low.
      duration: __ENV.DURATION || '60s', preAllocatedVUs: 400, maxVUs: 400,
      gracefulStop: '10s',
    },
  },
  thresholds: {
    'http_req_duration{scenario:changes}': ['p(99)<20'],
    'http_req_failed{scenario:changes}': ['rate==0'],
    'checks{scenario:changes}': ['rate==1'],
    dropped_iterations: ['count==0'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

function request(token) {
  return {
    method: 'GET', url: `${base}/api/v2/sync/changes`,
    params: { headers: { Authorization: `Bearer ${token}`, 'X-Schema-Version': String(fleet.schema_version) } },
  };
}

// Populate auth entries and the watermark cache before measuring the warm path.
// 2000 rotating tokens keep each real device limiter below its 120/min budget.
export function setup() {
  for (let start = 0; start < tokens.length; start += 50) {
    const batch = [];
    for (let i = start; i < Math.min(start + 50, tokens.length); i++) batch.push(request(tokens[i]));
    for (const response of http.batch(batch)) {
      if (response.status !== 200) throw new Error(`warmup failed: HTTP ${response.status}`);
    }
  }
}

export default function () {
  const req = request(tokens[exec.scenario.iterationInTest % tokens.length]);
  const response = http.get(req.url, req.params);
  let body;
  try { body = response.json(); } catch (_) { body = null; }
  check(response, {
    '200 object, correct cursors and metadata': (r) => r.status === 200 && body !== null &&
      !Array.isArray(body) && body.cursors && Object.keys(body.cursors).length === fleet.entities &&
      body.cursors.products === 1 && body.device_revision > 0 &&
      body.server_time_ms > 1600000000000 && body.next_poll_ms > 0,
  });
}
