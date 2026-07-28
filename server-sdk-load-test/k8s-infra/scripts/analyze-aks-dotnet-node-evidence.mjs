#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

import {
  analyzeNodeEvidence,
  parseOneSecondTsv,
} from "../../dotnet-sdk-runner/analysis/node-evidence-analysis.js";

function fail(message) {
  throw new Error(message);
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) fail(`Missing required file: ${filePath}`);
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
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

function writeExclusive(filePath, content) {
  fs.writeFileSync(filePath, content, { encoding: "utf8", flag: "wx" });
}

function parseMetadata(text) {
  return Object.fromEntries(
    String(text)
      .split(/\r?\n/)
      .filter((line) => line.includes("="))
      .map((line) => line.split(/=(.*)/s).slice(0, 2)),
  );
}

function format(value, digits = 2) {
  return Number(value).toFixed(digits);
}

function networkCell(network) {
  return `${network.tcpRetransSegments} / ${network.packetDrops} / ` +
    `${network.packetErrors + network.tcpInErrors + network.listenDrops +
      network.backlogDrops + network.receiveQueueDrops}`;
}

function gibibytes(bytes) {
  return format(Number(bytes) / 1024 / 1024 / 1024, 3);
}

function gigabitsPerSecond(bitsPerSecond) {
  return format(Number(bitsPerSecond) / 1_000_000_000, 3);
}

function poolRow(windowName, poolName, summary) {
  return `| ${windowName} | ${poolName} | ${summary.intervalCount} | ` +
    `${format(summary.cpuPercent.p99)} / ${format(summary.cpuPercent.max)} | ` +
    `${format(summary.cpuPressurePercent.p99)} / ` +
    `${format(summary.cpuPressurePercent.max)} | ` +
    `${format(summary.runQueue.p99)} / ${format(summary.runQueue.max)} | ` +
    `${format(summary.softirqCpuPercent.p99)} / ` +
    `${format(summary.softirqCpuPercent.max)} | ` +
    `${networkCell(summary.network)} |`;
}

function main() {
  const args = parseArguments(process.argv);
  const runDirectory = path.resolve(args["run-dir"]);
  if (!fs.existsSync(runDirectory) || !fs.statSync(runDirectory).isDirectory()) {
    fail(`Run directory does not exist: ${runDirectory}`);
  }
  const runId = path.basename(runDirectory);
  const analysis = readJson(
    path.join(runDirectory, `${runId}-dotnet-pilot-analysis.json`),
  );
  if (analysis.runId !== runId || analysis.status !== "passed") {
    fail("The canonical .NET SDK pilot analysis is missing or did not pass");
  }
  const nodeFilePattern = new RegExp(
    `^${runId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}-node-(.+)-1s\\.tsv$`,
  );
  const nodeFiles = fs
    .readdirSync(runDirectory)
    .map((name) => ({ name, match: name.match(nodeFilePattern) }))
    .filter((entry) => entry.match)
    .sort((left, right) => left.name.localeCompare(right.name));
  if (nodeFiles.length !== 13) {
    fail(`Expected 13 node evidence files; found ${nodeFiles.length}`);
  }

  const metadata = [];
  const nodeSamples = nodeFiles.map(({ name, match }) => {
    const node = match[1];
    const metadataName = `${runId}-node-${node}-metadata.txt`;
    const metadataPath = path.join(runDirectory, metadataName);
    if (!fs.existsSync(metadataPath)) {
      fail(`Node '${node}' is missing '${metadataName}'`);
    }
    const nodeMetadata = parseMetadata(fs.readFileSync(metadataPath, "utf8"));
    if (nodeMetadata.target_sample_interval_seconds !== "1") {
      fail(`Node '${node}' did not target a one-second sample interval`);
    }
    metadata.push({
      node,
      targetSampleIntervalSeconds: 1,
      sourceRunId: nodeMetadata.run_id ?? null,
    });
    return {
      node,
      rows: parseOneSecondTsv(
        fs.readFileSync(path.join(runDirectory, name), "utf8"),
        name,
      ),
    };
  });

  const result = analyzeNodeEvidence({
    nodeSamples,
    rampStartUnixMs: analysis.initialization.configured.startAtUnixMs,
    rampEndUnixMs: analysis.initialization.actual.lastReadyAtUnixMs,
    formalRevisionTimesUnixMs: analysis.propagation.revisions.map(
      (revision) => revision.controllerRequestStartedAtUnixMs,
    ),
  });
  const report = {
    ...result,
    runId,
    generatedAtUtc: new Date().toISOString(),
    status: "passed",
    evidence: {
      nodeFiles: nodeFiles.map(({ name }) => name),
      metadata,
      exactElsCgroupSource: `${runId}-dotnet-pilot-analysis.json`,
      exactElsCgroup: analysis.elsCgroup,
    },
    limitations: [
      "One-second deltas can dilute sub-second bursts.",
      "Pool percentiles are distributions across node-seconds, not per-request latency.",
      "ELS throttling uses the exact pre/post stable-Pod cgroup snapshots, not DaemonSet metadata.",
    ],
  };

  const outputSuffix = args["output-suffix"]
    ? `-${args["output-suffix"]}`
    : "";
  if (outputSuffix && !/^-[a-z0-9][a-z0-9-]*$/.test(outputSuffix)) {
    fail("--output-suffix must contain only lowercase letters, digits, and dashes");
  }
  const jsonPath = path.join(
    runDirectory,
    `${runId}-dotnet-node-evidence-1s${outputSuffix}.json`,
  );
  const markdownPath = path.join(
    runDirectory,
    `${runId}-dotnet-node-evidence-1s${outputSuffix}.md`,
  );
  writeExclusive(jsonPath, `${JSON.stringify(report, null, 2)}\n`);

  const windows = [
    ["full run", report.windows.full],
    ["ramp + initial sync", report.windows.rampAndInitialSync],
    ["formal revision windows", report.windows.formalRevisionWindows],
  ];
  const markdown = [
    "# Official .NET SDK pilot: one-second node evidence",
    "",
    `Run: \`${runId}\`  `,
    "Status: **PASS**",
    "",
    "All 13 expected node files were sampled at a one-second target cadence.",
    "The ramp window ends when the last official SDK client reported public",
    "`Initialized=true`. Formal rows combine ten -1s/+2.25s revision windows.",
    "",
    "| Window | Pool | node-seconds | CPU p99 / max | CPU pressure p99 / max | run queue p99 / max | softirq CPU p99 / max | TCP retrans / packet drops / other network errors+drops |",
    "| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |",
  ];
  for (const [windowName, window] of windows) {
    for (const poolName of ["loadgen", "featbit"]) {
      markdown.push(poolRow(windowName, poolName, window.pools[poolName]));
    }
  }
  markdown.push(
    "",
    "| Window | Pool | eth0 RX / TX | peak node RX / TX |",
    "| :--- | :--- | ---: | ---: |",
  );
  for (const [windowName, window] of windows) {
    for (const poolName of ["loadgen", "featbit"]) {
      const summary = window.pools[poolName];
      markdown.push(
        `| ${windowName} | ${poolName} | ` +
          `${gibibytes(summary.network.eth0RxBytes)} / ` +
          `${gibibytes(summary.network.eth0TxBytes)} GiB | ` +
          `${gigabitsPerSecond(summary.eth0RxBitsPerSecond.max)} / ` +
          `${gigabitsPerSecond(summary.eth0TxBitsPerSecond.max)} Gbit/s |`,
      );
    }
  }
  markdown.push(
    "",
    "Exact ELS cgroup evidence used stable Pod UIDs across the pre/post window:",
    `**${analysis.elsCgroup.totals.throttledPeriods} throttled periods / ` +
      `${format(analysis.elsCgroup.totals.throttledMilliseconds, 3)} ms**, ` +
      `with ${analysis.elsCgroup.restartCount} restarts.`,
    "",
    "One-second deltas can dilute sub-second bursts. Pool percentiles describe",
    "node-second distributions and must not be interpreted as request latency.",
    "The DaemonSet's ELS mapping is not used for the canonical throttling gate;",
    "the exact stable-Pod pre/post cgroup snapshots are authoritative.",
    "",
  );
  writeExclusive(markdownPath, `${markdown.join("\n")}\n`);
  process.stdout.write(
    `${JSON.stringify({
      runId,
      status: "passed",
      reportJsonPath: jsonPath,
      reportMarkdownPath: markdownPath,
    })}\n`,
  );
}

main();
