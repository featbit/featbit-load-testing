# AKS 10k：ELS × loadgen sentinel 判别实验

## 结论

三轮均完整：主负载 300,000 个 canonical streaming 样本，direct sentinel 5400 个正式事件，threshold failure 为 0。

预注册的 30 个 revision 中，ELS column wave = 0、loadgen row wave = 3、global wave = 0。主 runner p99 超过 100 ms 的 revision 有 28 个，但 direct matrix 只有 45 / 1800 个 cell 超过 100 ms。

三轮出现 3 次预注册 loadgen-row，其中 1 次在同节点 observer 敏感性分析后仍成立；没有 ELS-column 或 global wave。接收端 loadgen node/VM、kernel network wake-up 或其上的进程调度是已证实的尾延迟贡献者，跨节点时钟偏移不能解释全部现象；其余没有形成 row 的主 runner 尾峰仍不能精确归到单个实现组件。

## 固定拓扑与口径

| 项目 | 配置 |
| --- | --- |
| 主负载 | 10,000 WebSockets；20 runners × 500；100/s |
| ELS | 6 Pods；6 × D2 FeatBit nodes；严格一节点一 Pod |
| loadgen | 10 × D4 nodes；每节点两个主 runner |
| direct sentinel | 每个 loadgen node 到每个 ELS Pod 3 条连接；共 180 |
| 正式变更 | 10 revisions；只变更 flag-01；flag-02 满连接预热 |
| 重复 | 3 个 fresh runs，每轮冷重启并重新固定 ELS placement |
| cell spike | 3 条连接的中位数 >100 ms |
| row / column / global | ≥4/6 columns；≥7/10 rows；≥30/60 cells |

## 三轮完整结果

| Run | 主 streaming avg | 主最差 p95 / p99 | 主 max | control avg | sentinel avg / earliest p99 / node-local p99 | 主波峰 revisions | spike cells | failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| run 1 | 54.67 ms | 183.00 ms / 187.00 ms | 188.00 ms | 16.10 ms | 52.15 ms / 104.00 ms / 100.00 ms | 8/10 | 8/600 | 0 |
| run 2 | 55.50 ms | 210.00 ms / 218.00 ms | 219.00 ms | 16.30 ms | 54.51 ms / 108.02 ms / 104.00 ms | 10/10 | 14/600 | 0 |
| run 3 | 54.09 ms | 165.00 ms / 168.00 ms | 170.00 ms | 15.80 ms | 53.59 ms / 119.01 ms / 110.01 ms | 10/10 | 23/600 | 0 |

三轮主 streaming average 中位数为 54.675 ms (54.085–55.503 ms)；主 runner × revision 最差 p99 中位数为 187 ms (168–218 ms)。sentinel p99 中位数为 108.02 ms (104–119.01 ms)。

## 预注册分类

| Run | stable | main-runners-only | isolated-cells | loadgen-row | els-column | global / mixed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| run 1 | 2 | 4 | 4 | 0 | 0 | 0 |
| run 2 | 0 | 6 | 4 | 0 | 0 | 0 |
| run 3 | 0 | 4 | 3 | 3 | 0 | 0 |

### Node-local observer sensitivity

The primary classification keeps the pre-registered earliest-observer boundary. The node-local view subtracts the Redis observer on the same receiver node, removing its 0–10 ms cross-node clock/observer offset.

| Run | Primary slow cells | Primary rows | Node-local slow cells | Node-local rows | Node-local ELS columns / global |
| --- | ---: | ---: | ---: | ---: | ---: |
| run 1 | 8/600 | 0 | 2/600 | 0 | 0 / 0 |
| run 2 | 14/600 | 0 | 10/600 | 0 | 0 / 0 |
| run 3 | 23/600 | 3 | 14/600 | 1 | 0 / 0 |

### Detected loadgen rows

| Run / revision | loadgen node | primary → node-local targets | observer offset | colocated main runner raw / node-local p99 | sentinel p99 | node CPU / pressure / run queue |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| run 3 / rev 2 | `aks-loadgen-10501918-vmss000006` | 5/6 → 0/6 | 3 ms | r6 111.00 ms / 98.00 ms; r16 139.00 ms / 126.00 ms | 145.42 ms | 29.88% / 19.65% / 2 |
| run 3 / rev 8 | `aks-loadgen-10501918-vmss000003` | 6/6 → 6/6 | 10 ms | r4 124.00 ms / 104.00 ms; r14 123.02 ms / 103.02 ms | 121.00 ms | 16.51% / 11.98% / 2 |
| run 3 / rev 9 | `aks-loadgen-10501918-vmss000003` | 4/6 → 0/6 | 10 ms | r4 126.00 ms / 102.00 ms; r14 132.01 ms / 108.01 ms | 117.00 ms | 16.38% / 15.09% / 1 |

Colocated runner values show raw `FeatureFlag.UpdatedAt → SDK` followed by same-node observer → SDK p99. Every detected row recorded zero packet drop and zero retransmission in its one-second window.

## 本实验的资源消耗

以下资源只属于这三轮 sentinel 实验；不能与前面实验的资源表混用。host/cgroup 约 1 秒采样，Kubernetes 约 5 秒采样。

| Run | loadgen CPU / pressure / run queue p99 | ELS CPU p99 / max | ELS throttle rate / time | revision retrans / drops / throttle | runner / sentinel 聚合峰值内存 |
| --- | ---: | ---: | ---: | ---: | ---: |
| run 1 | 21.00% / 13.32% / 5.00 | 153.7m / 391m | 0.0313% / 69.10 ms | 6 / 0 / 0 | 18.08 GiB / 0.43 GiB |
| run 2 | 21.95% / 14.55% / 5.00 | 145.9m / 438m | 0.0271% / 122.99 ms | 6 / 0 / 0 | 17.89 GiB / 0.5 GiB |
| run 3 | 22.94% / 14.86% / 6.00 | 152m / 466.5m | 0.0208% / 109.90 ms | 0 / 0 / 0 | 17.9 GiB / 0.52 GiB |

## 判读边界

- 没有 ELS column wave：不支持“某个 ELS Pod/其所在节点整体变慢”。
- 预注册口径检测到 3 次 loadgen row wave，其中 1 次在同节点 observer 边界下仍成立；跨节点时钟/observer 偏移影响了阈值附近的两次，但不能解释全部现象。
- 没有 global wave：不支持“Redis publication 或集群共享事件让所有直连同时变慢”。
- 主 runner 仍有尾峰而 direct sentinels 大体稳定，说明剩余抖动更接近主连接 cohort、k6 receive loop/runner 进程内调度，或尚未被 direct sentinel 完全复现的 Service-selected 长连接路径。
- 少量 isolated cells 说明单连接/小 cohort 抖动确实存在；它们不足以归因到整个 ELS Pod 或整个 loadgen node。
- 该结果定位的是层级，不是 FeatBit 源码中的具体函数。没有修改任何 FeatBit 源码。

## 复现与证据

- 实验定义：[`aks-els-loadgen-sentinel.json`](../../k8s-infra/matrices/aks-els-loadgen-sentinel.json)
- 执行器：[`run-aks-capacity-matrix.ps1`](../../k8s-infra/scripts/run-aks-capacity-matrix.ps1)
- sentinel 分析：[`analyze-aks-sentinel-matrix.ps1`](../../k8s-infra/scripts/analyze-aks-sentinel-matrix.ps1)
- 三阶段分析：[`analyze-aks-stage-latency.ps1`](../../k8s-infra/scripts/analyze-aks-stage-latency.ps1)
- 1 秒证据：[`analyze-aks-1s-evidence.ps1`](../../k8s-infra/scripts/analyze-aks-1s-evidence.ps1)
- 本汇总：[`summarize-aks-sentinel-experiment.mjs`](../../k8s-infra/scripts/summarize-aks-sentinel-experiment.mjs)
- Machine-readable result：[`aks-10k-els-loadgen-sentinel.json`](aks-10k-els-loadgen-sentinel.json)

三轮 TestRun、20 份 runner JSON/HTML、sentinel raw logs、三阶段 timing、5 秒资源记录和 1 秒 TSV 均保留在本地 `results/<run-id>/`。本流程不会删除 TestRun、PVC、AKS 或数据库。

