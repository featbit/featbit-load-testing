import fs from "node:fs";
import path from "node:path";
import process from "node:process";

import {
  rollUpDistributedTrends,
  scalarStats,
  shiftTrend,
} from "../../k6/lib/stage-latency.js";

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
  if (!values["run-id"]) {
    fail("--run-id is required.");
  }
  if (!values["results-directory"]) {
    fail("--results-directory is required.");
  }
  return {
    runId: values["run-id"],
    resultsDirectory: path.resolve(values["results-directory"]),
  };
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function requireFile(directory, fileName) {
  const filePath = path.join(directory, fileName);
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    fail(`Required evidence file does not exist: ${filePath}`);
  }
  return filePath;
}

function locateRunDirectory(resultsDirectory, runId) {
  const archive = path.join(resultsDirectory, runId);
  if (fs.existsSync(archive) && fs.statSync(archive).isDirectory()) {
    return archive;
  }
  return resultsDirectory;
}

function extractServedRevision(flag) {
  if (!flag || typeof flag !== "object") {
    fail("Redis publication payload is not an object.");
  }
  const selectedId = flag.isEnabled
    ? flag.fallthrough?.variations?.[0]?.id
    : flag.disabledVariationId;
  const variation = flag.variations?.find((candidate) => candidate?.id === selectedId);
  if (!variation || typeof variation.value !== "string") {
    fail(`Cannot resolve served variation for flag '${flag.key ?? "<unknown>"}'.`);
  }
  return variation.value;
}

function parseObserverEvents(filePath) {
  return fs
    .readFileSync(filePath, "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line, index) => {
      let record;
      try {
        record = JSON.parse(line);
      } catch (error) {
        fail(`Invalid observer JSONL at line ${index + 1}: ${error.message}`);
      }
      const updatedAtMs = Date.parse(record.payload?.updatedAt);
      if (!Number.isFinite(updatedAtMs)) {
        fail(`Observer event ${index + 1} has no valid payload.updatedAt.`);
      }
      return {
        ...record,
        key: record.payload?.key,
        revision: extractServedRevision(record.payload),
        updatedAt: record.payload.updatedAt,
        updatedAtMs,
        observedAtUnixMs: Number(record.observedAtUnixMs),
      };
    });
}

function parseControlEvents(logText, runId) {
  const expression =
    /STREAM_CONTROL\|1\|(request_start|request_end|request_error)\|(\d+)\|([^|]+)\|(\d+)\|([^|]+)\|([^|]+)\|(\d+)/g;
  const events = [];
  for (const match of logText.matchAll(expression)) {
    if (match[3] !== runId) {
      continue;
    }
    events.push({
      event: match[1],
      atUnixMs: Number(match[2]),
      runId: match[3],
      revisionIndex: Number(match[4]),
      revision: match[5],
      flagKey: match[6],
      attempt: Number(match[7]),
    });
  }
  if (events.length === 0) {
    fail("No STREAM_CONTROL timing markers were found in runner 1 log.");
  }
  return events;
}

function successfulControlWrites(events) {
  const groups = new Map();
  for (const event of events) {
    const key = [
      event.revisionIndex,
      event.revision,
      event.flagKey,
      event.attempt,
    ].join("|");
    const group = groups.get(key) ?? {};
    group[event.event] = event;
    groups.set(key, group);
  }

  const successful = [];
  for (const group of groups.values()) {
    if (group.request_start && group.request_end && !group.request_error) {
      successful.push({
        ...group.request_start,
        requestEndedAtUnixMs: group.request_end.atUnixMs,
      });
    }
  }
  successful.sort((left, right) => left.revisionIndex - right.revisionIndex);
  if (successful.length === 0) {
    fail("No successful measured control writes were found.");
  }
  const indexes = successful.map((event) => event.revisionIndex);
  const expected = Array.from({ length: indexes.length }, (_, index) => index + 1);
  if (JSON.stringify(indexes) !== JSON.stringify(expected)) {
    fail(`Measured revision indexes are not contiguous: ${indexes.join(", ")}.`);
  }
  return successful;
}

function metric(summary, name) {
  const value = summary.metrics?.[name];
  if (!value) {
    fail(`Runner summary is missing '${name}'.`);
  }
  return value;
}

function formatMs(value) {
  return `${Number(value).toFixed(2)} ms`;
}

function formatRange(range) {
  return `${formatMs(range.min)}–${formatMs(range.max)}`;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function metricTableRow(name, semantic, rollup) {
  return `| \`${name}\` | ${semantic} | ${rollup.count} | ${formatMs(
    rollup.avg,
  )} | ${formatMs(rollup.min)} / ${formatMs(rollup.max)} | ${formatRange(
    rollup.p95,
  )} | ${formatRange(rollup.p99)} |`;
}

function createMarkdown(report) {
  const lines = [
    `# ${report.runId} 三阶段延迟验证`,
    "",
    "## 结论",
    "",
    "- `probe_sync_latency_ms` 现在表示 `streaming_delivery_latency_ms`，起点是 10 个 loadgen observer 中最早看到 Redis 发布的时间，终点是 SDK 连接应用变更。",
    "- `end_to_end_latency_ms = control_plane_write_latency_ms + probe_sync_latency_ms`。",
    "- FeatBit API、ELS 与 FeatBit 源码均未修改；计时来自 load-test controller 日志和只读 Redis SUBSCRIBE observer。",
    "",
    "## 三项延迟",
    "",
    "| 指标 | 口径 | 样本 | 平均 | min / max | runner × revision p95 | runner × revision p99 |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: |",
    metricTableRow(
      "end_to_end_latency_ms",
      "PUT 发起 → SDK 应用变更",
      report.metrics.end_to_end_latency_ms,
    ),
    `| \`control_plane_write_latency_ms\` | PUT 发起 → 10 个 observer 中最早看到 Redis 发布 | ${
      report.metrics.control_plane_write_latency_ms.count
    } | ${formatMs(report.metrics.control_plane_write_latency_ms.avg)} | ${formatMs(
      report.metrics.control_plane_write_latency_ms.min,
    )} / ${formatMs(report.metrics.control_plane_write_latency_ms.max)} | ${formatMs(
      report.metrics.control_plane_write_latency_ms.p95,
    )} | ${formatMs(report.metrics.control_plane_write_latency_ms.p99)} |`,
    metricTableRow(
      "probe_sync_latency_ms",
      "最早 Redis 发布旁路可见 → SDK 应用变更",
      report.metrics.probe_sync_latency_ms,
    ),
    "",
    "## Revision 明细",
    "",
    "| Revision | control-plane | streaming avg | streaming runner p95 | streaming runner p99 | end-to-end avg | Redis observer 到达跨度 |",
    "| ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ];

  for (const revision of report.revisions) {
    lines.push(
      `| ${revision.revisionIndex} (\`${revision.revision}\`) | ${formatMs(
        revision.controlPlaneWriteMs,
      )} | ${formatMs(revision.streaming.avg)} | ${formatRange(
        revision.streaming.p95,
      )} | ${formatRange(revision.streaming.p99)} | ${formatMs(
        revision.endToEnd.avg,
      )} | ${formatMs(revision.observerArrivalSpreadMs)} |`,
    );
  }

  lines.push(
    "",
    "## 测量边界与误差",
    "",
    `- observer：${report.observer.podCount} Pods / ${report.observer.nodeCount} loadgen nodes，共匹配 ${report.observer.matchedEventCount} 条正式事件。`,
    `- 每次发布在各节点 observer 的到达时间跨度：median ${formatMs(
      report.observer.arrivalSpreadMs.med,
    )}，p95 ${formatMs(report.observer.arrivalSpreadMs.p95)}，max ${formatMs(
      report.observer.arrivalSpreadMs.max,
    )}。它同时包含节点时钟偏差和 Redis→observer 网络差异，是本方法的保守不确定性提示。`,
    "- `probe_sync_latency_ms` 按 runner × revision cohort 的趋势整体平移；count、avg、min/max 以及每个 runner 的 percentile 平移是精确的。分布式 runner 之间无法仅靠摘要精确合并全局 percentile，因此报告展示 runner 范围。",
    "- 最早 observer 收到消息仍比 Redis 服务端执行 PUBLISH 晚一个很小的网络/调度间隔，所以该值可能轻微低估真正的 Redis PUBLISH→SDK 延迟。",
    "- 该算法假设 AKS 节点时钟已由平台同步；observer 到达跨度作为时钟偏差与订阅调度差异的合并不确定性提示。",
    "- 本轮最小值为 -2 ms，不是物理上的负延迟，而是毫秒取整、跨节点时钟与旁路边界误差的直接证据。因此本轮用于初步验证拆分口径；平均值和尾百分位可读，亚毫秒/低个位毫秒不能作精确归因。",
    "",
  );
  return `${lines.join("\n")}\n`;
}

function createHtml(report) {
  const rows = report.revisions
    .map(
      (revision) => `<tr><td>${revision.revisionIndex}</td><td>${escapeHtml(
        revision.revision,
      )}</td><td>${formatMs(revision.controlPlaneWriteMs)}</td><td>${formatMs(
        revision.streaming.avg,
      )}</td><td>${escapeHtml(formatRange(revision.streaming.p95))}</td><td>${escapeHtml(
        formatRange(revision.streaming.p99),
      )}</td><td>${formatMs(revision.endToEnd.avg)}</td></tr>`,
    )
    .join("\n");
  const streaming = report.metrics.probe_sync_latency_ms;
  const endToEnd = report.metrics.end_to_end_latency_ms;
  const control = report.metrics.control_plane_write_latency_ms;
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(report.runId)} 三阶段延迟</title>
<style>
body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;max-width:1180px;margin:40px auto;padding:0 24px;color:#172033;background:#f7f9fc}
h1,h2{color:#102a43}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:16px}
.card{background:#fff;border:1px solid #d9e2ec;border-radius:12px;padding:20px;box-shadow:0 4px 14px #102a4310}
.value{font-size:30px;font-weight:700;color:#087f5b}.label{font-size:14px;color:#52667a}.detail{margin-top:8px;color:#334e68}
table{width:100%;border-collapse:collapse;background:#fff}th,td{padding:10px;border:1px solid #d9e2ec;text-align:right}
th:first-child,td:first-child,th:nth-child(2),td:nth-child(2){text-align:left}code{background:#e9f2ff;padding:2px 5px;border-radius:4px}
.note{background:#fff4e6;border-left:4px solid #f08c00;padding:14px 18px}
</style>
</head>
<body>
<h1>${escapeHtml(report.runId)} 三阶段延迟验证</h1>
<p><code>probe_sync_latency_ms</code> = <code>streaming_delivery_latency_ms</code></p>
<div class="cards">
<div class="card"><div class="label">端到端平均</div><div class="value">${formatMs(
    endToEnd.avg,
  )}</div><div class="detail">runner × revision p99 ${escapeHtml(formatRange(endToEnd.p99))}</div></div>
<div class="card"><div class="label">控制面写入平均</div><div class="value">${formatMs(
    control.avg,
  )}</div><div class="detail">p95 ${formatMs(control.p95)} / p99 ${formatMs(
    control.p99,
  )}</div></div>
<div class="card"><div class="label">Streaming 投递平均（canonical probe_sync）</div><div class="value">${formatMs(
    streaming.avg,
  )}</div><div class="detail">runner × revision p95 ${escapeHtml(
    formatRange(streaming.p95),
  )} / p99 ${escapeHtml(formatRange(streaming.p99))}</div></div>
</div>
<h2>Revision 明细</h2>
<table><thead><tr><th>#</th><th>Revision</th><th>Control plane</th><th>Streaming avg</th><th>Streaming p95</th><th>Streaming p99</th><th>End-to-end avg</th></tr></thead>
<tbody>${rows}</tbody></table>
<h2>测量说明</h2>
<div class="note">报告使用 10 个 Redis SUBSCRIBE observer 中最早的到达时间近似 PUBLISH 边界。该边界避免把数据库、revision 写入和 API 前置处理计入 <code>probe_sync_latency_ms</code>；最早 observer 自身的网络/调度间隔会让 Streaming 结果有轻微低估。本轮 -2 ms 最小值表示约 2 ms 的时钟/边界误差，不表示真实负延迟。</div>
</body>
</html>
`;
}

function main() {
  const { runId, resultsDirectory } = parseArguments(process.argv.slice(2));
  const runDirectory = locateRunDirectory(resultsDirectory, runId);
  const metadata = readJson(requireFile(runDirectory, `${runId}-metadata.json`));
  const placement = readJson(
    requireFile(runDirectory, `${runId}-runner-placement.json`),
  );
  const observerEvents = parseObserverEvents(
    requireFile(runDirectory, `${runId}-stream-timing-events.jsonl`),
  );
  const observerPods = readJson(
    requireFile(runDirectory, `${runId}-stream-timing-pods.json`),
  ).items;
  const testRunName = metadata.testRunName ?? `featbit-${runId}`;
  const controllerLogPath = requireFile(runDirectory, `${testRunName}-1.log`);
  const controlWrites = successfulControlWrites(
    parseControlEvents(fs.readFileSync(controllerLogPath, "utf8"), runId),
  );

  const runnerNodes = new Map();
  for (const pod of placement.pods ?? []) {
    const match = String(pod.name).match(
      new RegExp(`^${testRunName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}-(\\d+)-`),
    );
    if (match) {
      runnerNodes.set(Number(match[1]), pod.node);
    }
  }
  if (runnerNodes.size !== Number(metadata.parallelism)) {
    fail(
      `Expected ${metadata.parallelism} runner placements; found ${runnerNodes.size}.`,
    );
  }
  const controllerNode = runnerNodes.get(1);
  if (!controllerNode) {
    fail("Runner 1 placement is missing.");
  }

  const observedNodes = [...new Set(observerEvents.map((event) => event.node))].sort();
  const expectedNodes = [...new Set(runnerNodes.values())].sort();
  if (JSON.stringify(observedNodes) !== JSON.stringify(expectedNodes)) {
    fail("Observer nodes do not exactly match runner nodes.");
  }

  const summaries = [];
  const summaryExpression = new RegExp(
    `^${testRunName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}-(\\d+)-[a-z0-9]+-summary\\.json$`,
  );
  for (const fileName of fs.readdirSync(runDirectory)) {
    const match = fileName.match(summaryExpression);
    if (match) {
      summaries.push({
        runner: Number(match[1]),
        summary: readJson(path.join(runDirectory, fileName)),
      });
    }
  }
  summaries.sort((left, right) => left.runner - right.runner);
  if (summaries.length !== Number(metadata.parallelism)) {
    fail(`Expected ${metadata.parallelism} summaries; found ${summaries.length}.`);
  }

  const revisionReports = [];
  const streamingTrends = [];
  const endToEndTrends = [];
  const rawTrends = [];
  const controlPlaneValues = [];
  const arrivalSpreads = [];
  let matchedEventCount = 0;

  for (const write of controlWrites) {
    const controllerCandidates = observerEvents.filter(
      (event) =>
        event.node === controllerNode &&
        event.key === write.flagKey &&
        event.revision === write.revision &&
        event.observedAtUnixMs >= write.atUnixMs - 500 &&
        event.observedAtUnixMs <= write.requestEndedAtUnixMs + 5_000,
    );
    if (controllerCandidates.length !== 1) {
      fail(
        `Revision ${write.revisionIndex} expected one controller-node publication; found ${controllerCandidates.length}.`,
      );
    }
    const controllerPublication = controllerCandidates[0];
    const revisionEvents = observerEvents.filter(
      (event) =>
        event.key === write.flagKey &&
        event.revision === write.revision &&
        event.updatedAt === controllerPublication.updatedAt,
    );
    if (revisionEvents.length !== expectedNodes.length) {
      fail(
        `Revision ${write.revisionIndex} expected ${expectedNodes.length} node events; found ${revisionEvents.length}.`,
      );
    }
    const eventByNode = new Map(revisionEvents.map((event) => [event.node, event]));
    if (eventByNode.size !== expectedNodes.length) {
      fail(`Revision ${write.revisionIndex} contains duplicate observer node events.`);
    }
    matchedEventCount += revisionEvents.length;

    const publicationObservedAtUnixMs = Math.min(
      ...revisionEvents.map((event) => event.observedAtUnixMs),
    );
    const controlPlaneWriteMs =
      publicationObservedAtUnixMs - write.atUnixMs;
    if (controlPlaneWriteMs < 0) {
      fail(`Revision ${write.revisionIndex} has a negative control-plane duration.`);
    }
    controlPlaneValues.push(controlPlaneWriteMs);

    const observedTimes = revisionEvents.map((event) => event.observedAtUnixMs);
    const observerArrivalSpreadMs = Math.max(...observedTimes) - Math.min(...observedTimes);
    arrivalSpreads.push(observerArrivalSpreadMs);

    const revisionStreaming = [];
    const revisionEndToEnd = [];
    const revisionRaw = [];
    for (const { runner, summary } of summaries) {
      const node = runnerNodes.get(runner);
      if (!eventByNode.has(node)) {
        fail(`Revision ${write.revisionIndex} has no observer event for runner ${runner}.`);
      }
      const raw = metric(
        summary,
        `probe_updated_at_to_sdk_latency_ms{revision_index:${write.revisionIndex}}`,
      );
      const updatedAtToObserverMs =
        publicationObservedAtUnixMs - controllerPublication.updatedAtMs;
      const streaming = shiftTrend(raw, -updatedAtToObserverMs);
      const endToEnd = shiftTrend(streaming, controlPlaneWriteMs);
      revisionRaw.push(raw);
      revisionStreaming.push(streaming);
      revisionEndToEnd.push(endToEnd);
      rawTrends.push(raw);
      streamingTrends.push(streaming);
      endToEndTrends.push(endToEnd);
    }

    revisionReports.push({
      revisionIndex: write.revisionIndex,
      revision: write.revision,
      flagKey: write.flagKey,
      updatedAt: controllerPublication.updatedAt,
      controllerRequestStartedAtUnixMs: write.atUnixMs,
      controllerRequestEndedAtUnixMs: write.requestEndedAtUnixMs,
      controllerApiResponseMs: write.requestEndedAtUnixMs - write.atUnixMs,
      redisObservedAtControllerNodeUnixMs: controllerPublication.observedAtUnixMs,
      redisFirstObservedAtUnixMs: publicationObservedAtUnixMs,
      controlPlaneWriteMs,
      observerArrivalSpreadMs,
      rawUpdatedAtToSdk: rollUpDistributedTrends(revisionRaw),
      streaming: rollUpDistributedTrends(revisionStreaming),
      endToEnd: rollUpDistributedTrends(revisionEndToEnd),
    });
  }

  const report = {
    schemaVersion: 1,
    runId,
    generatedAtUtc: new Date().toISOString(),
    validationStatus:
      "preliminary: canonical averages and runner percentiles are usable; values near zero carry approximately 2 ms boundary/clock uncertainty",
    definitions: {
      end_to_end_latency_ms: "controller PUT request start -> SDK applies revision",
      control_plane_write_latency_ms:
        "controller PUT request start -> earliest Redis publication observation across loadgen nodes",
      probe_sync_latency_ms:
        "earliest Redis publication observation across loadgen nodes -> SDK applies revision",
      probe_sync_alias: "streaming_delivery_latency_ms",
      raw_metric: "probe_updated_at_to_sdk_latency_ms",
      distributed_percentiles:
        "min-max range across runner x revision cohorts; not a merged global percentile",
    },
    equation:
      "end_to_end_latency_ms = control_plane_write_latency_ms + probe_sync_latency_ms",
    metrics: {
      end_to_end_latency_ms: rollUpDistributedTrends(endToEndTrends),
      control_plane_write_latency_ms: scalarStats(controlPlaneValues),
      probe_sync_latency_ms: rollUpDistributedTrends(streamingTrends),
      streaming_delivery_latency_ms: rollUpDistributedTrends(streamingTrends),
      probe_updated_at_to_sdk_latency_ms: rollUpDistributedTrends(rawTrends),
    },
    observer: {
      boundary: "Earliest Redis publication observation across ten loadgen nodes",
      clockAssumption: "AKS node clocks are platform-synchronized",
      podCount: observerPods.length,
      nodeCount: observedNodes.length,
      matchedEventCount,
      arrivalSpreadMs: scalarStats(arrivalSpreads),
      caveat:
        "The earliest subscriber receive follows Redis PUBLISH by a small network/scheduling interval and can slightly understate streaming delivery.",
    },
    topology: {
      parallelism: Number(metadata.parallelism),
      runnersPerNode: Number(metadata.runnersPerNode),
      connections: Number(metadata.parameters?.MaxConnections),
      connectionsPerSecond: Number(metadata.parameters?.ConnectionsPerSecond),
      controllerNode,
      loadgenNodes: expectedNodes,
    },
    revisions: revisionReports,
  };

  const jsonPath = path.join(runDirectory, `${runId}-stage-latency.json`);
  const markdownPath = path.join(runDirectory, `${runId}-stage-latency.md`);
  const htmlPath = path.join(runDirectory, `${runId}-stage-latency.html`);
  fs.writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`);
  fs.writeFileSync(markdownPath, createMarkdown(report));
  fs.writeFileSync(htmlPath, createHtml(report));

  process.stdout.write(
    `${JSON.stringify({
      runId,
      runDirectory,
      jsonPath,
      markdownPath,
      htmlPath,
      metrics: report.metrics,
    })}\n`,
  );
}

try {
  main();
} catch (error) {
  process.stderr.write(`Stage latency analysis failed: ${error.message}\n`);
  process.exitCode = 1;
}
