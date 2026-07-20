# FeatBit Evaluation Server WebSocket Load Test

Use k6 to open independent FeatBit Server SDK-compatible WebSocket connections and verify that every connection receives every configured feature flag update.

Use k6 2.1.0 on both the local workstation and the remote load generator.

## Test profiles

`Ramp rate` means new WebSocket connections per second.

| Profile | Run location | Ramp rate | Total connections | Probe flags | Hold time |
| --- | --- | ---: | ---: | ---: | ---: |
| Smoke | Local workstation, then remote load generator | 1/s | 10 | 1 | 3 minutes |
| Baseline | Remote load generator | 10/s | 1,000 | 10 | 10 minutes |
| Growth | Remote load generator | 50/s | 5,000 | 20 | 10 minutes |

Both Baseline and Growth take 100 seconds to reach their target connection count.

## 1. Create the probe flags

Create these String feature flags in the FeatBit Cloud environment under test:

| Profile | Required keys |
| --- | --- |
| Smoke | `loadtest-sync-probe-01` |
| Baseline | `loadtest-sync-probe-01` through `loadtest-sync-probe-10` |
| Growth | `loadtest-sync-probe-01` through `loadtest-sync-probe-20` |

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

```powershell
$env:PROBE_FLAG_KEYS = ((1..10) | ForEach-Object { "loadtest-sync-probe-{0:D2}" -f $_ }) -join ","
$env:MAX_CONNECTIONS = "1000"
$env:CONNECTIONS_PER_SECOND = "10"
$env:STABILIZATION_SECONDS = "30"
$env:INITIAL_SYNC_TIMEOUT_SECONDS = "20"
$env:HOLD_DURATION_SECONDS = "600"
$env:DRAIN_DURATION_SECONDS = "10"

New-Item -ItemType Directory -Force .\results | Out-Null
k6 run --summary-export .\results\baseline-summary.json .\k6\server-streaming.js
```

Measured hold: `T+130s` through `T+730s`.

### Growth

```powershell
$env:PROBE_FLAG_KEYS = ((1..20) | ForEach-Object { "loadtest-sync-probe-{0:D2}" -f $_ }) -join ","
$env:MAX_CONNECTIONS = "5000"
$env:CONNECTIONS_PER_SECOND = "50"
$env:STABILIZATION_SECONDS = "30"
$env:INITIAL_SYNC_TIMEOUT_SECONDS = "20"
$env:HOLD_DURATION_SECONDS = "600"
$env:DRAIN_DURATION_SECONDS = "10"

New-Item -ItemType Directory -Force .\results | Out-Null
k6 run --summary-export .\results\growth-summary.json .\k6\server-streaming.js
```

Measured hold: `T+130s` through `T+730s`.

## 4. Change the flags during the measured hold

Before starting, confirm that every probe flag serves `baseline` to 100%.

Wait until k6 prints the `measured hold` line, then perform these two rounds in FeatBit Cloud:

1. Change every probe flag in the selected profile from `baseline` to `rev-001`, saving each flag.
2. Wait at least 30 seconds after the last save.
3. Change every probe flag from `rev-001` to `rev-002`, saving each flag.
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

Each k6 VU opens one independent WebSocket and follows the FeatBit .NET Server SDK streaming protocol and version-application behavior for connection, full synchronization, patch updates, and application heartbeat. The script validates every key in `PROBE_FLAG_KEYS` on every connection. It does not call the FeatBit API or start real .NET processes.
