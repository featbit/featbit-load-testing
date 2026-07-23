import test from "node:test";
import assert from "node:assert/strict";

import {
  expectedConnectionsPerRunner,
  remainingSetupBarrierMilliseconds,
  runnerIndexFromHostname,
} from "../k6/lib/distribution.js";

test("splits the global connection target evenly across runners", () => {
  assert.equal(expectedConnectionsPerRunner(5000, 2), 2500);
  assert.equal(expectedConnectionsPerRunner(1000, 2), 500);
  assert.equal(expectedConnectionsPerRunner(10, 2), 5);
});

test("rejects a connection target that cannot be segmented evenly", () => {
  assert.throws(
    () => expectedConnectionsPerRunner(10, 3),
    /must be divisible by LOADTEST_PARALLELISM/,
  );
});

test("identifies the controller leader from the pinned operator hostname", () => {
  assert.equal(runnerIndexFromHostname("featbit-growth-abc-1", 2), 1);
  assert.equal(runnerIndexFromHostname("featbit-growth-abc-2", 2), 2);
  assert.equal(runnerIndexFromHostname("any-local-host", 1), 1);
});

test("rejects an unindexed hostname for a distributed run", () => {
  assert.throws(
    () => runnerIndexFromHostname("featbit-growth-initializer", 2),
    /HOSTNAME must end with the k6 Operator runner index/,
  );
});

test("aligns distributed runners to the same setup barrier", () => {
  assert.equal(remainingSetupBarrierMilliseconds(2, 60, 4_500), 55_500);
  assert.equal(remainingSetupBarrierMilliseconds(2, 60, 0), 60_000);
  assert.equal(remainingSetupBarrierMilliseconds(1, 0, 50_000), 0);
});

test("rejects a distributed setup that misses its barrier", () => {
  assert.throws(
    () => remainingSetupBarrierMilliseconds(2, 60, 60_001),
    /distributed setup exceeded its 60s barrier/,
  );
});
