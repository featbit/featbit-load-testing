# AKS 10k WebSocket p99 capacity matrix

- 状态：完整
- 主指标：Worst per-revision, per-runner probe_sync_latency_ms p99
- 门槛：每次运行的每个 revision、每个 runner p99 均小于 1000 ms
- 固定负载：10000 条 WebSocket，以 100/s 建连，10 revisions，3 次重复

## 组汇总

| 组 | runners × WS | ELS | 完成 | 最差 revision/runner p99 中位数（范围） | 全部通过 | ELS 聚合峰值 CPU 中位数 | ELS 聚合峰值内存中位数 |
|---|---:|---:|---:|---:|:---:|---:|---:|
| g1 | 20 × 500 | 6 pods / 3 nodes | 3/3 | 296.00 ms (207.01–299.00 ms) | 是 | 443.93m (424.56–539.61m) | 798.50 MiB (781.86–802.68 MiB) |
| g2 | 40 × 250 | 6 pods / 3 nodes | 3/3 | 233.00 ms (232.00–262.02 ms) | 是 | 382.48m (365.94–484.27m) | 793.08 MiB (774.30–834.14 MiB) |
| g3 | 20 × 500 | 12 pods / 3 nodes | 3/3 | 283.00 ms (245.00–286.00 ms) | 是 | 616.83m (523.72–683.11m) | 1,333.97 MiB (1,326.82–1,338.47 MiB) |
| g4 | 40 × 250 | 12 pods / 3 nodes | 3/3 | 309.00 ms (223.00–329.00 ms) | 是 | 642.52m (597.90–687.43m) | 1,344.36 MiB (1,335.00–1,350.84 MiB) |
| g5 | 20 × 500 | 3 pods / 3 nodes | 3/3 | 266.04 ms (226.01–327.00 ms) | 是 | 317.94m (306.73–389.74m) | 507.51 MiB (507.10–510.78 MiB) |

## 预注册组间比较

只有相对变化 < 10% 且绝对变化 < 50 ms，才判定为实际等价。

| 比较 | 参考中位数 | 候选中位数 | 差值 | 相对变化 | 实际等价 |
|---|---:|---:|---:|---:|:---:|
| runner sharding at ELS 6: p20 -> p40 | 296.00 ms | 233.00 ms | -63.00 ms | -21.28% | 否 |
| runner sharding at ELS 12: p20 -> p40 | 283.00 ms | 309.00 ms | +26.00 ms | +9.19% | 是 |
| ELS scaling at p20: 3 -> 6 | 266.04 ms | 296.00 ms | +29.96 ms | +11.26% | 否 |
| ELS scaling at p20: 6 -> 12 | 296.00 ms | 283.00 ms | -13.00 ms | -4.39% | 是 |
| ELS scaling at p40: 6 -> 12 | 233.00 ms | 309.00 ms | +76.00 ms | +32.62% | 否 |

## 容量结论边界

- p20 下通过门槛的最小 ELS 规模：3 pods。
- 同时在 p20 与 p40 分片下通过的最小已测 ELS 规模：6 pods。
- 本实验只验证 10,000 并行 WebSocket；不能据此宣称 10,000 以上的精确极限。
- 3 次重复用于观察稳定性和范围，不作统计显著性声明。

JSON evidence: [`aks-p99-capacity-10k-summary.json`](aks-p99-capacity-10k-summary.json)
