# AKS 10k / single Environment / 3,000 flags capacity validation

Status: **blocked after failed capacity validation; no propagation baseline was produced**.

## Workload

- One Project and one Environment.
- 3,000 flags: 2,500 string and 500 JSON configuration flags.
- Each JSON variation is exactly 2,048 bytes.
- 20 k6 runners × 500 Server SDK WebSockets.
- Configured connection schedule: 100 connections/s for 100 seconds.
- Planned formal workload: eight string flag revisions and two JSON flag revisions, 30 seconds apart.

No FeatBit source code, ELS source code, or FeatBit image was changed.

## Failed validation

Run `growth-f3k-v-20260727161112-18e5` used three ELS Pods at 1 CPU request /
3 CPU limit and 2 GiB request / 8 GiB limit. It is retained as a failed run:

| Evidence | Observation |
| --- | ---: |
| Runner Jobs | 20/20 failed |
| Confirmed runner `OOMKilled` | 5 |
| Additional runner exit 137 | 3 |
| Exact 3,000-flag sync records | 167/10,000 |
| Payload per exact sync | 5,048,186–5,635,811 bytes |
| Partial start-schedule drift max | 1,148 ms |
| Partial WebSocket-open drift max | 8,542 ms |
| Partial full-sync drift p50 / p95 / p99 / max | 355,247 / 399,145 / 406,376 / 406,509 ms |
| Partial JSON parse p50 / p99 / max | 349,903 / 399,325 / 399,403 ms |
| Loadgen node peak | about 4 CPU; 13.84 GB memory |
| Runner peak | 5.97 GiB against the 6 GiB limit |
| ELS Pod peak range | 2.40–2.81 CPU; 6.40–6.42 GiB |
| ELS health | liveness/readiness timeouts; at least two liveness restarts |
| Formal revisions | 0 |
| Baseline restoration | 10/10 flags |

These partial percentiles describe only the 167 completed sync callbacks. They
must not be reported as a 10,000-connection result. The run proves that the
current two-runners-per-D4 receive/parse path and colocated ELS topology are
not a valid measurement platform for this 50+ GiB full-sync wave.

## Resource-safe rerun

The checked-in isolated matrix leaves all historical pools untouched and adds:

- 10 × D4 `loadgen3k` nodes, combined with the historical 10 × D4 loadgen
  nodes to place exactly one runner on each of 20 nodes;
- 3 × D4 `els3k` nodes, dedicated to the three ELS Pods;
- runner 2 CPU / 4 GiB requests, no CPU limit, 12 GiB memory limit, and
  `GOMEMLIMIT=9GiB`;
- ELS 2 CPU / 8 GiB requests and 4 CPU / 12 GiB limits;
- a 900-second initial-sync stabilization window while preserving the
  100 connections/s, 100-second connection schedule.

East Asia currently reports 54/65 total regional vCPUs and 54/65 Standard
DDSv5-family vCPUs in use. The isolated profile requires 52 additional vCPUs,
or 106 total. Both limits must be raised; 120 vCPUs is the recommended target.
No existing node pool was scaled down, replaced, or deleted.

Exact definitions:

- [`aks-single-environment-3k-flags-g5-d4-els3.json`](../../k8s-infra/matrices/aks-single-environment-3k-flags-g5-d4-els3.json)
- [`aks-single-environment-3k-flags-g5-d4-els3-expanded.json`](../../k8s-infra/matrices/aks-single-environment-3k-flags-g5-d4-els3-expanded.json)
- [`aks-single-environment-3k-flags-g5-d4-isolated.json`](../../k8s-infra/matrices/aks-single-environment-3k-flags-g5-d4-isolated.json)
- [`testrun-aks-large-flagset.yaml`](../../k8s-infra/templates/testrun-aks-large-flagset.yaml)
- [`testrun-aks-large-flagset-isolated.yaml`](../../k8s-infra/templates/testrun-aks-large-flagset-isolated.yaml)

