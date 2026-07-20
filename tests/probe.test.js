import assert from "node:assert/strict";
import test from "node:test";

import {
  extractProbeSnapshot,
  findFeatureFlag,
  parseExpectedRevisions,
  parseProbeFlagKeys,
  parseStreamingMessage,
} from "../k6/lib/probe.js";

function createProbeFlag(overrides = {}) {
  return {
    key: "loadtest-sync-probe",
    updatedAt: "2026-07-20T12:00:00.123Z",
    variationType: "string",
    variations: [
      { id: "active", value: "rev-001" },
      { id: "inactive", value: "unused" },
    ],
    targetUsers: [],
    rules: [],
    isEnabled: true,
    disabledVariationId: "inactive",
    fallthrough: {
      variations: [{ id: "active", rollout: [0, 1] }],
    },
    ...overrides,
  };
}

test("parses and de-duplicates the expected revision list", () => {
  assert.deepEqual(parseExpectedRevisions("rev-001, rev-002"), ["rev-001", "rev-002"]);
  assert.throws(() => parseExpectedRevisions("rev-001,rev-001"), /duplicate/);
});

test("parses and de-duplicates the probe flag key list", () => {
  assert.deepEqual(parseProbeFlagKeys("loadtest-01, loadtest-02"), [
    "loadtest-01",
    "loadtest-02",
  ]);
  assert.throws(() => parseProbeFlagKeys("loadtest-01,loadtest-01"), /duplicate/);
});

test("parses FeatBit full and pong messages", () => {
  const full = parseStreamingMessage(
    JSON.stringify({
      messageType: "data-sync",
      data: { eventType: "full", featureFlags: [], segments: [] },
    }),
  );

  assert.equal(full.kind, "data-sync");
  assert.equal(full.eventType, "full");
  assert.deepEqual(parseStreamingMessage('{"messageType":"pong","data":{}}'), { kind: "pong" });
});

test("extracts the deterministic evaluation value from the probe flag", () => {
  const flag = createProbeFlag();
  const snapshot = extractProbeSnapshot(flag);

  assert.equal(snapshot.revision, "rev-001");
  assert.equal(snapshot.selectedVariationId, "active");
  assert.equal(snapshot.updatedAtMs, Date.parse(flag.updatedAt));
  assert.equal(findFeatureFlag([flag], flag.key), flag);
});

test("uses the disabled variation when the probe flag is off", () => {
  const snapshot = extractProbeSnapshot(createProbeFlag({ isEnabled: false }));
  assert.equal(snapshot.revision, "unused");
});

test("rejects a probe flag whose evaluation is not deterministic", () => {
  assert.throws(
    () => extractProbeSnapshot(createProbeFlag({ rules: [{ name: "a rule" }] })),
    /must not have target users or targeting rules/,
  );

  assert.throws(
    () =>
      extractProbeSnapshot(
        createProbeFlag({
          fallthrough: {
            variations: [
              { id: "active", rollout: [0, 0.5] },
              { id: "inactive", rollout: [0.5, 1] },
            ],
          },
        }),
      ),
    /exactly one variation/,
  );
});
