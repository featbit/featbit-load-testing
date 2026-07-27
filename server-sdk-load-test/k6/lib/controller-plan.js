function requireNonNegativeInteger(value, name) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }
}

export function validatePostRampWarmupFlagKey(rawFlagKey, measuredFlagKeys) {
  const flagKey = String(rawFlagKey ?? "").trim();
  if (!flagKey) {
    return "";
  }

  if (!Array.isArray(measuredFlagKeys)) {
    throw new Error("measuredFlagKeys must be an array");
  }
  if (measuredFlagKeys.includes(flagKey)) {
    throw new Error(
      `POST_RAMP_WARMUP_FLAG_KEY '${flagKey}' must not also appear in PROBE_FLAG_KEYS`,
    );
  }

  return flagKey;
}

export function postRampWarmupDurationSeconds(flagKey, settleSeconds) {
  requireNonNegativeInteger(settleSeconds, "CONTROLLER_POST_RAMP_WARMUP_SETTLE_SECONDS");
  return String(flagKey ?? "").trim() ? settleSeconds * 2 : 0;
}

export function scheduledControllerDelaySeconds(
  nowUnixMs,
  dueUnixMs,
  maximumLatenessMs = 750,
) {
  requireNonNegativeInteger(nowUnixMs, "nowUnixMs");
  requireNonNegativeInteger(dueUnixMs, "CONTROLLER_DUE_UNIX_MS");
  requireNonNegativeInteger(maximumLatenessMs, "maximumLatenessMs");
  if (dueUnixMs === 0) {
    return 0;
  }

  const latenessMs = nowUnixMs - dueUnixMs;
  if (latenessMs > maximumLatenessMs) {
    throw new Error(
      `scheduled controller update is ${latenessMs}ms late; ` +
        `maximum is ${maximumLatenessMs}ms`,
    );
  }
  return Math.max(0, dueUnixMs - nowUnixMs) / 1000;
}
