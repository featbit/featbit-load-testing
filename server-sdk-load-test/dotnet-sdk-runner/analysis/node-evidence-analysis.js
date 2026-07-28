import { percentileStats } from "../../k6/lib/multi-environment-analysis.js";

const CPU_COUNTERS = [
  "cpu_user",
  "cpu_nice",
  "cpu_system",
  "cpu_idle",
  "cpu_iowait",
  "cpu_irq",
  "cpu_softirq",
  "cpu_steal",
];

const DELTA_COUNTERS = [
  "eth0_rx_errors",
  "eth0_rx_drops",
  "eth0_tx_errors",
  "eth0_tx_drops",
  "cilium_rx_errors",
  "cilium_rx_drops",
  "cilium_tx_errors",
  "cilium_tx_drops",
  "tcp_retrans_segs",
  "tcp_in_errors",
  "tcp_ext_listen_drops",
  "tcp_ext_backlog_drops",
  "tcp_ext_rcv_queue_drops",
];

const TRAFFIC_COUNTERS = [
  "eth0_rx_bytes",
  "eth0_rx_packets",
  "eth0_tx_bytes",
  "eth0_tx_packets",
  "cilium_rx_bytes",
  "cilium_rx_packets",
  "cilium_tx_bytes",
  "cilium_tx_packets",
];

const REQUIRED_COLUMNS = [
  "observed_at_utc",
  "uptime_seconds",
  ...CPU_COUNTERS,
  "procs_running",
  "run_queue",
  "load_1m",
  "cpu_pressure_some_usec",
  "memory_pressure_some_usec",
  "io_pressure_some_usec",
  "softirq_net_rx",
  ...TRAFFIC_COUNTERS,
  ...DELTA_COUNTERS,
];

function fail(message) {
  throw new Error(message);
}

function finite(row, property) {
  const raw = row[property];
  if (raw === undefined || raw === null || String(raw).trim() === "") {
    fail(`one-second evidence is missing '${property}'`);
  }
  const value = Number(raw);
  if (!Number.isFinite(value)) {
    fail(`one-second evidence '${property}' is not finite`);
  }
  return value;
}

function delta(current, previous, property) {
  const value = finite(current, property) - finite(previous, property);
  return value < 0 ? null : value;
}

function sumFinite(values) {
  return values
    .filter((value) => Number.isFinite(value))
    .reduce((sum, value) => sum + value, 0);
}

function stats(values) {
  const numbers = values.filter((value) => Number.isFinite(value));
  if (numbers.length === 0) return null;
  return {
    min: Math.min(...numbers),
    ...percentileStats(numbers),
  };
}

export function classifyNodePool(node) {
  if (/^aks-(loadgen|loadgen3k)-/.test(node)) return "loadgen";
  if (/^aks-(featbit|els3k)-/.test(node)) return "featbit";
  return "other";
}

export function parseOneSecondTsv(text, label = "one-second evidence") {
  const lines = String(text)
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0);
  if (lines.length < 3) {
    fail(`${label} must contain a header and at least two samples`);
  }
  const header = lines[0].split("\t");
  if (new Set(header).size !== header.length) {
    fail(`${label} contains duplicate columns`);
  }
  for (const column of REQUIRED_COLUMNS) {
    if (!header.includes(column)) {
      fail(`${label} is missing required column '${column}'`);
    }
  }
  return lines.slice(1).map((line, index) => {
    const cells = line.split("\t");
    if (cells.length !== header.length) {
      fail(
        `${label}:${index + 2} has ${cells.length} fields; ` +
          `expected ${header.length}`,
      );
    }
    return Object.fromEntries(header.map((name, cell) => [name, cells[cell]]));
  });
}

export function buildNodeIntervalRecords({ node, rows }) {
  if (!node || !Array.isArray(rows) || rows.length < 2) {
    fail("node and at least two one-second samples are required");
  }
  const nodePool = classifyNodePool(node);
  const records = [];
  for (let index = 1; index < rows.length; index += 1) {
    const previous = rows[index - 1];
    const current = rows[index];
    const intervalSeconds =
      finite(current, "uptime_seconds") - finite(previous, "uptime_seconds");
    if (intervalSeconds <= 0) continue;

    const observedAtUnixMs = Date.parse(current.observed_at_utc);
    if (!Number.isFinite(observedAtUnixMs)) {
      fail(`node '${node}' has an invalid observed_at_utc timestamp`);
    }

    const cpuDeltas = Object.fromEntries(
      CPU_COUNTERS.map((property) => [
        property,
        delta(current, previous, property),
      ]),
    );
    const validCpuDeltas = Object.values(cpuDeltas).every(Number.isFinite);
    const cpuTotal = validCpuDeltas
      ? sumFinite(Object.values(cpuDeltas))
      : null;
    const cpuIdle = validCpuDeltas
      ? cpuDeltas.cpu_idle + cpuDeltas.cpu_iowait
      : null;
    const percent = (counter) =>
      Number.isFinite(cpuTotal) && cpuTotal > 0
        ? (counter / cpuTotal) * 100
        : null;

    const pressurePercent = (property) => {
      const counterDelta = delta(current, previous, property);
      return Number.isFinite(counterDelta)
        ? (counterDelta / intervalSeconds / 1_000_000) * 100
        : null;
    };
    const counterDeltas = Object.fromEntries(
      DELTA_COUNTERS.map((property) => [
        property,
        delta(current, previous, property),
      ]),
    );
    const trafficDeltas = Object.fromEntries(
      TRAFFIC_COUNTERS.map((property) => [
        property,
        delta(current, previous, property),
      ]),
    );
    const netRxDelta = delta(current, previous, "softirq_net_rx");

    records.push({
      node,
      nodePool,
      observedAtUnixMs,
      observedAtUtc: new Date(observedAtUnixMs).toISOString(),
      intervalSeconds,
      cpuPercent:
        Number.isFinite(cpuTotal) && cpuTotal > 0
          ? ((cpuTotal - cpuIdle) / cpuTotal) * 100
          : null,
      stealPercent: percent(cpuDeltas.cpu_steal),
      softirqCpuPercent: percent(cpuDeltas.cpu_softirq),
      cpuPressurePercent: pressurePercent("cpu_pressure_some_usec"),
      memoryPressurePercent: pressurePercent("memory_pressure_some_usec"),
      ioPressurePercent: pressurePercent("io_pressure_some_usec"),
      procsRunning: finite(current, "procs_running"),
      runQueue: finite(current, "run_queue"),
      load1m: finite(current, "load_1m"),
      netRxSoftirqPerSecond: Number.isFinite(netRxDelta)
        ? netRxDelta / intervalSeconds
        : null,
      eth0RxBytes: trafficDeltas.eth0_rx_bytes,
      eth0RxPackets: trafficDeltas.eth0_rx_packets,
      eth0TxBytes: trafficDeltas.eth0_tx_bytes,
      eth0TxPackets: trafficDeltas.eth0_tx_packets,
      ciliumRxBytes: trafficDeltas.cilium_rx_bytes,
      ciliumRxPackets: trafficDeltas.cilium_rx_packets,
      ciliumTxBytes: trafficDeltas.cilium_tx_bytes,
      ciliumTxPackets: trafficDeltas.cilium_tx_packets,
      eth0RxBitsPerSecond: Number.isFinite(trafficDeltas.eth0_rx_bytes)
        ? (trafficDeltas.eth0_rx_bytes * 8) / intervalSeconds
        : null,
      eth0TxBitsPerSecond: Number.isFinite(trafficDeltas.eth0_tx_bytes)
        ? (trafficDeltas.eth0_tx_bytes * 8) / intervalSeconds
        : null,
      eth0RxErrors: counterDeltas.eth0_rx_errors,
      eth0RxDrops: counterDeltas.eth0_rx_drops,
      eth0TxErrors: counterDeltas.eth0_tx_errors,
      eth0TxDrops: counterDeltas.eth0_tx_drops,
      ciliumRxErrors: counterDeltas.cilium_rx_errors,
      ciliumRxDrops: counterDeltas.cilium_rx_drops,
      ciliumTxErrors: counterDeltas.cilium_tx_errors,
      ciliumTxDrops: counterDeltas.cilium_tx_drops,
      tcpRetransSegments: counterDeltas.tcp_retrans_segs,
      tcpInErrors: counterDeltas.tcp_in_errors,
      listenDrops: counterDeltas.tcp_ext_listen_drops,
      backlogDrops: counterDeltas.tcp_ext_backlog_drops,
      receiveQueueDrops: counterDeltas.tcp_ext_rcv_queue_drops,
    });
  }
  if (records.length === 0) {
    fail(`node '${node}' produced no valid one-second intervals`);
  }
  return records;
}

export function summarizePoolRecords(records, pool) {
  const selected = records.filter((record) => record.nodePool === pool);
  if (selected.length === 0) return null;
  const sum = (property) => sumFinite(selected.map((record) => record[property]));
  const packetDrops = [
    "eth0RxDrops",
    "eth0TxDrops",
    "ciliumRxDrops",
    "ciliumTxDrops",
  ].reduce((total, property) => total + sum(property), 0);
  const packetErrors = [
    "eth0RxErrors",
    "eth0TxErrors",
    "ciliumRxErrors",
    "ciliumTxErrors",
  ].reduce((total, property) => total + sum(property), 0);
  return {
    nodeCount: new Set(selected.map((record) => record.node)).size,
    intervalCount: selected.length,
    intervalSeconds: stats(selected.map((record) => record.intervalSeconds)),
    cpuPercent: stats(selected.map((record) => record.cpuPercent)),
    cpuPressurePercent: stats(
      selected.map((record) => record.cpuPressurePercent),
    ),
    memoryPressurePercent: stats(
      selected.map((record) => record.memoryPressurePercent),
    ),
    ioPressurePercent: stats(
      selected.map((record) => record.ioPressurePercent),
    ),
    stealPercent: stats(selected.map((record) => record.stealPercent)),
    softirqCpuPercent: stats(
      selected.map((record) => record.softirqCpuPercent),
    ),
    procsRunning: stats(selected.map((record) => record.procsRunning)),
    runQueue: stats(selected.map((record) => record.runQueue)),
    load1m: stats(selected.map((record) => record.load1m)),
    netRxSoftirqPerSecond: stats(
      selected.map((record) => record.netRxSoftirqPerSecond),
    ),
    eth0RxBitsPerSecond: stats(
      selected.map((record) => record.eth0RxBitsPerSecond),
    ),
    eth0TxBitsPerSecond: stats(
      selected.map((record) => record.eth0TxBitsPerSecond),
    ),
    network: {
      eth0RxBytes: sum("eth0RxBytes"),
      eth0RxPackets: sum("eth0RxPackets"),
      eth0TxBytes: sum("eth0TxBytes"),
      eth0TxPackets: sum("eth0TxPackets"),
      ciliumRxBytes: sum("ciliumRxBytes"),
      ciliumRxPackets: sum("ciliumRxPackets"),
      ciliumTxBytes: sum("ciliumTxBytes"),
      ciliumTxPackets: sum("ciliumTxPackets"),
      tcpRetransSegments: sum("tcpRetransSegments"),
      tcpInErrors: sum("tcpInErrors"),
      listenDrops: sum("listenDrops"),
      backlogDrops: sum("backlogDrops"),
      receiveQueueDrops: sum("receiveQueueDrops"),
      eth0RxErrors: sum("eth0RxErrors"),
      eth0RxDrops: sum("eth0RxDrops"),
      eth0TxErrors: sum("eth0TxErrors"),
      eth0TxDrops: sum("eth0TxDrops"),
      ciliumRxErrors: sum("ciliumRxErrors"),
      ciliumRxDrops: sum("ciliumRxDrops"),
      ciliumTxErrors: sum("ciliumTxErrors"),
      ciliumTxDrops: sum("ciliumTxDrops"),
      packetDrops,
      packetErrors,
    },
  };
}

function summarizeWindow(records) {
  return {
    loadgen: summarizePoolRecords(records, "loadgen"),
    featbit: summarizePoolRecords(records, "featbit"),
  };
}

function inAnyWindow(timestamp, windows) {
  return windows.some(
    (window) => timestamp >= window.startUnixMs && timestamp <= window.endUnixMs,
  );
}

export function analyzeNodeEvidence({
  nodeSamples,
  rampStartUnixMs,
  rampEndUnixMs,
  formalRevisionTimesUnixMs = [],
}) {
  if (!Array.isArray(nodeSamples) || nodeSamples.length === 0) {
    fail("nodeSamples must be a non-empty array");
  }
  const nodes = new Set();
  const records = [];
  for (const sample of nodeSamples) {
    if (nodes.has(sample.node)) fail(`duplicate node evidence '${sample.node}'`);
    nodes.add(sample.node);
    records.push(
      ...buildNodeIntervalRecords({
        node: sample.node,
        rows: sample.rows,
      }),
    );
  }
  const rampRecords = records.filter(
    (record) =>
      record.observedAtUnixMs >= rampStartUnixMs &&
      record.observedAtUnixMs <= rampEndUnixMs,
  );
  const revisionWindows = formalRevisionTimesUnixMs.map((timestamp) => ({
    startUnixMs: timestamp - 1_000,
    endUnixMs: timestamp + 2_250,
  }));
  const formalRecords = records.filter((record) =>
    inAnyWindow(record.observedAtUnixMs, revisionWindows),
  );

  return {
    schemaVersion: 1,
    nodeCount: nodes.size,
    intervalRecordCount: records.length,
    windows: {
      full: {
        startUnixMs: Math.min(...records.map((record) => record.observedAtUnixMs)),
        endUnixMs: Math.max(...records.map((record) => record.observedAtUnixMs)),
        pools: summarizeWindow(records),
      },
      rampAndInitialSync: {
        startUnixMs: rampStartUnixMs,
        endUnixMs: rampEndUnixMs,
        intervalRecordCount: rampRecords.length,
        pools: summarizeWindow(rampRecords),
      },
      formalRevisionWindows: {
        revisionCount: revisionWindows.length,
        windowBeforeMs: 1_000,
        windowAfterMs: 2_250,
        intervalRecordCount: formalRecords.length,
        pools: summarizeWindow(formalRecords),
      },
    },
    perNode: [...nodes]
      .sort()
      .map((node) => ({
        node,
        pool: classifyNodePool(node),
        full: summarizePoolRecords(
          records
            .filter((record) => record.node === node)
            .map((record) => ({ ...record, nodePool: node })),
          node,
        ),
      })),
  };
}
