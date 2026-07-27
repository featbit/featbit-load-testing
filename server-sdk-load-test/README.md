[← All load-test suites](../README.md)

# FeatBit Server SDK WebSocket Load Testing

This suite uses k6 to validate FeatBit Evaluation Server WebSocket
connections, initial synchronization, feature-flag propagation, heartbeat
handling, and final revision consistency.

Run suite-specific commands from the `server-sdk-load-test/` directory. Paths
in the AKS and Docker Desktop runbooks are relative to that directory.

[Verified result](#verified-10000-connection-result) ·
[>100 ms jitter is attributed to k6](#jitter-and-tail-latency-above-100-ms-are-attributed-to-the-k6-measurement-path-not-featbit-els) ·
[Historical records](#historical-experiment-record) ·
[Five-group reference](#1-five-group-reference-matrix) ·
[Latest three-stage summary](docs/reports/aks-10k-three-stage-g5-d4.html) ·
[Latest k6 report](docs/reports/aks-10k-three-stage-g5-d4-runner-17.html) ·
[AKS runbook](k8s-infra/README-AKS.md)

## Verified 10,000-connection result

All rows below used 10,000 Server SDK WebSockets, a 100 connections/s ramp,
20 provisioned flags, one unmeasured post-ramp warm-up flag, one measured
flag, 10 revisions at 30-second intervals, and the internal Kubernetes
streaming Service. No FeatBit source code or image was changed.

The Five-group rows select the lowest worst-cohort p99 from three repetitions;
the two Three-stage rows are single formal runs. Complete p95/p99 values are
the conservative worst runner × revision cohort. `request → limit` describes
each ELS Pod.

| Experiment | Runners | ELS Pods: CPU; memory | Loadgen nodes | `probe_sync_latency_ms` boundary | Complete avg / p95 / p99 | `>100 ms` | De-jittered retained / avg / p95 / p99 |
| --- | ---: | --- | --- | --- | ---: | ---: | ---: |
| Five-group g1 | 20 × 500 | 6 × 500m→1 CPU; 256→512Mi | 10 × D4, 4 vCPU / 16Gi each | `FeatureFlag.UpdatedAt` → SDK | 61.26 / 202.05 / 207.01 ms | 7.543% | 92,457 / **55.89 ms / 84–97 ms** / 92–100 ms |
| Five-group g2 | 40 × 250 | 6 × 500m→1 CPU; 256→512Mi | 10 × D4, 4 vCPU / 16Gi each | `FeatureFlag.UpdatedAt` → SDK | 63.17 / 231 / 232 ms | 7.652% | 92,348 / 58.58 ms / 89–98 / 95–100 ms |
| Five-group g3 | 20 × 500 | 12 × 500m→1 CPU; 256→512Mi | 10 × D4, 4 vCPU / 16Gi each | `FeatureFlag.UpdatedAt` → SDK | 60.44 / 243 / 245 ms | 5.503% | 94,497 / 56.09 ms / 85–97 / 93–100 ms |
| Five-group g4 | 40 × 250 | 12 × 500m→1 CPU; 256→512Mi | 10 × D4, 4 vCPU / 16Gi each | `FeatureFlag.UpdatedAt` → SDK | 61.63 / 222 / 223 ms | 6.624% | 93,376 / 57.48 ms / 85–98 / 91–100 ms |
| Five-group g5 | 20 × 500 | 3 × 500m→1 CPU; 256→512Mi | 10 × D4, 4 vCPU / 16Gi each | `FeatureFlag.UpdatedAt` → SDK | 74.21 / 225 / 226.01 ms | 20.911% | 79,089 / 62.12 ms / 94–98 / 99–100 ms |
| Three-stage original | 20 × 500 | 6 × 250m→1 CPU; 256→512Mi | 10 × D4, 4 vCPU / 16Gi each | Redis publication observed → SDK | 49.62 / 190 / **193.01 ms** | Not retained | Not reconstructible for this boundary |
| Three-stage G5 replay | 20 × 500 | 3 × 500m→1 CPU; 256→512Mi | 10 × D4, 4 vCPU / 16Gi each | Redis publication observed → SDK | 59.83 / 228 / 237 ms | Not retained | Not reconstructible for this boundary |

The metric name is shared, but its clock starts at different boundaries. The
Five-group records predate the Redis observer and include the API/database
timestamp gap; the Three-stage rows start when Redis publication is first
observed. They are shown together for auditability, not as a direct
before/after comparison.

The De-jittered view removes `probe_sync_latency_ms > 100 ms`. It is a
secondary description of the usual path, not an SLO and not the complete
distribution. The Three-stage runs did not retain a fixed-cutoff submetric at
the canonical Redis-observer boundary, so inventing post-hoc filtered values
would be misleading.

### Scaling conclusion

Across the tested 10,000-connection configurations, larger FeatBit nodes,
more ELS Pod resources, more ELS replicas, and wider Pod spreading did not
consistently improve latency. Reducing loadgen capacity did make latency and
CPU pressure worse, so the observed bottleneck is more likely in the
k6/loadgen measurement path than in FeatBit ELS. This conclusion applies only
to the tested configurations.

### Jitter and tail latency above 100 ms are attributed to the k6 measurement path, not FeatBit ELS

The evidence localizes a material part of the measured tail after packets
leave FeatBit, without claiming that every delayed sample has one cause:

| Evidence | Observation | Interpretation |
| --- | --- | --- |
| Loadgen-only resource change | Moving loadgen from D4 to D2 raised median conservative p99 from 283.01 to 479 ms and put more than 52% of samples above 100 ms; the failing D2 window reached about 51% CPU pressure | Generator/receiver scheduling can dominate the reported latency |
| Direct sentinel matrix | One loadgen node delayed direct connections to all six ELS Pods at once; both colocated k6 runners also slowed | A receiver-row wave cannot be explained by one ELS Pod or one ELS node |
| ELS scaling | Increasing ELS from 6 to 12 Pods did not consistently improve p99; 12 Pods increased memory without a demonstrated latency gain | ELS replica count is not the controlling variable in these runs |
| ELS and network evidence | ELS CPU stayed far below limits, formal windows had negligible throttling, and the worst windows had no aligned packet drops or retransmissions | ELS saturation and packet loss are not supported as the tail source |
| Three-stage split | Control-plane p99 stayed at 12.82–21.82 ms while streaming-cohort p99 reached 193.01–237 ms | The API/database write stage is not the observed long tail |

The strongest current conclusion is therefore: **k6/loadgen VM scheduling,
kernel wake-up, receive-loop scheduling, and SDK application time materially
inflate the measured tail**. The exact cause of every remaining isolated
sample is still inconclusive, but the evidence does not support FeatBit API,
Redis, PostgreSQL, or ELS CPU/memory capacity as the primary bottleneck.

### Evidence and reproduction

- Five-group: [selected-run data](docs/reports/aks-p99-capacity-10k-best-runs.json),
  [complete matrix data](docs/reports/aks-p99-capacity-10k-summary.json),
  and [exact matrix](k8s-infra/matrices/aks-p99-capacity.json).
- Three-stage: [original run](docs/reports/aks-10k-stage-latency-validation.json),
  [latest G5 replay](docs/reports/aks-10k-three-stage-g5-d4.json),
  [original matrix](k8s-infra/matrices/aks-stage-latency-validation.json),
  and [G5 replay matrix](k8s-infra/matrices/aks-three-stage-g5-d4-els3.json).
- Commands and operational checks remain in the
  [AKS runbook](k8s-infra/README-AKS.md).

## Historical experiment record

The sections below are chronological, immutable records of the completed
campaigns that led to the current reference result. Their original latency
boundaries, resource tables, selection rules, and limitations are retained
for auditability. Compare values across sections only when the metric boundary
and percentile aggregation rule match.

Resource figures remain inside the experiment that produced them. Node sizes,
Pod counts, runner topology, sampling cadence, and latency boundaries changed
between experiments, so the resource tables are not interchangeable.

Each section links to a compact aggregate report, machine-readable JSON, and
the exact experiment matrix where available. Per-runner output, verbose logs,
credentials, and other generated files remain under the ignored `results/`
tree rather than being committed.

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

**Historical status:** two completed single-run observations. The original
run introduced the read-only Redis publication observer; the latest run
replayed the historical G5 topology with three ELS Pods spread across three
D4 FeatBit nodes. Neither run changed FeatBit source code.

#### Latency contract

The canonical propagation metric is now:

`probe_sync_latency_ms = streaming_delivery_latency_ms`

The three measurements satisfy:

`end_to_end_latency_ms = control_plane_write_latency_ms + probe_sync_latency_ms`

The two runs used the same load contract: 10,000 WebSocket connections at
100 connections/s, 20 runners × 500 connections, 20 provisioned flags, only
`loadtest-sync-probe-01` measured, a separate flag-02 warm-up, and 10 measured
revisions spaced 30 seconds apart. Both runs completed with all 20 runners,
100,000 formal propagation samples, 10,000 post-ramp warm-up checks, 10
controller writes, and 100 observer event matches.

| Run | Metric | Boundary | Samples | Average | Min / max | p95 | p99 |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Previous: 6 ELS / 6 D2 | `end_to_end_latency_ms` | controller PUT start → SDK applies revision | 100,000 | 65.82 ms | 12 / 219 ms | 68.05–206 ms | 70.01–209.01 ms |
| Previous: 6 ELS / 6 D2 | `control_plane_write_latency_ms` | PUT start → earliest Redis publication observation | 10 | 16.20 ms | 14 / 22 ms | 21.10 ms | 21.82 ms |
| Previous: 6 ELS / 6 D2 | `probe_sync_latency_ms` | earliest Redis publication observation → SDK applies revision | 100,000 | 49.62 ms | -2 / 203 ms | 53.05–190 ms | 55.01–193.01 ms |
| Latest: 3 ELS / 3 D4 | `end_to_end_latency_ms` | controller PUT start → SDK applies revision | 100,000 | 69.43 ms | 8 / 255 ms | 85–239 ms | 87.01–248 ms |
| Latest: 3 ELS / 3 D4 | `control_plane_write_latency_ms` | PUT start → earliest Redis publication observation | 10 | 9.60 ms | 7 / 13 ms | 12.10 ms | 12.82 ms |
| Latest: 3 ELS / 3 D4 | `probe_sync_latency_ms` | earliest Redis publication observation → SDK applies revision | 100,000 | 59.83 ms | -1 / 244 ms | 77–228 ms | 79.01–237 ms |

The p95/p99 values are min–max ranges across 20 runner × 10 revision cohorts,
not merged global percentiles. Counts, averages, and min/max are exact
aggregates. The `-2 ms` and `-1 ms` minima are cross-node clock, scheduling,
and millisecond-rounding uncertainty, not physical negative latency.

The legacy `FeatureFlag.UpdatedAt → SDK` measurement averaged 63.02 ms in the
previous run and remains available as
`probe_updated_at_to_sdk_latency_ms`. Moving the boundary removed a stable
13.40 ms from that run's average, but it did not remove the downstream tail
shape.

#### Provisioned resources

The cluster stayed at 54 provisioned vCPUs in both observations, including
one `Standard_D2ds_v5` system node. The worker topology and Pod allocations
were:

| Resource | Previous run | Latest G5 replay |
| --- | --- | --- |
| Run ID | `growth-20260725-152154-ce333a5f-bb94` | `growth-20260726-164117-6c29992e-0491` |
| FeatBit worker pool | 6 × `Standard_D2ds_v5`; 11.40 allocatable CPU / 39.78 GiB | 3 × `Standard_D4ds_v5`; 11.58 allocatable CPU / 43.48 GiB |
| Loadgen worker pool | 10 × `Standard_D4ds_v5`; 38.60 allocatable CPU / 148.83 GiB | Same |
| ELS placement | 6 Pods; exactly 1 per FeatBit node | 3 Pods; exactly 1 per FeatBit node |
| ELS, each Pod | request 250m CPU / 256 MiB; limit 1 CPU / 512 MiB | request 500m CPU / 256 MiB; limit 1 CPU / 512 MiB |
| k6 placement | 20 Pods; 2 per loadgen node | Same |
| k6, each Pod | request 500m CPU / 1 GiB; no CPU limit; 3 GiB memory limit | request 1 CPU / 2 GiB; no CPU limit; 6 GiB memory limit |
| Redis timing observers | 10 Pods; request 5m CPU / 16 MiB and limit 100m CPU / 64 MiB each | Same |
| UI, one Pod | request 100m CPU / 128 MiB; limit 500m CPU / 512 MiB | Same |
| API, one Pod | request 100m CPU / 256 MiB; limit 500m CPU / 1 GiB | Same |
| PostgreSQL, one Pod | request 1 CPU / 2 GiB; no CPU limit; 4 GiB memory limit | request 500m CPU / 2 GiB; no CPU limit; 4 GiB memory limit |
| Redis, one Pod | request 1 CPU / 1 GiB; no CPU limit; 2 GiB memory limit | request 500m CPU / 1 GiB; no CPU limit; 2 GiB memory limit |

This is not a strict D2-versus-D4 single-variable comparison. ELS replica
count and per-Pod request, k6 requests, and PostgreSQL/Redis CPU requests also
changed. It is a replay of two complete historical resource profiles.

#### Observed resource consumption

The following are simultaneous aggregate peaks from the five-second
Kubernetes sampler. Percentages use the applicable aggregate request, limit,
or allocatable node-pool capacity; a request percentage above 100% would be
valid for burstable containers with no CPU limit.

| Scope | Previous peak and occupancy | Latest peak and occupancy |
| --- | --- | --- |
| All ELS Pods | 468.87m CPU: 31.26% request / 7.81% limit; 899.84 MiB: 58.58% request / 29.29% limit | 307.02m CPU: 20.47% request / 10.23% limit; 509.32 MiB: 66.32% request / 33.16% limit |
| All k6 runners | 3.10 CPU: 31.02% request; 15.95 GiB: 79.73% request / 26.58% limit | 794.94m CPU: 3.97% request; 17.95 GiB: 44.87% request / 14.96% limit |
| FeatBit worker pool | 2.26 CPU / 11.34 GiB: 19.79% CPU / 28.49% memory | 1.34 CPU / 5.33 GiB: 11.54% CPU / 12.25% memory |
| Loadgen worker pool | 3.60 CPU / 32.43 GiB: 9.32% CPU / 21.79% memory | 3.95 CPU / 36.33 GiB: 10.23% CPU / 24.41% memory |

Supporting-service peaks were also well below their configured resources:

| Service | Previous five-second peak | Latest five-second peak |
| --- | ---: | ---: |
| UI | 0.60m CPU / 3.07 MiB | 0.38m CPU / 4.55 MiB |
| API | 8.19m CPU / 205.38 MiB | 36.63m CPU / 161.34 MiB |
| PostgreSQL | 7.63m CPU / 38.71 MiB | 7.04m CPU / 32.09 MiB |
| Redis | 32.25m CPU / 8.13 MiB | 32.57m CPU / 7.94 MiB |
| Timing observer, each | 0.98–1.14m CPU / approximately 7.6 MiB | 0.81–1.48m CPU / approximately 7.6 MiB |

The separate one-second host/cgroup capture provides the short-interval
evidence:

| Evidence | Previous: 6 ELS / 6 D2 | Latest: 3 ELS / 3 D4 |
| --- | ---: | ---: |
| Loadgen host CPU p99 | 22.00% | 25.30% |
| Loadgen CPU-pressure p99 | 12.50% | 14.64% |
| Loadgen run queue p99 | 5 | 5 |
| FeatBit host CPU p99 | 31.52% | 17.71% |
| FeatBit CPU-pressure p99 | 21.08% | 14.77% |
| ELS per-Pod cgroup CPU p99 / max | 159.29m / 396.14m | 190.88m / 419.31m |
| ELS throttled periods, full run | 29 / 46,640 (0.062%); 113.42 ms | 29 / 23,461 (0.124%); 639.09 ms |
| TCP retransmissions, loadgen / FeatBit | 13 / 11 | 28 / 7 |
| Packet drops | 0 | 0 |

Full-run throttling and retransmission counters include startup and
non-revision periods. In the previous run, every formal revision window had
zero drops, retransmissions, and ELS throttling. In the latest run, the worst
streaming cohort was revision 2 at 237 ms p99; its window likewise had zero
ELS throttling, retransmissions, and drops, while loadgen CPU pressure reached
36.14%.

#### Current jitter localization

The latest profile made the control plane faster but did not improve
streaming delivery. Average control-plane time fell from 16.20 to 9.60 ms,
while average streaming time rose from 49.62 to 59.83 ms and the worst
runner/revision streaming p99 rose from 193.01 to 237 ms. Neither observation
shows CPU, memory, ELS throttling, retransmission, or packet-loss saturation
that explains the tail.

| Evidence | Observation | Current interpretation |
| --- | --- | --- |
| Control plane | 7–22 ms across the two runs; p99 no higher than 21.82 ms | API/database/write path is not the observed tail source |
| Streaming share | 49.62/65.82 ms previously; 59.83/69.43 ms latest | Most average latency is after Redis publication |
| ELS capacity | Low aggregate utilization; worst latest window had no ELS throttling | ELS CPU or memory exhaustion is not demonstrated |
| Network | Zero packet drops; worst latest window had no retransmission | Packet loss is not supported as the cause |
| Latest loadgen association | Exploratory p99 correlation ≈0.51 with CPU and ≈0.60 with CPU pressure | Runner/node or Azure VM scheduling jitter remains plausible, not proven causal |
| Latest ELS association | Exploratory p99 correlation ≈0.15 with ELS CPU and ≈0.06 with throttled periods | Adding ELS compute alone is unlikely to remove the tail |

The high cohorts moved between runners and loadgen nodes. Some co-located
runners spiked together while other pairs did not. The combined evidence
therefore supports a mixed downstream problem:

1. loadgen/k6 receive scheduling or VM scheduling jitter is a likely
   contributor;
2. per-ELS connection fan-out or batching remains plausible;
3. Redis-to-ELS subscriber timing remains possible but is not associated with
   Redis saturation;
4. the existing artifacts cannot map each service-routed WebSocket to an ELS
   Pod, so they cannot separate the first two explanations.

At this stage, the correct decision was **INCONCLUSIVE for the exact
component**, with strong evidence against the control plane, ELS resource
saturation, and packet loss. One formal repetition per profile is not enough
to claim repeatability or a causal difference. The later sentinel experiment
in section 5 demonstrates a receiver-side contribution without changing
these observations. The internal URL
`ws://featbit-els.featbit.svc.cluster.local:5100` bypasses the public ingress;
an established WebSocket is not rebalanced by nginx or the Kubernetes Service
for each flag update.

Previous-run artifacts:
[full report](docs/reports/aks-10k-stage-latency-validation.md),
[rendered HTML](docs/reports/aks-10k-stage-latency-validation.html),
[machine-readable summary](docs/reports/aks-10k-stage-latency-validation.json),
[one-second evidence](docs/reports/aks-10k-stage-latency-validation-node-evidence-1s.md),
[evidence JSON](docs/reports/aks-10k-stage-latency-validation-node-evidence-1s.json),
and [exact matrix](k8s-infra/matrices/aks-stage-latency-validation.json).

Latest G5-replay artifacts:
[full report](docs/reports/aks-10k-three-stage-g5-d4.md),
[rendered HTML](docs/reports/aks-10k-three-stage-g5-d4.html),
[machine-readable summary](docs/reports/aks-10k-three-stage-g5-d4.json),
[one-second evidence](docs/reports/aks-10k-three-stage-g5-d4-node-evidence-1s.md),
[evidence JSON](docs/reports/aks-10k-three-stage-g5-d4-node-evidence-1s.json),
and [exact matrix](k8s-infra/matrices/aks-three-stage-g5-d4-els3.json).

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
[Three-stage G5 runner-17 k6 HTML](docs/reports/aks-10k-three-stage-g5-d4-runner-17.html).
It was selected deterministically as the runner with the highest overall raw
p99 in the latest run:

- Run: `growth-20260726-164117-6c29992e-0491`
- Runner: 17 of 20
- Connections / formal samples: 500 / 5,000
- Raw average / p95 / p99 / max: 74.13 / 141.05 / 229 / 256 ms

After these changes reach `main`, the existing Pages workflow publishes it at
`https://featbit.github.io/featbit-load-testing/reports/aks-10k-three-stage-g5-d4-runner-17.html`.

Distributed k6 creates one HTML per runner, not a merged 10,000-connection
report. The HTML also retains the raw `FeatureFlag.UpdatedAt → SDK` metric.
Use the
[Three-stage G5 report](docs/reports/aks-10k-three-stage-g5-d4.md) and its
[machine-readable result](docs/reports/aks-10k-three-stage-g5-d4.json) for
canonical streaming latency and aggregate conclusions. Full artifact
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
