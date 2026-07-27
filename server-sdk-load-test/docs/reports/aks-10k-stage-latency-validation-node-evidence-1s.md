# growth-20260725-152154-ce333a5f-bb94：1 秒节点与 ELS 证据

## 证据口径

- 16 个节点文件，14475 个相邻采样区间。
- 实际区间 p50/p95/max：1.02s / 1.06s / 1.14s。
- Revision 窗口为 controller apply 日志前 1 秒至后 2.25 秒。
- runner cohort 关联指标：`probe_updated_at_to_sdk_latency_ms`；canonical streaming 延迟以同轮三阶段报告为准。
- 1 秒差分可发现持续的调度、网络、pressure 和 throttling；亚秒微突发可能被稀释。

## 全程主机指标

| Pool | Nodes | CPU p95 / p99 / max | CPU pressure p99 / max | run queue p99 / max | steal max | TCP retrans | packet drops |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| loadgen | 10 | 13.16% / 22.00% / 96.93% | 12.501% / 86.164% | 5.00 / 50.00 | 0.000% | 13 | 0 |
| featbit | 6 | 23.50% / 31.52% / 67.18% | 21.083% / 48.643% | 7.97 / 26.00 | 0.000% | 11 | 0 |

## ELS cgroup

| Pods | CPU p95 / p99 / max | CPU pressure p99 / max | throttled periods | throttled interval | throttled time |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 6 | 68.05m / 159.29m / 396.14m | 2.865% / 7.545% | 29/46640 (0.062%) | 24/5404 | 113.42 ms |

## Revision 窗口

| Rev | worst runner p99 | max | loadgen CPU max | pressure max | run queue max | retrans | drops | ELS CPU max | throttled periods | throttle time |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 111.00 ms | 111.00 ms | 30.58% | 18.653% | 2.00 | 0 | 0 | 164.10m | 0 | 0.00 ms |
| 2 | 120.00 ms | 121.00 ms | 32.84% | 19.099% | 6.00 | 0 | 0 | 96.71m | 0 | 0.00 ms |
| 3 | 158.00 ms | 159.00 ms | 29.70% | 16.033% | 50.00 | 0 | 0 | 88.11m | 0 | 0.00 ms |
| 4 | 168.00 ms | 168.00 ms | 28.11% | 17.486% | 5.00 | 0 | 0 | 95.89m | 0 | 0.00 ms |
| 5 | 171.00 ms | 171.00 ms | 36.95% | 23.939% | 4.00 | 0 | 0 | 84.21m | 0 | 0.00 ms |
| 6 | 110.00 ms | 110.00 ms | 30.85% | 14.898% | 3.00 | 0 | 0 | 105.04m | 0 | 0.00 ms |
| 7 | 195.01 ms | 198.00 ms | 28.57% | 12.312% | 5.00 | 0 | 0 | 111.10m | 0 | 0.00 ms |
| 8 | 185.00 ms | 185.00 ms | 28.25% | 11.240% | 8.00 | 0 | 0 | 114.72m | 0 | 0.00 ms |
| 9 | 207.01 ms | 217.00 ms | 37.66% | 31.547% | 2.00 | 0 | 0 | 134.58m | 0 | 0.00 ms |
| 10 | 105.00 ms | 105.00 ms | 19.70% | 13.984% | 10.00 | 0 | 0 | 101.94m | 0 | 0.00 ms |

## 最差 runner × revision

| Runner | Node | Rev | p95 | p99 | max | node CPU max | pressure max | run queue max | retrans | ELS throttled periods |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 19 | aks-loadgen-10501918-vmss000004 | 9 | 199.00 ms | 207.01 ms | 211.00 ms | 37.66% | 31.547% | 1.00 | 0 | 0 |
| 6 | aks-loadgen-10501918-vmss000003 | 9 | 204.00 ms | 206.00 ms | 207.00 ms | 26.50% | 11.671% | 2.00 | 0 | 0 |
| 1 | aks-loadgen-10501918-vmss000005 | 7 | 190.00 ms | 195.01 ms | 198.00 ms | 27.09% | 12.312% | 2.00 | 0 | 0 |
| 8 | aks-loadgen-10501918-vmss000004 | 9 | 101.00 ms | 185.01 ms | 217.00 ms | 37.66% | 31.547% | 1.00 | 0 | 0 |
| 2 | aks-loadgen-10501918-vmss000002 | 7 | 181.00 ms | 185.00 ms | 186.00 ms | 28.57% | 10.237% | 5.00 | 0 | 0 |
| 15 | aks-loadgen-10501918-vmss000001 | 8 | 182.00 ms | 185.00 ms | 185.00 ms | 28.25% | 8.830% | 1.00 | 0 | 0 |
| 4 | aks-loadgen-10501918-vmss000000 | 9 | 173.05 ms | 177.01 ms | 180.00 ms | 32.12% | 17.222% | 1.00 | 0 | 0 |
| 4 | aks-loadgen-10501918-vmss000000 | 5 | 167.00 ms | 171.00 ms | 171.00 ms | 36.95% | 23.939% | 1.00 | 0 | 0 |
| 17 | aks-loadgen-10501918-vmss000008 | 4 | 167.00 ms | 168.00 ms | 168.00 ms | 28.11% | 16.327% | 5.00 | 0 | 0 |
| 19 | aks-loadgen-10501918-vmss000004 | 3 | 153.00 ms | 158.00 ms | 159.00 ms | 26.17% | 16.033% | 2.00 | 0 | 0 |
| 8 | aks-loadgen-10501918-vmss000004 | 3 | 140.00 ms | 144.00 ms | 145.00 ms | 26.17% | 16.033% | 2.00 | 0 | 0 |
| 15 | aks-loadgen-10501918-vmss000001 | 4 | 140.00 ms | 143.01 ms | 144.00 ms | 26.68% | 10.825% | 1.00 | 0 | 0 |
| 1 | aks-loadgen-10501918-vmss000005 | 3 | 138.05 ms | 141.00 ms | 142.00 ms | 29.70% | 10.567% | 2.00 | 0 | 0 |
| 14 | aks-loadgen-10501918-vmss000000 | 4 | 128.00 ms | 135.00 ms | 139.00 ms | 21.14% | 17.486% | 4.00 | 0 | 0 |
| 2 | aks-loadgen-10501918-vmss000002 | 3 | 129.00 ms | 133.00 ms | 134.00 ms | 24.88% | 10.404% | 1.00 | 0 | 0 |
| 18 | aks-loadgen-10501918-vmss000006 | 5 | 118.00 ms | 122.00 ms | 124.00 ms | 23.27% | 13.361% | 3.00 | 0 | 0 |
| 14 | aks-loadgen-10501918-vmss000000 | 5 | 118.05 ms | 121.00 ms | 125.00 ms | 36.95% | 23.939% | 1.00 | 0 | 0 |
| 12 | aks-loadgen-10501918-vmss000009 | 2 | 116.00 ms | 120.00 ms | 121.00 ms | 26.49% | 11.478% | 6.00 | 0 | 0 |
| 20 | aks-loadgen-10501918-vmss000007 | 7 | 119.00 ms | 120.00 ms | 120.00 ms | 14.08% | 10.984% | 1.00 | 0 | 0 |
| 9 | aks-loadgen-10501918-vmss000008 | 5 | 112.00 ms | 115.00 ms | 115.00 ms | 13.60% | 12.813% | 1.00 | 0 | 0 |

## 相关性（探索性）

Pearson r 只用于寻找后续方向；同节点两个 runner 会共享同一节点窗口，因此不作为因果证明。

| 1 秒窗口指标 | 与 runner/revision p99 的 r |
| --- | ---: |
| loadgenCpuMaximumPercent | 0.51 |
| loadgenStealMaximumPercent | n/a |
| loadgenCpuPressureMaximumPercent | 0.47 |
| loadgenRunQueueMaximum | -0.01 |
| loadgenNetRxSoftirqMaximumPerSecond | -0.08 |
| loadgenTcpRetransSegments | n/a |
| elsCpuMaximumMillicores | 0.06 |
| elsThrottledPeriods | n/a |
| elsCpuPressureMaximumPercent | 0.09 |
| featbitNodeCpuMaximumPercent | -0.08 |
| featbitNodeRunQueueMaximum | -0.10 |

Machine-readable evidence: `C:\Code\featbit\featbit-load-testing\server-sdk-load-test\results\growth-20260725-152154-ce333a5f-bb94\growth-20260725-152154-ce333a5f-bb94-node-evidence-1s.json`