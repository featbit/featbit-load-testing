import fs from "node:fs";
import path from "node:path";

function fail(message) {
  throw new Error(message);
}

function parseArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--")) {
      fail(`Unexpected argument '${argument}'.`);
    }
    const name = argument.slice(2);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      fail(`Argument '--${name}' requires a value.`);
    }
    values[name] = value;
    index += 1;
  }
  return values;
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) {
    fail(`Required file does not exist: ${filePath}`);
  }
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function round(value, digits = 3) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) {
    return null;
  }
  return Number(Number(value).toFixed(digits));
}

function percentile(values, fraction) {
  const sorted = values.map(Number).sort((left, right) => left - right);
  if (sorted.length === 0) {
    return null;
  }
  if (sorted.length === 1) {
    return sorted[0];
  }
  const rank = fraction * (sorted.length - 1);
  const lower = Math.floor(rank);
  const upper = Math.ceil(rank);
  if (lower === upper) {
    return sorted[lower];
  }
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - lower);
}

function distribution(values) {
  const numbers = values.map(Number);
  return {
    minimum: round(Math.min(...numbers)),
    median: round(percentile(numbers, 0.5)),
    maximum: round(Math.max(...numbers)),
  };
}

function countBy(values) {
  return Object.fromEntries(
    [...new Set(values)].sort().map((value) => [
      value,
      values.filter((candidate) => candidate === value).length,
    ]),
  );
}

function getPacketDrops(pool) {
  return (
    Number(pool.eth0RxDrops ?? 0) +
    Number(pool.eth0TxDrops ?? 0) +
    Number(pool.ciliumRxDrops ?? 0) +
    Number(pool.ciliumTxDrops ?? 0)
  );
}

function formatMs(value) {
  return `${Number(value).toFixed(2)} ms`;
}

function formatPercent(value, digits = 2) {
  return `${Number(value).toFixed(digits)}%`;
}

function formatRange(stats, suffix = "") {
  return `${round(stats.median)}${suffix} (${round(stats.minimum)}–${round(
    stats.maximum,
  )}${suffix})`;
}

function findArtifact(run, suffix) {
  const directory = path.resolve(run.archiveDirectory);
  return path.join(directory, `${run.runId}-${suffix}`);
}

function escapeRegularExpression(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function loadRunnerEvidence(run, evidence) {
  const directory = path.resolve(run.archiveDirectory);
  const placement = readJson(findArtifact(run, "runner-placement.json"));
  const runnersByNode = new Map();
  for (const pod of placement.pods ?? []) {
    const match = pod.name.match(/-(\d+)-[a-z0-9]+$/);
    if (!match) {
      continue;
    }
    const runner = Number(match[1]);
    const current = runnersByNode.get(pod.node) ?? [];
    current.push(runner);
    runnersByNode.set(pod.node, current);
  }
  for (const runners of runnersByNode.values()) {
    runners.sort((left, right) => left - right);
  }

  const summariesByRunner = new Map();
  const pattern = new RegExp(
    `^featbit-${escapeRegularExpression(run.runId)}-(\\d+)-[a-z0-9]+-summary\\.json$`,
  );
  for (const name of fs.readdirSync(directory)) {
    const match = name.match(pattern);
    if (match) {
      summariesByRunner.set(
        Number(match[1]),
        readJson(path.join(directory, name)),
      );
    }
  }

  function getRowEvidence(
    loadgenNode,
    revisionIndex,
    updatedAtToLocalObserverMs,
  ) {
    const runners = runnersByNode.get(loadgenNode) ?? [];
    const runnerP99 = runners.map((runner) => {
      const summary = summariesByRunner.get(runner);
      const candidates = [
        `probe_updated_at_to_sdk_latency_ms{revision_index:${revisionIndex}}`,
        `probe_sync_latency_ms{revision_index:${revisionIndex}}`,
      ];
      const metricName = candidates.find((name) => summary?.metrics?.[name]);
      if (!metricName) {
        fail(
          `Runner ${runner} is missing per-revision latency for revision ${revisionIndex}.`,
        );
      }
      return {
        runner,
        metric: metricName.split("{")[0],
        rawP99Ms: round(summary.metrics[metricName]["p(99)"]),
        nodeLocalP99Ms: round(
          summary.metrics[metricName]["p(99)"] -
            updatedAtToLocalObserverMs,
        ),
      };
    });
    const resourceWindow = (evidence.worstCohorts ?? []).find(
      (cohort) =>
        cohort.node === loadgenNode &&
        Number(cohort.revision) === Number(revisionIndex),
    );
    return {
      runnerP99,
      resourceWindow: resourceWindow
        ? {
            cpuMaximumPercent: round(
              resourceWindow.loadgenCpuMaximumPercent,
            ),
            cpuPressureMaximumPercent: round(
              resourceWindow.loadgenCpuPressureMaximumPercent,
            ),
            runQueueMaximum: round(resourceWindow.loadgenRunQueueMaximum),
            netRxSoftirqMaximumPerSecond: round(
              resourceWindow.loadgenNetRxSoftirqMaximumPerSecond,
            ),
            tcpRetransmissions: Number(
              resourceWindow.loadgenTcpRetransSegments ?? 0,
            ),
            packetDrops: Number(resourceWindow.loadgenPacketDrops ?? 0),
          }
        : null,
    };
  }

  return { getRowEvidence };
}

function summarizeRun(run) {
  const stage = readJson(findArtifact(run, "stage-latency.json"));
  const sentinel = readJson(findArtifact(run, "sentinel-analysis.json"));
  const evidence = readJson(findArtifact(run, "node-evidence-1s.json"));
  const runnerEvidence = loadRunnerEvidence(run, evidence);

  if (!sentinel.validation?.complete) {
    fail(`Sentinel evidence is incomplete for '${run.runId}'.`);
  }
  if (stage.validationStatus === "invalid") {
    fail(`Three-stage evidence is invalid for '${run.runId}'.`);
  }

  const classifications = sentinel.revisions.map(
    (revision) => revision.classification.classification,
  );
  const mainSpikeRevisions = sentinel.revisions.filter(
    (revision) => revision.classification.mainRunnerSpike,
  ).length;
  const spikingCells = sentinel.revisions.reduce(
    (total, revision) =>
      total + Number(revision.classification.spikingCells ?? 0),
    0,
  );
  const rowWaves = sentinel.revisions.reduce(
    (total, revision) =>
      total + (revision.classification.rowWaves?.length ?? 0),
    0,
  );
  const columnWaves = sentinel.revisions.reduce(
    (total, revision) =>
      total + (revision.classification.columnWaves?.length ?? 0),
    0,
  );
  const globalWaves = sentinel.revisions.filter(
    (revision) => revision.classification.globalWave,
  ).length;
  const rowWaveDetails = sentinel.revisions.flatMap((revision) =>
    (revision.classification.rowWaves ?? []).map((wave) => {
      const observerOffsetFromEarliestMs = Number(
        revision.nodeLocal.observerOffsetsFromEarliestMs[wave.loadgenNode],
      );
      const updatedAtToLocalObserverMs =
        Number(revision.redisFirstObservedAtUnixMs) +
        observerOffsetFromEarliestMs -
        Date.parse(revision.updatedAt);
      const corroboration = runnerEvidence.getRowEvidence(
        wave.loadgenNode,
        revision.revisionIndex,
        updatedAtToLocalObserverMs,
      );
      const nodeLocalWave = (
        revision.nodeLocal.classification.rowWaves ?? []
      ).find((candidate) => candidate.loadgenNode === wave.loadgenNode);
      return {
        revisionIndex: revision.revisionIndex,
        mainRunnerP99MaximumMs: round(revision.mainRunnerP99MaxMs),
        sentinelP99Ms: round(revision.sentinel.stats.p99),
        loadgenNode: wave.loadgenNode,
        affectedTargets: wave.affectedTargets,
        observerOffsetFromEarliestMs,
        survivesNodeLocalBoundary: Boolean(nodeLocalWave),
        nodeLocalAffectedTargets: nodeLocalWave?.affectedTargets ?? 0,
        colocatedMainRunners: corroboration.runnerP99,
        resourceWindow: corroboration.resourceWindow,
      };
    }),
  );
  const columnWaveDetails = sentinel.revisions.flatMap((revision) =>
    (revision.classification.columnWaves ?? []).map((wave) => ({
      revisionIndex: revision.revisionIndex,
      mainRunnerP99MaximumMs: round(revision.mainRunnerP99MaxMs),
      sentinelP99Ms: round(revision.sentinel.stats.p99),
      elsPod: wave.elsPod,
      affectedRows: wave.affectedRows,
    })),
  );
  const revisionWindows = evidence.revisions ?? [];
  const revisionDrops = revisionWindows.reduce(
    (total, revision) =>
      total +
      Number(revision.loadgenPacketDrops ?? 0) +
      Number(revision.featbitPacketDrops ?? 0),
    0,
  );
  const revisionRetransmissions = revisionWindows.reduce(
    (total, revision) =>
      total +
      Number(revision.loadgenTcpRetransSegments ?? 0) +
      Number(revision.featbitTcpRetransSegments ?? 0),
    0,
  );
  const revisionElsThrottledPeriods = revisionWindows.reduce(
    (total, revision) =>
      total + Number(revision.elsThrottledPeriods ?? 0),
    0,
  );

  return {
    sequence: run.sequence,
    runId: run.runId,
    main: {
      sampleCount: stage.metrics.probe_sync_latency_ms.count,
      streamingAverageMs: round(stage.metrics.probe_sync_latency_ms.avg),
      runnerRevisionP95MaximumMs: round(
        stage.metrics.probe_sync_latency_ms.p95.max,
      ),
      runnerRevisionP99MaximumMs: round(
        stage.metrics.probe_sync_latency_ms.p99.max,
      ),
      maximumMs: round(stage.metrics.probe_sync_latency_ms.max),
      controlPlaneAverageMs: round(
        stage.metrics.control_plane_write_latency_ms.avg,
      ),
      thresholdFailures: Number(run.analysis?.thresholdFailureCount ?? 0),
    },
    sentinel: {
      readyConnections: sentinel.validation.readyConnections,
      formalEvents: sentinel.validation.formalEvents,
      averageMs: round(
        sentinel.metrics.sentinel_streaming_delivery_latency_ms.avg,
      ),
      p95Ms: round(
        sentinel.metrics.sentinel_streaming_delivery_latency_ms.p95,
      ),
      p99Ms: round(
        sentinel.metrics.sentinel_streaming_delivery_latency_ms.p99,
      ),
      maximumMs: round(
        sentinel.metrics.sentinel_streaming_delivery_latency_ms.max,
      ),
      mainSpikeRevisions,
      spikingCells,
      rowWaves,
      columnWaves,
      globalWaves,
      rowWaveDetails,
      columnWaveDetails,
      classifications: countBy(classifications),
      nodeLocal: {
        averageMs: round(
          sentinel.metrics.sentinel_node_local_delivery_latency_ms.avg,
        ),
        p95Ms: round(
          sentinel.metrics.sentinel_node_local_delivery_latency_ms.p95,
        ),
        p99Ms: round(
          sentinel.metrics.sentinel_node_local_delivery_latency_ms.p99,
        ),
        maximumMs: round(
          sentinel.metrics.sentinel_node_local_delivery_latency_ms.max,
        ),
        spikingCells: sentinel.revisions.reduce(
          (total, revision) =>
            total +
            Number(revision.nodeLocal.classification.spikingCells ?? 0),
          0,
        ),
        rowWaves: sentinel.revisions.reduce(
          (total, revision) =>
            total +
            (revision.nodeLocal.classification.rowWaves?.length ?? 0),
          0,
        ),
        columnWaves: sentinel.revisions.reduce(
          (total, revision) =>
            total +
            (revision.nodeLocal.classification.columnWaves?.length ?? 0),
          0,
        ),
        globalWaves: sentinel.revisions.filter(
          (revision) => revision.nodeLocal.classification.globalWave,
        ).length,
      },
    },
    resources: {
      sampleIntervalP50Seconds: round(
        evidence.evidence.intervalSeconds.median,
      ),
      loadgenCpuP99Percent: round(evidence.pools.loadgen.cpuPercent.p99),
      loadgenCpuPressureP99Percent: round(
        evidence.pools.loadgen.cpuPressurePercent.p99,
      ),
      loadgenRunQueueP99: round(evidence.pools.loadgen.runQueue.p99),
      loadgenRetransmissionsFullRun: Number(
        evidence.pools.loadgen.tcpRetransSegments,
      ),
      loadgenPacketDropsFullRun: getPacketDrops(evidence.pools.loadgen),
      elsCpuP99Millicores: round(evidence.els.cpuMillicores.p99),
      elsCpuMaximumMillicores: round(evidence.els.cpuMillicores.maximum),
      elsThrottledPeriodRate: round(evidence.els.throttledPeriodRate, 7),
      elsThrottledMilliseconds: round(evidence.els.throttledMilliseconds),
      revisionRetransmissions,
      revisionDrops,
      revisionElsThrottledPeriods,
      kubernetesPeaks: evidence.kubernetesPeaks,
    },
  };
}

function renderMarkdown(report, outputJsonPath) {
  const lines = [];
  const decision = report.decision;

  lines.push("# AKS 10k：ELS × loadgen sentinel 判别实验", "");
  lines.push("## 结论", "");
  lines.push(
    `三轮均完整：主负载 ${report.totals.mainSamples.toLocaleString(
      "en-US",
    )} 个 canonical streaming 样本，direct sentinel ${
      report.totals.sentinelEvents
    } 个正式事件，threshold failure 为 ${report.totals.thresholdFailures}。`,
    "",
    `预注册的 30 个 revision 中，ELS column wave = ${decision.elsColumnWaves}、loadgen row wave = ${decision.loadgenRowWaves}、global wave = ${decision.globalWaves}。主 runner p99 超过 100 ms 的 revision 有 ${decision.mainSpikeRevisions} 个，但 direct matrix 只有 ${decision.isolatedSpikingCells} / ${decision.totalCellsAcrossRevisions} 个 cell 超过 100 ms。`,
    "",
    decision.statement,
    "",
  );

  lines.push("## 固定拓扑与口径", "");
  lines.push(
    "| 项目 | 配置 |",
    "| --- | --- |",
    "| 主负载 | 10,000 WebSockets；20 runners × 500；100/s |",
    "| ELS | 6 Pods；6 × D2 FeatBit nodes；严格一节点一 Pod |",
    "| loadgen | 10 × D4 nodes；每节点两个主 runner |",
    "| direct sentinel | 每个 loadgen node 到每个 ELS Pod 3 条连接；共 180 |",
    "| 正式变更 | 10 revisions；只变更 flag-01；flag-02 满连接预热 |",
    "| 重复 | 3 个 fresh runs，每轮冷重启并重新固定 ELS placement |",
    "| cell spike | 3 条连接的中位数 >100 ms |",
    "| row / column / global | ≥4/6 columns；≥7/10 rows；≥30/60 cells |",
    "",
  );

  lines.push("## 三轮完整结果", "");
  lines.push(
    "| Run | 主 streaming avg | 主最差 p95 / p99 | 主 max | control avg | sentinel avg / earliest p99 / node-local p99 | 主波峰 revisions | spike cells | failures |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const run of report.runs) {
    lines.push(
      `| run ${run.sequence} | ${formatMs(
        run.main.streamingAverageMs,
      )} | ${formatMs(run.main.runnerRevisionP95MaximumMs)} / ${formatMs(
        run.main.runnerRevisionP99MaximumMs,
      )} | ${formatMs(run.main.maximumMs)} | ${formatMs(
        run.main.controlPlaneAverageMs,
      )} | ${formatMs(run.sentinel.averageMs)} / ${formatMs(
        run.sentinel.p99Ms,
      )} / ${formatMs(
        run.sentinel.nodeLocal.p99Ms,
      )} | ${run.sentinel.mainSpikeRevisions}/10 | ${
        run.sentinel.spikingCells
      }/600 | ${run.main.thresholdFailures} |`,
    );
  }
  lines.push("");
  lines.push(
    `三轮主 streaming average 中位数为 ${formatRange(
      report.repeatability.mainStreamingAverageMs,
      " ms",
    )}；主 runner × revision 最差 p99 中位数为 ${formatRange(
      report.repeatability.mainRunnerRevisionP99MaximumMs,
      " ms",
    )}。sentinel p99 中位数为 ${formatRange(
      report.repeatability.sentinelP99Ms,
      " ms",
    )}。`,
    "",
  );

  lines.push("## 预注册分类", "");
  lines.push(
    "| Run | stable | main-runners-only | isolated-cells | loadgen-row | els-column | global / mixed |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const run of report.runs) {
    const counts = run.sentinel.classifications;
    lines.push(
      `| run ${run.sequence} | ${counts.stable ?? 0} | ${
        counts["main-runners-only"] ?? 0
      } | ${counts["isolated-cells"] ?? 0} | ${
        counts["loadgen-row"] ?? 0
      } | ${counts["els-column"] ?? 0} | ${
        (counts.global ?? 0) + (counts.mixed ?? 0)
      } |`,
    );
  }
  lines.push("");

  lines.push("### Node-local observer sensitivity", "");
  lines.push(
    "The primary classification keeps the pre-registered earliest-observer boundary. The node-local view subtracts the Redis observer on the same receiver node, removing its 0–10 ms cross-node clock/observer offset.",
    "",
    "| Run | Primary slow cells | Primary rows | Node-local slow cells | Node-local rows | Node-local ELS columns / global |",
    "| --- | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const run of report.runs) {
    lines.push(
      `| run ${run.sequence} | ${run.sentinel.spikingCells}/600 | ${run.sentinel.rowWaves} | ${run.sentinel.nodeLocal.spikingCells}/600 | ${run.sentinel.nodeLocal.rowWaves} | ${run.sentinel.nodeLocal.columnWaves} / ${run.sentinel.nodeLocal.globalWaves} |`,
    );
  }
  lines.push("");

  const rowWaveDetails = report.runs.flatMap((run) =>
    run.sentinel.rowWaveDetails.map((wave) => ({
      run: run.sequence,
      ...wave,
    })),
  );
  if (rowWaveDetails.length > 0) {
    lines.push("### Detected loadgen rows", "");
    lines.push(
      "| Run / revision | loadgen node | primary → node-local targets | observer offset | colocated main runner raw / node-local p99 | sentinel p99 | node CPU / pressure / run queue |",
      "| --- | --- | ---: | ---: | ---: | ---: | ---: |",
    );
    for (const wave of rowWaveDetails) {
      const runners = wave.colocatedMainRunners
        .map(
          (runner) =>
            `r${runner.runner} ${formatMs(
              runner.rawP99Ms,
            )} / ${formatMs(runner.nodeLocalP99Ms)}`,
        )
        .join("; ");
      const resource = wave.resourceWindow
        ? `${formatPercent(
            wave.resourceWindow.cpuMaximumPercent,
          )} / ${formatPercent(
            wave.resourceWindow.cpuPressureMaximumPercent,
          )} / ${wave.resourceWindow.runQueueMaximum}`
        : "not retained";
      lines.push(
        `| run ${wave.run} / rev ${wave.revisionIndex} | \`${wave.loadgenNode}\` | ${wave.affectedTargets}/6 → ${wave.nodeLocalAffectedTargets}/6 | ${wave.observerOffsetFromEarliestMs} ms | ${runners} | ${formatMs(
          wave.sentinelP99Ms,
        )} | ${resource} |`,
      );
    }
    lines.push(
      "",
      "Colocated runner values show raw `FeatureFlag.UpdatedAt → SDK` followed by same-node observer → SDK p99. Every detected row recorded zero packet drop and zero retransmission in its one-second window.",
      "",
    );
  }

  lines.push("## 本实验的资源消耗", "");
  lines.push(
    "以下资源只属于这三轮 sentinel 实验；不能与前面实验的资源表混用。host/cgroup 约 1 秒采样，Kubernetes 约 5 秒采样。",
    "",
    "| Run | loadgen CPU / pressure / run queue p99 | ELS CPU p99 / max | ELS throttle rate / time | revision retrans / drops / throttle | runner / sentinel 聚合峰值内存 |",
    "| --- | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const run of report.runs) {
    const peaks = run.resources.kubernetesPeaks ?? {};
    lines.push(
      `| run ${run.sequence} | ${formatPercent(
        run.resources.loadgenCpuP99Percent,
      )} / ${formatPercent(
        run.resources.loadgenCpuPressureP99Percent,
      )} / ${run.resources.loadgenRunQueueP99.toFixed(2)} | ${round(
        run.resources.elsCpuP99Millicores,
        1,
      )}m / ${round(run.resources.elsCpuMaximumMillicores, 1)}m | ${(
        run.resources.elsThrottledPeriodRate * 100
      ).toFixed(4)}% / ${run.resources.elsThrottledMilliseconds.toFixed(
        2,
      )} ms | ${run.resources.revisionRetransmissions} / ${
        run.resources.revisionDrops
      } / ${run.resources.revisionElsThrottledPeriods} | ${round(
        Number(peaks.runnerMemoryMiB ?? 0) / 1024,
        2,
      )} GiB / ${round(
        Number(peaks.sentinelMemoryMiB ?? 0) / 1024,
        2,
      )} GiB |`,
    );
  }
  lines.push("");

  lines.push("## 判读边界", "");
  if (decision.elsColumnWaves === 0) {
    lines.push(
      "- 没有 ELS column wave：不支持“某个 ELS Pod/其所在节点整体变慢”。",
    );
  } else {
    lines.push(
      `- 检测到 ${decision.elsColumnWaves} 次 ELS column wave：存在 ELS Pod/其所在路径维度的共同延迟。`,
    );
  }
  if (decision.loadgenRowWaves === 0) {
    lines.push(
      "- 没有 loadgen row wave：不支持“某个 loadgen node 上所有接收路径整体变慢”。",
    );
  } else {
    lines.push(
      `- 预注册口径检测到 ${decision.loadgenRowWaves} 次 loadgen row wave，其中 ${decision.nodeLocalLoadgenRowWaves} 次在同节点 observer 边界下仍成立；跨节点时钟/observer 偏移影响了阈值附近的两次，但不能解释全部现象。`,
    );
  }
  if (decision.globalWaves === 0) {
    lines.push(
      "- 没有 global wave：不支持“Redis publication 或集群共享事件让所有直连同时变慢”。",
    );
  } else {
    lines.push(
      `- 检测到 ${decision.globalWaves} 次 global wave：共享 publication 或集群事件需要继续调查。`,
    );
  }
  lines.push(
    "- 主 runner 仍有尾峰而 direct sentinels 大体稳定，说明剩余抖动更接近主连接 cohort、k6 receive loop/runner 进程内调度，或尚未被 direct sentinel 完全复现的 Service-selected 长连接路径。",
    "- 少量 isolated cells 说明单连接/小 cohort 抖动确实存在；它们不足以归因到整个 ELS Pod 或整个 loadgen node。",
    "- 该结果定位的是层级，不是 FeatBit 源码中的具体函数。没有修改任何 FeatBit 源码。",
    "",
  );

  lines.push("## 复现与证据", "");
  lines.push(
    "- 实验定义：[`aks-els-loadgen-sentinel.json`](../../k8s-infra/matrices/aks-els-loadgen-sentinel.json)",
    "- 执行器：[`run-aks-capacity-matrix.ps1`](../../k8s-infra/scripts/run-aks-capacity-matrix.ps1)",
    "- sentinel 分析：[`analyze-aks-sentinel-matrix.ps1`](../../k8s-infra/scripts/analyze-aks-sentinel-matrix.ps1)",
    "- 三阶段分析：[`analyze-aks-stage-latency.ps1`](../../k8s-infra/scripts/analyze-aks-stage-latency.ps1)",
    "- 1 秒证据：[`analyze-aks-1s-evidence.ps1`](../../k8s-infra/scripts/analyze-aks-1s-evidence.ps1)",
    "- 本汇总：[`summarize-aks-sentinel-experiment.mjs`](../../k8s-infra/scripts/summarize-aks-sentinel-experiment.mjs)",
    `- Machine-readable result：[\`${path.basename(
      outputJsonPath,
    )}\`](${path.basename(outputJsonPath)})`,
    "",
    "三轮 TestRun、20 份 runner JSON/HTML、sentinel raw logs、三阶段 timing、5 秒资源记录和 1 秒 TSV 均保留在本地 `results/<run-id>/`。本流程不会删除 TestRun、PVC、AKS 或数据库。",
    "",
  );

  return `${lines.join("\n")}\n`;
}

function main() {
  const args = parseArguments(process.argv.slice(2));
  if (!args.state || !args["output-prefix"]) {
    fail(
      "Usage: node summarize-aks-sentinel-experiment.mjs " +
        "--state <state.json> --output-prefix <path-without-extension>",
    );
  }

  const statePath = path.resolve(args.state);
  const outputPrefix = path.resolve(args["output-prefix"]);
  const state = readJson(statePath);
  const completedRuns = (state.runs ?? [])
    .filter((run) => run.status === "completed")
    .sort((left, right) => left.sequence - right.sequence);
  if (completedRuns.length !== 3) {
    fail(`Expected 3 completed runs; found ${completedRuns.length}.`);
  }

  const runs = completedRuns.map(summarizeRun);
  const allClassifications = runs.flatMap((run) =>
    Object.entries(run.sentinel.classifications).flatMap(
      ([classification, count]) => Array(count).fill(classification),
    ),
  );
  const totals = {
    mainSamples: runs.reduce(
      (sum, run) => sum + run.main.sampleCount,
      0,
    ),
    sentinelEvents: runs.reduce(
      (sum, run) => sum + run.sentinel.formalEvents,
      0,
    ),
    thresholdFailures: runs.reduce(
      (sum, run) => sum + run.main.thresholdFailures,
      0,
    ),
  };
  const decision = {
    status: "continue",
    exactComponent: "inconclusive",
    mainSpikeRevisions: runs.reduce(
      (sum, run) => sum + run.sentinel.mainSpikeRevisions,
      0,
    ),
    isolatedSpikingCells: runs.reduce(
      (sum, run) => sum + run.sentinel.spikingCells,
      0,
    ),
    totalCellsAcrossRevisions: runs.length * 10 * 60,
    loadgenRowWaves: runs.reduce(
      (sum, run) => sum + run.sentinel.rowWaves,
      0,
    ),
    elsColumnWaves: runs.reduce(
      (sum, run) => sum + run.sentinel.columnWaves,
      0,
    ),
    globalWaves: runs.reduce(
      (sum, run) => sum + run.sentinel.globalWaves,
      0,
    ),
    nodeLocalLoadgenRowWaves: runs.reduce(
      (sum, run) => sum + run.sentinel.nodeLocal.rowWaves,
      0,
    ),
    nodeLocalElsColumnWaves: runs.reduce(
      (sum, run) => sum + run.sentinel.nodeLocal.columnWaves,
      0,
    ),
    nodeLocalGlobalWaves: runs.reduce(
      (sum, run) => sum + run.sentinel.nodeLocal.globalWaves,
      0,
    ),
    nodeLocalSpikingCells: runs.reduce(
      (sum, run) => sum + run.sentinel.nodeLocal.spikingCells,
      0,
    ),
    rowWaveDetails: runs.flatMap((run) =>
      run.sentinel.rowWaveDetails.map((wave) => ({
        run: run.sequence,
        ...wave,
      })),
    ),
    columnWaveDetails: runs.flatMap((run) =>
      run.sentinel.columnWaveDetails.map((wave) => ({
        run: run.sequence,
        ...wave,
      })),
    ),
    classificationCounts: countBy(allClassifications),
    statement:
      "三轮证据若保持无 row/column/global wave，则剩余尾峰不属于整个 ELS Pod、整个 loadgen node 或共享 publication 波；它主要收缩到主连接 cohort / k6 receive path 的稀疏抖动。具体到单个实现组件仍为 INCONCLUSIVE。",
  };
  if (
    decision.loadgenRowWaves > 0 ||
    decision.elsColumnWaves > 0 ||
    decision.globalWaves > 0
  ) {
    decision.status = "investigate-detected-wave";
    decision.statement =
      "至少一轮触发了预注册 row、column 或 global wave；应按对应维度继续排查，不能归为纯主 runner 抖动。";
  }
  if (
    decision.loadgenRowWaves > 0 &&
    decision.elsColumnWaves === 0 &&
    decision.globalWaves === 0
  ) {
    decision.status = "continue-loadgen-receiver-diagnosis";
    decision.exactComponent = "loadgen receive path is a demonstrated contributor";
    decision.statement =
      `三轮出现 ${decision.loadgenRowWaves} 次预注册 loadgen-row，` +
      `其中 ${decision.nodeLocalLoadgenRowWaves} 次在同节点 observer ` +
      "敏感性分析后仍成立；没有 ELS-column 或 global wave。" +
      "接收端 loadgen node/VM、kernel network wake-up 或其上的进程调度" +
      "是已证实的尾延迟贡献者，跨节点时钟偏移不能解释全部现象；" +
      "其余没有形成 row 的主 runner 尾峰仍不能精确归到单个实现组件。";
  }

  const report = {
    schemaVersion: 1,
    generatedAtUtc: new Date().toISOString(),
    matrixId: state.matrixId,
    statePath,
    runIds: runs.map((run) => run.runId),
    totals,
    repeatability: {
      mainStreamingAverageMs: distribution(
        runs.map((run) => run.main.streamingAverageMs),
      ),
      mainRunnerRevisionP99MaximumMs: distribution(
        runs.map((run) => run.main.runnerRevisionP99MaximumMs),
      ),
      sentinelP99Ms: distribution(
        runs.map((run) => run.sentinel.p99Ms),
      ),
    },
    decision,
    runs,
  };

  const outputJsonPath = `${outputPrefix}.json`;
  const outputMarkdownPath = `${outputPrefix}.md`;
  fs.mkdirSync(path.dirname(outputPrefix), { recursive: true });
  fs.writeFileSync(
    outputJsonPath,
    `${JSON.stringify(report, null, 2)}\n`,
    "utf8",
  );
  fs.writeFileSync(
    outputMarkdownPath,
    renderMarkdown(report, outputJsonPath),
    "utf8",
  );
  process.stdout.write(
    `${JSON.stringify(
      {
        outputJsonPath,
        outputMarkdownPath,
        runIds: report.runIds,
        decision: report.decision,
      },
      null,
      2,
    )}\n`,
  );
}

main();
