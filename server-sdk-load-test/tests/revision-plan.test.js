import assert from "node:assert/strict";
import test from "node:test";

import {
  buildRevisionPlan,
  createBroadcastRevisionPlan,
  parsePerFlagRevisionPlan,
} from "../k6/lib/revision-plan.js";

test("builds the legacy broadcast plan", () => {
  const plan = buildRevisionPlan("", ["flag-a", "flag-b"], ["rev-001", "rev-002"]);

  assert.equal(plan.mode, "broadcast");
  assert.deepEqual(plan.expectedRevisionIndexesByFlag["flag-a"], [0, 1]);
  assert.deepEqual(plan.finalRevisionByFlag, {
    "flag-a": "rev-002",
    "flag-b": "rev-002",
  });
  assert.equal(createBroadcastRevisionPlan(["flag-a"], ["rev-001"]).steps.length, 1);
});

test("parses eight string and two JSON per-flag revisions", () => {
  const raw = JSON.stringify(
    Array.from({ length: 10 }, (_, offset) => ({
      index: offset + 1,
      flagKey: `flag-${String(offset + 1).padStart(4, "0")}`,
      revision: `rev-${String(offset + 1).padStart(3, "0")}`,
      variationType: offset < 8 ? "string" : "json",
    })),
  );
  const plan = buildRevisionPlan(raw, [], []);

  assert.equal(plan.mode, "per-flag");
  assert.equal(plan.steps.length, 10);
  assert.equal(plan.flagKeys.length, 10);
  assert.deepEqual(plan.expectedRevisionIndexesByFlag["flag-0009"], [8]);
  assert.equal(plan.variationTypeByFlag["flag-0009"], "json");
  assert.equal(plan.finalRevisionByFlag["flag-0010"], "rev-010");
});

test("rejects ambiguous per-flag plans", () => {
  assert.throws(
    () =>
      parsePerFlagRevisionPlan(
        JSON.stringify([
          {
            index: 1,
            flagKey: "flag-a",
            revision: "rev-001",
            variationType: "string",
          },
          {
            index: 2,
            flagKey: "flag-a",
            revision: "rev-002",
            variationType: "json",
          },
        ]),
      ),
    /duplicate flagKey/,
  );
});
