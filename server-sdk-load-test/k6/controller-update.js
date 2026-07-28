import exec from "k6/execution";
import http from "k6/http";
import { sleep } from "k6";

import {
  scheduledControllerDelaySeconds,
} from "./lib/controller-plan.js";
import {
  buildFeatureFlagUrl,
  buildTargetingUpdate,
  getDeterministicServedRevision,
  normalizeApiBaseUrl,
  validateControllerFlag,
} from "./lib/api-controller.js";
import { parseExpectedRevisions } from "./lib/probe.js";

function requiredString(name) {
  const value = String(__ENV[name] ?? "").trim();
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function integerEnv(name, fallback = 0) {
  const raw = String(__ENV[name] ?? "").trim();
  const value = raw ? Number(raw) : fallback;
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  return value;
}

function booleanEnv(name, fallback = false) {
  const raw = String(__ENV[name] ?? "").trim();
  return raw ? raw.toLowerCase() === "true" : fallback;
}

const API_URL = normalizeApiBaseUrl(requiredString("FEATBIT_API_URL"));
const ACCESS_TOKEN = requiredString("FEATBIT_API_ACCESS_TOKEN");
const ENVIRONMENT_ID = requiredString("FEATBIT_ENVIRONMENT_ID");
const FLAG_KEY = requiredString("CONTROLLER_FLAG_KEY");
const TARGET_REVISION = String(
  __ENV.CONTROLLER_TARGET_REVISION ?? __ENV.CONTROLLER_TARGET_VALUE ?? "",
).trim();
if (!TARGET_REVISION) {
  throw new Error("CONTROLLER_TARGET_REVISION is required");
}
const PHASE = requiredString("CONTROLLER_PHASE");
const RUN_ID = requiredString("RUN_ID");
const REVISION_INDEX = integerEnv("CONTROLLER_REVISION_INDEX");
const DUE_UNIX_MS = integerEnv("CONTROLLER_DUE_UNIX_MS");
const INITIAL_VALUE = String(__ENV.PROBE_INITIAL_VALUE ?? "baseline").trim();
const EXPECTED_REVISIONS = parseExpectedRevisions(__ENV.EXPECTED_REVISIONS);
const REQUIRED_REVISIONS = [
  INITIAL_VALUE,
  ...parseExpectedRevisions(
    __ENV.CONTROLLER_REQUIRED_REVISIONS ?? EXPECTED_REVISIONS.join(","),
  ),
];
const EXPECTED_VARIATION_TYPE = String(
  __ENV.CONTROLLER_VARIATION_TYPE ?? "",
).trim();
const ALLOW_ALREADY_SERVED = booleanEnv("CONTROLLER_ALLOW_ALREADY_SERVED");

export const options = {
  scenarios: {
    update: {
      executor: "shared-iterations",
      vus: 1,
      iterations: 1,
      maxDuration: "45s",
    },
  },
  systemTags: ["scenario", "name"],
};

function logTiming(event, atMs, attempt) {
  console.log(
    [
      "STREAM_CONTROL",
      "2",
      event,
      String(atMs),
      RUN_ID,
      ENVIRONMENT_ID,
      String(REVISION_INDEX),
      TARGET_REVISION,
      FLAG_KEY,
      String(attempt),
    ].join("|"),
  );
}

function request(method, url, body, operation) {
  const response = http.request(
    method,
    url,
    body === undefined ? null : JSON.stringify(body),
    {
      headers: {
        Accept: "application/json",
        Authorization: ACCESS_TOKEN,
        "Content-Type": "application/json",
      },
      redirects: 0,
      timeout: "15s",
      tags: { name: operation },
    },
  );

  let payload;
  try {
    payload = response.json();
  } catch {
    const error = new Error(`${operation} returned a non-JSON response`);
    error.status = response.status;
    throw error;
  }
  if (response.status !== 200 || payload?.success !== true) {
    const error = new Error(`${operation} failed with HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return payload.data;
}

function getFlag(url) {
  const flag = request("GET", url, undefined, "controller_get_flag");
  validateControllerFlag(
    flag,
    FLAG_KEY,
    REQUIRED_REVISIONS,
    EXPECTED_VARIATION_TYPE || undefined,
  );
  return flag;
}

function isRevisionConflict(error) {
  return (
    error?.status === 409 ||
    error?.status === 412 ||
    (error?.status === 400 && String(error.message).toLowerCase().includes("revision"))
  );
}

export default function () {
  const flagUrl = buildFeatureFlagUrl(API_URL, ENVIRONMENT_ID, FLAG_KEY);
  let scheduleApplied = false;

  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const flag = getFlag(flagUrl);
    if (getDeterministicServedRevision(flag) === TARGET_REVISION) {
      if (ALLOW_ALREADY_SERVED) {
        console.log(
          [
            "STREAM_CONTROLLER_RESULT",
            "1",
            RUN_ID,
            ENVIRONMENT_ID,
            FLAG_KEY,
            PHASE,
            TARGET_REVISION,
            "unchanged",
          ].join("|"),
        );
        return;
      }
      exec.test.abort(
        `feature flag '${FLAG_KEY}' already served the requested value before '${PHASE}'`,
      );
    }

    const payload = buildTargetingUpdate(
      flag,
      FLAG_KEY,
      REQUIRED_REVISIONS,
      TARGET_REVISION,
      `Load test ${RUN_ID}: ${PHASE}`,
      EXPECTED_VARIATION_TYPE || undefined,
    );
    if (!scheduleApplied) {
      const delaySeconds = scheduledControllerDelaySeconds(
        Date.now(),
        DUE_UNIX_MS,
      );
      if (delaySeconds > 0) {
        sleep(delaySeconds);
      }
      scheduledControllerDelaySeconds(Date.now(), DUE_UNIX_MS);
      scheduleApplied = true;
    }
    logTiming("request_start", Date.now(), attempt);
    try {
      request("PUT", `${flagUrl}/targeting`, payload, "controller_update_targeting");
      logTiming("request_end", Date.now(), attempt);
    } catch (error) {
      logTiming("request_error", Date.now(), attempt);
      if (attempt < 3 && isRevisionConflict(error)) {
        sleep(attempt * 0.25);
        continue;
      }
      throw error;
    }

    const verified = getFlag(flagUrl);
    if (getDeterministicServedRevision(verified) !== TARGET_REVISION) {
      throw new Error(`feature flag '${FLAG_KEY}' did not serve the requested revision`);
    }
    console.log(
      [
        "STREAM_CONTROLLER_RESULT",
        "1",
        RUN_ID,
        ENVIRONMENT_ID,
        FLAG_KEY,
        PHASE,
        TARGET_REVISION,
        "changed",
      ].join("|"),
    );
    return;
  }

  throw new Error(`controller update exhausted retries for '${FLAG_KEY}'`);
}

export function handleSummary() {
  return {};
}
