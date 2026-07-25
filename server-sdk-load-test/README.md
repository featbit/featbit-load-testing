[← All load-test suites](../README.md)

# FeatBit Server SDK WebSocket Load Testing

This suite uses k6 to validate FeatBit Evaluation Server WebSocket
connections, initial synchronization, feature-flag propagation, heartbeat
handling, and final revision consistency.

Run suite-specific commands from the `server-sdk-load-test/` directory. Paths
in the AKS and Docker Desktop runbooks are relative to that directory.

[Latest 10k result](#latest-validated-aks-result) ·
[Online k6 report](https://featbit.github.io/featbit-load-testing/reports/aks-10k-g2-run3-runner-15.html) ·
[Five-group result data](docs/reports/aks-p99-capacity-10k-best-runs.json) ·
[AKS runbook](k8s-infra/README-AKS.md)

## Latest validated AKS result

> **All 15 matrix runs passed at 10,000 concurrent WebSockets.** The best
> observed single run had a conservative p99 of **207.01 ms**; the best
> three-run median remained **233 ms**.

The benchmark ran on AKS with the official
`docker.io/featbit/featbit-evaluation-server:5.4.4` image.

| Test contract | Value |
| --- | ---: |
| Concurrent WebSockets | 10,000 |
| Connection ramp | 100/s |
| Provisioned feature flags | 20 |
| Changed and measured flags | 1 |
| Unmeasured post-ramp warm-up flags | 1 |
| Measured revisions per run | 10 |
| Configuration groups × repetitions | 5 × 3 |
| Formal latency samples | 1,500,000 |
| p99 threshold failures | 0 |

The primary metric is deliberately conservative: for each run, it selects the
highest per-runner `probe_sync_latency_ms p99` across all 10 revisions. The
tables below intentionally select the run with the **smallest primary p99
within each group**, as a best-observed comparison. This is not a
three-run average or a stability estimate.

### Best run from each of the five groups

| Group | Configuration | Selected run | Conservative p99 | Weighted average | Maximum | Samples >100 ms |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| **g1** | **20 × 500, ELS 6** | `growth-20260724-211542-fdf299e3-2735` | **207.01 ms** | **61.26 ms** | 208 ms | 7.543% |
| g2 | 40 × 250, ELS 6 | `growth-20260724-230351-fdf299e3-980a` | 232 ms | 63.17 ms | 232 ms | 7.652% |
| g3 | 20 × 500, ELS 12 | `growth-20260724-205529-fdf299e3-a56c` | 245 ms | 60.44 ms | 247 ms | 5.503% |
| g4 | 40 × 250, ELS 12 | `growth-20260724-224023-fdf299e3-619d` | 223 ms | 61.63 ms | 223 ms | 6.624% |
| g5 | 20 × 500, ELS 3 | `growth-20260724-201133-fdf299e3-18ef` | 226.01 ms | 74.21 ms | 227 ms | 20.911% |

Every selected run contains 100,000 formal propagation measurements and
10,000 post-ramp warm-up checks. Connection, initial-sync, warm-up coverage,
revision coverage, final revision, and connection-survival checks all passed.

### De-jittered view of the same selected runs

A spike was defined before analysis as
`probe_sync_latency_ms > 100 ms`. The diagnostic view removes only those
samples; values equal to 100 ms remain. Exact global percentiles cannot be
reconstructed from distributed k6 summaries, so p95 and p99 are shown as the
minimum–maximum range across filtered runner summaries.

| Group | Removed spikes | Affected runner × revision batches | Retained samples | De-jittered weighted average | Runner p95 range | Runner p99 range |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **g1** | **7,543 (7.543%)** | **79 / 200** | **92,457** | **55.89 ms** | **84–97 ms** | **92–100 ms** |
| g2 | 7,652 (7.652%) | 177 / 400 | 92,348 | 58.58 ms | 89–98 ms | 95–100 ms |
| g3 | 5,503 (5.503%) | 51 / 200 | 94,497 | 56.09 ms | 85–97 ms | 93–100 ms |
| g4 | 6,624 (6.624%) | 116 / 400 | 93,376 | 57.48 ms | 85–98 ms | 91–100 ms |
| g5 | 20,911 (20.911%) | 156 / 200 | 79,089 | 62.12 ms | 94–98 ms | 99–100 ms |

The de-jittered table isolates the usual path; it does not replace the complete
result, hide threshold failures, or establish the SLO.

## Resource consumption

All groups used 10 × `Standard_D4ds_v5` loadgen nodes and 3 ×
`Standard_D4ds_v5` FeatBit nodes. Each ELS Pod requested/limited
500m/1 CPU and 256Mi/512Mi memory; autoscaling was disabled and k6 used the
cluster-internal Service.

The table reports independently sampled, five-second aggregate peaks from the
same selected runs above. Node-pool values include Kubernetes overhead; ELS
and runner values include only the named containers.

| Group | ELS aggregate peak | Runner aggregate peak | FeatBit-node aggregate peak | Loadgen-node aggregate peak |
| --- | ---: | ---: | ---: | ---: |
| **g1** | **540m / 803Mi** | **2.34 CPU / 13.81Gi** | **0.96 CPU / 5.91Gi** | **2.04 CPU / 30.56Gi** |
| g2 | 484m / 793Mi | 1.70 CPU / 14.46Gi | 0.92 CPU / 5.94Gi | 2.47 CPU / 32.05Gi |
| g3 | 617m / 1,334Mi | 1.41 CPU / 13.97Gi | 1.06 CPU / 6.47Gi | 2.09 CPU / 30.65Gi |
| g4 | 598m / 1,344Mi | 1.32 CPU / 14.42Gi | 0.91 CPU / 6.50Gi | 2.51 CPU / 31.95Gi |
| g5 | 390m / 511Mi | 1.76 CPU / 11.25Gi | 0.81 CPU / 5.59Gi | 2.06 CPU / 27.66Gi |

## What the matrix showed

- The lowest best-observed p99 was g1 at 207.01 ms. Its de-jittered weighted
  average was also the lowest at 55.89 ms.
- g2 still produced the best three-run median and narrowest p99 range:
  233 ms across 232–262.02 ms. That stability result is separate from the
  best-single-run table above.
- Increasing ELS from 6 to 12 Pods did not improve the selected p99
  consistently and increased ELS memory from roughly 0.8Gi to 1.3Gi.
- Although g5's selected p99 was 226.01 ms, it had the highest weighted
  average and spike rate: 74.21 ms and 20.911%. A minimum p99 alone therefore
  does not make three ELS Pods the preferred topology.
- Six ELS Pods are therefore the recommended 10k reference topology. Twelve
  Pods add fixed CPU and memory overhead without a demonstrated latency gain.

The selected-run and de-jitter evidence is available in the
[five-group report](docs/reports/aks-p99-capacity-10k-best-runs.md) and
[machine-readable JSON](docs/reports/aks-p99-capacity-10k-best-runs.json).
The [complete matrix report](docs/reports/aks-p99-capacity-10k-summary.md) and
[full JSON](docs/reports/aks-p99-capacity-10k-summary.json) retain all 15 runs,
including three-run medians and ranges.

## Capacity boundary

This experiment establishes a verified lower bound, not the maximum:

- 3 ELS Pods supported 10,000 WebSockets under the tested 20-runner topology.
- 6 ELS Pods supported 10,000 WebSockets under both the 20- and 40-runner
  topologies.
- The worst conservative p99 observed anywhere in the five-group matrix was
  329 ms.
- Connection counts above 10,000 require a separate, controlled capacity
  ladder before claiming a higher limit.

## Published k6 report

[Open the latest rendered k6 HTML report](https://featbit.github.io/featbit-load-testing/reports/aks-10k-g2-run3-runner-15.html).

The Pages workflow publishes this URL from `main`. Until the repository's
first successful Pages deployment, use the versioned HTML linked below.

Distributed k6 creates one report per runner rather than one merged HTML
report. The published artifact is the worst-p99 runner from the final
repetition of g2, the configuration with the best three-run median:

- Run: `growth-20260724-230351-fdf299e3-980a`
- Runner: 15 of 40
- Connections: 250
- Formal samples: 2,500
- Runner p99/max: 230/232 ms

Use the matrix JSON—not this single-runner HTML—as the source of truth for the
10,000-connection aggregate conclusion. The exact
[versioned HTML](docs/reports/aks-10k-g2-run3-runner-15.html),
[runner summary](docs/reports/aks-10k-g2-run3-runner-15-summary.json), and
[artifact provenance](docs/reports/README.md) are retained in the repository.

## Test profiles

`Ramp rate` means new WebSocket connections per second.

| Profile | Run location | Ramp rate | Total connections | Provisioned flags | Changed/measured flags |
| --- | --- | ---: | ---: | ---: | ---: |
| Smoke | Local, then remote load generator | 1/s | 10 | 1 | 1 |
| Baseline | Remote load generator | 10/s | 1,000 | 10 | 1 |
| Baseline Plus | Remote load generator | 30/s | 3,000 | 10 | 1 |
| Growth | AKS only | 100/s | 10,000 | 20 | 1 |
| Growth Plus | AKS only | 200/s | 20,000 | 20 | 1 |

## Reproduce the test

Detailed commands and operational gates intentionally live outside this
README:

| File | Purpose |
| --- | --- |
| [`k8s-infra/README-AKS.md`](k8s-infra/README-AKS.md) | End-to-end AKS deployment, credentials, isolation, execution, monitoring, collection, and the 10k capacity-matrix procedure |
| [`k8s-infra/matrices/aks-p99-capacity.json`](k8s-infra/matrices/aks-p99-capacity.json) | Exact five-group experiment definition and execution order |
| [`k8s-infra/scripts/run-aks-capacity-matrix.ps1`](k8s-infra/scripts/run-aks-capacity-matrix.ps1) | Resumable matrix executor with topology and evidence gates |
| [`k8s-infra/scripts/summarize-aks-capacity-matrix.ps1`](k8s-infra/scripts/summarize-aks-capacity-matrix.ps1) | Final latency, comparison, and resource summarizer |
| [`k8s-infra/scripts/analyze-aks-latency.ps1`](k8s-infra/scripts/analyze-aks-latency.ps1) | Recreates the complete and `>100 ms` de-jittered views for one collected run |
| [`docs/reports/aks-p99-capacity-10k-best-runs.json`](docs/reports/aks-p99-capacity-10k-best-runs.json) | Machine-readable selected-run values used by the README tables |
| [`k8s-infra/terraform/aks/README.md`](k8s-infra/terraform/aks/README.md) | Ephemeral AKS, ACR, and node-pool provisioning |
| [`k8s-infra/README.md`](k8s-infra/README.md) | Docker Desktop rehearsal and local result collection |
| [`.github/workflows/publish-server-sdk-k6-report.yml`](../.github/workflows/publish-server-sdk-k6-report.yml) | Publishes the retained Server SDK HTML artifact to GitHub Pages |

## What this test covers

Each k6 virtual user opens an independent WebSocket and follows the FeatBit
.NET Server SDK streaming and version-application behavior. The test validates
connection establishment, full synchronization, patch updates, application
heartbeats, revision order, final values, and connection survival. It does not
start real .NET processes.
