[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("validation", "formal")]
    [string] $RunKind,

    [Parameter(Mandatory)]
    [ValidatePattern("^aks-featbit-load-testing$")]
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
    Join-Path `
        $repositoryRoot `
        "k8s-infra\matrices\aks-single-environment-3k-flags-g5-d4-els3.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $MatrixPath
    )
}
if (-not (Test-Path -LiteralPath $resolvedMatrixPath -PathType Leaf)) {
    throw "Large flag-set matrix does not exist: $resolvedMatrixPath"
}
$matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath | ConvertFrom-Json
if (
    $matrix.schemaVersion -ne 1 -or
    [string]$matrix.kubernetesContext -cne $targetContext
) {
    throw "Large flag-set matrix schema or AKS context is invalid."
}

$normalizedRunnerImage = Assert-DigestPinnedImage -Image $RunnerImage
$parallelism = [int]$matrix.parallelism
$connectionsPerRunner = [int]$matrix.connectionsPerRunner
$totalConnections = [int]$matrix.totalConnections
if (
    $parallelism -ne 20 -or
    $connectionsPerRunner -ne 500 -or
    $connectionsPerRunner * $parallelism -ne 10000 -or
    [int]$matrix.connectionsPerEnvironmentPerRunner -ne 500 -or
    [int]$matrix.connectionsPerEnvironment -ne 10000 -or
    [int]$matrix.flagCount -ne 3000 -or
    [int]$matrix.stringFlagCount -ne 2500 -or
    [int]$matrix.jsonFlagCount -ne 500 -or
    @($matrix.revisionPlan).Count -ne 10 -or
    @($matrix.revisionPlan | Where-Object variationType -eq "string").Count -ne 8 -or
    @($matrix.revisionPlan | Where-Object variationType -eq "json").Count -ne 2
) {
    throw "Matrix does not satisfy the fixed 20 x 500 / one-env / 3,000-flag contract."
}

$runnerPlacementProperty = (
    $matrix.fixedInfrastructure.PSObject.Properties["runnerPlacement"]
)
$runnerPlacement = if ($null -eq $runnerPlacementProperty) {
    [pscustomobject]@{
        nodeWorkloads = @("loadgen")
        nodeCount = [int]$matrix.fixedInfrastructure.loadgenNodes
        runnersPerNode = (
            $parallelism /
            [int]$matrix.fixedInfrastructure.loadgenNodes
        )
    }
}
else {
    $runnerPlacementProperty.Value
}
$runnerNodeWorkloads = @($runnerPlacement.nodeWorkloads)
$runnerPlacementNodeCount = [int]$runnerPlacement.nodeCount
$runnersPerNode = [int]$runnerPlacement.runnersPerNode
if (
    $runnerNodeWorkloads.Count -lt 1 -or
    @($runnerNodeWorkloads | Where-Object {
        [string]::IsNullOrWhiteSpace([string]$_)
    }).Count -gt 0 -or
    $runnerPlacementNodeCount -lt 1 -or
    $runnersPerNode -lt 1 -or
    $runnerPlacementNodeCount * $runnersPerNode -ne $parallelism
) {
    throw "Matrix runner placement does not cover exactly 20 runners."
}
$elsPlacementProperty = (
    $matrix.fixedInfrastructure.PSObject.Properties["elsPlacement"]
)
$elsPlacement = if ($null -eq $elsPlacementProperty) {
    [pscustomobject]@{
        nodeWorkload = "featbit"
        nodeCount = [int]$matrix.fixedInfrastructure.featbitNodes
    }
}
else {
    $elsPlacementProperty.Value
}
$elsPlacementWorkload = [string]$elsPlacement.nodeWorkload
if (
    [string]::IsNullOrWhiteSpace($elsPlacementWorkload) -or
    [int]$elsPlacement.nodeCount -ne
        [int]$matrix.fixedInfrastructure.elsReplicas
) {
    throw "Matrix ELS placement must provide one node per ELS replica."
}
$additionalPoolsProperty = (
    $matrix.fixedInfrastructure.PSObject.Properties["additionalNodePools"]
)
$additionalNodePools = if ($null -eq $additionalPoolsProperty) {
    @()
}
else {
    @($additionalPoolsProperty.Value)
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
foreach ($pool in $additionalNodePools) {
    $poolNodes = @($readyNodes | Where-Object {
        [string]$_.metadata.labels.workload -ceq [string]$pool.workload
    })
    if (
        [string]::IsNullOrWhiteSpace([string]$pool.name) -or
        [string]::IsNullOrWhiteSpace([string]$pool.workload) -or
        [int]$pool.nodes -lt 1 -or
        $poolNodes.Count -ne [int]$pool.nodes -or
        @($poolNodes | Where-Object {
            [string]$_.metadata.labels.agentpool -cne [string]$pool.name -or
            [string]$_.metadata.labels."node.kubernetes.io/instance-type" -cne
                [string]$pool.vmSize
        }).Count -ne 0
    ) {
        throw (
            "Additional node pool '$([string]$pool.name)' is absent or " +
            "differs from the matrix."
        )
    }
}
$runnerPlacementNodes = @($readyNodes | Where-Object {
    [string]$_.metadata.labels.workload -cin $runnerNodeWorkloads
})
if ($runnerPlacementNodes.Count -ne $runnerPlacementNodeCount) {
    throw (
        "Expected $runnerPlacementNodeCount runner-placement nodes; found " +
        "$($runnerPlacementNodes.Count)."
    )
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
$nodesByName = @{}
foreach ($node in $readyNodes) {
    $nodesByName[[string]$node.metadata.name] = $node
}
$elsOnWrongWorkload = @($readyElsPods | Where-Object {
    $nodeName = [string]$_.spec.nodeName
    -not $nodesByName.ContainsKey($nodeName) -or
    [string]$nodesByName[$nodeName].metadata.labels.workload -cne
        $elsPlacementWorkload
})
if (
    $readyElsPods.Count -ne 3 -or
    $elsNodes.Count -ne 3 -or
    $elsOnWrongWorkload.Count -ne 0
) {
    throw "Expected three ready ELS Pods spread one per FeatBit node."
}

$operatorResourcesProperty = (
    $matrix.fixedInfrastructure.PSObject.Properties["k6OperatorResources"]
)
if ($null -ne $operatorResourcesProperty) {
    $expectedOperator = $operatorResourcesProperty.Value
    $operator = Read-KubectlJson `
        -Arguments @(
            "--context", $targetContext,
            "-n", [string]$expectedOperator.namespace,
            "get", "deployment", [string]$expectedOperator.deployment,
            "-o", "json"
        ) `
        -FailureMessage "Failed to inspect the k6 Operator Deployment."
    $operatorContainer = @($operator.spec.template.spec.containers)[0]
    if (
        [int]$operator.spec.replicas -ne 1 -or
        [int]$operator.status.readyReplicas -ne 1 -or
        [string]$operatorContainer.image -cne
            [string]$expectedOperator.image -or
        [string]$operatorContainer.resources.requests.cpu -cne
            [string]$expectedOperator.cpuRequest -or
        [string]$operatorContainer.resources.limits.cpu -cne
            [string]$expectedOperator.cpuLimit -or
        [string]$operatorContainer.resources.requests.memory -cne
            [string]$expectedOperator.memoryRequest -or
        [string]$operatorContainer.resources.limits.memory -cne
            [string]$expectedOperator.memoryLimit
    ) {
        throw "k6 Operator image, replicas, readiness, or resources differ from the matrix."
    }
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

$syntheticPlan = @(
    foreach ($step in $matrix.revisionPlan) {
        [ordered]@{
            index = [int]$step.index
            flagKey = "{0}{1:D4}" -f `
                [string]$matrix.flagPrefix, `
                [int]$step.flagIndex
            revision = [string]$step.revision
            variationType = [string]$step.variationType
        }
    }
)
$config = if ($TopologyOnly) {
    [pscustomobject]@{
        data = [pscustomobject]@{
            EXPECTED_ENVIRONMENT_COUNT = "1"
            EXPECTED_CONNECTIONS_PER_ENVIRONMENT_PER_RUNNER = "500"
            EXPECTED_FULL_SYNC_FLAG_COUNT = "3000"
            FEATBIT_ENVIRONMENT_ID = "00000000-0000-0000-0000-000000000001"
            TARGET_ENVIRONMENT_KEY = [string]$matrix.environmentKey
            PROBE_FLAG_KEYS = (@($syntheticPlan.flagKey) -join ",")
            POST_RAMP_WARMUP_FLAG_KEY = (
                "{0}{1:D4}" -f
                [string]$matrix.flagPrefix,
                [int]$matrix.postRampWarmupFlagIndex
            )
            EXPECTED_REVISIONS = (@($syntheticPlan.revision) -join ",")
            REVISION_PLAN_JSON = (
                $syntheticPlan | ConvertTo-Json -Depth 8 -Compress
            )
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
        -FailureMessage "Failed to inspect the large flag-set ConfigMap."
}
$configuredPlan = [string]$config.data.REVISION_PLAN_JSON | ConvertFrom-Json
if (
    [string]$config.data.EXPECTED_ENVIRONMENT_COUNT -cne "1" -or
    [string]$config.data.EXPECTED_CONNECTIONS_PER_ENVIRONMENT_PER_RUNNER -cne
        "500" -or
    [string]$config.data.EXPECTED_FULL_SYNC_FLAG_COUNT -cne "3000" -or
    @($configuredPlan).Count -ne 10 -or
    @($configuredPlan | Where-Object variationType -eq "string").Count -ne 8 -or
    @($configuredPlan | Where-Object variationType -eq "json").Count -ne 2
) {
    throw "Large flag-set ConfigMap does not match the matrix."
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

$templateNameProperty = $matrix.PSObject.Properties["testRunTemplate"]
$templateName = if ($null -eq $templateNameProperty) {
    "testrun-aks-large-flagset.yaml"
}
else {
    [string]$templateNameProperty.Value
}
if ($templateName -notin @(
    "testrun-aks-large-flagset.yaml",
    "testrun-aks-large-flagset-isolated.yaml"
)) {
    throw "Matrix selected an unsupported large flag-set TestRun template."
}
$templatePath = Join-Path `
    $repositoryRoot `
    "k8s-infra\templates\$templateName"
$template = Get-Content -Raw -LiteralPath $templatePath
$gitSha = (& git -C $repositoryRoot rev-parse --short=8 HEAD 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $gitSha -notmatch "^[a-fA-F0-9]{8}$") {
    $gitSha = "nogit"
}
$runKindToken = if ($RunKind -eq "validation") { "v" } else { "f" }
$runId = "growth-f3k-{0}-{1}-{2}" -f `
    $runKindToken, `
    [DateTime]::UtcNow.ToString("yyyyMMddHHmmss"), `
    [Guid]::NewGuid().ToString("N").Substring(0, 4)
$testRunName = "featbit-$runId"
$initializerLabel = "$testRunName-initializer"
if ($initializerLabel.Length -gt 63) {
    throw "Generated k6 initializer label exceeds 63 characters."
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
    profile = "extreme-large-flagset"
    experimentId = [string]$matrix.experimentId
    matrixId = [string]$matrix.matrixId
    topologyOnly = [bool]$TopologyOnly
    note = $Note
    sourceGitSha = $gitSha.ToLowerInvariant()
    parallelism = $parallelism
    runnersPerNode = $runnersPerNode
    parameters = [ordered]@{
        MaxConnections = $totalConnections
        ConnectionsPerSecond = [int]$matrix.connectionsPerSecond
        RampDurationSeconds = [int]$matrix.rampDurationSeconds
        StabilizationSeconds = [int]$matrix.stabilizationSeconds
        InitialSyncTimeoutSeconds = [int]$matrix.initialSyncTimeoutSeconds
        HoldDurationSeconds = [int]$matrix.holdDurationSeconds
        EnvironmentCount = 1
        ConnectionsPerEnvironment = 10000
        ConnectionsPerEnvironmentPerRunner = 500
        FlagCount = 3000
        StringFlagCount = 2500
        JsonFlagCount = 500
        JsonVariationBytes = [int]$matrix.jsonVariationBytes
    }
    targetEnvironmentId = [string]$config.data.FEATBIT_ENVIRONMENT_ID
    targetEnvironmentKey = [string]$config.data.TARGET_ENVIRONMENT_KEY
    measuredProbeFlagKeys = @($configuredPlan.flagKey)
    postRampWarmupFlagKey = [string]$config.data.POST_RAMP_WARMUP_FLAG_KEY
    expectedRevisions = @($configuredPlan.revision)
    revisionPlan = @($configuredPlan)
    inventorySha256 = [string]$config.data.INVENTORY_SHA256
    runnerImage = $normalizedRunnerImage
    fixedInfrastructure = $matrix.fixedInfrastructure
    matrix = [ordered]@{
        id = [string]$matrix.matrixId
        description = [string]$matrix.description
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
    ConvertTo-Json -Depth 14 |
    Set-Content -LiteralPath $metadataPath -Encoding utf8

$dryRunText = (
    & kubectl --context $targetContext `
        apply --dry-run=server `
        -f $manifestPath `
        -o json |
        Out-String
)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($dryRunText)) {
    throw "Large flag-set TestRun failed server-side dry-run."
}
$dryRun = $dryRunText | ConvertFrom-Json
$runnerCpuLimitProperty = (
    $dryRun.spec.runner.resources.limits.PSObject.Properties["cpu"]
)
$expectedRunnerResources = $matrix.fixedInfrastructure.runnerResources
$expectedCpuLimit = $expectedRunnerResources.cpuLimit
$actualMinDomains = [int](
    @($dryRun.spec.runner.topologySpreadConstraints)[0].minDomains
)
if (
    [int]$dryRun.spec.parallelism -ne 20 -or
    [bool]$dryRun.spec.separate -ne $false -or
    [string]$dryRun.spec.script.localFile -cne
        "/tests/k6/server-streaming-large-flagset.js" -or
    [string]$dryRun.spec.runner.resources.requests.cpu -cne
        [string]$expectedRunnerResources.cpuRequest -or
    [string]$dryRun.spec.runner.resources.requests.memory -cne
        [string]$expectedRunnerResources.memoryRequest -or
    [string]$dryRun.spec.runner.resources.limits.memory -cne
        [string]$expectedRunnerResources.memoryLimit -or
    (
        $null -eq $expectedCpuLimit -and
        $null -ne $runnerCpuLimitProperty
    ) -or
    (
        $null -ne $expectedCpuLimit -and
        (
            $null -eq $runnerCpuLimitProperty -or
            [string]$runnerCpuLimitProperty.Value -cne
                [string]$expectedCpuLimit
        )
    ) -or
    $actualMinDomains -ne $runnerPlacementNodeCount
) {
    throw "Server-rendered runner topology or resources differ from the matrix."
}

Write-Host ""
Write-Host "Large flag-set TestRun rendered and server-validated; nothing was submitted." `
    -ForegroundColor Green
Write-Host "Run ID: $runId"
Write-Host "Run kind: $RunKind"
Write-Host "Topology-only render: $([bool]$TopologyOnly)"
Write-Host "Context: $targetContext"
Write-Host (
    "20 runners x 500 connections = 10,000; {0} node(s) x {1} runner(s)" -f
    $runnerPlacementNodeCount,
    $runnersPerNode
)
Write-Host "One environment; 3,000 flags (2,500 string + 500 JSON)"
Write-Host "Ramp: 100 connections/s for 100 seconds"
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
    EnvironmentCount = 1
    ConnectionsPerEnvironmentPerRunner = 500
    ConnectionsPerEnvironment = 10000
    FlagCount = 3000
    StringFlagCount = 2500
    JsonFlagCount = 500
    TotalConnections = 10000
}
