[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^aks-featbit-load-testing$")]
    [string] $KubeContext,

    [ValidatePattern("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")]
    [string] $CollectorName = "featbit-1s-evidence"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Read-KubectlJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $FailureMessage
    )

    $text = (& kubectl @Arguments | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        throw $FailureMessage
    }
    return $text | ConvertFrom-Json
}

function Test-PodReady {
    param([Parameter(Mandatory)][object] $Pod)

    $statuses = @($Pod.status.containerStatuses)
    return (
        $Pod.status.phase -eq "Running" -and
        $statuses.Count -eq 1 -and
        $statuses[0].ready -eq $true
    )
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext
$namespace = $script:LoadTestNamespace
$daemonSet = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", $namespace,
        "get", "daemonset", $CollectorName,
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect collector DaemonSet '$CollectorName'."
$configMap = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", $namespace,
        "get", "configmap", $CollectorName,
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect collector ConfigMap '$CollectorName'."
$ownerRunId = [string](
    $daemonSet.metadata.labels."loadtest.featbit.io/run-id"
)
if (
    [string]::IsNullOrWhiteSpace($ownerRunId) -or
    [string]$configMap.metadata.labels."loadtest.featbit.io/run-id" -cne
        $ownerRunId -or
    [string]::IsNullOrWhiteSpace(
        [string]$configMap.data."collect-aks-node-evidence.sh"
    ) -or
    [int]$daemonSet.status.desiredNumberScheduled -ne 13
) {
    throw (
        "Collector ownership, script, or 13-node contract is invalid; " +
        "the ConfigMap was not changed."
    )
}

$elsPods = @(
    (
        Read-KubectlJson `
            -Arguments @(
                "--context", $targetContext,
                "-n", "featbit",
                "get", "pods",
                "-l", "app.kubernetes.io/component=els",
                "-o", "json"
            ) `
            -FailureMessage "Failed to inspect current ELS Pods."
    ).items
)
$readyElsPods = @($elsPods | Where-Object { Test-PodReady -Pod $_ })
$elsNodes = @($readyElsPods.spec.nodeName | Sort-Object -Unique)
if (
    $elsPods.Count -ne 3 -or
    $readyElsPods.Count -ne 3 -or
    $elsNodes.Count -ne 3
) {
    throw (
        "Expected three ready ELS Pods on three nodes; the collector " +
        "mapping was not changed."
    )
}

$mapLines = @(
    foreach ($pod in $readyElsPods) {
        $statuses = @(
            $pod.status.containerStatuses |
                Where-Object name -eq "featbit-els"
        )
        if ($statuses.Count -ne 1) {
            throw (
                "Expected one featbit-els container status for " +
                "Pod '$($pod.metadata.name)'."
            )
        }
        $containerId = [string]$statuses[0].containerID
        if ($containerId -notmatch "^containerd://([0-9a-f]{64})$") {
            throw (
                "ELS Pod '$($pod.metadata.name)' has an invalid " +
                "containerd ID."
            )
        }
        (
            "{0}|{1}|{2}" -f
            [string]$pod.spec.nodeName,
            [string]$pod.metadata.name,
            $Matches[1]
        )
    }
) | Sort-Object
$expectedMap = ($mapLines -join "`n") + "`n"
$currentMap = [string]$configMap.data."els-map"
if ($currentMap -ceq $expectedMap) {
    [pscustomobject]@{
        CollectorName = $CollectorName
        OwnerRunId = $ownerRunId
        Updated = $false
        ElsMappings = $mapLines.Count
        ResourcesDeleted = 0
    }
    return
}

$patch = [ordered]@{
    data = [ordered]@{
        "els-map" = $expectedMap
    }
} | ConvertTo-Json -Depth 4 -Compress
& kubectl --context $targetContext `
    -n $namespace `
    patch configmap $CollectorName `
    --type merge `
    -p $patch *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to update collector ConfigMap '$CollectorName'."
}

[pscustomobject]@{
    CollectorName = $CollectorName
    OwnerRunId = $ownerRunId
    Updated = $true
    ElsMappings = $mapLines.Count
    ResourcesDeleted = 0
}
