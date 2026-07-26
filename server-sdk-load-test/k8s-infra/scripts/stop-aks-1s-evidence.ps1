[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [ValidateLength(1, 63)]
    [string] $RunId,

    [Parameter(Mandatory)]
    [string] $KubeContext
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext

$daemonSetText = (
    & kubectl --context $targetContext `
        -n $script:LoadTestNamespace `
        get daemonset featbit-1s-evidence `
        -o json |
        Out-String
)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($daemonSetText)) {
    throw "The 1-second evidence DaemonSet does not exist."
}
$daemonSet = $daemonSetText | ConvertFrom-Json
$actualRunId = [string]$daemonSet.metadata.labels."loadtest.featbit.io/run-id"
if ($actualRunId -cne $RunId) {
    throw (
        "Refusing to stop evidence for '$RunId'; the active collector " +
        "belongs to '$actualRunId'."
    )
}

& kubectl --context $targetContext `
    -n $script:LoadTestNamespace `
    delete daemonset featbit-1s-evidence `
    --wait=true `
    --timeout=5m
if ($LASTEXITCODE -ne 0) {
    throw "Failed to stop the 1-second evidence DaemonSet."
}

& kubectl --context $targetContext `
    -n $script:LoadTestNamespace `
    delete configmap featbit-1s-evidence `
    --ignore-not-found=true
if ($LASTEXITCODE -ne 0) {
    throw "Failed to remove the 1-second evidence ConfigMap."
}

$evidenceFiles = @()
& kubectl --context $targetContext `
    -n $script:LoadTestNamespace `
    get pod results-reader -o name *> $null
if ($LASTEXITCODE -eq 0) {
    $fileText = (
        & kubectl --context $targetContext `
            -n $script:LoadTestNamespace `
            exec results-reader `
            -- sh -c "ls -1 /results/$RunId-node-*-1s.tsv 2>/dev/null" |
            Out-String
    ).Trim()
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($fileText)) {
        $evidenceFiles = @($fileText -split "\r?\n" | Where-Object { $_ })
    }
}

[pscustomobject]@{
    RunId = $RunId
    Stopped = $true
    EvidenceFileCount = $evidenceFiles.Count
    EvidenceFiles = $evidenceFiles
}
