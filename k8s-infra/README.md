# Docker Desktop Kubernetes 本地演练

这个目录用于在 Docker Desktop 自带的单节点 Kubernetes 中演练下面这条链路：

```text
PowerShell -> k6 Operator -> 单个 k6 runner Pod -> FeatBit ELS ClusterIP Service
                                      |          -> FeatBit API（自动改 probe flags）
                                      |
                                      +-> PVC -> 本地 JSON / HTML 报告
```

这里验证的是 Kubernetes 部署、集群内连接、重复触发和结果收集流程。Docker Desktop 中的
k6、ELS、数据库等组件共享同一台电脑和同一个 Linux VM，因此 **不能** 用这里的结果判断
AKS 的真实容量或性能。

## 目录内容

```text
k8s-infra/
  Dockerfile.k6                 将仓库中的多文件 k6 脚本打进 runner 镜像
  manifests/local-base.yaml     测试 namespace、结果 PVC 和结果读取 Pod
  values/featbit-local.yaml      FeatBit 本地 HTTP + 3 ELS Pod 覆盖配置
  templates/testrun.yaml        每次测试使用的 TestRun 模板
  scripts/bootstrap.ps1         构建镜像并安装 k6 Operator
  scripts/configure-target.ps1  配置 ELS 内部地址和 Server SDK secret
  scripts/configure-controller.ps1  配置 REST controller 的环境和 Access Token
  scripts/run-test.ps1          创建唯一 TestRun、跟踪日志并收集报告
  scripts/collect-results.ps1   再次下载历史运行的报告
```

所有脚本都要求当前 `kubectl` context 恰好为 `docker-desktop`，并且执行 kubectl 时仍显式传入
`--context docker-desktop`。这是为了避免误操作 AKS。

## 1. 执行前确认

本流程假设 Docker Desktop Kubernetes 已经可用，并且 PowerShell 7、`docker`、`kubectl`、
Helm 3.7+ 和 Git 已安装。

只需要确认当前 context，避免误操作其他集群：

```powershell
kubectl config use-context docker-desktop
kubectl config current-context
kubectl --context docker-desktop get nodes
```

预期 context 是 `docker-desktop`，节点状态是 `Ready`。如果这里显示 AKS context，立即停止。

## 2. 初始化本地测试基础设施

从仓库根目录运行：

```powershell
.\k8s-infra\scripts\bootstrap.ps1
```

脚本会：

1. 再次确认当前 context 是 `docker-desktop`。
2. 用 `k8s-infra/Dockerfile.k6` 构建 `featbit-k6-local:2.1.0`。
3. 安装固定版本的 k6 Operator Helm chart。
4. 创建 `featbit-loadtest` namespace、结果 PVC 和 `results-reader` Pod。

重复执行是安全的。只想更新 Kubernetes 资源而不重新构建镜像时：

```powershell
.\k8s-infra\scripts\bootstrap.ps1 -SkipImageBuild
```

k6 Operator 官方文档：
<https://grafana.com/docs/k6/latest/set-up/set-up-distributed-k6/install-k6-operator/>

## 3. 部署 FeatBit（由你操作）

使用 FeatBit 官方 Helm repository 中已经发布的 chart `0.9.13`（FeatBit `5.4.4`），不依赖
本机的 `featbit-charts` 源码仓库。

这里使用本仓库专门用于负载测试的覆盖文件 `k8s-infra/values/featbit-local.yaml`，不修改也不
读取 chart 源码仓库中的 `values.yaml`。覆盖文件具有以下约束：

- UI、API、ELS 使用 HTTP NodePort，方便从 Windows 浏览器管理 flag，不需要 Ingress 或证书。
- ELS 固定 3 个副本并关闭 HPA。
- DAS 关闭；它不在本次 Server SDK streaming 数据路径上，Insights 页面不可用不影响测试。
- architecture 使用 Standard；内置 PostgreSQL 负责持久化，内置 Redis 负责缓存和消息分发。
- k6 不走 NodePort；它仍通过 ELS Service 的集群内 DNS 和 ClusterIP 访问 5100 端口。

chart 在 Standard 下会为 API 和 ELS 设置 `MqProvider=Redis`、`CacheProvider=Redis`，所以这里的
Redis 会被实际使用，而不是仅仅部署一个闲置实例。Redis 本身使用单副本 standalone 模式，适合
Docker Desktop 流程演练；这不是 AKS 生产环境的高可用 Redis 方案。

先创建 namespace，以及 API `5.4.4` 要求的唯一 JWT key：

```powershell
kubectl --context docker-desktop create namespace featbit `
  --dry-run=client -o yaml |
  kubectl --context docker-desktop apply -f -

$jwtKey = [Convert]::ToHexString(
  [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
).ToLowerInvariant()

kubectl --context docker-desktop -n featbit create secret generic featbit-jwt-secret `
  --from-literal="jwt-key=$jwtKey" `
  --dry-run=client -o yaml |
  kubectl --context docker-desktop -n featbit apply -f -

Remove-Variable jwtKey
```

先添加或刷新官方 chart repository，并确认固定版本可用：

```powershell
helm repo add featbit https://featbit.github.io/featbit-charts/ --force-update
helm repo update featbit
helm search repo featbit/featbit --version 0.9.13
```

然后由你执行 Helm 部署。`upgrade --install` 可以用于第一次安装，也可以在修改 values 后重复执行：

```powershell
$loadTestRoot = "C:\Code\featbit\featbit-load-testing"

helm upgrade --install featbit featbit/featbit `
  --version 0.9.13 `
  --kube-context docker-desktop `
  --namespace featbit `
  --create-namespace `
  --values "$loadTestRoot\k8s-infra\values\featbit-local.yaml" `
  --wait `
  --timeout 15m
```

这是全新数据库时的命令。以后升级 FeatBit/chart 或复用旧 PostgreSQL PVC 时，应先检查
[官方仓库的 migration 说明](https://github.com/featbit/featbit-charts/tree/main/migration)中对应版本；
Helm 不会自动执行升级迁移。

部署后确认 3 个 ELS endpoints 已经 Ready：

```powershell
helm status featbit --namespace featbit --kube-context docker-desktop

kubectl --context docker-desktop -n featbit get deployments,pods,services,pvc
kubectl --context docker-desktop -n featbit rollout status deployment/featbit-els --timeout=5m
kubectl --context docker-desktop -n featbit get endpointslices `
  -l kubernetes.io/service-name=featbit-els
```

本地管理入口为：

```text
UI:  http://localhost:30081
API: http://localhost:30000
ELS: http://localhost:30100
```

如果 Docker Desktop 没有把 NodePort 映射到 localhost，可以分别对 `featbit-ui:8081`、
`featbit-api:5000`、`featbit-els:5100` 做 `kubectl port-forward`，本地端口仍使用
`30081`、`30000`、`30100`。

对 k6 来说，确定的集群内 streaming base URL 是：

```text
ws://featbit-els.featbit.svc.cluster.local:5100
```

这里使用 `ws://` 是正确的：ELS 在 5100 上提供 HTTP，并通过 HTTP Upgrade 建立 WebSocket；
只有启用 TLS 时才使用 `wss://`。`evaluationServerExternalUrl` 给 UI/普通 SDK 使用，所以保持
`http://localhost:30100`；k6 的 `FEATBIT_STREAMING_URL` 则必须使用 `ws://`。不要添加
`/streaming`，测试脚本会自动补上。

## 4. 准备 probe flags

先运行 smoke。创建 String 类型 flag：

```text
loadtest-sync-probe-01
```

它需要有以下 variation value：

```text
baseline
rev-001
rev-002
```

启用 flag，并确保没有 target users 或 targeting rules。Default Rule 可以处于任意一个上述
variation；REST controller 会在每次测试的 `setup()` 中强制恢复为 `baseline`。

Baseline 使用 `loadtest-sync-probe-01` 至 `loadtest-sync-probe-10`；Growth 使用至
`loadtest-sync-probe-20`。完整规则仍以仓库根目录的 `README.md` 为准。

## 5. 配置集群内目标

使用 SecureString 输入 Server SDK secret，避免明文进入 PowerShell history：

```powershell
$serverSecret = Read-Host "FeatBit Server SDK secret" -AsSecureString

.\k8s-infra\scripts\configure-target.ps1 `
  -StreamingUrl "ws://featbit-els.featbit.svc.cluster.local:5100" `
  -ServerSecret $serverSecret

Remove-Variable serverSecret
```

脚本会创建：

- ConfigMap `featbit-k6-target`：ELS 地址及非敏感公共配置。
- Secret `featbit-k6-secret`：`FEATBIT_SERVER_SECRET`。

Secret 不会写入仓库或生成的 TestRun YAML。

### 配置 REST controller

REST controller 使用 FeatBit OpenAPI Access Token，而不是 Server SDK secret。Token 直接作为
`Authorization` header 的值，不添加 `Bearer`。使用 SecureString 避免进入 PowerShell history：

```powershell
$accessToken = Read-Host "FeatBit OpenAPI access token" -AsSecureString

# 可选：先列出 token 能访问的 project/environment key。
.\k8s-infra\scripts\configure-controller.ps1 `
  -AccessToken $accessToken `
  -ListEnvironments

.\k8s-infra\scripts\configure-controller.ps1 `
  -AccessToken $accessToken `
  -ProjectKey "<project-key>" `
  -EnvironmentKey "<environment-key>"

Remove-Variable accessToken
```

脚本通过 `http://localhost:30000` 验证 token 和解析 environment ID，然后创建：

- ConfigMap `featbit-k6-controller`：集群内 API URL、environment ID 和更新时间表。
- Secret `featbit-k6-controller-secret`：`FEATBIT_API_ACCESS_TOKEN`。

runner 实际调用的地址是 `http://featbit-api.featbit.svc.cluster.local:5000`。Access Token 不会
进入 TestRun YAML、metadata 或仓库文件。

## 6. 运行 smoke test

完成 target 和 REST controller 配置后运行：

```powershell
.\k8s-infra\scripts\run-test.ps1 -Profile smoke -Note "local ELS, first run"
```

脚本会生成类似下面的唯一 ID：

```text
smoke-20260721-143022-a1b2c3d4-7f2a
```

随后它会创建新的 `TestRun`、跟踪 runner 日志、等待测试结束并把报告复制到仓库根目录的
`results/`。同一 runner Pod 内的 controller 会自动执行：

1. `setup()` 在任何 WebSocket 建立前，把所有 probe flags 恢复为 `baseline`。
2. measured hold 开始 5 秒后，把所有 probe flags 更新为 `rev-001`。
3. 最后一个 `rev-001` 保存完成后等待 30 秒，再全部更新为 `rev-002`。
4. 测试结束后，`teardown()` 再把所有 probe flags 恢复为 `baseline`。

不需要再通过 UI 手动修改 flag。更新使用当前 flag `revision` 做乐观并发控制；如果 token、
flag 配置或并发 revision 不正确，controller 会让本轮测试失败，而不是静默继续。

自然结束会执行第 4 步。直接删除 TestRun 或强制终止 runner Pod 可能来不及执行
`teardown()`；下一轮的 `setup()` 仍会先恢复 `baseline`，但中断后不要假设 flag 已立即复原。

实时 Dashboard 默认监听 runner 的 5665 端口。另开一个 PowerShell 后执行：

```powershell
$pod = kubectl --context docker-desktop -n featbit-loadtest get pods `
  -l "app.kubernetes.io/name=featbit-k6-runner" `
  --field-selector=status.phase=Running `
  -o jsonpath='{.items[0].metadata.name}'

kubectl --context docker-desktop -n featbit-loadtest port-forward "pod/$pod" 5665:5665
```

打开 <http://localhost:5665>。测试结束时关闭 Dashboard 页面，让 k6 正常退出。

若只想提交 TestRun、稍后再观察：

```powershell
.\k8s-infra\scripts\run-test.ps1 -Profile smoke -Note "async run" -NoWait
```

## 7. 调整后再次运行

先修改 ELS 配置并等待 rollout 完成，然后再次执行同一个命令：

```powershell
kubectl --context docker-desktop -n <featbit-namespace> rollout status deployment/<els-deployment>
.\k8s-infra\scripts\run-test.ps1 -Profile smoke -Note "ELS CPU or image adjusted"
```

每次都会创建新的 `RUN_ID` 和新的 `TestRun`，不会覆盖之前的结果。脚本会拒绝在已有测试
仍处于 `Pending` 或 `Running` 时启动第二轮，避免两轮测试同时修改相同的 probe flags。

当 smoke 流程稳定后，可使用：

```powershell
.\k8s-infra\scripts\run-test.ps1 -Profile baseline -Note "baseline configuration A"
.\k8s-infra\scripts\run-test.ps1 -Profile growth -Note "growth configuration A"
```

当前固定 `parallelism: 1`。这是有意的：现有脚本包含全局精确连接数 threshold，并且本地
演练要保持单 runner 时钟和执行语义。

## 8. 查看结果

实时查看 Kubernetes 对象：

```powershell
kubectl --context docker-desktop -n featbit-loadtest get testruns,jobs,pods
kubectl --context docker-desktop -n featbit-loadtest describe testrun featbit-<run-id>
kubectl --context docker-desktop -n featbit-loadtest logs job/featbit-<run-id>-1
```

默认运行结束后，本地会有：

```text
results/<run-id>-summary.json
results/<run-id>-report.html
results/<run-id>-metadata.json
results/<run-id>-testrun.yaml
```

`summary.json` 和 runner 的退出结果是正式 Pass/Fail 依据；HTML 用于查看曲线。若之前使用
了 `-NoWait`，或想重新下载历史结果：

```powershell
.\k8s-infra\scripts\collect-results.ps1 -RunId <run-id> -OpenReport
```

k6 HTML 报告说明：
<https://grafana.com/docs/k6/latest/results-output/web-dashboard/>

测试自然结束后重点确认：

- 所有成功率 threshold 为 100%。
- `unexpected_close`、`websocket_error`、`heartbeat_timeout` 等错误计数为 0。
- `probe_sync_latency_ms` 有样本，并查看 p50/p95/p99。
- 被 Ctrl+C、中途删除或基础设施失败的运行应标记为 `Invalid`，不能当作性能失败。

## 9. 清理单次 Kubernetes 资源

确认报告已复制到本地后，可以只删除某一次运行：

```powershell
kubectl --context docker-desktop -n featbit-loadtest delete testrun featbit-<run-id>
```

这会清理该 TestRun 相关的 Job/Pod；共享 PVC 和仓库中的 `results/` 不受影响。不要删除
`featbit-loadtest` namespace，除非你确实准备同时删除 PVC 中的所有测试报告。

## 当前本地阶段的边界

- flag 更新已经由同一 k6 runner Pod 内的 REST controller 自动执行。
- 当前脚本的 `probe_sync_latency_ms` 仍使用 FeatBit payload 中的 `updatedAt` 计算。Docker
  Desktop 单节点上的 Pod 共享节点时钟，因此适合流程演练；后续若需要完全排除 API/ELS
  时钟因素，可再把 controller 的本地写入时刻作为独立 `t0` 指标。
- 真正的 3 Pod ELS 性能结论必须在 AKS 独立 load-test node pool 中重新执行。
