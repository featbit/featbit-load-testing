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
  const rawBytes = utf8ByteLength(rawMessage);
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
    return { kind: "pong", rawBytes };
  }

  if (message.messageType !== "data-sync") {
    return { kind: "ignored", messageType: message.messageType, rawBytes };
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
    rawBytes,
  };
}

export function findFeatureFlag(featureFlags, flagKey) {
  return featureFlags.find((flag) => flag && flag.key === flagKey);
}

export function indexFeatureFlags(featureFlags) {
  const index = new Map();
  for (const flag of featureFlags) {
    if (!flag || typeof flag.key !== "string" || flag.key.length === 0) {
      throw new Error("feature flag payload contains an invalid key");
    }
    if (index.has(flag.key)) {
      throw new Error(`feature flag payload contains duplicate key '${flag.key}'`);
    }
    index.set(flag.key, flag);
  }
  return index;
}

export function utf8ByteLength(value) {
  const text = String(value ?? "");
  let bytes = 0;
  for (let index = 0; index < text.length; index += 1) {
    const code = text.charCodeAt(index);
    if (code < 0x80) {
      bytes += 1;
    } else if (code < 0x800) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff) {
      const next = text.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4;
        index += 1;
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
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

  const variationType = normalizeVariationType(
    flag.variationType,
    "probe flag variationType",
  );

  const variations = requireArray(flag.variations, "variations");
  const selectedVariationId = selectVariationId(flag);
  const variation = variations.find((candidate) => candidate?.id === selectedVariationId);
  if (!variation) {
    throw new Error(`selected variation '${selectedVariationId}' was not found`);
  }

  const revision = extractVariationRevision(variation.value, variationType);

  const updatedAtMs = Date.parse(flag.updatedAt);
  if (!Number.isFinite(updatedAtMs)) {
    throw new Error("probe flag updatedAt is missing or invalid");
  }

  return {
    revision,
    updatedAtMs,
    selectedVariationId,
    variationType,
    variationValueBytes: utf8ByteLength(variation.value),
  };
}
import {
  extractVariationRevision,
  normalizeVariationType,
} from "./api-controller.js";
