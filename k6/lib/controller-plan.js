function requireNonNegativeInteger(value, name) {
  if (!Number.isInteger(value) || value < 0) {
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
