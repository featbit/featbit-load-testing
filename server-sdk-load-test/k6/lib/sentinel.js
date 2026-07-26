function requireNonEmptyString(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${name} must be a non-empty string`);
  }
  if (value.includes("|")) {
    throw new Error(`${name} must not contain the pipe character`);
  }
  return value.trim();
}

export function parseSentinelTargets(rawValue) {
  let parsed;
  try {
    parsed = JSON.parse(String(rawValue ?? ""));
  } catch (error) {
    throw new Error(`ELS_SENTINEL_TARGETS must be valid JSON: ${error.message}`);
  }

  if (!Array.isArray(parsed) || parsed.length === 0) {
    throw new Error("ELS_SENTINEL_TARGETS must be a non-empty array");
  }

  const targets = parsed.map((entry, index) => {
    if (!entry || typeof entry !== "object") {
      throw new Error(`ELS_SENTINEL_TARGETS[${index}] must be an object`);
    }
    return {
      pod: requireNonEmptyString(entry.pod, `ELS_SENTINEL_TARGETS[${index}].pod`),
      ip: requireNonEmptyString(entry.ip, `ELS_SENTINEL_TARGETS[${index}].ip`),
    };
  });

  for (const property of ["pod", "ip"]) {
    const values = targets.map((target) => target[property]);
    if (new Set(values).size !== values.length) {
      throw new Error(`ELS_SENTINEL_TARGETS contains duplicate ${property} values`);
    }
  }

  return targets;
}

export function assignSentinelConnection(vuId, targets, connectionsPerTarget) {
  if (!Number.isInteger(vuId) || vuId < 1) {
    throw new Error("vuId must be a positive integer");
  }
  if (!Array.isArray(targets) || targets.length === 0) {
    throw new Error("targets must be a non-empty array");
  }
  if (!Number.isInteger(connectionsPerTarget) || connectionsPerTarget < 1) {
    throw new Error("connectionsPerTarget must be a positive integer");
  }

  const zeroBased = vuId - 1;
  const targetIndex = Math.floor(zeroBased / connectionsPerTarget);
  if (targetIndex >= targets.length) {
    throw new Error(
      `vuId ${vuId} exceeds ${targets.length * connectionsPerTarget} sentinel assignments`,
    );
  }

  return {
    target: targets[targetIndex],
    targetIndex,
    connectionIndex: (zeroBased % connectionsPerTarget) + 1,
  };
}

export function formatSentinelRecord(kind, fields) {
  if (kind !== "READY" && kind !== "EVENT") {
    throw new Error(`Unsupported sentinel record kind '${kind}'`);
  }
  return [
    `SENTINEL_${kind}`,
    "1",
    ...fields.map((value, index) =>
      requireNonEmptyString(String(value), `sentinel field ${index + 1}`),
    ),
  ].join("|");
}

function percentile(sortedValues, fraction) {
  if (sortedValues.length === 0) {
    return null;
  }
  const rank = (sortedValues.length - 1) * fraction;
  const lower = Math.floor(rank);
  const upper = Math.ceil(rank);
  if (lower === upper) {
    return sortedValues[lower];
  }
  return (
    sortedValues[lower] +
    (sortedValues[upper] - sortedValues[lower]) * (rank - lower)
  );
}

export function summarizeSentinelValues(values) {
  if (!Array.isArray(values) || values.length === 0) {
    throw new Error("values must be a non-empty array");
  }
  const sorted = values.map(Number).sort((left, right) => left - right);
  if (sorted.some((value) => !Number.isFinite(value))) {
    throw new Error("values must contain only finite numbers");
  }
  return {
    count: sorted.length,
    avg: sorted.reduce((total, value) => total + value, 0) / sorted.length,
    min: sorted[0],
    med: percentile(sorted, 0.5),
    p95: percentile(sorted, 0.95),
    p99: percentile(sorted, 0.99),
    max: sorted.at(-1),
  };
}

export function classifySentinelRevision(cells, options = {}) {
  const spikeThresholdMs = Number(options.spikeThresholdMs ?? 100);
  const rowMinimumTargets = Number(options.rowMinimumTargets ?? 4);
  const columnMinimumNodes = Number(options.columnMinimumNodes ?? 7);
  const globalMinimumCells = Number(options.globalMinimumCells ?? 30);
  const mainRunnerP99Ms = Number(options.mainRunnerP99Ms ?? 0);

  if (!Array.isArray(cells) || cells.length === 0) {
    throw new Error("cells must be a non-empty array");
  }

  const spiking = cells.filter((cell) => Number(cell.stats?.med) > spikeThresholdMs);
  const rowCounts = new Map();
  const columnCounts = new Map();
  for (const cell of spiking) {
    rowCounts.set(cell.loadgenNode, (rowCounts.get(cell.loadgenNode) ?? 0) + 1);
    columnCounts.set(cell.elsPod, (columnCounts.get(cell.elsPod) ?? 0) + 1);
  }

  const rowWaves = [...rowCounts.entries()]
    .filter(([, count]) => count >= rowMinimumTargets)
    .map(([loadgenNode, affectedTargets]) => ({ loadgenNode, affectedTargets }));
  const columnWaves = [...columnCounts.entries()]
    .filter(([, count]) => count >= columnMinimumNodes)
    .map(([elsPod, affectedNodes]) => ({ elsPod, affectedNodes }));
  const globalWave = spiking.length >= globalMinimumCells;
  const mainRunnerSpike = mainRunnerP99Ms > spikeThresholdMs;

  let classification;
  if (globalWave) {
    classification = "global";
  } else if (rowWaves.length > 0 && columnWaves.length > 0) {
    classification = "mixed-row-column";
  } else if (columnWaves.length > 0) {
    classification = "els-column";
  } else if (rowWaves.length > 0) {
    classification = "loadgen-row";
  } else if (spiking.length > 0) {
    classification = "isolated-cells";
  } else if (mainRunnerSpike) {
    classification = "main-runners-only";
  } else {
    classification = "stable";
  }

  return {
    classification,
    spikeThresholdMs,
    mainRunnerP99Ms,
    mainRunnerSpike,
    spikingCells: spiking.length,
    rowWaves,
    columnWaves,
    globalWave,
  };
}
