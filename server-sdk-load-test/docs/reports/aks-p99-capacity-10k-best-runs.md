# AKS 10k capacity matrix: best run per group

This report is the detailed source for the five-group tables in the repository
README. The complete 15-run evidence remains in
[`aks-p99-capacity-10k-summary.json`](aks-p99-capacity-10k-summary.json).

## Selection rule

- Each group contains three completed runs.
- The selected run is the one with the smallest conservative primary metric:
  the worst per-revision, per-runner `probe_sync_latency_ms p99` across all
  10 measured revisions.
- Selection does not use average latency, spike rate, resource consumption, or
  the de-jittered result.
- This is a best-observed view. Use the complete matrix summary for three-run
  medians, ranges, and stability comparisons.

| Group | Configuration | Run 1 p99 | Run 2 p99 | Run 3 p99 | Selected |
| --- | --- | ---: | ---: | ---: | --- |
| g1 | 20 × 500, ELS 6 | 296 ms | **207.01 ms** | 299 ms | Run 2 |
| g2 | 40 × 250, ELS 6 | 262.02 ms | 233 ms | **232 ms** | Run 3 |
| g3 | 20 × 500, ELS 12 | 283 ms | **245 ms** | 286 ms | Run 2 |
| g4 | 40 × 250, ELS 12 | 309 ms | 329 ms | **223 ms** | Run 3 |
| g5 | 20 × 500, ELS 3 | 327 ms | **226.01 ms** | 266.04 ms | Run 2 |

## Complete selected-run results

Every selected run contains 100,000 formal propagation samples: 10,000
WebSockets × 10 measured revisions.

| Group | Run ID | Conservative p99 | Weighted average | Global maximum | Samples >100 ms |
| --- | --- | ---: | ---: | ---: | ---: |
| g1 | `growth-20260724-211542-fdf299e3-2735` | 207.01 ms | 61.255 ms | 208 ms | 7,543 (7.543%) |
| g2 | `growth-20260724-230351-fdf299e3-980a` | 232 ms | 63.17256 ms | 232 ms | 7,652 (7.652%) |
| g3 | `growth-20260724-205529-fdf299e3-a56c` | 245 ms | 60.44492 ms | 247 ms | 5,503 (5.503%) |
| g4 | `growth-20260724-224023-fdf299e3-619d` | 223 ms | 61.63243 ms | 223 ms | 6,624 (6.624%) |
| g5 | `growth-20260724-201133-fdf299e3-18ef` | 226.01 ms | 74.20572 ms | 227 ms | 20,911 (20.911%) |

## De-jittered results

The spike cutoff was fixed at `probe_sync_latency_ms > 100 ms`. Filtering is
applied to the same TestRun evidence and removes no samples at or below
100 ms. It is a diagnostic view of the usual path and does not replace the
complete result or SLO evaluation.

Distributed k6 summaries do not contain the raw samples needed to reconstruct
one exact global percentile. The weighted average, sample counts, minimum, and
maximum are globally exact; p95 and p99 are reported as the range across
runner-level filtered Trends.

| Group | Removed | Affected runners | Affected nodes | Affected runner × revision batches | Retained | Weighted average | Runner p95 range | Runner p99 range | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| g1 | 7,543 | 20 / 20 | 10 / 10 | 79 / 200 | 92,457 | 55.88648 ms | 84–97 ms | 92–100 ms | 100 ms |
| g2 | 7,652 | 40 / 40 | 10 / 10 | 177 / 400 | 92,348 | 58.57923 ms | 89–98 ms | 95–100 ms | 100 ms |
| g3 | 5,503 | 18 / 20 | 10 / 10 | 51 / 200 | 94,497 | 56.08916 ms | 85–97 ms | 93–100 ms | 100 ms |
| g4 | 6,624 | 38 / 40 | 10 / 10 | 116 / 400 | 93,376 | 57.47884 ms | 85–98 ms | 91–100 ms | 100 ms |
| g5 | 20,911 | 20 / 20 | 10 / 10 | 156 / 200 | 79,089 | 62.11645 ms | 94–98 ms | 99–100 ms | 100 ms |

## Selected-run resource peaks

Metrics were sampled every five seconds. Each cell is CPU / memory. Peaks are
calculated independently for each scope and may occur at different samples.
Node-pool values include Kubernetes overhead; ELS and runner values include
only their named containers.

| Group | ELS Pods | ELS aggregate | Runner aggregate | FeatBit nodes | Loadgen nodes |
| --- | ---: | ---: | ---: | ---: | ---: |
| g1 | 6 | 539.61m / 802.68Mi | 2,340.82m / 13.81Gi | 957.43m / 5.91Gi | 2,042.15m / 30.56Gi |
| g2 | 6 | 484.27m / 793.08Mi | 1,703.97m / 14.46Gi | 920.33m / 5.94Gi | 2,470.01m / 32.05Gi |
| g3 | 12 | 616.83m / 1,333.97Mi | 1,408.04m / 13.97Gi | 1,057.37m / 6.47Gi | 2,093.09m / 30.65Gi |
| g4 | 12 | 597.90m / 1,344.36Mi | 1,319.73m / 14.42Gi | 906.53m / 6.50Gi | 2,506.04m / 31.95Gi |
| g5 | 3 | 389.74m / 510.78Mi | 1,760.83m / 11.25Gi | 807.34m / 5.59Gi | 2,055.22m / 27.66Gi |

## Reproduction and provenance

- Matrix definition:
  [`../../k8s-infra/matrices/aks-p99-capacity.json`](../../k8s-infra/matrices/aks-p99-capacity.json)
- Matrix executor:
  [`../../k8s-infra/scripts/run-aks-capacity-matrix.ps1`](../../k8s-infra/scripts/run-aks-capacity-matrix.ps1)
- Full matrix summarizer:
  [`../../k8s-infra/scripts/summarize-aks-capacity-matrix.ps1`](../../k8s-infra/scripts/summarize-aks-capacity-matrix.ps1)
- Complete/de-jitter analyzer:
  [`../../k8s-infra/scripts/analyze-aks-latency.ps1`](../../k8s-infra/scripts/analyze-aks-latency.ps1)
- Operational procedure:
  [`../../k8s-infra/README-AKS.md`](../../k8s-infra/README-AKS.md)
- Machine-readable selected-run evidence:
  [`aks-p99-capacity-10k-best-runs.json`](aks-p99-capacity-10k-best-runs.json)

