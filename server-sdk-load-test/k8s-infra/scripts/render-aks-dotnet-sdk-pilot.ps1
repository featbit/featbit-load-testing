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

    [Parameter(Mandatory)]
    [string] $ControllerImage,

    [ValidateRange(120, 900)]
    [int] $StartDelaySeconds = 300,

    [string] $MatrixPath = "",

    [string] $OutputDirectory = "",

    [string] $Note = ""
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
    param(
        [Parameter(Mandatory)][string] $Image,
        [Parameter(Mandatory)][string] $ParameterName
    )

    $normalized = $Image.Trim()
    if (
        $normalized -notmatch
            "^[A-Za-z0-9._:/-]+@sha256:[a-fA-F0-9]{64}$" -or
        $normalized -notmatch "/"
    ) {
        throw (
            "$ParameterName must be an immutable " +
            "registry/repository@sha256:<64-hex-digest> reference."
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
    Join-Path $repositoryRoot (
        "k8s-infra\matrices\" +
        "aks-single-environment-3k-flags-dotnet-sdk-p500.json"
    )
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $MatrixPath
    )
}
if (-not (Test-Path -LiteralPath $resolvedMatrixPath -PathType Leaf)) {
    throw ".NET SDK pilot matrix does not exist: $resolvedMatrixPath"
}
$matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath |
    ConvertFrom-Json
$supportedMatrixIds = @(
    "aks-single-environment-3k-flags-dotnet-sdk-p500",
    "aks-single-environment-3k-flags-dotnet-sdk-p500-els-expanded"
)
if (
    [int]$matrix.schemaVersion -ne 1 -or
    [string]$matrix.matrixId -cnotin $supportedMatrixIds -or
    [string]$matrix.kubernetesContext -cne $targetContext
) {
    throw ".NET SDK pilot matrix schema, ID, or AKS context is invalid."
}

$normalizedRunnerImage = Assert-DigestPinnedImage `
    -Image $RunnerImage `
    -ParameterName "RunnerImage"
$normalizedControllerImage = Assert-DigestPinnedImage `
    -Image $ControllerImage `
    -ParameterName "ControllerImage"

$parallelism = [int]$matrix.parallelism
$clientsPerRunner = [int]$matrix.connectionsPerRunner
$totalConnections = [int]$matrix.totalConnections
if (
    $parallelism -ne 20 -or
    $clientsPerRunner -ne 25 -or
    $parallelism * $clientsPerRunner -ne 500 -or
    [int]$matrix.connectionsPerEnvironmentPerRunner -ne 25 -or
    [int]$matrix.connectionsPerEnvironment -ne 500 -or
    [int]$matrix.connectionsPerSecond -ne 20 -or
    [int]$matrix.rampDurationSeconds -ne 25 -or
    [int]$matrix.crossNodeClockToleranceMs -ne 10 -or
    [int]$matrix.flagCount -ne 3000 -or
    [int]$matrix.stringFlagCount -ne 2500 -or
    [int]$matrix.jsonFlagCount -ne 500 -or
    @($matrix.revisionPlan).Count -ne 10 -or
    @($matrix.revisionPlan |
        Where-Object variationType -eq "string").Count -ne 8 -or
    @($matrix.revisionPlan |
        Where-Object variationType -eq "json").Count -ne 2
) {
    throw (
        "Matrix does not satisfy the fixed 20 x 25 / 20 per second / " +
        "one-environment / 3,000-flag pilot contract."
    )
}

$nodes = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "get", "nodes",
        "-o", "json"
    ) `
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
    $featbitNodes.Count -ne
        [int]$matrix.fixedInfrastructure.featbitNodes -or
    @($featbitNodes | Where-Object {
        $_.metadata.labels."node.kubernetes.io/instance-type" -cne
            [string]$matrix.fixedInfrastructure.featbitNodeVmSize
    }).Count -ne 0
) {
    throw "FeatBit node count or VM size differs from the fixed matrix."
}
if (
    $loadgenNodes.Count -ne
        [int]$matrix.fixedInfrastructure.loadgenNodes -or
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
    throw "ELS replicas or resources differ from the fixed G5 matrix."
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
$elsNodeNames = @($readyElsPods.spec.nodeName | Sort-Object -Unique)
if (
    $readyElsPods.Count -ne 3 -or
    $elsNodeNames.Count -ne 3 -or
    @($readyElsPods | Where-Object {
        $_.spec.nodeName -notin @($featbitNodes.metadata.name)
    }).Count -ne 0
) {
    throw "Expected three ready ELS Pods spread one per FeatBit node."
}

$requiredObjects = @(
    @{
        Namespace = "featbit-loadtest"
        Kind = "persistentvolumeclaim"
        Name = [string]$matrix.kubernetesObjects.resultsPvc
    }
    @{
        Namespace = "featbit-loadtest"
        Kind = "pod"
        Name = "results-reader"
    }
    @{
        Namespace = "featbit-loadtest"
        Kind = "secret"
        Name = [string]$matrix.kubernetesObjects.controllerSecret
    }
    @{
        Namespace = "featbit-loadtest"
        Kind = "configmap"
        Name = [string]$matrix.kubernetesObjects.configMap
    }
    @{
        Namespace = "featbit-loadtest"
        Kind = "secret"
        Name = [string]$matrix.kubernetesObjects.secret
    }
    @{
        Namespace = "default"
        Kind = "customresourcedefinition"
        Name = "testruns.k6.io"
    }
)
foreach ($object in $requiredObjects) {
    Assert-KubernetesObjectExists `
        -Kind $object.Kind `
        -Name $object.Name `
        -Namespace $object.Namespace `
        -KubeContext $targetContext
}

$config = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit-loadtest",
        "get", "configmap",
        [string]$matrix.kubernetesObjects.configMap,
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect the 3,000-flag ConfigMap."
$configuredPlan = [string]$config.data.REVISION_PLAN_JSON |
    ConvertFrom-Json
$expectedPlan = @(
    foreach ($step in $matrix.revisionPlan) {
        [pscustomobject]@{
            index = [int]$step.index
            flagKey = "{0}{1:D4}" -f
                [string]$matrix.flagPrefix,
                [int]$step.flagIndex
            revision = [string]$step.revision
            variationType = [string]$step.variationType
        }
    }
)
if (
    [string]$config.data.EXPECTED_ENVIRONMENT_COUNT -cne "1" -or
    [string]$config.data.EXPECTED_FULL_SYNC_FLAG_COUNT -cne "3000" -or
    [string]$config.data.TARGET_ENVIRONMENT_KEY -cne
        [string]$matrix.environmentKey -or
    @($configuredPlan).Count -ne 10
) {
    throw "The existing 3,000-flag ConfigMap is not canonical."
}
for ($index = 0; $index -lt 10; $index += 1) {
    $actual = @($configuredPlan)[$index]
    $expected = @($expectedPlan)[$index]
    if (
        [int]$actual.index -ne [int]$expected.index -or
        [string]$actual.flagKey -cne [string]$expected.flagKey -or
        [string]$actual.revision -cne [string]$expected.revision -or
        [string]$actual.variationType -cne [string]$expected.variationType
    ) {
        throw "The existing revision plan differs from the pilot matrix."
    }
}

$testRuns = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit-loadtest",
        "get", "testruns.k6.io",
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect existing TestRuns."
$activeTestRuns = @($testRuns.items | Where-Object {
    [string]$_.status.stage -notin @("finished", "error")
})
if ($activeTestRuns.Count -gt 0) {
    throw (
        "Refusing to render while TestRun(s) are active: " +
        (($activeTestRuns.metadata.name | Sort-Object) -join ", ")
    )
}

$jobs = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit-loadtest",
        "get", "jobs",
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect existing Jobs."
$activeJobs = @($jobs.items | Where-Object {
    $activeProperty = $_.status.PSObject.Properties["active"]
    $null -ne $activeProperty -and [int]$activeProperty.Value -gt 0
})
if ($activeJobs.Count -gt 0) {
    throw (
        "Refusing to render while Job(s) are active: " +
        (($activeJobs.metadata.name | Sort-Object) -join ", ")
    )
}

$templatePath = Join-Path $repositoryRoot (
    "k8s-infra\templates\job-aks-dotnet-sdk-large-flagset-pilot.yaml"
)
$template = Get-Content -Raw -LiteralPath $templatePath
$gitSha = (
    & git -C $repositoryRoot rev-parse --short=8 HEAD 2>$null |
        Out-String
).Trim()
if ($LASTEXITCODE -ne 0 -or $gitSha -notmatch "^[a-fA-F0-9]{8}$") {
    $gitSha = "nogit"
}
$runKindToken = if ($RunKind -eq "validation") { "v" } else { "f" }
$runId = "growth-f3k-dotnet-p500-{0}-{1}-{2}" -f
    $runKindToken,
    [DateTime]::UtcNow.ToString("yyyyMMddHHmmss"),
    [Guid]::NewGuid().ToString("N").Substring(0, 4)
$jobName = "featbit-$runId"
if ($jobName.Length -gt 63) {
    throw "Generated Job name exceeds 63 characters."
}
$startAtUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() +
    ($StartDelaySeconds * 1000L)
$rendered = $template
foreach ($token in ([ordered]@{
    "__JOB_NAME__" = $jobName
    "__RUN_ID__" = $runId
    "__RUN_KIND__" = $RunKind.ToLowerInvariant()
    "__RUNNER_IMAGE__" = $normalizedRunnerImage
    "__START_AT_UNIX_MS__" = $startAtUnixMs
}).GetEnumerator()) {
    $rendered = $rendered.Replace($token.Key, [string]$token.Value)
}
if ($rendered -match "__[A-Z0-9_]+__") {
    throw "Rendered Job contains unresolved template tokens."
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
$manifestPath = Join-Path $resultsDirectory "$runId-job.yaml"
$metadataPath = Join-Path $resultsDirectory "$runId-metadata.json"
if (
    (Test-Path -LiteralPath $manifestPath) -or
    (Test-Path -LiteralPath $metadataPath)
) {
    throw "Refusing to overwrite render artifacts for '$runId'."
}
$rendered | Set-Content -LiteralPath $manifestPath -Encoding utf8

$metadata = [ordered]@{
    schemaVersion = 1
    runId = $runId
    jobName = $jobName
    runKind = $RunKind.ToLowerInvariant()
    createdAtUtc = [DateTime]::UtcNow.ToString("o")
    startAtUnixMs = $startAtUnixMs
    startDelaySeconds = $StartDelaySeconds
    kubernetesContext = $targetContext
    profile = "extreme-large-flagset-dotnet-p500"
    experimentId = [string]$matrix.experimentId
    resourceExperimentId = [string]$matrix.resourceExperimentId
    matrixId = [string]$matrix.matrixId
    note = $Note
    sourceGitSha = $gitSha.ToLowerInvariant()
    runnerKind = "official-dotnet-server-sdk"
    sdkPackage = "FeatBit.ServerSdk"
    sdkPackageVersion = "1.2.11"
    runnerImage = $normalizedRunnerImage
    controllerImage = $normalizedControllerImage
    targetEnvironmentId = [string]$config.data.FEATBIT_ENVIRONMENT_ID
    targetEnvironmentKey = [string]$config.data.TARGET_ENVIRONMENT_KEY
    measuredProbeFlagKeys = @($configuredPlan.flagKey)
    postRampWarmupFlagKey =
        [string]$config.data.POST_RAMP_WARMUP_FLAG_KEY
    expectedRevisions = @($configuredPlan.revision)
    revisionPlan = @($configuredPlan)
    inventorySha256 = [string]$config.data.INVENTORY_SHA256
    measurementContract = [ordered]@{
        initialization = (
            "client_create_started -> first public FbClient.Initialized=true"
        )
        endToEnd = (
            "controller PUT start -> first public StringVariation observation"
        )
        controlPlane = (
            "controller PUT start -> matching Redis observer event"
        )
        streaming = (
            "matching Redis observer event -> first StringVariation observation"
        )
        sdkObservationPollIntervalMs = [int]$matrix.pollIntervalMs
        crossNodeClockToleranceMs =
            [int]$matrix.crossNodeClockToleranceMs
        sdkObservationQuantization = (
            "0 to pollIntervalMs late; no SDK internal change event is used"
        )
    }
    parameters = [ordered]@{
        Parallelism = $parallelism
        ClientsPerRunner = $clientsPerRunner
        TotalConnections = $totalConnections
        ConnectionsPerSecond = [int]$matrix.connectionsPerSecond
        RampDurationSeconds = [int]$matrix.rampDurationSeconds
        EnvironmentCount = 1
        ConnectionsPerEnvironment = 500
        ConnectionsPerEnvironmentPerRunner = 25
        FlagCount = 3000
        StringFlagCount = 2500
        JsonFlagCount = 500
        JsonVariationBytes = [int]$matrix.jsonVariationBytes
        ReadyCoverageTimeoutSeconds =
            [int]$matrix.readyCoverageTimeoutSeconds
        RunDurationSeconds = [int]$matrix.runDurationSeconds
        RevisionIntervalSeconds = [int]$matrix.revisionIntervalSeconds
        PollIntervalMs = [int]$matrix.pollIntervalMs
    }
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
    ConvertTo-Json -Depth 16 |
    Set-Content -LiteralPath $metadataPath -Encoding utf8

$dryRunText = (
    & kubectl --context $targetContext `
        apply --dry-run=server `
        -f $manifestPath `
        -o json |
        Out-String
)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($dryRunText)) {
    throw ".NET SDK pilot Job failed server-side dry-run."
}
$dryRun = $dryRunText | ConvertFrom-Json
$container = @($dryRun.spec.template.spec.containers)[0]
$cpuLimitProperty =
    $container.resources.limits.PSObject.Properties["cpu"]
$spread = @($dryRun.spec.template.spec.topologySpreadConstraints)[0]
if (
    [int]$dryRun.spec.completions -ne 20 -or
    [int]$dryRun.spec.parallelism -ne 20 -or
    [string]$dryRun.spec.completionMode -cne "Indexed" -or
    [int]$dryRun.spec.backoffLimitPerIndex -ne 0 -or
    [string]$container.image -cne $normalizedRunnerImage -or
    [string]$container.resources.requests.cpu -cne "1" -or
    [string]$container.resources.requests.memory -cne "2Gi" -or
    [string]$container.resources.limits.memory -cne "6Gi" -or
    $null -ne $cpuLimitProperty -or
    [int]$spread.minDomains -ne 10
) {
    throw "Server-rendered Job topology or resources differ from the matrix."
}
$renderedEnvironment = @{}
foreach ($entry in @($container.env)) {
    $valueProperty = $entry.PSObject.Properties["value"]
    if ($null -ne $valueProperty) {
        $renderedEnvironment[[string]$entry.name] =
            [string]$valueProperty.Value
    }
}
foreach ($expected in @{
    LOADTEST_PARALLELISM = "20"
    CLIENTS_PER_RUNNER = "25"
    TOTAL_CONNECTIONS = "500"
    CONNECTIONS_PER_SECOND = "20"
    EXPECTED_FULL_SYNC_FLAG_COUNT = "3000"
    POLL_INTERVAL_MS = "10"
}.GetEnumerator()) {
    if (
        -not $renderedEnvironment.ContainsKey($expected.Key) -or
        $renderedEnvironment[$expected.Key] -cne $expected.Value
    ) {
        throw "Server-rendered Job has an invalid $($expected.Key) value."
    }
}

Write-Host ""
Write-Host (
    ".NET SDK pilot Job rendered and server-validated; nothing was submitted."
) -ForegroundColor Green
Write-Host "Run ID: $runId"
Write-Host "Run kind: $RunKind"
Write-Host "Context: $targetContext"
Write-Host "20 runners x 25 official SDK clients = 500"
Write-Host "Ramp: 20 clients/s for approximately 25 seconds"
Write-Host "One environment; 3,000 flags (2,500 string + 500 JSON)"
Write-Host "Scheduled start: $startAtUnixMs (Unix ms)"
Write-Host "Manifest: $manifestPath"
Write-Host "Metadata: $metadataPath"

[pscustomobject]@{
    RunId = $runId
    JobName = $jobName
    RunKind = $RunKind.ToLowerInvariant()
    ManifestPath = $manifestPath
    MetadataPath = $metadataPath
    StartAtUnixMs = $startAtUnixMs
    Parallelism = 20
    ConnectionsPerRunner = 25
    ConnectionsPerSecond = 20
    RampDurationSeconds = 25
    EnvironmentCount = 1
    ConnectionsPerEnvironment = 500
    FlagCount = 3000
    TotalConnections = 500
}
