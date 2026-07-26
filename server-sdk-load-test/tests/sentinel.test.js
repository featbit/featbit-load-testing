import assert from "node:assert/strict";
import test from "node:test";

import {
  assignSentinelConnection,
  classifySentinelRevision,
  formatSentinelRecord,
  parseSentinelTargets,
  summarizeSentinelValues,
} from "../k6/lib/sentinel.js";

const targets = [
  { pod: "els-a", ip: "10.0.0.1" },
  { pod: "els-b", ip: "10.0.0.2" },
];

test("parses targets and assigns contiguous VUs to each ELS Pod", () => {
  assert.deepEqual(parseSentinelTargets(JSON.stringify(targets)), targets);
  assert.deepEqual(assignSentinelConnection(1, targets, 3), {
    target: targets[0],
    targetIndex: 0,
    connectionIndex: 1,
  });
  assert.deepEqual(assignSentinelConnection(4, targets, 3), {
    target: targets[1],
    targetIndex: 1,
    connectionIndex: 1,
  });
  assert.throws(() => assignSentinelConnection(7, targets, 3), /exceeds/);
});

test("rejects duplicate target identities", () => {
  assert.throws(
    () =>
      parseSentinelTargets(
        JSON.stringify([
          { pod: "els-a", ip: "10.0.0.1" },
          { pod: "els-a", ip: "10.0.0.2" },
        ]),
      ),
    /duplicate pod/,
  );
});

test("formats machine-readable sentinel records", () => {
  assert.equal(
    formatSentinelRecord("EVENT", ["run-1", "node-a", "els-a", 1]),
    "SENTINEL_EVENT|1|run-1|node-a|els-a|1",
  );
});

test("summarizes a three-connection cell", () => {
  assert.deepEqual(summarizeSentinelValues([90, 110, 100]), {
    count: 3,
    avg: 100,
    min: 90,
    med: 100,
    p95: 109,
    p99: 109.8,
    max: 110,
  });
});

test("classifies ELS columns, loadgen rows, and main-runner-only spikes", () => {
  const makeCell = (loadgenNode, elsPod, med) => ({
    loadgenNode,
    elsPod,
    stats: { med },
  });

  const columnCells = [];
  for (let node = 1; node <= 10; node += 1) {
    for (let pod = 1; pod <= 6; pod += 1) {
      columnCells.push(makeCell(`node-${node}`, `els-${pod}`, pod === 2 ? 130 : 50));
    }
  }
  assert.equal(
    classifySentinelRevision(columnCells, { mainRunnerP99Ms: 180 }).classification,
    "els-column",
  );

  const rowCells = [];
  for (let node = 1; node <= 10; node += 1) {
    for (let pod = 1; pod <= 6; pod += 1) {
      rowCells.push(makeCell(`node-${node}`, `els-${pod}`, node === 3 ? 130 : 50));
    }
  }
  assert.equal(
    classifySentinelRevision(rowCells, { mainRunnerP99Ms: 180 }).classification,
    "loadgen-row",
  );

  const stableCells = columnCells.map((cell) => ({
    ...cell,
    stats: { med: 50 },
  }));
  assert.equal(
    classifySentinelRevision(stableCells, { mainRunnerP99Ms: 180 }).classification,
    "main-runners-only",
  );
});
