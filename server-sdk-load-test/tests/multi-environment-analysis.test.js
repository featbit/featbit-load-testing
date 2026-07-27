import assert from "node:assert/strict";
import test from "node:test";

import {
  percentileStats,
  validateReadyDistribution,
  validateTargetDeliveryDistribution,
} from "../k6/lib/multi-environment-analysis.js";

test("computes merged percentiles from raw target samples", () => {
  const stats = percentileStats(Array.from({ length: 100 }, (_, index) => index + 1));
  assert.deepEqual(stats, {
    count: 100,
    avg: 50.5,
    p50: 50.5,
    p90: 90.10000000000001,
    p95: 95.05,
    p99: 99.01,
    max: 100,
  });
});

test("validates 20 runners x 100 environments x 5 connections", () => {
  const environmentIds = Array.from({ length: 100 }, (_, index) => `env-${index + 1}`);
  const events = [];
  for (let runnerIndex = 1; runnerIndex <= 20; runnerIndex += 1) {
    for (let localConnectionIndex = 1; localConnectionIndex <= 500; localConnectionIndex += 1) {
      events.push({
        environmentId: environmentIds[(localConnectionIndex - 1) % 100],
        runnerIndex,
        localConnectionIndex,
      });
    }
  }

  assert.deepEqual(
    validateReadyDistribution(events, environmentIds, {
      parallelism: 20,
      connectionsPerRunner: 500,
      connectionsPerEnvironmentPerRunner: 5,
    }),
    {
      total: 10_000,
      runners: 20,
      environments: 100,
      connectionsPerRunner: 500,
      connectionsPerEnvironment: 100,
      connectionsPerEnvironmentPerRunner: 5,
    },
  );
});

test("validates target coverage and rejects duplicate connections", () => {
  const events = [];
  for (let runnerIndex = 1; runnerIndex <= 20; runnerIndex += 1) {
    for (let localConnectionIndex = 1; localConnectionIndex <= 5; localConnectionIndex += 1) {
      events.push({
        environmentId: "target",
        runnerIndex,
        localConnectionIndex,
      });
    }
  }

  assert.deepEqual(
    validateTargetDeliveryDistribution(events, {
      targetEnvironmentId: "target",
      parallelism: 20,
      connectionsPerEnvironmentPerRunner: 5,
      label: "revision",
    }),
    { count: 100, perRunner: 5 },
  );
  assert.throws(
    () =>
      validateTargetDeliveryDistribution([...events, events[0]], {
        targetEnvironmentId: "target",
        parallelism: 20,
        connectionsPerEnvironmentPerRunner: 5,
        label: "revision",
      }),
    /duplicate identity|count/,
  );
});
