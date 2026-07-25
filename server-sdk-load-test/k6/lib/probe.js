function parseUniqueList(rawValue, variableName) {
  const values = String(rawValue ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);

  const unique = new Set(values);
  if (unique.size !== values.length) {
    throw new Error(`${variableName} must not contain duplicate values`);
  }

  return values;
}

export function parseExpectedRevisions(rawValue) {
  return parseUniqueList(rawValue, "EXPECTED_REVISIONS");
}

export function parseProbeFlagKeys(rawValue) {
  return parseUniqueList(rawValue, "PROBE_FLAG_KEYS");
}

export function parseStreamingMessage(rawMessage) {
  let message;
  try {
    message = JSON.parse(rawMessage);
  } catch (error) {
    throw new Error(`message is not valid JSON: ${error.message}`);
  }

  if (!message || typeof message !== "object") {
    throw new Error("message must be a JSON object");
  }

  if (message.messageType === "pong") {
    return { kind: "pong" };
  }

  if (message.messageType !== "data-sync") {
    return { kind: "ignored", messageType: message.messageType };
  }

  const data = message.data;
  if (!data || (data.eventType !== "full" && data.eventType !== "patch")) {
    throw new Error("data-sync message must have eventType 'full' or 'patch'");
  }

  if (!Array.isArray(data.featureFlags) || !Array.isArray(data.segments)) {
    throw new Error("data-sync message must contain featureFlags and segments arrays");
  }

  return {
    kind: "data-sync",
    eventType: data.eventType,
    featureFlags: data.featureFlags,
    segments: data.segments,
  };
}

export function findFeatureFlag(featureFlags, flagKey) {
  return featureFlags.find((flag) => flag && flag.key === flagKey);
}

function requireArray(value, propertyName) {
  if (!Array.isArray(value)) {
    throw new Error(`probe flag '${propertyName}' must be an array`);
  }

  return value;
}

function selectVariationId(flag) {
  if (!flag.isEnabled) {
    if (!flag.disabledVariationId) {
      throw new Error("disabled probe flag has no disabledVariationId");
    }

    return flag.disabledVariationId;
  }

  const targetUsers = requireArray(flag.targetUsers, "targetUsers");
  const rules = requireArray(flag.rules, "rules");
  if (targetUsers.length > 0 || rules.length > 0) {
    throw new Error("probe flag must not have target users or targeting rules");
  }

  const fallthroughVariations = requireArray(flag.fallthrough?.variations, "fallthrough.variations");
  if (fallthroughVariations.length !== 1) {
    throw new Error("probe flag default rule must serve exactly one variation");
  }

  const selected = fallthroughVariations[0];
  if (!selected?.id) {
    throw new Error("probe flag default variation has no id");
  }

  if (
    !Array.isArray(selected.rollout) ||
    selected.rollout.length !== 2 ||
    selected.rollout[0] !== 0 ||
    selected.rollout[1] !== 1
  ) {
    throw new Error("probe flag default variation must have a 0% to 100% rollout");
  }

  return selected.id;
}

// The probe flag is intentionally constrained to a single 100% default variation.
// Under that constraint, this is the same value every .NET Server SDK evaluation returns.
export function extractProbeSnapshot(flag) {
  if (!flag || typeof flag !== "object") {
    throw new Error("probe flag payload is missing");
  }

  if (flag.isArchived) {
    throw new Error("probe flag is archived");
  }

  if (flag.variationType !== "string") {
    throw new Error("probe flag must be a string flag");
  }

  const variations = requireArray(flag.variations, "variations");
  const selectedVariationId = selectVariationId(flag);
  const variation = variations.find((candidate) => candidate?.id === selectedVariationId);
  if (!variation) {
    throw new Error(`selected variation '${selectedVariationId}' was not found`);
  }

  if (typeof variation.value !== "string" || variation.value.length === 0) {
    throw new Error("selected probe variation must have a non-empty string value");
  }

  const updatedAtMs = Date.parse(flag.updatedAt);
  if (!Number.isFinite(updatedAtMs)) {
    throw new Error("probe flag updatedAt is missing or invalid");
  }

  return {
    revision: variation.value,
    updatedAtMs,
    selectedVariationId,
  };
}
