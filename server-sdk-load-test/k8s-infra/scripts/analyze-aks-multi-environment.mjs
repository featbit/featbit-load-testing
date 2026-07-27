import fs from "node:fs";
import path from "node:path";
import process from "node:process";

import {
  connectionIdentity,
  percentileStats,
  validateReadyDistribution,
  validateTargetDeliveryDistribution,
} from "../../k6/lib/multi-environment-analysis.js";

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
  const events = { ready: [], warmup: [], apply: [], crossEnvironment: [] };

  const patterns = {
    ready:
      /STREAM_READY\|1\|(\d+)\|([^|]+)\|([^|]+)\|(\d+)\|(\d+)/g,
    warmup:
      /STREAM_WARMUP\|1\|(\d+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|(\d+)\|(\d+)/g,
    apply:
      /STREAM_APPLY\|1\|(\d+)\|([^|]+)\|([^|]+)\|([^|]+)\|(\d+)\|([^|]+)\|(\d+)\|(\d+)/g,
    cross:
      /STREAM_CROSS_ENV\|1\|(\d+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|(\d+)\|(\d+)/g,
  };

  for (const fileName of fs.readdirSync(runDirectory)) {
    const fileMatch = fileName.match(logExpression);
    if (!fileMatch) {
      continue;
    }
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
  return variation.value;
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
  if (writes.length !== metadata.expectedRevisions.length) {
    fail(`Expected ten successful formal controller writes; found ${writes.length}.`);
  }
  for (let index = 0; index < writes.length; index += 1) {
    const write = writes[index];
    if (
      write.revisionIndex !== index + 1 ||
      write.revision !== metadata.expectedRevisions[index] ||
      write.flagKey !== metadata.measuredProbeFlagKeys[0]
    ) {
      fail(`Controller write ${index + 1} does not match the formal plan.`);
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
    backgroundIsolation: sumRate("background_isolation_success"),
    backgroundConnectionsChecked: sumCounter("background_connection_checked"),
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
    "cross_environment_delivery",
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

function validateElsEvidence(deployment, podList) {
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
  if (
    Number(deployment?.spec?.replicas) !== 3 ||
    Number(deployment?.status?.readyReplicas) !== 3 ||
    readyPods.length !== 3 ||
    nodes.length !== 3 ||
    resources?.requests?.cpu !== "500m" ||
    resources?.limits?.cpu !== "1" ||
    resources?.requests?.memory !== "256Mi" ||
    resources?.limits?.memory !== "512Mi"
  ) {
    fail("ELS replicas, spreading, or resources differ from the fixed G5 matrix.");
  }
  return {
    image: container.image,
    replicas: 3,
    nodes,
    resources: {
      cpuRequest: "500m",
      cpuLimit: "1",
      memoryRequest: "256Mi",
      memoryLimit: "512Mi",
    },
  };
}

function formatNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number.toFixed(2) : "—";
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
  const lines = [
    `# ${report.runId} 多环境 Three-stage 结果`,
    "",
    `状态：**${report.passed ? "PASS" : "FAIL"}**；run kind：\`${report.runKind}\`。`,
    "",
    "## 三个互不混淆的范围",
    "",
    `- 背景连接健康：${report.health.opened}/10,000 opened，${report.health.fullSync}/10,000 full sync，${report.health.survived.passes}/10,000 survived。`,
    `- target 环境传播：100 条连接 × 10 revisions = ${report.formalDeliveryCount}/1,000 原始样本。`,
    `- 环境隔离：cross-environment delivery = ${report.crossEnvironmentDeliveryCount}。`,
    "",
    "## 合并的 target 原始样本",
    "",
    "| 指标 | count | avg | p50 | p90 | p95 | p99 | max |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    statsRow("end_to_end_latency_ms", report.metrics.end_to_end_latency_ms),
    statsRow("probe_sync_latency_ms", report.metrics.probe_sync_latency_ms),
    statsRow(
      "probe_sync_latency_ms ≤100ms（辅助去抖动）",
      report.deJittered.probe_sync_latency_ms,
    ),
    statsRow(
      "control_plane_write_latency_ms（10 次更新）",
      report.metrics.control_plane_write_latency_ms,
    ),
    "",
    "## 每 revision 的 100 条 target 样本",
    "",
    "| revision | count | probe avg | p50 | p90 | p95 | p99 | max | control | end-to-end avg |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ];
  for (const revision of report.revisions) {
    const stats = revision.probe_sync_latency_ms;
    lines.push(
      `| ${revision.revision} | ${stats.count} | ${formatNumber(stats.avg)} | ` +
        `${formatNumber(stats.p50)} | ${formatNumber(stats.p90)} | ` +
        `${formatNumber(stats.p95)} | ${formatNumber(stats.p99)} | ` +
        `${formatNumber(stats.max)} | ${formatNumber(
          revision.controlPlaneWriteMs,
        )} | ${formatNumber(revision.end_to_end_latency_ms.avg)} |`,
    );
  }
  lines.push(
    "",
    "> 每 revision 只有 100 个 target 样本；线性插值 p99 主要由最慢的约两个观测决定，适合描述本轮分布，不应当作稳定尾部估计。runner 每 revision 仅 5 个样本，因此 runner percentile 只用于定位，不作为主结论。",
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
    "## 资源证据",
    "",
    "5 秒 Kubernetes 峰值为同一采样点内该范围的合计值：",
    "",
    "| 范围 | peak CPU (m) | peak memory (MiB) |",
    "| --- | ---: | ---: |",
  );
  for (const [name, scope] of [
    ["ELS (3 Pods)", report.resources.fiveSecondPeaks.els],
    ["k6 runners (20)", report.resources.fiveSecondPeaks.runners],
    ["FeatBit API", report.resources.fiveSecondPeaks.api],
    ["FeatBit UI", report.resources.fiveSecondPeaks.ui],
    ["PostgreSQL", report.resources.fiveSecondPeaks.postgresql],
    ["Redis", report.resources.fiveSecondPeaks.redis],
    ["FeatBit nodes (3)", report.resources.fiveSecondPeaks.featbitNodes],
    ["loadgen nodes (10)", report.resources.fiveSecondPeaks.loadgenNodes],
  ]) {
    lines.push(
      `| ${name} | ${formatNumber(scope?.cpuMillicores)} | ` +
        `${formatNumber(scope?.memoryMiB)} |`,
    );
  }
  const oneSecond = report.resources.oneSecond;
  lines.push(
    "",
    "1 秒主机差分与 ELS cgroup：",
    "",
    "| 范围 | CPU p99 / max | CPU pressure p99 / max | run queue p99 / max | TCP retrans | packet drops |",
    "| --- | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const [name, pool] of [
    ["loadgen nodes", oneSecond?.loadgen],
    ["FeatBit nodes", oneSecond?.featbit],
  ]) {
    const drops =
      Number(pool?.eth0RxDrops ?? 0) +
      Number(pool?.eth0TxDrops ?? 0) +
      Number(pool?.ciliumRxDrops ?? 0) +
      Number(pool?.ciliumTxDrops ?? 0);
    lines.push(
      `| ${name} | ${formatNumber(pool?.cpuPercent?.p99)}% / ` +
        `${formatNumber(pool?.cpuPercent?.maximum)}% | ` +
        `${formatNumber(pool?.cpuPressurePercent?.p99)}% / ` +
        `${formatNumber(pool?.cpuPressurePercent?.maximum)}% | ` +
        `${formatNumber(pool?.runQueue?.p99)} / ` +
        `${formatNumber(pool?.runQueue?.maximum)} | ` +
        `${Number(pool?.tcpRetransSegments ?? 0)} | ${drops} |`,
    );
  }
  lines.push(
    "",
    `ELS cgroup CPU p99/max：${formatNumber(
      oneSecond?.els?.cpuMillicores?.p99,
    )}/${formatNumber(oneSecond?.els?.cpuMillicores?.maximum)} m；` +
      `throttled periods：${Number(
        oneSecond?.els?.throttledPeriods ?? 0,
      )}/${Number(oneSecond?.els?.cpuPeriods ?? 0)}；` +
      `throttled time：${formatNumber(
        oneSecond?.els?.throttledMilliseconds,
      )} ms。`,
    "",
    "完整分布是正式结果；`≤100ms` 去抖动视图只用于辅助诊断，没有替代或修改任何 gate。",
    "",
    "本轮是“10,000 总连接、100 target 环境连接”的新基线。由于单次变更 fan-out 从旧实验的 10,000 降为 100，不能直接描述为比旧 G5 更快或更慢。",
    "",
  );
  return `${lines.join("\n")}\n`;
}

function createHtml(report) {
  const rows = report.revisions
    .map(
      (revision) =>
        `<tr><td>${revision.revision}</td><td>${revision.probe_sync_latency_ms.count}</td>` +
        `<td>${formatNumber(revision.probe_sync_latency_ms.avg)}</td>` +
        `<td>${formatNumber(revision.probe_sync_latency_ms.p95)}</td>` +
        `<td>${formatNumber(revision.probe_sync_latency_ms.p99)}</td>` +
        `<td>${formatNumber(revision.probe_sync_latency_ms.max)}</td></tr>`,
    )
    .join("");
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${report.runId} multi-environment</title>
<style>body{font-family:system-ui;max-width:1100px;margin:40px auto;padding:0 20px;color:#172033}
.ok{color:#087f5b}.bad{color:#c92a2a}.cards{display:flex;gap:16px;flex-wrap:wrap}.card{border:1px solid #ddd;border-radius:10px;padding:16px;min-width:220px}
table{border-collapse:collapse;width:100%}th,td{border:1px solid #ddd;padding:8px;text-align:right}th:first-child,td:first-child{text-align:left}</style></head>
<body><h1>${report.runId}</h1><h2 class="${report.passed ? "ok" : "bad"}">${
    report.passed ? "PASS" : "FAIL"
  }</h2>
<div class="cards"><div class="card">背景健康<br><strong>${report.health.opened}/10,000</strong></div>
<div class="card">Target samples<br><strong>${report.formalDeliveryCount}/1,000</strong></div>
<div class="card">Cross-env<br><strong>${report.crossEnvironmentDeliveryCount}</strong></div>
<div class="card">Merged probe p99<br><strong>${formatNumber(
    report.metrics.probe_sync_latency_ms?.p99,
  )} ms</strong></div></div>
<h2>Revisions</h2><table><thead><tr><th>Revision</th><th>Count</th><th>Avg</th><th>p95</th><th>p99</th><th>Max</th></tr></thead><tbody>${rows}</tbody></table>
<p>100 samples/revision; p99 is dominated by roughly the two slowest observations. This is a 10,000-total / 100-target-connection baseline and is not directly faster/slower than the old 10,000-fan-out G5 result.</p></body></html>`;
}

function main() {
  const { runId, resultsDirectory } = parseArguments(process.argv.slice(2));
  const runDirectory = locateRunDirectory(resultsDirectory, runId);
  const metadata = readJson(requireFile(runDirectory, `${runId}-metadata.json`));
  const inventory = readJson(
    requireFile(runDirectory, `${runId}-multi-environment-inventory.json`),
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

  const runnerNodes = new Map();
  const escapedName = metadata.testRunName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  for (const pod of placement.pods ?? []) {
    const match = String(pod.name).match(new RegExp(`^${escapedName}-(\\d+)-`));
    if (match) runnerNodes.set(Number(match[1]), pod.node);
  }
  if (runnerNodes.size !== Number(metadata.parallelism)) {
    fail(`Expected ${metadata.parallelism} runner placements; found ${runnerNodes.size}.`);
  }
  const loadgenNodes = [...new Set(runnerNodes.values())].sort();
  if (loadgenNodes.length !== 10) {
    fail(`Expected ten loadgen nodes; found ${loadgenNodes.length}.`);
  }

  const environmentIds = inventory.environments.map((environment) => environment.id);
  const targetEnvironmentId = metadata.targetEnvironmentId;
  const measuredFlagKey = metadata.measuredProbeFlagKeys[0];
  const gates = [];
  gates.push(
    evaluateGate("10,000 ready distribution", () =>
      validateReadyDistribution(runnerEvents.ready, environmentIds, {
        parallelism: 20,
        connectionsPerRunner: 500,
        connectionsPerEnvironmentPerRunner: 5,
      }),
    ),
  );
  const warmRevisionEvents = runnerEvents.warmup.filter(
    (event) => event.phase === "revision",
  );
  const warmBaselineEvents = runnerEvents.warmup.filter(
    (event) => event.phase === "baseline",
  );
  gates.push(
    evaluateGate("target warm-up revision 100/100", () =>
      validateTargetDeliveryDistribution(warmRevisionEvents, {
        targetEnvironmentId,
        parallelism: 20,
        connectionsPerEnvironmentPerRunner: 5,
        label: "warm-up revision",
      }),
    ),
  );
  gates.push(
    evaluateGate("target warm-up baseline 100/100", () =>
      validateTargetDeliveryDistribution(warmBaselineEvents, {
        targetEnvironmentId,
        parallelism: 20,
        connectionsPerEnvironmentPerRunner: 5,
        label: "warm-up baseline",
      }),
    ),
  );
  gates.push(
    evaluateGate("cross-environment delivery zero", () => {
      if (runnerEvents.crossEnvironment.length !== 0) {
        fail(`found ${runnerEvents.crossEnvironment.length} cross-environment event(s)`);
      }
      return { count: 0 };
    }),
  );

  const writes = successfulControlWrites(controlRecords, metadata);
  gates.push(
    evaluateGate("controller ten writes", () => ({ count: writes.length })),
  );
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
    const observed = observerGroupForWrite(observerEvents, write, loadgenNodes);
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
        event.flagKey === measuredFlagKey &&
        event.revisionIndex === write.revisionIndex &&
        event.revision === write.revision,
    );
    gates.push(
      evaluateGate(`revision ${write.revisionIndex} target coverage 100/100`, () =>
        validateTargetDeliveryDistribution(applications, {
          targetEnvironmentId,
          parallelism: 20,
          connectionsPerEnvironmentPerRunner: 5,
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
      const runnerValues = applications
        .filter((event) => event.runnerIndex === runner)
        .map((event) => event.atUnixMs - firstObservedAtUnixMs);
      runnerDiagnostics.push({
        runner,
        count: runnerValues.length,
        values: runnerValues,
        avg:
          runnerValues.length > 0
            ? runnerValues.reduce((sum, value) => sum + value, 0) /
              runnerValues.length
            : null,
        max: runnerValues.length > 0 ? Math.max(...runnerValues) : null,
      });
    }
    revisions.push({
      revisionIndex: write.revisionIndex,
      revision: write.revision,
      environmentId: targetEnvironmentId,
      flagKey: measuredFlagKey,
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
    evaluateGate("Redis observer 10 x 10 matches", () => {
      if (observerMatchedEventCount !== 100) {
        fail(`matched ${observerMatchedEventCount}, expected 100`);
      }
      return { count: observerMatchedEventCount, nodes: loadgenNodes.length };
    }),
  );

  const healthGate = evaluateGate("connection and protocol health", () => {
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
      failures.push("one or more connection health rates contain failures");
    }
    if (failures.length > 0) fail(failures.join("; "));
    return { opened: 10_000, fullSync: 10_000, ready: 10_000, survived: 10_000 };
  });
  gates.push(healthGate);
  gates.push(
    evaluateGate("warm-up metrics 100/100 and 200 deliveries", () => {
      if (
        health.warmupCoverage.passes !== 100 ||
        health.warmupCoverage.fails !== 0 ||
        health.warmupPatchDeliveries !== 200
      ) {
        fail(
          `coverage=${health.warmupCoverage.passes}/${health.warmupCoverage.fails}, ` +
            `deliveries=${health.warmupPatchDeliveries}`,
        );
      }
      return { coverage: 100, deliveries: 200 };
    }),
  );
  gates.push(
    evaluateGate("formal metrics 1,000/1,000 and final 100/100", () => {
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
        deliveries !== 1_000 ||
        coveragePasses !== 1_000 ||
        coverageFails !== 0 ||
        health.finalRevisionCorrectness.passes !== 100 ||
        health.finalRevisionCorrectness.fails !== 0
      ) {
        fail(
          `deliveries=${deliveries}, coverage=${coveragePasses}/${coverageFails}, ` +
            `final=${health.finalRevisionCorrectness.passes}/` +
            `${health.finalRevisionCorrectness.fails}`,
        );
      }
      return { deliveries, coverage: coveragePasses, final: 100 };
    }),
  );
  gates.push(
    evaluateGate("background isolation metrics 9,900/9,900", () => {
      if (
        health.backgroundConnectionsChecked !== 9_900 ||
        health.backgroundIsolation.passes !== 9_900 ||
        health.backgroundIsolation.fails !== 0
      ) {
        fail(
          `checked=${health.backgroundConnectionsChecked}, ` +
            `passed=${health.backgroundIsolation.passes}, ` +
            `failed=${health.backgroundIsolation.fails}`,
        );
      }
      return { checked: 9_900, passed: 9_900 };
    }),
  );

  const resourceSummaryPath = requireFile(
    runDirectory,
    `${runId}-resource-summary.json`,
  );
  const resourceSummary = readJson(resourceSummaryPath);
  const elsConfiguration = validateElsEvidence(
    readJson(requireFile(runDirectory, `${runId}-els-deployment.json`)),
    readJson(requireFile(runDirectory, `${runId}-els-pods.json`)),
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
    evaluateGate("ELS fixed resources and one-Pod-per-node spreading", () =>
      elsConfiguration,
    ),
  );
  gates.push(
    evaluateGate("5-second and 1-second resource evidence complete", () => {
      if (resourceSummary.complete !== true) {
        fail("5-second resource monitor is incomplete");
      }
      if (!oneSecondEvidence) {
        fail("1-second node evidence report is missing");
      }
      if (
        Number(oneSecondEvidence.evidence?.nodeFiles) !== 13 ||
        Number(oneSecondEvidence.evidence?.metadataFiles) !== 13
      ) {
        fail("1-second evidence does not contain 13 node and metadata files");
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
      "10,000 total connections across 100 environments; 100 target-environment connections",
    comparisonBoundary:
      "Not directly faster or slower than the old single-environment G5 result because measured fan-out changed from 10,000 to 100 connections.",
    statisticalLimit:
      "Each revision has 100 samples; interpolated p99 is dominated by roughly the two slowest observations. Runner cohorts contain only five samples per revision and are diagnostic only.",
    topology: {
      environments: 100,
      flagsPerEnvironment: 20,
      parallelism: 20,
      connectionsPerRunner: 500,
      connectionsPerEnvironmentPerRunner: 5,
      connectionsPerEnvironment: 100,
      totalConnections: 10_000,
      targetEnvironmentId,
      targetEnvironmentKey: metadata.targetEnvironmentKey,
      measuredFlagKey,
      postRampWarmupFlagKey: metadata.postRampWarmupFlagKey,
      loadgenNodes,
    },
    health,
    formalDeliveryCount: runnerEvents.apply.filter(
      (event) =>
        event.environmentId === targetEnvironmentId &&
        event.flagKey === measuredFlagKey,
    ).length,
    crossEnvironmentDeliveryCount: runnerEvents.crossEnvironment.length,
    controller: {
      successfulFormalWrites: writes.length,
      revisionStartIntervalsMs: intervals,
      apiResponseLatencyMs: safeStats(
        writes.map((write) => write.requestEndedAtUnixMs - write.atUnixMs),
      ),
    },
    observer: {
      nodeCount: loadgenNodes.length,
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
      const values = revisions.flatMap((revision) =>
        revision.runnerDiagnostics
          .filter((entry) => entry.runner === runner)
          .flatMap((entry) => entry.values),
      );
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

  const jsonPath = path.join(runDirectory, `${runId}-multi-environment-analysis.json`);
  const markdownPath = path.join(
    runDirectory,
    `${runId}-multi-environment-analysis.md`,
  );
  const htmlPath = path.join(runDirectory, `${runId}-multi-environment-analysis.html`);
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
      metrics: report.metrics,
    })}\n`,
  );
  if (!passed) process.exitCode = 2;
}

try {
  main();
} catch (error) {
  process.stderr.write(`Multi-environment analysis failed: ${error.message}\n`);
  process.exitCode = 1;
}
