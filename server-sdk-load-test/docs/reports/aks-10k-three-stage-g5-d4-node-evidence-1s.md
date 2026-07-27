# growth-20260726-164117-6c29992e-0491：1 秒节点与 ELS 证据

## 证据口径

- 13 个节点文件，11957 个相邻采样区间。
- 实际区间 p50/p95/max：1.02s / 1.07s / 1.38s。
- Revision 窗口为 controller apply 日志前 1 秒至后 2.25 秒。
- runner cohort 关联指标：`probe_updated_at_to_sdk_latency_ms`；canonical streaming 延迟以同轮三阶段报告为准。
- 1 秒差分可发现持续的调度、网络、pressure 和 throttling；亚秒微突发可能被稀释。

## 全程主机指标

| Pool | Nodes | CPU p95 / p99 / max | CPU pressure p99 / max | run queue p99 / max | steal max | TCP retrans | packet drops |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| loadgen | 10 | 14.39% / 25.30% / 98.83% | 14.636% / 97.289% | 5.00 / 36.00 | 0.000% | 28 | 0 |
| featbit | 3 | 13.44% / 17.71% / 33.17% | 14.766% / 426.035% | 4.00 / 23.00 | 0.000% | 7 | 0 |

## ELS cgroup

| Pods | CPU p95 / p99 / max | CPU pressure p99 / max | throttled periods | throttled interval | throttled time |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | 114.68m / 190.88m / 419.31m | 0.810% / 6.986% | 29/23461 (0.124%) | 22/2756 | 639.09 ms |

## Revision 窗口

| Rev | worst runner p99 | max | loadgen CPU max | pressure max | run queue max | retrans | drops | ELS CPU max | throttled periods | throttle time |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 177.00 ms | 178.00 ms | 28.54% | 21.240% | 5.00 | 0 | 0 | 141.54m | 0 | 0.00 ms |
| 2 | 249.00 ms | 256.00 ms | 43.07% | 36.141% | 2.00 | 0 | 0 | 140.41m | 0 | 0.00 ms |
| 3 | 139.00 ms | 139.00 ms | 38.59% | 33.790% | 5.00 | 0 | 0 | 153.04m | 0 | 0.00 ms |
| 4 | 144.01 ms | 145.00 ms | 21.26% | 19.759% | 9.00 | 0 | 0 | 129.93m | 0 | 0.00 ms |
| 5 | 133.00 ms | 136.00 ms | 25.62% | 18.991% | 13.00 | 0 | 0 | 135.81m | 1 | 26.37 ms |
| 6 | 136.00 ms | 136.00 ms | 39.51% | 16.030% | 12.00 | 0 | 0 | 136.12m | 0 | 0.00 ms |
| 7 | 158.00 ms | 158.00 ms | 24.26% | 20.933% | 3.00 | 0 | 0 | 148.13m | 0 | 0.00 ms |
| 8 | 122.00 ms | 123.00 ms | 20.64% | 14.366% | 5.00 | 6 | 0 | 147.89m | 2 | 60.67 ms |
| 9 | 194.01 ms | 198.00 ms | 35.98% | 33.898% | 6.00 | 0 | 0 | 152.66m | 1 | 24.05 ms |
| 10 | 139.00 ms | 140.00 ms | 38.56% | 16.817% | 11.00 | 0 | 0 | 137.59m | 0 | 0.00 ms |

## 最差 runner × revision

| Runner | Node | Rev | p95 | p99 | max | node CPU max | pressure max | run queue max | retrans | ELS throttled periods |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 17 | aks-loadgen-10501918-vmss000005 | 2 | 240.00 ms | 249.00 ms | 256.00 ms | 43.07% | 36.141% | 1.00 | 0 | 0 |
| 9 | aks-loadgen-10501918-vmss000003 | 9 | 187.00 ms | 194.01 ms | 198.00 ms | 35.98% | 33.898% | 1.00 | 0 | 1 |
| 6 | aks-loadgen-10501918-vmss000002 | 9 | 177.00 ms | 179.01 ms | 180.00 ms | 32.75% | 20.545% | 3.00 | 0 | 1 |
| 2 | aks-loadgen-10501918-vmss000008 | 1 | 172.05 ms | 177.00 ms | 178.00 ms | 28.54% | 21.240% | 5.00 | 0 | 0 |
| 14 | aks-loadgen-10501918-vmss000004 | 9 | 172.00 ms | 176.00 ms | 177.00 ms | 31.13% | 15.101% | 1.00 | 0 | 1 |
| 13 | aks-loadgen-10501918-vmss000006 | 9 | 163.05 ms | 170.00 ms | 172.00 ms | 27.93% | 15.985% | 6.00 | 0 | 1 |
| 18 | aks-loadgen-10501918-vmss000000 | 2 | 160.00 ms | 164.00 ms | 165.00 ms | 29.63% | 11.633% | 2.00 | 0 | 0 |
| 15 | aks-loadgen-10501918-vmss00000a | 7 | 156.00 ms | 158.00 ms | 158.00 ms | 23.28% | 20.933% | 2.00 | 0 | 0 |
| 7 | aks-loadgen-10501918-vmss000005 | 2 | 142.05 ms | 154.01 ms | 158.00 ms | 43.07% | 36.141% | 1.00 | 0 | 0 |
| 19 | aks-loadgen-10501918-vmss000003 | 9 | 141.05 ms | 154.00 ms | 156.00 ms | 35.98% | 33.898% | 1.00 | 0 | 1 |
| 2 | aks-loadgen-10501918-vmss000008 | 9 | 146.00 ms | 150.00 ms | 151.00 ms | 30.39% | 10.496% | 2.00 | 0 | 1 |
| 15 | aks-loadgen-10501918-vmss00000a | 4 | 142.00 ms | 144.01 ms | 145.00 ms | 19.81% | 19.759% | 1.00 | 0 | 0 |
| 5 | aks-loadgen-10501918-vmss00000a | 9 | 134.00 ms | 143.00 ms | 144.00 ms | 35.63% | 18.516% | 4.00 | 0 | 1 |
| 20 | aks-loadgen-10501918-vmss000007 | 10 | 137.00 ms | 139.00 ms | 140.00 ms | 17.87% | 13.404% | 2.00 | 0 | 0 |
| 5 | aks-loadgen-10501918-vmss00000a | 3 | 134.05 ms | 139.00 ms | 139.00 ms | 38.59% | 33.790% | 5.00 | 0 | 0 |
| 5 | aks-loadgen-10501918-vmss00000a | 6 | 134.00 ms | 136.00 ms | 136.00 ms | 20.43% | 14.859% | 2.00 | 0 | 0 |
| 10 | aks-loadgen-10501918-vmss000007 | 10 | 132.00 ms | 135.00 ms | 138.00 ms | 17.87% | 13.404% | 2.00 | 0 | 0 |
| 5 | aks-loadgen-10501918-vmss00000a | 5 | 130.05 ms | 133.00 ms | 136.00 ms | 20.94% | 18.991% | 3.00 | 0 | 1 |
| 5 | aks-loadgen-10501918-vmss00000a | 4 | 128.00 ms | 131.00 ms | 134.00 ms | 19.81% | 19.759% | 1.00 | 0 | 0 |
| 6 | aks-loadgen-10501918-vmss000002 | 10 | 129.00 ms | 131.00 ms | 131.00 ms | 16.19% | 16.817% | 2.00 | 0 | 0 |

## 相关性（探索性）

Pearson r 只用于寻找后续方向；同节点两个 runner 会共享同一节点窗口，因此不作为因果证明。

| 1 秒窗口指标 | 与 runner/revision p99 的 r |
| --- | ---: |
| loadgenCpuMaximumPercent | 0.51 |
| loadgenStealMaximumPercent | n/a |
| loadgenCpuPressureMaximumPercent | 0.60 |
| loadgenRunQueueMaximum | 0.04 |
| loadgenNetRxSoftirqMaximumPerSecond | -0.07 |
| loadgenTcpRetransSegments | 0.04 |
| elsCpuMaximumMillicores | 0.15 |
| elsThrottledPeriods | 0.06 |
| elsCpuPressureMaximumPercent | 0.02 |
| featbitNodeCpuMaximumPercent | -0.18 |
| featbitNodeRunQueueMaximum | -0.18 |

Machine-readable evidence: `C:\Code\featbit\featbit-load-testing\server-sdk-load-test\results\growth-20260726-164117-6c29992e-0491\growth-20260726-164117-6c29992e-0491-node-evidence-1s.json`