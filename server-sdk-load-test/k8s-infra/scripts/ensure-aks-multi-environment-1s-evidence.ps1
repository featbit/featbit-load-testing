[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $KubeContext
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$targetContext = $KubeContext.Trim()
$continuousRunId = "growth-menv-continuous"
$namespace = $script:LoadTestNamespace
$daemonSetName = "featbit-1s-evidence"

Assert-KubernetesContext -KubeContext $targetContext

$daemonSetText = (
    & kubectl --context $targetContext `
        -n $namespace `
        get daemonset $daemonSetName `
        -o json 2>$null |
        Out-String
)
if ($LASTEXITCODE -ne 0) {
    $result = & (Join-Path $PSScriptRoot "start-aks-1s-evidence.ps1") `
        -RunId $continuousRunId `
        -KubeContext $targetContext `
        -ExpectedFeatBitNodes 3 `
        -ExpectedLoadgenNodes 10 `
        -ExpectedElsPods 3 `
        -ExpectedElsNodes 3 `
        -PreserveOnFailure
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the continuous one-second evidence collector."
    }
    return $result
}

$daemonSet = $daemonSetText | ConvertFrom-Json
$ownerRunId = [string]$daemonSet.metadata.labels."loadtest.featbit.io/run-id"
if ($ownerRunId -cne $continuousRunId) {
    throw (
        "DaemonSet '$daemonSetName' belongs to '$ownerRunId', not the " +
        "multi-environment continuous collector. It was not changed."
    )
}
if (
    [int]$daemonSet.status.desiredNumberScheduled -ne 13 -or
    [int]$daemonSet.status.numberReady -ne 13
) {
    throw (
        "The continuous one-second collector is not complete: desired=" +
        "$($daemonSet.status.desiredNumberScheduled), " +
        "ready=$($daemonSet.status.numberReady)."
    )
}

$configMapText = (
    & kubectl --context $targetContext `
        -n $namespace `
        get configmap $daemonSetName `
        -o json |
        Out-String
)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($configMapText)) {
    throw "The continuous one-second collector ConfigMap is missing."
}
$configMap = $configMapText | ConvertFrom-Json
if (
    [string]$configMap.metadata.labels."loadtest.featbit.io/run-id" -cne
        $continuousRunId -or
    [string]::IsNullOrWhiteSpace(
        [string]$configMap.data."collect-aks-node-evidence.sh"
    )
) {
    throw "The continuous one-second collector ConfigMap is not canonical."
}

[pscustomobject]@{
    RunId = $continuousRunId
    Reused = $true
    CollectorPods = [int]$daemonSet.status.numberReady
    SampleIntervalSeconds = 1
    DeletedResources = 0
}
