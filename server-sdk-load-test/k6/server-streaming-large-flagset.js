// Dedicated customer-visible entry point for the single-environment,
// 3,000-feature-flag experiment. The shared streaming engine keeps the
// historical broadcast-string behavior when REVISION_PLAN_JSON is absent;
// this profile requires the explicit per-flag plan and exact full-sync count.
import {
  controlProbeRevisions,
  default as runStreamingExperiment,
  options,
  setup as setupStreamingExperiment,
  teardown,
} from "./server-streaming.js";

function validateLargeFlagsetProfile() {
  const revisionPlan = String(__ENV.REVISION_PLAN_JSON ?? "").trim();
  const expectedFlagCount = Number(__ENV.EXPECTED_FULL_SYNC_FLAG_COUNT);

  if (!revisionPlan) {
    throw new Error("large-flagset runner requires REVISION_PLAN_JSON");
  }
  if (expectedFlagCount !== 3_000) {
    throw new Error(
      "large-flagset runner requires EXPECTED_FULL_SYNC_FLAG_COUNT=3000",
    );
  }
}

export function setup() {
  validateLargeFlagsetProfile();
  return setupStreamingExperiment();
}

export {
  controlProbeRevisions,
  runStreamingExperiment as default,
  options,
  teardown,
};
