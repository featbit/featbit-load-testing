import fs from "node:fs";
import path from "node:path";
import process from "node:process";

function fail(message) {
  throw new Error(message);
}

function parseArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      fail(`Invalid argument list near '${key ?? "<end>"}'.`);
    }
    values[key.slice(2)] = value;
  }
  const runIds = String(values["run-ids"] ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  if (
    !values["results-directory"] ||
    !values["output-directory"] ||
    !values["output-name"] ||
    runIds.length !== 4
  ) {
    fail(
      "--results-directory, --output-directory, --output-name, and exactly " +
        "four comma-separated --run-ids are required.",
    );
  }
  return {
    resultsDirectory: path.resolve(values["results-directory"]),
    outputDirectory: path.resolve(values["output-directory"]),
    outputName: values["output-name"],
    runIds,
  };
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) fail(`Required file does not exist: ${filePath}`);
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function number(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed.toFixed(2) : "—";
}

function packetDrops(scope) {
  return [
    "tcpInErrors",
    "listenDrops",
    "backlogDrops",
    "receiveQueueDrops",
    "eth0RxErrors",
    "eth0RxDrops",
    "eth0TxErrors",
    "eth0TxDrops",
    "ciliumRxErrors",
    "ciliumRxDrops",
    "ciliumTxErrors",
    "ciliumTxDrops",
  ].reduce((total, key) => total + Number(scope?.[key] ?? 0), 0);
}

function loadAnalysis(resultsDirectory, runId) {
  const filePath = path.join(
    resultsDirectory,
    runId,
    `${runId}-multi-environment-analysis.json`,
  );
  const analysis = readJson(filePath);
  if (analysis.runId !== runId) fail(`Analysis run ID mismatch in ${filePath}.`);
  return analysis;
}

function loadBaselineRestore(resultsDirectory, runId) {
  const filePath = path.join(
    resultsDirectory,
    runId,
    `${runId}-restore.log`,
  );
  if (!fs.existsSync(filePath)) {
    fail(`Post-run baseline restore evidence does not exist: ${filePath}`);
  }
  const contents = fs.readFileSync(filePath, "utf8");
  const matches = [
    ...contents.matchAll(
      /STREAM_CONTROLLER_RESULT\|1\|[^|\r\n]+\|[^|\r\n]+\|[^|\r\n]+\|post-run-baseline\|baseline\|(changed|unchanged)/g,
    ),
  ];
  if (matches.length !== 1) {
    fail(
      `Expected exactly one post-run baseline restore result in ${filePath}; ` +
        `found ${matches.length}.`,
    );
  }
  return {
    confirmed: true,
    outcome: matches[0][1],
    evidenceFile: path.basename(filePath),
  };
}

function createMarkdown(report) {
  const lines = [
    "# AKS Server SDK 多环境 WebSocket 基线",
    "",
    `状态：**${report.passed ? "PASS" : "FAIL"}**。`,
    "",
    "## 实验边界",
    "",
    "- 总背景负载：10,000 条 Server SDK WebSocket。",
    "- 100 个 environments，每环境 20 个 flags、100 条连接。",
    "- 20 runners，每 runner 对每环境 5 条连接。",
    "- 只有 target environment 的 100 条连接接收正式 flag-01 revisions。",
    "- 每轮 10 revisions × 100 target connections = 1,000 条正式原始样本。",
    "",
    "这是“10,000 总连接、100 target 环境连接”的新基线。旧 G5 是一次变更 fan-out 到 10,000 条连接；本实验只 fan-out 到 100 条，因此不能把两者直接描述为更快或更慢。",
    "",
    "## 四轮 gate 与连接健康",
    "",
    "| run | kind | status | opened | full sync | ready | survived | warm-up | formal | cross-env | baseline restored |",
    "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
  ];
  for (const run of report.runs) {
    lines.push(
      `| ${run.runId} | ${run.runKind} | ${run.passed ? "PASS" : "FAIL"} | ` +
        `${run.health.opened}/10000 | ${run.health.fullSync}/10000 | ` +
        `${run.health.readyBeforeHold.passes}/10000 | ` +
        `${run.health.survived.passes}/10000 | ` +
        `${run.health.warmupPatchDeliveries}/200 | ` +
        `${run.formalDeliveryCount}/1000 | ` +
        `${run.crossEnvironmentDeliveryCount} | ` +
        `${run.postRunBaseline.confirmed ? "PASS" : "FAIL"} |`,
    );
  }
  lines.push(
    "",
    "## 每轮合并 1,000 条 target 样本",
    "",
    "| run | metric | count | avg | p50 | p90 | p95 | p99 | max |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const run of report.runs) {
    for (const metricName of [
      "end_to_end_latency_ms",
      "control_plane_write_latency_ms",
      "probe_sync_latency_ms",
    ]) {
      const stats = run.metrics[metricName];
      lines.push(
        `| ${run.runId} | ${metricName} | ${stats?.count ?? 0} | ` +
          `${number(stats?.avg)} | ${number(stats?.p50)} | ${number(
            stats?.p90,
          )} | ${number(stats?.p95)} | ${number(stats?.p99)} | ` +
          `${number(stats?.max)} |`,
      );
    }
    const filtered = run.deJittered.probe_sync_latency_ms;
    lines.push(
      `| ${run.runId} | probe_sync_latency_ms ≤100ms（辅助） | ` +
        `${filtered?.count ?? 0} | ${number(filtered?.avg)} | ` +
        `${number(filtered?.p50)} | ${number(filtered?.p90)} | ` +
        `${number(filtered?.p95)} | ${number(filtered?.p99)} | ` +
        `${number(filtered?.max)} |`,
    );
  }
  lines.push(
    "",
    "> 完整原始分布是正式结果；≤100 ms 去抖动视图只用于辅助诊断。每 revision 只有 100 个样本，插值 p99 主要受最慢约两个观测影响。每 runner×revision 只有 5 个样本，其 percentile 不作为主结论。",
  );
  for (const run of report.runs) {
    lines.push(
      "",
      `## ${run.runId}：每 revision 100 条样本`,
      "",
      "| revision | count | probe avg | p50 | p90 | p95 | p99 | max | control | end-to-end avg |",
      "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    );
    for (const revision of run.revisions) {
      const probe = revision.probe_sync_latency_ms;
      lines.push(
        `| ${revision.revision} | ${probe.count} | ${number(probe.avg)} | ` +
          `${number(probe.p50)} | ${number(probe.p90)} | ` +
          `${number(probe.p95)} | ${number(probe.p99)} | ` +
          `${number(probe.max)} | ${number(revision.controlPlaneWriteMs)} | ` +
          `${number(revision.end_to_end_latency_ms.avg)} |`,
      );
    }
  }
  lines.push(
    "",
    "## 资源证据",
    "",
    "5 秒 Kubernetes 峰值为同一采样点内该范围的合计值：",
    "",
    "| run | ELS CPU/memory | runners CPU/memory | API CPU/memory | UI CPU/memory | PostgreSQL CPU/memory | Redis CPU/memory | FeatBit nodes CPU/memory | loadgen nodes CPU/memory |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const run of report.runs) {
    const five = run.resources.fiveSecondPeaks;
    lines.push(
      `| ${run.runId} | ${number(five.els.cpuMillicores)}m / ` +
        `${number(five.els.memoryMiB)}MiB | ` +
        `${number(five.runners.cpuMillicores)}m / ` +
        `${number(five.runners.memoryMiB)}MiB | ` +
        `${number(five.api.cpuMillicores)}m / ` +
        `${number(five.api.memoryMiB)}MiB | ` +
        `${number(five.ui.cpuMillicores)}m / ` +
        `${number(five.ui.memoryMiB)}MiB | ` +
        `${number(five.postgresql.cpuMillicores)}m / ` +
        `${number(five.postgresql.memoryMiB)}MiB | ` +
        `${number(five.redis.cpuMillicores)}m / ` +
        `${number(five.redis.memoryMiB)}MiB | ` +
        `${number(five.featbitNodes.cpuMillicores)}m / ` +
        `${number(five.featbitNodes.memoryMiB)}MiB | ` +
        `${number(five.loadgenNodes.cpuMillicores)}m / ` +
        `${number(five.loadgenNodes.memoryMiB)}MiB |`,
    );
  }
  lines.push(
    "",
    "1 秒 loadgen 主机差分：",
    "",
    "| run | CPU p99/max | CPU pressure p99/max | run queue p99/max | softirq CPU p99/max | TCP retrans | packet drops |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const run of report.runs) {
    const loadgen = run.resources.oneSecond.loadgen;
    lines.push(
      `| ${run.runId} | ${number(loadgen.cpuPercent.p99)}% / ` +
        `${number(loadgen.cpuPercent.maximum)}% | ` +
        `${number(loadgen.cpuPressurePercent.p99)}% / ` +
        `${number(loadgen.cpuPressurePercent.maximum)}% | ` +
        `${number(loadgen.runQueue.p99)} / ` +
        `${number(loadgen.runQueue.maximum)} | ` +
        `${number(loadgen.softirqCpuPercent.p99)}% / ` +
        `${number(loadgen.softirqCpuPercent.maximum)}% | ` +
        `${loadgen.tcpRetransSegments} | ${packetDrops(loadgen)} |`,
    );
  }
  lines.push(
    "",
    "1 秒 FeatBit 主机差分：",
    "",
    "| run | CPU p99/max | CPU pressure p99/max | run queue p99/max | softirq CPU p99/max | TCP retrans | packet drops |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const run of report.runs) {
    const featbit = run.resources.oneSecond.featbit;
    lines.push(
      `| ${run.runId} | ${number(featbit.cpuPercent.p99)}% / ` +
        `${number(featbit.cpuPercent.maximum)}% | ` +
        `${number(featbit.cpuPressurePercent.p99)}% / ` +
        `${number(featbit.cpuPressurePercent.maximum)}% | ` +
        `${number(featbit.runQueue.p99)} / ` +
        `${number(featbit.runQueue.maximum)} | ` +
        `${number(featbit.softirqCpuPercent.p99)}% / ` +
        `${number(featbit.softirqCpuPercent.maximum)}% | ` +
        `${featbit.tcpRetransSegments} | ${packetDrops(featbit)} |`,
    );
  }
  lines.push(
    "",
    "1 秒 ELS cgroup：",
    "",
    "| run | CPU p99/max | CPU pressure p99/max | throttled periods | throttled time |",
    "| --- | ---: | ---: | ---: | ---: |",
  );
  for (const run of report.runs) {
    const els = run.resources.oneSecond.els;
    lines.push(
      `| ${run.runId} | ${number(els.cpuMillicores.p99)}m / ` +
        `${number(els.cpuMillicores.maximum)}m | ` +
        `${number(els.cpuPressurePercent.p99)}% / ` +
        `${number(els.cpuPressurePercent.maximum)}% | ` +
        `${els.throttledPeriods}/${els.cpuPeriods} | ` +
        `${number(els.throttledMilliseconds)} ms |`,
    );
  }
  lines.push(
    "",
    "## 与旧单环境 G5 的口径区别",
    "",
    `旧 G5：10,000 条连接都接收每次 revision，probe_sync_latency_ms avg ${number(
      report.oldSingleEnvironmentG5.metrics.probe_sync_latency_ms.avg,
    )} ms，conservative p95/p99 最高 ${number(
      report.oldSingleEnvironmentG5.metrics.probe_sync_latency_ms.p95.max,
    )}/${number(
      report.oldSingleEnvironmentG5.metrics.probe_sync_latency_ms.p99.max,
    )} ms，control-plane p99 ${number(
      report.oldSingleEnvironmentG5.metrics.control_plane_write_latency_ms.p99,
    )} ms。`,
    "",
    "新基线保持 10,000 总连接，但一次正式变更只影响 target environment 的 100 条连接。这里列出旧值只是定义边界，不作速度优劣比较。",
    "",
  );
  return `${lines.join("\n")}\n`;
}

function main() {
  const args = parseArguments(process.argv.slice(2));
  const runs = args.runIds.map((runId) => ({
    ...loadAnalysis(args.resultsDirectory, runId),
    postRunBaseline: loadBaselineRestore(args.resultsDirectory, runId),
  }));
  if (
    runs.filter((run) => run.runKind === "validation").length !== 1 ||
    runs.filter((run) => run.runKind === "formal").length !== 3
  ) {
    fail("Expected exactly one validation and three formal analyses.");
  }
  const repositoryRoot = path.resolve(
    path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1")),
    "..",
    "..",
  );
  const oldBaselinePath = path.join(
    repositoryRoot,
    "docs",
    "reports",
    "aks-10k-three-stage-g5-d4.json",
  );
  const oldBaseline = readJson(oldBaselinePath);
  const report = {
    schemaVersion: 1,
    generatedAtUtc: new Date().toISOString(),
    passed: runs.every(
      (run) =>
        run.passed === true && run.postRunBaseline.confirmed === true,
    ),
    baselineDefinition:
      "10,000 total connections, 100 environments, 100 target-environment connections",
    comparisonBoundary:
      "No direct faster/slower comparison with the old 10,000-fan-out G5 baseline.",
    oldSingleEnvironmentG5: {
      runId: oldBaseline.runId,
      fanOutConnections: 10_000,
      metrics: oldBaseline.metrics,
    },
    runs,
  };
  fs.mkdirSync(args.outputDirectory, { recursive: true });
  const jsonPath = path.join(args.outputDirectory, `${args.outputName}.json`);
  const markdownPath = path.join(args.outputDirectory, `${args.outputName}.md`);
  for (const outputPath of [jsonPath, markdownPath]) {
    if (fs.existsSync(outputPath)) {
      fail(`Refusing to overwrite existing final report: ${outputPath}`);
    }
  }
  fs.writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`);
  fs.writeFileSync(markdownPath, createMarkdown(report));
  process.stdout.write(
    `${JSON.stringify({
      passed: report.passed,
      jsonPath,
      markdownPath,
      runIds: args.runIds,
    })}\n`,
  );
  if (!report.passed) process.exitCode = 2;
}

try {
  main();
} catch (error) {
  process.stderr.write(`Multi-environment summary failed: ${error.message}\n`);
  process.exitCode = 1;
}
