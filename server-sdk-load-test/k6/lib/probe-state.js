export function createProbeState(key, index, expectedRevisionCount) {
  return {
    key,
    index,
    initialValueValid: false,
    appliedRevision: null,
    appliedUpdatedAtMs: null,
    lastExpectedRevisionIndex: -1,
    seenRevisions: Array(expectedRevisionCount).fill(false),
  };
}

export function initializeProbeState(probeState, snapshot) {
  probeState.appliedRevision = snapshot.revision;
  probeState.appliedUpdatedAtMs = snapshot.updatedAtMs;
}

// Mirrors the .NET SDK store: a patch only changes the applied state when its
// updatedAt version is newer than the version already held by the connection.
export function applyProbeSnapshot(probeState, snapshot, expectedRevisionIndex) {
  const revisionIndex = expectedRevisionIndex[snapshot.revision];
  const previousUpdatedAtMs = probeState.appliedUpdatedAtMs;

  if (previousUpdatedAtMs !== null && snapshot.updatedAtMs <= previousUpdatedAtMs) {
    const exactDuplicate =
      snapshot.updatedAtMs === previousUpdatedAtMs &&
      snapshot.revision === probeState.appliedRevision;

    return {
      kind: exactDuplicate ? "duplicate" : "stale",
      applied: false,
      firstSeen: false,
      revisionIndex,
      sequenceError: false,
    };
  }

  let kind = "expected";
  let firstSeen = false;
  let sequenceError = false;

  if (revisionIndex === undefined) {
    kind = "unexpected";
  } else if (probeState.seenRevisions[revisionIndex]) {
    kind = "repeated";
    // Re-saving the current value is harmless, but applying an older value
    // after a newer expected revision is a real sequence regression.
    sequenceError = revisionIndex < probeState.lastExpectedRevisionIndex;
  } else {
    firstSeen = true;
    sequenceError = revisionIndex !== probeState.lastExpectedRevisionIndex + 1;
    probeState.seenRevisions[revisionIndex] = true;
    probeState.lastExpectedRevisionIndex = Math.max(
      probeState.lastExpectedRevisionIndex,
      revisionIndex,
    );
  }

  probeState.appliedRevision = snapshot.revision;
  probeState.appliedUpdatedAtMs = snapshot.updatedAtMs;

  return {
    kind,
    applied: true,
    firstSeen,
    revisionIndex,
    sequenceError,
  };
}
