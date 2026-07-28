#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

import {
  analyzeElsCgroupSnapshots,
  analyzeFormalPropagation,
  summarizeInitialization,
  summarizePublicHealth,
  summarizeRunnerRuntime,
  validateReadyEvents,
  validateWarmupCoverage,
} from "../../dotnet-sdk-runner/analysis/dotnet-sdk-pilot-analysis.js";

function fail(message) {
  throw new Error(message);
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) fail(`Missing required file: ${filePath}`);
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function readJsonLines(filePath) {
  if (!fs.existsSync(filePath)) fail(`Missing required file: ${filePath}`);
  return fs
    .readFileSync(filePath, "utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0)
    .map((line, index) => {
      try {
        return JSON.parse(line);
      } catch (error) {
        fail(`${filePath}:${index + 1} is invalid JSON: ${error.message}`);
      }
    });
}

function writeExclusive(filePath, content) {
  fs.writeFileSync(filePath, content, { encoding: "utf8", flag: "wx" });
}

function parseArguments(argv) {
  const result = {};
  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) fail(`Unexpected argument '${token}'`);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) fail(`Argument '${token}' needs a value`);
    result[token.slice(2)] = value;
    index += 1;
  }
  if (!result["run-dir"]) fail("--run-dir is required");
  return result;
}

function formatNumber(value, digits = 2) {
  return Number(value).toFixed(digits);
}

function formatBytes(value) {
  if (!Number.isFinite(Number(value))) return "n/a";
  return `${formatNumber(Number(value) / 1024 / 1024, 1)} MiB`;
}

function statsRow(label, stats) {
  return `| ${label} | ${stats.count} | ${formatNumber(stats.avg)} | ` +
    `${formatNumber(stats.p50)} | ${formatNumber(stats.p90)} | ` +
    `${formatNumber(stats.p95)} | ${formatNumber(stats.p99)} | ` +
    `${formatNumber(stats.max)} |`;
}

function gate(name, passed, evidence) {
  return { name, passed: Boolean(passed), evidence };
}

function main() {
  const args = parseArguments(process.argv);
  const runDirectory = path.resolve(args["run-dir"]);
  if (!fs.statSync(runDirectory).isDirectory()) {
    fail(`Run directory does not exist: ${runDirectory}`);
  }
  const directoryName = path.basename(runDirectory);
  const metadataPath = path.join(runDirectory, `${directoryName}-metadata.json`);
  const metadata = readJson(metadataPath);
  const runId = metadata.runId;
  if (runId !== directoryName) {
    fail(`Run directory '${directoryName}' does not match metadata runId '${runId}'`);
  }
  const supportedMatrixIds = new Set([
    "aks-single-environment-3k-flags-dotnet-sdk-p500",
    "aks-single-environment-3k-flags-dotnet-sdk-p500-els-expanded",
  ]);
  if (
    !supportedMatrixIds.has(metadata.matrixId) ||
    metadata.runnerKind !== "official-dotnet-server-sdk"
  ) {
    fail("Metadata is not for the official .NET SDK 500-connection pilot");
  }

  const eventFiles = fs
    .readdirSync(runDirectory)
    .filter((name) => new RegExp(`^${runId}-dotnet-runner-\\d{2}-events\\.jsonl$`).test(name))
    .sort();
  const summaryFiles = fs
    .readdirSync(runDirectory)
    .filter((name) => new RegExp(`^${runId}-dotnet-runner-\\d{2}-summary\\.json$`).test(name))
    .sort();
  const events = eventFiles.flatMap((name) =>
    readJsonLines(path.join(runDirectory, name)),
  );
  for (const event of events) {
    if (event.runId !== runId) fail("Runner event contains a foreign run ID");
    if (!Number.isInteger(Number(event.runner))) {
      fail("Runner event contains an invalid runner index");
    }
  }
  const summaries = summaryFiles.map((name) => readJson(path.join(runDirectory, name)));
  if (new Set(summaries.map((summary) => summary.runner)).size !== summaries.length) {
    fail("Runner summaries contain duplicate runner indices");
  }

  const controllerRecords = readJsonLines(
    path.join(runDirectory, `${runId}-external-controller-events.jsonl`),
  );
  const observerRecords = readJsonLines(
    path.join(runDirectory, `${runId}-stream-timing-events.jsonl`),
  );
  const job = readJson(path.join(runDirectory, `${runId}-job-cluster.json`));
  const resourceSummaryPath = path.join(
    runDirectory,
    `${runId}-resource-summary.json`,
  );
  const resourceSummary = fs.existsSync(resourceSummaryPath)
    ? readJson(resourceSummaryPath)
    : null;
  const elsCgroupPre = readJson(
    path.join(runDirectory, `${runId}-els-cgroup-pre.json`),
  );
  const elsCgroupPost = readJson(
    path.join(runDirectory, `${runId}-els-cgroup-post.json`),
  );
  const elsCgroup = analyzeElsCgroupSnapshots(elsCgroupPre, elsCgroupPost);
  const nodeEvidenceFiles = fs
    .readdirSync(runDirectory)
    .filter((name) => new RegExp(`^${runId}-node-.*-1s\\.tsv$`).test(name));

  const topology = {
    parallelism: Number(metadata.parameters.Parallelism),
    clientsPerRunner: Number(metadata.parameters.ClientsPerRunner),
    totalConnections: Number(metadata.parameters.TotalConnections),
    connectionsPerSecond: Number(metadata.parameters.ConnectionsPerSecond),
    startAtUnixMs: Number(metadata.startAtUnixMs),
    environmentId: metadata.targetEnvironmentId,
  };
  const readyEvents = events.filter((event) => event.event === "sdk_ready");
  const readyValidation = validateReadyEvents(readyEvents, topology);
  const initialization = summarizeInitialization(readyEvents, {
    startAtUnixMs: topology.startAtUnixMs,
    configuredRampDurationMs: Number(metadata.parameters.RampDurationSeconds) * 1000,
    totalConnections: topology.totalConnections,
    connectionsPerSecond: topology.connectionsPerSecond,
  });
  const health = summarizePublicHealth(events, topology.parallelism);
  const runtime = summarizeRunnerRuntime(
    events.filter((event) => event.event === "runtime_sample"),
  );
  const warmup = validateWarmupCoverage({
    observations: events,
    controllerRecords,
    environmentId: topology.environmentId,
    flagKey: metadata.postRampWarmupFlagKey,
    expectedConnections: topology.totalConnections,
    parallelism: topology.parallelism,
    clientsPerRunner: topology.clientsPerRunner,
  });
  const observerNodes = [
    ...new Set(observerRecords.map((record) => String(record.node))),
  ].sort();
  const crossNodeClockToleranceMs = Number(
    metadata.measurementContract.crossNodeClockToleranceMs ?? 10,
  );
  const propagation = analyzeFormalPropagation({
    observations: events,
    controllerRecords,
    observerRecords,
    plan: metadata.revisionPlan,
    environmentId: topology.environmentId,
    expectedConnections: topology.totalConnections,
    parallelism: topology.parallelism,
    clientsPerRunner: topology.clientsPerRunner,
    expectedObserverNodes: observerNodes,
    crossNodeClockToleranceMs,
  });

  const controllerErrors = controllerRecords.filter(
    (record) => record.event === "request_error",
  );
  const formalStarts = controllerRecords.filter(
    (record) => record.event === "request_start" && Number(record.revisionIndex) > 0,
  );
  const formalEnds = controllerRecords.filter(
    (record) => record.event === "request_end" && Number(record.revisionIndex) > 0,
  );
  const gates = [
    gate(
      "20 runner artifacts",
      eventFiles.length === 20 && summaryFiles.length === 20,
      { eventFiles: eventFiles.length, summaryFiles: summaryFiles.length },
    ),
    gate("500/500 official SDK initialized", readyEvents.length === 500, readyValidation),
    gate("public SDK health", health.passed, health),
    gate(
      "warm-up 500/500 twice",
      warmup.connectionCoverage === 500 && warmup.deliveryCount === 1000,
      warmup,
    ),
    gate(
      "ten successful controller writes",
      formalStarts.length === 10 &&
        formalEnds.length === 10 &&
        controllerErrors.length === 0,
      {
        requestStarts: formalStarts.length,
        requestEnds: formalEnds.length,
        requestErrors: controllerErrors.length,
      },
    ),
    gate(
      "Redis observer evidence",
      observerNodes.length === 10 &&
        propagation.revisions.every((revision) => revision.observerEventCount === 10),
      {
        observerNodes,
        perRevision: propagation.revisions.map((revision) => ({
          revisionIndex: revision.revisionIndex,
          eventCount: revision.observerEventCount,
        })),
      },
    ),
    gate(
      "formal revision delivery 5,000/5,000",
      propagation.sampleCount === 5_000,
      {
        actual: propagation.sampleCount,
        expected: propagation.expectedSampleCount,
      },
    ),
    gate(
      "cross-node clock uncertainty",
      propagation.crossNodeClockUncertainty.minimumProbeSyncLatencyMs >=
        -crossNodeClockToleranceMs,
      propagation.crossNodeClockUncertainty,
    ),
    gate(
      "revision sequence and final correctness",
      propagation.revisionSequenceErrors === 0 &&
        propagation.finalRevisionCorrectConnections === 500,
      {
        sequenceErrors: propagation.revisionSequenceErrors,
        finalRevisionCorrectConnections:
          propagation.finalRevisionCorrectConnections,
      },
    ),
    gate(
      "runner Job completed",
      Number(job.status?.succeeded) === 20 &&
        Number(job.status?.failed ?? 0) === 0,
      {
        succeeded: Number(job.status?.succeeded ?? 0),
        failed: Number(job.status?.failed ?? 0),
      },
    ),
    gate(
      "resource evidence",
      resourceSummary !== null && nodeEvidenceFiles.length === 13,
      {
        kubernetesResourceSummary: resourceSummary !== null,
        oneSecondNodeFiles: nodeEvidenceFiles.length,
      },
    ),
    gate(
      "exact ELS cgroup throttling evidence",
      elsCgroup.exactWindowDelta &&
        elsCgroup.podIdentityStable &&
        elsCgroup.restartCount === 0,
      elsCgroup,
    ),
  ];
  const passed = gates.every((entry) => entry.passed);

  const result = {
    schemaVersion: 1,
    runId,
    generatedAtUtc: new Date().toISOString(),
    status: passed ? "passed" : "failed",
    scope: {
      qualification: "500-connection official .NET SDK pilot",
      formalTenThousandConnectionBaseline: false,
      environmentCount: 1,
      featureFlagCount: 3000,
      stringFlagCount: 2500,
      jsonFlagCount: 500,
      jsonVariationBytes: Number(metadata.parameters.JsonVariationBytes),
      totalConnections: 500,
      rampConnectionsPerSecond: 20,
      configuredRampSeconds: 25,
      runnerPods: 20,
      sdkClientsPerRunner: 25,
      sdkPackage: metadata.sdkPackage,
      sdkPackageVersion: metadata.sdkPackageVersion,
    },
    measurement: {
      initializationBoundary:
        "FbClient construction start to first public Initialized=true observation",
      connectionOpenBoundary:
        "Not separately observable through the public .NET SDK API",
      propagationBoundary:
        "Controller/Redis timestamps to first public StringVariation observation",
      observationPollIntervalMs:
        Number(metadata.measurementContract.sdkObservationPollIntervalMs),
      observationQuantization:
        "SDK observation can be 0-10 ms later than the internal apply time",
      crossNodeClockUncertainty:
        "Raw probe-sync samples are retained; low negative values within the " +
        `${crossNodeClockToleranceMs} ms distributed-clock tolerance are ` +
        "reported, never clipped",
    },
    gates,
    initialization,
    warmup,
    propagation,
    publicHealth: health,
    runtime,
    kubernetesResources: resourceSummary,
    elsCgroup,
    evidence: {
      eventFiles,
      summaryFiles,
      observerNodes,
      nodeEvidenceFiles: nodeEvidenceFiles.sort(),
    },
  };

  const outputSuffix = args["output-suffix"]
    ? `-${args["output-suffix"]}`
    : "";
  if (outputSuffix && !/^-[a-z0-9][a-z0-9-]*$/.test(outputSuffix)) {
    fail("--output-suffix must contain only lowercase letters, digits, and dashes");
  }
  const reportJsonPath = path.join(
    runDirectory,
    `${runId}-dotnet-pilot-analysis${outputSuffix}.json`,
  );
  const reportMarkdownPath = path.join(
    runDirectory,
    `${runId}-dotnet-pilot-analysis${outputSuffix}.md`,
  );
  writeExclusive(reportJsonPath, `${JSON.stringify(result, null, 2)}\n`);

  const revisionRows = propagation.revisions
    .map(
      (revision) =>
        `| ${String(revision.revisionIndex).padStart(2, "0")} | ` +
        `${revision.variationType} | ${revision.flagKey} | ` +
        `${revision.probe_sync_latency_ms.count} | ` +
        `${formatNumber(revision.control_plane_write_latency_ms)} | ` +
        `${formatNumber(revision.probe_sync_latency_ms.avg)} | ` +
        `${formatNumber(revision.probe_sync_latency_ms.p50)} | ` +
        `${formatNumber(revision.probe_sync_latency_ms.p90)} | ` +
        `${formatNumber(revision.probe_sync_latency_ms.p95)} | ` +
        `${formatNumber(revision.probe_sync_latency_ms.p99)} | ` +
        `${formatNumber(revision.probe_sync_latency_ms.max)} |`,
    )
    .join("\n");
  const gateRows = gates
    .map((entry) => `| ${entry.name} | ${entry.passed ? "PASS" : "FAIL"} |`)
    .join("\n");
  const markdown = `# Official .NET SDK 500-connection / 3,000-flag pilot

Run: \`${runId}\`  
Status: **${passed ? "PASS" : "FAIL"}**

This is a 500-connection pilot, not a replacement for the 10,000-connection
capacity result. Twenty runner Pods each hosted 25 independent official
\`FbClient\` instances. The global start rate was 20 clients/s for 25 seconds.

## Ramp and initial synchronization

- Ready at the configured 25-second ramp end: **${initialization.actual.readyAtRampEnd}/500**
- Backlog at ramp end: **${initialization.actual.readyBacklogAtRampEnd}**
- Last SDK ready offset: **${formatNumber(initialization.actual.readyCompletionOffsetMs)} ms**
- Delay after configured ramp end: **${formatNumber(initialization.actual.readyCompletionDelayVsRampEndMs)} ms**
- Public initialization latency p50/p95/p99/max:
  **${formatNumber(initialization.metrics.sdk_initialization_latency_ms.p50)} /
  ${formatNumber(initialization.metrics.sdk_initialization_latency_ms.p95)} /
  ${formatNumber(initialization.metrics.sdk_initialization_latency_ms.p99)} /
  ${formatNumber(initialization.metrics.sdk_initialization_latency_ms.max)} ms**

\`Initialized=true\` is the official public readiness boundary. The public SDK
does not expose a separate WebSocket-open callback, so this report does not
invent a connection-open latency.

## Propagation

| rev | type | flag | count | control plane ms | avg | p50 | p90 | p95 | p99 | max |
| ---: | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
${revisionRows}

Combined 5,000 target observations:

| metric | count | avg | p50 | p90 | p95 | p99 | max |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
${statsRow("end_to_end_latency_ms", propagation.combined.end_to_end_latency_ms)}
${statsRow("probe_sync_latency_ms", propagation.combined.probe_sync_latency_ms)}
${statsRow(
    "control_plane_write_latency_ms (10 writes)",
    propagation.combined.control_plane_write_latency_ms,
  )}

Auxiliary de-jittered view, retaining only samples with
\`probe_sync_latency_ms <= 100 ms\`: **${
    propagation.combined.deJitterDiagnostic.retainedCount
  }/${propagation.combined.deJitterDiagnostic.originalCount} retained; ${
    propagation.combined.deJitterDiagnostic.removedCount
  } (${formatNumber(
    propagation.combined.deJitterDiagnostic.removedPercent,
    3,
  )}%) removed**.

| diagnostic metric | count | avg | p50 | p90 | p95 | p99 | max |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
${statsRow(
    "end_to_end_latency_ms",
    propagation.combined.deJitterDiagnostic.end_to_end_latency_ms,
  )}
${statsRow(
    "probe_sync_latency_ms",
    propagation.combined.deJitterDiagnostic.probe_sync_latency_ms,
  )}

This filtered view is a secondary scheduling/jitter diagnostic. The complete
5,000-sample distribution above remains the primary result and the filter is
not an SLO or PASS gate.

The SDK value was polled through the public \`StringVariation\` API every 10 ms.
Therefore the SDK-side timestamp includes a bounded 0–10 ms late-observation
error. It is not an SDK-internal patch callback timestamp. Canonical
\`probe_sync_latency_ms\` retains raw values: **${
    propagation.crossNodeClockUncertainty.negativeProbeSyncSampleCount
  }** samples were below zero, with a minimum of **${formatNumber(
    propagation.crossNodeClockUncertainty.minimumProbeSyncLatencyMs,
  )} ms**. Values were not clipped; the accepted cross-node clock/observer
uncertainty is ${formatNumber(crossNodeClockToleranceMs)} ms.

## Runtime

- Runner runtime samples: **${runtime.sampleCount}**
- Peak CPU of one runner process: **${
    runtime.aggregatePeaks
      ? formatNumber(runtime.aggregatePeaks.maxSingleRunnerCpuCores, 3)
      : "n/a"
  } cores**
- Peak working set of one runner process: **${
    runtime.aggregatePeaks
      ? formatBytes(runtime.aggregatePeaks.maxSingleRunnerWorkingSetBytes)
      : "n/a"
  }**
- Peak process threads in one runner: **${
    runtime.aggregatePeaks?.maxSingleRunnerThreads ?? "n/a"
  }**
- ELS cgroup window: **${elsCgroup.podCount}/3 stable Pods, ${
    elsCgroup.totals.throttledPeriods
  } throttled periods, ${formatNumber(
    elsCgroup.totals.throttledMilliseconds,
    3,
  )} ms throttled time**

## Gates

| gate | result |
| :--- | :---: |
${gateRows}

Lower-level k6 protocol counters are not reused here because these are real
.NET SDK clients. The equivalent public evidence is initialization, status
transitions, evaluation correctness, SDK diagnostics, Job completion, and
cluster/node telemetry.
`;
  writeExclusive(reportMarkdownPath, markdown);
  process.stdout.write(
    `${JSON.stringify({
      runId,
      status: result.status,
      reportJsonPath,
      reportMarkdownPath,
    })}\n`,
  );
  if (!passed) process.exitCode = 2;
}

try {
  main();
} catch (error) {
  process.stderr.write(`Analysis failed: ${error.message}\n`);
  process.exitCode = 1;
}
