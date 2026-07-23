[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $KubeContext,

    [string] $OperatorChartVersion = "4.5.0"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext
Assert-CommandAvailable -Name "helm"

$nodeJson = (& kubectl --context $targetContext get nodes -o json | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read nodes from '$targetContext'."
}
$nodes = ($nodeJson | ConvertFrom-Json).items
$loadgenNodes = @($nodes | Where-Object {
    $_.metadata.labels.workload -eq "loadgen"
})
if ($loadgenNodes.Count -lt 2) {
    throw "Expected at least two nodes labelled workload=loadgen; found $($loadgenNodes.Count)."
}

foreach ($node in $loadgenNodes) {
    $hasRequiredTaint = @($node.spec.taints | Where-Object {
        $_.key -eq "workload" -and
        $_.value -eq "loadgen" -and
        $_.effect -eq "NoSchedule"
    }).Count -gt 0
    if (-not $hasRequiredTaint) {
        throw "Loadgen node '$($node.metadata.name)' is missing workload=loadgen:NoSchedule."
    }
}

Write-Host "Installing k6 Operator chart $OperatorChartVersion on loadgen nodes ..."
$helmRepositoryUrl = "https://grafana.github.io/helm-charts"
$helmWorkspace = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "featbit-k6-helm-$([Guid]::NewGuid().ToString('N'))"
$helmRepositoryCache = Join-Path $helmWorkspace "repository"
$helmRepositoryConfig = Join-Path $helmWorkspace "repositories.yaml"
$helmWorkspaceCreated = $false

try {
    New-Item -ItemType Directory -Path $helmRepositoryCache -Force | Out-Null
    $helmWorkspaceCreated = $true

    # Use an isolated repository config so stale indexes in the user's global
    # Helm cache cannot break this reproducible bootstrap.
    & helm repo add grafana $helmRepositoryUrl `
        --force-update `
        --repository-config $helmRepositoryConfig `
        --repository-cache $helmRepositoryCache
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to prepare the isolated Grafana Helm repository."
    }

    & helm upgrade --install k6-operator grafana/k6-operator `
        --version $OperatorChartVersion `
        --namespace k6-operator-system `
        --create-namespace `
        --set "namespace.create=false" `
        --set "nodeSelector.workload=loadgen" `
        --set "tolerations[0].key=workload" `
        --set "tolerations[0].operator=Equal" `
        --set "tolerations[0].value=loadgen" `
        --set "tolerations[0].effect=NoSchedule" `
        --kube-context $targetContext `
        --repository-config $helmRepositoryConfig `
        --repository-cache $helmRepositoryCache `
        --atomic `
        --wait `
        --timeout 10m
    if ($LASTEXITCODE -ne 0) {
        throw "k6 Operator installation failed."
    }
}
finally {
    if ($helmWorkspaceCreated -and (Test-Path -LiteralPath $helmWorkspace)) {
        $resolvedWorkspace = [IO.Path]::GetFullPath($helmWorkspace)
        $resolvedTempRoot = Split-Path -Parent (
            Join-Path ([IO.Path]::GetTempPath()) "path-safety-check"
        )
        $resolvedParent = Split-Path -Parent $resolvedWorkspace
        $workspaceName = Split-Path -Leaf $resolvedWorkspace
        $isExpectedWorkspace = (
            [string]::Equals(
                $resolvedParent,
                $resolvedTempRoot,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            $workspaceName.StartsWith(
                "featbit-k6-helm-",
                [StringComparison]::OrdinalIgnoreCase
            )
        )

        if ($isExpectedWorkspace) {
            Remove-Item -LiteralPath $resolvedWorkspace -Recurse -Force
        }
        else {
            Write-Warning "Skipped cleanup of unexpected Helm workspace '$resolvedWorkspace'."
        }
    }
}

$baseManifest = Join-Path $PSScriptRoot "..\manifests\aks-loadtest-base.yaml"
& kubectl --context $targetContext apply -f $baseManifest
if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply the AKS load-test base manifest."
}

& kubectl --context $targetContext -n featbit-loadtest wait `
    --for=condition=Ready pod/results-reader `
    --timeout=5m
if ($LASTEXITCODE -ne 0) {
    throw "results-reader did not become Ready."
}

& kubectl --context $targetContext get crd testruns.k6.io -o name
if ($LASTEXITCODE -ne 0) {
    throw "The TestRun CRD is unavailable after installing k6 Operator."
}

$operatorPods = (
    & kubectl --context $targetContext -n k6-operator-system get pods -o json |
    ConvertFrom-Json
).items
$readerPod = (
    & kubectl --context $targetContext -n featbit-loadtest get pod results-reader -o json |
    ConvertFrom-Json
)
$nodeWorkload = @{}
foreach ($node in $nodes) {
    $nodeWorkload[$node.metadata.name] = $node.metadata.labels.workload
}

$misplacedPods = @(
    @($operatorPods) + @($readerPod) |
    Where-Object {
        [string]::IsNullOrWhiteSpace($_.spec.nodeName) -or
        $nodeWorkload[$_.spec.nodeName] -ne "loadgen"
    } |
    ForEach-Object { $_.metadata.name }
)
if ($misplacedPods.Count -gt 0) {
    throw "k6 bootstrap Pods are not on loadgen nodes: $($misplacedPods -join ', ')."
}

Write-Host ""
Write-Host "AKS k6 bootstrap completed." -ForegroundColor Green
Write-Host "Kubernetes context: $targetContext"
Write-Host "Loadgen nodes: $($loadgenNodes.metadata.name -join ', ')"
& kubectl --context $targetContext -n k6-operator-system get pods -o wide
& kubectl --context $targetContext -n featbit-loadtest get pod,pvc -o wide
