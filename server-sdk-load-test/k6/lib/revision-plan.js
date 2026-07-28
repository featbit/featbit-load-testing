function requireNonEmptyString(value, name) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${name} must be a non-empty string`);
  }
  return value.trim();
}

function normalizeVariationType(value, name) {
  const normalized = requireNonEmptyString(value, name).toLowerCase();
  if (normalized !== "string" && normalized !== "json") {
    throw new Error(`${name} must be 'string' or 'json'`);
  }
  return normalized;
}

export function createBroadcastRevisionPlan(flagKeys, revisions) {
  if (!Array.isArray(flagKeys) || flagKeys.length === 0) {
    throw new Error("flagKeys must be a non-empty array");
  }
  if (!Array.isArray(revisions) || revisions.length === 0) {
    throw new Error("revisions must be a non-empty array");
  }
  return {
    mode: "broadcast",
    steps: revisions.map((revision, offset) => ({
      index: offset + 1,
      revision: requireNonEmptyString(revision, `revision ${offset + 1}`),
      flagKeys: flagKeys.map((key, keyOffset) =>
        requireNonEmptyString(key, `flag key ${keyOffset + 1}`),
      ),
      variationTypes: Object.fromEntries(flagKeys.map((key) => [key, "string"])),
    })),
  };
}

export function parsePerFlagRevisionPlan(rawValue) {
  let document;
  try {
    document = JSON.parse(String(rawValue ?? ""));
  } catch (error) {
    throw new Error(`REVISION_PLAN_JSON is not valid JSON: ${error.message}`);
  }
  if (!Array.isArray(document) || document.length === 0) {
    throw new Error("REVISION_PLAN_JSON must be a non-empty array");
  }

  const flagKeys = new Set();
  const revisions = new Set();
  const steps = document.map((candidate, offset) => {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
      throw new Error(`revision plan step ${offset + 1} must be an object`);
    }
    const index = Number(candidate.index);
    if (!Number.isSafeInteger(index) || index !== offset + 1) {
      throw new Error(
        `revision plan indexes must be contiguous from 1; expected ${offset + 1}`,
      );
    }
    const flagKey = requireNonEmptyString(
      candidate.flagKey,
      `revision plan step ${index} flagKey`,
    );
    const revision = requireNonEmptyString(
      candidate.revision,
      `revision plan step ${index} revision`,
    );
    const variationType = normalizeVariationType(
      candidate.variationType,
      `revision plan step ${index} variationType`,
    );
    if (flagKeys.has(flagKey)) {
      throw new Error(`revision plan contains duplicate flagKey '${flagKey}'`);
    }
    if (revisions.has(revision)) {
      throw new Error(`revision plan contains duplicate revision '${revision}'`);
    }
    flagKeys.add(flagKey);
    revisions.add(revision);
    return {
      index,
      revision,
      flagKeys: [flagKey],
      variationTypes: { [flagKey]: variationType },
    };
  });

  return { mode: "per-flag", steps };
}

export function buildRevisionPlan(rawValue, fallbackFlagKeys, fallbackRevisions) {
  const raw = String(rawValue ?? "").trim();
  const plan = raw
    ? parsePerFlagRevisionPlan(raw)
    : createBroadcastRevisionPlan(fallbackFlagKeys, fallbackRevisions);

  const flagKeys = [];
  const expectedRevisionIndexesByFlag = {};
  const expectedRevisionsByFlag = {};
  const variationTypeByFlag = {};
  const finalRevisionByFlag = {};
  for (const step of plan.steps) {
    for (const flagKey of step.flagKeys) {
      if (!flagKeys.includes(flagKey)) {
        flagKeys.push(flagKey);
      }
      expectedRevisionIndexesByFlag[flagKey] ??= [];
      expectedRevisionsByFlag[flagKey] ??= [];
      expectedRevisionIndexesByFlag[flagKey].push(step.index - 1);
      expectedRevisionsByFlag[flagKey].push(step.revision);
      variationTypeByFlag[flagKey] = step.variationTypes[flagKey];
      finalRevisionByFlag[flagKey] = step.revision;
    }
  }

  return {
    ...plan,
    flagKeys,
    revisions: plan.steps.map((step) => step.revision),
    expectedRevisionIndexesByFlag,
    expectedRevisionsByFlag,
    variationTypeByFlag,
    finalRevisionByFlag,
  };
}
