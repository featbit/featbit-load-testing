[CmdletBinding()]
param(
    [ValidateSet("smoke", "baseline", "growth")]
    [string] $Profile = "smoke",

    [string] $Note = "",

    [switch] $NoWait
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Get-TestProfile {
    param([string] $Name)

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
                RunnerMemoryRequest = "4Gi"
                RunnerMemoryLimit = "8Gi"
            }
        }
        default {
            throw "Unknown test profile '$Name'."
        }
    }
}

function Assert-NoActiveLoadTest {
    $podJson = (& kubectl `
        --context $script:LocalKubernetesContext `
        -n $script:LoadTestNamespace `
        get pods `
        -l "loadtest.featbit.io/run-id" `
        -o json | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query existing load-test Pods."
    }

    $podList = $podJson | ConvertFrom-Json
    $activePods = @($podList.items | Where-Object {
        $_.status.phase -in @("Pending", "Running", "Unknown")
    })

    if ($activePods.Count -gt 0) {
        $names = ($activePods | ForEach-Object { $_.metadata.name }) -join ", "
        throw "Another load test is still active: $names"
    }
}

function Get-RunnerPodName {
    param(
        [string] $RunId,
        [string] $TestRunName,
        [DateTime] $Deadline
    )

    do {
        $podJson = (& kubectl `
            --context $script:LocalKubernetesContext `
            -n $script:LoadTestNamespace `
            get pods `
            -l "loadtest.featbit.io/run-id=$RunId" `
            -o json | Out-String)

        if ($LASTEXITCODE -eq 0) {
            $podList = $podJson | ConvertFrom-Json
            $runnerPod = @($podList.items | Where-Object {
                $_.metadata.name -like "$TestRunName-1-*"
            } | Select-Object -First 1)

            if ($runnerPod.Count -gt 0) {
                return $runnerPod[0].metadata.name
            }
        }

        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $Deadline)

    throw "Timed out waiting for the k6 runner Pod."
}

function Wait-RunnerJob {
    param(
        [string] $JobName,
        [DateTime] $Deadline
    )

    do {
        $jobJson = (& kubectl `
            --context $script:LocalKubernetesContext `
            -n $script:LoadTestNamespace `
            get job $JobName `
            -o json 2>$null | Out-String)

        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($jobJson)) {
            $job = $jobJson | ConvertFrom-Json
            $succeededProperty = $job.status.PSObject.Properties["succeeded"]
            $failedProperty = $job.status.PSObject.Properties["failed"]
            $succeeded = if ($null -eq $succeededProperty) { 0 } else { [int] $succeededProperty.Value }
            $failed = if ($null -eq $failedProperty) { 0 } else { [int] $failedProperty.Value }

            if ($succeeded -ge 1) {
                return "passed"
            }
            if ($failed -ge 1) {
                return "failed"
            }
        }

        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $Deadline)

    return "timeout"
}

Assert-LocalKubernetesContext
Assert-CommandAvailable -Name "docker"
Assert-CommandAvailable -Name "git"
Assert-KubernetesObjectExists -Kind "configmap" -Name "featbit-k6-target"
Assert-KubernetesObjectExists -Kind "secret" -Name "featbit-k6-secret"
Assert-KubernetesObjectExists -Kind "configmap" -Name "featbit-k6-controller"
Assert-KubernetesObjectExists -Kind "secret" -Name "featbit-k6-controller-secret"
Assert-KubernetesObjectExists -Kind "pod" -Name "results-reader"
Assert-NoActiveLoadTest

& docker image inspect $script:K6Image *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Local image '$script:K6Image' does not exist. Run bootstrap.ps1 first."
}

$repositoryRoot = Get-RepositoryRoot
$profileName = $Profile.ToLowerInvariant()
$profileConfig = Get-TestProfile -Name $profileName
$probeFlagKeys = ((1..$profileConfig.ProbeFlagCount) | ForEach-Object {
    "loadtest-sync-probe-{0:D2}" -f $_
}) -join ","

Write-Host "Provisioning $($profileConfig.ProbeFlagCount) probe flag(s) for profile '$profileName' ..."
& (Join-Path $PSScriptRoot "prepare-probe-flags.ps1") `
    -ProbeFlagCount $profileConfig.ProbeFlagCount

$gitSha = (& git -C $repositoryRoot rev-parse --short=8 HEAD 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitSha)) {
    $gitSha = "nogit"
}

$runId = "{0}-{1}-{2}" -f `
    $profileName, `
    [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"), `
    $gitSha.ToLowerInvariant()
$runId = "$runId-$([Guid]::NewGuid().ToString("N").Substring(0, 4))"
$testRunName = "featbit-$runId"

$templatePath = Join-Path $repositoryRoot "k8s-infra\templates\testrun.yaml"
$renderedTestRun = Get-Content -Raw $templatePath
$tokens = [ordered]@{
    "__TEST_RUN_NAME__" = $testRunName
    "__RUN_ID__" = $runId
    "__PROFILE__" = $profileName
    "__PROBE_FLAG_KEYS__" = $probeFlagKeys
    "__MAX_CONNECTIONS__" = $profileConfig.MaxConnections
    "__CONNECTIONS_PER_SECOND__" = $profileConfig.ConnectionsPerSecond
    "__STABILIZATION_SECONDS__" = $profileConfig.StabilizationSeconds
    "__INITIAL_SYNC_TIMEOUT_SECONDS__" = $profileConfig.InitialSyncTimeoutSeconds
    "__HOLD_DURATION_SECONDS__" = $profileConfig.HoldDurationSeconds
    "__DRAIN_DURATION_SECONDS__" = $profileConfig.DrainDurationSeconds
    "__RUNNER_MEMORY_REQUEST__" = $profileConfig.RunnerMemoryRequest
    "__RUNNER_MEMORY_LIMIT__" = $profileConfig.RunnerMemoryLimit
}

foreach ($token in $tokens.GetEnumerator()) {
    $renderedTestRun = $renderedTestRun.Replace($token.Key, [string]$token.Value)
}

if ($renderedTestRun -match "__[A-Z0-9_]+__") {
    throw "The rendered TestRun still contains an unresolved template token."
}

$resultsDirectory = Join-Path $repositoryRoot "results"
$null = New-Item -ItemType Directory -Force $resultsDirectory
$manifestPath = Join-Path $resultsDirectory "$runId-testrun.yaml"
$metadataPath = Join-Path $resultsDirectory "$runId-metadata.json"
$renderedTestRun | Set-Content -Encoding utf8 $manifestPath

$metadata = [ordered]@{
    runId = $runId
    testRunName = $testRunName
    createdAtUtc = [DateTime]::UtcNow.ToString("o")
    kubernetesContext = $script:LocalKubernetesContext
    profile = $profileName
    note = $Note
    gitCommit = $gitSha
    k6Image = $script:K6Image
    parameters = $profileConfig
    probeFlagKeys = $probeFlagKeys.Split(",")
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $metadataPath

Write-Host "Creating TestRun $testRunName ..."
Invoke-CheckedCommand `
    -FilePath "kubectl" `
    -ArgumentList @("--context", $script:LocalKubernetesContext, "create", "-f", $manifestPath) `
    -FailureMessage "Failed to create TestRun '$testRunName'"

Write-Host "RUN_ID=$runId"
Write-Host "Metadata: $metadataPath"

if ($NoWait) {
    Write-Host "TestRun submitted. Use collect-results.ps1 -RunId $runId when it finishes."
    return
}

$runnerPodDeadline = [DateTime]::UtcNow.AddMinutes(5)
$runnerPodName = Get-RunnerPodName `
    -RunId $runId `
    -TestRunName $testRunName `
    -Deadline $runnerPodDeadline

Invoke-CheckedCommand `
    -FilePath "kubectl" `
    -ArgumentList @(
        "--context", $script:LocalKubernetesContext,
        "-n", $script:LoadTestNamespace,
        "wait", "--for=condition=Ready", "pod/$runnerPodName", "--timeout=5m"
    ) `
    -FailureMessage "The k6 runner Pod did not become ready"

Write-Host "Following logs from $runnerPodName ..."
& kubectl `
    --context $script:LocalKubernetesContext `
    -n $script:LoadTestNamespace `
    logs -f $runnerPodName --pod-running-timeout=5m
if ($LASTEXITCODE -ne 0) {
    Write-Warning "The log stream ended with an error; checking the runner Job status."
}

$rampSeconds = [Math]::Ceiling(
    $profileConfig.MaxConnections / $profileConfig.ConnectionsPerSecond
)
$maximumRunSeconds = `
    $rampSeconds + `
    $profileConfig.StabilizationSeconds + `
    $profileConfig.HoldDurationSeconds + `
    $profileConfig.DrainDurationSeconds + `
    300
$jobDeadline = [DateTime]::UtcNow.AddSeconds($maximumRunSeconds)
$runnerJobName = "$testRunName-1"
$result = Wait-RunnerJob -JobName $runnerJobName -Deadline $jobDeadline

& (Join-Path $PSScriptRoot "collect-results.ps1") -RunId $runId

switch ($result) {
    "passed" {
        Write-Host "Test PASSED: $runId" -ForegroundColor Green
    }
    "failed" {
        throw "Test FAILED: $runId. Review the runner log and summary JSON."
    }
    default {
        throw "Test result is INVALID: runner Job did not finish before the timeout."
    }
}
