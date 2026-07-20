import assert from "node:assert/strict";
import test from "node:test";

import {
  applyProbeSnapshot,
  createProbeState,
  initializeProbeState,
} from "../k6/lib/probe-state.js";

const expectedRevisionIndex = {
  "rev-001": 0,
  "rev-002": 1,
};

function createInitializedState() {
  const state = createProbeState("loadtest-sync-probe-01", 0, 2);
  initializeProbeState(state, { revision: "baseline", updatedAtMs: 1_000 });
  return state;
}

test("applies the expected revisions and tracks their coverage", () => {
  const state = createInitializedState();

  const first = applyProbeSnapshot(
    state,
    { revision: "rev-001", updatedAtMs: 2_000 },
    expectedRevisionIndex,
  );
  const second = applyProbeSnapshot(
    state,
    { revision: "rev-002", updatedAtMs: 3_000 },
    expectedRevisionIndex,
  );

  assert.deepEqual(first, {
    kind: "expected",
    applied: true,
    firstSeen: true,
    revisionIndex: 0,
    sequenceError: false,
  });
  assert.deepEqual(second, {
    kind: "expected",
    applied: true,
    firstSeen: true,
    revisionIndex: 1,
    sequenceError: false,
  });
  assert.deepEqual(state.seenRevisions, [true, true]);
  assert.equal(state.appliedRevision, "rev-002");
  assert.equal(state.appliedUpdatedAtMs, 3_000);
});

test("ignores duplicate and stale patches like the .NET SDK store", () => {
  const state = createInitializedState();
  applyProbeSnapshot(
    state,
    { revision: "rev-001", updatedAtMs: 2_000 },
    expectedRevisionIndex,
  );

  const duplicate = applyProbeSnapshot(
    state,
    { revision: "rev-001", updatedAtMs: 2_000 },
    expectedRevisionIndex,
  );
  const stale = applyProbeSnapshot(
    state,
    { revision: "rev-002", updatedAtMs: 1_500 },
    expectedRevisionIndex,
  );

  assert.equal(duplicate.kind, "duplicate");
  assert.equal(duplicate.applied, false);
  assert.equal(stale.kind, "stale");
  assert.equal(stale.applied, false);
  assert.deepEqual(state.seenRevisions, [true, false]);
  assert.equal(state.appliedRevision, "rev-001");
  assert.equal(state.appliedUpdatedAtMs, 2_000);
});

test("keeps the expected final value after the final patch is replayed", () => {
  const state = createInitializedState();
  applyProbeSnapshot(
    state,
    { revision: "rev-001", updatedAtMs: 2_000 },
    expectedRevisionIndex,
  );
  applyProbeSnapshot(
    state,
    { revision: "rev-002", updatedAtMs: 3_000 },
    expectedRevisionIndex,
  );

  const replay = applyProbeSnapshot(
    state,
    { revision: "rev-002", updatedAtMs: 3_000 },
    expectedRevisionIndex,
  );

  assert.equal(replay.kind, "duplicate");
  assert.equal(replay.applied, false);
  assert.deepEqual(state.seenRevisions, [true, true]);
  assert.equal(state.appliedRevision, "rev-002");
  assert.equal(state.appliedUpdatedAtMs, 3_000);
});

test("allows a newer re-save of the current value without losing final correctness", () => {
  const state = createInitializedState();
  applyProbeSnapshot(
    state,
    { revision: "rev-001", updatedAtMs: 2_000 },
    expectedRevisionIndex,
  );

  const repeated = applyProbeSnapshot(
    state,
    { revision: "rev-001", updatedAtMs: 2_500 },
    expectedRevisionIndex,
  );
  const final = applyProbeSnapshot(
    state,
    { revision: "rev-002", updatedAtMs: 3_000 },
    expectedRevisionIndex,
  );

  assert.equal(repeated.kind, "repeated");
  assert.equal(repeated.applied, true);
  assert.equal(repeated.firstSeen, false);
  assert.equal(repeated.sequenceError, false);
  assert.equal(final.sequenceError, false);
  assert.deepEqual(state.seenRevisions, [true, true]);
  assert.equal(state.appliedRevision, "rev-002");
});

test("detects a newer rollback after the final expected revision", () => {
  const state = createInitializedState();
  applyProbeSnapshot(
    state,
    { revision: "rev-001", updatedAtMs: 2_000 },
    expectedRevisionIndex,
  );
  applyProbeSnapshot(
    state,
    { revision: "rev-002", updatedAtMs: 3_000 },
    expectedRevisionIndex,
  );

  const rollback = applyProbeSnapshot(
    state,
    { revision: "rev-001", updatedAtMs: 4_000 },
    expectedRevisionIndex,
  );

  assert.equal(rollback.kind, "repeated");
  assert.equal(rollback.applied, true);
  assert.equal(rollback.sequenceError, true);
  assert.equal(state.appliedRevision, "rev-001");
  assert.equal(state.appliedUpdatedAtMs, 4_000);
});

test("marks a skipped expected revision as a sequence error", () => {
  const state = createInitializedState();

  const outcome = applyProbeSnapshot(
    state,
    { revision: "rev-002", updatedAtMs: 2_000 },
    expectedRevisionIndex,
  );

  assert.equal(outcome.kind, "expected");
  assert.equal(outcome.firstSeen, true);
  assert.equal(outcome.sequenceError, true);
  assert.deepEqual(state.seenRevisions, [false, true]);
  assert.equal(state.appliedRevision, "rev-002");
});
