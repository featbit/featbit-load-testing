import { percentileStats } from "../../k6/lib/multi-environment-analysis.js";

function fail(message) {
  throw new Error(message);
}

function finite(value, name) {
  const number = Number(value);
  if (!Number.isFinite(number)) fail(`${name} must be finite`);
  return number;
}

function integer(value, name) {
  const number = Number(value);
  if (!Number.isInteger(number)) fail(`${name} must be an integer`);
  return number;
}

function identity(event) {
  return `${event.runner}|${event.localConnection}`;
}

function assertUnique(events, label) {
  const seen = new Set();
  for (const event of events) {
    const key = identity(event);
    if (seen.has(key)) fail(`${label} contains duplicate identity '${key}'`);
    seen.add(key);
  }
  return seen;
}

function safeStats(values) {
  return values.length === 0 ? null : percentileStats(values);
}

function deJitterDiagnostic(endToEnd, probeSync, cutoffMs = 100) {
  const retainedIndexes = [];
  for (let index = 0; index < probeSync.length; index += 1) {
    if (probeSync[index] <= cutoffMs) retainedIndexes.push(index);
  }
  const retainedEndToEnd = retainedIndexes.map((index) => endToEnd[index]);
  const retainedProbeSync = retainedIndexes.map((index) => probeSync[index]);
  const removedCount = probeSync.length - retainedIndexes.length;
  return {
    rule: `probe_sync_latency_ms <= ${cutoffMs}`,
    cutoffMs,
    originalCount: probeSync.length,
    retainedCount: retainedIndexes.length,
    removedCount,
    removedPercent:
      probeSync.length === 0 ? 0 : (removedCount / probeSync.length) * 100,
    end_to_end_latency_ms: safeStats(retainedEndToEnd),
    probe_sync_latency_ms: safeStats(retainedProbeSync),
    primaryResult: false,
  };
}

export function validateReadyEvents(
  events,
  {
    parallelism,
    clientsPerRunner,
    totalConnections,
    connectionsPerSecond,
    startAtUnixMs,
    environmentId,
  },
) {
  if (!Array.isArray(events)) fail("ready events must be an array");
  if (events.length !== totalConnections) {
    fail(`ready event count ${events.length} does not equal ${totalConnections}`);
  }
  assertUnique(events, "ready events");

  const globals = new Set();
  const runnerCounts = new Map();
  for (const event of events) {
    const runner = integer(event.runner, "runner");
    const local = integer(event.localConnection, "localConnection");
    const global = integer(event.globalConnection, "globalConnection");
    if (runner < 1 || runner > parallelism) {
      fail(`ready event has invalid runner ${runner}`);
    }
    if (local < 1 || local > clientsPerRunner) {
      fail(`ready event has invalid local connection ${local}`);
    }
    const expectedGlobal = (local - 1) * parallelism + runner;
    if (global !== expectedGlobal) {
      fail(
        `ready identity ${runner}|${local} has global ${global}; ` +
          `expected ${expectedGlobal}`,
      );
    }
    if (globals.has(global)) fail(`global connection ${global} is duplicated`);
    globals.add(global);

    if (event.environmentId !== environmentId) {
      fail(`ready event references environment '${event.environmentId}'`);
    }
    const expectedScheduled =
      startAtUnixMs + Math.floor(((global - 1) * 1000) / connectionsPerSecond);
    const scheduled = finite(event.scheduledAtUnixMs, "scheduledAtUnixMs");
    const created = finite(event.createStartedAtUnixMs, "createStartedAtUnixMs");
    const constructorReturned = finite(
      event.constructorReturnedAtUnixMs,
      "constructorReturnedAtUnixMs",
    );
    const ready = finite(event.atUnixMs, "atUnixMs");
    if (scheduled !== expectedScheduled) {
      fail(
        `ready identity ${runner}|${local} was scheduled at ${scheduled}; ` +
          `expected ${expectedScheduled}`,
      );
    }
    if (
      created < scheduled - 25 ||
      constructorReturned < created ||
      ready < constructorReturned
    ) {
      fail(`ready identity ${runner}|${local} has invalid timestamp order`);
    }
    if (finite(event.initializationLatencyMs, "initializationLatencyMs") !== ready - created) {
      fail(`ready identity ${runner}|${local} has inconsistent initialization latency`);
    }
    if (finite(event.readyScheduleDriftMs, "readyScheduleDriftMs") !== ready - scheduled) {
      fail(`ready identity ${runner}|${local} has inconsistent ready schedule drift`);
    }
    runnerCounts.set(runner, (runnerCounts.get(runner) ?? 0) + 1);
  }

  for (let runner = 1; runner <= parallelism; runner += 1) {
    if (runnerCounts.get(runner) !== clientsPerRunner) {
      fail(
        `runner ${runner} ready count is ${runnerCounts.get(runner) ?? 0}; ` +
          `expected ${clientsPerRunner}`,
      );
    }
  }
  if (
    globals.size !== totalConnections ||
    Math.min(...globals) !== 1 ||
    Math.max(...globals) !== totalConnections
  ) {
    fail("global connection IDs do not cover the exact expected range");
  }
  return {
    count: events.length,
    runners: runnerCounts.size,
    connectionsPerRunner: clientsPerRunner,
  };
}

export function summarizeInitialization(
  readyEvents,
  {
    startAtUnixMs,
    configuredRampDurationMs,
    totalConnections,
    connectionsPerSecond,
  },
) {
  if (!Array.isArray(readyEvents) || readyEvents.length === 0) {
    fail("at least one ready event is required");
  }
  const rampEnd = finite(startAtUnixMs, "startAtUnixMs") +
    finite(configuredRampDurationMs, "configuredRampDurationMs");
  const createTimes = readyEvents.map((event) =>
    finite(event.createStartedAtUnixMs, "createStartedAtUnixMs"),
  );
  const readyTimes = readyEvents.map((event) => finite(event.atUnixMs, "atUnixMs"));
  const scheduledTimes = readyEvents.map((event) =>
    finite(event.scheduledAtUnixMs, "scheduledAtUnixMs"),
  );
  const lastScheduled = Math.max(...scheduledTimes);
  const lastCreated = Math.max(...createTimes);
  const lastReady = Math.max(...readyTimes);
  const readyOffsets = readyTimes.map((value) => value - startAtUnixMs);
  const perSecond = [];
  const finalSecond = Math.max(
    0,
    Math.ceil((lastReady - startAtUnixMs) / 1000),
  );
  for (let second = 1; second <= finalSecond; second += 1) {
    const boundary = startAtUnixMs + second * 1000;
    perSecond.push({
      second,
      scheduled: scheduledTimes.filter((value) => value <= boundary).length,
      created: createTimes.filter((value) => value <= boundary).length,
      ready: readyTimes.filter((value) => value <= boundary).length,
    });
  }

  return {
    configured: {
      totalConnections,
      connectionsPerSecond,
      rampDurationMs: configuredRampDurationMs,
      startAtUnixMs,
      rampEndAtUnixMs: rampEnd,
    },
    actual: {
      firstCreateAtUnixMs: Math.min(...createTimes),
      lastScheduledAtUnixMs: lastScheduled,
      lastCreateAtUnixMs: lastCreated,
      lastReadyAtUnixMs: lastReady,
      scheduledSpanMs: lastScheduled - startAtUnixMs,
      createCompletionOffsetMs: lastCreated - startAtUnixMs,
      readyCompletionOffsetMs: lastReady - startAtUnixMs,
      createCompletionDelayVsRampEndMs: lastCreated - rampEnd,
      readyCompletionDelayVsRampEndMs: lastReady - rampEnd,
      readyAtRampEnd: readyTimes.filter((value) => value <= rampEnd).length,
      readyBacklogAtRampEnd:
        totalConnections - readyTimes.filter((value) => value <= rampEnd).length,
    },
    metrics: {
      create_schedule_drift_ms: percentileStats(
        readyEvents.map(
          (event) => Number(event.createStartedAtUnixMs) - Number(event.scheduledAtUnixMs),
        ),
      ),
      sdk_initialization_latency_ms: percentileStats(
        readyEvents.map((event) => Number(event.initializationLatencyMs)),
      ),
      ready_schedule_drift_ms: percentileStats(
        readyEvents.map((event) => Number(event.readyScheduleDriftMs)),
      ),
      ready_offset_from_ramp_start_ms: percentileStats(readyOffsets),
    },
    cumulativePerSecond: perSecond,
  };
}

export function extractServedRevision(flag) {
  const selectedId = flag?.isEnabled
    ? flag.fallthrough?.variations?.[0]?.id
    : flag?.disabledVariationId;
  const variation = flag?.variations?.find((candidate) => candidate?.id === selectedId);
  if (!variation || typeof variation.value !== "string") {
    fail(`Cannot resolve served revision for flag '${flag?.key ?? "<unknown>"}'`);
  }
  const variationType = String(flag.variationType ?? "").toLowerCase();
  if (variationType === "string") return variation.value;
  if (variationType !== "json") {
    fail(`Unsupported observer variation type '${flag?.variationType}'`);
  }
  let configuration;
  try {
    configuration = JSON.parse(variation.value);
  } catch (error) {
    fail(`Observer JSON variation is invalid: ${error.message}`);
  }
  if (
    !configuration ||
    typeof configuration !== "object" ||
    typeof configuration._loadTestRevision !== "string" ||
    configuration._loadTestRevision.length === 0
  ) {
    fail("Observer JSON variation has no _loadTestRevision");
  }
  return configuration._loadTestRevision;
}

export function normalizeObserverRecords(records) {
  if (!Array.isArray(records)) fail("observer records must be an array");
  return records.map((record, index) => {
    const observedAtUnixMs = finite(
      record.observedAtUnixMs,
      `observer[${index}].observedAtUnixMs`,
    );
    const updatedAtMs = Date.parse(record.payload?.updatedAt);
    if (!Number.isFinite(updatedAtMs)) {
      fail(`observer[${index}].payload.updatedAt is invalid`);
    }
    return {
      node: String(record.node ?? ""),
      environmentId: String(record.payload?.envId ?? ""),
      flagKey: String(record.payload?.key ?? ""),
      revision: extractServedRevision(record.payload),
      entityRevision: String(record.payload?.revision ?? ""),
      updatedAt: String(record.payload.updatedAt),
      updatedAtMs,
      observedAtUnixMs,
    };
  });
}

export function successfulControllerWrites(records, plan, environmentId) {
  if (!Array.isArray(records)) fail("controller records must be an array");
  const formal = records.filter(
    (record) =>
      record.environmentId === environmentId && Number(record.revisionIndex) > 0,
  );
  const groups = new Map();
  for (const record of formal) {
    const key = [
      record.revisionIndex,
      record.revision,
      record.flagKey,
      record.attempt,
    ].join("|");
    const group = groups.get(key) ?? {};
    group[record.event] = record;
    groups.set(key, group);
  }
  const writes = [];
  for (const group of groups.values()) {
    if (group.request_start && group.request_end) {
      writes.push({
        ...group.request_start,
        atUnixMs: finite(group.request_start.atUnixMs, "controller request start"),
        requestEndedAtUnixMs: finite(
          group.request_end.atUnixMs,
          "controller request end",
        ),
        revisionIndex: integer(group.request_start.revisionIndex, "revisionIndex"),
      });
    }
  }
  writes.sort((left, right) => left.revisionIndex - right.revisionIndex);
  if (writes.length !== plan.length) {
    fail(`successful controller write count ${writes.length} does not equal ${plan.length}`);
  }
  for (let index = 0; index < plan.length; index += 1) {
    const write = writes[index];
    const expected = plan[index];
    if (
      write.revisionIndex !== index + 1 ||
      write.revision !== expected.revision ||
      write.flagKey !== expected.flagKey
    ) {
      fail(`controller write ${index + 1} does not match the revision plan`);
    }
    if (write.requestEndedAtUnixMs < write.atUnixMs) {
      fail(`controller write ${index + 1} has invalid timestamps`);
    }
  }
  return writes;
}

function observerGroupForWrite(observerEvents, write, expectedObserverNodes) {
  const candidates = observerEvents.filter(
    (event) =>
      event.environmentId === write.environmentId &&
      event.flagKey === write.flagKey &&
      event.revision === write.revision &&
      event.observedAtUnixMs >= write.atUnixMs - 500 &&
      event.observedAtUnixMs <= write.requestEndedAtUnixMs + 5_000,
  );
  const groups = new Map();
  for (const event of candidates) {
    const key = `${event.updatedAt}|${event.entityRevision}`;
    const group = groups.get(key) ?? [];
    group.push(event);
    groups.set(key, group);
  }
  const valid = [...groups.values()].filter((events) => {
    const nodes = new Set(events.map((event) => event.node));
    return events.length === expectedObserverNodes.length &&
      nodes.size === expectedObserverNodes.length;
  });
  if (valid.length !== 1) {
    fail(
      `revision ${write.revisionIndex} expected one complete observer group; ` +
        `found ${valid.length}`,
    );
  }
  const actualNodes = [...new Set(valid[0].map((event) => event.node))].sort();
  const expectedNodes = [...expectedObserverNodes].sort();
  if (JSON.stringify(actualNodes) !== JSON.stringify(expectedNodes)) {
    fail(`revision ${write.revisionIndex} observer nodes differ from the contract`);
  }
  return valid[0];
}

function validateObservationDistribution(
  events,
  { expectedConnections, parallelism, clientsPerRunner, environmentId, label },
) {
  if (events.length !== expectedConnections) {
    fail(`${label} count ${events.length} does not equal ${expectedConnections}`);
  }
  assertUnique(events, label);
  const runnerCounts = new Map();
  for (const event of events) {
    const runner = integer(event.runner, "runner");
    const local = integer(event.localConnection, "localConnection");
    if (
      runner < 1 ||
      runner > parallelism ||
      local < 1 ||
      local > clientsPerRunner
    ) {
      fail(`${label} has invalid connection identity ${runner}|${local}`);
    }
    if (event.environmentId !== environmentId) {
      fail(`${label} references environment '${event.environmentId}'`);
    }
    runnerCounts.set(runner, (runnerCounts.get(runner) ?? 0) + 1);
  }
  for (let runner = 1; runner <= parallelism; runner += 1) {
    if (runnerCounts.get(runner) !== clientsPerRunner) {
      fail(
        `${label} runner ${runner} count is ${runnerCounts.get(runner) ?? 0}; ` +
          `expected ${clientsPerRunner}`,
      );
    }
  }
}

export function analyzeFormalPropagation({
  observations,
  controllerRecords,
  observerRecords,
  plan,
  environmentId,
  expectedConnections,
  parallelism,
  clientsPerRunner,
  expectedObserverNodes,
  crossNodeClockToleranceMs = 10,
}) {
  const clockToleranceMs = finite(
    crossNodeClockToleranceMs,
    "crossNodeClockToleranceMs",
  );
  if (clockToleranceMs < 0) {
    fail("crossNodeClockToleranceMs must be non-negative");
  }
  const writes = successfulControllerWrites(controllerRecords, plan, environmentId);
  const observerEvents = normalizeObserverRecords(observerRecords);
  const revisions = [];
  const combinedEndToEnd = [];
  const combinedStreaming = [];
  const controlPlaneValues = [];
  const perConnection = new Map();

  for (const write of writes) {
    const observerGroup = observerGroupForWrite(
      observerEvents,
      write,
      expectedObserverNodes,
    );
    const redisObservedAt = Math.min(
      ...observerGroup.map((event) => event.observedAtUnixMs),
    );
    const matching = observations.filter(
      (event) =>
        event.event === "variation_observed" &&
        event.environmentId === environmentId &&
        event.flagKey === write.flagKey &&
        event.revision === write.revision &&
        Number(event.revisionIndex) === write.revisionIndex &&
        Number(event.atUnixMs) >= write.atUnixMs,
    );
    validateObservationDistribution(matching, {
      expectedConnections,
      parallelism,
      clientsPerRunner,
      environmentId,
      label: `revision ${write.revisionIndex}`,
    });
    const endToEnd = matching.map(
      (event) => Number(event.atUnixMs) - write.atUnixMs,
    );
    const streaming = matching.map(
      (event) => Number(event.atUnixMs) - redisObservedAt,
    );
    if (endToEnd.some((value) => value < 0)) {
      fail(`revision ${write.revisionIndex} contains negative end-to-end latency`);
    }
    const minimumStreaming = Math.min(...streaming);
    const negativeStreamingCount = streaming.filter((value) => value < 0).length;
    if (minimumStreaming < -clockToleranceMs) {
      fail(
        `revision ${write.revisionIndex} probe-sync minimum ` +
          `${minimumStreaming} ms exceeds the ${clockToleranceMs} ms ` +
          "cross-node clock uncertainty tolerance",
      );
    }
    const controlPlane = redisObservedAt - write.atUnixMs;
    if (controlPlane < 0) {
      fail(`revision ${write.revisionIndex} has negative control-plane latency`);
    }
    combinedEndToEnd.push(...endToEnd);
    combinedStreaming.push(...streaming);
    controlPlaneValues.push(controlPlane);

    const runnerDiagnostics = [];
    for (let runner = 1; runner <= parallelism; runner += 1) {
      const samples = matching
        .filter((event) => Number(event.runner) === runner)
        .map((event) => Number(event.atUnixMs) - redisObservedAt);
      runnerDiagnostics.push({ runner, ...percentileStats(samples) });
    }
    for (const event of matching) {
      const key = identity(event);
      const sequence = perConnection.get(key) ?? [];
      sequence.push({
        revisionIndex: write.revisionIndex,
        atUnixMs: Number(event.atUnixMs),
      });
      perConnection.set(key, sequence);
    }

    revisions.push({
      revisionIndex: write.revisionIndex,
      flagKey: write.flagKey,
      revision: write.revision,
      variationType: plan[write.revisionIndex - 1].variationType,
      controllerRequestStartedAtUnixMs: write.atUnixMs,
      controllerRequestEndedAtUnixMs: write.requestEndedAtUnixMs,
      redisFirstObservedAtUnixMs: redisObservedAt,
      observerArrivalSpreadMs:
        Math.max(...observerGroup.map((event) => event.observedAtUnixMs)) -
        redisObservedAt,
      observerEventCount: observerGroup.length,
      control_plane_write_latency_ms: controlPlane,
      end_to_end_latency_ms: percentileStats(endToEnd),
      probe_sync_latency_ms: percentileStats(streaming),
      deJitterDiagnostic: deJitterDiagnostic(endToEnd, streaming),
      probeSyncMinimumMs: minimumStreaming,
      negativeProbeSyncSampleCount: negativeStreamingCount,
      runnerDiagnostics,
    });
  }

  let sequenceErrors = 0;
  for (const sequence of perConnection.values()) {
    sequence.sort((left, right) => left.revisionIndex - right.revisionIndex);
    if (sequence.length !== plan.length) {
      sequenceErrors += 1;
      continue;
    }
    for (let index = 0; index < sequence.length; index += 1) {
      if (
        sequence[index].revisionIndex !== index + 1 ||
        (index > 0 && sequence[index].atUnixMs < sequence[index - 1].atUnixMs)
      ) {
        sequenceErrors += 1;
        break;
      }
    }
  }
  if (perConnection.size !== expectedConnections) {
    sequenceErrors += expectedConnections - perConnection.size;
  }

  return {
    revisionCount: revisions.length,
    expectedSampleCount: expectedConnections * plan.length,
    sampleCount: combinedStreaming.length,
    revisionSequenceErrors: sequenceErrors,
    finalRevisionCorrectConnections:
      observations.filter(
        (event) =>
          event.event === "variation_observed" &&
          event.environmentId === environmentId &&
          event.flagKey === plan.at(-1).flagKey &&
          event.revision === plan.at(-1).revision &&
          Number(event.revisionIndex) === plan.length,
      ).length,
    revisions,
    combined: {
      end_to_end_latency_ms: percentileStats(combinedEndToEnd),
      probe_sync_latency_ms: percentileStats(combinedStreaming),
      control_plane_write_latency_ms: percentileStats(controlPlaneValues),
      deJitterDiagnostic: deJitterDiagnostic(
        combinedEndToEnd,
        combinedStreaming,
      ),
    },
    crossNodeClockUncertainty: {
      toleranceMs: clockToleranceMs,
      minimumProbeSyncLatencyMs: Math.min(...combinedStreaming),
      negativeProbeSyncSampleCount:
        combinedStreaming.filter((value) => value < 0).length,
      valuesClipped: false,
    },
  };
}

export function validateWarmupCoverage({
  observations,
  controllerRecords,
  environmentId,
  flagKey,
  expectedConnections,
  parallelism,
  clientsPerRunner,
}) {
  const warmupWrites = controllerRecords
    .filter(
      (record) =>
        record.environmentId === environmentId &&
        Number(record.revisionIndex) === 0 &&
        record.flagKey === flagKey &&
        record.event === "request_start",
    )
    .sort((left, right) => Number(left.atUnixMs) - Number(right.atUnixMs));
  if (warmupWrites.length !== 2) {
    fail(`expected two warm-up writes; found ${warmupWrites.length}`);
  }
  const expectedRevisions = ["rev-001", "baseline"];
  const deliveries = [];
  for (let index = 0; index < 2; index += 1) {
    const write = warmupWrites[index];
    if (write.revision !== expectedRevisions[index]) {
      fail(`warm-up write ${index + 1} expected '${expectedRevisions[index]}'`);
    }
    const nextWriteAt =
      index + 1 < warmupWrites.length
        ? Number(warmupWrites[index + 1].atUnixMs)
        : Number.POSITIVE_INFINITY;
    const matching = observations.filter(
      (event) =>
        event.event === "variation_observed" &&
        event.environmentId === environmentId &&
        event.flagKey === flagKey &&
        event.revision === write.revision &&
        Number(event.atUnixMs) >= Number(write.atUnixMs) &&
        Number(event.atUnixMs) < nextWriteAt,
    );
    validateObservationDistribution(matching, {
      expectedConnections,
      parallelism,
      clientsPerRunner,
      environmentId,
      label: `warm-up ${write.revision}`,
    });
    deliveries.push({
      revision: write.revision,
      count: matching.length,
      latencyMs: percentileStats(
        matching.map((event) => Number(event.atUnixMs) - Number(write.atUnixMs)),
      ),
    });
  }
  return {
    connectionCoverage: expectedConnections,
    deliveryCount: deliveries.reduce((sum, entry) => sum + entry.count, 0),
    deliveries,
  };
}

export function summarizeRunnerRuntime(samples) {
  if (!Array.isArray(samples) || samples.length === 0) {
    return { sampleCount: 0, perRunner: [], aggregatePeaks: null };
  }
  const perRunner = [];
  const runners = [...new Set(samples.map((sample) => Number(sample.runner)))].sort(
    (left, right) => left - right,
  );
  for (const runner of runners) {
    const rows = samples.filter((sample) => Number(sample.runner) === runner);
    perRunner.push({
      runner,
      samples: rows.length,
      peakCpuCores: Math.max(...rows.map((row) => Number(row.cpuCores))),
      peakWorkingSetBytes: Math.max(
        ...rows.map((row) => Number(row.workingSetBytes)),
      ),
      peakPrivateMemoryBytes: Math.max(
        ...rows.map((row) => Number(row.privateMemoryBytes)),
      ),
      peakManagedMemoryBytes: Math.max(
        ...rows.map((row) => Number(row.managedMemoryBytes)),
      ),
      peakProcessThreads: Math.max(
        ...rows.map((row) => Number(row.processThreads)),
      ),
    });
  }
  return {
    sampleCount: samples.length,
    perRunner,
    aggregatePeaks: {
      maxSingleRunnerCpuCores: Math.max(
        ...perRunner.map((entry) => entry.peakCpuCores),
      ),
      maxSingleRunnerWorkingSetBytes: Math.max(
        ...perRunner.map((entry) => entry.peakWorkingSetBytes),
      ),
      maxSingleRunnerPrivateMemoryBytes: Math.max(
        ...perRunner.map((entry) => entry.peakPrivateMemoryBytes),
      ),
      maxSingleRunnerManagedMemoryBytes: Math.max(
        ...perRunner.map((entry) => entry.peakManagedMemoryBytes),
      ),
      maxSingleRunnerThreads: Math.max(
        ...perRunner.map((entry) => entry.peakProcessThreads),
      ),
    },
  };
}

export function summarizePublicHealth(events, expectedRunners) {
  const count = (name) => events.filter((event) => event.event === name).length;
  const readyByIdentity = new Map(
    events
      .filter((event) => event.event === "sdk_ready")
      .map((event) => [identity(event), Number(event.atUnixMs)]),
  );
  const unhealthyTransitions = events.filter((event) => {
    if (event.event !== "client_status_changed" || event.status === "Ready") {
      return false;
    }
    const readyAt = readyByIdentity.get(identity(event));
    return Number.isFinite(readyAt) && Number(event.atUnixMs) >= readyAt;
  });
  const canaries = events.filter((event) => event.event === "canary_flag_count");
  return {
    runnerStarted: count("runner_started"),
    runnerFinished: count("runner_finished"),
    clientCreateFailures: count("client_create_failed"),
    readyTimeouts: count("ready_timeout"),
    invalidVariationObservations: count("variation_observation_invalid"),
    startGateLateRunners: count("start_gate_late"),
    postReadyUnhealthyTransitions: unhealthyTransitions.length,
    canaryFlagCountChecks: canaries.length,
    canaryFlagCountMatches: canaries.filter((event) => event.matched === true).length,
    expectedRunners,
    passed:
      count("runner_started") === expectedRunners &&
      count("runner_finished") === expectedRunners &&
      count("client_create_failed") === 0 &&
      count("ready_timeout") === 0 &&
      count("variation_observation_invalid") === 0 &&
      count("start_gate_late") === 0 &&
      unhealthyTransitions.length === 0 &&
      canaries.length === expectedRunners &&
      canaries.every((event) => event.matched === true),
  };
}

export function analyzeElsCgroupSnapshots(pre, post) {
  if (!pre || !post) fail("both ELS cgroup snapshots are required");
  if (pre.runId !== post.runId) fail("ELS cgroup snapshots have different run IDs");
  if (pre.phase !== "pre" || post.phase !== "post") {
    fail("ELS cgroup snapshots have invalid phases");
  }
  const prePods = Array.isArray(pre.pods) ? pre.pods : [];
  const postPods = Array.isArray(post.pods) ? post.pods : [];
  if (prePods.length !== 3 || postPods.length !== 3) {
    fail("ELS cgroup snapshots must each contain exactly three Pods");
  }
  const preByUid = new Map(prePods.map((pod) => [String(pod.podUid), pod]));
  const perPod = [];
  for (const after of postPods) {
    const before = preByUid.get(String(after.podUid));
    if (!before || before.pod !== after.pod || before.node !== after.node) {
      fail(`ELS Pod '${after.pod}' changed between cgroup snapshots`);
    }
    if (
      Number(before.restartCount) !== Number(after.restartCount) ||
      Number(after.restartCount) !== 0
    ) {
      fail(`ELS Pod '${after.pod}' restarted during the measured window`);
    }
    const delta = (field) => {
      const value = finite(after.cpu?.[field], `post ${after.pod} ${field}`) -
        finite(before.cpu?.[field], `pre ${after.pod} ${field}`);
      if (value < 0) fail(`ELS Pod '${after.pod}' ${field} counter decreased`);
      return value;
    };
    const cpuPeriods = delta("nr_periods");
    const throttledPeriods = delta("nr_throttled");
    const throttledUsec = delta("throttled_usec");
    perPod.push({
      pod: String(after.pod),
      podUid: String(after.podUid),
      node: String(after.node),
      usageUsec: delta("usage_usec"),
      cpuPeriods,
      throttledPeriods,
      throttledUsec,
      throttledPeriodRate:
        cpuPeriods === 0 ? 0 : throttledPeriods / cpuPeriods,
    });
  }
  const sum = (field) =>
    perPod.reduce((total, pod) => total + Number(pod[field]), 0);
  const cpuPeriods = sum("cpuPeriods");
  const throttledPeriods = sum("throttledPeriods");
  const throttledUsec = sum("throttledUsec");
  return {
    exactWindowDelta: true,
    preCapturedAtUnixMs: finite(pre.capturedAtUnixMs, "pre capturedAtUnixMs"),
    postCapturedAtUnixMs: finite(post.capturedAtUnixMs, "post capturedAtUnixMs"),
    podCount: perPod.length,
    podIdentityStable: true,
    restartCount: 0,
    perPod,
    totals: {
      usageUsec: sum("usageUsec"),
      cpuPeriods,
      throttledPeriods,
      throttledUsec,
      throttledMilliseconds: throttledUsec / 1000,
      throttledPeriodRate:
        cpuPeriods === 0 ? 0 : throttledPeriods / cpuPeriods,
    },
  };
}

export { safeStats };
