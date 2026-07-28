[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^aks-featbit-load-testing$")]
    [string] $KubeContext,

    [Parameter(Mandatory)]
    [string] $MatrixPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Read-KubectlJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $FailureMessage,
        [switch] $AllowNotFound
    )

    $text = (& kubectl @Arguments 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0) {
        if ($AllowNotFound) {
            return $null
        }
        throw $FailureMessage
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw $FailureMessage
    }
    return $text | ConvertFrom-Json
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext
$resolvedMatrixPath = (
    $ExecutionContext.SessionState.Path.
        GetUnresolvedProviderPathFromPSPath($MatrixPath)
)
if (-not (Test-Path -LiteralPath $resolvedMatrixPath -PathType Leaf)) {
    throw "Large flag-set matrix does not exist: $resolvedMatrixPath"
}
$matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath | ConvertFrom-Json
$collectorProperty = $matrix.PSObject.Properties["evidence"]
if (
    $null -eq $collectorProperty -or
    $null -eq $collectorProperty.Value.PSObject.Properties[
        "additionalCollector"
    ]
) {
    [pscustomobject]@{
        MatrixId = [string]$matrix.matrixId
        Required = $false
        Reused = $false
        CollectorPods = 0
        DeletedResources = 0
    }
    return
}

$collector = $matrix.evidence.additionalCollector
$sourceRunId = [string]$collector.sourceRunId
$daemonSetName = [string]$collector.daemonSetName
$expectedNodeCount = [int]$collector.expectedNodeCount
$namespace = $script:LoadTestNamespace
if (
    $sourceRunId -notmatch "^growth-[a-z0-9-]+$" -or
    $daemonSetName -notmatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" -or
    $expectedNodeCount -ne (
        [int]$collector.featbitNodes +
        [int]$collector.loadgenNodes
    )
) {
    throw "The additional one-second evidence collector contract is invalid."
}

$daemonSet = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", $namespace,
        "get", "daemonset", $daemonSetName,
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect DaemonSet '$daemonSetName'." `
    -AllowNotFound
$configMap = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", $namespace,
        "get", "configmap", $daemonSetName,
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect ConfigMap '$daemonSetName'." `
    -AllowNotFound

if (($null -eq $daemonSet) -xor ($null -eq $configMap)) {
    throw (
        "Additional evidence resources are incomplete; refusing to replace " +
        "or delete the surviving object."
    )
}
if ($null -eq $daemonSet) {
    return & (Join-Path $PSScriptRoot "start-aks-1s-evidence.ps1") `
        -RunId $sourceRunId `
        -KubeContext $targetContext `
        -ExpectedFeatBitNodes ([int]$collector.featbitNodes) `
        -ExpectedLoadgenNodes ([int]$collector.loadgenNodes) `
        -ExpectedElsPods ([int]$matrix.fixedInfrastructure.elsReplicas) `
        -ExpectedElsNodes ([int]$matrix.fixedInfrastructure.elsReplicas) `
        -CollectorName $daemonSetName `
        -FeatBitWorkload ([string]$collector.featbitWorkload) `
        -LoadgenWorkload ([string]$collector.loadgenWorkload) `
        -PreserveOnFailure
}

$ownerRunId = [string](
    $daemonSet.metadata.labels."loadtest.featbit.io/run-id"
)
if (
    $ownerRunId -cne $sourceRunId -or
    [int]$daemonSet.status.desiredNumberScheduled -ne $expectedNodeCount -or
    [int]$daemonSet.status.numberReady -ne $expectedNodeCount -or
    [string]$configMap.metadata.labels."loadtest.featbit.io/run-id" -cne
        $sourceRunId -or
    [string]::IsNullOrWhiteSpace(
        [string]$configMap.data."collect-aks-node-evidence.sh"
    )
) {
    throw (
        "Existing additional evidence collector is not the canonical " +
        "'$sourceRunId' deployment; it was not changed."
    )
}

[pscustomobject]@{
    MatrixId = [string]$matrix.matrixId
    Required = $true
    RunId = $sourceRunId
    CollectorName = $daemonSetName
    Reused = $true
    CollectorPods = [int]$daemonSet.status.numberReady
    SampleIntervalSeconds = 1
    DeletedResources = 0
}
