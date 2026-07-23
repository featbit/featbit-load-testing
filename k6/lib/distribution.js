export function expectedConnectionsPerRunner(maxConnections, parallelism) {
  if (!Number.isInteger(maxConnections) || maxConnections < 1) {
    throw new Error("maxConnections must be a positive integer");
  }
  if (!Number.isInteger(parallelism) || parallelism < 1) {
    throw new Error("parallelism must be a positive integer");
  }
  if (maxConnections % parallelism !== 0) {
    throw new Error(
      `MAX_CONNECTIONS (${maxConnections}) must be divisible by ` +
        `LOADTEST_PARALLELISM (${parallelism})`,
    );
  }

  return maxConnections / parallelism;
}

export function runnerIndexFromHostname(hostname, parallelism) {
  if (!Number.isInteger(parallelism) || parallelism < 1) {
    throw new Error("parallelism must be a positive integer");
  }
  if (parallelism === 1) {
    return 1;
  }

  const normalized = String(hostname ?? "").trim();
  const match = /-([1-9][0-9]*)$/.exec(normalized);
  if (!match) {
    throw new Error(
      "HOSTNAME must end with the k6 Operator runner index when " +
        "LOADTEST_PARALLELISM is greater than 1",
    );
  }

  const index = Number(match[1]);
  if (index > parallelism) {
    throw new Error(`runner index ${index} exceeds LOADTEST_PARALLELISM ${parallelism}`);
  }

  return index;
}

export function remainingSetupBarrierMilliseconds(parallelism, barrierSeconds, elapsedMilliseconds) {
  if (!Number.isInteger(parallelism) || parallelism < 1) {
    throw new Error("parallelism must be a positive integer");
  }
  if (!Number.isInteger(barrierSeconds) || barrierSeconds < 0) {
    throw new Error("barrierSeconds must be a non-negative integer");
  }
  if (!Number.isFinite(elapsedMilliseconds) || elapsedMilliseconds < 0) {
    throw new Error("elapsedMilliseconds must be non-negative");
  }
  if (parallelism === 1) {
    return 0;
  }
  if (barrierSeconds === 0) {
    throw new Error(
      "DISTRIBUTED_SETUP_BARRIER_SECONDS must be greater than 0 for a distributed run",
    );
  }

  const remaining = barrierSeconds * 1_000 - elapsedMilliseconds;
  if (remaining <= 0) {
    throw new Error(
      `distributed setup exceeded its ${barrierSeconds}s barrier; ` +
        "increase DISTRIBUTED_SETUP_BARRIER_SECONDS and rerun",
    );
  }

  return remaining;
}
