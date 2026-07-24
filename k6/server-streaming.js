import { sleep } from "k6";
import exec from "k6/execution";
import http from "k6/http";
import { Counter, Rate, Trend } from "k6/metrics";
import { WebSocket } from "k6/websockets";

import {
  buildFeatureFlagUrl,
  buildTargetingUpdate,
  getDeterministicServedValue,
  normalizeApiBaseUrl,
  validateControllerFlag,
} from "./lib/api-controller.js";
import { generateConnectionToken } from "./lib/connection-token.js";
import {
  expectedConnectionsPerRunner,
  remainingSetupBarrierMilliseconds,
  runnerIndexFromHostname,
} from "./lib/distribution.js";
import {
  postRampWarmupDurationSeconds,
  validatePostRampWarmupFlagKey,
} from "./lib/controller-plan.js";
import {
  extractProbeSnapshot,
  findFeatureFlag,
  parseExpectedRevisions,
  parseProbeFlagKeys,
  parseStreamingMessage,
} from "./lib/probe.js";
import {
  applyProbeSnapshot,
  createProbeState,
  initializeProbeState,
} from "./lib/probe-state.js";

function integerEnv(name, fallback, minimum = 1) {
  const rawValue = __ENV[name];
  const value = rawValue === undefined || rawValue === "" ? fallback : Number(rawValue);
  if (!Number.isInteger(value) || value < minimum) {
    throw new Error(`${name} must be an integer greater than or equal to ${minimum}`);
  }

  return value;
}

function booleanEnv(name, fallback = false) {
  const rawValue = __ENV[name];
  if (rawValue === undefined || rawValue === "") {
    return fallback;
  }

  return String(rawValue).toLowerCase() === "true";
}

const FEATBIT_STREAMING_URL = String(__ENV.FEATBIT_STREAMING_URL ?? "").trim();
const FEATBIT_SERVER_SECRET = String(__ENV.FEATBIT_SERVER_SECRET ?? "").trim();
const FEATBIT_API_URL = String(__ENV.FEATBIT_API_URL ?? "").trim();
const FEATBIT_API_ACCESS_TOKEN = String(__ENV.FEATBIT_API_ACCESS_TOKEN ?? "").trim();
const FEATBIT_ENVIRONMENT_ID = String(__ENV.FEATBIT_ENVIRONMENT_ID ?? "").trim();
const RUN_ID = String(__ENV.RUN_ID ?? "local-run").trim();
const PROBE_FLAG_KEYS = parseProbeFlagKeys(
  __ENV.PROBE_FLAG_KEYS ?? __ENV.PROBE_FLAG_KEY ?? "loadtest-sync-probe",
);
const POST_RAMP_WARMUP_FLAG_KEY = String(
  __ENV.POST_RAMP_WARMUP_FLAG_KEY ?? "",
).trim();
const PROBE_INITIAL_VALUE = String(__ENV.PROBE_INITIAL_VALUE ?? "baseline").trim();
const EXPECTED_REVISIONS = parseExpectedRevisions(__ENV.EXPECTED_REVISIONS);
const EXPECTED_REVISION_INDEX = Object.fromEntries(
  EXPECTED_REVISIONS.map((revision, index) => [revision, index]),
);

const MAX_CONNECTIONS = integerEnv("MAX_CONNECTIONS", 10_000);
const CONNECTIONS_PER_SECOND = integerEnv("CONNECTIONS_PER_SECOND", 200);
const LOADTEST_PARALLELISM = integerEnv("LOADTEST_PARALLELISM", 1);
const EXPECTED_CONNECTIONS_PER_RUNNER = expectedConnectionsPerRunner(
  MAX_CONNECTIONS,
  LOADTEST_PARALLELISM,
);
const RAMP_UP_SECONDS = Math.ceil(MAX_CONNECTIONS / CONNECTIONS_PER_SECOND);
const STABILIZATION_SECONDS = integerEnv("STABILIZATION_SECONDS", 30, 0);
const HOLD_DURATION_SECONDS = integerEnv("HOLD_DURATION_SECONDS", 600);
const DRAIN_DURATION_SECONDS = integerEnv("DRAIN_DURATION_SECONDS", 10, 2);

const PING_INTERVAL_SECONDS = integerEnv("PING_INTERVAL_SECONDS", 15);
const INITIAL_SYNC_TIMEOUT_SECONDS = integerEnv("INITIAL_SYNC_TIMEOUT_SECONDS", 20);
const HEARTBEAT_TIMEOUT_SECONDS = integerEnv(
  "HEARTBEAT_TIMEOUT_SECONDS",
  PING_INTERVAL_SECONDS * 3,
);
const INITIAL_SYNC_P99_MS = integerEnv("INITIAL_SYNC_P99_MS", 5_000);
const SYNC_P95_MS = integerEnv("SYNC_P95_MS", 500);
const SYNC_P99_MS = integerEnv("SYNC_P99_MS", 1_000);
const CLOCK_SKEW_TOLERANCE_MS = integerEnv("CLOCK_SKEW_TOLERANCE_MS", 1_000, 0);
const DEBUG = booleanEnv("DEBUG");
const STRICT_PATCH_DELIVERY = booleanEnv("STRICT_PATCH_DELIVERY");
const AUTO_CONTROL_REVISIONS = booleanEnv("AUTO_CONTROL_REVISIONS");
const CONTROLLER_WARMUP_SETTLE_SECONDS = integerEnv(
  "CONTROLLER_WARMUP_SETTLE_SECONDS",
  2,
  0,
);
const CONTROLLER_POST_RAMP_WARMUP_SETTLE_SECONDS = integerEnv(
  "CONTROLLER_POST_RAMP_WARMUP_SETTLE_SECONDS",
  2,
  0,
);
const CONTROLLER_START_DELAY_SECONDS = integerEnv("CONTROLLER_START_DELAY_SECONDS", 5, 0);
const CONTROLLER_REVISION_INTERVAL_SECONDS = integerEnv(
  "CONTROLLER_REVISION_INTERVAL_SECONDS",
  30,
);
const CONTROLLER_FINAL_SETTLE_SECONDS = integerEnv(
  "CONTROLLER_FINAL_SETTLE_SECONDS",
  30,
);
const DISTRIBUTED_SETUP_BARRIER_SECONDS = integerEnv(
  "DISTRIBUTED_SETUP_BARRIER_SECONDS",
  LOADTEST_PARALLELISM > 1 ? 60 : 0,
  0,
);
const DISTRIBUTED_TEARDOWN_GRACE_SECONDS = integerEnv(
  "DISTRIBUTED_TEARDOWN_GRACE_SECONDS",
  LOADTEST_PARALLELISM > 1 ? 30 : 0,
  0,
);

const RAMP_UP_MS = RAMP_UP_SECONDS * 1_000;
const STABILIZATION_MS = STABILIZATION_SECONDS * 1_000;
const HOLD_DURATION_MS = HOLD_DURATION_SECONDS * 1_000;
const DRAIN_DURATION_MS = DRAIN_DURATION_SECONDS * 1_000;
const PING_INTERVAL_MS = PING_INTERVAL_SECONDS * 1_000;
const INITIAL_SYNC_TIMEOUT_MS = INITIAL_SYNC_TIMEOUT_SECONDS * 1_000;
const HEARTBEAT_TIMEOUT_MS = HEARTBEAT_TIMEOUT_SECONDS * 1_000;
const FINALIZE_GRACE_MS = 1_000;
const REQUIRED_PROBE_VALUES = [PROBE_INITIAL_VALUE, ...EXPECTED_REVISIONS];

const FULL_DATA_SYNC_MESSAGE = JSON.stringify({
  messageType: "data-sync",
  data: { timestamp: 0 },
});
const PING_MESSAGE = JSON.stringify({ messageType: "ping", data: {} });

const connectionOpened = new Counter("connection_opened");
const fullSyncReceived = new Counter("full_sync_received");
const patchReceived = new Counter("patch_received");
const probePatchReceived = new Counter("probe_patch_received");
const pingSent = new Counter("ping_sent");
const pongReceived = new Counter("pong_received");
const unexpectedClose = new Counter("unexpected_close");
const websocketError = new Counter("websocket_error");
const invalidMessage = new Counter("invalid_message");
const initialSyncTimeout = new Counter("initial_sync_timeout");
const heartbeatTimeout = new Counter("heartbeat_timeout");
const duplicatePatch = new Counter("duplicate_patch");
const stalePatch = new Counter("stale_patch");
const repeatedRevision = new Counter("repeated_revision");
const revisionSequenceError = new Counter("revision_sequence_error");
const unexpectedRevision = new Counter("unexpected_revision");
const clockSkewDetected = new Counter("clock_skew_detected");
const probeRevisionReceived = new Counter("probe_revision_received");
const controllerApiError = new Counter("controller_api_error");
const controllerWarmupUpdates = new Counter("controller_warmup_updates");
const controllerPostRampWarmupUpdates = new Counter(
  "controller_post_ramp_warmup_updates",
);
const controllerRevisionUpdates = new Counter("controller_revision_updates");
const postRampWarmupPatchReceived = new Counter(
  "post_ramp_warmup_patch_received",
);

const connectionOpenSuccess = new Rate("connection_open_success");
const initialSyncSuccess = new Rate("initial_sync_success");
const readyBeforeHold = new Rate("ready_before_hold");
const connectionSurvived = new Rate("connection_survived");
const initialProbeValueSuccess = new Rate("initial_probe_value_success");
const postRampWarmupCoverage = new Rate("post_ramp_warmup_coverage");
const probeRevisionCoverage = new Rate("probe_revision_coverage");
const finalAppliedRevisionSuccess = new Rate("final_applied_revision_success");
const controllerUpdateSuccess = new Rate("controller_update_success");
const probeSyncOver60Ms = new Rate("probe_sync_over_60ms");
const probeSyncOver80Ms = new Rate("probe_sync_over_80ms");
const probeSyncOver100Ms = new Rate("probe_sync_over_100ms");

const connectionOpenLatency = new Trend("connection_open_latency_ms", true);
const initialSyncLatency = new Trend("initial_sync_latency_ms", true);
const postRampWarmupLatency = new Trend("post_ramp_warmup_latency_ms", true);
const probeSyncLatency = new Trend("probe_sync_latency_ms", true);
const probeSyncLatencyWithoutSpikes = new Trend(
  "probe_sync_latency_without_spikes_ms",
  true,
);
const applicationPongLatency = new Trend("application_pong_latency_ms", true);
const controllerApiLatency = new Trend("controller_api_latency_ms", true);

const ZERO_VALUE_COUNTERS = [
  unexpectedClose,
  websocketError,
  invalidMessage,
  initialSyncTimeout,
  heartbeatTimeout,
  revisionSequenceError,
  unexpectedRevision,
  clockSkewDetected,
];

if (STRICT_PATCH_DELIVERY) {
  ZERO_VALUE_COUNTERS.push(duplicatePatch, stalePatch, repeatedRevision);
}

const thresholds = {
  connection_opened: [
    `count>=${EXPECTED_CONNECTIONS_PER_RUNNER}`,
    `count<=${EXPECTED_CONNECTIONS_PER_RUNNER}`,
  ],
  connection_open_success: ["rate==1"],
  initial_sync_success: ["rate==1"],
  ready_before_hold: ["rate==1"],
  connection_survived: ["rate==1"],
  initial_probe_value_success: ["rate==1"],
  final_applied_revision_success: ["rate==1"],
  unexpected_close: ["count==0"],
  websocket_error: ["count==0"],
  invalid_message: ["count==0"],
  initial_sync_timeout: ["count==0"],
  heartbeat_timeout: ["count==0"],
  revision_sequence_error: ["count==0"],
  unexpected_revision: ["count==0"],
  clock_skew_detected: ["count==0"],
  initial_sync_latency_ms: [`p(99)<${INITIAL_SYNC_P99_MS}`],
  probe_sync_latency_ms: [`p(95)<${SYNC_P95_MS}`, `p(99)<${SYNC_P99_MS}`],
};

if (POST_RAMP_WARMUP_FLAG_KEY) {
  thresholds.post_ramp_warmup_coverage = ["rate==1"];
}

if (STRICT_PATCH_DELIVERY) {
  thresholds.duplicate_patch = ["count==0"];
  thresholds.stale_patch = ["count==0"];
  thresholds.repeated_revision = ["count==0"];
}

for (let index = 0; index < EXPECTED_REVISIONS.length; index += 1) {
  thresholds[`probe_revision_coverage{revision_index:${index + 1}}`] = ["rate==1"];
  thresholds[`probe_sync_latency_ms{revision_index:${index + 1}}`] = [
    `p(95)<${SYNC_P95_MS}`,
    `p(99)<${SYNC_P99_MS}`,
  ];
  thresholds[`probe_sync_over_100ms{revision_index:${index + 1}}`] = ["rate<=1"];
}

if (AUTO_CONTROL_REVISIONS && LOADTEST_PARALLELISM === 1) {
  thresholds.controller_api_error = ["count==0"];
  thresholds.controller_update_success = ["rate==1"];
  thresholds.controller_warmup_updates = [`count==${PROBE_FLAG_KEYS.length * 2}`];
  thresholds.controller_revision_updates = [
    `count==${PROBE_FLAG_KEYS.length * EXPECTED_REVISIONS.length}`,
  ];
}

const scenarios = {
  featbit_server_streaming: {
    executor: "ramping-vus",
    startVUs: 0,
    stages: [
      { duration: `${RAMP_UP_SECONDS}s`, target: MAX_CONNECTIONS },
      { duration: `${STABILIZATION_SECONDS}s`, target: MAX_CONNECTIONS },
      { duration: `${HOLD_DURATION_SECONDS}s`, target: MAX_CONNECTIONS },
      { duration: `${DRAIN_DURATION_SECONDS}s`, target: 0 },
    ],
    gracefulRampDown: `${DRAIN_DURATION_SECONDS + 5}s`,
  },
};

if (AUTO_CONTROL_REVISIONS) {
  scenarios.featbit_flag_controller = {
    executor: "shared-iterations",
    vus: 1,
    iterations: 1,
    startTime: `${RAMP_UP_SECONDS + STABILIZATION_SECONDS + CONTROLLER_START_DELAY_SECONDS}s`,
    maxDuration: `${CONTROLLER_REVISION_INTERVAL_SECONDS * EXPECTED_REVISIONS.length + 120}s`,
    exec: "controlProbeRevisions",
  };
}

export const options = {
  scenarios,
  thresholds,
  setupTimeout: "5m",
  teardownTimeout: "5m",
  // Every tokenized URL is unique and the token contains the server secret envelope.
  // Do not emit the default `url` system tag: it leaks credentials and creates 10k series.
  systemTags: ["scenario", "name"],
  summaryTrendStats: ["count", "avg", "min", "med", "max", "p(90)", "p(95)", "p(99)"],
};

function buildStreamingUrl() {
  const baseUrl = FEATBIT_STREAMING_URL.replace(/\/+$/, "");
  const endpoint = baseUrl.endsWith("/streaming") ? baseUrl : `${baseUrl}/streaming`;
  const token = generateConnectionToken(FEATBIT_SERVER_SECRET);
  return `${endpoint}?type=server&token=${encodeURIComponent(token)}`;
}

function reportInvalid(state, message) {
  invalidMessage.add(1);
  state.invalid = true;

  if (DEBUG && exec.vu.idInTest <= 5) {
    console.error(`[VU ${exec.vu.idInTest}] ${message}`);
  }
}

function getProbeTags(probeState) {
  return {
    flag_index: String(probeState.index + 1),
    flag_key: probeState.key,
  };
}

function recordProbePatch(snapshot, probeState) {
  const flagTags = getProbeTags(probeState);
  probePatchReceived.add(1, flagTags);
  const outcome = applyProbeSnapshot(probeState, snapshot, EXPECTED_REVISION_INDEX);
  const revisionTags = {
    ...flagTags,
    revision: snapshot.revision,
  };

  if (outcome.revisionIndex !== undefined) {
    revisionTags.revision_index = String(outcome.revisionIndex + 1);
  }

  if (outcome.kind === "duplicate") {
    if (STRICT_PATCH_DELIVERY) {
      duplicatePatch.add(1, revisionTags);
    }
    return;
  }

  if (outcome.kind === "stale") {
    if (STRICT_PATCH_DELIVERY) {
      stalePatch.add(1, revisionTags);
    }
    return;
  }

  if (outcome.kind === "repeated") {
    if (STRICT_PATCH_DELIVERY) {
      repeatedRevision.add(1, revisionTags);
    }
  } else if (outcome.kind === "unexpected") {
    unexpectedRevision.add(1, revisionTags);
  }

  if (outcome.sequenceError) {
    revisionSequenceError.add(1, revisionTags);
  }

  if (!outcome.firstSeen) {
    return;
  }

  const latencyMs = Date.now() - snapshot.updatedAtMs;
  if (latencyMs < -CLOCK_SKEW_TOLERANCE_MS) {
    clockSkewDetected.add(1, revisionTags);
  }

  probeSyncLatency.add(latencyMs, revisionTags);
  probeSyncOver60Ms.add(latencyMs > 60, revisionTags);
  probeSyncOver80Ms.add(latencyMs > 80, revisionTags);
  probeSyncOver100Ms.add(latencyMs > 100, revisionTags);
  if (latencyMs <= 100) {
    probeSyncLatencyWithoutSpikes.add(latencyMs, revisionTags);
  }
  probeRevisionReceived.add(1, revisionTags);
}

function recordPostRampWarmupPatch(snapshot, warmupState) {
  const warmupRevision = EXPECTED_REVISIONS[0];
  let phase;

  if (snapshot.revision === warmupRevision && !warmupState.revisionSeen) {
    warmupState.revisionSeen = true;
    phase = "revision";
  } else if (
    snapshot.revision === PROBE_INITIAL_VALUE &&
    warmupState.revisionSeen &&
    !warmupState.baselineSeen
  ) {
    warmupState.baselineSeen = true;
    phase = "baseline";
  } else {
    return;
  }

  const tags = {
    flag_key: POST_RAMP_WARMUP_FLAG_KEY,
    phase,
    revision: snapshot.revision,
  };
  postRampWarmupPatchReceived.add(1, tags);
  postRampWarmupLatency.add(Date.now() - snapshot.updatedAtMs, tags);
}

function controllerRequest(method, url, body, operation, tags = {}) {
  const response = http.request(method, url, body === undefined ? null : JSON.stringify(body), {
    headers: {
      Accept: "application/json",
      Authorization: FEATBIT_API_ACCESS_TOKEN,
      "Content-Type": "application/json",
    },
    redirects: 0,
    timeout: "15s",
    tags: { name: operation, ...tags },
  });

  controllerApiLatency.add(response.timings.duration, { operation, ...tags });

  let payload;
  try {
    payload = response.json();
  } catch (error) {
    const requestError = new Error(
      `${operation} returned HTTP ${response.status} with a non-JSON response`,
    );
    requestError.status = response.status;
    throw requestError;
  }

  if (response.status !== 200 || payload?.success !== true) {
    const apiErrors = Array.isArray(payload?.errors)
      ? payload.errors.map((entry) => (typeof entry === "string" ? entry : JSON.stringify(entry)))
      : [];
    const detail = apiErrors.length > 0 ? `: ${apiErrors.join("; ")}` : "";
    const requestError = new Error(`${operation} failed with HTTP ${response.status}${detail}`);
    requestError.status = response.status;
    throw requestError;
  }

  return payload.data;
}

function getControllerFlag(flagKey) {
  const flagUrl = buildFeatureFlagUrl(FEATBIT_API_URL, FEATBIT_ENVIRONMENT_ID, flagKey);
  const flag = controllerRequest("GET", flagUrl, undefined, "controller_get_flag", {
    flag_key: flagKey,
  });
  validateControllerFlag(flag, flagKey, REQUIRED_PROBE_VALUES);
  return flag;
}

function isRevisionConflict(error) {
  return (
    error?.status === 409 ||
    error?.status === 412 ||
    (error?.status === 400 && String(error.message).toLowerCase().includes("revision"))
  );
}

function setProbeFlagValue(
  flagKey,
  targetValue,
  phase,
  recordExpectedRevision,
  recordWarmupUpdate,
) {
  const metricTags = {
    flag_key: flagKey,
    phase,
    revision: targetValue,
  };

  try {
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      const flag = getControllerFlag(flagKey);
      if (getDeterministicServedValue(flag) === targetValue) {
        if (recordExpectedRevision || recordWarmupUpdate) {
          throw new Error(
            `feature flag '${flagKey}' already served '${targetValue}' before the controller update`,
          );
        }
        controllerUpdateSuccess.add(1, { ...metricTags, changed: "false" });
        return;
      }

      const payload = buildTargetingUpdate(
        flag,
        flagKey,
        REQUIRED_PROBE_VALUES,
        targetValue,
        `Load test ${RUN_ID}: ${phase}`,
      );
      const flagUrl = buildFeatureFlagUrl(FEATBIT_API_URL, FEATBIT_ENVIRONMENT_ID, flagKey);

      try {
        controllerRequest(
          "PUT",
          `${flagUrl}/targeting`,
          payload,
          "controller_update_targeting",
          metricTags,
        );
      } catch (error) {
        if (attempt < 3 && isRevisionConflict(error)) {
          sleep(attempt * 0.25);
          continue;
        }
        throw error;
      }

      const verifiedFlag = getControllerFlag(flagKey);
      const servedValue = getDeterministicServedValue(verifiedFlag);
      if (servedValue !== targetValue) {
        throw new Error(
          `feature flag '${flagKey}' served '${servedValue}' after updating it to '${targetValue}'`,
        );
      }

      controllerUpdateSuccess.add(1, { ...metricTags, changed: "true" });
      if (recordExpectedRevision) {
        controllerRevisionUpdates.add(1, metricTags);
      }
      if (recordWarmupUpdate) {
        controllerWarmupUpdates.add(1, metricTags);
      }
      return;
    }
  } catch (error) {
    controllerUpdateSuccess.add(0, metricTags);
    controllerApiError.add(1, metricTags);
    throw error;
  }
}

function setAllProbeFlags(
  targetValue,
  phase,
  recordExpectedRevision = false,
  recordWarmupUpdate = false,
) {
  for (const flagKey of PROBE_FLAG_KEYS) {
    setProbeFlagValue(
      flagKey,
      targetValue,
      phase,
      recordExpectedRevision,
      recordWarmupUpdate,
    );
  }
}

export function setup() {
  const setupStartedAt = Date.now();
  const errors = [];
  let runnerIndex = 1;

  try {
    runnerIndex = runnerIndexFromHostname(__ENV.HOSTNAME, LOADTEST_PARALLELISM);
  } catch (error) {
    errors.push(error.message);
  }

  const controlsProbeFlags = AUTO_CONTROL_REVISIONS && runnerIndex === 1;

  if (!/^wss?:\/\//.test(FEATBIT_STREAMING_URL)) {
    errors.push("FEATBIT_STREAMING_URL must start with ws:// or wss://");
  }
  if (FEATBIT_STREAMING_URL.includes("?")) {
    errors.push("FEATBIT_STREAMING_URL must be the base URL without query parameters");
  }
  if (!FEATBIT_SERVER_SECRET) {
    errors.push("FEATBIT_SERVER_SECRET is required");
  }
  if (PROBE_FLAG_KEYS.length === 0) {
    errors.push("PROBE_FLAG_KEYS must contain at least one key");
  }
  try {
    validatePostRampWarmupFlagKey(POST_RAMP_WARMUP_FLAG_KEY, PROBE_FLAG_KEYS);
  } catch (error) {
    errors.push(error.message);
  }
  if (!PROBE_INITIAL_VALUE) {
    errors.push("PROBE_INITIAL_VALUE is required");
  }
  if (EXPECTED_REVISIONS.length === 0) {
    errors.push("EXPECTED_REVISIONS must contain at least one value");
  }
  if (EXPECTED_REVISION_INDEX[PROBE_INITIAL_VALUE] !== undefined) {
    errors.push("PROBE_INITIAL_VALUE must not also appear in EXPECTED_REVISIONS");
  }
  if (HEARTBEAT_TIMEOUT_SECONDS <= PING_INTERVAL_SECONDS) {
    errors.push("HEARTBEAT_TIMEOUT_SECONDS must be greater than PING_INTERVAL_SECONDS");
  }
  if (INITIAL_SYNC_TIMEOUT_SECONDS > STABILIZATION_SECONDS && STABILIZATION_SECONDS > 0) {
    errors.push("STABILIZATION_SECONDS must be at least INITIAL_SYNC_TIMEOUT_SECONDS");
  }
  if (controlsProbeFlags) {
    try {
      normalizeApiBaseUrl(FEATBIT_API_URL);
    } catch (error) {
      errors.push(error.message);
    }
    if (!FEATBIT_API_ACCESS_TOKEN) {
      errors.push("FEATBIT_API_ACCESS_TOKEN is required when AUTO_CONTROL_REVISIONS=true");
    }
    if (!FEATBIT_ENVIRONMENT_ID) {
      errors.push("FEATBIT_ENVIRONMENT_ID is required when AUTO_CONTROL_REVISIONS=true");
    }

    const postRampWarmupSeconds = postRampWarmupDurationSeconds(
      POST_RAMP_WARMUP_FLAG_KEY,
      CONTROLLER_POST_RAMP_WARMUP_SETTLE_SECONDS,
    );
    const finalRevisionOffset =
      CONTROLLER_START_DELAY_SECONDS +
      postRampWarmupSeconds +
      CONTROLLER_REVISION_INTERVAL_SECONDS * (EXPECTED_REVISIONS.length - 1);
    if (finalRevisionOffset + CONTROLLER_FINAL_SETTLE_SECONDS > HOLD_DURATION_SECONDS) {
      errors.push(
        "The controller revision schedule and final settle period must fit inside HOLD_DURATION_SECONDS",
      );
    }
    if (LOADTEST_PARALLELISM > 1 && DISTRIBUTED_TEARDOWN_GRACE_SECONDS === 0) {
      errors.push(
        "DISTRIBUTED_TEARDOWN_GRACE_SECONDS must be greater than 0 for a distributed run",
      );
    }
  }

  if (errors.length > 0) {
    throw new Error(`Invalid test configuration:\n- ${errors.join("\n- ")}`);
  }

  if (controlsProbeFlags) {
    if (POST_RAMP_WARMUP_FLAG_KEY) {
      console.log(
        `[controller] restoring post-ramp warm-up flag '${POST_RAMP_WARMUP_FLAG_KEY}' to baseline`,
      );
      setProbeFlagValue(
        POST_RAMP_WARMUP_FLAG_KEY,
        PROBE_INITIAL_VALUE,
        "pre-run post-ramp warm-up baseline",
      );
    }

    console.log(`[controller] restoring ${PROBE_FLAG_KEYS.length} probe flag(s) to baseline`);
    setAllProbeFlags(PROBE_INITIAL_VALUE, "pre-run baseline");

    const warmupRevision = EXPECTED_REVISIONS[0];
    console.log(
      `[controller] pre-warming ${PROBE_FLAG_KEYS.length} probe flag(s): ` +
        `${PROBE_INITIAL_VALUE} -> ${warmupRevision} -> ${PROBE_INITIAL_VALUE}`,
    );
    setAllProbeFlags(warmupRevision, "pre-run warm-up revision", false, true);
    if (CONTROLLER_WARMUP_SETTLE_SECONDS > 0) {
      sleep(CONTROLLER_WARMUP_SETTLE_SECONDS);
    }
    setAllProbeFlags(PROBE_INITIAL_VALUE, "pre-run baseline after warm-up", false, true);
    if (CONTROLLER_WARMUP_SETTLE_SECONDS > 0) {
      sleep(CONTROLLER_WARMUP_SETTLE_SECONDS);
    }
  }

  const setupBarrierRemainingMs = remainingSetupBarrierMilliseconds(
    LOADTEST_PARALLELISM,
    DISTRIBUTED_SETUP_BARRIER_SECONDS,
    Date.now() - setupStartedAt,
  );
  if (setupBarrierRemainingMs > 0) {
    console.log(
      `[runner ${runnerIndex}] waiting ${Math.ceil(setupBarrierRemainingMs / 1_000)}s ` +
        "for the distributed setup barrier",
    );
    sleep(setupBarrierRemainingMs / 1_000);
  }

  let controllerDescription;
  if (controlsProbeFlags) {
    controllerDescription =
      `- REST controller: pre-warmed, then automatic ${PROBE_INITIAL_VALUE} -> ` +
      EXPECTED_REVISIONS.join(" -> ");
  } else if (AUTO_CONTROL_REVISIONS) {
    controllerDescription = "- REST controller: handled by runner 1";
  } else {
    controllerDescription =
      "- during the measured hold, update every probe flag in this order: " +
      EXPECTED_REVISIONS.join(" -> ");
  }

  const holdStartsAt = RAMP_UP_SECONDS + STABILIZATION_SECONDS;
  console.log(
    [
      "FeatBit server-streaming load test",
      `- ${MAX_CONNECTIONS} connections, approximately ${CONNECTIONS_PER_SECOND}/s (${RAMP_UP_SECONDS}s ramp-up)`,
      `- runner ${runnerIndex}/${LOADTEST_PARALLELISM}: ${EXPECTED_CONNECTIONS_PER_RUNNER} connections`,
      `- measured hold: T+${holdStartsAt}s through T+${holdStartsAt + HOLD_DURATION_SECONDS}s`,
      `- probe flags (${PROBE_FLAG_KEYS.length}): ${PROBE_FLAG_KEYS.join(", ")}`,
      `- post-ramp warm-up flag: ${POST_RAMP_WARMUP_FLAG_KEY || "disabled"}`,
      `- initial value for every probe flag: ${PROBE_INITIAL_VALUE}`,
      controllerDescription,
      `- duplicate/stale patch delivery: ${STRICT_PATCH_DELIVERY ? "strict (recorded and fails the run)" : "ignored (SDK-compatible)"}`,
    ].join("\n"),
  );

  return { autoController: controlsProbeFlags };
}

export function controlProbeRevisions(data) {
  if (!data?.autoController) {
    return;
  }

  controllerApiError.add(0);
  try {
    if (POST_RAMP_WARMUP_FLAG_KEY) {
      const warmupRevision = EXPECTED_REVISIONS[0];
      console.log(
        `[controller] post-ramp warm-up on '${POST_RAMP_WARMUP_FLAG_KEY}': ` +
          `${PROBE_INITIAL_VALUE} -> ${warmupRevision} -> ${PROBE_INITIAL_VALUE}`,
      );
      setProbeFlagValue(
        POST_RAMP_WARMUP_FLAG_KEY,
        warmupRevision,
        "post-ramp warm-up revision",
      );
      controllerPostRampWarmupUpdates.add(1, {
        flag_key: POST_RAMP_WARMUP_FLAG_KEY,
        phase: "revision",
      });
      if (CONTROLLER_POST_RAMP_WARMUP_SETTLE_SECONDS > 0) {
        sleep(CONTROLLER_POST_RAMP_WARMUP_SETTLE_SECONDS);
      }
      setProbeFlagValue(
        POST_RAMP_WARMUP_FLAG_KEY,
        PROBE_INITIAL_VALUE,
        "post-ramp warm-up baseline",
      );
      controllerPostRampWarmupUpdates.add(1, {
        flag_key: POST_RAMP_WARMUP_FLAG_KEY,
        phase: "baseline",
      });
      if (CONTROLLER_POST_RAMP_WARMUP_SETTLE_SECONDS > 0) {
        sleep(CONTROLLER_POST_RAMP_WARMUP_SETTLE_SECONDS);
      }
    }

    for (let index = 0; index < EXPECTED_REVISIONS.length; index += 1) {
      const revision = EXPECTED_REVISIONS[index];
      console.log(
        `[controller] applying ${revision} to ${PROBE_FLAG_KEYS.length} probe flag(s)`,
      );
      setAllProbeFlags(revision, `measured revision ${index + 1}`, true);

      if (index < EXPECTED_REVISIONS.length - 1) {
        sleep(CONTROLLER_REVISION_INTERVAL_SECONDS);
      }
    }
  } catch (error) {
    const message = `FeatBit REST controller failed: ${error.message}`;
    console.error(`[controller] ${message}`);
    exec.test.abort(message);
  }
}

export function teardown(data) {
  if (!data?.autoController) {
    return;
  }

  if (DISTRIBUTED_TEARDOWN_GRACE_SECONDS > 0) {
    console.log(
      `[controller] waiting ${DISTRIBUTED_TEARDOWN_GRACE_SECONDS}s for other runners to drain`,
    );
    sleep(DISTRIBUTED_TEARDOWN_GRACE_SECONDS);
  }

  console.log(`[controller] restoring ${PROBE_FLAG_KEYS.length} probe flag(s) to baseline`);
  setAllProbeFlags(PROBE_INITIAL_VALUE, "post-run baseline");
  if (POST_RAMP_WARMUP_FLAG_KEY) {
    console.log(
      `[controller] restoring post-ramp warm-up flag '${POST_RAMP_WARMUP_FLAG_KEY}' to baseline`,
    );
    setProbeFlagValue(
      POST_RAMP_WARMUP_FLAG_KEY,
      PROBE_INITIAL_VALUE,
      "post-run warm-up baseline",
    );
  }
}

export default function () {
  for (const counter of ZERO_VALUE_COUNTERS) {
    counter.add(0);
  }

  const scenarioStartAt = exec.scenario.startTime;
  const holdStartsAt = scenarioStartAt + RAMP_UP_MS + STABILIZATION_MS;
  const plannedCloseAt = holdStartsAt + HOLD_DURATION_MS;
  const scenarioEndsAt = plannedCloseAt + DRAIN_DURATION_MS;
  const iterationStartedAt = Date.now();

  // A VU can be asked for another iteration while the executor drains. Never open a second socket.
  if (iterationStartedAt >= plannedCloseAt) {
    const remainingSeconds = (scenarioEndsAt - iterationStartedAt) / 1_000;
    if (remainingSeconds > 0) {
      sleep(remainingSeconds);
    }
    return;
  }

  const state = {
    opened: false,
    closed: false,
    plannedClose: false,
    hadError: false,
    invalid: false,
    initialSyncValid: false,
    initialSyncAt: null,
    initialSyncTimedOut: false,
    heartbeatTimedOut: false,
    lastPongAt: null,
    lastPingSentAt: null,
    probes: PROBE_FLAG_KEYS.map((key, index) =>
      createProbeState(key, index, EXPECTED_REVISIONS.length),
    ),
    postRampWarmup: {
      revisionSeen: false,
      baselineSeen: false,
    },
    finalized: false,
  };

  let socket;
  let pingTimer;
  let initialSyncTimer;

  const finalize = () => {
    if (state.finalized) {
      return;
    }
    state.finalized = true;

    if (pingTimer !== undefined) {
      clearInterval(pingTimer);
    }
    if (initialSyncTimer !== undefined) {
      clearTimeout(initialSyncTimer);
    }

    connectionOpenSuccess.add(state.opened);
    initialSyncSuccess.add(state.initialSyncValid && !state.initialSyncTimedOut);
    readyBeforeHold.add(
      state.opened &&
        state.initialSyncValid &&
        state.initialSyncAt !== null &&
        state.initialSyncAt <= holdStartsAt,
    );
    connectionSurvived.add(
      state.opened && !state.hadError && !state.heartbeatTimedOut && !state.invalid,
    );
    initialProbeValueSuccess.add(
      state.probes.every((probeState) => probeState.initialValueValid),
    );
    if (POST_RAMP_WARMUP_FLAG_KEY) {
      postRampWarmupCoverage.add(
        state.postRampWarmup.revisionSeen && state.postRampWarmup.baselineSeen,
      );
    }

    for (let index = 0; index < EXPECTED_REVISIONS.length; index += 1) {
      probeRevisionCoverage.add(
        state.probes.every((probeState) => probeState.seenRevisions[index]),
        {
          revision_index: String(index + 1),
          revision: EXPECTED_REVISIONS[index],
        },
      );
    }

    finalAppliedRevisionSuccess.add(
      state.probes.every(
        (probeState) =>
          probeState.appliedRevision === EXPECTED_REVISIONS[EXPECTED_REVISIONS.length - 1],
      ),
    );

    if (socket && socket.readyState === 1) {
      state.plannedClose = true;
      socket.close();
    }
  };

  try {
    socket = new WebSocket(buildStreamingUrl(), [], {
      tags: { name: "featbit-server-streaming", sdk_type: "server" },
    });
  } catch (error) {
    websocketError.add(1);
    state.hadError = true;
    if (DEBUG && exec.vu.idInTest <= 5) {
      console.error(`[VU ${exec.vu.idInTest}] failed to create WebSocket: ${error.message}`);
    }
  }

  if (socket) {
    socket.onopen = () => {
      const now = Date.now();
      state.opened = true;
      state.lastPongAt = now;
      connectionOpened.add(1);
      connectionOpenLatency.add(now - iterationStartedAt);

      socket.send(FULL_DATA_SYNC_MESSAGE);

      initialSyncTimer = setTimeout(() => {
        if (!state.initialSyncValid && !state.initialSyncTimedOut) {
          state.initialSyncTimedOut = true;
          initialSyncTimeout.add(1);
        }
      }, INITIAL_SYNC_TIMEOUT_MS);

      pingTimer = setInterval(() => {
        const pingAt = Date.now();
        if (
          !state.heartbeatTimedOut &&
          state.lastPongAt !== null &&
          pingAt - state.lastPongAt > HEARTBEAT_TIMEOUT_MS
        ) {
          state.heartbeatTimedOut = true;
          heartbeatTimeout.add(1);
        }

        if (socket.readyState === 1) {
          try {
            state.lastPingSentAt = pingAt;
            socket.send(PING_MESSAGE);
            pingSent.add(1);
          } catch (error) {
            websocketError.add(1);
            state.hadError = true;
          }
        }
      }, PING_INTERVAL_MS);
    };

    socket.onmessage = (event) => {
      let message;
      try {
        message = parseStreamingMessage(event.data);
      } catch (error) {
        reportInvalid(state, error.message);
        return;
      }

      if (message.kind === "ignored") {
        return;
      }

      if (message.kind === "pong") {
        const now = Date.now();
        pongReceived.add(1);
        state.lastPongAt = now;
        if (state.lastPingSentAt !== null) {
          applicationPongLatency.add(now - state.lastPingSentAt);
        }
        return;
      }

      if (message.eventType === "full") {
        fullSyncReceived.add(1);
        if (state.initialSyncAt !== null) {
          reportInvalid(state, "received more than one full data-sync response");
          return;
        }

        state.initialSyncAt = Date.now();
        let allProbeConfigsValid = true;

        for (const probeState of state.probes) {
          const probeFlag = findFeatureFlag(message.featureFlags, probeState.key);
          if (!probeFlag) {
            allProbeConfigsValid = false;
            reportInvalid(
              state,
              `full data-sync did not contain probe flag '${probeState.key}'`,
            );
            continue;
          }

          try {
            const snapshot = extractProbeSnapshot(probeFlag);
            probeState.initialValueValid = snapshot.revision === PROBE_INITIAL_VALUE;
            initializeProbeState(probeState, snapshot);

            if (!probeState.initialValueValid) {
              reportInvalid(
                state,
                `probe flag '${probeState.key}' initial value was '${snapshot.revision}', expected '${PROBE_INITIAL_VALUE}'`,
              );
            }
          } catch (error) {
            allProbeConfigsValid = false;
            reportInvalid(state, `probe flag '${probeState.key}': ${error.message}`);
          }
        }

        state.initialSyncValid = allProbeConfigsValid;
        if (state.initialSyncValid) {
          initialSyncLatency.add(state.initialSyncAt - iterationStartedAt);
        }
        return;
      }

      patchReceived.add(1);
      if (POST_RAMP_WARMUP_FLAG_KEY) {
        const warmupFlag = findFeatureFlag(
          message.featureFlags,
          POST_RAMP_WARMUP_FLAG_KEY,
        );
        if (warmupFlag) {
          try {
            recordPostRampWarmupPatch(
              extractProbeSnapshot(warmupFlag),
              state.postRampWarmup,
            );
          } catch (error) {
            reportInvalid(
              state,
              `post-ramp warm-up flag '${POST_RAMP_WARMUP_FLAG_KEY}': ${error.message}`,
            );
          }
        }
      }

      for (const probeState of state.probes) {
        const probeFlag = findFeatureFlag(message.featureFlags, probeState.key);
        if (!probeFlag) {
          continue;
        }

        try {
          recordProbePatch(extractProbeSnapshot(probeFlag), probeState);
        } catch (error) {
          reportInvalid(state, `probe flag '${probeState.key}': ${error.message}`);
        }
      }
    };

    socket.onerror = (event) => {
      websocketError.add(1);
      state.hadError = true;
      if (DEBUG && exec.vu.idInTest <= 5) {
        console.error(`[VU ${exec.vu.idInTest}] WebSocket error: ${event?.error ?? "unknown"}`);
      }
    };

    socket.onclose = (event) => {
      state.closed = true;
      if (pingTimer !== undefined) {
        clearInterval(pingTimer);
      }

      if (!state.plannedClose && Date.now() < plannedCloseAt) {
        unexpectedClose.add(1, {
          close_code: String(event?.code ?? "unknown"),
        });
        state.hadError = true;
      }
    };
  }

  setTimeout(() => {
    state.plannedClose = true;
    if (pingTimer !== undefined) {
      clearInterval(pingTimer);
    }
    if (socket && socket.readyState === 1) {
      socket.close();
    }
  }, Math.max(0, plannedCloseAt - Date.now()));

  // Keep the original iteration alive through the drain stage so ramping-vus never
  // starts a second WebSocket iteration for the same VU.
  setTimeout(finalize, Math.max(0, scenarioEndsAt + FINALIZE_GRACE_MS - Date.now()));
}
