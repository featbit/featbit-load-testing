import assert from "node:assert/strict";
import test from "node:test";

import {
  extractProbeSnapshot,
  findFeatureFlag,
  parseExpectedRevisions,
  parseProbeFlagKeys,
  parseStreamingMessage,
} from "../k6/lib/probe.js";
import { createProbeFlag } from "./helpers/probe-fixtures.js";

const listParserCases = [
  {
    name: "expected revision",
    parse: parseExpectedRevisions,
    input: "rev-001, rev-002",
    expected: ["rev-001", "rev-002"],
    duplicateInput: "rev-001,rev-001",
  },
  {
    name: "probe flag key",
    parse: parseProbeFlagKeys,
    input: "loadtest-01, loadtest-02",
    expected: ["loadtest-01", "loadtest-02"],
    duplicateInput: "loadtest-01,loadtest-01",
  },
];

for (const { name, parse, input, expected, duplicateInput } of listParserCases) {
  test(`parses and de-duplicates the ${name} list`, () => {
    assert.deepEqual(parse(input), expected);
    assert.throws(() => parse(duplicateInput), /duplicate/);
  });
}

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
