import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const matrixPath = new URL(
  "../k8s-infra/matrices/aks-single-environment-3k-flags-g5-d4-els3.json",
  import.meta.url,
);
const expandedMatrixPath = new URL(
  "../k8s-infra/matrices/aks-single-environment-3k-flags-g5-d4-els3-expanded.json",
  import.meta.url,
);
const dotnetPilotMatrixPath = new URL(
  "../k8s-infra/matrices/aks-single-environment-3k-flags-dotnet-sdk-p500.json",
  import.meta.url,
);
const expandedDotnetPilotMatrixPath = new URL(
  "../k8s-infra/matrices/aks-single-environment-3k-flags-dotnet-sdk-p500-els-expanded.json",
  import.meta.url,
);
const isolatedMatrixPath = new URL(
  "../k8s-infra/matrices/aks-single-environment-3k-flags-g5-d4-isolated.json",
  import.meta.url,
);
const isolatedTemplatePath = new URL(
  "../k8s-infra/templates/testrun-aks-large-flagset-isolated.yaml",
  import.meta.url,
);
const originalLargeFlagsetTemplatePath = new URL(
  "../k8s-infra/templates/testrun-aks-large-flagset.yaml",
  import.meta.url,
);
const nodePoolScriptPath = new URL(
  "../k8s-infra/scripts/ensure-aks-large-flagset-node-pools.ps1",
  import.meta.url,
);
const historicalMatrixPath = new URL(
  "../k8s-infra/matrices/aks-multi-environment-g5-d4-els3.json",
  import.meta.url,
);

test("large flag-set matrix is one environment with 8 string and 2 JSON revisions", async () => {
  const matrix = JSON.parse(await readFile(matrixPath, "utf8"));

  assert.equal(matrix.flagCount, 3_000);
  assert.equal(matrix.stringFlagCount, 2_500);
  assert.equal(matrix.jsonFlagCount, 500);
  assert.equal(matrix.parallelism, 20);
  assert.equal(matrix.connectionsPerRunner, 500);
  assert.equal(matrix.totalConnections, 10_000);
  assert.equal(matrix.connectionsPerSecond, 100);
  assert.equal(
    matrix.revisionPlan.filter((step) => step.variationType === "string").length,
    8,
  );
  assert.equal(
    matrix.revisionPlan.filter((step) => step.variationType === "json").length,
    2,
  );
});

test("expanded ELS profile preserves the workload and runner contracts", async () => {
  const baseline = JSON.parse(await readFile(matrixPath, "utf8"));
  const expanded = JSON.parse(await readFile(expandedMatrixPath, "utf8"));

  for (const property of [
    "experimentId",
    "environmentKey",
    "flagPrefix",
    "flagCount",
    "stringFlagCount",
    "jsonFlagCount",
    "jsonVariationBytes",
    "parallelism",
    "connectionsPerRunner",
    "totalConnections",
    "connectionsPerSecond",
    "rampDurationSeconds",
  ]) {
    assert.deepEqual(expanded[property], baseline[property], property);
  }
  assert.deepEqual(expanded.revisionPlan, baseline.revisionPlan);
  assert.deepEqual(
    expanded.fixedInfrastructure.runnerResources,
    baseline.fixedInfrastructure.runnerResources,
  );
  assert.deepEqual(expanded.fixedInfrastructure.elsResources, {
    cpuRequest: "1",
    cpuLimit: "3",
    memoryRequest: "2Gi",
    memoryLimit: "8Gi",
  });
});

test("expanded .NET pilot profile changes only the ELS resource envelope", async () => {
  const baseline = JSON.parse(await readFile(dotnetPilotMatrixPath, "utf8"));
  const expanded = JSON.parse(
    await readFile(expandedDotnetPilotMatrixPath, "utf8"),
  );

  for (const property of [
    "experimentId",
    "resourceExperimentId",
    "environmentKey",
    "flagPrefix",
    "flagCount",
    "stringFlagCount",
    "jsonFlagCount",
    "jsonVariationBytes",
    "parallelism",
    "connectionsPerRunner",
    "totalConnections",
    "connectionsPerSecond",
    "rampDurationSeconds",
    "crossNodeClockToleranceMs",
  ]) {
    assert.deepEqual(expanded[property], baseline[property], property);
  }
  assert.deepEqual(expanded.revisionPlan, baseline.revisionPlan);
  assert.equal(baseline.crossNodeClockToleranceMs, 10);
  assert.deepEqual(
    expanded.fixedInfrastructure.runnerResources,
    baseline.fixedInfrastructure.runnerResources,
  );
  assert.deepEqual(expanded.fixedInfrastructure.elsResources, {
    cpuRequest: "1",
    cpuLimit: "3",
    memoryRequest: "2Gi",
    memoryLimit: "8Gi",
  });
});

test("isolated large-flagset profile preserves the workload and leaves historical pools intact", async () => {
  const baseline = JSON.parse(await readFile(matrixPath, "utf8"));
  const isolated = JSON.parse(await readFile(isolatedMatrixPath, "utf8"));
  const template = await readFile(isolatedTemplatePath, "utf8");

  for (const property of [
    "experimentId",
    "environmentKey",
    "flagPrefix",
    "flagCount",
    "stringFlagCount",
    "jsonFlagCount",
    "jsonVariationBytes",
    "parallelism",
    "connectionsPerRunner",
    "totalConnections",
    "connectionsPerSecond",
    "rampDurationSeconds",
  ]) {
    assert.deepEqual(isolated[property], baseline[property], property);
  }
  assert.deepEqual(isolated.revisionPlan, baseline.revisionPlan);
  assert.equal(isolated.fixedInfrastructure.featbitNodes, 3);
  assert.equal(isolated.fixedInfrastructure.loadgenNodes, 10);
  assert.deepEqual(
    isolated.fixedInfrastructure.additionalNodePools.map((pool) => ({
      name: pool.name,
      nodes: pool.nodes,
      vmSize: pool.vmSize,
    })),
    [
      { name: "loadgen3k", nodes: 10, vmSize: "Standard_D4ds_v5" },
      { name: "els3k", nodes: 3, vmSize: "Standard_D4ds_v5" },
    ],
  );
  assert.deepEqual(isolated.fixedInfrastructure.runnerPlacement, {
    nodeWorkloads: ["loadgen", "loadgen3k"],
    nodeCount: 20,
    runnersPerNode: 1,
  });
  assert.equal(
    isolated.fixedInfrastructure.elsPlacement.nodeWorkload,
    "els3k",
  );
  assert.match(template, /minDomains: 20/);
  assert.match(template, /- loadgen3k/);
  assert.match(template, /memory: 12Gi/);
  assert.match(template, /value: 9GiB/);
});

test("large full-sync size/count trends are not rendered as time values", async () => {
  const runner = await readFile(
    new URL("../k6/server-streaming.js", import.meta.url),
    "utf8",
  );

  for (const metric of [
    "full_sync_payload_bytes",
    "full_sync_feature_flag_count",
    "full_sync_segment_count",
  ]) {
    assert.match(runner, new RegExp(`new Trend\\("${metric}"\\)`));
    assert.doesNotMatch(
      runner,
      new RegExp(`new Trend\\("${metric}",\\s*true\\)`),
    );
  }
});

test("historical multi-environment matrix remains unchanged and runnable", async () => {
  const matrix = JSON.parse(await readFile(historicalMatrixPath, "utf8"));

  assert.equal(matrix.environmentCount, 100);
  assert.equal(matrix.flagCountPerEnvironment, 20);
  assert.equal(matrix.parallelism, 20);
  assert.equal(matrix.connectionsPerRunner, 500);
  assert.equal(matrix.connectionsPerEnvironmentPerRunner, 5);
  assert.equal(matrix.totalConnections, 10_000);
  assert.equal(matrix.revisionPlan, undefined);
});

test("original large-flagset topology remains a separate ten-node profile", async () => {
  const template = await readFile(originalLargeFlagsetTemplatePath, "utf8");

  assert.match(template, /minDomains: 10/);
  assert.match(template, /cpu: "1"\s+memory: 2Gi/);
  assert.match(template, /memory: 6Gi/);
  assert.doesNotMatch(template, /loadgen3k|els3k|GOMEMLIMIT/);
});

test("isolated node-pool provisioning is additive and cluster-scoped", async () => {
  const script = await readFile(nodePoolScriptPath, "utf8");

  assert.match(script, /\$clusterName = "aks-featbit-load-testing"/);
  assert.match(script, /\$resourceGroup = "featbit-devtest"/);
  assert.match(script, /aks nodepool add/);
  assert.doesNotMatch(script, /aks nodepool (?:delete|scale)/);
  assert.doesNotMatch(script, /terraform\s+destroy/);
});
