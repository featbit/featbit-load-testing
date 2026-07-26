# Ephemeral AKS Terraform stack

This stack creates the Azure infrastructure used by a temporary FeatBit load-test environment:

- one AKS Free-tier control plane with a small, tainted system pool;
- a tainted target pool shared by FeatBit UI, API, and ELS Pods;
- a tainted loadgen pool whose node count is explicitly sized for the selected profile;
- an ephemeral ACR and the kubelet `AcrPull` role assignment;
- OIDC Workload Identity and the optional Key Vault CSI add-on.

The checked-in example reuses the existing `featbit-devtest` resource group and preserves that
group on `terraform destroy`. AKS always spans two resource groups: the AKS resource and ACR go into
`featbit-devtest`, while Azure creates `featbit-devtest-nodes` for VM scale sets, networking, and
managed disks. Azure deletes the node resource group with the cluster. It cannot be the same as the
main resource group and must not already exist.

It intentionally does not install Kubernetes/Helm resources in the same Terraform apply. HashiCorp
recommends managing a newly created cluster and in-cluster resources in separate apply operations.
After this stack is ready, use this guide to deploy the temporary FeatBit profile and follow the
parent [AKS runbook](../../README-AKS.md) to install the k6 Operator and run the test.

Run relative-path commands in this document from the repository's
`server-sdk-load-test/` directory.

## Checked-in quota-constrained topology

| Pool | Default | Purpose |
| --- | --- | --- |
| `system` | `1 × Standard_D2ds_v5` | Temporary AKS system services |
| `featbit` | `6 × Standard_D2ds_v5` | UI/API/dependencies plus six ELS Pods, strictly one ELS per node |
| `loadgen` | `10 × Standard_D4ds_v5` | Twenty 500-connection runners, two per node |

This is the exact 54-vCPU topology used by the
[quota-safe D4-loadgen validation](../../../docs/reports/aks-10k-d4-loadgen-d2-featbit-1s.md).
It fits the existing 65-vCPU regional and DDSv5-family quota without an
increase. All three 10,000-connection repetitions passed; the conservative
p99 median was 283.01 ms.

The one-node system pool is also an explicit cost tradeoff. A system-node failure invalidates that
run. It is not a production AKS recommendation.

## Deploy before a test

Prerequisites: Terraform 1.5+, Azure CLI, an authenticated Azure account, sufficient regional vCPU
quota, and permission to create role assignments.

```powershell
az login
az account set --subscription "<subscription-id>"
az group show --name featbit-devtest --output table
az group exists --name featbit-devtest-nodes
# Expected: false. AKS must create its node resource group itself.

Set-Location .\k8s-infra\terraform\aks
Copy-Item terraform.tfvars.example terraform.tfvars
# Edit subscription_id, owner, and expires-at; never add secrets.

terraform init
terraform fmt -check
terraform validate
terraform plan -out featbit-aks.tfplan
terraform apply featbit-aks.tfplan

Invoke-Expression (terraform output -raw get_credentials_command)
$aksContext = (kubectl config current-context).Trim()
kubectl --context $aksContext get nodes -L agentpool,workload -o wide
```

Do not reuse a plan after changing variables or after a failed apply. `terraform.tfvars`, state files,
plans, and `.terraform/` are ignored by Git.

Do not infer FeatBit capacity from a run in which loadgen CPU pressure is high.
The historical 50k experiment also showed about `5.33Gi` peak memory for a
5,000-connection runner, so every topology change must re-check both CPU
pressure and memory rather than only `kubectl top`.

The checked-in topology uses:

```text
system 1 × 2 vCPU + featbit 6 × 2 vCPU + loadgen 10 × 4 vCPU = 54 vCPU
```

For a fresh ephemeral cluster, one apply can create this topology directly.
Changing an existing node pool's VM size forces replacement. With only 11
vCPUs of headroom, the AzureRM provider may otherwise try to overlap a
temporary pool and the full final pool and exceed quota. Rotate one pool at a
time, inspect every fresh plan, and ensure temporary capacity is removed or
reduced before creating the final ten-node D4 pool. Never reuse the plan from
a failed replacement.

The local state is suitable for a manual ephemeral run. CI should use a remote backend that lives
outside AKS. Do not store the backend in the AKS-managed node resource group because that group is
deleted with the cluster.

The `featbit-devtest` resource group's own metadata location can remain `westus3`; `location =
"eastasia"` independently places AKS and ACR in East Asia. To create a dedicated main group instead,
set `create_resource_group = true` and choose an unused `resource_group_name`.

## Deploy FeatBit with bundled PostgreSQL and Redis

This repository includes a dev/test profile that deploys FeatBit chart `0.9.13` / app `5.4.4`
together with its bundled PostgreSQL and Redis subcharts:

- PostgreSQL chart `14.0.5`, using PostgreSQL image `16.2.0-debian-11-r1`;
- Redis chart `18.12.1`, using Redis image `7.2.4-debian-11-r5`;
- one UI Pod, one API Pod, and six ELS Pods;
- PostgreSQL on `1 CPU / 2Gi` request, `4Gi` memory limit, and a `32Gi`
  `managed-csi-premium` disk;
- Redis on `1 CPU / 1Gi` request, `2Gi` memory limit, and an `8Gi`
  `managed-csi-premium` disk;
- public UI, API, and ELS LoadBalancers open to Internet clients;
- the UI auto-discovery init container pinned to the chart's Kubernetes `1.26.6` client image in
  `bitnamilegacy/kubectl`, because that exact chart tag is unavailable from `bitnami/kubectl`;
- DAS, MongoDB, Kafka, and ingress disabled.

This is a disposable load-test configuration. FeatBit production deployments must use managed
external PostgreSQL and Redis. The values file schedules every application and data Pod onto the
tainted `workload=featbit` pool; omitting its node selector or toleration leaves Pods Pending.
Each ELS replica has a fixed `250m` CPU request and `1 CPU` limit, HPA is
disabled, and the replica count stays at six so CPU saturation is visible
instead of being hidden by scheduling or scaling changes. The lower request
is only a scheduler reservation needed to fit PostgreSQL, Redis, API, UI, and
one ELS on each D2 target node; the unchanged one-core limit preserves the
measured ELS execution ceiling.
This measures the capacity of a `6 × 1 vCPU-limit` ELS profile, not an
unlimited product ceiling. The
request reserves schedulable capacity, while the limit applies a cgroup quota; it does not promise
an exclusive physical core. Correlate latency with ELS CPU and CFS-throttling metrics.
PostgreSQL and Redis deliberately have no CPU limit: each reserves one core but may use spare target
node CPU, avoiding an artificial dependency-side CFS ceiling before ELS reaches its fixed limit.
This is headroom, not proof that they are out of the critical path; their metrics remain run
validity guardrails.

### Connect to the intended AKS context

The Azure Portal link does not change the local kubeconfig. Fetch the new context, select it
explicitly, and stop if the guard does not pass:

```powershell
$resourceGroup = terraform output -raw resource_group_name
$aksName = terraform output -raw aks_name
$aksContext = $aksName

az aks get-credentials `
  --resource-group $resourceGroup `
  --name $aksName `
  --overwrite-existing

kubectl config use-context $aksContext
$currentContext = (kubectl config current-context).Trim()
if ($currentContext -ne $aksContext) {
    throw "Expected context '$aksContext', found '$currentContext'."
}

kubectl --context $aksContext get nodes `
  -L agentpool,workload `
  -o wide

kubectl --context $aksContext get storageclass managed-csi-premium -o name
```

Expected pools are `system` (`1` node), `featbit` (`6` nodes), and `loadgen` (`10` nodes), and the
Premium Azure Disk storage class must exist. Continue to pass `--context` to `kubectl` and
`--kube-context` to Helm even after changing the default.

### Create the namespace and credentials

The checked-in
[`featbit-aks-internal.yaml`](../../values/featbit-aks-internal.yaml) contains only Secret
references. Generate per-cluster credentials and store them in Kubernetes; do not put their values
in Git, Terraform variables, Helm values, or command output:

```powershell
kubectl create namespace featbit --dry-run=client -o yaml |
  kubectl --context $aksContext apply -f -

$pgPassword = [Convert]::ToHexString(
    [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
).ToLowerInvariant()
$redisPassword = [Convert]::ToHexString(
    [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
).ToLowerInvariant()
$jwtKey = [Convert]::ToHexString(
    [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
).ToLowerInvariant()

kubectl --context $aksContext -n featbit create secret generic featbit-postgresql-auth `
  --from-literal=password=$pgPassword `
  --from-literal=postgres-password=$pgPassword `
  --dry-run=client -o yaml |
  kubectl --context $aksContext apply -f -

kubectl --context $aksContext -n featbit create secret generic featbit-redis-auth `
  --from-literal=redis-password=$redisPassword `
  --dry-run=client -o yaml |
  kubectl --context $aksContext apply -f -

kubectl --context $aksContext -n featbit create secret generic featbit-jwt-secret `
  --from-literal=jwt-key=$jwtKey `
  --dry-run=client -o yaml |
  kubectl --context $aksContext apply -f -

Remove-Variable pgPassword, redisPassword, jwtKey

kubectl --context $aksContext -n featbit get secret `
  featbit-postgresql-auth `
  featbit-redis-auth `
  featbit-jwt-secret `
  -o name
```

The PostgreSQL Secret has both `postgres-password` and `password` because the bundled chart uses
separate administrator and application-user keys. The Redis chart reads `redis-password`.

### Render and install the released chart

Use the released repository artifact for a reproducible test. Use the local chart path only when
intentionally testing unreleased chart changes.

This install profile assumes a fresh release. If `helm list --namespace featbit` or
`kubectl --context $aksContext -n featbit get pvc` shows an earlier deployment, stop and review it
before upgrading: StatefulSet volume-claim templates cannot switch an existing PVC to a different
storage class.

```powershell
$aksContext = (terraform output -raw aks_name).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($aksContext)) {
    throw "Cannot read aks_name from this Terraform stack."
}

$availableContexts = @(kubectl config get-contexts -o name)
if ($availableContexts -notcontains $aksContext) {
    $credentialsCommand = (terraform output -raw get_credentials_command).Trim()
    throw "kubectl context '$aksContext' is missing. Run: $credentialsCommand"
}

$featbitValues = (Resolve-Path ..\..\values\featbit-aks-internal.yaml).Path

$versionJson = kubectl --context $aksContext version -o json
if ($LASTEXITCODE -ne 0) {
    throw "Cannot reach Kubernetes through context '$aksContext'."
}
$kubeVersion = (($versionJson | ConvertFrom-Json).serverVersion.gitVersion -replace '^v', '')
if ($kubeVersion -notmatch '^\d+\.\d+\.\d+(?:[-+].*)?$') {
    throw "Kubernetes returned invalid server version '$kubeVersion'."
}

$requiredSecrets = @(
    "featbit-postgresql-auth",
    "featbit-redis-auth",
    "featbit-jwt-secret"
)
kubectl --context $aksContext -n featbit get secret @requiredSecrets -o name |
  Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "One or more required FeatBit Secrets are missing. Run the credential block above first."
}

helm repo add featbit https://featbit.github.io/featbit-charts/ --force-update
if ($LASTEXITCODE -ne 0) {
    throw "Failed to configure the FeatBit Helm repository."
}
helm repo update featbit
if ($LASTEXITCODE -ne 0) {
    throw "Failed to update the FeatBit Helm repository."
}
helm show chart featbit/featbit --version 0.9.13
if ($LASTEXITCODE -ne 0) {
    throw "FeatBit chart 0.9.13 is unavailable."
}

# Render first. This does not change the cluster.
helm template featbit featbit/featbit `
  --version 0.9.13 `
  --namespace featbit `
  --kube-version $kubeVersion `
  --values $featbitValues |
  Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "FeatBit Helm rendering failed; the cluster was not changed."
}

helm upgrade --install featbit featbit/featbit `
  --version 0.9.13 `
  --namespace featbit `
  --create-namespace `
  --kube-context $aksContext `
  --values $featbitValues `
  --atomic `
  --wait `
  --timeout 20m
if ($LASTEXITCODE -ne 0) {
    throw "FeatBit Helm installation failed and --atomic requested rollback."
}
```

The values intentionally create public Azure LoadBalancers without
`azure-load-balancer-internal` or a source-IP allowlist. UI, API, and ELS therefore receive public
external IPs reachable from any Internet source. This is only acceptable for the short-lived
dev/test cluster requested here: these endpoints use HTTP, and a fresh bundled database contains a
known bootstrap login. Change that password immediately, use only disposable environment-scoped
tokens, rotate them afterward, and destroy the stack promptly. For a durable or production
deployment, use HTTPS Ingress, Azure Front Door, or another TLS terminator and restore network
access controls before exposing FeatBit.

The released chart already packages its dependencies; `helm dependency build` is unnecessary. To
deploy the local working tree instead, first run
`helm dependency build C:\Code\featbit\featbit-charts\charts\featbit`, then replace
`featbit/featbit --version 0.9.13` with that chart directory in the install command.

### Verify placement and readiness

```powershell
helm status featbit `
  --namespace featbit `
  --kube-context $aksContext

kubectl --context $aksContext -n featbit wait `
  --for=condition=Ready pod `
  --all `
  --timeout=20m

kubectl --context $aksContext -n featbit get `
  deployments,statefulsets,pods,services,pvc `
  -o wide

kubectl --context $aksContext -n featbit get service `
  featbit-ui featbit-api featbit-els `
  -o 'custom-columns=NAME:.metadata.name,TYPE:.spec.type,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip,PORT:.spec.ports[0].port'

kubectl --context $aksContext -n featbit get deployment featbit-els `
  -o 'custom-columns=REPLICAS:.spec.replicas,CPU-REQUEST:.spec.template.spec.containers[0].resources.requests.cpu,CPU-LIMIT:.spec.template.spec.containers[0].resources.limits.cpu,MEMORY-LIMIT:.spec.template.spec.containers[0].resources.limits.memory'

kubectl --context $aksContext -n featbit get statefulset `
  -l app.kubernetes.io/instance=featbit `
  -o 'custom-columns=NAME:.metadata.name,CPU-REQUEST:.spec.template.spec.containers[0].resources.requests.cpu,CPU-LIMIT:.spec.template.spec.containers[0].resources.limits.cpu,MEMORY-REQUEST:.spec.template.spec.containers[0].resources.requests.memory,MEMORY-LIMIT:.spec.template.spec.containers[0].resources.limits.memory'

kubectl --context $aksContext -n featbit get pvc `
  -o 'custom-columns=NAME:.metadata.name,STORAGECLASS:.spec.storageClassName,SIZE:.spec.resources.requests.storage,STATUS:.status.phase'

foreach ($serviceName in @("featbit-ui", "featbit-api", "featbit-els")) {
    $service = (
        kubectl --context $aksContext -n featbit get service $serviceName -o json |
        ConvertFrom-Json
    )
    if ($service.spec.type -ne "LoadBalancer") {
        throw "$serviceName is '$($service.spec.type)', expected a public LoadBalancer."
    }
    if ($service.metadata.annotations.'service.beta.kubernetes.io/azure-load-balancer-internal' -eq "true") {
        throw "$serviceName is configured as an internal Azure LoadBalancer."
    }
    if ($service.metadata.annotations.'service.beta.kubernetes.io/azure-allowed-ip-ranges') {
        throw "$serviceName still has a source-IP allowlist."
    }
    if (-not $service.status.loadBalancer.ingress[0].ip) {
        throw "$serviceName does not have a public external IP."
    }
}
```

Confirm:

- UI and API each have one Ready Pod;
- ELS has `6/6` Ready Pods, distributed exactly one per each of the six `featbit` nodes;
- ELS reports `6`, `250m`, `1`, and `512Mi` for replicas, CPU request, CPU limit, and memory limit;
- PostgreSQL and Redis StatefulSets are Ready and have Bound PVCs;
- PostgreSQL reports `1`, `<none>`, `2Gi`, and `4Gi`; Redis reports `1`, `<none>`, `1Gi`, and
  `2Gi` for CPU request, CPU limit, memory request, and memory limit;
- their PVCs use `managed-csi-premium`, with `32Gi` for PostgreSQL and `8Gi` for Redis;
- no FeatBit, PostgreSQL, or Redis Pod is on `system` or `loadgen`;
- UI, API, and ELS are public `LoadBalancer` Services with assigned external IPs and no source-IP
  allowlist;
- PostgreSQL and Redis remain `ClusterIP` and have no external IP.

For a fresh bundled database, the chart's PostgreSQL init ConfigMap creates the schema. Chart
`0.9.13` introduces no schema migration. For an upgrade or reused PVC, review every intervening
file in the chart repository's `migration/` directory before running Helm because migrations are
not automatic.

The PVC storage class is immutable. If this release already has Bound PVCs from the earlier
configuration, a Helm upgrade does not move them to Premium disks. Export anything needed, then
recreate the disposable release/PVCs or use a new namespace; never delete a PVC that contains data
you intend to keep.

Treat the run as dependency-limited, not as an ELS capacity result, if any of these correlate with
the propagation-latency spike:

- PostgreSQL or Redis consumes sustained CPU beyond its reserved core while target-node CPU is
  saturated;
- either container approaches its memory limit, restarts, or is OOM-killed;
- PostgreSQL shows lock waits, slow commits, disk queueing, or elevated WAL/fsync latency;
- Redis shows command-latency spikes, rejected connections, blocked clients, or evictions.

### Verify flags and create the test access token

Finish all manual verification and credential setup before k6 warm-up. Do not use the UI or public
API during the measured window because that adds uncontrolled traffic to API, PostgreSQL, and ELS.

Read the three public endpoints:

```powershell
$uiIp = (
    kubectl --context $aksContext -n featbit get service featbit-ui `
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
).Trim()
$apiIp = (
    kubectl --context $aksContext -n featbit get service featbit-api `
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
).Trim()
$elsIp = (
    kubectl --context $aksContext -n featbit get service featbit-els `
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
).Trim()

"UI:  http://${uiIp}:8081"
"API: http://${apiIp}:5000"
"ELS: http://${elsIp}:5100"
```

Open the UI address from any Internet-connected workstation. A fresh bundled database uses
`test@featbit.com` / `123456`; immediately change that password at `/organization/profile`. Verify
the test environment and a feature flag manually before generating automation credentials.

Create a service token under **Integrations > Access Tokens**:

1. Name it for the run, for example `k6-growth-controller`.
2. Limit it to the load-test project/environment.
3. Grant feature-flag read/list, create, archive, delete, and targeting-update permissions. Granting
   all feature-flag actions is acceptable only when the token is restricted to this disposable
   environment.
4. Copy the `api-...` value when it is first shown; FeatBit masks it after leaving the page. Never
   paste it into a values file, Terraform state, Git, a report, or chat.

Service-token permissions are fixed after creation. If the scope is wrong, delete the token and
create a new least-privilege one instead of broadening the deployment around it.

Apply the AKS load-test base manifest and use the context-aware credential helpers in the parent
[AKS runbook](../../README-AKS.md#6-配置测试凭据与-controller). They prompt for both the OpenAPI
token and the environment's Server SDK secret as `SecureString`, resolve the selected environment,
and create the four ConfigMap/Secret objects without putting credential values in Git or native
process arguments. Always pass `-KubeContext aks-featbit-load-testing`; omitting it deliberately
targets the local `docker-desktop` default.

In-cluster k6 continues to use
`http://featbit-api.featbit.svc.cluster.local:5000` and
`ws://featbit-els.featbit.svc.cluster.local:5100`; load-test traffic does not traverse the public
LoadBalancers. These addresses are explicit in the AKS TestRun runner environment and override
duplicate `envFrom` values, so the public endpoints remain browser-only. Rotate the service token
and destroy the cluster after evidence collection.

## Build the k6 image

```powershell
$acrName = terraform output -raw acr_name
$gitSha = (git -C ..\..\.. rev-parse --short=12 HEAD).Trim()

az acr build `
  --registry $acrName `
  --image "featbit-k6:$gitSha" `
  --file ..\..\Dockerfile.k6 `
  ..\..\..
```

Record the resulting image digest, Terraform outputs, `terraform.tfvars`, and AKS node inventory
with the test result. Do not store credentials in Terraform variables or outputs.

## Check current VM prices

The helper queries Microsoft's unauthenticated Azure Retail Prices API and excludes Windows, Spot,
and Low Priority meters:

```powershell
.\get-vm-prices.ps1 -Location eastasia | Format-Table -AutoSize
.\get-vm-prices.ps1 -Location southeastasia | Format-Table -AutoSize
```

Retail prices exclude discounts and most non-VM charges. Confirm quota and SKU availability
separately before applying.

## Destroy after a test

First copy JSON/HTML reports and monitoring evidence outside AKS and its ephemeral ACR. Then review
the exact destroy plan and remove the stack. The bundled PostgreSQL/Redis PVC data is also deleted
with AKS, so export anything that must survive before continuing:

```powershell
$resourceGroup = terraform output -raw resource_group_name
$nodeResourceGroup = terraform output -raw node_resource_group

terraform plan -destroy -out featbit-aks-destroy.tfplan
terraform apply featbit-aks-destroy.tfplan
```

With the checked-in `create_resource_group = false` setting, Terraform removes the AKS resource,
ACR, role assignment, and AKS-managed node group but preserves the existing `featbit-devtest`
resource group and any unrelated resources in it. Never manually add resources to
`featbit-devtest-nodes`.

After destruction, verify that the main group remains and the AKS-managed node group is gone:

```powershell
az group exists --name $resourceGroup
az group exists --name $nodeResourceGroup
```

The expected output is `true` for `featbit-devtest` and `false` for `featbit-devtest-nodes`. Capture
the names before applying the destroy plan because the outputs are removed from state after a
successful destroy. If `create_resource_group = true`, both outputs should instead be `false`.

## Official references

- [AzureRM AKS resource](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster)
- [AzureRM AKS node pool resource](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster_node_pool)
- [AKS resource-group behavior](https://learn.microsoft.com/azure/aks/faq#why-are-two-resource-groups-created-with-aks)
- [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)
- [AKS baseline architecture](https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks)
- [AKS public Standard LoadBalancer and allowed IP ranges](https://learn.microsoft.com/azure/aks/configure-load-balancer-standard#restrict-inbound-traffic-to-specific-ip-ranges)
- [AKS Azure Disk storage classes](https://learn.microsoft.com/azure/aks/create-volume-azure-disk)
- [FeatBit Helm chart](https://github.com/featbit/featbit-charts)
- [FeatBit API access tokens](https://docs.featbit.co/integrations/api-access-tokens)
- [Bitnami PostgreSQL chart](https://github.com/bitnami/charts/tree/main/bitnami/postgresql)
- [Bitnami Redis chart](https://github.com/bitnami/charts/tree/main/bitnami/redis)
