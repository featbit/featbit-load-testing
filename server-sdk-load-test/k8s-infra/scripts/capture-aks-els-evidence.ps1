[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [string] $RunId,

    [Parameter(Mandatory)]
    [string] $KubeContext,

    [string] $OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Invoke-KubectlJsonText {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter(Mandatory)]
        [string] $FailureMessage
    )

    $value = (& kubectl @Arguments | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw $FailureMessage
    }

    $null = $value | ConvertFrom-Json
    return $value
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext

$repositoryRoot = Get-RepositoryRoot
$resultsDirectory = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path $repositoryRoot "results"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputDirectory
    )
}
$null = New-Item -ItemType Directory -Force -Path $resultsDirectory

$deploymentText = Invoke-KubectlJsonText `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit",
        "get", "deployment", "featbit-els",
        "-o", "json"
    ) `
    -FailureMessage "Failed to capture the FeatBit ELS deployment."
$podsText = Invoke-KubectlJsonText `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit",
        "get", "pods",
        "-l", "app.kubernetes.io/component=els",
        "-o", "json"
    ) `
    -FailureMessage "Failed to capture the FeatBit ELS pods."

$deployment = $deploymentText | ConvertFrom-Json
$pods = ($podsText | ConvertFrom-Json).items
$desiredReplicas = [int]$deployment.spec.replicas
$readyReplicas = [int]$deployment.status.readyReplicas
$readyPods = @($pods | Where-Object {
    $_.status.phase -eq "Running" -and
    @($_.status.containerStatuses | Where-Object ready).Count -eq
        @($_.status.containerStatuses).Count
})
if (
    $desiredReplicas -lt 1 -or
    $readyReplicas -ne $desiredReplicas -or
    $readyPods.Count -ne $desiredReplicas
) {
    throw (
        "ELS is not fully ready: desired=$desiredReplicas, " +
        "deploymentReady=$readyReplicas, readyPods=$($readyPods.Count)."
    )
}

$deploymentPath = Join-Path $resultsDirectory "$RunId-els-deployment.json"
$podsPath = Join-Path $resultsDirectory "$RunId-els-pods.json"
foreach ($path in @($deploymentPath, $podsPath)) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        throw "Refusing to overwrite existing ELS evidence: $path"
    }
}

$utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($deploymentPath, $deploymentText, $utf8NoBom)
[IO.File]::WriteAllText($podsPath, $podsText, $utf8NoBom)

[pscustomobject]@{
    RunId = $RunId
    Image = [string]$deployment.spec.template.spec.containers[0].image
    DesiredReplicas = $desiredReplicas
    ReadyReplicas = $readyReplicas
    Nodes = @($pods.spec.nodeName | Sort-Object -Unique)
    ImageIds = @(
        $pods.status.containerStatuses.imageID |
        Sort-Object -Unique
    )
    DeploymentPath = $deploymentPath
    PodsPath = $podsPath
}
