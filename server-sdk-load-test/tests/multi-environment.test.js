import assert from "node:assert/strict";
import test from "node:test";

import {
  assignEnvironmentToConnection,
  connectionsPerEnvironmentPerRunner,
  parseMultiEnvironmentSecret,
  validateMultiEnvironmentTopology,
} from "../k6/lib/multi-environment.js";

function secretDocument(environmentCount = 100) {
  return JSON.stringify({
    schemaVersion: 1,
    experimentId: "sdk-menv-g5-v1",
    projectId: "project-id",
    targetEnvironmentId: "environment-001",
    environments: Array.from({ length: environmentCount }, (_, offset) => ({
      index: offset + 1,
      id: `environment-${String(offset + 1).padStart(3, "0")}`,
      key: `sdk-menv-g5-v1-env-${String(offset + 1).padStart(3, "0")}`,
      serverSecret: `server-secret-${offset + 1}`,
    })),
  });
}

test("parses and validates a 100-environment secret without exposing values", () => {
  const parsed = parseMultiEnvironmentSecret(secretDocument());

  assert.equal(parsed.environments.length, 100);
  assert.equal(parsed.targetEnvironmentId, "environment-001");
  assert.equal(parsed.targetEnvironmentKey, "sdk-menv-g5-v1-env-001");
});

test("assigns exactly five connections to every environment on every runner", () => {
  const { environments } = parseMultiEnvironmentSecret(secretDocument());
  const counts = new Map(environments.map((environment) => [environment.id, 0]));

  for (let localConnectionIndex = 1; localConnectionIndex <= 500; localConnectionIndex += 1) {
    const environment = assignEnvironmentToConnection(
      localConnectionIndex,
      environments,
      500,
    );
    counts.set(environment.id, counts.get(environment.id) + 1);
  }

  assert.deepEqual([...new Set(counts.values())], [5]);
});

test("validates the fixed 20 x 500 multi-environment topology", () => {
  assert.deepEqual(
    validateMultiEnvironmentTopology({
      environmentCount: 100,
      parallelism: 20,
      connectionsPerRunner: 500,
      connectionsPerEnvironmentPerRunner: 5,
      totalConnections: 10_000,
    }),
    {
      environmentCount: 100,
      parallelism: 20,
      connectionsPerRunner: 500,
      connectionsPerEnvironmentPerRunner: 5,
      connectionsPerEnvironment: 100,
      totalConnections: 10_000,
    },
  );
});

test("rejects non-divisible and non-contiguous mappings", () => {
  assert.throws(
    () => connectionsPerEnvironmentPerRunner(500, 99),
    /must be divisible/,
  );

  const invalid = JSON.parse(secretDocument(2));
  invalid.environments[1].index = 3;
  assert.throws(
    () => parseMultiEnvironmentSecret(JSON.stringify(invalid)),
    /contiguous/,
  );
});
