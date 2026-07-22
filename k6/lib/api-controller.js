function requireObject(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${name} must be an object`);
  }

  return value;
}

function requireNonEmptyString(value, name) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${name} must be a non-empty string`);
  }

  return value.trim();
}

export function normalizeApiBaseUrl(value) {
  const url = requireNonEmptyString(value, "FEATBIT_API_URL").replace(/\/+$/, "");
  if (!/^https?:\/\//.test(url)) {
    throw new Error("FEATBIT_API_URL must start with http:// or https://");
  }
  if (url.includes("?")) {
    throw new Error("FEATBIT_API_URL must not contain query parameters");
  }

  return url;
}

export function buildFeatureFlagUrl(apiBaseUrl, environmentId, flagKey) {
  const baseUrl = normalizeApiBaseUrl(apiBaseUrl);
  const envId = requireNonEmptyString(environmentId, "FEATBIT_ENVIRONMENT_ID");
  const key = requireNonEmptyString(flagKey, "feature flag key");
  return `${baseUrl}/api/v1/envs/${encodeURIComponent(envId)}/feature-flags/${encodeURIComponent(key)}`;
}

export function validateControllerFlag(flag, expectedKey, requiredValues) {
  requireObject(flag, `feature flag '${expectedKey}'`);
  const key = requireNonEmptyString(flag.key, "feature flag key");
  if (key !== expectedKey) {
    throw new Error(`requested feature flag '${expectedKey}', but API returned '${key}'`);
  }
  if (flag.isArchived) {
    throw new Error(`feature flag '${key}' must not be archived`);
  }
  if (flag.isEnabled !== true) {
    throw new Error(`feature flag '${key}' must be enabled`);
  }
  if (String(flag.variationType).toLowerCase() !== "string") {
    throw new Error(`feature flag '${key}' must use string variations`);
  }
  if (Array.isArray(flag.targetUsers) && flag.targetUsers.length > 0) {
    throw new Error(`feature flag '${key}' must not have target users`);
  }
  if (Array.isArray(flag.rules) && flag.rules.length > 0) {
    throw new Error(`feature flag '${key}' must not have targeting rules`);
  }

  requireNonEmptyString(flag.revision, `feature flag '${key}' revision`);
  if (!Array.isArray(flag.variations) || flag.variations.length === 0) {
    throw new Error(`feature flag '${key}' must contain variations`);
  }

  const variationsByValue = new Map();
  for (const variation of flag.variations) {
    requireObject(variation, `feature flag '${key}' variation`);
    const id = requireNonEmptyString(variation.id, `feature flag '${key}' variation ID`);
    const value = requireNonEmptyString(variation.value, `feature flag '${key}' variation value`);
    if (variationsByValue.has(value)) {
      throw new Error(`feature flag '${key}' has duplicate variation value '${value}'`);
    }
    variationsByValue.set(value, { ...variation, id, value });
  }

  for (const value of requiredValues) {
    if (!variationsByValue.has(value)) {
      throw new Error(`feature flag '${key}' is missing required variation value '${value}'`);
    }
  }

  return variationsByValue;
}

export function getDeterministicServedValue(flag) {
  if (!flag || flag.isEnabled !== true || !Array.isArray(flag.variations)) {
    return null;
  }

  const served = flag.fallthrough?.variations;
  if (!Array.isArray(served) || served.length !== 1) {
    return null;
  }

  const [rollout] = served;
  if (
    !Array.isArray(rollout.rollout) ||
    rollout.rollout.length !== 2 ||
    rollout.rollout[0] !== 0 ||
    rollout.rollout[1] !== 1
  ) {
    return null;
  }

  return flag.variations.find((variation) => variation.id === rollout.id)?.value ?? null;
}

export function buildTargetingUpdate(flag, expectedKey, requiredValues, targetValue, comment) {
  const variationsByValue = validateControllerFlag(flag, expectedKey, requiredValues);
  const selectedVariation = variationsByValue.get(targetValue);
  if (!selectedVariation) {
    throw new Error(`feature flag '${expectedKey}' cannot serve unknown value '${targetValue}'`);
  }

  return {
    comment: String(comment ?? "Automated load-test probe update"),
    revision: flag.revision,
    targeting: {
      targetUsers: [],
      rules: [],
      fallthrough: {
        dispatchKey: flag.fallthrough?.dispatchKey ?? null,
        includedInExpt: flag.fallthrough?.includedInExpt ?? true,
        variations: [
          {
            id: selectedVariation.id,
            rollout: [0, 1],
            exptRollout: 1,
          },
        ],
      },
      exptIncludeAllTargets: flag.exptIncludeAllTargets ?? true,
    },
  };
}
