# Ephemeral AKS Terraform stack

This stack creates the Azure infrastructure used by a temporary FeatBit load-test environment:

- one AKS Free-tier control plane with a small, tainted system pool;
- a tainted target pool shared by FeatBit UI, API, and ELS Pods;
- a tainted loadgen pool with two nodes by default;
- an ephemeral ACR and the kubelet `AcrPull` role assignment;
- OIDC Workload Identity and the optional Key Vault CSI add-on.

The checked-in example reuses the existing `featbit-devtest` resource group and preserves that
group on `terraform destroy`. AKS always spans two resource groups: the AKS resource and ACR go into
`featbit-devtest`, while Azure creates `featbit-devtest-nodes` for VM scale sets, networking, and
managed disks. Azure deletes the node resource group with the cluster. It cannot be the same as the
main resource group and must not already exist.

It intentionally does not install Kubernetes/Helm resources in the same Terraform apply. HashiCorp
recommends managing a newly created cluster and in-cluster resources in separate apply operations.
After this stack is ready, follow the parent [AKS runbook](../../README-AKS.md) to install the k6
Operator and FeatBit.

## Default topology

| Pool | Default | Purpose |
| --- | --- | --- |
| `system` | `1 × Standard_D2ds_v5` | Temporary AKS system services |
| `featbit` | `2 × Standard_D4ds_v5` | UI/API plus three ELS Pods |
| `loadgen` | `2 × Standard_D4ds_v5` | Two k6 runners, one per node |

Three ELS replicas do not require three target nodes. The two-node default is the cost-oriented
rehearsal topology; set `target_node_count = 3` when one ELS replica per node or three failure
domains are part of the test contract.

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

The local state is suitable for a manual ephemeral run. CI should use a remote backend that lives
outside AKS. Do not store the backend in the AKS-managed node resource group because that group is
deleted with the cluster.

The `featbit-devtest` resource group's own metadata location can remain `westus3`; `location =
"eastasia"` independently places AKS and ACR in East Asia. To create a dedicated main group instead,
set `create_resource_group = true` and choose an unused `resource_group_name`.

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
the exact destroy plan and remove the stack:

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
