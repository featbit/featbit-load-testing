import fs from "node:fs";
import path from "node:path";
import process from "node:process";

import {
  classifySentinelRevision,
  summarizeSentinelValues,
} from "../../k6/lib/sentinel.js";

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

function locateRunDirectory(resultsDirectory, runId) {
  const archive = path.join(resultsDirectory, runId);
  if (fs.existsSync(archive) && fs.statSync(archive).isDirectory()) {
    return archive;
  }
  return resultsDirectory;
}

function requireFile(directory, fileName) {
  const filePath = path.join(directory, fileName);
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    fail(`Required evidence file does not exist: ${filePath}`);
  }
  return filePath;
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
        fail(`Invalid JSONL at ${filePath}:${index + 1}: ${error.message}`);
      }
    });
}

function unique(values) {
  return [...new Set(values)].sort();
}

function groupBy(values, keySelector) {
  const groups = new Map();
  for (const value of values) {
    const key = keySelector(value);
    const group = groups.get(key) ?? [];
    group.push(value);
    groups.set(key, group);
  }
  return groups;
}

function formatMs(value) {
  return `${Number(value).toFixed(2)} ms`;
}

function createMarkdown(report) {
  const lines = [
    `# ${report.runId} ELS × loadgen sentinel diagnostic`,
    "",
    "## Contract",
    "",
    `- Main load: ${report.contract.mainConnections.toLocaleString()} service-routed WebSockets.`,
    `- Direct diagnostic matrix: ${report.contract.loadgenNodes} loadgen nodes × ${report.contract.elsPods} ELS Pods × ${report.contract.connectionsPerCell} connections = ${report.contract.sentinelConnections} connections.`,
    `- Cell spike: median streaming delivery > ${report.classificationRules.spikeThresholdMs} ms.`,
    `- Loadgen row wave: at least ${report.classificationRules.rowMinimumTargets}/${report.contract.elsPods} ELS targets spike on one loadgen node.`,
    `- ELS column wave: at least ${report.classificationRules.columnMinimumNodes}/${report.contract.loadgenNodes} loadgen nodes spike for one ELS Pod.`,
    `- Global wave: at least ${report.classificationRules.globalMinimumCells}/${report.contract.cellCount} cells spike in one revision.`,
    "",
    "## Revision classification",
    "",
    "| Revision | Main runner p99 max | Sentinel avg | Sentinel p99 | Earliest-boundary cells / class | Node-local cells / class |",
    "| ---: | ---: | ---: | ---: | --- | --- |",
  ];

  for (const revision of report.revisions) {
    lines.push(
      `| ${revision.revisionIndex} (\`${revision.revision}\`) | ${formatMs(
        revision.mainRunnerP99MaxMs,
      )} | ${formatMs(revision.sentinel.stats.avg)} | ${formatMs(
        revision.sentinel.stats.p99,
      )} | ${revision.classification.spikingCells}/${report.contract.cellCount} \`${revision.classification.classification}\` | ${revision.nodeLocal.classification.spikingCells}/${report.contract.cellCount} \`${revision.nodeLocal.classification.classification}\` |`,
    );
  }

  lines.push(
    "",
    "## Interpretation",
    "",
    "- `els-column`: the same ELS Pod is late from many receiver nodes; investigate that Pod or its fan-out path.",
    "- `loadgen-row`: one receiver node is late across many direct ELS targets; investigate loadgen/k6/VM scheduling.",
    "- `global`: many rows and columns are late together; investigate shared Redis-to-ELS or cluster-wide timing.",
    "- `main-runners-only`: direct sentinels are stable while service-routed load runners spike; investigate the main runner receive path, high-fan-out connection cohorts, or Service-selected cohorts.",
    "- `isolated-cells`: evidence is connection/path specific and does not support a whole-node or whole-ELS conclusion.",
    "- The pre-registered earliest-observer classification is primary. The node-local observer view is a sensitivity analysis that removes each receiver node's observer/clock offset; a row that survives it is not explained by cross-node clock skew.",
    "",
    `Overall sentinel streaming latency: avg ${formatMs(
      report.metrics.sentinel_streaming_delivery_latency_ms.avg,
    )}, p95 ${formatMs(
      report.metrics.sentinel_streaming_delivery_latency_ms.p95,
    )}, p99 ${formatMs(
      report.metrics.sentinel_streaming_delivery_latency_ms.p99,
    )}, max ${formatMs(
      report.metrics.sentinel_streaming_delivery_latency_ms.max,
    )}.`,
    `Node-local observer-to-sentinel latency: avg ${formatMs(
      report.metrics.sentinel_node_local_delivery_latency_ms.avg,
    )}, p95 ${formatMs(
      report.metrics.sentinel_node_local_delivery_latency_ms.p95,
    )}, p99 ${formatMs(
      report.metrics.sentinel_node_local_delivery_latency_ms.p99,
    )}, max ${formatMs(
      report.metrics.sentinel_node_local_delivery_latency_ms.max,
    )}.`,
    "",
    `Coverage: ${report.validation.formalEvents}/${report.validation.expectedFormalEvents} formal events and ${report.validation.readyConnections}/${report.validation.expectedReadyConnections} ready connections.`,
    "",
  );

  return `${lines.join("\n")}\n`;
}

function main() {
  const { runId, resultsDirectory } = parseArguments(process.argv.slice(2));
  const runDirectory = locateRunDirectory(resultsDirectory, runId);
  const stage = readJson(
    requireFile(runDirectory, `${runId}-stage-latency.json`),
  );
  const events = readJsonLines(
    requireFile(runDirectory, `${runId}-sentinel-events.jsonl`),
  );
  const timingEvents = readJsonLines(
    requireFile(runDirectory, `${runId}-stream-timing-events.jsonl`),
  );
  const ready = readJsonLines(
    requireFile(runDirectory, `${runId}-sentinel-ready.jsonl`),
  );
  const targets = readJson(
    requireFile(runDirectory, `${runId}-sentinel-targets.json`),
  );

  const loadgenNodes = unique(ready.map((record) => record.loadgenNode));
  const elsPods = unique(targets.map((target) => target.pod));
  const connectionIndexes = unique(
    ready.map(
      (record) =>
        `${record.loadgenNode}|${record.elsPod}|${record.connectionIndex}`,
    ),
  );
  const cellCount = loadgenNodes.length * elsPods.length;
  if (connectionIndexes.length % cellCount !== 0) {
    fail("Ready sentinel connection count is not divisible by matrix cells.");
  }
  const connectionsPerCell = connectionIndexes.length / cellCount;
  const expectedReadyConnections = cellCount * connectionsPerCell;
  if (ready.length !== expectedReadyConnections) {
    fail(
      `Expected ${expectedReadyConnections} READY records; found ${ready.length}.`,
    );
  }

  const classificationRules = {
    spikeThresholdMs: 100,
    rowMinimumTargets: 4,
    columnMinimumNodes: 7,
    globalMinimumCells: 30,
  };
  const revisionReports = [];
  const allFormalLatencies = [];
  const allNodeLocalLatencies = [];
  let formalEvents = 0;
  let matchedNodeLocalObserverEvents = 0;

  for (const stageRevision of stage.revisions) {
    const updatedAtUnixMs = Date.parse(stageRevision.updatedAt);
    if (!Number.isFinite(updatedAtUnixMs)) {
      fail(`Stage revision ${stageRevision.revisionIndex} has invalid updatedAt.`);
    }
    const revisionEvents = events.filter(
      (event) =>
        event.revisionIndex === stageRevision.revisionIndex &&
        event.revision === stageRevision.revision &&
        event.updatedAtUnixMs === updatedAtUnixMs,
    );
    const identities = new Set(
      revisionEvents.map(
        (event) =>
          `${event.loadgenNode}|${event.elsPod}|${event.connectionIndex}`,
      ),
    );
    if (
      revisionEvents.length !== expectedReadyConnections ||
      identities.size !== expectedReadyConnections
    ) {
      fail(
        `Revision ${stageRevision.revisionIndex} expected ${expectedReadyConnections} unique sentinel events; found ${revisionEvents.length}/${identities.size}.`,
      );
    }

    const localObserverGroups = groupBy(
      timingEvents.filter(
        (event) =>
          event.node &&
          event.payload?.updatedAt &&
          Date.parse(event.payload.updatedAt) === updatedAtUnixMs,
      ),
      (event) => event.node,
    );
    const localObserverByNode = new Map(
      [...localObserverGroups.entries()].map(([node, nodeEvents]) => [
        node,
        Math.min(...nodeEvents.map((event) => event.observedAtUnixMs)),
      ]),
    );
    const missingObserverNodes = loadgenNodes.filter(
      (node) => !localObserverByNode.has(node),
    );
    if (missingObserverNodes.length > 0) {
      fail(
        `Revision ${stageRevision.revisionIndex} has no node-local Redis observer event for: ${missingObserverNodes.join(", ")}.`,
      );
    }
    matchedNodeLocalObserverEvents += localObserverByNode.size;

    for (const event of revisionEvents) {
      event.streamingDeliveryLatencyMs =
        event.receivedAtUnixMs - stageRevision.redisFirstObservedAtUnixMs;
      event.nodeLocalDeliveryLatencyMs =
        event.receivedAtUnixMs - localObserverByNode.get(event.loadgenNode);
      allFormalLatencies.push(event.streamingDeliveryLatencyMs);
      allNodeLocalLatencies.push(event.nodeLocalDeliveryLatencyMs);
    }
    formalEvents += revisionEvents.length;

    const cellGroups = groupBy(
      revisionEvents,
      (event) => `${event.loadgenNode}|${event.elsPod}`,
    );
    if (cellGroups.size !== cellCount) {
      fail(
        `Revision ${stageRevision.revisionIndex} expected ${cellCount} cells; found ${cellGroups.size}.`,
      );
    }
    const cells = [...cellGroups.values()].map((cellEvents) => {
      if (cellEvents.length !== connectionsPerCell) {
        fail(
          `Cell ${cellEvents[0].loadgenNode}/${cellEvents[0].elsPod} has ${cellEvents.length} events; expected ${connectionsPerCell}.`,
        );
      }
      return {
        loadgenNode: cellEvents[0].loadgenNode,
        elsPod: cellEvents[0].elsPod,
        stats: summarizeSentinelValues(
          cellEvents.map((event) => event.streamingDeliveryLatencyMs),
        ),
      };
    });
    cells.sort(
      (left, right) =>
        left.loadgenNode.localeCompare(right.loadgenNode) ||
        left.elsPod.localeCompare(right.elsPod),
    );
    const nodeLocalCells = [...cellGroups.values()].map((cellEvents) => ({
      loadgenNode: cellEvents[0].loadgenNode,
      elsPod: cellEvents[0].elsPod,
      stats: summarizeSentinelValues(
        cellEvents.map((event) => event.nodeLocalDeliveryLatencyMs),
      ),
    }));
    nodeLocalCells.sort(
      (left, right) =>
        left.loadgenNode.localeCompare(right.loadgenNode) ||
        left.elsPod.localeCompare(right.elsPod),
    );

    const rows = [...groupBy(revisionEvents, (event) => event.loadgenNode)].map(
      ([loadgenNode, rowEvents]) => ({
        loadgenNode,
        stats: summarizeSentinelValues(
          rowEvents.map((event) => event.streamingDeliveryLatencyMs),
        ),
      }),
    );
    const columns = [...groupBy(revisionEvents, (event) => event.elsPod)].map(
      ([elsPod, columnEvents]) => ({
        elsPod,
        stats: summarizeSentinelValues(
          columnEvents.map((event) => event.streamingDeliveryLatencyMs),
        ),
      }),
    );
    const mainRunnerP99MaxMs = Number(stageRevision.streaming.p99.max);
    const classification = classifySentinelRevision(cells, {
      ...classificationRules,
      mainRunnerP99Ms: mainRunnerP99MaxMs,
    });
    const nodeLocalClassification = classifySentinelRevision(nodeLocalCells, {
      ...classificationRules,
      mainRunnerP99Ms: mainRunnerP99MaxMs,
    });

    revisionReports.push({
      revisionIndex: stageRevision.revisionIndex,
      revision: stageRevision.revision,
      updatedAt: stageRevision.updatedAt,
      redisFirstObservedAtUnixMs: stageRevision.redisFirstObservedAtUnixMs,
      mainRunnerP99MaxMs,
      sentinel: {
        stats: summarizeSentinelValues(
          revisionEvents.map((event) => event.streamingDeliveryLatencyMs),
        ),
        cells,
        rows,
        columns,
      },
      classification,
      nodeLocal: {
        definition:
          "same-loadgen-node Redis observer receive -> direct sentinel connection applies revision",
        observerOffsetsFromEarliestMs: Object.fromEntries(
          loadgenNodes.map((node) => [
            node,
            localObserverByNode.get(node) -
              stageRevision.redisFirstObservedAtUnixMs,
          ]),
        ),
        stats: summarizeSentinelValues(
          revisionEvents.map((event) => event.nodeLocalDeliveryLatencyMs),
        ),
        cells: nodeLocalCells,
        classification: nodeLocalClassification,
      },
    });
  }

  const report = {
    schemaVersion: 1,
    runId,
    generatedAtUtc: new Date().toISOString(),
    contract: {
      mainConnections: Number(stage.topology.connections),
      loadgenNodes: loadgenNodes.length,
      elsPods: elsPods.length,
      connectionsPerCell,
      cellCount,
      sentinelConnections: expectedReadyConnections,
      formalRevisions: stage.revisions.length,
    },
    classificationRules,
    definitions: {
      sentinel_streaming_delivery_latency_ms:
        "earliest Redis publication observation across loadgen nodes -> direct ELS sentinel connection applies revision",
      sentinel_node_local_delivery_latency_ms:
        "same-loadgen-node Redis observer receive -> direct ELS sentinel connection applies revision; sensitivity analysis for receiver clock/observer offset",
      cell:
        "one loadgen node x one directly addressed ELS Pod; median across the configured direct connections",
    },
    metrics: {
      sentinel_streaming_delivery_latency_ms:
        summarizeSentinelValues(allFormalLatencies),
      sentinel_node_local_delivery_latency_ms:
        summarizeSentinelValues(allNodeLocalLatencies),
    },
    validation: {
      readyConnections: ready.length,
      expectedReadyConnections,
      formalEvents,
      expectedFormalEvents: expectedReadyConnections * stage.revisions.length,
      matchedNodeLocalObserverEvents,
      expectedNodeLocalObserverEvents:
        loadgenNodes.length * stage.revisions.length,
      complete:
        ready.length === expectedReadyConnections &&
        formalEvents === expectedReadyConnections * stage.revisions.length &&
        matchedNodeLocalObserverEvents ===
          loadgenNodes.length * stage.revisions.length,
    },
    loadgenNodes,
    elsTargets: targets,
    revisions: revisionReports,
  };

  const jsonPath = path.join(runDirectory, `${runId}-sentinel-analysis.json`);
  const markdownPath = path.join(runDirectory, `${runId}-sentinel-analysis.md`);
  fs.writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`);
  fs.writeFileSync(markdownPath, createMarkdown(report));

  process.stdout.write(
    `${JSON.stringify({
      runId,
      runDirectory,
      jsonPath,
      markdownPath,
      validation: report.validation,
      metrics: report.metrics,
      classifications: revisionReports.map((revision) => ({
        revisionIndex: revision.revisionIndex,
        classification: revision.classification.classification,
        nodeLocalClassification:
          revision.nodeLocal.classification.classification,
      })),
    })}\n`,
  );
}

try {
  main();
} catch (error) {
  process.stderr.write(`Sentinel matrix analysis failed: ${error.message}\n`);
  process.exitCode = 1;
}
