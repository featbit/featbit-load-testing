[CmdletBinding()]
param(
    [ValidateSet("smoke", "baseline", "growth")]
    [string] $Profile = "smoke",

    [Parameter(Mandatory)]
    [string] $KubeContext,

    [Parameter(Mandatory)]
    [string] $RunnerImage,

    [ValidateRange(2, 20)]
    [int] $Parallelism = 2,

    [string] $Note = "",

    [string] $OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Get-AksTestProfile {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    switch ($Name.ToLowerInvariant()) {
        "smoke" {
            return [ordered]@{
                ProbeFlagCount = 1
                MaxConnections = 10
                ConnectionsPerSecond = 1
                StabilizationSeconds = 10
                InitialSyncTimeoutSeconds = 10
                HoldDurationSeconds = 180
                DrainDurationSeconds = 10
                RunnerCpuRequest = "1"
                RunnerMemoryRequest = "512Mi"
                RunnerMemoryLimit = "4Gi"
            }
        }
        "baseline" {
            return [ordered]@{
                ProbeFlagCount = 10
                MaxConnections = 1000
                ConnectionsPerSecond = 10
                StabilizationSeconds = 30
                InitialSyncTimeoutSeconds = 20
                HoldDurationSeconds = 600
                DrainDurationSeconds = 10
                RunnerCpuRequest = "1"
                RunnerMemoryRequest = "512Mi"
                RunnerMemoryLimit = "4Gi"
            }
        }
        "growth" {
            return [ordered]@{
                ProbeFlagCount = 20
                MaxConnections = 5000
                ConnectionsPerSecond = 50
                StabilizationSeconds = 30
                InitialSyncTimeoutSeconds = 20
                HoldDurationSeconds = 600
                DrainDurationSeconds = 10
                RunnerCpuRequest = "3"
                RunnerMemoryRequest = "4Gi"
                RunnerMemoryLimit = "8Gi"
            }
        }
        default {
            throw "Unknown test profile '$Name'."
        }
    }
}

function Assert-DigestPinnedImage {
    param(
        [Parameter(Mandatory)]
        [string] $Image
    )

    $normalizedImage = $Image.Trim()
    $imageParts = @($normalizedImage -split "@sha256:", 2)
    if (
        $imageParts.Count -ne 2 -or
        $imageParts[0] -notmatch "^[A-Za-z0-9._:/-]+$" -or
        $imageParts[0] -notmatch "/" -or
        $imageParts[1] -notmatch "^[a-fA-F0-9]{64}$"
    ) {
        throw @"
RunnerImage must be an immutable digest reference:
<acr-login-server>/<repository>@sha256:<64-hex-digest>
"@
    }

    return $normalizedImage
}

function Get-LoadgenNodes {
    param(
        [Parameter(Mandatory)]
        [string] $Context
    )

    $nodeJson = (& kubectl `
        --context $Context `
        get nodes `
        -l "workload=loadgen" `
        -o json | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query loadgen nodes through context '$Context'."
    }

    return @(($nodeJson | ConvertFrom-Json).items)
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext
$normalizedRunnerImage = Assert-DigestPinnedImage -Image $RunnerImage

$profileName = $Profile.ToLowerInvariant()
$profileConfig = Get-AksTestProfile -Name $profileName
if ($profileConfig.MaxConnections % $Parallelism -ne 0) {
    throw (
        "Profile '$profileName' has $($profileConfig.MaxConnections) connections, " +
        "which is not divisible by parallelism $Parallelism."
    )
}

$loadgenNodes = @(Get-LoadgenNodes -Context $targetContext)
if ($loadgenNodes.Count -lt $Parallelism) {
    throw (
        "parallelism $Parallelism with separate=true requires at least $Parallelism " +
        "loadgen nodes; found $($loadgenNodes.Count)."
    )
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

Assert-KubernetesObjectExists `
    -Kind "customresourcedefinition" `
    -Name "testruns.k6.io" `
    -Namespace "default" `
    -KubeContext $targetContext
foreach ($object in @(
    @{ Kind = "configmap"; Name = "featbit-k6-target" }
    @{ Kind = "secret"; Name = "featbit-k6-secret" }
    @{ Kind = "configmap"; Name = "featbit-k6-controller" }
    @{ Kind = "secret"; Name = "featbit-k6-controller-secret" }
    @{ Kind = "persistentvolumeclaim"; Name = "featbit-k6-results" }
    @{ Kind = "pod"; Name = "results-reader" }
)) {
    Assert-KubernetesObjectExists `
        -Kind $object.Kind `
        -Name $object.Name `
        -KubeContext $targetContext
}

foreach ($field in @(
    "testrun.spec.initializer.image"
    "testrun.spec.initializer.imagePullPolicy"
    "testrun.spec.initializer.resources"
    "testrun.spec.runner.nodeSelector"
    "testrun.spec.runner.tolerations"
    "testrun.spec.runner.resources"
)) {
    & kubectl --context $targetContext explain $field *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "The installed TestRun CRD does not expose '$field'."
    }
}

$repositoryRoot = Get-RepositoryRoot
$templatePath = Join-Path $repositoryRoot "k8s-infra\templates\testrun-aks.yaml"
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw "AKS TestRun template does not exist: $templatePath"
}

$gitSha = (& git -C $repositoryRoot rev-parse --short=8 HEAD 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $gitSha -notmatch "^[a-fA-F0-9]{8}$") {
    $gitSha = "nogit"
}

$runId = "{0}-{1}-{2}" -f `
    $profileName, `
    [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"), `
    $gitSha.ToLowerInvariant()
$runId = "$runId-$([Guid]::NewGuid().ToString("N").Substring(0, 4))"
$testRunName = "featbit-$runId"
$probeFlagKeys = ((1..$profileConfig.ProbeFlagCount) | ForEach-Object {
    "loadtest-sync-probe-{0:D2}" -f $_
}) -join ","

$renderedTestRun = Get-Content -Raw -LiteralPath $templatePath
$tokens = [ordered]@{
    "__TEST_RUN_NAME__" = $testRunName
    "__RUN_ID__" = $runId
    "__PROFILE__" = $profileName
    "__PARALLELISM__" = $Parallelism
    "__RUNNER_IMAGE__" = $normalizedRunnerImage
    "__RUNNER_CPU_REQUEST__" = $profileConfig.RunnerCpuRequest
    "__RUNNER_MEMORY_REQUEST__" = $profileConfig.RunnerMemoryRequest
    "__RUNNER_MEMORY_LIMIT__" = $profileConfig.RunnerMemoryLimit
    "__PROBE_FLAG_KEYS__" = $probeFlagKeys
    "__MAX_CONNECTIONS__" = $profileConfig.MaxConnections
    "__CONNECTIONS_PER_SECOND__" = $profileConfig.ConnectionsPerSecond
    "__STABILIZATION_SECONDS__" = $profileConfig.StabilizationSeconds
    "__INITIAL_SYNC_TIMEOUT_SECONDS__" = $profileConfig.InitialSyncTimeoutSeconds
    "__HOLD_DURATION_SECONDS__" = $profileConfig.HoldDurationSeconds
    "__DRAIN_DURATION_SECONDS__" = $profileConfig.DrainDurationSeconds
}

foreach ($token in $tokens.GetEnumerator()) {
    $renderedTestRun = $renderedTestRun.Replace($token.Key, [string]$token.Value)
}
if ($renderedTestRun -match "__[A-Z0-9_]+__") {
    $unresolvedTokens = @(
        [regex]::Matches($renderedTestRun, "__[A-Z0-9_]+__") |
        ForEach-Object { $_.Value } |
        Sort-Object -Unique
    )
    throw "The rendered TestRun contains unresolved tokens: $($unresolvedTokens -join ', ')."
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
$renderedTestRun | Set-Content -LiteralPath $manifestPath -Encoding utf8

$metadata = [ordered]@{
    runId = $runId
    testRunName = $testRunName
    createdAtUtc = [DateTime]::UtcNow.ToString("o")
    kubernetesContext = $targetContext
    profile = $profileName
    parallelism = $Parallelism
    runnerImage = $normalizedRunnerImage
    note = $Note
    parameters = $profileConfig
    template = [ordered]@{
        path = $templatePath
        sha256 = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$metadata |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $metadataPath -Encoding utf8

$dryRunJson = (& kubectl `
    --context $targetContext `
    apply `
    --dry-run=server `
    -f $manifestPath `
    -o json | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "The rendered TestRun failed Kubernetes server-side dry-run validation."
}
$dryRunObject = $dryRunJson | ConvertFrom-Json
if (
    $dryRunObject.spec.initializer.image -cne $normalizedRunnerImage -or
    $dryRunObject.spec.runner.image -cne $normalizedRunnerImage
) {
    throw "Initializer and runner must use the same digest-pinned image."
}
$dryRunOutput = "testrun.k6.io/$($dryRunObject.metadata.name)"

Write-Host ""
Write-Host "AKS TestRun rendered and validated; nothing was submitted." -ForegroundColor Green
Write-Host "Kubernetes context: $targetContext"
Write-Host "Profile: $profileName"
Write-Host "Parallelism: $Parallelism"
Write-Host "Total connections: $($profileConfig.MaxConnections)"
Write-Host "Connections per runner: $($profileConfig.MaxConnections / $Parallelism)"
Write-Host "Runner image: $normalizedRunnerImage"
Write-Host "Manifest: $manifestPath"
Write-Host "Metadata: $metadataPath"
Write-Host "Server dry-run: $dryRunOutput"

[pscustomobject]@{
    RunId = $runId
    TestRunName = $testRunName
    Profile = $profileName
    ProbeFlagCount = $profileConfig.ProbeFlagCount
    ManifestPath = $manifestPath
    MetadataPath = $metadataPath
}
