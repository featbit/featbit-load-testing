# AKS 500-client / single Environment / 3,000 flags official .NET SDK pilot

Status: **PASS**.

Run: `growth-f3k-dotnet-p500-v-20260728130543-8b66`

This is a 500-client pilot, not a replacement for the failed 10,000-client
capacity validation. It establishes a new lower-scale baseline for one
large-flagset Environment using the official .NET Server SDK.

No FeatBit source code, ELS source code, or FeatBit image was changed.

## Workload and resources

| Contract | Value |
| --- | --- |
| Environment | 1 |
| Flags | 3,000: 2,500 string + 500 JSON |
| JSON variation | 2,048 bytes |
| Official SDK | `FeatBit.ServerSdk` 1.2.11 |
| Clients | 500 |
| Runner topology | 20 Pods × 25 independent `FbClient` instances |
| Ramp | 20 clients/s for 25 seconds |
| Warm-up | one update + baseline restore, delivered to all 500 clients |
| Formal changes | 8 string + 2 JSON, 30 seconds apart |
| FeatBit nodes | 3 × `Standard_D4ds_v5` |
| Loadgen nodes | 10 × `Standard_D4ds_v5` |
| ELS | 3 Pods; request 1 CPU / 2Gi; limit 3 CPU / 8Gi |
| Runner, each | request 1 CPU / 2Gi; no CPU limit; memory limit 6Gi |
| ELS image | `docker.io/featbit/featbit-evaluation-server:5.4.4` |
| Runner image | `featbitloadtesting22793c56acr.azurecr.io/featbit-dotnet-sdk-loadtest@sha256:ee15206675396b2516d5e6b2f7c0a657a1a202ba526331263fb82ecfa07db817` |
| Controller image | `featbitloadtesting22793c56acr.azurecr.io/featbit-k6@sha256:1d4cdc7665ebaf3ec267aa7f938da0a5c768bdab9d00b3d8733e24c6e4fd9580` |

The ELS resource envelope was increased after the original 512Mi profile
produced `OutOfMemoryException` during this large full-sync workload. The
image remained `docker.io/featbit/featbit-evaluation-server:5.4.4`.

## Ramp and initial synchronization

All 500 clients used the public `FbClient.Initialized` boundary:

| Measurement | Result |
| --- | ---: |
| Ready at the configured 25-second ramp end | 498/500 |
| Backlog at ramp end | 2 |
| Last client ready | 25,057 ms after ramp start |
| Delay beyond the configured ramp | **57 ms** |
| Client-create schedule drift avg / p95 / p99 / max | 0.89 / 3 / 9.01 / 50 ms |
| SDK initialization avg / p50 / p90 / p95 / p99 / max | 181.57 / 161 / 265.10 / 314.05 / 472.09 / 514 ms |
| Canary clients enumerating exactly 3,000 flags | 20/20 |
| Create failures / ready timeouts / unhealthy transitions | 0 / 0 / 0 |

The 181.57 ms initialization average is measured from each client's scheduled
construction start, not from the beginning of the 25-second global ramp.
At 20 clients/s the initial-sync wave therefore stayed almost exactly on
schedule: only two clients crossed the ramp boundary, and both finished
within 57 ms.

The public SDK has no WebSocket-open callback. This report does not invent a
separate open-latency value.

During the ramp and initial-sync window, the three FeatBit nodes sent
4.628 GiB over `eth0`, with a highest one-second per-node rate of
1.067 Gbit/s. The loadgen nodes received 2.618 GiB, with a highest per-node
rate of 0.133 Gbit/s. There were 78 loadgen-side and 42 FeatBit-side TCP
retransmission counter increments, but zero packet drops or network error
counters. Together with the 57 ms final backlog, this does not support a
network-bandwidth bottleneck at 500 clients.

## Delivery gates

| Gate | Result |
| --- | ---: |
| Runner artifacts | 20/20 |
| Official SDK initialized | 500/500 |
| Warm-up connection coverage | 500/500 |
| Warm-up deliveries | 1,000/1,000 |
| Controller formal writes | 10/10 |
| Redis observer groups | 10/10 revisions × 10 observer nodes |
| Formal revision delivery | 5,000/5,000 |
| Revision sequence errors | 0 |
| Final revision correctness | 500/500 |
| Runner Job | 20/20 successful indexes; 0 failed |

`1,000/1,000` means **500 clients × two warm-up patches**: the warm-up
revision and its baseline restore. `5,000/5,000` means **500 clients × ten
formal revisions**.

## Three-stage propagation latency

The SDK value was observed through public `StringVariation` polling every
10 ms. SDK-side timestamps can therefore be 0–10 ms later than the SDK's
internal apply time.

### End to end: controller PUT start → SDK observation (ms)

Each revision contains 500 client observations.

| rev | type | avg | p50 | p90 | p95 | p99 | max |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| 01 | string | 31.34 | 24 | 32 | 132 | 148 | 266 |
| 02 | string | 30.08 | 24 | 29 | 30 | 249 | 270 |
| 03 | string | 28.46 | 22 | 29 | 40 | 210 | 231 |
| 04 | string | 29.01 | 25 | 33 | 108 | 159 | 159 |
| 05 | string | 27.40 | 24 | 32 | 54 | 54 | 221 |
| 06 | string | 25.71 | 24 | 28 | 30 | 222 | 310 |
| 07 | string | 23.67 | 22.50 | 31 | 34 | 34 | 38 |
| 08 | string | 24.13 | 24 | 28 | 33 | 33.04 | 37 |
| 09 | JSON | 27.98 | 25 | 29 | 33 | 207 | 232 |
| 10 | JSON | 34.44 | 31 | 38 | 38 | 212 | 251 |

### Redis observer → SDK observation (ms)

| rev | type | control plane | avg | p50 | p90 | p95 | p99 | max |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 01 | string | 17 | 14.34 | 7 | 15 | 115 | 131 | 249 |
| 02 | string | 18 | 12.08 | 6 | 11 | 12 | 231 | 252 |
| 03 | string | 17 | 11.46 | 5 | 12 | 23 | 193 | 214 |
| 04 | string | 18 | 11.01 | 7 | 15 | 90 | 141 | 141 |
| 05 | string | 19 | 8.40 | 5 | 13 | 35 | 35 | 202 |
| 06 | string | 18 | 7.71 | 6 | 10 | 12 | 204 | 292 |
| 07 | string | 19 | 4.67 | 3.50 | 12 | 15 | 15 | 19 |
| 08 | string | 18 | 6.13 | 6 | 10 | 15 | 15.04 | 19 |
| 09 | JSON | 20 | 7.98 | 5 | 9 | 13 | 187 | 212 |
| 10 | JSON | 26 | 8.44 | 5 | 12 | 12 | 186 | 225 |

### Combined result

| Metric (ms) | count | avg | p50 | p90 | p95 | p99 | max |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `end_to_end_latency_ms` | 5,000 | 28.22 | 24 | 32 | 34 | 186 | 310 |
| `control_plane_write_latency_ms` | 10 | 19.00 | 18 | 20.60 | 23.30 | 25.46 | 26 |
| `probe_sync_latency_ms` | 5,000 | 9.22 | 6 | 12 | 15 | 168 | 292 |

There were 107 raw negative `probe_sync_latency_ms` samples, with a minimum
of -2 ms. They were retained, not clipped, and remain inside the declared
10 ms cross-node clock/observer uncertainty.

### Auxiliary de-jittered view

The pre-existing diagnostic rule retains
`probe_sync_latency_ms <= 100 ms`. It is not an SLO or a PASS gate.

| Metric (ms) | retained | removed | avg | p50 | p90 | p95 | p99 | max |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `end_to_end_latency_ms` | 4,911 | 89 (1.78%) | 25.35 | 24 | 31 | 33 | 54 | 114 |
| `probe_sync_latency_ms` | 4,911 | 89 (1.78%) | 6.34 | 6 | 11 | 13 | 35 | 97 |

The complete 5,000-sample distributions above remain the primary result.

## Resource and one-second evidence

Five-second Kubernetes peaks:

| Scope | Peak CPU | Peak memory |
| --- | ---: | ---: |
| 20 .NET runner containers, aggregate | 3.509 CPU | 8.03 GiB |
| One runner container, maximum | 202m | 485.6 MiB |
| Three ELS containers, aggregate | 467m | 1.313 GiB |
| One ELS container, observed range | 114–212m | 408.7–481.7 MiB |
| Other FeatBit containers, aggregate | 65m | 419.3 MiB |
| Loadgen node pool, including support collectors | 8.600 CPU | 34.87 GiB |
| FeatBit node pool, including platform workloads | 1.457 CPU | 6.79 GiB |

The runner's one-second process telemetry observed a highest single-process
CPU value of 0.776 cores, a highest working set of 521.0 MiB, and 23 threads.
The Kubernetes resource monitor retained 67 samples with zero collection
errors.

| Window | Pool | CPU p99 / max | CPU pressure p99 / max | run queue p99 / max | softirq CPU p99 / max | retrans / drops |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: |
| Ramp + initial sync | loadgen | 53.81 / 54.21% | 24.01 / 31.36% | 8 / 14 | 0.99 / 0.99% | 78 / 0 |
| Ramp + initial sync | FeatBit | 36.09 / 43.17% | 19.43 / 20.30% | 13.40 / 35 | 2.97 / 3.23% | 42 / 0 |
| Formal revision windows | loadgen | 30.63 / 38.12% | 21.59 / 23.89% | 10.13 / 15 | 0.25 / 0.25% | 0 / 0 |
| Formal revision windows | FeatBit | 11.01 / 11.92% | 11.82 / 14.07% | 6.48 / 10 | 0.49 / 0.49% | 3 / 0 |

Exact pre/post cgroup snapshots matched the same three ELS Pod UIDs:
11,359 CPU periods, **0 throttled periods, 0 ms throttled time, and 0
restarts**. The time-windowed ELS logs contained 500 lines and zero
`OutOfMemoryException`, `DataSyncMessageHandler` error, fatal, or unhandled
exception matches.

## Conclusion and scope

- At 500 clients and 20/s, the 3,000-flag initial sync added only 57 ms beyond
  the configured ramp. This profile passed.
- The initial-sync phase was the heavier resource/network phase. Formal
  revisions used much less network and ELS CPU.
- The successful profile required a larger ELS memory envelope than the
  original 512Mi limit. It did not require any FeatBit code or image change.
- This result does not overturn the failed 10,000-client k6 capacity run and
  must not be described as a 10,000-client result. A higher official-SDK
  connection count needs a separate capacity ladder.
- It must not be compared as faster or slower with the earlier 10,000-client
  full-fan-out or 100-target multi-environment baselines: connection count,
  flag count, client implementation, ELS resource envelope, and fan-out all
  differ.

Reproduction:

- [official .NET runner](../../dotnet-sdk-runner/README.md)
- [exact matrix](../../k8s-infra/matrices/aks-single-environment-3k-flags-dotnet-sdk-p500-els-expanded.json)
- [AKS runbook](../../k8s-infra/README-AKS.md#118-official-net-sdk-500-client-pilot)
- [machine-readable report](aks-500-single-env-3k-flags-dotnet-sdk-pilot.json)

All failed attempts and the final successful run remain under the ignored
`results/` tree. No run was renamed from failure to success.
