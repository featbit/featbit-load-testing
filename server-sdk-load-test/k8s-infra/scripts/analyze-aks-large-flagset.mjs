import fs from "node:fs";
import path from "node:path";
import process from "node:process";

import {
  connectionIdentity,
  percentileStats,
  validateReadyDistribution,
  validateTargetDeliveryDistribution,
} from "../../k6/lib/multi-environment-analysis.js";
import {
  summarizeInitialSyncRamp,
  validateInitialSyncEvents,
} from "../../k6/lib/large-flagset-analysis.js";

function fail(message) {
  throw new Error(message);
}

function parseArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name?.startsWith("--") || value === undefined) {
      fail(`Invalid argument list near '${name ?? "<end>"}'.`);
    }
    values[name.slice(2)] = value;
  }
  if (!values["run-id"] || !values["results-directory"]) {
    fail("--run-id and --results-directory are required.");
  }
  return {
    runId: values["run-id"],
    resultsDirectory: path.resolve(values["results-directory"]),
  };
}

function locateRunDirectory(resultsDirectory, runId) {
  const archive = path.join(resultsDirectory, runId);
  return fs.existsSync(archive) && fs.statSync(archive).isDirectory()
    ? archive
    : resultsDirectory;
}

function requireFile(directory, fileName) {
  const filePath = path.join(directory, fileName);
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    fail(`Required evidence file does not exist: ${filePath}`);
  }
  return filePath;
}

function optionalFile(directory, fileName) {
  const filePath = path.join(directory, fileName);
  return fs.existsSync(filePath) && fs.statSync(filePath).isFile()
    ? filePath
    : null;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function readJsonLines(filePath) {
  return fs
    .readFileSync(filePath, "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line, index) => {
      try {
        return JSON.parse(line);
      } catch (error) {
        fail(`Invalid JSONL in ${filePath} at line ${index + 1}: ${error.message}`);
      }
    });
}

function parseRunnerEvents(runDirectory, metadata) {
  const escapedName = metadata.testRunName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const logExpression = new RegExp(`^${escapedName}-(\\d+)\\.log$`);
  const events = {
    ready: [],
    sync: [],
    warmup: [],
    apply: [],
    crossEnvironment: [],
  };
  const patterns = {
    ready:
      /STREAM_READY\|1\|(\d+)\|([^|]+)\|([^|]+)\|(\d+)\|(\d+)/g,
    sync:
      /STREAM_SYNC\|1\|(\d+)\|([^|]+)\|([^|]+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)/g,
    warmup:
      /STREAM_WARMUP\|1\|(\d+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|(\d+)\|(\d+)/g,
    apply:
      /STREAM_APPLY\|1\|(\d+)\|([^|]+)\|([^|]+)\|([^|]+)\|(\d+)\|([^|]+)\|(\d+)\|(\d+)/g,
    cross:
      /STREAM_CROSS_ENV\|1\|(\d+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|(\d+)\|(\d+)/g,
  };

  for (const fileName of fs.readdirSync(runDirectory)) {
    const fileMatch = fileName.match(logExpression);
    if (!fileMatch) continue;
    const logRunner = Number(fileMatch[1]);
    const text = fs.readFileSync(path.join(runDirectory, fileName), "utf8");
    for (const match of text.matchAll(patterns.ready)) {
      if (match[2] !== metadata.runId) continue;
      events.ready.push({
        atUnixMs: Number(match[1]),
        runId: match[2],
        environmentId: match[3],
        runnerIndex: Number(match[4]),
        localConnectionIndex: Number(match[5]),
        logRunner,
      });
    }
    for (const match of text.matchAll(patterns.sync)) {
      if (match[2] !== metadata.runId) continue;
      events.sync.push({
        completedAtUnixMs: Number(match[1]),
        runId: match[2],
        environmentId: match[3],
        runnerIndex: Number(match[4]),
        localConnectionIndex: Number(match[5]),
        scheduledStartAtUnixMs: Number(match[6]),
        iterationStartedAtUnixMs: Number(match[7]),
        openedAtUnixMs: Number(match[8]),
        payloadBytes: Number(match[9]),
        featureFlagCount: Number(match[10]),
        segmentCount: Number(match[11]),
        parseLatencyMs: Number(match[12]),
        validationLatencyMs: Number(match[13]),
        logRunner,
      });
    }
    for (const match of text.matchAll(patterns.warmup)) {
      if (match[2] !== metadata.runId) continue;
      events.warmup.push({
        atUnixMs: Number(match[1]),
        runId: match[2],
        environmentId: match[3],
        flagKey: match[4],
        phase: match[5],
        revision: match[6],
        runnerIndex: Number(match[7]),
        localConnectionIndex: Number(match[8]),
        logRunner,
      });
    }
    for (const match of text.matchAll(patterns.apply)) {
      if (match[2] !== metadata.runId) continue;
      events.apply.push({
        atUnixMs: Number(match[1]),
        runId: match[2],
        environmentId: match[3],
        flagKey: match[4],
        revisionIndex: Number(match[5]),
        revision: match[6],
        runnerIndex: Number(match[7]),
        localConnectionIndex: Number(match[8]),
        logRunner,
      });
    }
    for (const match of text.matchAll(patterns.cross)) {
      if (match[2] !== metadata.runId) continue;
      events.crossEnvironment.push({
        atUnixMs: Number(match[1]),
        runId: match[2],
        environmentId: match[3],
        flagKey: match[4],
        phase: match[5],
        revision: match[6],
        runnerIndex: Number(match[7]),
        localConnectionIndex: Number(match[8]),
        logRunner,
      });
    }
  }

  for (const collection of Object.values(events)) {
    for (const event of collection) {
      if (event.runnerIndex !== event.logRunner) {
        fail(
          `Runner event claims runner ${event.runnerIndex} in runner ${event.logRunner} log.`,
        );
      }
    }
  }
  return events;
}

function extractServedRevision(flag) {
  const selectedId = flag?.isEnabled
    ? flag.fallthrough?.variations?.[0]?.id
    : flag?.disabledVariationId;
  const variation = flag?.variations?.find((candidate) => candidate?.id === selectedId);
  if (!variation || typeof variation.value !== "string") {
    fail(`Cannot resolve served revision for flag '${flag?.key ?? "<unknown>"}'.`);
  }
  const variationType = String(flag.variationType ?? "").toLowerCase();
  if (variationType === "string") return variation.value;
  if (variationType !== "json") {
    fail(`Unsupported variation type '${flag.variationType}' in observer event.`);
  }
  let configuration;
  try {
    configuration = JSON.parse(variation.value);
  } catch (error) {
    fail(`Observer JSON variation is invalid: ${error.message}`);
  }
  if (
    !configuration ||
    typeof configuration !== "object" ||
    typeof configuration._loadTestRevision !== "string" ||
    configuration._loadTestRevision.length === 0
  ) {
    fail("Observer JSON variation has no _loadTestRevision.");
  }
  return configuration._loadTestRevision;
}

function parseObserverEvents(filePath) {
  return readJsonLines(filePath).map((record, index) => {
    const updatedAtMs = Date.parse(record.payload?.updatedAt);
    const observedAtUnixMs = Number(record.observedAtUnixMs);
    if (!Number.isFinite(updatedAtMs) || !Number.isFinite(observedAtUnixMs)) {
      fail(`Observer event ${index + 1} has invalid timestamps.`);
    }
    return {
      node: String(record.node),
      environmentId: String(record.payload?.envId ?? ""),
      flagKey: String(record.payload?.key ?? ""),
      revision: extractServedRevision(record.payload),
      entityRevision: String(record.payload?.revision ?? ""),
      updatedAt: String(record.payload.updatedAt),
      updatedAtMs,
      observedAtUnixMs,
    };
  });
}

function successfulControlWrites(records, metadata) {
  const formalRecords = records.filter(
    (record) =>
      record.runId === metadata.runId &&
      record.environmentId === metadata.targetEnvironmentId &&
      Number(record.revisionIndex) > 0,
  );
  const groups = new Map();
  for (const record of formalRecords) {
    const key = [
      record.revisionIndex,
      record.revision,
      record.flagKey,
      record.attempt,
    ].join("|");
    const group = groups.get(key) ?? {};
    group[record.event] = record;
    groups.set(key, group);
  }
  const writes = [];
  for (const group of groups.values()) {
    if (group.request_start && group.request_end) {
      writes.push({
        ...group.request_start,
        atUnixMs: Number(group.request_start.atUnixMs),
        requestEndedAtUnixMs: Number(group.request_end.atUnixMs),
        revisionIndex: Number(group.request_start.revisionIndex),
        attempt: Number(group.request_start.attempt),
      });
    } else if (group.request_start && !group.request_error) {
      fail(
        `Controller attempt for revision ${group.request_start.revisionIndex} ` +
          "has neither request_end nor request_error.",
      );
    }
  }
  writes.sort((left, right) => left.revisionIndex - right.revisionIndex);
  if (writes.length !== 10) {
    fail(`Expected ten successful formal controller writes; found ${writes.length}.`);
  }
  for (let index = 0; index < writes.length; index += 1) {
    const write = writes[index];
    const expected = metadata.revisionPlan[index];
    if (
      write.revisionIndex !== index + 1 ||
      write.revision !== expected.revision ||
      write.flagKey !== expected.flagKey
    ) {
      fail(`Controller write ${index + 1} does not match the per-flag plan.`);
    }
  }
  return writes;
}

function observerGroupForWrite(observerEvents, write, expectedNodes) {
  const candidates = observerEvents.filter(
    (event) =>
      event.environmentId === write.environmentId &&
      event.flagKey === write.flagKey &&
      event.revision === write.revision &&
      event.observedAtUnixMs >= write.atUnixMs - 500 &&
      event.observedAtUnixMs <= write.requestEndedAtUnixMs + 5_000,
  );
  const groups = new Map();
  for (const event of candidates) {
    const key = `${event.updatedAt}|${event.entityRevision}`;
    const group = groups.get(key) ?? [];
    group.push(event);
    groups.set(key, group);
  }
  const valid = [...groups.values()].filter((events) => {
    const nodes = new Set(events.map((event) => event.node));
    return events.length === expectedNodes.length && nodes.size === expectedNodes.length;
  });
  if (valid.length !== 1) {
    fail(
      `Revision ${write.revisionIndex} expected one ${expectedNodes.length}-node ` +
        `observer publication group; found ${valid.length}.`,
    );
  }
  const events = valid[0];
  const actualNodes = [...new Set(events.map((event) => event.node))].sort();
  if (JSON.stringify(actualNodes) !== JSON.stringify(expectedNodes)) {
    fail(`Revision ${write.revisionIndex} observer nodes do not match loadgen nodes.`);
  }
  return events;
}

function safeStats(values) {
  return values.length > 0 ? percentileStats(values) : null;
}

function evaluateGate(name, action) {
  try {
    return { name, passed: true, evidence: action() };
  } catch (error) {
    return { name, passed: false, error: error.message };
  }
}

function counterValue(summary, name) {
  const metric = summary.metrics?.[name];
  if (!metric || !Number.isFinite(Number(metric.count))) {
    fail(`Runner summary is missing counter '${name}'.`);
  }
  return Number(metric.count);
}

function rateValues(summary, name) {
  const metric = summary.metrics?.[name];
  if (
    !metric ||
    !Number.isFinite(Number(metric.passes)) ||
    !Number.isFinite(Number(metric.fails))
  ) {
    fail(`Runner summary is missing rate '${name}'.`);
  }
  return { passes: Number(metric.passes), fails: Number(metric.fails) };
}

function aggregateHealth(summaries, expectedRevisionCount) {
  const sumCounter = (name) =>
    summaries.reduce((sum, entry) => sum + counterValue(entry.summary, name), 0);
  const sumRate = (name) =>
    summaries.reduce(
      (total, entry) => {
        const values = rateValues(entry.summary, name);
        total.passes += values.passes;
        total.fails += values.fails;
        return total;
      },
      { passes: 0, fails: 0 },
    );
  const health = {
    opened: sumCounter("connection_opened"),
    fullSync: sumCounter("full_sync_received"),
    readyBeforeHold: sumRate("ready_before_hold"),
    survived: sumRate("connection_survived"),
    connectionOpenSuccess: sumRate("connection_open_success"),
    initialSyncSuccess: sumRate("initial_sync_success"),
    initialValueSuccess: sumRate("initial_probe_value_success"),
    warmupCoverage: sumRate("post_ramp_warmup_coverage"),
    warmupPatchDeliveries: sumCounter("post_ramp_warmup_patch_received"),
    finalRevisionCorrectness: sumRate("final_applied_revision_success"),
    faults: {},
    revisions: [],
  };
  for (const name of [
    "connection_open_failure",
    "initial_sync_failure",
    "initial_sync_timeout",
    "unexpected_close",
    "websocket_error",
    "heartbeat_timeout",
    "invalid_message",
    "revision_sequence_error",
    "unexpected_revision",
    "cross_environment_delivery",
    "full_sync_flag_count_mismatch",
  ]) {
    health.faults[name] = sumCounter(name);
  }
  for (let index = 1; index <= expectedRevisionCount; index += 1) {
    health.revisions.push({
      revisionIndex: index,
      coverage: sumRate(`probe_revision_coverage{revision_index:${index}}`),
      deliveries: sumCounter(`probe_revision_received{revision_index:${index}}`),
    });
  }
  return health;
}

function readRunnerSummaries(runDirectory, metadata) {
  const expression = new RegExp(
    `^${metadata.testRunName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}-(\\d+)-[a-z0-9]+-summary\\.json$`,
  );
  const summaries = [];
  for (const fileName of fs.readdirSync(runDirectory)) {
    const match = fileName.match(expression);
    if (match) {
      summaries.push({
        runner: Number(match[1]),
        summary: readJson(path.join(runDirectory, fileName)),
      });
    }
  }
  summaries.sort((left, right) => left.runner - right.runner);
  if (summaries.length !== Number(metadata.parallelism)) {
    fail(`Expected ${metadata.parallelism} runner summaries; found ${summaries.length}.`);
  }
  return summaries;
}

function aggregateResourcePeaks(samplesPath, metadata) {
  const samples = readJsonLines(samplesPath);
  const peaks = {
    sampleCount: samples.length,
    els: { cpuMillicores: 0, memoryMiB: 0 },
    runners: { cpuMillicores: 0, memoryMiB: 0 },
    api: { cpuMillicores: 0, memoryMiB: 0 },
    ui: { cpuMillicores: 0, memoryMiB: 0 },
    postgresql: { cpuMillicores: 0, memoryMiB: 0 },
    redis: { cpuMillicores: 0, memoryMiB: 0 },
    featbitNodes: { cpuMillicores: 0, memoryMiB: 0 },
    loadgenNodes: { cpuMillicores: 0, memoryMiB: 0 },
  };
  const update = (scope, rows) => {
    const cpu = rows.reduce((sum, row) => sum + Number(row.cpuMillicores), 0);
    const memoryMiB =
      rows.reduce((sum, row) => sum + Number(row.memoryBytes), 0) / 1024 / 1024;
    scope.cpuMillicores = Math.max(scope.cpuMillicores, cpu);
    scope.memoryMiB = Math.max(scope.memoryMiB, memoryMiB);
  };
  const runnerExpression = new RegExp(
    `^${metadata.testRunName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}-\\d+-`,
  );
  for (const sample of samples) {
    const containers = sample.containers ?? [];
    update(
      peaks.els,
      containers.filter(
        (row) => row.namespace === "featbit" && row.container === "featbit-els",
      ),
    );
    update(
      peaks.runners,
      containers.filter(
        (row) =>
          row.namespace === "featbit-loadtest" && runnerExpression.test(row.pod),
      ),
    );
    update(
      peaks.api,
      containers.filter(
        (row) => row.namespace === "featbit" && row.container === "featbit-api",
      ),
    );
    update(
      peaks.ui,
      containers.filter(
        (row) => row.namespace === "featbit" && row.container === "featbit-ui",
      ),
    );
    update(
      peaks.postgresql,
      containers.filter(
        (row) => row.namespace === "featbit" && row.container === "postgresql",
      ),
    );
    update(
      peaks.redis,
      containers.filter(
        (row) => row.namespace === "featbit" && row.container === "redis",
      ),
    );
    update(
      peaks.featbitNodes,
      (sample.nodes ?? []).filter((row) => row.nodePool === "featbit"),
    );
    update(
      peaks.loadgenNodes,
      (sample.nodes ?? []).filter((row) => row.nodePool === "loadgen"),
    );
  }
  return peaks;
}

function validateElsEvidence(deployment, podList, metadata) {
  const elsContainers = (deployment?.spec?.template?.spec?.containers ?? []).filter(
    (container) => container?.name === "featbit-els",
  );
  if (elsContainers.length !== 1) {
    fail(`Expected one featbit-els container; found ${elsContainers.length}.`);
  }
  const container = elsContainers[0];
  const resources = container.resources ?? {};
  const pods = podList?.items ?? [];
  const readyPods = pods.filter((pod) => {
    const statuses = pod?.status?.containerStatuses ?? [];
    return (
      pod?.status?.phase === "Running" &&
      statuses.length > 0 &&
      statuses.every((status) => status?.ready === true)
    );
  });
  const nodes = [...new Set(readyPods.map((pod) => pod?.spec?.nodeName))].sort();
  const expectedResources = metadata?.fixedInfrastructure?.elsResources;
  const expectedPlacement =
    metadata?.fixedInfrastructure?.elsPlacement?.nodeWorkload ?? "featbit";
  const placementExpression = new RegExp(
    `^aks-${String(expectedPlacement).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}-`,
  );
  if (
    Number(deployment?.spec?.replicas) !== 3 ||
    Number(deployment?.status?.readyReplicas) !== 3 ||
    readyPods.length !== 3 ||
    nodes.length !== 3 ||
    !nodes.every((node) => placementExpression.test(String(node))) ||
    resources?.requests?.cpu !== expectedResources?.cpuRequest ||
    resources?.limits?.cpu !== expectedResources?.cpuLimit ||
    resources?.requests?.memory !== expectedResources?.memoryRequest ||
    resources?.limits?.memory !== expectedResources?.memoryLimit
  ) {
    fail("ELS replicas, placement, spreading, or resources differ from the selected matrix.");
  }
  return {
    image: container.image,
    replicas: 3,
    nodes,
    placementWorkload: expectedPlacement,
    resources: expectedResources,
  };
}

function formatNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number.toFixed(2) : "—";
}

function formatMiB(bytes) {
  return formatNumber(Number(bytes) / 1024 / 1024);
}

function statsRow(name, stats) {
  if (!stats) return `| ${name} | 0 | — | — | — | — | — | — |`;
  return `| ${name} | ${stats.count} | ${formatNumber(stats.avg)} | ${formatNumber(
    stats.p50,
  )} | ${formatNumber(stats.p90)} | ${formatNumber(stats.p95)} | ${formatNumber(
    stats.p99,
  )} | ${formatNumber(stats.max)} |`;
}

function createMarkdown(report) {
  const ramp = report.rampAndInitialSync;
  const lines = [
    `# ${report.runId} 单环境 3,000 flags 极限测试`,
    "",
    `状态：**${report.passed ? "PASS" : "FAIL"}**。`,
    "",
    "场景：一个 Environment、3,000 flags（2,500 string + 500 JSON）；20 runners × 500 connections；100 connections/s，目标 100 秒到 10,000。正式变更为 8 个 string flags + 2 个 JSON config flags，每次 fan-out 到全部 10,000 connections。",
    "",
    "## Ramp 与大 initial sync",
    "",
    "| 阶段 | 配置目标 | 实际完成时间 | 相对 100s 目标的延迟 |",
    "| --- | ---: | ---: | ---: |",
    `| 最后一次连接尝试 | 100,000 ms | ${formatNumber(ramp.actualAttemptRampDurationMs)} ms | ${formatNumber(ramp.attemptCompletionDelayMs)} ms |`,
    `| 最后一次 WebSocket open | 100,000 ms | ${formatNumber(ramp.actualOpenRampDurationMs)} ms | ${formatNumber(ramp.openCompletionDelayMs)} ms |`,
    `| 最后一次 3,000-flag sync 完成 | 100,000 ms | ${formatNumber(ramp.actualReadyRampDurationMs)} ms | ${formatNumber(ramp.readyCompletionDelayMs)} ms |`,
    "",
    `Initial-sync ready milestones：p50 ${formatNumber(
      ramp.readyMilestonesMs.p50,
    )} ms，p90 ${formatNumber(ramp.readyMilestonesMs.p90)} ms，p95 ${formatNumber(
      ramp.readyMilestonesMs.p95,
    )} ms，p99 ${formatNumber(ramp.readyMilestonesMs.p99)} ms，100% ${formatNumber(
      ramp.readyMilestonesMs.p100,
    )} ms。`,
    "",
    `每连接 full-sync payload：avg ${formatMiB(
      ramp.payload.perConnectionBytes.avg,
    )} MiB，max ${formatMiB(
      ramp.payload.perConnectionBytes.max,
    )} MiB；10,000 connections 合计约 ${formatNumber(
      ramp.payload.totalGiB,
    )} GiB。每条 sync 都验证为 3,000 flags。`,
    "",
    "| Initial-sync 指标 | count | avg | p50 | p90 | p95 | p99 | max |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    statsRow(
      "connection_start_schedule_drift_ms",
      ramp.metrics.connection_start_schedule_drift_ms,
    ),
    statsRow(
      "connection_open_latency_ms",
      ramp.metrics.connection_open_latency_ms,
    ),
    statsRow(
      "initial_sync_after_open_latency_ms",
      ramp.metrics.initial_sync_after_open_latency_ms,
    ),
    statsRow(
      "initial_sync_end_to_end_latency_ms",
      ramp.metrics.initial_sync_end_to_end_latency_ms,
    ),
    statsRow(
      "full_sync_parse_latency_ms",
      ramp.metrics.full_sync_parse_latency_ms,
    ),
    "",
    "## Three-stage latency",
    "",
    "| 指标 | count | avg | p50 | p90 | p95 | p99 | max |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    statsRow("end_to_end_latency_ms", report.metrics.end_to_end_latency_ms),
    statsRow(
      "control_plane_write_latency_ms",
      report.metrics.control_plane_write_latency_ms,
    ),
    statsRow("probe_sync_latency_ms", report.metrics.probe_sync_latency_ms),
    statsRow(
      "probe_sync_latency_ms ≤100ms（辅助）",
      report.deJittered.probe_sync_latency_ms,
    ),
    "",
    "## 每次 flag 变更（每行 10,000 条连接）",
    "",
    "| # | type | flag | revision | count | probe avg | p95 | p99 | max | control | end-to-end avg |",
    "| ---: | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ];
  for (const revision of report.revisions) {
    lines.push(
      `| ${revision.revisionIndex} | ${revision.variationType} | \`${revision.flagKey}\` | ${revision.revision} | ` +
        `${revision.probe_sync_latency_ms.count} | ${formatNumber(
          revision.probe_sync_latency_ms.avg,
        )} | ${formatNumber(revision.probe_sync_latency_ms.p95)} | ` +
        `${formatNumber(revision.probe_sync_latency_ms.p99)} | ` +
        `${formatNumber(revision.probe_sync_latency_ms.max)} | ` +
        `${formatNumber(revision.controlPlaneWriteMs)} | ` +
        `${formatNumber(revision.end_to_end_latency_ms.avg)} |`,
    );
  }
  lines.push(
    "",
    "## Gate",
    "",
    "| Gate | 结果 |",
    "| --- | --- |",
  );
  for (const gate of report.gates) {
    lines.push(`| ${gate.name} | ${gate.passed ? "PASS" : `FAIL: ${gate.error}`} |`);
  }
  lines.push(
    "",
    "## 5 秒资源峰值",
    "",
    "| 范围 | CPU | Memory |",
    "| --- | ---: | ---: |",
  );
  for (const [name, value] of [
    ["ELS (3 Pods)", report.resources.fiveSecondPeaks.els],
    ["k6 runners (20)", report.resources.fiveSecondPeaks.runners],
    ["FeatBit API", report.resources.fiveSecondPeaks.api],
    ["PostgreSQL", report.resources.fiveSecondPeaks.postgresql],
    ["Redis", report.resources.fiveSecondPeaks.redis],
    [
      `FeatBit/ELS nodes (${report.topology.functionalFeatbitNodeCount})`,
      report.resources.fiveSecondPeaks.featbitNodes,
    ],
    [
      `loadgen nodes (${report.topology.runnerNodeCount})`,
      report.resources.fiveSecondPeaks.loadgenNodes,
    ],
  ]) {
    lines.push(
      `| ${name} | ${formatNumber(value.cpuMillicores)} m | ${formatNumber(
        value.memoryMiB,
      )} MiB |`,
    );
  }
  lines.push(
    "",
    "这是“单环境 3,000 flags、10,000 connection fan-out”的独立极限基线。它与多环境 100-target 场景、以及旧单环境少量 flags 的 G5 基线都不是同一工作负载，不能直接只用一个 latency 数字判定快慢。",
    "",
  );
  return `${lines.join("\n")}\n`;
}

function createHtml(report) {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${report.runId} large flag-set</title>
<style>body{font-family:system-ui;max-width:1000px;margin:40px auto;padding:0 20px;color:#172033}
.ok{color:#087f5b}.bad{color:#c92a2a}.cards{display:flex;gap:16px;flex-wrap:wrap}
.card{border:1px solid #ddd;border-radius:10px;padding:16px;min-width:190px}</style></head>
<body><h1>${report.runId}</h1><h2 class="${report.passed ? "ok" : "bad"}">${
    report.passed ? "PASS" : "FAIL"
  }</h2><div class="cards">
<div class="card">Connections<br><strong>${report.health.opened}/10,000</strong></div>
<div class="card">Flags/full sync<br><strong>3,000</strong></div>
<div class="card">Attempt ramp delay<br><strong>${formatNumber(
    report.rampAndInitialSync.attemptCompletionDelayMs,
  )} ms</strong></div>
<div class="card">Ready after ramp target<br><strong>${formatNumber(
    report.rampAndInitialSync.readyCompletionDelayMs,
  )} ms</strong></div>
<div class="card">Merged probe p99<br><strong>${formatNumber(
    report.metrics.probe_sync_latency_ms?.p99,
  )} ms</strong></div></div></body></html>`;
}

function main() {
  const { runId, resultsDirectory } = parseArguments(process.argv.slice(2));
  const runDirectory = locateRunDirectory(resultsDirectory, runId);
  const metadata = readJson(requireFile(runDirectory, `${runId}-metadata.json`));
  const inventory = readJson(
    requireFile(runDirectory, `${runId}-large-flagset-inventory.json`),
  );
  const placement = readJson(
    requireFile(runDirectory, `${runId}-runner-placement.json`),
  );
  const observerEvents = parseObserverEvents(
    requireFile(runDirectory, `${runId}-stream-timing-events.jsonl`),
  );
  const controlRecords = readJsonLines(
    requireFile(runDirectory, `${runId}-external-controller-events.jsonl`),
  );
  const runnerEvents = parseRunnerEvents(runDirectory, metadata);
  const summaries = readRunnerSummaries(runDirectory, metadata);
  const health = aggregateHealth(summaries, metadata.expectedRevisions.length);
  const targetEnvironmentId = metadata.targetEnvironmentId;

  const runnerNodes = new Map();
  const escapedName = metadata.testRunName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  for (const pod of placement.pods ?? []) {
    const match = String(pod.name).match(new RegExp(`^${escapedName}-(\\d+)-`));
    if (match) runnerNodes.set(Number(match[1]), pod.node);
  }
  if (runnerNodes.size !== 20) {
    fail(`Expected 20 runner placements; found ${runnerNodes.size}.`);
  }
  const runnerNodeNames = [...new Set(runnerNodes.values())].sort();
  const expectedRunnerNodeCount = Number(
    metadata.fixedInfrastructure?.runnerPlacement?.nodeCount ??
      metadata.fixedInfrastructure?.loadgenNodes,
  );
  if (runnerNodeNames.length !== expectedRunnerNodeCount) {
    fail(
      `Expected ${expectedRunnerNodeCount} runner nodes; found ${runnerNodeNames.length}.`,
    );
  }
  const expectedObserverNodeCount = Number(
    metadata.fixedInfrastructure?.loadgenNodes,
  );
  const observerNodeNames = [
    ...new Set(observerEvents.map((event) => event.node)),
  ].sort();
  if (observerNodeNames.length !== expectedObserverNodeCount) {
    fail(
      `Expected ${expectedObserverNodeCount} Redis observer nodes; ` +
        `found ${observerNodeNames.length}.`,
    );
  }

  const gates = [];
  gates.push(
    evaluateGate("10,000 ready in one environment", () =>
      validateReadyDistribution(runnerEvents.ready, [targetEnvironmentId], {
        parallelism: 20,
        connectionsPerRunner: 500,
        connectionsPerEnvironmentPerRunner: 500,
      }),
    ),
  );
  gates.push(
    evaluateGate("10,000 exact 3,000-flag initial-sync records", () =>
      validateInitialSyncEvents(runnerEvents.sync, {
        expectedConnections: 10_000,
        parallelism: 20,
        connectionsPerRunner: 500,
        expectedEnvironmentId: targetEnvironmentId,
        expectedFlagCount: 3_000,
      }),
    ),
  );
  const rampAndInitialSync = summarizeInitialSyncRamp(
    runnerEvents.sync,
    Number(metadata.parameters.RampDurationSeconds) * 1_000,
  );

  for (const phase of ["revision", "baseline"]) {
    const events = runnerEvents.warmup.filter((event) => event.phase === phase);
    gates.push(
      evaluateGate(`post-ramp warm-up ${phase} 10,000/10,000`, () =>
        validateTargetDeliveryDistribution(events, {
          targetEnvironmentId,
          parallelism: 20,
          connectionsPerEnvironmentPerRunner: 500,
          label: `warm-up ${phase}`,
        }),
      ),
    );
  }
  gates.push(
    evaluateGate("cross-environment delivery zero", () => {
      if (runnerEvents.crossEnvironment.length !== 0) {
        fail(`found ${runnerEvents.crossEnvironment.length} event(s)`);
      }
      return { count: 0 };
    }),
  );

  const writes = successfulControlWrites(controlRecords, metadata);
  gates.push(evaluateGate("controller 8 string + 2 JSON writes", () => ({
    count: writes.length,
    string: metadata.revisionPlan.filter((step) => step.variationType === "string")
      .length,
    json: metadata.revisionPlan.filter((step) => step.variationType === "json")
      .length,
  })));
  const intervals = writes.slice(1).map(
    (write, index) => write.atUnixMs - writes[index].atUnixMs,
  );
  gates.push(
    evaluateGate("30-second revision intervals", () => {
      const outside = intervals.filter((value) => value < 29_000 || value > 31_000);
      if (outside.length > 0) {
        fail(`interval(s) outside 29–31s: ${outside.join(", ")}`);
      }
      return { milliseconds: intervals };
    }),
  );

  const revisions = [];
  const allProbe = [];
  const allEndToEnd = [];
  const controlPlane = [];
  let observerMatchedEventCount = 0;
  for (const write of writes) {
    const plan = metadata.revisionPlan[write.revisionIndex - 1];
    const observed = observerGroupForWrite(
      observerEvents,
      write,
      observerNodeNames,
    );
    observerMatchedEventCount += observed.length;
    const firstObservedAtUnixMs = Math.min(
      ...observed.map((event) => event.observedAtUnixMs),
    );
    const arrivalSpreadMs =
      Math.max(...observed.map((event) => event.observedAtUnixMs)) -
      firstObservedAtUnixMs;
    const controlPlaneWriteMs = firstObservedAtUnixMs - write.atUnixMs;
    controlPlane.push(controlPlaneWriteMs);
    const applications = runnerEvents.apply.filter(
      (event) =>
        event.environmentId === targetEnvironmentId &&
        event.flagKey === write.flagKey &&
        event.revisionIndex === write.revisionIndex &&
        event.revision === write.revision,
    );
    gates.push(
      evaluateGate(`revision ${write.revisionIndex} coverage 10,000/10,000`, () =>
        validateTargetDeliveryDistribution(applications, {
          targetEnvironmentId,
          parallelism: 20,
          connectionsPerEnvironmentPerRunner: 500,
          label: `revision ${write.revisionIndex}`,
        }),
      ),
    );
    const probeValues = applications.map(
      (event) => event.atUnixMs - firstObservedAtUnixMs,
    );
    const endToEndValues = applications.map(
      (event) => event.atUnixMs - write.atUnixMs,
    );
    allProbe.push(...probeValues);
    allEndToEnd.push(...endToEndValues);
    const runnerDiagnostics = [];
    for (let runner = 1; runner <= 20; runner += 1) {
      const values = applications
        .filter((event) => event.runnerIndex === runner)
        .map((event) => event.atUnixMs - firstObservedAtUnixMs);
      runnerDiagnostics.push({
        runner,
        count: values.length,
        probe_sync_latency_ms: safeStats(values),
      });
    }
    revisions.push({
      revisionIndex: write.revisionIndex,
      revision: write.revision,
      variationType: plan.variationType,
      environmentId: targetEnvironmentId,
      flagKey: write.flagKey,
      controllerRequestStartedAtUnixMs: write.atUnixMs,
      controllerRequestEndedAtUnixMs: write.requestEndedAtUnixMs,
      controllerApiResponseMs: write.requestEndedAtUnixMs - write.atUnixMs,
      redisFirstObservedAtUnixMs: firstObservedAtUnixMs,
      observerArrivalSpreadMs: arrivalSpreadMs,
      observerEventCount: observed.length,
      controlPlaneWriteMs,
      probe_sync_latency_ms: safeStats(probeValues),
      end_to_end_latency_ms: safeStats(endToEndValues),
      deJitteredProbeSyncLatencyMs: safeStats(
        probeValues.filter((value) => value <= 100),
      ),
      runnerDiagnostics,
    });
  }
  gates.push(
    evaluateGate(
      `Redis observer 10 revisions x ${expectedObserverNodeCount} nodes`,
      () => {
        const expectedEvents = 10 * expectedObserverNodeCount;
        if (observerMatchedEventCount !== expectedEvents) {
          fail(`matched ${observerMatchedEventCount}, expected ${expectedEvents}`);
        }
        return {
          count: observerMatchedEventCount,
          nodes: expectedObserverNodeCount,
        };
      }
    ),
  );

  gates.push(
    evaluateGate("connection and protocol health", () => {
      const failures = [];
      for (const [name, value] of Object.entries(health.faults)) {
        if (value !== 0) failures.push(`${name}=${value}`);
      }
      for (const [name, value] of [
        ["opened", health.opened],
        ["fullSync", health.fullSync],
        ["ready", health.readyBeforeHold.passes],
        ["survived", health.survived.passes],
      ]) {
        if (value !== 10_000) failures.push(`${name}=${value}`);
      }
      if (
        health.readyBeforeHold.fails !== 0 ||
        health.survived.fails !== 0 ||
        health.connectionOpenSuccess.fails !== 0 ||
        health.initialSyncSuccess.fails !== 0 ||
        health.initialValueSuccess.fails !== 0
      ) {
        failures.push("one or more health rates contain failures");
      }
      if (failures.length > 0) fail(failures.join("; "));
      return { opened: 10_000, fullSync: 10_000, ready: 10_000, survived: 10_000 };
    }),
  );
  gates.push(
    evaluateGate("warm-up coverage 10,000 and 20,000 deliveries", () => {
      if (
        health.warmupCoverage.passes !== 10_000 ||
        health.warmupCoverage.fails !== 0 ||
        health.warmupPatchDeliveries !== 20_000
      ) {
        fail(
          `coverage=${health.warmupCoverage.passes}/${health.warmupCoverage.fails}, ` +
            `deliveries=${health.warmupPatchDeliveries}`,
        );
      }
      return { coverage: 10_000, deliveries: 20_000 };
    }),
  );
  gates.push(
    evaluateGate("formal coverage 100,000 and final 10,000", () => {
      const deliveries = health.revisions.reduce(
        (sum, revision) => sum + revision.deliveries,
        0,
      );
      const coveragePasses = health.revisions.reduce(
        (sum, revision) => sum + revision.coverage.passes,
        0,
      );
      const coverageFails = health.revisions.reduce(
        (sum, revision) => sum + revision.coverage.fails,
        0,
      );
      if (
        deliveries !== 100_000 ||
        coveragePasses !== 100_000 ||
        coverageFails !== 0 ||
        health.finalRevisionCorrectness.passes !== 10_000 ||
        health.finalRevisionCorrectness.fails !== 0
      ) {
        fail(
          `deliveries=${deliveries}, coverage=${coveragePasses}/${coverageFails}, ` +
            `final=${health.finalRevisionCorrectness.passes}/` +
            `${health.finalRevisionCorrectness.fails}`,
        );
      }
      return { deliveries, coverage: coveragePasses, final: 10_000 };
    }),
  );

  const resourceSummary = readJson(
    requireFile(runDirectory, `${runId}-resource-summary.json`),
  );
  const elsConfiguration = validateElsEvidence(
    readJson(requireFile(runDirectory, `${runId}-els-deployment.json`)),
    readJson(requireFile(runDirectory, `${runId}-els-pods.json`)),
    metadata,
  );
  const resourcePeaks = aggregateResourcePeaks(
    requireFile(runDirectory, `${runId}-resource-samples.jsonl`),
    metadata,
  );
  const oneSecondPath = optionalFile(
    runDirectory,
    `${runId}-node-evidence-1s.json`,
  );
  const oneSecondEvidence = oneSecondPath ? readJson(oneSecondPath) : null;
  gates.push(
    evaluateGate("ELS fixed resources and spreading", () => elsConfiguration),
  );
  gates.push(
    evaluateGate("5-second and 1-second resource evidence complete", () => {
      if (resourceSummary.complete !== true) {
        fail("5-second resource monitor is incomplete");
      }
      if (!oneSecondEvidence) {
        fail("1-second node evidence report is missing");
      }
      const additionalNodes = (
        metadata.fixedInfrastructure?.additionalNodePools ?? []
      ).reduce((sum, pool) => sum + Number(pool.nodes), 0);
      const expectedNodeFiles =
        Number(metadata.fixedInfrastructure?.featbitNodes) +
        Number(metadata.fixedInfrastructure?.loadgenNodes) +
        additionalNodes;
      if (
        Number(oneSecondEvidence.evidence?.nodeFiles) !== expectedNodeFiles ||
        Number(oneSecondEvidence.evidence?.metadataFiles) !== expectedNodeFiles
      ) {
        fail(
          `1-second evidence does not contain ${expectedNodeFiles} node and metadata files`,
        );
      }
      return {
        resourceSamples: resourcePeaks.sampleCount,
        nodeFiles: oneSecondEvidence.evidence.nodeFiles,
      };
    }),
  );

  const passed = gates.every((gate) => gate.passed);
  const combinedProbeStats = safeStats(allProbe);
  const report = {
    schemaVersion: 1,
    runId,
    runKind: metadata.runKind,
    generatedAtUtc: new Date().toISOString(),
    passed,
    baselineDefinition:
      "One environment with 3,000 flags; 10,000 Server SDK connections; 8 string and 2 JSON per-flag revisions.",
    comparisonBoundary:
      "Independent extreme baseline; not directly comparable to the 100-target multi-environment baseline or the old small-inventory single-environment G5 baseline.",
    topology: {
      environments: 1,
      flags: 3_000,
      stringFlags: 2_500,
      jsonFlags: 500,
      jsonVariationBytes: Number(inventory.topology.jsonVariationBytes),
      parallelism: 20,
      connectionsPerRunner: 500,
      connectionsPerEnvironment: 10_000,
      totalConnections: 10_000,
      configuredConnectionsPerSecond: 100,
      configuredRampDurationSeconds: 100,
      targetEnvironmentId,
      targetEnvironmentKey: metadata.targetEnvironmentKey,
      postRampWarmupFlagKey: metadata.postRampWarmupFlagKey,
      runnerNodeCount: runnerNodeNames.length,
      runnerNodes: runnerNodeNames,
      observerNodeCount: observerNodeNames.length,
      observerNodes: observerNodeNames,
      functionalFeatbitNodeCount:
        Number(metadata.fixedInfrastructure?.featbitNodes) +
        (metadata.fixedInfrastructure?.additionalNodePools ?? [])
          .filter((pool) => pool.role === "featbit")
          .reduce((sum, pool) => sum + Number(pool.nodes), 0),
    },
    rampAssessment: {
      connectionAttemptRampDelayed:
        rampAndInitialSync.attemptCompletionDelayMs > 0,
      connectionAttemptDelayMs: rampAndInitialSync.attemptCompletionDelayMs,
      websocketOpenAfterRampTargetMs: rampAndInitialSync.openCompletionDelayMs,
      fullSyncReadyAfterRampTargetMs: rampAndInitialSync.readyCompletionDelayMs,
      interpretation:
        "Attempt delay measures k6 scheduling against the configured 100/s ramp. Open and ready delay additionally include handshake and the 3,000-flag full-sync path.",
    },
    rampAndInitialSync,
    health,
    formalDeliveryCount: runnerEvents.apply.length,
    controller: {
      successfulFormalWrites: writes.length,
      stringWrites: metadata.revisionPlan.filter(
        (step) => step.variationType === "string",
      ).length,
      jsonWrites: metadata.revisionPlan.filter(
        (step) => step.variationType === "json",
      ).length,
      revisionStartIntervalsMs: intervals,
      apiResponseLatencyMs: safeStats(
        writes.map((write) => write.requestEndedAtUnixMs - write.atUnixMs),
      ),
    },
    observer: {
      nodeCount: 10,
      matchedEventCount: observerMatchedEventCount,
      arrivalSpreadMs: safeStats(
        revisions.map((revision) => revision.observerArrivalSpreadMs),
      ),
      caveat:
        "Earliest subscriber receive follows Redis PUBLISH by a small network/scheduling interval and can slightly understate streaming delivery.",
    },
    metrics: {
      end_to_end_latency_ms: safeStats(allEndToEnd),
      control_plane_write_latency_ms: safeStats(controlPlane),
      probe_sync_latency_ms: combinedProbeStats,
      streaming_delivery_latency_ms: combinedProbeStats,
    },
    deJittered: {
      definition: "probe_sync_latency_ms <= 100ms; auxiliary diagnostic only",
      removed: allProbe.filter((value) => value > 100).length,
      retained: allProbe.filter((value) => value <= 100).length,
      probe_sync_latency_ms: safeStats(allProbe.filter((value) => value <= 100)),
    },
    revisions,
    runnerDiagnostics: Array.from({ length: 20 }, (_, offset) => {
      const runner = offset + 1;
      const values = revisions.flatMap((revision) => {
        const entry = revision.runnerDiagnostics.find(
          (candidate) => candidate.runner === runner,
        );
        return entry?.probe_sync_latency_ms
          ? runnerEvents.apply
              .filter(
                (event) =>
                  event.runnerIndex === runner &&
                  event.revisionIndex === revision.revisionIndex,
              )
              .map(
                (event) =>
                  event.atUnixMs - revision.redisFirstObservedAtUnixMs,
              )
          : [];
      });
      return { runner, probe_sync_latency_ms: safeStats(values) };
    }),
    resources: {
      elsConfiguration,
      fiveSecondPeaks: resourcePeaks,
      oneSecond: oneSecondEvidence
        ? {
            loadgen: oneSecondEvidence.pools?.loadgen,
            featbit: oneSecondEvidence.pools?.featbit,
            els: oneSecondEvidence.els,
            kubernetesPeaks: oneSecondEvidence.kubernetesPeaks,
          }
        : null,
    },
    gates,
  };

  const jsonPath = path.join(runDirectory, `${runId}-large-flagset-analysis.json`);
  const markdownPath = path.join(
    runDirectory,
    `${runId}-large-flagset-analysis.md`,
  );
  const htmlPath = path.join(runDirectory, `${runId}-large-flagset-analysis.html`);
  fs.writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`);
  fs.writeFileSync(markdownPath, createMarkdown(report));
  fs.writeFileSync(htmlPath, createHtml(report));
  process.stdout.write(
    `${JSON.stringify({
      runId,
      passed,
      jsonPath,
      markdownPath,
      htmlPath,
      rampAssessment: report.rampAssessment,
      metrics: report.metrics,
    })}\n`,
  );
  if (!passed) process.exitCode = 2;
}

try {
  main();
} catch (error) {
  process.stderr.write(`Large flag-set analysis failed: ${error.message}\n`);
  process.exitCode = 1;
}
