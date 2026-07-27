function requireFiniteValues(values) {
  if (!Array.isArray(values) || values.length === 0) {
    throw new Error("at least one latency sample is required");
  }
  const normalized = values.map(Number);
  if (normalized.some((value) => !Number.isFinite(value))) {
    throw new Error("latency samples must be finite");
  }
  return normalized.sort((left, right) => left - right);
}

export function percentileStats(values) {
  const sorted = requireFiniteValues(values);
  const percentile = (fraction) => {
    const index = (sorted.length - 1) * fraction;
    const lower = Math.floor(index);
    const upper = Math.ceil(index);
    if (lower === upper) {
      return sorted[lower];
    }
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - lower);
  };

  return {
    count: sorted.length,
    avg: sorted.reduce((sum, value) => sum + value, 0) / sorted.length,
    p50: percentile(0.5),
    p90: percentile(0.9),
    p95: percentile(0.95),
    p99: percentile(0.99),
    max: sorted.at(-1),
  };
}

export function connectionIdentity(event) {
  return `${event.environmentId}|${event.runnerIndex}|${event.localConnectionIndex}`;
}

export function assertUniqueEvents(events, identity, label) {
  const seen = new Set();
  for (const event of events) {
    const key = identity(event);
    if (seen.has(key)) {
      throw new Error(`${label} contains duplicate identity '${key}'`);
    }
    seen.add(key);
  }
  return seen;
}

export function validateReadyDistribution(
  events,
  environmentIds,
  {
    parallelism,
    connectionsPerRunner,
    connectionsPerEnvironmentPerRunner,
  },
) {
  if (!Array.isArray(environmentIds) || environmentIds.length === 0) {
    throw new Error("environmentIds must be a non-empty array");
  }
  const expectedIds = new Set(environmentIds);
  if (expectedIds.size !== environmentIds.length) {
    throw new Error("environmentIds must be unique");
  }
  assertUniqueEvents(events, connectionIdentity, "ready events");

  const expectedTotal = parallelism * connectionsPerRunner;
  if (events.length !== expectedTotal) {
    throw new Error(`ready event count ${events.length} does not equal ${expectedTotal}`);
  }

  const runnerCounts = new Map();
  const environmentCounts = new Map();
  const cellCounts = new Map();
  for (const event of events) {
    if (!expectedIds.has(event.environmentId)) {
      throw new Error(`ready event references unknown environment '${event.environmentId}'`);
    }
    if (
      !Number.isInteger(event.runnerIndex) ||
      event.runnerIndex < 1 ||
      event.runnerIndex > parallelism
    ) {
      throw new Error(`ready event has invalid runner ${event.runnerIndex}`);
    }
    runnerCounts.set(event.runnerIndex, (runnerCounts.get(event.runnerIndex) ?? 0) + 1);
    environmentCounts.set(
      event.environmentId,
      (environmentCounts.get(event.environmentId) ?? 0) + 1,
    );
    const cell = `${event.environmentId}|${event.runnerIndex}`;
    cellCounts.set(cell, (cellCounts.get(cell) ?? 0) + 1);
  }

  for (let runner = 1; runner <= parallelism; runner += 1) {
    if (runnerCounts.get(runner) !== connectionsPerRunner) {
      throw new Error(
        `runner ${runner} ready count is ${runnerCounts.get(runner) ?? 0}, ` +
          `expected ${connectionsPerRunner}`,
      );
    }
  }
  const expectedPerEnvironment =
    connectionsPerEnvironmentPerRunner * parallelism;
  for (const environmentId of environmentIds) {
    if (environmentCounts.get(environmentId) !== expectedPerEnvironment) {
      throw new Error(
        `environment '${environmentId}' ready count is ` +
          `${environmentCounts.get(environmentId) ?? 0}, expected ${expectedPerEnvironment}`,
      );
    }
    for (let runner = 1; runner <= parallelism; runner += 1) {
      const cell = `${environmentId}|${runner}`;
      if (cellCounts.get(cell) !== connectionsPerEnvironmentPerRunner) {
        throw new Error(
          `environment '${environmentId}' runner ${runner} ready count is ` +
            `${cellCounts.get(cell) ?? 0}, expected ` +
            `${connectionsPerEnvironmentPerRunner}`,
        );
      }
    }
  }

  return {
    total: events.length,
    runners: runnerCounts.size,
    environments: environmentCounts.size,
    connectionsPerRunner,
    connectionsPerEnvironment: expectedPerEnvironment,
    connectionsPerEnvironmentPerRunner,
  };
}

export function validateTargetDeliveryDistribution(
  events,
  {
    targetEnvironmentId,
    parallelism,
    connectionsPerEnvironmentPerRunner,
    label,
  },
) {
  const expectedTotal = parallelism * connectionsPerEnvironmentPerRunner;
  if (events.some((event) => event.environmentId !== targetEnvironmentId)) {
    throw new Error(`${label} contains a non-target environment event`);
  }
  assertUniqueEvents(events, connectionIdentity, label);
  if (events.length !== expectedTotal) {
    throw new Error(`${label} count ${events.length} does not equal ${expectedTotal}`);
  }
  for (let runner = 1; runner <= parallelism; runner += 1) {
    const count = events.filter((event) => event.runnerIndex === runner).length;
    if (count !== connectionsPerEnvironmentPerRunner) {
      throw new Error(
        `${label} runner ${runner} count ${count} does not equal ` +
          `${connectionsPerEnvironmentPerRunner}`,
      );
    }
  }
  return { count: events.length, perRunner: connectionsPerEnvironmentPerRunner };
}
