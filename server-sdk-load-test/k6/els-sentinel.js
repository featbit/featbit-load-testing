import exec from "k6/execution";
import { Counter, Trend } from "k6/metrics";
import { WebSocket } from "k6/websockets";

import { generateConnectionToken } from "./lib/connection-token.js";
import {
  extractProbeSnapshot,
  findFeatureFlag,
  parseExpectedRevisions,
  parseProbeFlagKeys,
  parseStreamingMessage,
} from "./lib/probe.js";
import {
  assignSentinelConnection,
  formatSentinelRecord,
  parseSentinelTargets,
} from "./lib/sentinel.js";

function integerEnv(name, fallback, minimum = 1) {
  const rawValue = __ENV[name];
  const value = rawValue === undefined || rawValue === "" ? fallback : Number(rawValue);
  if (!Number.isInteger(value) || value < minimum) {
    throw new Error(`${name} must be an integer greater than or equal to ${minimum}`);
  }
  return value;
}

const RUN_ID = String(__ENV.RUN_ID ?? "").trim();
const NODE_NAME = String(__ENV.NODE_NAME ?? "").trim();
const POD_NAME = String(__ENV.POD_NAME ?? "").trim();
const FEATBIT_SERVER_SECRET = String(__ENV.FEATBIT_SERVER_SECRET ?? "").trim();
const TARGETS = parseSentinelTargets(__ENV.ELS_SENTINEL_TARGETS);
const CONNECTIONS_PER_TARGET = integerEnv("SENTINEL_CONNECTIONS_PER_TARGET", 3);
const TOTAL_CONNECTIONS = TARGETS.length * CONNECTIONS_PER_TARGET;
const HOLD_SECONDS = integerEnv("SENTINEL_HOLD_SECONDS", 1_800, 60);
const PING_INTERVAL_SECONDS = integerEnv("PING_INTERVAL_SECONDS", 15);
const INITIAL_SYNC_TIMEOUT_SECONDS = integerEnv(
  "INITIAL_SYNC_TIMEOUT_SECONDS",
  20,
);
const PROBE_FLAG_KEY = String(
  __ENV.PROBE_FLAG_KEY ??
    parseProbeFlagKeys(__ENV.PROBE_FLAG_KEYS ?? "loadtest-sync-probe-01")[0],
).trim();
const PROBE_INITIAL_VALUE = String(__ENV.PROBE_INITIAL_VALUE ?? "baseline").trim();
const EXPECTED_REVISIONS = parseExpectedRevisions(__ENV.EXPECTED_REVISIONS);
const EXPECTED_REVISION_INDEX = Object.fromEntries(
  EXPECTED_REVISIONS.map((revision, index) => [revision, index + 1]),
);

for (const [name, value] of Object.entries({
  RUN_ID,
  NODE_NAME,
  POD_NAME,
  FEATBIT_SERVER_SECRET,
  PROBE_FLAG_KEY,
})) {
  if (!value) {
    throw new Error(`${name} must not be empty`);
  }
}

const FULL_DATA_SYNC_MESSAGE = JSON.stringify({
  messageType: "data-sync",
  data: { timestamp: 0 },
});
const PING_MESSAGE = JSON.stringify({ messageType: "ping", data: {} });

const connectionOpened = new Counter("sentinel_connection_opened");
const connectionReady = new Counter("sentinel_connection_ready");
const revisionReceived = new Counter("sentinel_revision_received");
const unexpectedClose = new Counter("sentinel_unexpected_close");
const websocketError = new Counter("sentinel_websocket_error");
const invalidMessage = new Counter("sentinel_invalid_message");
const initialSyncTimeout = new Counter("sentinel_initial_sync_timeout");
const rawLatency = new Trend("sentinel_updated_at_to_sdk_latency_ms", true);

const thresholds = {
  sentinel_connection_opened: [
    `count>=${TOTAL_CONNECTIONS}`,
    `count<=${TOTAL_CONNECTIONS}`,
  ],
  sentinel_connection_ready: [
    `count>=${TOTAL_CONNECTIONS}`,
    `count<=${TOTAL_CONNECTIONS}`,
  ],
  sentinel_unexpected_close: ["count==0"],
  sentinel_websocket_error: ["count==0"],
  sentinel_invalid_message: ["count==0"],
  sentinel_initial_sync_timeout: ["count==0"],
};

for (const target of TARGETS) {
  for (let revisionIndex = 1; revisionIndex <= EXPECTED_REVISIONS.length; revisionIndex += 1) {
    thresholds[
      `sentinel_revision_received{els_pod:${target.pod},revision_index:${revisionIndex}}`
    ] = [`count>=${CONNECTIONS_PER_TARGET}`];
  }
}

export const options = {
  scenarios: {
    els_sentinel: {
      executor: "constant-vus",
      vus: TOTAL_CONNECTIONS,
      duration: `${HOLD_SECONDS}s`,
      gracefulStop: "10s",
    },
  },
  thresholds,
  systemTags: ["scenario", "name"],
  summaryTrendStats: ["count", "avg", "min", "med", "max", "p(90)", "p(95)", "p(99)"],
};

function buildStreamingUrl(ip) {
  const token = generateConnectionToken(FEATBIT_SERVER_SECRET);
  return `ws://${ip}:5100/streaming?type=server&token=${encodeURIComponent(token)}`;
}

function tagsFor(assignment) {
  return {
    els_pod: assignment.target.pod,
    els_ip: assignment.target.ip,
    connection_index: String(assignment.connectionIndex),
  };
}

function logReady(assignment, readyAtMs) {
  console.log(
    formatSentinelRecord("READY", [
      RUN_ID,
      NODE_NAME,
      POD_NAME,
      assignment.target.pod,
      assignment.target.ip,
      assignment.connectionIndex,
      readyAtMs,
    ]),
  );
}

function logRevision(assignment, snapshot, receivedAtMs) {
  const revisionIndex = EXPECTED_REVISION_INDEX[snapshot.revision];
  console.log(
    formatSentinelRecord("EVENT", [
      RUN_ID,
      NODE_NAME,
      POD_NAME,
      assignment.target.pod,
      assignment.target.ip,
      assignment.connectionIndex,
      revisionIndex,
      snapshot.revision,
      receivedAtMs,
      snapshot.updatedAtMs,
    ]),
  );
}

export default function () {
  for (const metric of [
    unexpectedClose,
    websocketError,
    invalidMessage,
    initialSyncTimeout,
  ]) {
    metric.add(0);
  }

  const assignment = assignSentinelConnection(
    exec.vu.idInTest,
    TARGETS,
    CONNECTIONS_PER_TARGET,
  );
  const tags = tagsFor(assignment);
  const seenUpdates = new Set();
  let plannedClose = false;
  let ready = false;
  let initialTimer;
  let pingTimer;
  let socket;

  try {
    socket = new WebSocket(buildStreamingUrl(assignment.target.ip), [], {
      tags: {
        name: "featbit-els-direct-sentinel",
        ...tags,
      },
    });
  } catch (error) {
    websocketError.add(1, tags);
    console.error(
      `Sentinel failed to create a WebSocket for ${assignment.target.pod}: ${error.message}`,
    );
    return;
  }

  socket.onopen = () => {
    connectionOpened.add(1, tags);
    socket.send(FULL_DATA_SYNC_MESSAGE);

    initialTimer = setTimeout(() => {
      if (!ready) {
        initialSyncTimeout.add(1, tags);
      }
    }, INITIAL_SYNC_TIMEOUT_SECONDS * 1_000);

    pingTimer = setInterval(() => {
      if (socket.readyState === 1) {
        socket.send(PING_MESSAGE);
      }
    }, PING_INTERVAL_SECONDS * 1_000);
  };

  socket.onmessage = (event) => {
    let message;
    try {
      message = parseStreamingMessage(event.data);
    } catch (error) {
      invalidMessage.add(1, tags);
      console.error(
        `Sentinel received an invalid message from ${assignment.target.pod}: ${error.message}`,
      );
      return;
    }

    if (message.kind !== "data-sync") {
      return;
    }

    const flag = findFeatureFlag(message.featureFlags, PROBE_FLAG_KEY);
    if (!flag) {
      if (message.eventType === "full") {
        invalidMessage.add(1, tags);
      }
      return;
    }

    let snapshot;
    try {
      snapshot = extractProbeSnapshot(flag);
    } catch (error) {
      invalidMessage.add(1, tags);
      console.error(
        `Sentinel could not evaluate '${PROBE_FLAG_KEY}' from ${assignment.target.pod}: ${error.message}`,
      );
      return;
    }

    if (message.eventType === "full") {
      if (snapshot.revision !== PROBE_INITIAL_VALUE) {
        invalidMessage.add(1, tags);
        console.error(
          `Sentinel initial value from ${assignment.target.pod} was '${snapshot.revision}', expected '${PROBE_INITIAL_VALUE}'`,
        );
        return;
      }
      if (!ready) {
        ready = true;
        if (initialTimer !== undefined) {
          clearTimeout(initialTimer);
        }
        connectionReady.add(1, tags);
        logReady(assignment, Date.now());
      }
      return;
    }

    const revisionIndex = EXPECTED_REVISION_INDEX[snapshot.revision];
    if (revisionIndex === undefined) {
      return;
    }

    const updateIdentity = `${snapshot.revision}|${snapshot.updatedAtMs}`;
    if (seenUpdates.has(updateIdentity)) {
      return;
    }
    seenUpdates.add(updateIdentity);

    const receivedAtMs = Date.now();
    revisionReceived.add(1, {
      ...tags,
      revision: snapshot.revision,
      revision_index: String(revisionIndex),
    });
    rawLatency.add(receivedAtMs - snapshot.updatedAtMs, {
      ...tags,
      revision: snapshot.revision,
      revision_index: String(revisionIndex),
    });
    logRevision(assignment, snapshot, receivedAtMs);
  };

  socket.onerror = (event) => {
    websocketError.add(1, tags);
    console.error(
      `Sentinel WebSocket error from ${assignment.target.pod}: ${event?.error ?? "unknown"}`,
    );
  };

  socket.onclose = (event) => {
    if (pingTimer !== undefined) {
      clearInterval(pingTimer);
    }
    if (!plannedClose) {
      unexpectedClose.add(1, {
        ...tags,
        close_code: String(event?.code ?? "unknown"),
      });
    }
  };

  setTimeout(() => {
    plannedClose = true;
    if (pingTimer !== undefined) {
      clearInterval(pingTimer);
    }
    if (socket.readyState === 1) {
      socket.close();
    }
  }, Math.max(1_000, (HOLD_SECONDS - 2) * 1_000));
}
