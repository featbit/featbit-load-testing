import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const analyzer = path.resolve(
  testDirectory,
  "../k8s-infra/scripts/analyze-aks-sentinel-matrix.mjs",
);

test("analyzer joins formal events to the Redis boundary and detects an ELS column", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "featbit-sentinel-analysis-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const runId = "growth-sentinel-fixture";
  const runDirectory = path.join(root, runId);
  fs.mkdirSync(runDirectory);
  const updatedAt = "2026-07-26T00:00:00.000Z";
  const updatedAtUnixMs = Date.parse(updatedAt);
  const redisObservedAt = updatedAtUnixMs + 20;

  fs.writeFileSync(
    path.join(runDirectory, `${runId}-stage-latency.json`),
    `${JSON.stringify({
      topology: { connections: 10_000 },
      revisions: [
        {
          revisionIndex: 1,
          revision: "rev-001",
          updatedAt,
          redisFirstObservedAtUnixMs: redisObservedAt,
          streaming: { p99: { max: 180 } },
        },
      ],
    })}\n`,
  );

  const targets = Array.from({ length: 6 }, (_, index) => ({
    pod: `els-${index + 1}`,
    ip: `10.0.0.${index + 1}`,
    node: `featbit-${index + 1}`,
    uid: `uid-${index + 1}`,
  }));
  fs.writeFileSync(
    path.join(runDirectory, `${runId}-sentinel-targets.json`),
    `${JSON.stringify(targets)}\n`,
  );

  const ready = [];
  const events = [];
  const timingEvents = [];
  for (let node = 1; node <= 10; node += 1) {
    timingEvents.push({
      runId,
      pod: `observer-${node}`,
      node: `loadgen-${node}`,
      observedAtUnixMs: redisObservedAt + node,
      channel: "featbit-feature-flag-change",
      payload: {
        key: "loadtest-sync-probe-01",
        updatedAt,
      },
    });
    for (let target = 1; target <= 6; target += 1) {
      for (let connection = 1; connection <= 3; connection += 1) {
        const base = {
          runId,
          sentinelPod: `sentinel-${node}`,
          loadgenNode: `loadgen-${node}`,
          elsPod: `els-${target}`,
          elsIp: `10.0.0.${target}`,
          connectionIndex: connection,
        };
        ready.push({ ...base, readyAtUnixMs: redisObservedAt - 1_000 });
        events.push({
          ...base,
          revisionIndex: 1,
          revision: "rev-001",
          receivedAtUnixMs: redisObservedAt + (target === 2 ? 130 : 50),
          updatedAtUnixMs,
        });
      }
    }
  }

  fs.writeFileSync(
    path.join(runDirectory, `${runId}-sentinel-ready.jsonl`),
    `${ready.map((record) => JSON.stringify(record)).join("\n")}\n`,
  );
  fs.writeFileSync(
    path.join(runDirectory, `${runId}-sentinel-events.jsonl`),
    `${events.map((record) => JSON.stringify(record)).join("\n")}\n`,
  );
  fs.writeFileSync(
    path.join(runDirectory, `${runId}-stream-timing-events.jsonl`),
    `${timingEvents.map((record) => JSON.stringify(record)).join("\n")}\n`,
  );

  const result = spawnSync(
    process.execPath,
    [
      analyzer,
      "--run-id",
      runId,
      "--results-directory",
      root,
    ],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr);

  const report = JSON.parse(
    fs.readFileSync(
      path.join(runDirectory, `${runId}-sentinel-analysis.json`),
      "utf8",
    ),
  );
  assert.equal(report.validation.complete, true);
  assert.equal(report.validation.formalEvents, 180);
  assert.equal(report.validation.matchedNodeLocalObserverEvents, 10);
  assert.equal(report.revisions[0].classification.classification, "els-column");
  assert.deepEqual(report.revisions[0].classification.columnWaves, [
    { elsPod: "els-2", affectedNodes: 10 },
  ]);
  assert.equal(
    report.revisions[0].nodeLocal.classification.classification,
    "els-column",
  );
});
