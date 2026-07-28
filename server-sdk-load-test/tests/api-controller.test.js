import assert from "node:assert/strict";
import test from "node:test";

import {
  buildFeatureFlagUrl,
  buildTargetingUpdate,
  extractVariationRevision,
  getDeterministicServedRevision,
  getDeterministicServedValue,
  normalizeApiBaseUrl,
  validateControllerFlag,
} from "../k6/lib/api-controller.js";

const requiredValues = ["baseline", "rev-001", "rev-002"];

function createFlag(overrides = {}) {
  return {
    key: "loadtest-sync-probe-01",
    revision: "11111111-1111-1111-1111-111111111111",
    variationType: "string",
    isEnabled: true,
    isArchived: false,
    variations: [
      { id: "baseline-id", name: "Baseline", value: "baseline" },
      { id: "revision-1-id", name: "Revision 1", value: "rev-001" },
      { id: "revision-2-id", name: "Revision 2", value: "rev-002" },
    ],
    targetUsers: [],
    rules: [],
    fallthrough: {
      dispatchKey: null,
      includedInExpt: true,
      variations: [{ id: "baseline-id", rollout: [0, 1], exptRollout: 1 }],
    },
    exptIncludeAllTargets: true,
    ...overrides,
  };
}

test("normalizes the API URL and builds an escaped feature flag URL", () => {
  assert.equal(normalizeApiBaseUrl("http://featbit-api:5000/"), "http://featbit-api:5000");
  assert.equal(
    buildFeatureFlagUrl("http://featbit-api:5000/", "env-id", "flag/key"),
    "http://featbit-api:5000/api/v1/envs/env-id/feature-flags/flag%2Fkey",
  );
  assert.throws(() => normalizeApiBaseUrl("ws://featbit-api"), /http:\/\/ or https:\/\//);
});

test("validates the controller contract and selects the deterministic value", () => {
  const flag = createFlag();
  const values = validateControllerFlag(flag, flag.key, requiredValues);

  assert.equal(values.get("rev-001").id, "revision-1-id");
  assert.equal(getDeterministicServedValue(flag), "baseline");
  assert.equal(getDeterministicServedRevision(flag), "baseline");
});

test("selects JSON configuration variations by revision token", () => {
  const baseline = JSON.stringify({
    _loadTestRevision: "baseline",
    settings: { timeoutMs: 1000 },
    padding: "x".repeat(128),
  });
  const revision = JSON.stringify({
    _loadTestRevision: "rev-009",
    settings: { timeoutMs: 2500 },
    padding: "y".repeat(128),
  });
  const flag = createFlag({
    variationType: "json",
    variations: [
      { id: "baseline-id", name: "Baseline", value: baseline },
      { id: "revision-9-id", name: "Revision 9", value: revision },
    ],
  });

  const values = validateControllerFlag(
    flag,
    flag.key,
    ["baseline", "rev-009"],
    "json",
  );
  assert.equal(values.get("rev-009").value, revision);
  assert.equal(getDeterministicServedRevision(flag), "baseline");
  assert.equal(extractVariationRevision(revision, "json"), "rev-009");

  const payload = buildTargetingUpdate(
    flag,
    flag.key,
    ["baseline", "rev-009"],
    "rev-009",
    "json load test",
    "json",
  );
  assert.equal(payload.targeting.fallthrough.variations[0].id, "revision-9-id");
});

test("rejects JSON configurations without a load-test revision token", () => {
  assert.throws(
    () => extractVariationRevision('{"settings":{}}', "json"),
    /_loadTestRevision/,
  );
});

test("builds a revision-protected 100 percent default-rule update", () => {
  const flag = createFlag();
  const payload = buildTargetingUpdate(
    flag,
    flag.key,
    requiredValues,
    "rev-002",
    "load test",
  );

  assert.equal(payload.revision, flag.revision);
  assert.equal(payload.comment, "load test");
  assert.deepEqual(payload.targeting.targetUsers, []);
  assert.deepEqual(payload.targeting.rules, []);
  assert.deepEqual(payload.targeting.fallthrough.variations, [
    { id: "revision-2-id", rollout: [0, 1], exptRollout: 1 },
  ]);
});

test("rejects flags that would make the probe nondeterministic", () => {
  assert.throws(
    () => validateControllerFlag(createFlag({ rules: [{ id: "rule" }] }), "loadtest-sync-probe-01", requiredValues),
    /must not have targeting rules/,
  );
  assert.throws(
    () => validateControllerFlag(createFlag({ isEnabled: false }), "loadtest-sync-probe-01", requiredValues),
    /must be enabled/,
  );
  assert.throws(
    () => validateControllerFlag(createFlag({ variations: [] }), "loadtest-sync-probe-01", requiredValues),
    /must contain variations/,
  );
});
