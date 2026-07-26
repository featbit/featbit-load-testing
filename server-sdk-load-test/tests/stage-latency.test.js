import assert from "node:assert/strict";
import test from "node:test";

import {
  rollUpDistributedTrends,
  scalarStats,
  shiftTrend,
} from "../k6/lib/stage-latency.js";

const trend = {
  count: 10,
  avg: 80,
  min: 50,
  med: 75,
  max: 140,
  "p(90)": 110,
  "p(95)": 125,
  "p(99)": 137,
};

test("shiftTrend subtracts a same-cohort observer offset exactly", () => {
  assert.deepEqual(shiftTrend(trend, -20), {
    count: 10,
    avg: 60,
    min: 30,
    med: 55,
    max: 120,
    "p(90)": 90,
    "p(95)": 105,
    "p(99)": 117,
  });
});

test("end-to-end equals control-plane plus streaming for every trend field", () => {
  const streaming = shiftTrend(trend, -20);
  const endToEnd = shiftTrend(streaming, 35);
  for (const field of ["avg", "min", "med", "max", "p(90)", "p(95)", "p(99)"]) {
    assert.equal(endToEnd[field], streaming[field] + 35);
  }
});

test("distributed rollup keeps exact count, weighted average, and percentile ranges", () => {
  const shifted = shiftTrend(trend, 10);
  const rollup = rollUpDistributedTrends([trend, { ...shifted, count: 30 }]);

  assert.equal(rollup.count, 40);
  assert.equal(rollup.avg, 87.5);
  assert.deepEqual(rollup.p95, { min: 125, max: 135 });
  assert.equal(rollup.min, 50);
  assert.equal(rollup.max, 150);
});

test("scalarStats calculates the control-plane distribution", () => {
  assert.deepEqual(scalarStats([10, 20, 30]), {
    count: 3,
    avg: 20,
    min: 10,
    med: 20,
    p90: 28,
    p95: 29,
    p99: 29.8,
    max: 30,
  });
});
