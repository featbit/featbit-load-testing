# FeatBit Evaluation Server WebSocket Load Test

Use k6 to open independent FeatBit Server SDK-compatible WebSocket connections and verify that every connection receives every configured feature flag update.

Use k6 2.1.0 on both the local workstation and the remote load generator.

Deployment runbooks:

- Docker Desktop rehearsal and local result collection: [`k8s-infra/README.md`](k8s-infra/README.md)
- AKS migration, isolation, sizing, observability, and execution gates:
  [`k8s-infra/README-AKS.md`](k8s-infra/README-AKS.md)
- Ephemeral AKS/ACR/node-pool Terraform stack:
  [`k8s-infra/terraform/aks/`](k8s-infra/terraform/aks/README.md)

## Test profiles

`Ramp rate` means new WebSocket connections per second.

| Profile | Run location | Ramp rate | Total connections | Provisioned flags | Changed/measured flags | Hold time |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Smoke | Local workstation, then remote load generator | 1/s | 10 | 1 | 1 | 3 minutes |
| Baseline | Remote load generator | 10/s | 1,000 | 10 | 1 | 70 seconds |
| Baseline Plus | Remote load generator | 30/s | 3,000 | 10 | 1 | 70 seconds |
| Growth | AKS only | 100/s | 10,000 | 20 | 1 | 10 minutes |
| Growth Plus | AKS only | 200/s | 20,000 | 20 | 1 | 10 minutes |

Baseline, Baseline Plus, Growth, and Growth Plus each take 100 seconds to reach their target
connection count. Growth requires at least five AKS runners; Growth Plus requires at least ten.
Both change and measure only `loadtest-sync-probe-01`; flag `02` is reserved for the unmeasured
post-ramp warm-up.

## 1. Create the probe flags

Create these String feature flags in the FeatBit Cloud environment under test:

| Profile | Required keys |
| --- | --- |
| Smoke | `loadtest-sync-probe-01` |
| Baseline | `loadtest-sync-probe-01` through `loadtest-sync-probe-10` |
| Baseline Plus | `loadtest-sync-probe-01` through `loadtest-sync-probe-10` |
| Growth | `loadtest-sync-probe-01` through `loadtest-sync-probe-20` |
| Growth Plus | `loadtest-sync-probe-01` through `loadtest-sync-probe-20` |

Configure every probe flag as follows:

| Setting | Value |
| --- | --- |
| Type | String |
| Status | Enabled |
| Variation values | `baseline`, `rev-001`, `rev-002` |
| Target Users / Targeting Rules | None |
| Default Rule before each run | Serve `baseline` to 100% |

Use the values above as variation **values**, not variation names.

## 2. Configure FeatBit Cloud

Run this in the PowerShell session that will start k6. Replace `<server-sdk-secret>` with the environment's **Server SDK secret**. Do not use an API token or Client SDK secret.

```powershell
$env:FEATBIT_STREAMING_URL = "wss://app-eval.featbit.co"
$env:FEATBIT_SERVER_SECRET = "<server-sdk-secret>"
$env:PROBE_INITIAL_VALUE = "baseline"
$env:EXPECTED_REVISIONS = "rev-001,rev-002"
$env:STRICT_PATCH_DELIVERY = "false"
```

These variables exist only in the current PowerShell session and its child processes. Never commit the secret.

`STRICT_PATCH_DELIVERY=false` matches the FeatBit .NET Server SDK: duplicate and stale
patch versions are silently ignored and their quality counters are omitted from the
summary. Set it to `true` only when the test contract explicitly requires exactly-once
patch delivery; that mode records them and fails the corresponding thresholds.

## 3. Select and run a profile

### Smoke: local and remote

Run this profile once from the local workstation and once from the remote load generator.

```powershell
$env:PROBE_FLAG_KEYS = "loadtest-sync-probe-01"
$env:MAX_CONNECTIONS = "10"
$env:CONNECTIONS_PER_SECOND = "1"
$env:STABILIZATION_SECONDS = "10"
$env:INITIAL_SYNC_TIMEOUT_SECONDS = "10"
$env:HOLD_DURATION_SECONDS = "180"
$env:DRAIN_DURATION_SECONDS = "10"

New-Item -ItemType Directory -Force .\results | Out-Null
k6 run --summary-export .\results\smoke-summary.json .\k6\server-streaming.js
```

Measured hold: `T+20s` through `T+200s`.

### Baseline

Keep all 10 Baseline flags in the environment. Only `loadtest-sync-probe-01` is included in
`PROBE_FLAG_KEYS`, so the measured controller changes that one flag while flags `02` through `10`
remain at `baseline`.

```powershell
$env:PROBE_FLAG_KEYS = "loadtest-sync-probe-01"
$env:MAX_CONNECTIONS = "1000"
$env:CONNECTIONS_PER_SECOND = "10"
$env:STABILIZATION_SECONDS = "30"
$env:INITIAL_SYNC_TIMEOUT_SECONDS = "20"
$env:HOLD_DURATION_SECONDS = "70"
$env:DRAIN_DURATION_SECONDS = "10"

New-Item -ItemType Directory -Force .\results | Out-Null
k6 run --summary-export .\results\baseline-summary.json .\k6\server-streaming.js
```

Measured hold: `T+130s` through `T+200s`.

### Baseline Plus

Baseline Plus keeps the same 10 provisioned flags and only changes/measures
`loadtest-sync-probe-01`. It increases the connection target to 3,000 and the global ramp rate to
30/s.

```powershell
$env:PROBE_FLAG_KEYS = "loadtest-sync-probe-01"
$env:MAX_CONNECTIONS = "3000"
$env:CONNECTIONS_PER_SECOND = "30"
$env:STABILIZATION_SECONDS = "30"
$env:INITIAL_SYNC_TIMEOUT_SECONDS = "20"
$env:HOLD_DURATION_SECONDS = "70"
$env:DRAIN_DURATION_SECONDS = "10"

New-Item -ItemType Directory -Force .\results | Out-Null
k6 run --summary-export .\results\baseline-plus-summary.json .\k6\server-streaming.js
```

Measured hold: `T+130s` through `T+200s`.

### Growth and Growth Plus

These profiles are AKS-only. Do not run 10,000 or 20,000 connections in one local k6 Pod.
Render them through the guarded AKS workflow:

```powershell
.\k8s-infra\scripts\render-aks-testrun.ps1 `
  -Profile growth `
  -KubeContext $aksContext `
  -RunnerImage $runnerImage `
  -Parallelism 5

.\k8s-infra\scripts\render-aks-testrun.ps1 `
  -Profile growth-plus `
  -KubeContext $aksContext `
  -RunnerImage $runnerImage `
  -Parallelism 10
```

The second command requires at least ten isolated loadgen nodes. See
[`README-AKS.md`](k8s-infra/README-AKS.md) for resource monitoring and result collection.

## 4. Control the flags during the measured hold

Docker Desktop Kubernetes runs use the REST controller documented in
[`k8s-infra/README.md`](k8s-infra/README.md). With `AUTO_CONTROL_REVISIONS=true`, the
single local runner—or runner 1 in the distributed AKS profile—restores every flag listed in
`PROBE_FLAG_KEYS` to `baseline` in `setup()`, applies
an unmeasured `baseline -> rev-001 -> baseline` warm-up before any WebSocket is
opened, and then applies `rev-001` and `rev-002` during the measured hold. When
`POST_RAMP_WARMUP_FLAG_KEY` names a separate unmeasured flag, it also performs a second
`baseline -> rev-001 -> baseline` warm-up after all WebSockets are established and before
the measured revisions. It restores all controlled flags to `baseline` in `teardown()`.
No manual flag changes are required.

For a direct k6 run without the REST controller, use the following manual process.

Before starting, confirm that every probe flag serves `baseline` to 100%.

Wait until k6 prints the `measured hold` line, then perform these two rounds in FeatBit Cloud:

1. Change every flag listed in `PROBE_FLAG_KEYS` from `baseline` to `rev-001`, saving each flag.
2. Wait at least 30 seconds after the last save.
3. Change the same flags from `rev-001` to `rev-002`, saving each flag.
4. Leave the flags unchanged and let k6 finish naturally.

Each WebSocket must receive this sequence for every configured flag:

```text
baseline -> rev-001 -> rev-002
```

A missing revision, an out-of-order update, or a final value other than `rev-002` fails the test.

## 5. Stop a run

- Stop changing flags at any time by making no further saves; the WebSockets remain connected.
- Stop k6 at any time with `Ctrl+C` in its PowerShell window.
- k6 2.1.0 cannot pause and resume the same run. Do not suspend the process because its heartbeat timers will also stop and invalidate the result.

With the REST controller enabled, a natural completion restores `baseline` in
`teardown()`. Force-killing the runner can skip teardown; the next run still restores
`baseline` in `setup()`, but do not assume an interrupted run cleaned up immediately.

An interrupted run is incomplete; do not treat its threshold failures as a load-test result.

## 6. Check the result

After a natural completion, confirm:

- `connection_open_success`, `initial_sync_success`, `ready_before_hold`, `connection_survived`, `initial_probe_value_success`, every `probe_revision_coverage`, and `final_applied_revision_success` are 100%.
- `unexpected_close`, `websocket_error`, `heartbeat_timeout`, `revision_sequence_error`, and `unexpected_revision` are 0.
- With `STRICT_PATCH_DELIVERY=false`, delivery-quality counters are intentionally absent. With `true`, `duplicate_patch`, `stale_patch`, and `repeated_revision` must all be 0.
- Timing metrics have a non-zero `count`; a displayed latency of `0` with `count=0` means no valid sample was recorded.
- The selected summary file exists under `results/`.

### Patch delivery semantics

The script applies patches with the same version rule as the FeatBit .NET Server SDK:

- A patch with a newer `updatedAt` version is applied.
- The same revision and version is ignored; strict mode counts it as `duplicate_patch`.
- An older version is ignored; strict mode counts it as `stale_patch`.
- A newer configuration that still serves the same probe value is applied; strict mode counts it as `repeated_revision`.

`final_applied_revision_success` answers whether every simulated SDK connection ends with
the final value from `EXPECTED_REVISIONS`. Revision coverage and stream-delivery quality
are reported separately so duplicate delivery cannot masquerade as a missing final value.
It replaces the old `latest_revision_received` metric, which combined final-state and
delivery-quality failures into one misleading percentage.

## What this tests

Each k6 VU opens one independent WebSocket and follows the FeatBit .NET Server SDK streaming protocol and version-application behavior for connection, full synchronization, patch updates, and application heartbeat. The script validates every key in `PROBE_FLAG_KEYS` on every connection. When `AUTO_CONTROL_REVISIONS=true`, a separate k6 scenario calls the FeatBit REST API to control the probe flags; otherwise the flags remain manual. The test does not start real .NET processes.
