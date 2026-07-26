# AKS 10k：D2 loadgen 与 ELS 单节点隔离实验

## 结论

本轮在现有配额内完成资源重分配并跑满三次，但 **D2 loadgen 不能替代先前 D4 参考拓扑来判断 FeatBit 容量**。三轮共 300,000 个正式传播样本全部收到；第三轮有 1 个 runner × revision 的 p95 超过 500 ms，其余连接、revision、最终状态和生存检查完整。

- 保守 p99 三轮中位数为 479 ms（409.01–567.03 ms）。
- 加权平均延迟中位数为 111.36 ms；`>100 ms` 样本中位占比为 53.14%。
- D2 节点 CPU p99 只有 44.7%–52.14%，但 CPU pressure p99 稳定在 27.67%–28.33%，说明平均 CPU 掩盖了短时调度等待。
- 正式 revision 窗口合计 ELS throttled periods / TCP retrans / packet drops 为 0 / 2 / 0。

## 固定拓扑与负载

| 项目 | 配置 |
| --- | --- |
| AKS vCPU | 46（无需提高本轮配额） |
| system | 1 × `Standard_D2ds_v5` |
| FeatBit | 6 × `Standard_D4ds_v5` |
| ELS | 6 Pods，严格每节点 1 Pod，500m request / 1 CPU limit，256Mi request / 512Mi limit |
| loadgen | 10 × `Standard_D2ds_v5` |
| k6 | 20 runners × 500 WS；每个 loadgen node 2 runners |
| 建连 | 10,000 WS，100/s |
| flags | 预置 20；flag-02 满连接预热；只变更/测量 flag-01 |
| 正式变更 | 10 revisions，间隔 30s；每种配置 3 次 |
| 采样 | Kubernetes 5s；16 个工作节点 host/ELS cgroup 实测 p50 1.01s、p95 1.06s |

## 正常结果（不删除样本）

| Run | 加权平均 | 最差 revision/runner p95 | 保守 p99 | max | >100 ms | threshold failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `growth-20260725-090612-ce333a5f-5f07` | 111.36 ms | 476.00 ms | 479.00 ms | 481.00 ms | 53140 (53.140%) | 0 |
| `growth-20260725-092858-ce333a5f-58fd` | 113.29 ms | 400.00 ms | 409.01 ms | 412.00 ms | 55411 (55.411%) | 0 |
| `growth-20260725-095136-ce333a5f-576e` | 109.38 ms | 562.00 ms | 567.03 ms | 571.00 ms | 52503 (52.503%) | 1 |

三轮中最低保守 p99 是 run 2 的 409.01 ms；它是「本拓扑最好一次」，不是替代三轮稳定性统计。

第三轮唯一 threshold failure 来自 runner 18 / revision 9：p95/p99/max = 562/567.03/571 ms。该节点上的另一个 runner 同一 revision p99 也约 460 ms；窗口 CPU/pressure 约 71.3%/51.2%，且 ELS throttling、重传、丢包均为 0。

## 去除 `>100 ms` 后的诊断视图

| Run | 删除样本 | 保留样本 | 保留后加权平均 | runner p95 范围 | runner p99 范围 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `growth-20260725-090612-ce333a5f-5f07` | 53140 (53.140%) | 46860 | 58.19 ms | 95.00–97.00 ms | 99.00–100.00 ms |
| `growth-20260725-092858-ce333a5f-58fd` | 55411 (55.411%) | 44589 | 59.43 ms | 96.00–97.00 ms | 99.00–100.00 ms |
| `growth-20260725-095136-ce333a5f-576e` | 52503 (52.503%) | 47497 | 57.50 ms | 96.00–97.00 ms | 99.00–100.00 ms |

> 本轮 `>100 ms` 占 52.503%–55.411%，已经不是「偶发波峰」。这个视图只回答剩余样本的形状，不能作为去抖后的真实性能或 SLO。

## 资源消耗

5 秒 Kubernetes 峰值是同一时刻的聚合值；1 秒 host 指标是各节点秒级分布。

| Run | ELS 聚合峰值 | runner 聚合峰值 | FeatBit nodes 聚合峰值 | loadgen nodes 聚合峰值 | D2 CPU p99 / pressure p99 / run queue p99 | ELS cgroup CPU p99 / throttle rate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| run 1 | 445m / 781Mi | 2.65 CPU / 13.59Gi | 2.00 CPU / 10.74Gi | 3.11 CPU / 30.03Gi | 44.70% / 27.67% / 6.66 | 153.2m / 0.092% |
| run 2 | 511m / 771Mi | 2.54 CPU / 13.73Gi | 2.05 CPU / 10.74Gi | 3.26 CPU / 30.01Gi | 52.14% / 28.10% / 7.00 | 156.8m / 0.085% |
| run 3 | 475m / 781Mi | 1.18 CPU / 13.68Gi | 2.03 CPU / 10.75Gi | 3.37 CPU / 30.19Gi | 48.52% / 28.33% / 7.00 | 150.8m / 0.068% |

- ELS 六 Pod 聚合峰值仅 445–511m CPU、771–781Mi memory；单 Pod 1 秒 CPU p99 为 151–157m。
- loadgen Kubernetes 聚合峰值只有 3.11–3.37 CPU / 20 vCPU，但单节点 1 秒 run queue p99 为 6.66–7（D2 仅 2 vCPU）。
- 三轮 loadgen 全程 TCP retrans 合计 35，packet drops 为 0；全部正式 revision 窗口合计只有 2 次 retrans、0 次 drops，且没有与最差波峰对齐。
- ELS 全程 throttling 很少（period rate 0.068%–0.092%），正式 revision 窗口为 0；其 CPU 与 runner p99 的探索性相关性也未呈正向。

## 与历史 D4 参考的边界比较

| 指标 | 历史 D4 g1 三轮中位数 | 当前 D2 三轮中位数 | 变化 |
| --- | ---: | ---: | ---: |
| 保守 p99 | 296.00 ms | 479.00 ms | +183.00 ms (61.82%) |
| 加权平均 | 65.65 ms | 111.36 ms | +45.71 ms (69.62%) |
| >100 ms | 9.028% | 53.140% | +44.112 pp |

这是跨 campaign 的诊断比较：FeatBit 从 3 个 D4 nodes（每节点 2 ELS）变成 6 个 D4 nodes（每节点 1 ELS），并加入 1 秒采集器，因此不能把差异当作严格的单变量因果证明。不过，同 D2 节点上的两个 runner 在同一 revision 成对变慢、loadgen CPU/pressure 与 p99 同向，而 ELS/网络指标不随之抬升，足以说明本轮结果受负载生成器明显污染。

## 下一步（仍不申请配额）

先不要继续降低 runner request；request 只影响调度保留量，不会给 D2 增加物理 CPU。更有信息量的下一步二选一：

1. 保持 10 × D2 loadgen，改为 10 runners × 1,000 WS（每节点一个进程），检验同节点双 runner 调度竞争；
2. 把 6 个 FeatBit nodes 改为 D2、把 10 个 loadgen nodes 恢复 D4：system 2 + FeatBit 12 + loadgen 40 = 54 vCPU，仍保留 ELS 一节点一 Pod且不提高现有峰值配额。

方案 2 更适合继续判断 FeatBit 极限：本轮 ELS 单 Pod CPU p99 仅约 0.15 core，D4 算力优先留给观测端更合理；但它仍需作为新配置重新跑三次，不能与本轮拼接。

## 复现与证据

- Matrix：[`k8s-infra/matrices/aks-10k-d2-els-node-isolation-1s.json`](../../k8s-infra/matrices/aks-10k-d2-els-node-isolation-1s.json)
- 执行器：[`k8s-infra/scripts/run-aks-capacity-matrix.ps1`](../../k8s-infra/scripts/run-aks-capacity-matrix.ps1)
- 1 秒采集：[`start-aks-1s-evidence.ps1`](../../k8s-infra/scripts/start-aks-1s-evidence.ps1)、[`collect-aks-node-evidence.sh`](../../k8s-infra/scripts/collect-aks-node-evidence.sh)、[`stop-aks-1s-evidence.ps1`](../../k8s-infra/scripts/stop-aks-1s-evidence.ps1)
- 单轮分析：[`analyze-aks-1s-evidence.ps1`](../../k8s-infra/scripts/analyze-aks-1s-evidence.ps1)、[`analyze-aks-latency.ps1`](../../k8s-infra/scripts/analyze-aks-latency.ps1)
- 本汇总：[`summarize-aks-d2-node-isolation.ps1`](../../k8s-infra/scripts/summarize-aks-d2-node-isolation.ps1)
- Machine-readable result：[`aks-10k-d2-node-isolation-1s.json`](aks-10k-d2-node-isolation-1s.json)

所有 TestRun、Pod snapshot、runner JSON/HTML、正常/去波峰报告、5 秒资源记录与 1 秒 TSV 均保留在本地 `results/<run-id>/`。本流程不会删除 TestRun、PVC、AKS 或数据库。