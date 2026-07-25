import test from "node:test";
import assert from "node:assert/strict";

import {
  postRampWarmupDurationSeconds,
  validatePostRampWarmupFlagKey,
} from "../k6/lib/controller-plan.js";

test("accepts an unmeasured flag for post-ramp warm-up", () => {
  assert.equal(
    validatePostRampWarmupFlagKey("loadtest-sync-probe-02", [
      "loadtest-sync-probe-01",
    ]),
    "loadtest-sync-probe-02",
  );
});

test("allows post-ramp warm-up to be disabled", () => {
  assert.equal(validatePostRampWarmupFlagKey("", ["loadtest-sync-probe-01"]), "");
});

test("rejects measuring the post-ramp warm-up flag", () => {
  assert.throws(
    () =>
      validatePostRampWarmupFlagKey("loadtest-sync-probe-01", [
        "loadtest-sync-probe-01",
      ]),
    /must not also appear in PROBE_FLAG_KEYS/,
  );
});

test("accounts for both post-ramp warm-up mutations", () => {
  assert.equal(postRampWarmupDurationSeconds("loadtest-sync-probe-02", 2), 4);
  assert.equal(postRampWarmupDurationSeconds("", 2), 0);
});
