import test from "node:test";
import assert from "node:assert/strict";

import {
  analyzeNodeEvidence,
  classifyNodePool,
  parseOneSecondTsv,
} from "../dotnet-sdk-runner/analysis/node-evidence-analysis.js";

const header = [
  "observed_at_utc",
  "uptime_seconds",
  "cpu_user",
  "cpu_nice",
  "cpu_system",
  "cpu_idle",
  "cpu_iowait",
  "cpu_irq",
  "cpu_softirq",
  "cpu_steal",
  "procs_running",
  "run_queue",
  "load_1m",
  "cpu_pressure_some_usec",
  "memory_pressure_some_usec",
  "io_pressure_some_usec",
  "softirq_net_rx",
  "eth0_rx_bytes",
  "eth0_rx_packets",
  "eth0_tx_bytes",
  "eth0_tx_packets",
  "cilium_rx_bytes",
  "cilium_rx_packets",
  "cilium_tx_bytes",
  "cilium_tx_packets",
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

function row({
  second,
  user,
  idle,
  softirq = 0,
  pressure = 0,
  retrans = 0,
  drops = 0,
}) {
  const values = {
    observed_at_utc: new Date(1_000_000 + second * 1000).toISOString(),
    uptime_seconds: 100 + second,
    cpu_user: user,
    cpu_nice: 0,
    cpu_system: 0,
    cpu_idle: idle,
    cpu_iowait: 0,
    cpu_irq: 0,
    cpu_softirq: softirq,
    cpu_steal: 0,
    procs_running: second + 1,
    run_queue: second + 1,
    load_1m: second,
    cpu_pressure_some_usec: pressure,
    memory_pressure_some_usec: 0,
    io_pressure_some_usec: 0,
    softirq_net_rx: second * 10,
    eth0_rx_bytes: second * 1000,
    eth0_rx_packets: second * 10,
    eth0_tx_bytes: second * 2000,
    eth0_tx_packets: second * 20,
    cilium_rx_bytes: second * 100,
    cilium_rx_packets: second,
    cilium_tx_bytes: second * 200,
    cilium_tx_packets: second * 2,
    eth0_rx_errors: 0,
    eth0_rx_drops: drops,
    eth0_tx_errors: 0,
    eth0_tx_drops: 0,
    cilium_rx_errors: 0,
    cilium_rx_drops: 0,
    cilium_tx_errors: 0,
    cilium_tx_drops: 0,
    tcp_retrans_segs: retrans,
    tcp_in_errors: 0,
    tcp_ext_listen_drops: 0,
    tcp_ext_backlog_drops: 0,
    tcp_ext_rcv_queue_drops: 0,
  };
  return header.map((name) => values[name]).join("\t");
}

function sampleTsv() {
  return [
    header.join("\t"),
    row({ second: 0, user: 100, idle: 900 }),
    row({
      second: 1,
      user: 200,
      idle: 1200,
      softirq: 20,
      pressure: 100_000,
      retrans: 2,
      drops: 1,
    }),
    row({
      second: 2,
      user: 400,
      idle: 1400,
      softirq: 40,
      pressure: 300_000,
      retrans: 5,
      drops: 1,
    }),
  ].join("\n");
}

test("classifies current and isolated AKS node-pool names", () => {
  assert.equal(classifyNodePool("aks-loadgen-123-vmss000001"), "loadgen");
  assert.equal(classifyNodePool("aks-loadgen3k-123-vmss000001"), "loadgen");
  assert.equal(classifyNodePool("aks-featbit-123-vmss000001"), "featbit");
  assert.equal(classifyNodePool("aks-els3k-123-vmss000001"), "featbit");
});

test("parses one-second TSV and summarizes ramp and network deltas", () => {
  const rows = parseOneSecondTsv(sampleTsv());
  const result = analyzeNodeEvidence({
    nodeSamples: [
      { node: "aks-loadgen-123-vmss000001", rows },
      { node: "aks-featbit-123-vmss000001", rows },
    ],
    rampStartUnixMs: 1_001_000,
    rampEndUnixMs: 1_002_000,
    formalRevisionTimesUnixMs: [1_001_000],
  });
  const loadgen = result.windows.full.pools.loadgen;
  assert.equal(result.nodeCount, 2);
  assert.equal(loadgen.intervalCount, 2);
  assert.equal(loadgen.network.tcpRetransSegments, 5);
  assert.equal(loadgen.network.packetDrops, 1);
  assert.equal(loadgen.network.eth0RxBytes, 2000);
  assert.equal(loadgen.network.eth0TxPackets, 40);
  assert.equal(loadgen.eth0RxBitsPerSecond.max, 8000);
  assert.equal(loadgen.cpuPressurePercent.max, 20);
  assert.equal(loadgen.runQueue.max, 3);
  assert.equal(result.windows.rampAndInitialSync.intervalRecordCount, 4);
  assert.equal(
    result.windows.formalRevisionWindows.pools.featbit.network.tcpRetransSegments,
    5,
  );
});

test("rejects malformed TSV instead of silently treating missing counters as zero", () => {
  const malformed = sampleTsv().replace("tcp_retrans_segs", "missing_retrans");
  assert.throws(
    () => parseOneSecondTsv(malformed),
    /missing required column 'tcp_retrans_segs'/,
  );
});
