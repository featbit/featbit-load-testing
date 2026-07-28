import test from "node:test";
import assert from "node:assert/strict";

import {
  analyzeElsCgroupSnapshots,
  analyzeFormalPropagation,
  extractServedRevision,
  summarizeInitialization,
  validateReadyEvents,
  validateWarmupCoverage,
} from "../dotnet-sdk-runner/analysis/dotnet-sdk-pilot-analysis.js";

const contract = {
  parallelism: 2,
  clientsPerRunner: 2,
  totalConnections: 4,
  connectionsPerSecond: 2,
  startAtUnixMs: 1_000_000,
  environmentId: "env-1",
};

function readyEvents() {
  const events = [];
  for (let local = 1; local <= 2; local += 1) {
    for (let runner = 1; runner <= 2; runner += 1) {
      const globalConnection = (local - 1) * 2 + runner;
      const scheduledAtUnixMs =
        contract.startAtUnixMs + Math.floor(((globalConnection - 1) * 1000) / 2);
      const createStartedAtUnixMs = scheduledAtUnixMs + runner;
      const atUnixMs = createStartedAtUnixMs + 100 + local;
      events.push({
        event: "sdk_ready",
        runner,
        localConnection: local,
        globalConnection,
        environmentId: "env-1",
        scheduledAtUnixMs,
        createStartedAtUnixMs,
        constructorReturnedAtUnixMs: atUnixMs,
        atUnixMs,
        initializationLatencyMs: atUnixMs - createStartedAtUnixMs,
        readyScheduleDriftMs: atUnixMs - scheduledAtUnixMs,
      });
    }
  }
  return events;
}

test("validates the interleaved runner schedule and summarizes ramp backlog", () => {
  const ready = readyEvents();
  assert.equal(validateReadyEvents(ready, contract).count, 4);
  const summary = summarizeInitialization(ready, {
    startAtUnixMs: contract.startAtUnixMs,
    configuredRampDurationMs: 2_000,
    totalConnections: 4,
    connectionsPerSecond: 2,
  });
  assert.equal(summary.actual.readyAtRampEnd, 4);
  assert.equal(summary.actual.readyBacklogAtRampEnd, 0);
  assert.equal(summary.metrics.sdk_initialization_latency_ms.count, 4);
});

test("rejects a duplicate global connection identity", () => {
  const ready = readyEvents();
  ready[1].globalConnection = ready[0].globalConnection;
  assert.throws(() => validateReadyEvents(ready, contract), /global/);
});

test("extracts string and JSON observer revisions", () => {
  const stringFlag = {
    key: "flag-string",
    isEnabled: true,
    variationType: "string",
    fallthrough: { variations: [{ id: "served" }] },
    variations: [{ id: "served", value: "rev-001" }],
  };
  const jsonFlag = {
    key: "flag-json",
    isEnabled: true,
    variationType: "json",
    fallthrough: { variations: [{ id: "served" }] },
    variations: [
      {
        id: "served",
        value: JSON.stringify({ _loadTestRevision: "rev-010", payload: "x" }),
      },
    ],
  };
  assert.equal(extractServedRevision(stringFlag), "rev-001");
  assert.equal(extractServedRevision(jsonFlag), "rev-010");
});

function observerRecord({ at, revision, flagKey, node, publishedAt = at }) {
  return {
    observedAtUnixMs: at,
    node,
    payload: {
      envId: "env-1",
      key: flagKey,
      revision: `entity-${revision}`,
      updatedAt: new Date(publishedAt).toISOString(),
      isEnabled: true,
      variationType: "string",
      fallthrough: { variations: [{ id: "served" }] },
      variations: [{ id: "served", value: revision }],
    },
  };
}

test("joins controller, Redis observer, and SDK observations", () => {
  const plan = [
    {
      index: 1,
      flagKey: "flag-1",
      revision: "rev-001",
      variationType: "string",
    },
  ];
  const controllerRecords = [
    {
      event: "request_start",
      atUnixMs: 2_000,
      environmentId: "env-1",
      revisionIndex: 1,
      revision: "rev-001",
      flagKey: "flag-1",
      attempt: 1,
    },
    {
      event: "request_end",
      atUnixMs: 2_010,
      environmentId: "env-1",
      revisionIndex: 1,
      revision: "rev-001",
      flagKey: "flag-1",
      attempt: 1,
    },
  ];
  const observerRecords = [
    observerRecord({
      at: 2_005,
      publishedAt: 2_004,
      revision: "rev-001",
      flagKey: "flag-1",
      node: "n1",
    }),
    observerRecord({
      at: 2_006,
      publishedAt: 2_004,
      revision: "rev-001",
      flagKey: "flag-1",
      node: "n2",
    }),
  ];
  const observations = readyEvents().map((event, index) => ({
    event: "variation_observed",
    atUnixMs: index === 3 ? 2_206 : 2_020 + index,
    runner: event.runner,
    localConnection: event.localConnection,
    environmentId: "env-1",
    flagKey: "flag-1",
    revision: "rev-001",
    revisionIndex: 1,
  }));
  const result = analyzeFormalPropagation({
    observations,
    controllerRecords,
    observerRecords,
    plan,
    environmentId: "env-1",
    expectedConnections: 4,
    parallelism: 2,
    clientsPerRunner: 2,
    expectedObserverNodes: ["n1", "n2"],
  });
  assert.equal(result.sampleCount, 4);
  assert.equal(result.combined.control_plane_write_latency_ms.p99, 5);
  assert.equal(result.combined.probe_sync_latency_ms.count, 4);
  assert.equal(result.combined.deJitterDiagnostic.retainedCount, 3);
  assert.equal(result.combined.deJitterDiagnostic.removedCount, 1);
  assert.equal(result.revisionSequenceErrors, 0);
});

test("retains low negative probe-sync values as cross-node clock uncertainty", () => {
  const plan = [
    {
      index: 1,
      flagKey: "flag-1",
      revision: "rev-001",
      variationType: "string",
    },
  ];
  const controllerRecords = [
    {
      event: "request_start",
      atUnixMs: 2_000,
      environmentId: "env-1",
      revisionIndex: 1,
      revision: "rev-001",
      flagKey: "flag-1",
      attempt: 1,
    },
    {
      event: "request_end",
      atUnixMs: 2_010,
      environmentId: "env-1",
      revisionIndex: 1,
      revision: "rev-001",
      flagKey: "flag-1",
      attempt: 1,
    },
  ];
  const observerRecords = ["n1", "n2"].map((node, index) =>
    observerRecord({
      at: 2_005 + index,
      publishedAt: 2_004,
      revision: "rev-001",
      flagKey: "flag-1",
      node,
    }),
  );
  const observations = readyEvents().map((event, index) => ({
    event: "variation_observed",
    atUnixMs: index === 0 ? 2_004 : 2_020 + index,
    runner: event.runner,
    localConnection: event.localConnection,
    environmentId: "env-1",
    flagKey: "flag-1",
    revision: "rev-001",
    revisionIndex: 1,
  }));
  const result = analyzeFormalPropagation({
    observations,
    controllerRecords,
    observerRecords,
    plan,
    environmentId: "env-1",
    expectedConnections: 4,
    parallelism: 2,
    clientsPerRunner: 2,
    expectedObserverNodes: ["n1", "n2"],
    crossNodeClockToleranceMs: 10,
  });

  assert.equal(result.combined.probe_sync_latency_ms.avg, 12.5);
  assert.equal(result.crossNodeClockUncertainty.minimumProbeSyncLatencyMs, -1);
  assert.equal(result.crossNodeClockUncertainty.negativeProbeSyncSampleCount, 1);
  assert.equal(result.crossNodeClockUncertainty.valuesClipped, false);
});

test("rejects probe-sync values beyond the clock uncertainty contract", () => {
  const plan = [
    {
      index: 1,
      flagKey: "flag-1",
      revision: "rev-001",
      variationType: "string",
    },
  ];
  const controllerRecords = [
    {
      event: "request_start",
      atUnixMs: 2_000,
      environmentId: "env-1",
      revisionIndex: 1,
      revision: "rev-001",
      flagKey: "flag-1",
      attempt: 1,
    },
    {
      event: "request_end",
      atUnixMs: 2_010,
      environmentId: "env-1",
      revisionIndex: 1,
      revision: "rev-001",
      flagKey: "flag-1",
      attempt: 1,
    },
  ];
  const observerRecords = ["n1", "n2"].map((node, index) =>
    observerRecord({
      at: 2_020 + index,
      publishedAt: 2_004,
      revision: "rev-001",
      flagKey: "flag-1",
      node,
    }),
  );
  const observations = readyEvents().map((event, index) => ({
    event: "variation_observed",
    atUnixMs: index === 0 ? 2_001 : 2_030 + index,
    runner: event.runner,
    localConnection: event.localConnection,
    environmentId: "env-1",
    flagKey: "flag-1",
    revision: "rev-001",
    revisionIndex: 1,
  }));

  assert.throws(
    () =>
      analyzeFormalPropagation({
        observations,
        controllerRecords,
        observerRecords,
        plan,
        environmentId: "env-1",
        expectedConnections: 4,
        parallelism: 2,
        clientsPerRunner: 2,
        expectedObserverNodes: ["n1", "n2"],
        crossNodeClockToleranceMs: 10,
      }),
    /exceeds the 10 ms cross-node clock uncertainty tolerance/,
  );
});

test("requires both warm-up deliveries for every SDK client", () => {
  const controllerRecords = [
    {
      event: "request_start",
      atUnixMs: 3_000,
      environmentId: "env-1",
      revisionIndex: 0,
      revision: "rev-001",
      flagKey: "warmup",
    },
    {
      event: "request_start",
      atUnixMs: 4_000,
      environmentId: "env-1",
      revisionIndex: 0,
      revision: "baseline",
      flagKey: "warmup",
    },
  ];
  const observations = [];
  for (const ready of readyEvents()) {
    observations.push({
      event: "variation_observed",
      atUnixMs: 3_010,
      runner: ready.runner,
      localConnection: ready.localConnection,
      environmentId: "env-1",
      flagKey: "warmup",
      revision: "rev-001",
    });
    observations.push({
      event: "variation_observed",
      atUnixMs: 4_010,
      runner: ready.runner,
      localConnection: ready.localConnection,
      environmentId: "env-1",
      flagKey: "warmup",
      revision: "baseline",
    });
  }
  const result = validateWarmupCoverage({
    observations,
    controllerRecords,
    environmentId: "env-1",
    flagKey: "warmup",
    expectedConnections: 4,
    parallelism: 2,
    clientsPerRunner: 2,
  });
  assert.equal(result.connectionCoverage, 4);
  assert.equal(result.deliveryCount, 8);
});

test("calculates exact ELS cgroup deltas for stable Pods", () => {
  const snapshot = (phase, offset) => ({
    runId: "growth-test",
    phase,
    capturedAtUnixMs: 10_000 + offset,
    pods: [1, 2, 3].map((index) => ({
      pod: `els-${index}`,
      podUid: `uid-${index}`,
      node: `node-${index}`,
      restartCount: 0,
      cpu: {
        usage_usec: 1_000 * index + offset * 10,
        nr_periods: 100 * index + offset,
        nr_throttled: index + offset / 10,
        throttled_usec: 50 * index + offset * 2,
      },
    })),
  });
  const result = analyzeElsCgroupSnapshots(
    snapshot("pre", 0),
    snapshot("post", 10),
  );

  assert.equal(result.exactWindowDelta, true);
  assert.equal(result.podCount, 3);
  assert.equal(result.totals.usageUsec, 300);
  assert.equal(result.totals.cpuPeriods, 30);
  assert.equal(result.totals.throttledPeriods, 3);
  assert.equal(result.totals.throttledMilliseconds, 0.06);
});

test("rejects an ELS Pod replacement between cgroup snapshots", () => {
  const pre = {
    runId: "growth-test",
    phase: "pre",
    capturedAtUnixMs: 1,
    pods: [1, 2, 3].map((index) => ({
      pod: `els-${index}`,
      podUid: `uid-${index}`,
      node: `node-${index}`,
      restartCount: 0,
      cpu: {
        usage_usec: 1,
        nr_periods: 1,
        nr_throttled: 0,
        throttled_usec: 0,
      },
    })),
  };
  const post = structuredClone(pre);
  post.phase = "post";
  post.capturedAtUnixMs = 2;
  post.pods[0].podUid = "replacement";

  assert.throws(
    () => analyzeElsCgroupSnapshots(pre, post),
    /changed between cgroup snapshots/,
  );
});
