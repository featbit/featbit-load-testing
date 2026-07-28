import assert from "node:assert/strict";
import test from "node:test";

import {
  summarizeInitialSyncRamp,
  validateInitialSyncEvents,
} from "../k6/lib/large-flagset-analysis.js";

function syncEvents() {
  return [
    {
      environmentId: "env",
      runnerIndex: 1,
      localConnectionIndex: 1,
      scheduledStartAtUnixMs: 1_001_000,
      iterationStartedAtUnixMs: 1_001_020,
      openedAtUnixMs: 1_001_050,
      completedAtUnixMs: 1_001_250,
      payloadBytes: 5_000_000,
      featureFlagCount: 3_000,
      segmentCount: 0,
      parseLatencyMs: 10,
      validationLatencyMs: 2,
    },
    {
      environmentId: "env",
      runnerIndex: 1,
      localConnectionIndex: 2,
      scheduledStartAtUnixMs: 1_002_000,
      iterationStartedAtUnixMs: 1_002_100,
      openedAtUnixMs: 1_002_150,
      completedAtUnixMs: 1_002_500,
      payloadBytes: 5_000_000,
      featureFlagCount: 3_000,
      segmentCount: 0,
      parseLatencyMs: 12,
      validationLatencyMs: 3,
    },
  ];
}

test("validates complete one-environment initial-sync identities", () => {
  assert.deepEqual(
    validateInitialSyncEvents(syncEvents(), {
      expectedConnections: 2,
      parallelism: 1,
      connectionsPerRunner: 2,
      expectedEnvironmentId: "env",
      expectedFlagCount: 3_000,
    }),
    { count: 2, runners: 1 },
  );
});

test("separates schedule, open, and full-sync ramp delay", () => {
  const summary = summarizeInitialSyncRamp(syncEvents(), 2_000);

  assert.equal(summary.scenarioStartAtUnixMs, 1_000_000);
  assert.equal(summary.attemptCompletionDelayMs, 100);
  assert.equal(summary.openCompletionDelayMs, 150);
  assert.equal(summary.readyCompletionDelayMs, 500);
  assert.equal(summary.actualReadyRampDurationMs, 2_500);
  assert.equal(summary.metrics.initial_sync_after_open_latency_ms.max, 350);
  assert.equal(summary.payload.totalBytes, 10_000_000);
});

test("rejects a full sync that does not contain exactly 3,000 flags", () => {
  const events = syncEvents();
  events[0].featureFlagCount = 2_999;

  assert.throws(
    () =>
      validateInitialSyncEvents(events, {
        expectedConnections: 2,
        parallelism: 1,
        connectionsPerRunner: 2,
        expectedEnvironmentId: "env",
        expectedFlagCount: 3_000,
      }),
    /expected 3000/,
  );
});
