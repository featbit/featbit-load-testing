# growth-20260726-164117-6c29992e-0491 三阶段延迟验证

## 结论

- `probe_sync_latency_ms` 现在表示 `streaming_delivery_latency_ms`，起点是 10 个 loadgen observer 中最早看到 Redis 发布的时间，终点是 SDK 连接应用变更。
- `end_to_end_latency_ms = control_plane_write_latency_ms + probe_sync_latency_ms`。
- FeatBit API、ELS 与 FeatBit 源码均未修改；计时来自 load-test controller 日志和只读 Redis SUBSCRIBE observer。

## 三项延迟

| 指标 | 口径 | 样本 | 平均 | min / max | runner × revision p95 | runner × revision p99 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `end_to_end_latency_ms` | PUT 发起 → SDK 应用变更 | 100000 | 69.43 ms | 8.00 ms / 255.00 ms | 85.00 ms–239.00 ms | 87.01 ms–248.00 ms |
| `control_plane_write_latency_ms` | PUT 发起 → 10 个 observer 中最早看到 Redis 发布 | 10 | 9.60 ms | 7.00 ms / 13.00 ms | 12.10 ms | 12.82 ms |
| `probe_sync_latency_ms` | 最早 Redis 发布旁路可见 → SDK 应用变更 | 100000 | 59.83 ms | -1.00 ms / 244.00 ms | 77.00 ms–228.00 ms | 79.01 ms–237.00 ms |

## Revision 明细

| Revision | control-plane | streaming avg | streaming runner p95 | streaming runner p99 | end-to-end avg | Redis observer 到达跨度 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 (`rev-001`) | 10.00 ms | 50.43 ms | 77.05 ms–160.05 ms | 83.00 ms–165.00 ms | 60.43 ms | 9.00 ms |
| 2 (`rev-002`) | 11.00 ms | 71.87 ms | 92.00 ms–228.00 ms | 93.00 ms–237.00 ms | 82.87 ms | 7.00 ms |
| 3 (`rev-003`) | 9.00 ms | 57.32 ms | 82.00 ms–123.05 ms | 87.01 ms–128.00 ms | 66.32 ms | 6.00 ms |
| 4 (`rev-004`) | 7.00 ms | 67.58 ms | 87.00 ms–133.00 ms | 89.00 ms–135.01 ms | 74.58 ms | 7.00 ms |
| 5 (`rev-005`) | 11.00 ms | 49.02 ms | 79.00 ms–118.05 ms | 86.00 ms–121.00 ms | 60.02 ms | 6.00 ms |
| 6 (`rev-006`) | 8.00 ms | 54.39 ms | 77.00 ms–124.00 ms | 79.01 ms–126.00 ms | 62.39 ms | 7.00 ms |
| 7 (`rev-007`) | 8.00 ms | 69.06 ms | 86.00 ms–146.00 ms | 102.01 ms–148.00 ms | 77.06 ms | 8.00 ms |
| 8 (`rev-008`) | 13.00 ms | 50.94 ms | 81.05 ms–99.00 ms | 100.00 ms–109.00 ms | 63.94 ms | 7.00 ms |
| 9 (`rev-009`) | 9.00 ms | 61.77 ms | 81.00 ms–177.00 ms | 85.00 ms–184.01 ms | 70.77 ms | 8.00 ms |
| 10 (`rev-010`) | 10.00 ms | 65.96 ms | 84.00 ms–126.00 ms | 87.00 ms–128.00 ms | 75.96 ms | 7.00 ms |

## 测量边界与误差

- observer：10 Pods / 10 loadgen nodes，共匹配 100 条正式事件。
- 每次发布在各节点 observer 的到达时间跨度：median 7.00 ms，p95 8.55 ms，max 9.00 ms。它同时包含节点时钟偏差和 Redis→observer 网络差异，是本方法的保守不确定性提示。
- `probe_sync_latency_ms` 按 runner × revision cohort 的趋势整体平移；count、avg、min/max 以及每个 runner 的 percentile 平移是精确的。分布式 runner 之间无法仅靠摘要精确合并全局 percentile，因此报告展示 runner 范围。
- 最早 observer 收到消息仍比 Redis 服务端执行 PUBLISH 晚一个很小的网络/调度间隔，所以该值可能轻微低估真正的 Redis PUBLISH→SDK 延迟。
- 该算法假设 AKS 节点时钟已由平台同步；observer 到达跨度作为时钟偏差与订阅调度差异的合并不确定性提示。
- 本轮最小值为 -2 ms，不是物理上的负延迟，而是毫秒取整、跨节点时钟与旁路边界误差的直接证据。因此本轮用于初步验证拆分口径；平均值和尾百分位可读，亚毫秒/低个位毫秒不能作精确归因。

