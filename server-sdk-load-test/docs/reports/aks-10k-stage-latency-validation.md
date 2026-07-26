# AKS 10k 三阶段传播延迟初步验证

本报告固化单轮 10,000 WebSocket 实验
`growth-20260725-152154-ce333a5f-bb94`。旧归档没有 Redis 发布边界，
无法精确反算三阶段延迟，因此本轮使用只读 Redis `SUBSCRIBE` observer
重新采集。

## 结论

- `probe_sync_latency_ms` 现在等同于
  `streaming_delivery_latency_ms`。
- `end_to_end_latency_ms = control_plane_write_latency_ms +
  probe_sync_latency_ms`。
- 旧指标 `FeatureFlag.UpdatedAt → SDK` 保留为
  `probe_updated_at_to_sdk_latency_ms`，仅用于兼容历史证据。
- FeatBit API、ELS 和其他 FeatBit 源码均未修改。

## 实验合同

| 项目 | 配置 |
| --- | --- |
| WebSocket | 10,000，100/s 建连 |
| k6 | 20 runners × 500 connections；10 × D4 loadgen nodes |
| ELS | 6 Pods；6 × D2 FeatBit nodes；严格一节点一 Pod |
| Flags | 20 个预置；flag-02 预热；只变更并测量 flag-01 |
| 正式变更 | 10 revisions，间隔 30 秒 |
| Observer | 10 Pods，10 个 loadgen nodes 各一个；取最早看到 Redis 发布的时间 |

## 三项延迟

分布式 k6 摘要无法精确合并全局 percentile，因此端到端和 streaming
的 p95/p99 展示 20 runners × 10 revisions cohorts 的 min–max 范围。
平均值、样本数和 min/max 是精确聚合值。

| 指标 | 口径 | 样本 | 平均 | min / max | p95 | p99 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `end_to_end_latency_ms` | controller 发起 PUT → SDK 应用变更 | 100,000 | 65.82 ms | 12 / 219 ms | 68.05–206 ms | 70.01–209.01 ms |
| `control_plane_write_latency_ms` | PUT 发起 → 最早 observer 看到 Redis 发布 | 10 | 16.20 ms | 14 / 22 ms | 21.10 ms | 21.82 ms |
| `probe_sync_latency_ms` | 最早 observer 看到 Redis 发布 → SDK 应用变更 | 100,000 | 49.62 ms | -2 / 203 ms | 53.05–190 ms | 55.01–193.01 ms |

原始 `updatedAt → SDK` 平均为 63.02 ms。按新边界，
canonical `probe_sync_latency_ms` 平均为 49.62 ms，减少 13.40 ms；
从 PUT 开始计算的控制面阶段平均为 16.20 ms。

## Revision 明细

| Revision | control-plane | streaming avg | streaming runner p95 | streaming runner p99 | end-to-end avg | observer 到达跨度 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 (`rev-001`) | 16 ms | 51.99 ms | 66–95 ms | 68–97 ms | 67.99 ms | 5 ms |
| 2 (`rev-002`) | 15 ms | 46.12 ms | 58–104 ms | 60–108 ms | 61.12 ms | 4 ms |
| 3 (`rev-003`) | 14 ms | 49.84 ms | 60–141 ms | 63–146 ms | 63.84 ms | 27 ms |
| 4 (`rev-004`) | 20 ms | 48.22 ms | 55–150 ms | 57–151 ms | 68.22 ms | 5 ms |
| 5 (`rev-005`) | 22 ms | 52.87 ms | 63–150 ms | 65–154 ms | 74.87 ms | 37 ms |
| 6 (`rev-006`) | 15 ms | 46.64 ms | 53.05–97 ms | 55.01–99 ms | 61.64 ms | 26 ms |
| 7 (`rev-007`) | 14 ms | 53.22 ms | 63–178 ms | 66–183.01 ms | 67.22 ms | 5 ms |
| 8 (`rev-008`) | 15 ms | 49.30 ms | 57–169 ms | 63–172 ms | 64.30 ms | 5 ms |
| 9 (`rev-009`) | 16 ms | 52.89 ms | 63–190 ms | 65–193.01 ms | 68.89 ms | 5 ms |
| 10 (`rev-010`) | 15 ms | 45.11 ms | 61–92 ms | 68–93 ms | 60.11 ms | 31 ms |

## 完整性与资源

- 20/20 runner thresholds 通过。
- 100,000 个正式样本、10,000 个满连接预热检查、10,000 条连接均通过。
- 10 次 controller start、10 次 end、0 次 error。
- 每个 observer 捕获 14 个事件；10 次正式 revision 共匹配 100 个节点事件。
- 167 个五秒资源样本完整，无采样错误。

| 资源 | 本轮峰值 |
| --- | ---: |
| 每个 timing observer | 0.98–1.14m CPU / 7.96–7.98 MB |
| 每个 ELS Pod | 73.96–80.64m CPU / 139.90–171.04 MB |
| 每个 k6 runner | 116.27–222.74m CPU / 805.74–890.48 MB |
| 每个 loadgen node | 336.79–383.49m CPU / 3.44–3.54 GB |
| 每个 FeatBit node | 351.31–407.35m CPU / 1.90–2.32 GB |
| API / PostgreSQL / Redis | 8.19m / 7.63m / 32.25m CPU |

Observer 资源相对负载很小，但它仍会给 Redis 增加 10 个订阅客户端。因此本报告
属于新口径的初步验证，不应把它与没有 observer 的历史容量轮次当成完全等价的重复。

## 测量限制

最早 subscriber 收到消息晚于 Redis 服务端真正执行 `PUBLISH` 的时刻，所以
`probe_sync_latency_ms` 可能被轻微低估。10 个 observer 的到达跨度 median 为
5 ms、p95 为 34.30 ms、max 为 37 ms，它混合了 subscriber 调度、网络路径和节点
时钟差异。

本轮出现 `-2 ms` 的最小值。这不是物理上的负延迟，而是毫秒取整、跨节点时钟和
旁路边界误差的直接证据。平均值与尾百分位可用于初步判断；低个位毫秒不能作精确归因。
若要获得严格的 Redis 服务端 `PUBLISH` 边界，需要额外采集 Redis 服务端时间并校准
各节点时钟。

## 复现入口

- [AKS 三阶段延迟步骤](../../k8s-infra/README-AKS.md#111-三阶段延迟验证)
- [实验矩阵](../../k8s-infra/matrices/aks-stage-latency-validation.json)
- [HTML 报告](aks-10k-stage-latency-validation.html)
- [机器可读摘要](aks-10k-stage-latency-validation.json)
