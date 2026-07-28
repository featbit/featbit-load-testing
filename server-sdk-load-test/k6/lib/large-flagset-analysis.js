import { percentileStats } from "./multi-environment-analysis.js";

function requireFinite(value, name) {
  const number = Number(value);
  if (!Number.isFinite(number)) {
    throw new Error(`${name} must be finite`);
  }
  return number;
}

function identity(event) {
  return `${event.environmentId}|${event.runnerIndex}|${event.localConnectionIndex}`;
}

export function validateInitialSyncEvents(
  events,
  {
    expectedConnections,
    parallelism,
    connectionsPerRunner,
    expectedEnvironmentId,
    expectedFlagCount,
  },
) {
  if (!Array.isArray(events)) {
    throw new Error("initial-sync events must be an array");
  }
  if (events.length !== expectedConnections) {
    throw new Error(
      `initial-sync event count ${events.length} does not equal ${expectedConnections}`,
    );
  }
  const seen = new Set();
  const runnerCounts = new Map();
  for (const event of events) {
    const key = identity(event);
    if (seen.has(key)) {
      throw new Error(`initial-sync events contain duplicate identity '${key}'`);
    }
    seen.add(key);
    if (event.environmentId !== expectedEnvironmentId) {
      throw new Error(`initial-sync event references environment '${event.environmentId}'`);
    }
    if (
      !Number.isInteger(event.runnerIndex) ||
      event.runnerIndex < 1 ||
      event.runnerIndex > parallelism
    ) {
      throw new Error(`initial-sync event has invalid runner ${event.runnerIndex}`);
    }
    if (
      !Number.isInteger(event.localConnectionIndex) ||
      event.localConnectionIndex < 1 ||
      event.localConnectionIndex > connectionsPerRunner
    ) {
      throw new Error(
        `initial-sync event has invalid connection ${event.localConnectionIndex}`,
      );
    }
    if (Number(event.featureFlagCount) !== expectedFlagCount) {
      throw new Error(
        `initial-sync event ${key} contains ${event.featureFlagCount} flags; ` +
          `expected ${expectedFlagCount}`,
      );
    }
    for (const [name, value] of Object.entries({
      completedAtUnixMs: event.completedAtUnixMs,
      scheduledStartAtUnixMs: event.scheduledStartAtUnixMs,
      iterationStartedAtUnixMs: event.iterationStartedAtUnixMs,
      openedAtUnixMs: event.openedAtUnixMs,
      payloadBytes: event.payloadBytes,
      parseLatencyMs: event.parseLatencyMs,
      validationLatencyMs: event.validationLatencyMs,
    })) {
      requireFinite(value, name);
    }
    if (
      event.scheduledStartAtUnixMs > event.iterationStartedAtUnixMs + 1_000 ||
      event.iterationStartedAtUnixMs > event.openedAtUnixMs ||
      event.openedAtUnixMs > event.completedAtUnixMs
    ) {
      throw new Error(`initial-sync event ${key} has an invalid timestamp order`);
    }
    runnerCounts.set(
      event.runnerIndex,
      (runnerCounts.get(event.runnerIndex) ?? 0) + 1,
    );
  }
  for (let runner = 1; runner <= parallelism; runner += 1) {
    if (runnerCounts.get(runner) !== connectionsPerRunner) {
      throw new Error(
        `runner ${runner} initial-sync count is ${runnerCounts.get(runner) ?? 0}; ` +
          `expected ${connectionsPerRunner}`,
      );
    }
  }
  return { count: events.length, runners: runnerCounts.size };
}

export function summarizeInitialSyncRamp(events, configuredRampDurationMs) {
  if (!Array.isArray(events) || events.length === 0) {
    throw new Error("at least one initial-sync event is required");
  }
  const rampDurationMs = requireFinite(
    configuredRampDurationMs,
    "configuredRampDurationMs",
  );
  if (rampDurationMs <= 0) {
    throw new Error("configuredRampDurationMs must be positive");
  }

  const scenarioStartAtUnixMs =
    Math.max(...events.map((event) => Number(event.scheduledStartAtUnixMs))) -
    rampDurationMs;
  const configuredRampEndAtUnixMs = scenarioStartAtUnixMs + rampDurationMs;
  const values = {
    connection_start_schedule_drift_ms: events.map(
      (event) =>
        Number(event.iterationStartedAtUnixMs) -
        Number(event.scheduledStartAtUnixMs),
    ),
    connection_open_schedule_drift_ms: events.map(
      (event) => Number(event.openedAtUnixMs) - Number(event.scheduledStartAtUnixMs),
    ),
    initial_sync_schedule_drift_ms: events.map(
      (event) =>
        Number(event.completedAtUnixMs) - Number(event.scheduledStartAtUnixMs),
    ),
    connection_open_latency_ms: events.map(
      (event) =>
        Number(event.openedAtUnixMs) - Number(event.iterationStartedAtUnixMs),
    ),
    initial_sync_after_open_latency_ms: events.map(
      (event) => Number(event.completedAtUnixMs) - Number(event.openedAtUnixMs),
    ),
    initial_sync_end_to_end_latency_ms: events.map(
      (event) =>
        Number(event.completedAtUnixMs) - Number(event.iterationStartedAtUnixMs),
    ),
    full_sync_payload_bytes: events.map((event) => Number(event.payloadBytes)),
    full_sync_parse_latency_ms: events.map((event) => Number(event.parseLatencyMs)),
    full_sync_validation_latency_ms: events.map(
      (event) => Number(event.validationLatencyMs),
    ),
  };
  const lastAttemptAtUnixMs = Math.max(
    ...events.map((event) => Number(event.iterationStartedAtUnixMs)),
  );
  const lastOpenAtUnixMs = Math.max(
    ...events.map((event) => Number(event.openedAtUnixMs)),
  );
  const lastInitialSyncAtUnixMs = Math.max(
    ...events.map((event) => Number(event.completedAtUnixMs)),
  );
  const completionOffsets = events
    .map((event) => Number(event.completedAtUnixMs) - scenarioStartAtUnixMs)
    .sort((left, right) => left - right);
  const completionAt = (fraction) => {
    const index = Math.ceil(completionOffsets.length * fraction) - 1;
    return completionOffsets[Math.max(0, index)];
  };
  const totalPayloadBytes = values.full_sync_payload_bytes.reduce(
    (sum, value) => sum + value,
    0,
  );

  return {
    configuredRampDurationMs: rampDurationMs,
    scenarioStartAtUnixMs,
    configuredRampEndAtUnixMs,
    lastAttemptAtUnixMs,
    lastOpenAtUnixMs,
    lastInitialSyncAtUnixMs,
    actualAttemptRampDurationMs: lastAttemptAtUnixMs - scenarioStartAtUnixMs,
    actualOpenRampDurationMs: lastOpenAtUnixMs - scenarioStartAtUnixMs,
    actualReadyRampDurationMs: lastInitialSyncAtUnixMs - scenarioStartAtUnixMs,
    attemptCompletionDelayMs: lastAttemptAtUnixMs - configuredRampEndAtUnixMs,
    openCompletionDelayMs: lastOpenAtUnixMs - configuredRampEndAtUnixMs,
    readyCompletionDelayMs: lastInitialSyncAtUnixMs - configuredRampEndAtUnixMs,
    readyMilestonesMs: {
      p50: completionAt(0.5),
      p90: completionAt(0.9),
      p95: completionAt(0.95),
      p99: completionAt(0.99),
      p100: completionAt(1),
    },
    payload: {
      perConnectionBytes: percentileStats(values.full_sync_payload_bytes),
      totalBytes: totalPayloadBytes,
      totalGiB: totalPayloadBytes / 1024 / 1024 / 1024,
    },
    metrics: Object.fromEntries(
      Object.entries(values).map(([name, samples]) => [
        name,
        percentileStats(samples),
      ]),
    ),
  };
}
