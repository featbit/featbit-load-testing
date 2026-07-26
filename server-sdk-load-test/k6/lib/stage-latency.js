const TREND_FIELDS = ["avg", "min", "med", "max", "p(90)", "p(95)", "p(99)"];

export function shiftTrend(trend, offsetMs) {
  if (!trend || !Number.isFinite(Number(trend.count)) || Number(trend.count) <= 0) {
    throw new Error("trend must contain a positive sample count");
  }
  if (!Number.isFinite(offsetMs)) {
    throw new Error("offsetMs must be finite");
  }

  const shifted = { count: Number(trend.count) };
  for (const field of TREND_FIELDS) {
    const value = Number(trend[field]);
    if (!Number.isFinite(value)) {
      throw new Error(`trend field '${field}' must be finite`);
    }
    shifted[field] = value + offsetMs;
  }
  return shifted;
}

export function rollUpDistributedTrends(trends) {
  if (!Array.isArray(trends) || trends.length === 0) {
    throw new Error("at least one trend is required");
  }

  const count = trends.reduce((sum, trend) => sum + Number(trend.count), 0);
  if (!Number.isFinite(count) || count <= 0) {
    throw new Error("combined trend count must be positive");
  }
  const weightedAverage =
    trends.reduce(
      (sum, trend) => sum + Number(trend.avg) * Number(trend.count),
      0,
    ) / count;

  const range = (field) => {
    const values = trends.map((trend) => Number(trend[field]));
    if (values.some((value) => !Number.isFinite(value))) {
      throw new Error(`trend field '${field}' must be finite`);
    }
    return { min: Math.min(...values), max: Math.max(...values) };
  };

  return {
    count,
    avg: weightedAverage,
    min: Math.min(...trends.map((trend) => Number(trend.min))),
    max: Math.max(...trends.map((trend) => Number(trend.max))),
    med: range("med"),
    p90: range("p(90)"),
    p95: range("p(95)"),
    p99: range("p(99)"),
  };
}

export function scalarStats(values) {
  if (!Array.isArray(values) || values.length === 0) {
    throw new Error("at least one scalar value is required");
  }
  const sorted = values.map(Number).sort((left, right) => left - right);
  if (sorted.some((value) => !Number.isFinite(value))) {
    throw new Error("scalar values must be finite");
  }

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
    min: sorted[0],
    med: percentile(0.5),
    p90: percentile(0.9),
    p95: percentile(0.95),
    p99: percentile(0.99),
    max: sorted.at(-1),
  };
}
