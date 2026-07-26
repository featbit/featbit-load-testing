[← All load-test suites](../README.md)

# FeatBit Server SDK WebSocket Load Testing

This suite uses k6 to validate FeatBit Evaluation Server WebSocket
connections, initial synchronization, feature-flag propagation, heartbeat
handling, and final revision consistency.

Run suite-specific commands from the `server-sdk-load-test/` directory. Paths
in the AKS and Docker Desktop runbooks are relative to that directory.

[Best verified result](#best-verified-10000-connection-result) ·
[Tail attribution](#why-the-tail-is-not-attributed-to-featbit-els-capacity) ·
[Historical records](#historical-experiment-record) ·
[Five-group reference](#1-five-group-reference-matrix) ·
[Latest retained k6 report](docs/reports/aks-10k-els-loadgen-sentinel-run3-runner-1.html) ·
[Currently deployed report](https://featbit.github.io/featbit-load-testing/reports/aks-10k-g2-run3-runner-15.html) ·
[AKS runbook](k8s-infra/README-AKS.md)

## Best verified 10,000-connection result

The current reference is
`growth-20260726-052542-ce333a5f-ad79`, the best-observed repetition by the
canonical worst runner × revision `probe_sync_latency_ms p99` in the final
three-run sentinel campaign. It is a measured result, not a guaranteed SLO or
a claimed maximum capacity.

All 20 runners passed. The run retained 100,000 formal propagation samples,
10,000 full-connection warm-up checks, all 10 revisions, 180/180 direct
sentinel connections, and 1,800/1,800 formal sentinel events.

### Test contract and resource allocation

| Area | Allocation |
| --- | --- |
| Main load | 10,000 WebSockets; 100 new connections/s; 20 runners × 500; two runners per loadgen node |
| Flags | 20 provisioned; flag-02 full-connection pre-warm; flag-01 changed 10 times |
| AKS node pools | 1 × `Standard_D2ds_v5` system; 6 × `Standard_D2ds_v5` FeatBit; 10 × `Standard_D4ds_v5` loadgen; 54 vCPU total |
| ELS | 6 Pods, strictly one per FeatBit node; each 250m CPU request / 1 CPU limit and 256Mi request / 512Mi limit |
| k6 runners | 20 Pods; each 500m CPU request with no CPU limit and 1Gi request / 3Gi memory limit |
| Direct sentinels | 10 Pods, one per loadgen node; 180 diagnostic WebSockets; each 20m / 250m CPU and 64Mi / 256Mi memory request / limit |
| UI / API | One Pod each; UI 100m / 500m CPU and 128Mi / 512Mi memory; API 100m / 500m CPU and 256Mi / 1Gi memory |
| PostgreSQL | 1 CPU request with no CPU limit; 2Gi / 4Gi memory; 32Gi managed disk |
| Redis | 1 CPU request with no CPU limit; 1Gi / 2Gi memory; 8Gi managed disk |

The main runners used the cluster-internal
`ws://featbit-els.featbit.svc.cluster.local:5100` endpoint. The 180 sentinels
were diagnostic connections from every loadgen node directly to every ELS
Pod IP; they were not part of the 10,000-connection capacity count.

### Canonical latency

The current latency contract is:

`end_to_end_latency_ms = control_plane_write_latency_ms + probe_sync_latency_ms`

`probe_sync_latency_ms` is the canonical
`streaming_delivery_latency_ms`: earliest Redis publication observation to
the SDK applying the revision.

| Metric | Samples | Average | p95 | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: |
| `end_to_end_latency_ms` | 100,000 | **69.885 ms** | 72–180 ms | 74.01–184 ms | 188 ms |
| `control_plane_write_latency_ms` | 10 | **15.800 ms** | 19.65 ms | 20.73 ms | 21 ms |
| `probe_sync_latency_ms` | 100,000 | **54.085 ms** | 56–165 ms | **58.01–168 ms** | 170 ms |
| Legacy `FeatureFlag.UpdatedAt → SDK` | 100,000 | 64.785 ms | 68–175.05 ms | 70.01–180 ms | 184 ms |

For the 100,000-sample metrics, p95 and p99 are the minimum–maximum range
across 20 runner × 10 revision cohorts; the right edge is the conservative
worst cohort. Counts, weighted averages, and maximums are exact. The control
plane percentiles are calculated directly from the 10 controller writes.

The other two repetitions are shown to keep the selected best run in context:

| Run | Probe sync average | Worst p95 / p99 | End-to-end average / worst p99 | Control average / p99 | Failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 54.675 ms | 183 / 187 ms | 70.775 / 201 ms | 16.10 / 19.82 ms | 0 |
| 2 | 55.503 ms | 210 / 218 ms | 71.803 / 232 ms | 16.30 / 23.82 ms | 0 |
| **3, selected** | **54.085 ms** | **165 / 168 ms** | **69.885 / 184 ms** | **15.80 / 20.73 ms** | **0** |

Across the three repetitions, the canonical average median was 54.675 ms
(54.085–55.503 ms), and the conservative p99 median was 187 ms
(168–218 ms).

The selected run's direct sentinels are reported separately because they are
diagnostic connections, not the 10,000-connection workload:

| Sentinel boundary | Samples | Average | p95 | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: |
| Earliest Redis observer → direct sentinel | 1,800 | 53.592 ms | 96 ms | 119.01 ms | 151 ms |
| Same receiver-node observer → direct sentinel | 1,800 | 50.192 ms | 92 ms | 110.01 ms | 148 ms |

The same-node sensitivity view removes the receiver's 0–10 ms cross-node
clock/observer offset; it does not replace the pre-registered primary result.

### Resource consumption for the selected run

These measurements belong only to the selected run and include the sentinel
diagnostics. Kubernetes consumption was sampled every five seconds; host and
cgroup evidence was sampled at approximately one second.

| Workload or pool | Allocation context | Observed peak |
| --- | --- | ---: |
| Six ELS containers | 1.5 CPU requested / 6 CPU limited; 1.5Gi requested / 3Gi limited | 373.4m CPU / 920Mi |
| Twenty main runners | 10 CPU requested; 20Gi requested / 60Gi limited memory | 1.204 CPU / 17.90Gi |
| Ten sentinel containers | 200m CPU request / 2.5 CPU limit; 640Mi request / 2.5Gi limit | 200.8m CPU / 0.52Gi |
| Six FeatBit nodes | 6 × D2 | 2.238 CPU / 11.58Gi |
| Ten loadgen nodes | 10 × D4 | 3.745 CPU / 35.76Gi |
| UI | 100m / 500m CPU; 128Mi / 512Mi memory | 0.57m CPU / 3.20Mi |
| API | 100m / 500m CPU; 256Mi / 1Gi memory | 8.33m CPU / 214.37Mi |
| PostgreSQL | 1 CPU requested; 2Gi / 4Gi memory | 7.60m CPU / 41.13Mi |
| Redis | 1 CPU requested; 1Gi / 2Gi memory | 33.01m CPU / 8.26Mi |

| One-second evidence | Observed |
| --- | ---: |
| Loadgen host CPU p99 | 22.94% |
| Loadgen CPU-pressure p99 | 14.86% |
| Loadgen run-queue p99 | 6 |
| ELS per-Pod CPU p99 / maximum | 152.0m / 466.5m |
| ELS full-run throttled-period rate / time | 0.0208% / 109.90 ms |
| Formal revision-window ELS throttling | 0 |
| Formal revision-window retransmissions / packet drops | 0 / 0 |

Requests and limits are scheduler and cgroup settings, not measured
consumption. Node-pool peaks include Kubernetes and diagnostic overhead;
container peaks include only the named containers.

### Pre-registered de-jittered diagnostic

The k6 script pre-registered a tail sample as the legacy raw
`FeatureFlag.UpdatedAt → SDK >100 ms`. The same run therefore has an exact
full and filtered comparison:

| View | Samples | Weighted average | Runner p95 range | Runner p99 range | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: |
| Complete raw distribution | 100,000 | 64.79 ms | 95–140 ms | 103–171 ms | 184 ms |
| Remove raw samples `>100 ms` | 90,776 | **59.63 ms** | **91–97 ms** | **96–100 ms** | 100 ms |

The diagnostic removed 9,224 / 100,000 samples (9.224%). It describes the
usual path after excluding the pre-defined tail; it does not replace the full
result, hide failures, or define a new SLO.

This filtered view retains the historical raw boundary because distributed
k6 summaries did not emit the variable per-revision threshold needed to
reconstruct an exact canonical filtered percentile. The Three-stage analysis
moved the start boundary from `FeatureFlag.UpdatedAt` to the earliest Redis
publication observer. In this selected run that boundary change reduced the
unfiltered average by 10.700 ms, from 64.785 to 54.085 ms; it did not remove
the downstream tail shape.

### Why the tail is not attributed to FeatBit ELS capacity

The evidence does not support ELS resource capacity, one slow ELS Pod, or a
cluster-wide ELS broadcast wave as the source of the observed p99 tail:

| Hypothesis | Observation | Evidence-based status |
| --- | --- | --- |
| API / PostgreSQL write path | Control-plane average 15.8–16.3 ms; p99 19.82–23.82 ms | Not the observed long-tail source |
| ELS CPU or memory exhaustion | ELS CPU p99 146–154m; selected-run aggregate memory peak 920Mi against 3Gi of limits; no formal-window throttling | Not supported |
| One slow ELS Pod or node | Zero ELS-column waves across 30 measured revisions | Not supported |
| Shared Redis-to-ELS or cluster-wide delivery delay | Zero global waves across 30 revisions | Not supported |
| Packet loss | No formal-window packet drops; the decisive event had no retransmission | Not supported |
| Loadgen receiver path | One loadgen-row event survived the same-node observer boundary across all six ELS targets | Demonstrated contributor |

The decisive run-3 revision-8 event slowed all six directly connected ELS
targets, both independent main runners on the same loadgen node, and the
independent sentinel process. That loadgen node was only at 16.51% CPU,
11.98% CPU pressure, run queue 2, with zero retransmission and zero packet
drop. Because six different ELS Pods slowed only for one receiver node, the
event is consistent with receiver VM scheduling, kernel network wake-up, or a
process receive-loop pause rather than ELS saturation.

This is a localization result, not proof that every tail sample has the same
cause. The exact split among Azure VM scheduling, the loadgen kernel, k6
receive loops, and small connection cohorts remains **INCONCLUSIVE**. No
FeatBit source function was identified or changed.

### D2 loadgen reduction as corroborating evidence

The quota-constrained campaign moved loadgen from D4 to D2 while moving the
six FeatBit nodes from D2 to D4. Performance became much worse even though ELS
received the larger nodes:

| Topology | Weighted average | Conservative p99 median (range) | Samples >100 ms | Loadgen CPU-pressure p99 | Failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| 10 × D2 loadgen; 6 × D4 FeatBit | 109.38–113.29 ms | **479 ms (409.01–567.03)** | 52.503–55.411% | 27.67–28.33% | 1 |
| 10 × D4 loadgen; 6 × D2 FeatBit | 66.62–77.09 ms | **283.01 ms (252–299.01)** | 10.608–20.099% | 10.57–11.76% | 0 |

Both rows use the historical `FeatureFlag.UpdatedAt → SDK` boundary.
In the failed D2 run, both runners on one loadgen node slowed together while
that node reached about 71% CPU and 51% CPU pressure; the same formal window
had no ELS throttling, retransmission, or packet drop. This is strong
corroboration that generator/receiver resources can inflate the measured
tail. Because quota redistribution changed both node pools, it is not
presented as a strict single-variable A/B test.

### How historical metrics relate to the current result

The Five-group matrix remains the broadest topology comparison, but it used
the historical `FeatureFlag.UpdatedAt → SDK` boundary. Its best selected
conservative p99 was 207.01 ms for 20 × 500 runners and six ELS Pods. It
showed that reducing ELS to three Pods increased average latency and the tail
rate, while increasing from six to twelve Pods did not consistently improve
p99.

The Three-stage contract later separated the stable control-plane component
from downstream streaming delivery. Therefore, the current canonical 168 ms
best-observed p99 must not be described as a direct 39 ms topology
improvement over the historical 207.01 ms result: part of the difference is
the latency boundary, and part is run-to-run variation. The historical
sections below preserve both datasets with their original definitions.

See the
[complete three-run sentinel report](docs/reports/aks-10k-els-loadgen-sentinel.md),
[machine-readable result](docs/reports/aks-10k-els-loadgen-sentinel.json),
[retained selected-run k6 HTML](docs/reports/aks-10k-els-loadgen-sentinel-run3-runner-1.html),
and the
[de-jitter analyzer](k8s-infra/scripts/analyze-aks-latency.ps1).

[Back to top](#featbit-server-sdk-websocket-load-testing)

## Historical experiment record

The sections below are chronological, immutable records of the completed
campaigns that led to the current reference result. Their original latency
boundaries, resource tables, selection rules, and limitations are retained
for auditability. Compare values across sections only when the metric boundary
and percentile aggregation rule match.

Resource figures remain inside the experiment that produced them. Node sizes,
Pod counts, runner topology, sampling cadence, and latency boundaries changed
between experiments, so the resource tables are not interchangeable.

### 1. Five-group reference matrix

**Historical status:** completed capacity comparison, 15/15 runs passed.

The benchmark ran on AKS with the official
`docker.io/featbit/featbit-evaluation-server:5.4.4` image. All groups used
10 × `Standard_D4ds_v5` loadgen nodes and
3 × `Standard_D4ds_v5` FeatBit nodes.

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

The primary metric deliberately selects the highest per-runner
`probe_sync_latency_ms p99` across all 10 revisions in each run. The table
selects the run with the smallest primary p99 within each group. It is a
best-observed comparison, not a three-run average or stability estimate.

#### Best run from each group

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

#### De-jittered view

A spike was defined before analysis as
`probe_sync_latency_ms > 100 ms`. This diagnostic removes only those samples;
values equal to 100 ms remain. Exact global percentiles cannot be reconstructed
from distributed k6 summaries, so p95 and p99 are the minimum–maximum range
across filtered runner summaries.

| Group | Removed spikes | Affected runner × revision batches | Retained samples | De-jittered weighted average | Runner p95 range | Runner p99 range |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **g1** | **7,543 (7.543%)** | **79 / 200** | **92,457** | **55.89 ms** | **84–97 ms** | **92–100 ms** |
| g2 | 7,652 (7.652%) | 177 / 400 | 92,348 | 58.58 ms | 89–98 ms | 95–100 ms |
| g3 | 5,503 (5.503%) | 51 / 200 | 94,497 | 56.09 ms | 85–97 ms | 93–100 ms |
| g4 | 6,624 (6.624%) | 116 / 400 | 93,376 | 57.48 ms | 85–98 ms | 91–100 ms |
| g5 | 20,911 (20.911%) | 156 / 200 | 79,089 | 62.12 ms | 94–98 ms | 99–100 ms |

This view describes the usual path. It does not replace the complete result,
hide threshold failures, or establish a new SLO.

#### Resource consumption

Each ELS Pod requested/limited 500m/1 CPU and 256Mi/512Mi memory. Autoscaling
was disabled and k6 used the cluster-internal Service. Values are independently
sampled, five-second aggregate peaks from the selected runs above. Node-pool
values include Kubernetes overhead; ELS and runner values include only the
named containers.

| Group | ELS aggregate peak | Runner aggregate peak | FeatBit-node aggregate peak | Loadgen-node aggregate peak |
| --- | ---: | ---: | ---: | ---: |
| **g1** | **540m / 803Mi** | **2.34 CPU / 13.81Gi** | **0.96 CPU / 5.91Gi** | **2.04 CPU / 30.56Gi** |
| g2 | 484m / 793Mi | 1.70 CPU / 14.46Gi | 0.92 CPU / 5.94Gi | 2.47 CPU / 32.05Gi |
| g3 | 617m / 1,334Mi | 1.41 CPU / 13.97Gi | 1.06 CPU / 6.47Gi | 2.09 CPU / 30.65Gi |
| g4 | 598m / 1,344Mi | 1.32 CPU / 14.42Gi | 0.91 CPU / 6.50Gi | 2.51 CPU / 31.95Gi |
| g5 | 390m / 511Mi | 1.76 CPU / 11.25Gi | 0.81 CPU / 5.59Gi | 2.06 CPU / 27.66Gi |

#### Finding

- The lowest best-observed p99 was g1 at 207.01 ms; its de-jittered weighted
  average was also the lowest at 55.89 ms.
- g2 produced the best three-run median and narrowest p99 range:
  233 ms across 232–262.02 ms.
- Increasing ELS from 6 to 12 Pods did not consistently improve p99 and
  increased ELS memory from roughly 0.8Gi to 1.3Gi.
- g5's selected p99 was 226.01 ms, but it had the highest weighted average and
  spike rate: 74.21 ms and 20.911%.
- Six ELS Pods are therefore the 10k reference topology. Twelve Pods add fixed
  overhead without a demonstrated latency gain.

See the
[five-group selected-run report](docs/reports/aks-p99-capacity-10k-best-runs.md),
[selected-run JSON](docs/reports/aks-p99-capacity-10k-best-runs.json),
[complete matrix report](docs/reports/aks-p99-capacity-10k-summary.md), and
[complete matrix JSON](docs/reports/aks-p99-capacity-10k-summary.json).

### 2. Quota-constrained D2 loadgen follow-up

**Historical status:** completed diagnostic; rejected as the capacity
baseline.

The existing quota was redistributed to 6 × D4 FeatBit nodes and
10 × D2 loadgen nodes. Six ELS Pods were isolated one per FeatBit node; k6
stayed at 20 × 500 connections, two runners per loadgen node.

#### Result

| Run | Weighted average | Conservative p99 | Maximum | >100 ms | Threshold failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 111.36 ms | 479.00 ms | 481 ms | 53.140% | 0 |
| 2 | 113.29 ms | 409.01 ms | 412 ms | 55.411% | 0 |
| 3 | 109.38 ms | 567.03 ms | 571 ms | 52.503% | 1 |

The third-run failure was one runner/revision p95 at 562 ms. Its co-located
runner slowed in the same revision; that D2 node reached roughly 71% CPU and
51% CPU pressure in the one-second event window, with no ELS throttling,
retransmission, or packet drop in that window.

The requested filtered view is retained, but removing `>100 ms` discarded
more than half of every run and therefore no longer describes occasional
jitter:

| Run | Removed | Retained | Filtered weighted average | Runner p95 range | Runner p99 range |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 53,140 | 46,860 | 58.19 ms | 95–97 ms | 99–100 ms |
| 2 | 55,411 | 44,589 | 59.43 ms | 96–97 ms | 99–100 ms |
| 3 | 52,503 | 47,497 | 57.50 ms | 96–97 ms | 99–100 ms |

#### Resource consumption

| Resource | Observed across three runs |
| --- | ---: |
| Six ELS containers | 445–511m CPU / 771–781Mi |
| Twenty runner containers | 1.18–2.65 CPU / 13.59–13.73Gi |
| Six FeatBit nodes | 2.00–2.05 CPU / 10.74–10.75Gi |
| Ten loadgen nodes | 3.11–3.37 CPU / 30.01–30.19Gi |
| Loadgen host CPU p99 | 44.70%–52.14% |
| Loadgen host CPU-pressure p99 | 27.67%–28.33% |
| Loadgen run-queue p99 | 6.66–7.00 on two-vCPU nodes |
| ELS per-Pod cgroup CPU p99 | 151–157m |

All formal revision windows combined had zero ELS throttled periods, zero
packet drops, and only two retransmitted TCP segments, neither aligned with
the worst tail.

#### Finding

Low five-second aggregate CPU did not imply generator headroom. D2 loadgen
scheduling pressure materially polluted the observer, so this topology cannot
replace the D4 reference.

See the
[complete D2 report](docs/reports/aks-10k-d2-node-isolation-1s.md),
[machine-readable data](docs/reports/aks-10k-d2-node-isolation-1s.json), and
[exact matrix](k8s-infra/matrices/aks-10k-d2-els-node-isolation-1s.json).

### 3. Quota-safe D4 loadgen validation

**Historical status:** completed capacity baseline; 3/3 runs passed.

Moving the ten loadgen nodes back to D4 while using six D2 FeatBit nodes kept
the cluster at 54 vCPU and reduced the conservative three-run median p99 from
the D2 diagnostic's 479 ms to **283.01 ms**.

This campaign predates the Redis publication observer. Its latency values use
the historical `FeatureFlag.UpdatedAt → SDK` boundary; its topology,
pass/fail, connection coverage, and resource evidence remain valid.

| Pool / workload | Configuration |
| --- | --- |
| system | 1 × `Standard_D2ds_v5` |
| FeatBit | 6 × `Standard_D2ds_v5`; UI/API/PostgreSQL/Redis plus ELS |
| ELS | 6 Pods, one per FeatBit node; 250m request / 1 CPU limit; 256Mi request / 512Mi limit |
| loadgen | 10 × `Standard_D4ds_v5` |
| k6 | 20 runners × 500 WebSockets; two runners per loadgen node |
| Total | 54 / 65 regional and DDSv5-family vCPU quota |

#### Complete post-warm-up result

| Run | Weighted average | Worst runner/revision p95 | Conservative p99 | Maximum | Samples >100 ms | Affected runner × revision batches | Failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 67.34 ms | 291.05 ms | 299.01 ms | 302 ms | 10,608 (10.608%) | 111 / 200 | 0 |
| 2 | 77.09 ms | 278.00 ms | 283.01 ms | 285 ms | 20,099 (20.099%) | 123 / 200 | 0 |
| **3** | **66.62 ms** | **247.00 ms** | **252.00 ms** | **257 ms** | **10,789 (10.789%)** | **115 / 200** | **0** |

Run 3 is the best observed repetition by the primary metric. The conservative
p99 median was 283.01 ms with a 252–299.01 ms range. Every run delivered
100,000 formal propagation samples, passed 10,000 post-ramp warm-up checks,
covered all revisions and connections, and had no threshold failure.

Run 2 revision 1 put all 10,000 samples above 100 ms. Its 20.099% tail is a
complete broadcast-wave event, not a handful of removable outliers.

#### Pre-registered de-jittered diagnostic

| Run | Removed | Retained | Filtered weighted average | Runner p95 range | Runner p99 range |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 10,608 (10.608%) | 89,392 | 60.02 ms | 91–97 ms | 96–100 ms |
| 2 | 20,099 (20.099%) | 79,901 | 59.77 ms | 88–97 ms | 94–100 ms |
| **3** | **10,789 (10.789%)** | **89,211** | **59.25 ms** | **88–97 ms** | **98–100 ms** |

The filtered view describes the usual path. It does not replace the complete
capacity gate or define a new SLO.

#### Resource consumption

Kubernetes values are same-sample, five-second aggregate peaks. Host CPU, CPU
pressure, run queue, softirq, retransmission/drop counters, and ELS cgroup
throttling were additionally sampled at approximately one-second intervals on
all 16 worker nodes.

| Resource | Observed across three runs |
| --- | ---: |
| Six ELS containers | 400–470m CPU / 874–894Mi |
| Twenty runner containers | 1.05–3.12 CPU / 13.92–14.49Gi |
| Six FeatBit nodes | 1.98–2.20 CPU / 10.53–11.08Gi |
| Ten loadgen nodes | 2.94–3.22 CPU / 28.77–30.32Gi |
| Loadgen host CPU p99 | 19.75%–23.26% |
| Loadgen host CPU-pressure p99 | 10.57%–11.76% |
| Loadgen run-queue p99 | 5.00 on four-vCPU nodes |
| ELS per-Pod cgroup CPU p99 | 162.8–163.9m |
| ELS throttled-period rate | 0.046%–0.052% |

All formal revision windows combined recorded one ELS throttled period, seven
TCP retransmitted segments, and zero packet drops. The data does not support
assigning the remaining tail to packet loss or ELS saturation.

#### Finding

Compared with the D2 loadgen diagnostic, median conservative p99, weighted
average, `>100 ms` rate, and loadgen CPU-pressure p99 improved by 40.92%,
39.52%, 79.70%, and 61.94%. Compared with historical g1, the current p99
median was 283.01 vs 296 ms, within the matrix's predeclared `<50 ms` and
`<10%` practical-equivalence rule. D2 loadgen capacity polluted the prior
observer, but the remaining tail still cannot be assigned to one FeatBit
component.

See the
[complete 54-vCPU report](docs/reports/aks-10k-d4-loadgen-d2-featbit-1s.md),
[machine-readable data](docs/reports/aks-10k-d4-loadgen-d2-featbit-1s.json),
and
[exact matrix](k8s-infra/matrices/aks-10k-d4-loadgen-d2-featbit-1s.json).

### 4. Three-stage latency contract

**Historical status:** preliminary attribution run; complete enough to
exclude several causes, not to identify one exact downstream component.

A fresh 10,000-connection run,
`growth-20260725-152154-ce333a5f-bb94`, introduced a read-only Redis
publication observer. Historical artifacts cannot be backfilled exactly
because they did not capture this boundary.

#### Latency contract

The canonical propagation metric is now:

`probe_sync_latency_ms = streaming_delivery_latency_ms`

The three measurements satisfy:

`end_to_end_latency_ms = control_plane_write_latency_ms + probe_sync_latency_ms`

| Metric | Boundary | Samples | Average | Min / max | p95 | p99 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `end_to_end_latency_ms` | controller PUT start → SDK applies revision | 100,000 | 65.82 ms | 12 / 219 ms | 68.05–206 ms | 70.01–209.01 ms |
| `control_plane_write_latency_ms` | PUT start → earliest Redis publication observation | 10 | 16.20 ms | 14 / 22 ms | 21.10 ms | 21.82 ms |
| `probe_sync_latency_ms` | earliest Redis publication observation → SDK applies revision | 100,000 | 49.62 ms | -2 / 203 ms | 53.05–190 ms | 55.01–193.01 ms |

The run used 20 × 500 runners, 10 × D4 loadgen nodes, and six ELS Pods placed
one per D2 FeatBit node. All 20 runners passed; all 100,000 formal propagation
samples, 10,000 post-ramp warm-up checks, 10 controller writes, and 100 formal
observer event matches were present.

The p95/p99 values are min–max ranges across 20 runner × 10 revision cohorts,
not merged global percentiles. Counts, averages, and min/max are exact
aggregates. The `-2 ms` minimum is measurement uncertainty, not physical
negative latency.

The legacy `FeatureFlag.UpdatedAt → SDK` measurement averaged 63.02 ms in the
same run and is retained as `probe_updated_at_to_sdk_latency_ms`. Moving the
boundary removed a stable 13.40 ms from the average, but it did not remove the
downstream tail shape.

#### Resource consumption

Five-second resource samples and one-second host/cgroup evidence belong only
to this three-stage run:

| Resource | Observed |
| --- | ---: |
| Each timing observer | 0.98–1.14m CPU / 7.96–7.98 MB |
| Each ELS Pod, five-second peak | 73.96–80.64m CPU / 139.90–171.04 MB |
| Each k6 runner, five-second peak | 116.27–222.74m CPU / 805.74–890.48 MB |
| Each loadgen node, five-second peak | 336.79–383.49m CPU / 3.44–3.54 GB |
| Each FeatBit node, five-second peak | 351.31–407.35m CPU / 1.90–2.32 GB |
| API / PostgreSQL / Redis CPU | 8.19m / 7.63m / 32.25m |
| Loadgen host CPU p99 / mean | 22.00% / 7.41% |
| Loadgen CPU-pressure p99 / mean | 12.50% / 5.29% |
| ELS per-Pod cgroup CPU p99 / max | 159.29m / 396.14m |
| ELS throttled periods, full run | 29 / 46,640 (0.0622%); 113.4 ms total |

Every formal revision window recorded zero packet drops, zero retransmissions,
and zero ELS throttling. The full-run counters above include startup and
non-revision periods.

#### Current jitter localization

The stable control-plane measurement explains why the new metric still looks
similar to the historical one: a nearly constant component was subtracted,
while the irregular downstream component remained.

| Evidence | Observation | Current interpretation |
| --- | --- | --- |
| Control plane | 14–22 ms; p99 21.82 ms | API/database/write path is not the tail source |
| Streaming share | 49.62 ms of the 65.82 ms average | About 75% of average latency is after Redis publication |
| Worst tail | 193.01 ms streaming out of about 209 ms end-to-end | More than 92% of the worst tail is downstream |
| Revision shape | Median runner p99 stayed at 78.5–88.5 ms | The usual path is stable |
| Spike breadth | Only 0–4 of 20 runners spiked per revision | Not a cluster-wide broadcast slowdown |
| ELS capacity | Low CPU and no revision-window throttling | ELS CPU/memory limit is not the demonstrated bottleneck |
| Network | No revision-window loss or retransmission | Packet loss is not supported as the cause |
| Loadgen association | Exploratory p99 correlation ≈0.51 with node CPU and ≈0.47 with CPU pressure | Runner/node scheduling is a plausible contributor, not yet proven causal |
| ELS association | Exploratory p99 correlation ≈0.06 with ELS CPU | Adding ELS compute alone is unlikely to remove the tail |

The high cohorts moved between runners and nodes. Some co-located runners
spiked together—for example both runners on one loadgen node were high in
revisions 3 and 9—while other co-located pairs did not. The evidence therefore
supports a mixed downstream problem:

1. loadgen/k6 receive scheduling or VM scheduling jitter is a likely
   contributor;
2. per-ELS connection fan-out or batching remains plausible;
3. Redis-to-ELS subscriber timing remains possible but is not associated with
   Redis saturation;
4. the existing artifacts cannot map each service-routed WebSocket to an ELS
   Pod, so they cannot separate the first two explanations.

At this stage, the correct decision was **INCONCLUSIVE for the exact
component**, with strong evidence against the control plane, ELS resource
saturation, and packet loss. The later sentinel experiment in section 5
demonstrates a receiver-side contribution without changing this stage's
original evidence. The internal URL
`ws://featbit-els.featbit.svc.cluster.local:5100` bypasses the public ingress;
an established WebSocket is not rebalanced by nginx or the Kubernetes Service
for each flag update.

See the
[full three-stage report](docs/reports/aks-10k-stage-latency-validation.md),
[rendered HTML](docs/reports/aks-10k-stage-latency-validation.html),
[machine-readable summary](docs/reports/aks-10k-stage-latency-validation.json),
and
[exact matrix](k8s-infra/matrices/aks-stage-latency-validation.json).

### 5. ELS × loadgen sentinel diagnostic

**Historical status:** completed receiver-path localization; 3/3 fresh runs
passed. This is the detailed evidence record behind the current reference
result at the top of this README.

This experiment retained the 10,000 service-routed main connections and added
180 separately reported direct sentinel connections. Each of the 10 loadgen
nodes opened three WebSockets to every one of the six ELS Pod IPs. No FeatBit
source code was changed.

The pre-registered cell threshold was a three-connection median above 100 ms.
Four or more slow ELS targets in one loadgen row formed a `loadgen-row`; seven
or more slow loadgen rows for one ELS formed an `els-column`; 30 or more slow
cells formed a `global` wave.

#### Complete result

| Run | Main streaming avg | Main worst p95 / p99 | Control avg | Sentinel avg / earliest p99 / node-local p99 | Slow cells | Failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 54.67 ms | 183 / 187 ms | 16.10 ms | 52.15 / 104 / 100 ms | 8 / 600 | 0 |
| 2 | 55.50 ms | 210 / 218 ms | 16.30 ms | 54.51 / 108.02 / 104 ms | 14 / 600 | 0 |
| 3 | 54.09 ms | 165 / 168 ms | 15.80 ms | 53.59 / 119.01 / 110.01 ms | 23 / 600 | 0 |

All three runs had 100,000 canonical streaming samples, 10,000 full-connection
warm-up checks, 180/180 ready sentinels, 1,800/1,800 formal sentinel events,
20/20 passing runners, and complete five-second plus one-second evidence.
Across the three runs, 45/1,800 cell/revision combinations crossed 100 ms.

#### Pre-registered classification

| Run | Stable | Main runners only | Isolated cells | Loadgen row | ELS column | Global |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 2 | 4 | 4 | 0 | 0 | 0 |
| 2 | 0 | 6 | 4 | 0 | 0 | 0 |
| 3 | 0 | 4 | 3 | 3 | 0 | 0 |

The table above preserves the pre-registered earliest-observer boundary. A
secondary same-node observer view removes each receiver's 0–10 ms
clock/observer offset:

| Run | Primary slow cells | Primary rows | Node-local slow cells | Node-local rows | Node-local ELS columns / global |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 8 / 600 | 0 | 2 / 600 | 0 | 0 / 0 |
| 2 | 14 / 600 | 0 | 10 / 600 | 0 | 0 / 0 |
| 3 | 23 / 600 | 3 | 14 / 600 | 1 | 0 / 0 |

Run 3 produced three primary loadgen rows and one row that survived the
node-local sensitivity boundary:

| Revision | Receiver node | Primary → node-local ELS targets | Observer offset | Colocated main-runner raw / node-local p99 |
| ---: | --- | ---: | ---: | ---: |
| 2 | `aks-loadgen-10501918-vmss000006` | 5/6 → 0/6 | 3 ms | 111 / 98 ms; 139 / 126 ms |
| **8** | **`aks-loadgen-10501918-vmss000003`** | **6/6 → 6/6** | **10 ms** | **124 / 104 ms; 123.02 / 103.02 ms** |
| 9 | `aks-loadgen-10501918-vmss000003` | 4/6 → 0/6 | 10 ms | 126 / 102 ms; 132.01 / 108.01 ms |

The first value in each runner pair retains
`FeatureFlag.UpdatedAt → SDK`; the second uses that receiver node's local
Redis observer as the boundary. The sensitivity view was added after the
pre-registered result and does not replace it.

#### Resource consumption

These figures belong only to the sentinel experiment. The extra 180
connections and 10 sentinel Pods were present in every sample.

| Run | Loadgen CPU / pressure / run queue p99 | ELS CPU p99 / max | Formal-window retrans / drops / ELS throttle | Main-runner / sentinel memory peak |
| --- | ---: | ---: | ---: | ---: |
| 1 | 21.00% / 13.32% / 5 | 153.7m / 391m | 6 / 0 / 0 | 18.08 / 0.43 GiB |
| 2 | 21.95% / 14.55% / 5 | 145.9m / 438m | 6 / 0 / 0 | 17.89 / 0.50 GiB |
| 3 | 22.94% / 14.86% / 6 | 152.0m / 466.5m | 0 / 0 / 0 | 17.90 / 0.52 GiB |

#### Finding

The experiment demonstrates that the receiver side is one real contributor,
even after removing cross-node clock/observer offset:

- run 3 revision 8 delayed all six direct ELS targets on loadgen node 003
  under both boundaries;
- both independent main runner processes on that node remained over 100 ms
  from the same-node observer;
- the independent sentinel process also slowed, despite connecting directly
  to six different ELS Pods;
- that one-second window showed only 16.51% CPU, 11.98% CPU pressure, run
  queue 2, zero retransmission, and zero packet drop.

This is consistent with a sub-second receiver node/VM scheduling, kernel
network wake-up, or per-process receive delay, not CPU exhaustion. Two other
primary rows fell below the strict `>100 ms` cell threshold after removing
3–10 ms of node-local observer offset, so they cannot be used as equally
strong node-delay evidence. Cross-node clock offset therefore affects
threshold-adjacent results but cannot explain revision 8.

No ELS column occurred in 30 measured revisions, ELS CPU remained around
146–154m at p99, and no formal window recorded ELS throttling. The evidence
therefore does not support ELS Pod capacity, a specific ELS node, Redis
publication, or cluster-wide broadcast as the source of the observed tail.

The exact source of the remaining main-runner-only and isolated-cell tail is
still **INCONCLUSIVE**. It is narrowed to receiver/loadgen scheduling,
per-runner receive loops, or small connection cohorts that three sentinels per
cell do not fully reproduce; it is not narrowed to a FeatBit source function.

See the
[complete sentinel report](docs/reports/aks-10k-els-loadgen-sentinel.md),
[machine-readable result](docs/reports/aks-10k-els-loadgen-sentinel.json),
[exact matrix](k8s-infra/matrices/aks-els-loadgen-sentinel.json), and
[AKS sentinel runbook](k8s-infra/README-AKS.md#112-els--loadgen-sentinel-判别实验).

## Test profiles

`Ramp rate` means new WebSocket connections per second.

| Profile | Run location | Ramp rate | Total connections | Provisioned flags | Changed/measured flags |
| --- | --- | ---: | ---: | ---: | ---: |
| Smoke | Local, then remote load generator | 1/s | 10 | 1 | 1 |
| Baseline | Remote load generator | 10/s | 1,000 | 10 | 1 |
| Baseline Plus | Remote load generator | 30/s | 3,000 | 10 | 1 |
| Growth | AKS only | 100/s | 10,000 | 20 | 1 |
| Growth Plus | AKS only | 200/s | 20,000 | 20 | 1 |

The 10,000-connection investigations retain a 100/s ramp, 20 provisioned
flags, flag-02 as the unmeasured full-connection warm-up, flag-01 as the only
changed and measured flag, and 10 formal revisions per run.

[Back to top](#featbit-server-sdk-websocket-load-testing)

## Capacity boundary

These experiments establish a verified lower bound, not the maximum:

- 3 ELS Pods supported 10,000 WebSockets under the tested 20-runner topology.
- 6 ELS Pods supported 10,000 WebSockets under both the 20- and 40-runner
  topologies.
- The worst conservative p99 observed anywhere in the five-group matrix was
  329 ms.
- Connection counts above 10,000 require a separate controlled capacity
  ladder before claiming a higher limit.

## Published k6 report

The latest retained artifact is the
[sentinel run-3 runner-1 k6 HTML](docs/reports/aks-10k-els-loadgen-sentinel-run3-runner-1.html)
with its
[summary JSON](docs/reports/aks-10k-els-loadgen-sentinel-run3-runner-1-summary.json).
It was selected deterministically as the runner with the highest
per-revision raw p99 in the final repetition:

- Run: `growth-20260726-052542-ce333a5f-ad79`
- Runner: 1 of 20
- Connections / formal samples: 500 / 5,000
- Overall raw p99 / max: 169 / 181 ms
- Worst per-revision raw p99: 180 ms

After these changes reach `main`, the existing Pages workflow publishes it at
`https://featbit.github.io/featbit-load-testing/reports/aks-10k-els-loadgen-sentinel-run3-runner-1.html`.
Until that deployment occurs, the
[previous verified online report](https://featbit.github.io/featbit-load-testing/reports/aks-10k-g2-run3-runner-15.html)
remains available.

Distributed k6 creates one HTML per runner, not a merged 10,000-connection
report. The HTML also retains the raw `FeatureFlag.UpdatedAt → SDK` metric.
Use the
[three-run sentinel report](docs/reports/aks-10k-els-loadgen-sentinel.md)
and its
[machine-readable result](docs/reports/aks-10k-els-loadgen-sentinel.json)
for canonical streaming latency and aggregate conclusions. Full artifact
selection, hashes, and historical reports are recorded in
[artifact provenance](docs/reports/README.md).

## Reproduce the test

Detailed commands and operational gates intentionally live outside this
README:

| File | Purpose |
| --- | --- |
| [`k8s-infra/README-AKS.md`](k8s-infra/README-AKS.md) | End-to-end AKS deployment, credentials, isolation, execution, monitoring, and collection |
| [`k8s-infra/matrices/aks-p99-capacity.json`](k8s-infra/matrices/aks-p99-capacity.json) | Exact five-group experiment definition and execution order |
| [`k8s-infra/matrices/aks-10k-d2-els-node-isolation-1s.json`](k8s-infra/matrices/aks-10k-d2-els-node-isolation-1s.json) | Exact D2 loadgen diagnostic |
| [`k8s-infra/matrices/aks-10k-d4-loadgen-d2-featbit-1s.json`](k8s-infra/matrices/aks-10k-d4-loadgen-d2-featbit-1s.json) | Exact 54-vCPU, 20 × 500, three-repetition validation |
| [`k8s-infra/matrices/aks-stage-latency-validation.json`](k8s-infra/matrices/aks-stage-latency-validation.json) | Exact three-stage attribution run |
| [`k8s-infra/matrices/aks-els-loadgen-sentinel.json`](k8s-infra/matrices/aks-els-loadgen-sentinel.json) | Exact three-run ELS-column versus loadgen-row diagnostic |
| [`k8s-infra/scripts/run-aks-capacity-matrix.ps1`](k8s-infra/scripts/run-aks-capacity-matrix.ps1) | Resumable matrix executor with topology and evidence gates |
| [`k8s-infra/scripts/start-aks-els-sentinels.ps1`](k8s-infra/scripts/start-aks-els-sentinels.ps1) | Creates the temporary direct-ELS sentinel matrix after ELS placement is fixed |
| [`k8s-infra/scripts/analyze-aks-sentinel-matrix.ps1`](k8s-infra/scripts/analyze-aks-sentinel-matrix.ps1) | Joins direct sentinel receive times to the Redis publication boundary and applies the row/column rules |
| [`k8s-infra/scripts/summarize-aks-sentinel-experiment.mjs`](k8s-infra/scripts/summarize-aks-sentinel-experiment.mjs) | Recreates the three-run sentinel result, repeatability, classification, and experiment-specific resource table |
| [`k8s-infra/scripts/summarize-aks-quota-safe-d4-loadgen.ps1`](k8s-infra/scripts/summarize-aks-quota-safe-d4-loadgen.ps1) | Recreates the D4 full/de-jittered latency, one-second evidence, and resource report |
| [`k8s-infra/scripts/summarize-aks-capacity-matrix.ps1`](k8s-infra/scripts/summarize-aks-capacity-matrix.ps1) | Recreates five-group latency, comparison, and resource tables |
| [`k8s-infra/scripts/analyze-aks-stage-latency.ps1`](k8s-infra/scripts/analyze-aks-stage-latency.ps1) | Recreates all three latency stages for one collected run |
| [`k8s-infra/scripts/analyze-aks-latency.ps1`](k8s-infra/scripts/analyze-aks-latency.ps1) | Recreates complete and `>100 ms` de-jittered views for one run |
| [`k8s-infra/terraform/aks/README.md`](k8s-infra/terraform/aks/README.md) | Ephemeral AKS, ACR, and node-pool provisioning |
| [`k8s-infra/README.md`](k8s-infra/README.md) | Docker Desktop rehearsal and local result collection |
| [`.github/workflows/publish-server-sdk-k6-report.yml`](../.github/workflows/publish-server-sdk-k6-report.yml) | Publishes the retained Server SDK HTML artifact to GitHub Pages |

## What this test covers

Each k6 virtual user opens an independent WebSocket and follows the FeatBit
.NET Server SDK streaming and version-application behavior. The test validates
connection establishment, full synchronization, patch updates, application
heartbeats, revision order, final values, and connection survival. It does not
start real .NET processes.
