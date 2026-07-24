[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [string] $RunId,

    [Parameter(Mandatory)]
    [string] $KubeContext,

    [string] $OutputDirectory = "",

    [switch] $AllowIncomplete,

    [switch] $AllowFailedRunners,

    [switch] $OpenReports
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Invoke-KubectlText {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter(Mandatory)]
        [string] $FailureMessage,

        [ValidateRange(1, 10)]
        [int] $MaxAttempts = 4
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $output = (
            & kubectl --request-timeout=30s @Arguments |
                Out-String
        )
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return $output
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Warning (
                "kubectl read failed (attempt $attempt/$MaxAttempts, exit $exitCode); " +
                "retrying in $($attempt * 2) second(s)."
            )
            Start-Sleep -Seconds ($attempt * 2)
        }
    }

    throw "$FailureMessage kubectl failed after $MaxAttempts attempts."
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [AllowEmptyString()]
        [string] $Value
    )

    [IO.File]::WriteAllText(
        $Path,
        $Value,
        [Text.UTF8Encoding]::new($false)
    )
}

function Test-JobComplete {
    param(
        [Parameter(Mandatory)]
        [object] $Job
    )

    return @($Job.status.conditions | Where-Object {
        $_.type -eq "Complete" -and $_.status -eq "True"
    }).Count -gt 0
}

function Test-JobFailed {
    param(
        [Parameter(Mandatory)]
        [object] $Job
    )

    return @($Job.status.conditions | Where-Object {
        $_.type -eq "Failed" -and $_.status -eq "True"
    }).Count -gt 0
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext
Assert-KubernetesObjectExists `
    -Kind "pod" `
    -Name "results-reader" `
    -KubeContext $targetContext

$testRunName = "featbit-$RunId"
Assert-KubernetesObjectExists `
    -Kind "testrun" `
    -Name $testRunName `
    -KubeContext $targetContext

$namespace = $script:LoadTestNamespace
$testRunJson = Invoke-KubectlText `
    -Arguments @(
        "--context", $targetContext,
        "-n", $namespace,
        "get", "testrun", $testRunName,
        "-o", "json"
    ) `
    -FailureMessage "Failed to read TestRun '$testRunName'."
$testRun = $testRunJson | ConvertFrom-Json
$stage = [string]$testRun.status.stage
$parallelism = [int]$testRun.spec.parallelism
if (-not $AllowIncomplete -and $stage -ne "finished") {
    throw "TestRun '$testRunName' is at stage '$stage'; collection requires 'finished'."
}
if ($parallelism -lt 1) {
    throw "TestRun '$testRunName' has invalid parallelism '$parallelism'."
}

$jobsJson = Invoke-KubectlText `
    -Arguments @(
        "--context", $targetContext,
        "-n", $namespace,
        "get", "jobs",
        "-l", "k6_cr=$testRunName",
        "-o", "json"
    ) `
    -FailureMessage "Failed to read Jobs for TestRun '$testRunName'."
$jobs = @((ConvertFrom-Json $jobsJson).items)
$runnerJobs = @($jobs | Where-Object {
    $runnerLabel = $_.metadata.labels.PSObject.Properties["runner"]
    ($null -ne $runnerLabel -and $runnerLabel.Value -eq "true") -or
    $_.metadata.name -match "^$([regex]::Escape($testRunName))-\d+$"
})

foreach ($runnerIndex in 1..$parallelism) {
    $expectedJobName = "$testRunName-$runnerIndex"
    $matchingJobs = @($runnerJobs | Where-Object {
        $_.metadata.name -ceq $expectedJobName
    })
    if ($matchingJobs.Count -ne 1) {
        throw "Expected exactly one runner Job '$expectedJobName'; found $($matchingJobs.Count)."
    }
    $runnerJob = $matchingJobs[0]
    $jobComplete = Test-JobComplete -Job $runnerJob
    $diagnosticFailure = (
        $AllowFailedRunners -and
        (Test-JobFailed -Job $runnerJob)
    )
    if (-not $AllowIncomplete -and -not $jobComplete -and -not $diagnosticFailure) {
        throw (
            "Runner Job '$expectedJobName' is neither Complete nor an explicitly " +
            "allowed Failed job. Use -AllowFailedRunners only to preserve " +
            "diagnostic artifacts from a finished performance test."
        )
    }
}

$remoteListing = Invoke-KubectlText `
    -Arguments @(
        "--context", $targetContext,
        "-n", $namespace,
        "exec", "results-reader", "--",
        "ls", "-1", "/results"
    ) `
    -FailureMessage "Failed to list artifacts through results-reader."
$remoteNames = @(
    $remoteListing -split "\r?\n" |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$artifactPattern = (
    "^$([regex]::Escape($testRunName))-" +
    "(?<runner>\d+)-[a-z0-9]+-" +
    "(?<kind>summary\.json|report\.html)$"
)
$artifacts = @(
    foreach ($remoteName in $remoteNames) {
        $match = [regex]::Match($remoteName, $artifactPattern)
        if ($match.Success) {
            [pscustomobject]@{
                Name = $remoteName
                Runner = [int]$match.Groups["runner"].Value
                Kind = $match.Groups["kind"].Value
            }
        }
    }
)

foreach ($runnerIndex in 1..$parallelism) {
    foreach ($kind in @("summary.json", "report.html")) {
        $matches = @($artifacts | Where-Object {
            $_.Runner -eq $runnerIndex -and $_.Kind -ceq $kind
        })
        if ($matches.Count -ne 1) {
            throw (
                "Expected exactly one '$kind' artifact for runner $runnerIndex; " +
                "found $($matches.Count)."
            )
        }
    }
}
if ($artifacts.Count -ne ($parallelism * 2)) {
    throw (
        "Expected $($parallelism * 2) runner artifacts; " +
        "found $($artifacts.Count)."
    )
}

$repositoryRoot = Get-RepositoryRoot
$archiveDirectory = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path (Join-Path $repositoryRoot "results") $RunId
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputDirectory
    )
}
$null = New-Item -ItemType Directory -Force -Path $archiveDirectory

$sortedArtifacts = @($artifacts | Sort-Object Runner, Kind)
$hashArguments = @(
    "--context", $targetContext,
    "-n", $namespace,
    "exec", "results-reader", "--",
    "sha256sum"
) + @($sortedArtifacts | ForEach-Object {
    "/results/$($_.Name)"
})
$remoteHashOutput = Invoke-KubectlText `
    -Arguments $hashArguments `
    -FailureMessage "Failed to hash remote runner artifacts."
$remoteHashes = @{}
foreach ($hashLine in @($remoteHashOutput -split "\r?\n")) {
    if ([string]::IsNullOrWhiteSpace($hashLine)) {
        continue
    }
    if ($hashLine -notmatch "^(?<Hash>[a-fA-F0-9]{64})\s+(?<Path>.+)$") {
        throw "Remote artifact hash output contains an invalid line: '$hashLine'."
    }

    $artifactName = [IO.Path]::GetFileName($Matches.Path.TrimStart("*"))
    if ($remoteHashes.ContainsKey($artifactName)) {
        throw "Remote artifact hash output contains duplicate '$artifactName'."
    }
    $remoteHashes[$artifactName] = $Matches.Hash.ToLowerInvariant()
}
if ($remoteHashes.Count -ne $sortedArtifacts.Count) {
    throw (
        "Expected $($sortedArtifacts.Count) remote artifact hashes; " +
        "received $($remoteHashes.Count)."
    )
}

$artifactEvidence = @()
foreach ($artifact in $sortedArtifacts) {
    $remotePath = "/results/$($artifact.Name)"
    if (-not $remoteHashes.ContainsKey($artifact.Name)) {
        throw "Remote artifact hash is missing for '$($artifact.Name)'."
    }
    $remoteHash = $remoteHashes[$artifact.Name]

    $localPath = Join-Path $archiveDirectory $artifact.Name
    $copyRequired = $true
    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        $existingHash = (
            Get-FileHash -LiteralPath $localPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($existingHash -eq $remoteHash) {
            $copyRequired = $false
        }
        else {
            throw (
                "Local artifact '$localPath' already exists with a different hash. " +
                "Use another OutputDirectory instead of overwriting evidence."
            )
        }
    }

    if ($copyRequired) {
        $temporaryPath = "$localPath.partial-$([Guid]::NewGuid().ToString('N'))"
        try {
            $temporaryName = Split-Path -Leaf $temporaryPath
            $copySucceeded = $false
            for ($attempt = 1; $attempt -le 4; $attempt++) {
                if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                    Remove-Item -LiteralPath $temporaryPath -Force
                }

                Push-Location $archiveDirectory
                try {
                    & kubectl --request-timeout=30s `
                        --context $targetContext `
                        -n $namespace `
                        cp `
                        "results-reader:$remotePath" `
                        ".\$temporaryName"
                    $exitCode = $LASTEXITCODE
                }
                finally {
                    Pop-Location
                }

                if ($exitCode -eq 0) {
                    $copySucceeded = $true
                    break
                }

                if ($attempt -lt 4) {
                    Write-Warning (
                        "Copying '$($artifact.Name)' failed " +
                        "(attempt $attempt/4, exit $exitCode); " +
                        "retrying in $($attempt * 2) second(s)."
                    )
                    Start-Sleep -Seconds ($attempt * 2)
                }
            }

            if (-not $copySucceeded) {
                throw (
                    "Failed to copy '$($artifact.Name)' from results-reader " +
                    "after 4 attempts."
                )
            }

            $copiedHash = (
                Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            if ($copiedHash -ne $remoteHash) {
                throw "SHA-256 mismatch after copying '$($artifact.Name)'."
            }
            Move-Item `
                -LiteralPath $temporaryPath `
                -Destination $localPath
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
    }

    $localItem = Get-Item -LiteralPath $localPath
    $artifactEvidence += [pscustomobject]@{
        name = $artifact.Name
        runner = $artifact.Runner
        kind = $artifact.Kind
        bytes = $localItem.Length
        sha256 = $remoteHash
        path = $localItem.FullName
    }
}

Write-Utf8Text `
    -Path (Join-Path $archiveDirectory "testrun-cluster.json") `
    -Value $testRunJson
Write-Utf8Text `
    -Path (Join-Path $archiveDirectory "jobs-cluster.json") `
    -Value $jobsJson

$podsJson = Invoke-KubectlText `
    -Arguments @(
        "--context", $targetContext,
        "-n", $namespace,
        "get", "pods",
        "-l", "k6_cr=$testRunName",
        "-o", "json"
    ) `
    -FailureMessage "Failed to read Pods for TestRun '$testRunName'."
Write-Utf8Text `
    -Path (Join-Path $archiveDirectory "pods-cluster.json") `
    -Value $podsJson

$eventsText = Invoke-KubectlText `
    -Arguments @(
        "--context", $targetContext,
        "-n", $namespace,
        "get", "events",
        "--sort-by=.lastTimestamp"
    ) `
    -FailureMessage "Failed to read namespace events."
Write-Utf8Text `
    -Path (Join-Path $archiveDirectory "events.txt") `
    -Value $eventsText

foreach ($job in ($jobs | Sort-Object { $_.metadata.name })) {
    $jobName = [string]$job.metadata.name
    $jobLog = Invoke-KubectlText `
        -Arguments @(
            "--context", $targetContext,
            "-n", $namespace,
            "logs", "job/$jobName"
        ) `
        -FailureMessage "Failed to read logs for Job '$jobName'."
    Write-Utf8Text `
        -Path (Join-Path $archiveDirectory "$jobName.log") `
        -Value $jobLog
}

$supplementalEvidence = @()
foreach ($sourceSuffix in @(
    "testrun.yaml",
    "metadata.json",
    "resource-samples.jsonl",
    "resource-summary.json",
    "resource-monitor.log",
    "resource-monitor-error.log",
    "els-deployment.json",
    "els-pods.json"
)) {
    $sourcePath = Join-Path $repositoryRoot "results\$RunId-$sourceSuffix"
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
        $destinationPath = Join-Path $archiveDirectory "$RunId-$sourceSuffix"
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            Copy-Item `
                -LiteralPath $sourcePath `
                -Destination $destinationPath
        }
        else {
            $sourceHash = (
                Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256
            ).Hash
            $destinationHash = (
                Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256
            ).Hash
            if ($sourceHash -cne $destinationHash) {
                throw "Archived '$destinationPath' differs from source '$sourcePath'."
            }
        }

        $supplementalEvidence += [pscustomobject]@{
            kind = $sourceSuffix
            name = [IO.Path]::GetFileName($destinationPath)
            path = $destinationPath
            length = (Get-Item -LiteralPath $destinationPath).Length
            sha256 = (
                Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
    }
}

$profileLabel = $testRun.metadata.labels.PSObject.Properties[
    "loadtest.featbit.io/profile"
]
$profileName = if ($null -eq $profileLabel) {
    ""
}
else {
    [string]$profileLabel.Value
}
$requiresResourceEvidence = $profileName -in @("growth", "growth-plus")
$resourceSummaryEvidence = @($supplementalEvidence | Where-Object {
    $_.kind -ceq "resource-summary.json"
})
$resourceSamplesEvidence = @($supplementalEvidence | Where-Object {
    $_.kind -ceq "resource-samples.jsonl"
})
$resourceEvidenceComplete = if (-not $requiresResourceEvidence) {
    $true
}
elseif (
    $resourceSummaryEvidence.Count -ne 1 -or
    $resourceSamplesEvidence.Count -ne 1
) {
    $false
}
else {
    $resourceSummary = Get-Content `
        -Raw `
        -LiteralPath $resourceSummaryEvidence[0].path |
        ConvertFrom-Json
    [bool]$resourceSummary.complete
}

$runnerSummaries = @()
foreach ($artifact in ($artifactEvidence | Where-Object {
    $_.kind -ceq "summary.json"
} | Sort-Object runner)) {
    $summary = Get-Content -Raw -LiteralPath $artifact.path | ConvertFrom-Json
    $failedThresholds = @(
        foreach ($metricProperty in $summary.metrics.PSObject.Properties) {
            $thresholdsProperty = $metricProperty.Value.PSObject.Properties["thresholds"]
            if ($null -eq $thresholdsProperty -or $null -eq $thresholdsProperty.Value) {
                continue
            }
            foreach ($thresholdProperty in $thresholdsProperty.Value.PSObject.Properties) {
                $thresholdValue = $thresholdProperty.Value
                $thresholdFailed = if ($thresholdValue -is [bool]) {
                    # k6 v2 summary-export stores whether the threshold was crossed.
                    [bool]$thresholdValue
                }
                else {
                    $okProperty = $thresholdValue.PSObject.Properties["ok"]
                    if ($null -eq $okProperty) {
                        throw (
                            "Unsupported threshold result for " +
                            "'$($metricProperty.Name): $($thresholdProperty.Name)'."
                        )
                    }
                    -not [bool]$okProperty.Value
                }

                if ($thresholdFailed) {
                    "$($metricProperty.Name): $($thresholdProperty.Name)"
                }
            }
        }
    )
    $runnerSummaries += [pscustomobject]@{
        runner = $artifact.runner
        file = $artifact.name
        thresholdFailures = $failedThresholds
    }
}

$collectionManifest = [ordered]@{
    runId = $RunId
    testRunName = $testRunName
    collectedAtUtc = [DateTime]::UtcNow.ToString("o")
    kubernetesContext = $targetContext
    profile = $profileName
    stage = $stage
    parallelism = $parallelism
    resourceEvidenceRequired = $requiresResourceEvidence
    resourceEvidenceComplete = $resourceEvidenceComplete
    complete = (
        $stage -eq "finished" -and
        $resourceEvidenceComplete -and
        @($runnerSummaries | Where-Object {
            $_.thresholdFailures.Count -gt 0
        }).Count -eq 0
    )
    artifacts = $artifactEvidence
    supplementalArtifacts = $supplementalEvidence
    runners = $runnerSummaries
}
$collectionPath = Join-Path $archiveDirectory "collection.json"
$collectionManifest |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $collectionPath -Encoding utf8

$checksumLines = @(
    @($artifactEvidence) + @($supplementalEvidence) |
    Sort-Object name |
    ForEach-Object { "$($_.sha256)  $($_.name)" }
)
Write-Utf8Text `
    -Path (Join-Path $archiveDirectory "checksums.sha256") `
    -Value (($checksumLines -join [Environment]::NewLine) + [Environment]::NewLine)

Write-Host ""
Write-Host "AKS result collection completed; no cluster resources were deleted." -ForegroundColor Green
Write-Host "TestRun: $testRunName"
Write-Host "Stage: $stage"
Write-Host (
    "Artifacts: {0} runner + {1} supplemental" -f
    $artifactEvidence.Count,
    $supplementalEvidence.Count
)
Write-Host "Archive: $archiveDirectory"
foreach ($runnerSummary in $runnerSummaries) {
    if ($runnerSummary.thresholdFailures.Count -eq 0) {
        Write-Host "Runner $($runnerSummary.runner): all exported thresholds passed"
    }
    else {
        Write-Warning (
            "Runner $($runnerSummary.runner) threshold failures: " +
            ($runnerSummary.thresholdFailures -join "; ")
        )
    }
}

if ($OpenReports) {
    foreach ($report in ($artifactEvidence | Where-Object {
        $_.kind -ceq "report.html"
    } | Sort-Object runner)) {
        Start-Process -FilePath $report.path
    }
}

[pscustomobject]@{
    RunId = $RunId
    TestRunName = $testRunName
    Stage = $stage
    ArchiveDirectory = $archiveDirectory
    CollectionPath = $collectionPath
    ArtifactCount = $artifactEvidence.Count
}
