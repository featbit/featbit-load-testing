[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("validation", "formal")]
    [string] $RunKind,

    [Parameter(Mandatory)]
    [string] $KubeContext,

    [Parameter(Mandatory)]
    [string] $RunnerImage,

    [string] $MatrixPath = "",

    [string] $OutputDirectory = "",

    [string] $Note = "",

    [switch] $TopologyOnly
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

function Assert-DigestPinnedImage {
    param([Parameter(Mandatory)][string] $Image)

    $normalized = $Image.Trim()
    if (
        $normalized -notmatch "^[A-Za-z0-9._:/-]+@sha256:[a-fA-F0-9]{64}$" -or
        $normalized -notmatch "/"
    ) {
        throw (
            "RunnerImage must be an immutable registry/repository@sha256:" +
            "<64-hex-digest> reference."
        )
    }
    return $normalized
}

function Test-PodReady {
    param([Parameter(Mandatory)][object] $Pod)

    $statuses = @($Pod.status.containerStatuses)
    return (
        $Pod.status.phase -eq "Running" -and
        $statuses.Count -gt 0 -and
        @($statuses | Where-Object ready).Count -eq $statuses.Count
    )
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext

$repositoryRoot = Get-RepositoryRoot
$resolvedMatrixPath = if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
    Join-Path $repositoryRoot "k8s-infra\matrices\aks-multi-environment-g5-d4-els3.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MatrixPath)
}
if (-not (Test-Path -LiteralPath $resolvedMatrixPath -PathType Leaf)) {
    throw "Multi-environment matrix does not exist: $resolvedMatrixPath"
}
$matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath | ConvertFrom-Json
if ($matrix.schemaVersion -ne 1) {
    throw "Multi-environment matrix schemaVersion must be 1."
}
if ([string]$matrix.kubernetesContext -cne $targetContext) {
    throw (
        "Matrix context '$($matrix.kubernetesContext)' does not match " +
        "'$targetContext'."
    )
}

$normalizedRunnerImage = Assert-DigestPinnedImage -Image $RunnerImage
$parallelism = [int]$matrix.parallelism
$connectionsPerRunner = [int]$matrix.connectionsPerRunner
$environmentCount = [int]$matrix.environmentCount
$perEnvironmentPerRunner = [int]$matrix.connectionsPerEnvironmentPerRunner
$totalConnections = [int]$matrix.totalConnections
if (
    $parallelism -ne 20 -or
    $connectionsPerRunner -ne 500 -or
    $environmentCount -ne 100 -or
    $perEnvironmentPerRunner -ne 5 -or
    $connectionsPerRunner * $parallelism -ne $totalConnections -or
    $connectionsPerRunner / $environmentCount -ne $perEnvironmentPerRunner -or
    $perEnvironmentPerRunner * $parallelism -ne [int]$matrix.connectionsPerEnvironment
) {
    throw "Matrix does not satisfy the fixed 20 x 500 / 100 x 100 topology."
}

$nodes = Read-KubectlJson `
    -Arguments @("--context", $targetContext, "get", "nodes", "-o", "json") `
    -FailureMessage "Failed to inspect AKS nodes."
$readyNodes = @($nodes.items | Where-Object {
    ($_.status.conditions | Where-Object type -eq "Ready").status -eq "True"
})
$featbitNodes = @($readyNodes | Where-Object {
    $_.metadata.labels.workload -eq "featbit"
})
$loadgenNodes = @($readyNodes | Where-Object {
    $_.metadata.labels.workload -eq "loadgen"
})
if (
    $featbitNodes.Count -ne [int]$matrix.fixedInfrastructure.featbitNodes -or
    @($featbitNodes | Where-Object {
        $_.metadata.labels."node.kubernetes.io/instance-type" -cne
            [string]$matrix.fixedInfrastructure.featbitNodeVmSize
    }).Count -ne 0
) {
    throw "FeatBit node count or VM size differs from the fixed matrix."
}
if (
    $loadgenNodes.Count -ne [int]$matrix.fixedInfrastructure.loadgenNodes -or
    @($loadgenNodes | Where-Object {
        $_.metadata.labels."node.kubernetes.io/instance-type" -cne
            [string]$matrix.fixedInfrastructure.loadgenNodeVmSize
    }).Count -ne 0
) {
    throw "Loadgen node count or VM size differs from the fixed matrix."
}

$elsDeployment = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit",
        "get", "deployment", "featbit-els",
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect the ELS deployment."
$elsResources = $elsDeployment.spec.template.spec.containers[0].resources
if (
    [int]$elsDeployment.spec.replicas -ne
        [int]$matrix.fixedInfrastructure.elsReplicas -or
    [int]$elsDeployment.status.readyReplicas -ne
        [int]$matrix.fixedInfrastructure.elsReplicas -or
    [string]$elsResources.requests.cpu -cne
        [string]$matrix.fixedInfrastructure.elsResources.cpuRequest -or
    [string]$elsResources.limits.cpu -cne
        [string]$matrix.fixedInfrastructure.elsResources.cpuLimit -or
    [string]$elsResources.requests.memory -cne
        [string]$matrix.fixedInfrastructure.elsResources.memoryRequest -or
    [string]$elsResources.limits.memory -cne
        [string]$matrix.fixedInfrastructure.elsResources.memoryLimit
) {
    throw "ELS replicas or resources differ from the fixed matrix."
}
$elsPods = (Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit",
        "get", "pods",
        "-l", "app.kubernetes.io/component=els",
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect ELS Pods.").items
$readyElsPods = @($elsPods | Where-Object { Test-PodReady -Pod $_ })
$elsNodes = @($readyElsPods.spec.nodeName | Sort-Object -Unique)
if ($readyElsPods.Count -ne 3 -or $elsNodes.Count -ne 3) {
    throw "Expected three ready ELS Pods spread one per FeatBit node."
}

$hpa = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit",
        "get", "hpa",
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect FeatBit HPAs."
if (@($hpa.items).Count -ne 0) {
    throw "FeatBit HPA resources must be absent for the fixed experiment."
}

foreach ($object in @(
    @{ Namespace = "featbit-loadtest"; Kind = "persistentvolumeclaim"; Name = "featbit-k6-results" }
    @{ Namespace = "featbit-loadtest"; Kind = "pod"; Name = "results-reader" }
    @{ Namespace = "featbit-loadtest"; Kind = "secret"; Name = "featbit-k6-controller-secret" }
    @{ Namespace = "default"; Kind = "customresourcedefinition"; Name = "testruns.k6.io" }
)) {
    Assert-KubernetesObjectExists `
        -Kind $object.Kind `
        -Name $object.Name `
        -Namespace $object.Namespace `
        -KubeContext $targetContext
}

$config = if ($TopologyOnly) {
    [pscustomobject]@{
        data = [pscustomobject]@{
            EXPECTED_ENVIRONMENT_COUNT = "100"
            EXPECTED_CONNECTIONS_PER_ENVIRONMENT_PER_RUNNER = "5"
            FEATBIT_ENVIRONMENT_ID = "00000000-0000-0000-0000-000000000001"
            TARGET_ENVIRONMENT_KEY = (
                "{0}{1:D3}" -f
                [string]$matrix.environmentPrefix,
                [int]$matrix.targetEnvironmentIndex
            )
            PROBE_FLAG_KEYS = (
                "{0}{1:D2}" -f
                [string]$matrix.flagPrefix,
                [int]$matrix.measuredFlagIndex
            )
            POST_RAMP_WARMUP_FLAG_KEY = (
                "{0}{1:D2}" -f
                [string]$matrix.flagPrefix,
                [int]$matrix.postRampWarmupFlagIndex
            )
            EXPECTED_REVISIONS = (@($matrix.expectedRevisions) -join ",")
            INVENTORY_SHA256 = "topology-only-not-provisioned"
        }
    }
}
else {
    foreach ($object in @(
        @{ Kind = "configmap"; Name = [string]$matrix.kubernetesObjects.configMap }
        @{ Kind = "secret"; Name = [string]$matrix.kubernetesObjects.secret }
    )) {
        Assert-KubernetesObjectExists `
            -Kind $object.Kind `
            -Name $object.Name `
            -KubeContext $targetContext
    }
    Read-KubectlJson `
        -Arguments @(
            "--context", $targetContext,
            "-n", "featbit-loadtest",
            "get", "configmap", [string]$matrix.kubernetesObjects.configMap,
            "-o", "json"
        ) `
        -FailureMessage "Failed to inspect the multi-environment ConfigMap."
}
if (
    [string]$config.data.EXPECTED_ENVIRONMENT_COUNT -cne "100" -or
    [string]$config.data.EXPECTED_CONNECTIONS_PER_ENVIRONMENT_PER_RUNNER -cne "5" -or
    [string]$config.data.PROBE_FLAG_KEYS -cne
        ("{0}{1:D2}" -f $matrix.flagPrefix, [int]$matrix.measuredFlagIndex) -or
    [string]$config.data.POST_RAMP_WARMUP_FLAG_KEY -cne
        ("{0}{1:D2}" -f $matrix.flagPrefix, [int]$matrix.postRampWarmupFlagIndex)
) {
    throw "Multi-environment ConfigMap does not match the matrix."
}

$testRuns = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit-loadtest",
        "get", "testruns.k6.io",
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect existing TestRuns."
$active = @($testRuns.items | Where-Object {
    [string]$_.status.stage -notin @("finished", "error")
})
if ($active.Count -gt 0) {
    throw (
        "Refusing to render while TestRun(s) are active: " +
        (($active.metadata.name | Sort-Object) -join ", ")
    )
}

$templatePath = Join-Path `
    $repositoryRoot `
    "k8s-infra\templates\testrun-aks-multi-environment.yaml"
$template = Get-Content -Raw -LiteralPath $templatePath
$gitSha = (& git -C $repositoryRoot rev-parse --short=8 HEAD 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $gitSha -notmatch "^[a-fA-F0-9]{8}$") {
    $gitSha = "nogit"
}
$runId = "growth-menv-{0}-{1}-{2}" -f `
    $RunKind.ToLowerInvariant(), `
    [DateTime]::UtcNow.ToString("yyyyMMddHHmmss"), `
    [Guid]::NewGuid().ToString("N").Substring(0, 4)
$testRunName = "featbit-$runId"
$initializerLabel = "$testRunName-initializer"
if ($initializerLabel.Length -gt 63) {
    throw (
        "Generated k6 initializer label is $($initializerLabel.Length) " +
        "characters; Kubernetes permits at most 63."
    )
}
$rendered = $template
foreach ($token in ([ordered]@{
    "__TEST_RUN_NAME__" = $testRunName
    "__RUN_ID__" = $runId
    "__RUN_KIND__" = $RunKind.ToLowerInvariant()
    "__RUNNER_IMAGE__" = $normalizedRunnerImage
}).GetEnumerator()) {
    $rendered = $rendered.Replace($token.Key, [string]$token.Value)
}
if ($rendered -match "__[A-Z0-9_]+__") {
    throw "Rendered TestRun contains unresolved template tokens."
}

$resultsDirectory = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path $repositoryRoot "results"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputDirectory
    )
}
$null = New-Item -ItemType Directory -Force -Path $resultsDirectory
$manifestPath = Join-Path $resultsDirectory "$runId-testrun.yaml"
$metadataPath = Join-Path $resultsDirectory "$runId-metadata.json"
if (
    (Test-Path -LiteralPath $manifestPath) -or
    (Test-Path -LiteralPath $metadataPath)
) {
    throw "Refusing to overwrite existing render artifacts for '$runId'."
}
$rendered | Set-Content -LiteralPath $manifestPath -Encoding utf8

$metadata = [ordered]@{
    schemaVersion = 1
    runId = $runId
    testRunName = $testRunName
    runKind = $RunKind.ToLowerInvariant()
    createdAtUtc = [DateTime]::UtcNow.ToString("o")
    kubernetesContext = $targetContext
    profile = "growth"
    experimentId = [string]$matrix.experimentId
    topologyOnly = [bool]$TopologyOnly
    note = $Note
    sourceGitSha = $gitSha.ToLowerInvariant()
    parallelism = $parallelism
    runnersPerNode = 2
    parameters = [ordered]@{
        MaxConnections = $totalConnections
        ConnectionsPerSecond = [int]$matrix.connectionsPerSecond
        StabilizationSeconds = [int]$matrix.stabilizationSeconds
        HoldDurationSeconds = [int]$matrix.holdDurationSeconds
        EnvironmentCount = $environmentCount
        ConnectionsPerEnvironment = [int]$matrix.connectionsPerEnvironment
        ConnectionsPerEnvironmentPerRunner = $perEnvironmentPerRunner
    }
    targetEnvironmentId = [string]$config.data.FEATBIT_ENVIRONMENT_ID
    targetEnvironmentKey = [string]$config.data.TARGET_ENVIRONMENT_KEY
    measuredProbeFlagKeys = @([string]$config.data.PROBE_FLAG_KEYS)
    postRampWarmupFlagKey = [string]$config.data.POST_RAMP_WARMUP_FLAG_KEY
    expectedRevisions = @(
        ([string]$config.data.EXPECTED_REVISIONS).Split(",") |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    inventorySha256 = [string]$config.data.INVENTORY_SHA256
    runnerImage = $normalizedRunnerImage
    fixedInfrastructure = $matrix.fixedInfrastructure
    matrix = [ordered]@{
        path = $resolvedMatrixPath
        sha256 = (
            Get-FileHash -LiteralPath $resolvedMatrixPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }
    template = [ordered]@{
        path = $templatePath
        sha256 = (
            Get-FileHash -LiteralPath $templatePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }
}
$metadata |
    ConvertTo-Json -Depth 12 |
    Set-Content -LiteralPath $metadataPath -Encoding utf8

$dryRunText = (
    & kubectl --context $targetContext `
        apply --dry-run=server `
        -f $manifestPath `
        -o json |
        Out-String
)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($dryRunText)) {
    throw "Multi-environment TestRun failed server-side dry-run."
}
$dryRun = $dryRunText | ConvertFrom-Json
$runnerCpuLimitProperty = (
    $dryRun.spec.runner.resources.limits.PSObject.Properties["cpu"]
)
if (
    [int]$dryRun.spec.parallelism -ne 20 -or
    [bool]$dryRun.spec.separate -ne $false -or
    [string]$dryRun.spec.runner.resources.requests.cpu -cne "1" -or
    [string]$dryRun.spec.runner.resources.requests.memory -cne "2Gi" -or
    [string]$dryRun.spec.runner.resources.limits.memory -cne "6Gi" -or
    $null -ne $runnerCpuLimitProperty
) {
    throw "Server-rendered runner topology or resources differ from the matrix."
}

Write-Host ""
Write-Host "Multi-environment TestRun rendered and server-validated; nothing was submitted." `
    -ForegroundColor Green
Write-Host "Run ID: $runId"
Write-Host "Run kind: $RunKind"
Write-Host "Topology-only render: $([bool]$TopologyOnly)"
Write-Host "Context: $targetContext"
Write-Host "20 runners x 500 connections = 10,000"
Write-Host "100 environments x 5 connections/runner = 100 connections/environment"
Write-Host "Manifest: $manifestPath"
Write-Host "Metadata: $metadataPath"

[pscustomobject]@{
    RunId = $runId
    TestRunName = $testRunName
    RunKind = $RunKind.ToLowerInvariant()
    ManifestPath = $manifestPath
    MetadataPath = $metadataPath
    Parallelism = 20
    ConnectionsPerRunner = 500
    EnvironmentCount = 100
    ConnectionsPerEnvironmentPerRunner = 5
    ConnectionsPerEnvironment = 100
    TotalConnections = 10000
}
