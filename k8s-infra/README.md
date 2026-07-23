# Docker Desktop Kubernetes 本地负载测试

本目录用于在 Docker Desktop 的单节点 Kubernetes 中验证 FeatBit Server SDK streaming：
k6 建立固定数量的 WebSocket，REST controller 自动预热并修改 probe flags，测试结束后生成
JSON 与 HTML 报告。

这里是本地流程演练环境，不用于得出 AKS 容量结论。所有 PowerShell 脚本都要求当前
`kubectl` context 恰好为 `docker-desktop`，并在每次调用时显式传入该 context。

要把 FeatBit 与负载生成器迁移到 Azure，并形成可归因的容量结果，请使用
[AKS 负载测试迁移与运行指南](README-AKS.md)。

## 执行顺序

1. 初始化 k6 Operator、runner 镜像和结果存储。
2. 使用固定 Helm chart 部署本地 FeatBit。
3. 获取同一个 FeatBit environment 的 Server SDK secret 和 OpenAPI token。
4. 配置 k6 streaming target 与 REST controller。
5. 先运行 smoke，再运行 baseline，最后按需运行 growth；每轮自动重建该 Profile 的 probe flags。
6. 查看实时 Dashboard，并从 `results/` 读取最终报告。

所有命令都从仓库根目录、使用 PowerShell 7 执行。

让 Codex 代跑时，只需说明 `smoke`、`baseline` 或 `growth` 以及本轮 Note。Codex 负责执行命令、
记录 `RUN_ID`、监控运行并收集报告；不会要求你手工创建、修改或复原 feature flags。

## 当前本地拓扑

| 组件 | 当前配置 |
| --- | --- |
| FeatBit | Helm chart `0.9.13`，应用 `5.4.4` |
| UI / API / ELS | 1 / 1 / 3 个 Pod |
| 数据组件 | 单副本 PostgreSQL、单副本 Redis |
| k6 Operator | Helm chart `4.5.0`，应用 `1.5.0` |
| 负载生成器 | `parallelism: 1`，一个实际产生负载的 runner Pod |
| 结果存储 | `featbit-loadtest/featbit-k6-results`，1 GiB RWO PVC |

k6 Operator 还会创建短生命周期的 initializer 和 starter Pod；它们不产生负载，也不改变
runner 的单 Pod 执行语义。

## 1. 前置条件

需要：

- Docker Desktop，且 Kubernetes 已启用；
- PowerShell 7；
- `docker`、`kubectl`、Helm 3.7+ 和 Git。

切换并确认 context：

```powershell
kubectl config use-context docker-desktop
kubectl config current-context
kubectl --context docker-desktop get nodes
```

预期 context 为 `docker-desktop`，节点状态为 `Ready`。脚本检测到其他 context 时会拒绝继续。

## 2. 初始化 k6 基础设施

```powershell
.\k8s-infra\scripts\bootstrap.ps1
```

该命令会：

- 构建本地镜像 `featbit-k6-local:2.1.0`；
- 安装 k6 Operator chart `4.5.0`；
- 创建 `featbit-loadtest` namespace、结果 PVC 和常驻 `results-reader` Pod；
- 等待 `results-reader` Ready，并确认 `testruns.k6.io` CRD 可用。

只有在本地 runner 镜像已经存在、且 `k6/` 代码没有变化时，才使用：

```powershell
.\k8s-infra\scripts\bootstrap.ps1 -SkipImageBuild
```

修改 `k6/` 后必须重新运行不带 `-SkipImageBuild` 的 bootstrap，否则新 TestRun 仍会使用旧代码。

## 3. 部署本地 FeatBit

本流程固定使用 `featbit/featbit` chart `0.9.13` 与
[`values/featbit-local.yaml`](values/featbit-local.yaml)。首次部署先创建 namespace 和 JWT secret；
已有 secret 时不要重新生成，以免轮换 JWT key。

```powershell
kubectl --context docker-desktop create namespace featbit `
  --dry-run=client -o yaml |
  kubectl --context docker-desktop apply -f -

$jwtSecret = kubectl --context docker-desktop -n featbit get secret featbit-jwt-secret `
  --ignore-not-found -o name

if ([string]::IsNullOrWhiteSpace($jwtSecret)) {
  $jwtKey = [Convert]::ToHexString(
    [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
  ).ToLowerInvariant()

  kubectl --context docker-desktop -n featbit create secret generic featbit-jwt-secret `
    --from-literal="jwt-key=$jwtKey" `
    --dry-run=client -o yaml |
    kubectl --context docker-desktop -n featbit apply -f -

  Remove-Variable jwtKey
}

Remove-Variable jwtSecret
```

安装或更新固定 chart：

```powershell
helm repo add featbit https://featbit.github.io/featbit-charts/ --force-update
helm repo update featbit

$repoRoot = (Resolve-Path .).Path

helm upgrade --install featbit featbit/featbit `
  --version 0.9.13 `
  --kube-context docker-desktop `
  --namespace featbit `
  --create-namespace `
  --values "$repoRoot\k8s-infra\values\featbit-local.yaml" `
  --wait `
  --timeout 15m
```

确认部署结果：

```powershell
helm status featbit --namespace featbit --kube-context docker-desktop
kubectl --context docker-desktop -n featbit rollout status deployment/featbit-els --timeout=5m
kubectl --context docker-desktop -n featbit get deployments,pods,services,pvc
kubectl --context docker-desktop -n featbit get endpointslices `
  -l kubernetes.io/service-name=featbit-els
```

预期 ELS Deployment 为 `3/3` Ready，且 EndpointSlice 中有三个 Ready endpoint。

当前本地入口：

| 服务 | Windows 地址 | 集群内地址 |
| --- | --- | --- |
| UI | <http://localhost:30081> | `http://featbit-ui.featbit.svc.cluster.local:8081` |
| REST API | <http://localhost:30000> | `http://featbit-api.featbit.svc.cluster.local:5000` |
| ELS | <http://localhost:30100> | `http://featbit-els.featbit.svc.cluster.local:5100` |

如果 Docker Desktop 没有映射 NodePort，可在三个独立 PowerShell 窗口中保持以下命令运行：

```powershell
kubectl --context docker-desktop -n featbit port-forward service/featbit-ui 30081:8081
kubectl --context docker-desktop -n featbit port-forward service/featbit-api 30000:5000
kubectl --context docker-desktop -n featbit port-forward service/featbit-els 30100:5100
```

升级 chart 或复用其他版本创建的 PostgreSQL PVC 前，先检查 FeatBit chart 对应版本的 migration
说明；Helm 不会替你执行数据库迁移。

## 4. 自动管理 probe flags

不要手工创建或修改 probe flags。`run-test.ps1` 会在创建 TestRun 前调用
`prepare-probe-flags.ps1`，在 controller 配置指向的 environment 中按 Profile 精确重建它们：

| Profile | 自动创建的 flag keys | 数量 | 连接数 | 建连速率 | Stabilization | Hold |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `smoke` | `loadtest-sync-probe-01` | 1 | 10 | 1/s | 10s | 180s |
| `baseline` | `loadtest-sync-probe-01` 至 `loadtest-sync-probe-10` | 10 | 1,000 | 10/s | 30s | 600s |
| `growth` | `loadtest-sync-probe-01` 至 `loadtest-sync-probe-20` | 20 | 5,000 | 50/s | 30s | 600s |

runner 资源按 Profile 分配：smoke/baseline 使用 `512Mi` memory request 与 `4Gi` limit；growth
使用 `4Gi` request 与 `8Gi` limit，以容纳 5,000 个独立 k6 VU、WebSocket 状态和 20 个 probe
flag 的同步峰值。调度前请确保节点至少能满足该 request。

每轮 provision 会：

1. 确认当前没有 Pending/Running 的负载测试；
2. 从 `featbit-k6-controller` 和 `featbit-k6-controller-secret` 读取 environment ID 与 OpenAPI token；
3. archive 并删除该 environment 中所有 active/archived 的 `loadtest-sync-probe-NN`；
4. 创建该 Profile 所需的准确数量，并验证每个 flag 的完整配置和初始值。

自动创建的每个 flag 都是：

| 配置 | 要求 |
| --- | --- |
| Type | String |
| Status | Enabled、未归档 |
| Variation values | `baseline`、`rev-001`、`rev-002` |
| Target users / targeting rules | 均为空 |
| Default Rule | 100% `baseline` |

`loadtest-sync-probe-NN` 是这套测试的保留 key，会在每轮开始前被删除并重建；不要把业务配置、
targeting rules 或人工数据放在这些 flags 上。从 growth 切回 baseline 或 smoke 时，多余 flags 也会
自动删除，因此下一轮始终从该 Profile 的准确数量和 `baseline` 状态开始。

## 5. 配置 streaming target

从 FeatBit UI 获取目标 environment 的 **Server SDK secret**。集群内 ELS streaming base URL 固定为
`ws://featbit-els.featbit.svc.cluster.local:5100`；不要添加 `/streaming`，k6 脚本会自动补上。

```powershell
$serverSecret = Read-Host "FeatBit Server SDK secret" -AsSecureString

.\k8s-infra\scripts\configure-target.ps1 `
  -StreamingUrl "ws://featbit-els.featbit.svc.cluster.local:5100" `
  -ServerSecret $serverSecret

Remove-Variable serverSecret
```

该脚本创建或更新：

- ConfigMap `featbit-k6-target`；
- Secret `featbit-k6-secret`。

## 6. 配置 REST controller

controller 使用 FeatBit OpenAPI token。先列出 token 可访问的 project/environment，再选择与
Server SDK secret **完全相同的 environment**。如果二者不一致，controller 会修改一个环境，
WebSocket 却连接另一个环境，测试必然收不到 revision。

Token 必须允许读取、列举、创建、archive、删除 feature flags，以及更新 targeting；权限不足时
`run-test.ps1` 会在创建 TestRun 前失败，不会带着不完整的 flags 开始负载。

```powershell
$accessToken = Read-Host "FeatBit OpenAPI access token" -AsSecureString

.\k8s-infra\scripts\configure-controller.ps1 `
  -AccessToken $accessToken `
  -ListEnvironments

.\k8s-infra\scripts\configure-controller.ps1 `
  -AccessToken $accessToken `
  -ProjectKey "<上一步输出的 project key>" `
  -EnvironmentKey "<上一步输出的 environment key>"

Remove-Variable accessToken
```

该脚本通过 `http://localhost:30000` 验证 token，然后创建或更新：

- ConfigMap `featbit-k6-controller`；
- Secret `featbit-k6-controller-secret`。

controller 的默认时序：

| 参数 | 默认值 | 含义 |
| --- | ---: | --- |
| `WarmupSettleSeconds` | 2s | 预热每次写入后的等待时间 |
| `StartDelaySeconds` | 5s | measured hold 开始后多久写入 `rev-001` |
| `RevisionIntervalSeconds` | 30s | 完成 `rev-001` 后到开始 `rev-002` 的间隔 |
| `FinalSettleSeconds` | 30s | 最终 revision 至少保留多久 |

需要调整时，把相应参数传给最后一次 `configure-controller.ps1`；配置会供后续所有 TestRun 使用。

## 7. 运行测试

每条命令都会先 provision flags，再打印 `RUN_ID`、创建唯一 TestRun、跟踪 runner 日志、等待 Job
结束并复制报告。同一时间只允许一个 Pending/Running 测试；provision 失败时不会创建 TestRun。

每轮自动执行：

1. `run-test.ps1` 删除并重建该 Profile 的准确数量，全部初始化为 `baseline`；
2. k6 `setup()` 再确认所有 probe flags 为 `baseline`；
3. 在任何 WebSocket 建立前执行不计入正式 revision 的
   `baseline -> rev-001 -> baseline` 预热，每步默认等待 2 秒；
4. 建立 Profile 指定数量的 WebSocket；
5. measured hold 开始 5 秒后写入 `rev-001`；
6. 完成所有 `rev-001` 写入后等待 30 秒，再写入 `rev-002`；
7. 测试自然结束后，`teardown()` 恢复 `baseline`。

不需要在 UI 中操作 flag。每个 flag 每轮产生两次预热变更、两次正式变更，并在结束时恢复。

### Smoke

先用 smoke 验证凭据、REST CRUD、ELS streaming、自动变更和结果收集链路：

```powershell
.\k8s-infra\scripts\run-test.ps1 `
  -Profile smoke `
  -Note "local ELS, automatic warm-up"
```

该轮自动创建 1 个 flag、建立 10 条连接，10 秒 ramp-up 后稳定 10 秒；measured hold 为
`T+20s` 至 `T+200s`。预期 `controller_warmup_updates == 2`、
`controller_revision_updates == 2`。

### Baseline

smoke 自然结束并通过后运行 baseline：

```powershell
.\k8s-infra\scripts\run-test.ps1 `
  -Profile baseline `
  -Note "baseline configuration A"
```

该轮会先把 smoke 的 flag 集合重建为 10 个 canonical flags，再建立 1,000 条连接。ramp-up 为
100 秒，随后稳定 30 秒；measured hold 为 `T+130s` 至 `T+730s`，drain 在 `T+740s` 结束。
预期 `controller_warmup_updates == 20`、`controller_revision_updates == 20`。

### Growth

baseline 自然结束并通过后运行 growth：

```powershell
.\k8s-infra\scripts\run-test.ps1 `
  -Profile growth `
  -Note "growth configuration A"
```

该轮会重建为 20 个 canonical flags，再建立 5,000 条连接。ramp-up 同样为 100 秒，随后稳定
30 秒；measured hold 为 `T+130s` 至 `T+730s`，drain 在 `T+740s` 结束。预期
`controller_warmup_updates == 40`、`controller_revision_updates == 40`。

运行 growth 前确认 Docker Desktop 为 5,000 条 WebSocket 和三个 ELS Pod 留有足够 CPU/内存；
growth runner 会请求 `4Gi`、限制为 `8Gi`。资源不足导致的运行属于本地环境瓶颈，不能直接
当作 FeatBit 容量结论。

### 后台提交

任意 Profile 都可以用 `-NoWait` 只提交 TestRun。例如：

```powershell
.\k8s-infra\scripts\run-test.ps1 `
  -Profile baseline `
  -Note "async baseline" `
  -NoWait
```

使用 `-NoWait` 时请保存打印出的 `RUN_ID`，待 Job 结束后再运行结果收集脚本。

## 8. 实时 Dashboard

在 `run-test.ps1` 打印 `RUN_ID` 后，另开一个 PowerShell：

```powershell
$runId = "<RUN_ID>"
$deadline = (Get-Date).AddMinutes(5)

do {
  $pod = kubectl --context docker-desktop -n featbit-loadtest get pods `
    -l "batch.kubernetes.io/job-name=featbit-$runId-1" `
    --field-selector=status.phase=Running `
    -o jsonpath='{.items[0].metadata.name}' 2>$null

  if ([string]::IsNullOrWhiteSpace($pod)) {
    Start-Sleep -Seconds 2
  }
} while ([string]::IsNullOrWhiteSpace($pod) -and (Get-Date) -lt $deadline)

if ([string]::IsNullOrWhiteSpace($pod)) {
  throw "Timed out waiting for the k6 runner Pod."
}

kubectl --context docker-desktop -n featbit-loadtest wait `
  --for=condition=Ready "pod/$pod" --timeout=5m
kubectl --context docker-desktop -n featbit-loadtest port-forward "pod/$pod" 5665:5665
```

打开 <http://localhost:5665>。runner Pod 结束后 port-forward 会自动断开；Dashboard 页面是否打开
不会影响 k6 退出。

## 9. 查看与收集结果

查看运行状态和日志：

```powershell
$runId = "<RUN_ID>"

kubectl --context docker-desktop -n featbit-loadtest get testruns,jobs,pods
kubectl --context docker-desktop -n featbit-loadtest describe testrun "featbit-$runId"
kubectl --context docker-desktop -n featbit-loadtest logs "job/featbit-$runId-1"
```

正常等待模式会在仓库根目录生成：

```text
results/<run-id>-metadata.json
results/<run-id>-testrun.yaml
results/<run-id>-summary.json
results/<run-id>-report.html
```

`-NoWait` 运行或重新下载历史报告时：

```powershell
.\k8s-infra\scripts\collect-results.ps1 -RunId $runId -OpenReport
```

`summary.json` 和 runner Job 的退出状态是 Pass/Fail 依据；HTML 用于查看时间序列。重点确认：

- `controller_warmup_updates == probe flag 数量 x 2`；
- `controller_revision_updates == probe flag 数量 x 2`；
- 每个 `probe_revision_coverage{revision_index:*}` 为 100%；
- `probe_sync_latency_ms{revision_index:*}` 的 p95 `<500ms`、p99 `<1000ms`；
- `initial_sync_success`、`connection_survived`、`final_applied_revision_success` 为 100%；
- `controller_api_error`、`websocket_error`、`heartbeat_timeout`、
  `revision_sequence_error`、`unexpected_revision` 为 0。

`controller_api_latency_ms` 会同时包含 setup、预热、正式更新和 teardown 的 GET/PUT/验证请求，
因此它的 aggregate max 可能正好是被预热吸收的冷请求。正式 flag 传播延迟应看按
`revision_index` 拆分的 `probe_sync_latency_ms`。

## 10. 重跑、停止与清理

重复执行 `run-test.ps1` 会创建新的 RUN_ID，不覆盖旧报告。修改 FeatBit values 后重新执行第 3
节的 `helm upgrade --install`，并确认：

```powershell
kubectl --context docker-desktop -n featbit rollout status deployment/featbit-els --timeout=5m
```

在 `run-test.ps1` 前台日志窗口按 `Ctrl+C`，可能只会停止本地日志跟踪和 PowerShell 脚本，Kubernetes
中的 TestRun/Job 仍可能继续。先检查状态；若要真正停止负载，删除 TestRun：

```powershell
$runId = "<RUN_ID>"
kubectl --context docker-desktop -n featbit-loadtest get testrun "featbit-$runId"
kubectl --context docker-desktop -n featbit-loadtest delete testrun "featbit-$runId"
```

被中止或删除的运行是 Invalid，不能作为性能失败。强制删除可能跳过 `teardown()`；下一轮
`run-test.ps1` 会先删除并重建该 Profile 的 flags，再由 `setup()` 确认 baseline；但不要假设
中断后、下一轮开始前 flag 已立即复原。

自然结束并确认报告已复制后，也可用同一个 delete 命令清理该轮 Job/Pod。共享 PVC 和本地
`results/` 不会被删除。

## 常见问题

- **脚本拒绝当前 context**：执行 `kubectl config use-context docker-desktop`。
- **缺少 `featbit-k6-target` 或 controller 配置**：重新执行第 5、6 节的配置脚本。
- **flag provision 在 TestRun 创建前失败**：确认本地 API `http://localhost:30000` 可访问，且
  OpenAPI token 对目标 environment 有读取、创建、archive、删除和 targeting 更新权限。
- **出现 `received pong for unknown ping ID`**：如果 `ping_sent == pong_received`、
  `heartbeat_timeout == 0` 且 `websocket_error == 0`，这是 k6 的 pong 跟踪警告，不影响本轮结论。
- **报告尚不可用**：确认 runner Job 已结束，再执行 `collect-results.ps1`。

## 本地结果边界

- Docker Desktop 中的 k6、API、ELS、PostgreSQL 和 Redis 共享同一台电脑及 Linux VM；结果不能
  外推为 AKS 容量。
- `probe_sync_latency_ms` 使用 FeatBit payload 的 `updatedAt` 作为起点。当前单节点时钟适合本地
  演练；跨节点测试必须先保证节点时钟同步。
- 这些脚本是 local-only，硬编码并强制检查 `docker-desktop`；不要直接用于 AKS。

[返回顶部](#docker-desktop-kubernetes-本地负载测试)
