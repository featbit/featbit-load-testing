import {
  applyProbeSnapshot,
  createProbeState,
  initializeProbeState,
} from "../../k6/lib/probe-state.js";

const EXPECTED_REVISIONS = Object.freeze(["rev-001", "rev-002"]);

export function createProbeFlag(overrides = {}) {
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

export function createProbeStateFixture({
  key = "loadtest-sync-probe-01",
  index = 0,
  initialRevision = "baseline",
  initialUpdatedAtMs = 1_000,
  expectedRevisions = EXPECTED_REVISIONS,
} = {}) {
  const expectedRevisionIndex = Object.fromEntries(
    expectedRevisions.map((revision, revisionIndex) => [revision, revisionIndex]),
  );
  const state = createProbeState(key, index, expectedRevisions.length);
  initializeProbeState(state, {
    revision: initialRevision,
    updatedAtMs: initialUpdatedAtMs,
  });

  function apply(revision, updatedAtMs) {
    return applyProbeSnapshot(state, { revision, updatedAtMs }, expectedRevisionIndex);
  }

  return {
    state,
    apply,
    applySequence: (...snapshots) =>
      snapshots.map(([revision, updatedAtMs]) => apply(revision, updatedAtMs)),
  };
}
