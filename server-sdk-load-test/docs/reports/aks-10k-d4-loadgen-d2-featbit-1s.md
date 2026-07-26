# AKS 10k：54-vCPU 配额内的 D4 loadgen 复核

## 结论

按 `1 × D2 system + 6 × D2 FeatBit + 10 × D4 loadgen = 54 vCPU` 重分配后，三轮全部完成并通过。三轮共 300,000 个正式传播样本、30,000 次满连接预热检查，threshold failure 为 0。

- 保守 p99 三轮中位数为 283.01 ms（252.00–299.01 ms）。
- 加权平均延迟中位数为 67.34 ms；`>100 ms` 样本中位占比为 10.789%。
- 最佳一轮是 `growth-20260725-130514-ce333a5f-1519`：保守 p99 252.00 ms，加权平均 66.62 ms，`>100 ms` 占 10.789%。
- 相较 10 × D2 loadgen 诊断轮，三轮中位保守 p99、平均延迟、`>100 ms` 占比和 loadgen CPU-pressure p99 分别变化 -40.92%、-39.52%、-79.70%、-61.94%。

## 固定拓扑与负载

| 项目 | 配置 |
| --- | --- |
| AKS vCPU | 54 / 65 quota |
| system | 1 × `Standard_D2ds_v5` |
| FeatBit | 6 × `Standard_D2ds_v5` |
| ELS | 6 Pods，严格一节点一 Pod；250m request / 1 CPU limit；256Mi request / 512Mi limit |
| loadgen | 10 × `Standard_D4ds_v5` |
| k6 | 20 runners × 500 WS；每节点 2 runners |
| runner resources | 500m CPU / 1Gi memory request；无 CPU limit，3Gi memory limit |
| 建连 | 10000 WS，100/s |
| flags | 预置 20；flag-02 满连接预热；只变更/测量 flag-01 |
| 正式变更 | 10 revisions，间隔 30s；共 3 次 |
| 采样 | Kubernetes 5s；16 个工作节点 host/ELS cgroup 约 1s |

## 正常结果（完整样本）

| Run | 加权平均 | 最差 revision/runner p95 | 保守 p99 | max | >100 ms 波峰 | 受影响 runner × revision | failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| run 1 | 67.34 ms | 291.05 ms | 299.01 ms | 302.00 ms | 10608 (10.608%) | 111 / 200 | 0 |
| run 2 | 77.09 ms | 278.00 ms | 283.01 ms | 285.00 ms | 20099 (20.099%) | 123 / 200 | 0 |
| run 3 | 66.62 ms | 247.00 ms | 252.00 ms | 257.00 ms | 10789 (10.789%) | 115 / 200 | 0 |

Run 2 的 revision 1 有 10,000 / 10,000 个样本超过 100 ms，因此该轮的 20.099% 不是少量离群点，而是一次完整广播波。所有数值仍低于预设的 p95 500 ms / p99 1000 ms gate。

## 去除 `>100 ms` 后的诊断视图

| Run | 删除样本 | 保留样本 | 保留后加权平均 | runner p95 范围 | runner p99 范围 |
| --- | ---: | ---: | ---: | ---: | ---: |
| run 1 | 10608 (10.608%) | 89392 | 60.02 ms | 91.00–97.00 ms | 96.00–100.00 ms |
| run 2 | 20099 (20.099%) | 79901 | 59.77 ms | 88.00–97.00 ms | 94.00–100.00 ms |
| run 3 | 10789 (10.789%) | 89211 | 59.25 ms | 88.00–97.00 ms | 98.00–100.00 ms |

> `>100 ms` 是运行前固定的诊断阈值。该表用于观察常见路径，不能替代完整结果、隐藏波峰或作为新的 SLO。

## 资源消耗

Kubernetes 峰值为同一 5 秒样本中的池级聚合值；host/cgroup 指标按约 1 秒采集。

| Run | ELS 聚合峰值 | runner 聚合峰值 | FeatBit nodes 聚合峰值 | loadgen nodes 聚合峰值 | loadgen CPU / pressure / run queue p99 | ELS CPU p99 / throttle rate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| run 1 | 400m / 894Mi | 1.05 CPU / 13.96Gi | 1.98 CPU / 10.53Gi | 3.22 CPU / 28.77Gi | 20.54% / 10.57% / 5.00 | 163.9m / 0.050% |
| run 2 | 468m / 877Mi | 3.12 CPU / 13.92Gi | 2.20 CPU / 10.85Gi | 2.94 CPU / 29.33Gi | 19.75% / 10.70% / 5.00 | 163.6m / 0.052% |
| run 3 | 470m / 874Mi | 1.72 CPU / 14.49Gi | 2.12 CPU / 11.08Gi | 3.11 CPU / 30.32Gi | 23.26% / 11.76% / 5.00 | 162.8m / 0.046% |

- 正式 revision 窗口合计 ELS throttled periods / TCP retrans / packet drops = 1 / 7 / 0。
- 三轮 ELS 1 秒 CPU p99 为 162.8–163.9m；没有接近单 Pod 1 CPU limit。
- D4 loadgen 的 CPU-pressure p99 为 10.57%–11.76%，明显低于 D2 诊断轮的 27.67%–28.33%。
- Run 1 的最差 revision 与池级 7 次 retrans 同窗，但最差 runner 所在节点自身记录为 0；三轮均无 packet drop，因此不能把该波峰归因于丢包。

## 对照边界

| 指标 | 10 × D2 loadgen | 当前 10 × D4 loadgen | 变化 |
| --- | ---: | ---: | ---: |
| 保守 p99 三轮中位数 | 479.00 ms | 283.01 ms | -40.92% |
| 加权平均三轮中位数 | 111.36 ms | 67.34 ms | -39.52% |
| >100 ms 中位占比 | 53.140% | 10.789% | -79.70% |
| loadgen CPU-pressure p99 中位数 | 28.10% | 10.70% | -61.94% |

与历史 g1（同为 20 × 500 与 D4 loadgen，但 6 ELS 分布在 3 个 D4 FeatBit nodes）相比，当前保守 p99 中位数为 283.01 ms vs 296.00 ms，差 -12.99 ms（-4.39%）。按矩阵预注册的 `<50 ms` 且 `<10%` 规则，两者实际等价：`True`。这是跨 campaign 比较，不是随机化单变量证明。

现有证据支持「D2 loadgen 是上一轮主要观测端污染源」；它不支持「剩余全部尾延迟都来自某一个 FeatBit 组件」。ELS 没有饱和，正式窗口几乎无 throttling/丢包，而剩余波峰仍会随 runner/广播批次变化。

## 复现与证据

- 实验定义：[`aks-10k-d4-loadgen-d2-featbit-1s.json`](../../k8s-infra/matrices/aks-10k-d4-loadgen-d2-featbit-1s.json)
- 基础设施：[`terraform/aks/terraform.tfvars.example`](../../k8s-infra/terraform/aks/terraform.tfvars.example)、[`featbit-aks-internal.yaml`](../../k8s-infra/values/featbit-aks-internal.yaml)
- 执行器：[`run-aks-capacity-matrix.ps1`](../../k8s-infra/scripts/run-aks-capacity-matrix.ps1)
- 单轮分析：[`analyze-aks-latency.ps1`](../../k8s-infra/scripts/analyze-aks-latency.ps1)、[`analyze-aks-1s-evidence.ps1`](../../k8s-infra/scripts/analyze-aks-1s-evidence.ps1)
- 本汇总：[`summarize-aks-quota-safe-d4-loadgen.ps1`](../../k8s-infra/scripts/summarize-aks-quota-safe-d4-loadgen.ps1)
- Machine-readable result：[`aks-10k-d4-loadgen-d2-featbit-1s.json`](aks-10k-d4-loadgen-d2-featbit-1s.json)

三轮 TestRun、runner JSON/HTML、完整/去波峰延迟报告、5 秒资源记录和 1 秒 TSV 均保留在本地 `results/<run-id>/`。本流程不会删除 TestRun、PVC、AKS 或数据库。