import assert from "node:assert/strict";
import test from "node:test";

import { createProbeStateFixture } from "./helpers/probe-fixtures.js";

function assertProbeState(state, expected) {
  assert.deepEqual(
    {
      seenRevisions: state.seenRevisions,
      appliedRevision: state.appliedRevision,
      appliedUpdatedAtMs: state.appliedUpdatedAtMs,
    },
    expected,
  );
}

test("applies the expected revisions and tracks their coverage", () => {
  const { state, applySequence } = createProbeStateFixture();
  const [first, second] = applySequence(
    ["rev-001", 2_000],
    ["rev-002", 3_000],
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
  assertProbeState(state, {
    seenRevisions: [true, true],
    appliedRevision: "rev-002",
    appliedUpdatedAtMs: 3_000,
  });
});

test("ignores duplicate and stale patches like the .NET SDK store", () => {
  const { state, apply } = createProbeStateFixture();
  apply("rev-001", 2_000);

  const duplicate = apply("rev-001", 2_000);
  const stale = apply("rev-002", 1_500);

  assert.equal(duplicate.kind, "duplicate");
  assert.equal(duplicate.applied, false);
  assert.equal(stale.kind, "stale");
  assert.equal(stale.applied, false);
  assertProbeState(state, {
    seenRevisions: [true, false],
    appliedRevision: "rev-001",
    appliedUpdatedAtMs: 2_000,
  });
});

test("keeps the expected final value after the final patch is replayed", () => {
  const { state, apply, applySequence } = createProbeStateFixture();
  applySequence(
    ["rev-001", 2_000],
    ["rev-002", 3_000],
  );

  const replay = apply("rev-002", 3_000);

  assert.equal(replay.kind, "duplicate");
  assert.equal(replay.applied, false);
  assertProbeState(state, {
    seenRevisions: [true, true],
    appliedRevision: "rev-002",
    appliedUpdatedAtMs: 3_000,
  });
});

test("allows a newer re-save of the current value without losing final correctness", () => {
  const { state, apply } = createProbeStateFixture();
  apply("rev-001", 2_000);

  const repeated = apply("rev-001", 2_500);
  const final = apply("rev-002", 3_000);

  assert.equal(repeated.kind, "repeated");
  assert.equal(repeated.applied, true);
  assert.equal(repeated.firstSeen, false);
  assert.equal(repeated.sequenceError, false);
  assert.equal(final.sequenceError, false);
  assertProbeState(state, {
    seenRevisions: [true, true],
    appliedRevision: "rev-002",
    appliedUpdatedAtMs: 3_000,
  });
});

test("detects a newer rollback after the final expected revision", () => {
  const { state, apply, applySequence } = createProbeStateFixture();
  applySequence(
    ["rev-001", 2_000],
    ["rev-002", 3_000],
  );

  const rollback = apply("rev-001", 4_000);

  assert.equal(rollback.kind, "repeated");
  assert.equal(rollback.applied, true);
  assert.equal(rollback.sequenceError, true);
  assertProbeState(state, {
    seenRevisions: [true, true],
    appliedRevision: "rev-001",
    appliedUpdatedAtMs: 4_000,
  });
});

test("marks a skipped expected revision as a sequence error", () => {
  const { state, apply } = createProbeStateFixture();
  const outcome = apply("rev-002", 2_000);

  assert.equal(outcome.kind, "expected");
  assert.equal(outcome.firstSeen, true);
  assert.equal(outcome.sequenceError, true);
  assertProbeState(state, {
    seenRevisions: [false, true],
    appliedRevision: "rev-002",
    appliedUpdatedAtMs: 2_000,
  });
});
