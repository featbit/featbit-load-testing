[CmdletBinding()]
param(
    [string] $MatrixPath = "",

    [string] $StatePath = "",

    [switch] $Resume,

    [switch] $RetryFailed,

    [switch] $ValidateOnly,

    [ValidateRange(0, 100)]
    [int] $MaxFreshRuns = 100
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Write-Utf8Json {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [object] $Value,

        [ValidateRange(3, 30)]
        [int] $Depth = 15
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    $temporaryPath = "$Path.partial-$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Invoke-KubectlText {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter(Mandatory)]
        [string] $FailureMessage,

        [ValidateRange(1, 10)]
        [int] $MaxAttempts = 4
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt += 1) {
        $output = (
            & kubectl --request-timeout=30s @Arguments 2>&1 |
                Out-String
        )
        if ($LASTEXITCODE -eq 0) {
            return $output
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Warning (
                "$FailureMessage (attempt $attempt/$MaxAttempts); " +
                "retrying in $($attempt * 2)s."
            )
            Start-Sleep -Seconds ($attempt * 2)
        }
    }

    throw "$FailureMessage kubectl failed after $MaxAttempts attempts.`n$output"
}

function Invoke-KubectlJson {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter(Mandatory)]
        [string] $FailureMessage
    )

    return (
        Invoke-KubectlText `
            -Arguments $Arguments `
            -FailureMessage $FailureMessage
    ) | ConvertFrom-Json
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [AllowNull()]
        [object] $Actual,

        [AllowNull()]
        [object] $Expected
    )

    if ([string]$Actual -cne [string]$Expected) {
        throw "$Name mismatch: expected '$Expected', found '$Actual'."
    }
}

function Get-MatrixGroup {
    param(
        [Parameter(Mandatory)]
        [string] $GroupId
    )

    $matches = @($script:Matrix.groups | Where-Object id -ceq $GroupId)
    if ($matches.Count -ne 1) {
        throw "Matrix group '$GroupId' does not resolve exactly once."
    }
    return $matches[0]
}

function Assert-MatrixDefinition {
    $fixed = $script:Matrix.fixed
    $groups = @($script:Matrix.groups)
    $executionOrder = @($script:Matrix.executionOrder)

    if ($groups.Count -lt 1) {
        throw "The matrix must contain at least one group."
    }
    Assert-Equal `
        -Name "matrix execution count" `
        -Actual $executionOrder.Count `
        -Expected ($groups.Count * [int]$fixed.repetitions)
    Assert-Equal `
        -Name "expected revision count" `
        -Actual @($fixed.expectedRevisions).Count `
        -Expected 10

    $duplicateGroups = @($groups | Group-Object id | Where-Object Count -ne 1)
    if ($duplicateGroups.Count -ne 0) {
        throw "Matrix group IDs must be unique."
    }

    $expectedKeys = [Collections.Generic.List[string]]::new()
    foreach ($group in $groups) {
        $parallelism = [int]$group.parallelism
        $connectionsPerRunner = [int]$group.connectionsPerRunner
        $runnersPerNode = [int]$group.runnersPerNode
        $elsReplicas = [int]$group.elsReplicas

        if ($parallelism -lt 1 -or $connectionsPerRunner -lt 1 -or $runnersPerNode -lt 1) {
            throw "Group '$($group.id)' contains a non-positive runner setting."
        }
        Assert-Equal `
            -Name "group '$($group.id)' total connections" `
            -Actual ($parallelism * $connectionsPerRunner) `
            -Expected $fixed.totalConnections
        Assert-Equal `
            -Name "group '$($group.id)' loadgen distribution" `
            -Actual $parallelism `
            -Expected ($runnersPerNode * [int]$fixed.loadgenNodeCount)
        if (
            $elsReplicas -lt 1 -or
            $elsReplicas % [int]$fixed.featbitNodeCount -ne 0
        ) {
            throw (
                "Group '$($group.id)' ELS replicas must be positive and evenly " +
                "divisible across the fixed FeatBit node count."
            )
        }
        foreach ($resourceName in @(
            "cpuRequest",
            "memoryRequest",
            "memoryLimit"
        )) {
            if (
                $null -eq $group.runnerResources.PSObject.Properties[$resourceName] -or
                [string]::IsNullOrWhiteSpace(
                    [string]$group.runnerResources.$resourceName
                )
            ) {
                throw "Group '$($group.id)' is missing runner resource '$resourceName'."
            }
        }

        foreach ($replicate in 1..[int]$fixed.repetitions) {
            $expectedKeys.Add("$($group.id):$replicate")
        }
    }

    $actualKeys = [Collections.Generic.List[string]]::new()
    $existingRunIds = [Collections.Generic.List[string]]::new()
    foreach ($entry in $executionOrder) {
        $group = Get-MatrixGroup -GroupId ([string]$entry.group)
        $replicate = [int]$entry.replicate
        if ($replicate -lt 1 -or $replicate -gt [int]$fixed.repetitions) {
            throw (
                "Execution entry '$($group.id):$replicate' is outside the " +
                "configured repetition range."
            )
        }
        $actualKeys.Add("$($group.id):$replicate")
        if (
            $null -ne $entry.PSObject.Properties["existingRunId"] -and
            -not [string]::IsNullOrWhiteSpace([string]$entry.existingRunId)
        ) {
            $existingRunIds.Add([string]$entry.existingRunId)
        }
    }
    if (
        @($actualKeys | Group-Object | Where-Object Count -ne 1).Count -ne 0 -or
        (@($actualKeys | Sort-Object) -join "`n") -cne
            (@($expectedKeys | Sort-Object) -join "`n")
    ) {
        throw "Execution order must contain every group/replicate pair exactly once."
    }
    if (@($existingRunIds | Group-Object | Where-Object Count -ne 1).Count -ne 0) {
        throw "Existing seed run IDs must be unique."
    }

    if (
        [double]$script:Matrix.practicalEquivalence.relativeFraction -le 0 -or
        [double]$script:Matrix.practicalEquivalence.relativeFraction -ge 1 -or
        [double]$script:Matrix.practicalEquivalence.absoluteMilliseconds -le 0
    ) {
        throw "Practical-equivalence bounds must be positive and relativeFraction < 1."
    }
    if ([int]$fixed.holdDurationSeconds -le (
        @($fixed.expectedRevisions).Count *
        [int]$fixed.revisionIntervalSeconds
    )) {
        throw "Hold duration is too short to contain all configured revisions."
    }

    $sentinelEnabled = $fixed.PSObject.Properties["enableElsSentinelMatrix"]
    if ($null -ne $sentinelEnabled -and [bool]$sentinelEnabled.Value) {
        $stageTimingEnabled = $fixed.PSObject.Properties["enableStageLatencyTiming"]
        if ($null -eq $stageTimingEnabled -or -not [bool]$stageTimingEnabled.Value) {
            throw "The ELS sentinel matrix requires enableStageLatencyTiming=true."
        }
        foreach ($propertyName in @(
            "sentinelConnectionsPerTarget",
            "sentinelHoldDurationSeconds"
        )) {
            if ($null -eq $fixed.PSObject.Properties[$propertyName]) {
                throw "The ELS sentinel matrix is missing '$propertyName'."
            }
        }
        if ([int]$fixed.sentinelConnectionsPerTarget -lt 1) {
            throw "sentinelConnectionsPerTarget must be positive."
        }
        if ([int]$fixed.sentinelHoldDurationSeconds -lt 300) {
            throw "sentinelHoldDurationSeconds must be at least 300."
        }
    }
}

function New-MatrixState {
    param(
        [Parameter(Mandatory)]
        [string] $MatrixPath,

        [Parameter(Mandatory)]
        [string] $MatrixHash
    )

    $runs = [Collections.Generic.List[object]]::new()
    for (
        $entryIndex = 0;
        $entryIndex -lt @($script:Matrix.executionOrder).Count;
        $entryIndex += 1
    ) {
        $entry = @($script:Matrix.executionOrder)[$entryIndex]
        $hasExistingRun = (
            $null -ne $entry.PSObject.Properties["existingRunId"] -and
            -not [string]::IsNullOrWhiteSpace([string]$entry.existingRunId)
        )
        $runs.Add([pscustomobject][ordered]@{
            sequence = $entryIndex + 1
            group = [string]$entry.group
            replicate = [int]$entry.replicate
            source = if ($hasExistingRun) { "existing" } else { "fresh" }
            runId = if ($hasExistingRun) { [string]$entry.existingRunId } else { "" }
            testRunName = ""
            status = "pending"
            stage = ""
            startedAtUtc = $null
            completedAtUtc = $null
            archiveDirectory = ""
            collectionComplete = $false
            resourceEvidenceComplete = $false
            runnerPlacementPath = ""
            analysis = $null
            stageLatencyAnalysis = $null
            sentinelAnalysis = $null
            error = ""
        })
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        matrixId = $script:Matrix.matrixId
        matrixPath = $MatrixPath
        matrixSha256 = $MatrixHash
        createdAtUtc = [DateTime]::UtcNow.ToString("o")
        updatedAtUtc = [DateTime]::UtcNow.ToString("o")
        completedAtUtc = $null
        status = "running"
        kubernetesContext = $script:KubeContext
        preflight = $null
        runs = @($runs)
    }
}

function Save-State {
    if ($script:ValidateOnly) {
        return
    }
    $script:State.updatedAtUtc = [DateTime]::UtcNow.ToString("o")
    Write-Utf8Json -Path $script:ResolvedStatePath -Value $script:State
}

function Get-ElsState {
    $deployment = Invoke-KubectlJson `
        -Arguments @(
            "--context", $script:KubeContext,
            "-n", "featbit",
            "get", "deployment", "featbit-els",
            "-o", "json"
        ) `
        -FailureMessage "Failed to read the ELS deployment."
    $podList = Invoke-KubectlJson `
        -Arguments @(
            "--context", $script:KubeContext,
            "-n", "featbit",
            "get", "pods",
            "-l", "app.kubernetes.io/component=els",
            "-o", "json"
        ) `
        -FailureMessage "Failed to read ELS pods."

    return [pscustomobject]@{
        deployment = $deployment
        pods = @($podList.items)
    }
}

function Assert-ElsContract {
    param(
        [Parameter(Mandatory)]
        [object] $Deployment
    )

    $container = $Deployment.spec.template.spec.containers[0]
    $expected = $script:Matrix.fixed
    Assert-Equal -Name "ELS image" -Actual $container.image -Expected $expected.elsImage
    Assert-Equal `
        -Name "ELS CPU request" `
        -Actual $container.resources.requests.cpu `
        -Expected $expected.elsResources.cpuRequest
    Assert-Equal `
        -Name "ELS CPU limit" `
        -Actual $container.resources.limits.cpu `
        -Expected $expected.elsResources.cpuLimit
    Assert-Equal `
        -Name "ELS memory request" `
        -Actual $container.resources.requests.memory `
        -Expected $expected.elsResources.memoryRequest
    Assert-Equal `
        -Name "ELS memory limit" `
        -Actual $container.resources.limits.memory `
        -Expected $expected.elsResources.memoryLimit
}

function Assert-ElsPlacement {
    param(
        [Parameter(Mandatory)]
        [object] $ElsState,

        [Parameter(Mandatory)]
        [int] $ExpectedReplicas
    )

    $deployment = $ElsState.deployment
    $pods = @($ElsState.pods)
    Assert-ElsContract -Deployment $deployment
    Assert-Equal `
        -Name "ELS desired replicas" `
        -Actual $deployment.spec.replicas `
        -Expected $ExpectedReplicas
    Assert-Equal `
        -Name "ELS ready replicas" `
        -Actual $deployment.status.readyReplicas `
        -Expected $ExpectedReplicas

    $readyPods = @($pods | Where-Object {
        $null -eq $_.metadata.PSObject.Properties["deletionTimestamp"] -and
        $_.status.phase -eq "Running" -and
        @($_.status.containerStatuses).Count -gt 0 -and
        @($_.status.containerStatuses | Where-Object ready).Count -eq
            @($_.status.containerStatuses).Count
    })
    Assert-Equal `
        -Name "ELS ready pod count" `
        -Actual $readyPods.Count `
        -Expected $ExpectedReplicas

    $expectedPerNode = $ExpectedReplicas / [int]$script:Matrix.fixed.featbitNodeCount
    if ($expectedPerNode -ne [Math]::Floor($expectedPerNode)) {
        throw (
            "ELS replicas $ExpectedReplicas cannot be evenly placed on " +
            "$($script:Matrix.fixed.featbitNodeCount) FeatBit nodes."
        )
    }
    $placement = @(
        $readyPods |
            Group-Object { $_.spec.nodeName } |
            Sort-Object Name
    )
    Assert-Equal `
        -Name "ELS placement node count" `
        -Actual $placement.Count `
        -Expected $script:Matrix.fixed.featbitNodeCount
    foreach ($nodeGroup in $placement) {
        Assert-Equal `
            -Name "ELS pods on node '$($nodeGroup.Name)'" `
            -Actual $nodeGroup.Count `
            -Expected ([int]$expectedPerNode)
    }

    return [pscustomobject]@{
        readyPods = $readyPods
        placement = @(
            $placement | ForEach-Object {
                [pscustomobject]@{
                    node = $_.Name
                    pods = $_.Count
                }
            }
        )
    }
}

function Reset-ElsForRun {
    param(
        [Parameter(Mandatory)]
        [int] $Replicas
    )

    Write-Host (
        "[{0}] cold-resetting ELS to {1} replicas" -f
        (Get-Date -Format "HH:mm:ss"),
        $Replicas
    )
    $null = Invoke-KubectlText `
        -Arguments @(
            "--context", $script:KubeContext,
            "-n", "featbit",
            "scale", "deployment/featbit-els",
            "--replicas=0"
        ) `
        -FailureMessage "Failed to scale ELS to zero before the controlled restart."

    $zeroDeadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        $zeroState = Invoke-KubectlJson `
            -Arguments @(
                "--context", $script:KubeContext,
                "-n", "featbit",
                "get", "pods",
                "-l", "app.kubernetes.io/component=els",
                "-o", "json"
            ) `
            -FailureMessage "Failed to verify the ELS scale-to-zero state."
        if (@($zeroState.items).Count -eq 0) {
            break
        }
        if ([DateTime]::UtcNow -ge $zeroDeadline) {
            throw "ELS pods did not terminate within five minutes."
        }
        Start-Sleep -Seconds 2
    } while ($true)

    $null = Invoke-KubectlText `
        -Arguments @(
            "--context", $script:KubeContext,
            "-n", "featbit",
            "scale", "deployment/featbit-els",
            "--replicas=$Replicas"
        ) `
        -FailureMessage "Failed to scale ELS to $Replicas replicas."
    $null = Invoke-KubectlText `
        -Arguments @(
            "--context", $script:KubeContext,
            "-n", "featbit",
            "rollout", "status", "deployment/featbit-els",
            "--timeout=10m"
        ) `
        -FailureMessage "ELS rollout did not complete."

    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    do {
        try {
            $placement = Assert-ElsPlacement `
                -ElsState (Get-ElsState) `
                -ExpectedReplicas $Replicas
            break
        }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw
            }
            Start-Sleep -Seconds 5
        }
    } while ($true)

    $settleSeconds = [int]$script:Matrix.fixed.elsSettleSeconds
    if ($settleSeconds -gt 0) {
        Write-Host "ELS placement ready; settling for ${settleSeconds}s."
        Start-Sleep -Seconds $settleSeconds
    }
    return $placement
}

function New-RunnerPlacementRecord {
    param(
        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [string] $TestRunName,

        [Parameter(Mandatory)]
        [object[]] $Pods,

        [Parameter(Mandatory)]
        [int] $Parallelism,

        [Parameter(Mandatory)]
        [int] $RunnersPerNode,

        [Parameter(Mandatory)]
        [string] $EvidenceSource
    )

    $scheduled = @(
        foreach ($pod in $Pods) {
            $specProperty = $pod.PSObject.Properties["spec"]
            if ($null -eq $specProperty) {
                continue
            }
            $nodeNameProperty = $specProperty.Value.PSObject.Properties["nodeName"]
            if (
                $null -ne $nodeNameProperty -and
                -not [string]::IsNullOrWhiteSpace([string]$nodeNameProperty.Value)
            ) {
                $pod
            }
        }
    )
    Assert-Equal `
        -Name "runner placement pod count" `
        -Actual $scheduled.Count `
        -Expected $Parallelism

    $placement = @(
        $scheduled |
            Group-Object { $_.spec.nodeName } |
            Sort-Object Name
    )
    Assert-Equal `
        -Name "runner placement node count" `
        -Actual $placement.Count `
        -Expected $script:Matrix.fixed.loadgenNodeCount
    foreach ($nodeGroup in $placement) {
        Assert-Equal `
            -Name "runners on node '$($nodeGroup.Name)'" `
            -Actual $nodeGroup.Count `
            -Expected $RunnersPerNode
    }

    foreach ($pod in $scheduled) {
        $runnerContainers = @($pod.spec.containers | Where-Object name -eq "k6")
        Assert-Equal `
            -Name "runner container count on '$($pod.metadata.name)'" `
            -Actual $runnerContainers.Count `
            -Expected 1
        Assert-Equal `
            -Name "runner image on '$($pod.metadata.name)'" `
            -Actual $runnerContainers[0].image `
            -Expected $script:Matrix.fixed.runnerImage
    }

    return [ordered]@{
        runId = $RunId
        testRunName = $TestRunName
        capturedAtUtc = [DateTime]::UtcNow.ToString("o")
        evidenceSource = $EvidenceSource
        expectedParallelism = $Parallelism
        expectedRunnersPerNode = $RunnersPerNode
        pods = @(
            $scheduled |
                Sort-Object { $_.metadata.name } |
                ForEach-Object {
                    $status = @(
                        $_.status.containerStatuses |
                            Where-Object name -eq "k6"
                    )
                    [ordered]@{
                        name = $_.metadata.name
                        node = $_.spec.nodeName
                        phase = $_.status.phase
                        image = @(
                            $_.spec.containers |
                                Where-Object name -eq "k6"
                        )[0].image
                        imageId = if ($status.Count -eq 1) {
                            [string]$status[0].imageID
                        }
                        else {
                            ""
                        }
                    }
                }
        )
        placement = @(
            $placement | ForEach-Object {
                [ordered]@{
                    node = $_.Name
                    runners = $_.Count
                }
            }
        )
    }
}

function Get-OrCreateArchivedRunnerPlacement {
    param(
        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [object] $Group,

        [Parameter(Mandatory)]
        [string] $ArchiveDirectory
    )

    $placementPath = Join-Path `
        $ArchiveDirectory `
        "$RunId-runner-placement.json"
    if (Test-Path -LiteralPath $placementPath -PathType Leaf) {
        $record = Get-Content -Raw -LiteralPath $placementPath |
            ConvertFrom-Json
        Assert-Equal `
            -Name "archived runner parallelism" `
            -Actual $record.expectedParallelism `
            -Expected $Group.parallelism
        Assert-Equal `
            -Name "archived runners per node" `
            -Actual $record.expectedRunnersPerNode `
            -Expected $Group.runnersPerNode
        Assert-Equal `
            -Name "archived runner pod count" `
            -Actual @($record.pods).Count `
            -Expected $Group.parallelism
        Assert-Equal `
            -Name "archived runner node count" `
            -Actual @($record.placement).Count `
            -Expected $script:Matrix.fixed.loadgenNodeCount
        foreach ($nodeRecord in @($record.placement)) {
            Assert-Equal `
                -Name "archived runners on '$($nodeRecord.node)'" `
                -Actual $nodeRecord.runners `
                -Expected $Group.runnersPerNode
        }
        return $placementPath
    }

    $testRunName = "featbit-$RunId"
    $podList = Invoke-KubectlJson `
        -Arguments @(
            "--context", $script:KubeContext,
            "-n", "featbit-loadtest",
            "get", "pods",
            "-l", "k6_cr=$testRunName,runner=true",
            "-o", "json"
        ) `
        -FailureMessage "Failed to read completed runner pods for '$RunId'."
    $record = New-RunnerPlacementRecord `
        -RunId $RunId `
        -TestRunName $testRunName `
        -Pods @($podList.items) `
        -Parallelism ([int]$Group.parallelism) `
        -RunnersPerNode ([int]$Group.runnersPerNode) `
        -EvidenceSource "completed Kubernetes runner pod specs"
    if (-not $script:ValidateOnly) {
        Write-Utf8Json -Path $placementPath -Value $record -Depth 20
    }
    return $placementPath
}

function Wait-RunnerPlacement {
    param(
        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [string] $TestRunName,

        [Parameter(Mandatory)]
        [int] $Parallelism,

        [Parameter(Mandatory)]
        [int] $RunnersPerNode
    )

    $deadline = [DateTime]::UtcNow.AddMinutes(6)
    do {
        $podList = Invoke-KubectlJson `
            -Arguments @(
                "--context", $script:KubeContext,
                "-n", "featbit-loadtest",
                "get", "pods",
                "-l", "k6_cr=$TestRunName,runner=true",
                "-o", "json"
            ) `
            -FailureMessage "Failed to read runner pods for '$TestRunName'."
        $pods = @($podList.items)
        # Kubernetes can return newly created runner Pods before the scheduler
        # has added spec.nodeName. Under StrictMode, reading that absent
        # property throws and aborts the matrix even though placement is still
        # converging. Treat those Pods as unscheduled and keep polling.
        $scheduled = @(
            foreach ($pod in $pods) {
                $specProperty = $pod.PSObject.Properties["spec"]
                if ($null -eq $specProperty) {
                    continue
                }
                $nodeNameProperty = $specProperty.Value.PSObject.Properties["nodeName"]
                if (
                    $null -ne $nodeNameProperty -and
                    -not [string]::IsNullOrWhiteSpace(
                        [string]$nodeNameProperty.Value
                    )
                ) {
                    $pod
                }
            }
        )
        if ($scheduled.Count -eq $Parallelism) {
            try {
                $record = New-RunnerPlacementRecord `
                    -RunId $RunId `
                    -TestRunName $TestRunName `
                    -Pods $scheduled `
                    -Parallelism $Parallelism `
                    -RunnersPerNode $RunnersPerNode `
                    -EvidenceSource "live Kubernetes runner pod specs"
                $placementPath = Join-Path `
                    $script:ResultsDirectory `
                    "$RunId-runner-placement.json"
                Write-Utf8Json `
                    -Path $placementPath `
                    -Value $record `
                    -Depth 20
                return $placementPath
            }
            catch {
                # Pods can be scheduled incrementally. Keep polling until the
                # exact topology converges or the deadline is reached.
            }
        }

        if ([DateTime]::UtcNow -ge $deadline) {
            $description = (
                Invoke-KubectlText `
                    -Arguments @(
                        "--context", $script:KubeContext,
                        "-n", "featbit-loadtest",
                        "get", "pods",
                        "-l", "k6_cr=$TestRunName",
                        "-o", "wide"
                    ) `
                    -FailureMessage "Failed to describe runner placement."
            )
            throw (
                "Runner placement did not converge to $Parallelism pods, " +
                "$RunnersPerNode per each of $($script:Matrix.fixed.loadgenNodeCount) nodes.`n" +
                $description
            )
        }
        Start-Sleep -Seconds 5
    } while ($true)
}

function Wait-TestRun {
    param(
        [Parameter(Mandatory)]
        [string] $TestRunName
    )

    $deadline = [DateTime]::UtcNow.AddMinutes(30)
    $lastProgressAt = [DateTime]::MinValue
    do {
        $testRun = Invoke-KubectlJson `
            -Arguments @(
                "--context", $script:KubeContext,
                "-n", "featbit-loadtest",
                "get", "testrun", $TestRunName,
                "-o", "json"
            ) `
            -FailureMessage "Failed to read TestRun '$TestRunName'."
        $stage = if (
            $null -ne $testRun.PSObject.Properties["status"] -and
            $null -ne $testRun.status.PSObject.Properties["stage"]
        ) {
            [string]$testRun.status.stage
        }
        else {
            ""
        }
        if ($stage -in @("finished", "error")) {
            return $stage
        }
        if (([DateTime]::UtcNow - $lastProgressAt).TotalSeconds -ge 60) {
            Write-Host (
                "[{0}] TestRun {1}: stage={2}" -f
                (Get-Date -Format "HH:mm:ss"),
                $TestRunName,
                $stage
            )
            $lastProgressAt = [DateTime]::UtcNow
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "TestRun '$TestRunName' exceeded the 30-minute deadline."
        }
        Start-Sleep -Seconds 10
    } while ($true)
}

function Get-RunAnalysisRecord {
    param(
        [Parameter(Mandatory)]
        [string] $RunId
    )

    $analysis = & $script:AnalyzeScript `
        -RunId $RunId `
        -ResultsDirectory $script:ResultsDirectory
    $worstRevisionP99 = (
        $analysis.RevisionRollups.latency.p99Max |
            Measure-Object -Maximum
    ).Maximum
    $worstRevisionP95 = (
        $analysis.RevisionRollups.latency.p95Max |
            Measure-Object -Maximum
    ).Maximum

    return [ordered]@{
        sampleCount = [int64]$analysis.FullSampleCount
        revisionCount = @($analysis.RevisionRollups).Count
        weightedAverageMs = [double]$analysis.FullRollup.avg
        runnerP95MinMs = [double]$analysis.FullRollup.p95Min
        runnerP95MaxMs = [double]$analysis.FullRollup.p95Max
        runnerP99MinMs = [double]$analysis.FullRollup.p99Min
        runnerP99MaxMs = [double]$analysis.FullRollup.p99Max
        worstRevisionRunnerP95Ms = [double]$worstRevisionP95
        worstRevisionRunnerP99Ms = [double]$worstRevisionP99
        maximumMs = [double]$analysis.FullRollup.max
        over100MsCount = [int64]$analysis.SpikeCount
        over100MsRate = [double]$analysis.SpikeRate
        thresholdFailureCount = [int]$analysis.ThresholdFailureCount
        warmupPasses = [int64]$analysis.WarmupPasses
        connectionCount = [int64]$analysis.ConnectionCount
        unknownPingWarningCount = [int]$analysis.UnknownPingWarningCount
        revisionRollups = @(
            $analysis.RevisionRollups | ForEach-Object {
                [ordered]@{
                    revision = [int]$_.revision
                    count = [int64]$_.latency.count
                    averageMs = [double]$_.latency.avg
                    runnerP95MaxMs = [double]$_.latency.p95Max
                    runnerP99MaxMs = [double]$_.latency.p99Max
                    maximumMs = [double]$_.latency.max
                    over100MsCount = [int64]$_.spikeCount
                    over100MsRate = [double]$_.spikeRate
                }
            }
        )
    }
}

function Assert-ArchiveForGroup {
    param(
        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [object] $Group
    )

    $archive = Join-Path $script:ResultsDirectory $RunId
    if (-not (Test-Path -LiteralPath $archive -PathType Container)) {
        throw "Result archive '$RunId' does not exist."
    }
    foreach ($requiredFile in @(
        "collection.json",
        "$RunId-metadata.json",
        "$RunId-resource-summary.json",
        "$RunId-resource-samples.jsonl",
        "$RunId-els-deployment.json",
        "$RunId-els-pods.json"
    )) {
        $path = Join-Path $archive $requiredFile
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Seed archive '$RunId' is missing '$requiredFile'."
        }
    }
    $null = Get-OrCreateArchivedRunnerPlacement `
        -RunId $RunId `
        -Group $Group `
        -ArchiveDirectory $archive

    $metadata = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $archive "$RunId-metadata.json") |
        ConvertFrom-Json
    Assert-Equal -Name "seed parallelism" -Actual $metadata.parallelism -Expected $Group.parallelism
    Assert-Equal `
        -Name "seed runnersPerNode" `
        -Actual $metadata.runnersPerNode `
        -Expected $Group.runnersPerNode
    Assert-Equal `
        -Name "seed total connections" `
        -Actual $metadata.parameters.MaxConnections `
        -Expected $script:Matrix.fixed.totalConnections
    Assert-Equal `
        -Name "seed connection rate" `
        -Actual $metadata.parameters.ConnectionsPerSecond `
        -Expected $script:Matrix.fixed.connectionsPerSecond
    Assert-Equal `
        -Name "seed hold duration" `
        -Actual $metadata.parameters.HoldDurationSeconds `
        -Expected $script:Matrix.fixed.holdDurationSeconds
    Assert-Equal `
        -Name "seed runner image" `
        -Actual $metadata.runnerImage `
        -Expected $script:Matrix.fixed.runnerImage
    Assert-Equal `
        -Name "seed runner CPU request" `
        -Actual $metadata.parameters.RunnerCpuRequest `
        -Expected $Group.runnerResources.cpuRequest
    Assert-Equal `
        -Name "seed runner memory request" `
        -Actual $metadata.parameters.RunnerMemoryRequest `
        -Expected $Group.runnerResources.memoryRequest
    Assert-Equal `
        -Name "seed runner memory limit" `
        -Actual $metadata.parameters.RunnerMemoryLimit `
        -Expected $Group.runnerResources.memoryLimit

    $collection = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $archive "collection.json") |
        ConvertFrom-Json
    if (-not [bool]$collection.resourceEvidenceComplete) {
        throw "Seed archive '$RunId' has incomplete resource evidence."
    }
    Assert-Equal -Name "seed stage" -Actual $collection.stage -Expected "finished"

    $deployment = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $archive "$RunId-els-deployment.json") |
        ConvertFrom-Json
    Assert-ElsContract -Deployment $deployment
    Assert-Equal `
        -Name "seed ELS replicas" `
        -Actual $deployment.spec.replicas `
        -Expected $Group.elsReplicas
    $pods = (
        Get-Content `
            -Raw `
            -LiteralPath (Join-Path $archive "$RunId-els-pods.json") |
            ConvertFrom-Json
    ).items
    $placement = @($pods | Group-Object { $_.spec.nodeName })
    Assert-Equal `
        -Name "seed ELS node count" `
        -Actual $placement.Count `
        -Expected $script:Matrix.fixed.featbitNodeCount
    $expectedPerNode = [int]$Group.elsReplicas / [int]$script:Matrix.fixed.featbitNodeCount
    foreach ($nodeGroup in $placement) {
        Assert-Equal `
            -Name "seed ELS pods on '$($nodeGroup.Name)'" `
            -Actual $nodeGroup.Count `
            -Expected $expectedPerNode
    }
    $initialElsPodNames = @(
        $pods |
            ForEach-Object { [string]$_.metadata.name } |
            Sort-Object -Unique
    )
    $observedElsPodNames = @(
        Get-Content -LiteralPath (
            Join-Path $archive "$RunId-resource-samples.jsonl"
        ) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object {
                $sample = $_ | ConvertFrom-Json
                @($sample.containers | Where-Object {
                    $_.namespace -eq "featbit" -and
                    $_.container -eq "featbit-els"
                }) | ForEach-Object { [string]$_.pod }
            } |
            Sort-Object -Unique
    )
    if (
        ($observedElsPodNames -join "`n") -cne
            ($initialElsPodNames -join "`n")
    ) {
        throw (
            "Run '$RunId' did not keep the same ELS pod identities for the " +
            "full resource-sampling window."
        )
    }

    $resourceSummary = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $archive "$RunId-resource-summary.json") |
        ConvertFrom-Json
    if (-not [bool]$resourceSummary.complete) {
        throw "Seed archive '$RunId' has an incomplete resource summary."
    }

    $analysis = Get-RunAnalysisRecord -RunId $RunId
    Assert-Equal `
        -Name "seed revision count" `
        -Actual $analysis.revisionCount `
        -Expected $script:Matrix.fixed.expectedRevisions.Count
    Assert-Equal `
        -Name "seed measured samples" `
        -Actual $analysis.sampleCount `
        -Expected (
            [int64]$script:Matrix.fixed.totalConnections *
            [int64]$script:Matrix.fixed.expectedRevisions.Count
        )
    Assert-Equal `
        -Name "seed warm-up coverage" `
        -Actual $analysis.warmupPasses `
        -Expected $script:Matrix.fixed.totalConnections
    Assert-Equal `
        -Name "seed connection count" `
        -Actual $analysis.connectionCount `
        -Expected $script:Matrix.fixed.totalConnections
    foreach ($revision in @($analysis.revisionRollups)) {
        Assert-Equal `
            -Name "seed revision $($revision.revision) sample coverage" `
            -Actual $revision.count `
            -Expected $script:Matrix.fixed.totalConnections
    }

    return $analysis
}

function Invoke-FreshMatrixRun {
    param(
        [Parameter(Mandatory)]
        [object] $RunState,

        [Parameter(Mandatory)]
        [object] $Group
    )

    $null = Reset-ElsForRun -Replicas ([int]$Group.elsReplicas)

    $note = (
        "Capacity matrix {0} {1} replicate {2}: p{3} x {4}; " +
        "10k total at 100/s; ELS {5} pods / {6} nodes; 10 revisions." -f
        $script:Matrix.matrixId,
        $Group.id,
        $RunState.replicate,
        $Group.parallelism,
        $Group.connectionsPerRunner,
        $Group.elsReplicas,
        $script:Matrix.fixed.featbitNodeCount
    )
    $rendered = & $script:RenderScript `
        -Profile $script:Matrix.fixed.profile `
        -KubeContext $script:KubeContext `
        -RunnerImage $script:Matrix.fixed.runnerImage `
        -Parallelism $Group.parallelism `
        -RunnersPerNode $Group.runnersPerNode `
        -RunnerCpuRequest $Group.runnerResources.cpuRequest `
        -RunnerMemoryRequest $Group.runnerResources.memoryRequest `
        -RunnerMemoryLimit $Group.runnerResources.memoryLimit `
        -Note $note

    $RunState.runId = $rendered.RunId
    $RunState.testRunName = $rendered.TestRunName
    $RunState.startedAtUtc = [DateTime]::UtcNow.ToString("o")
    $RunState.status = "running"
    Save-State

    $elsEvidence = & $script:CaptureElsScript `
        -RunId $rendered.RunId `
        -KubeContext $script:KubeContext
    Assert-Equal `
        -Name "captured ELS replicas" `
        -Actual $elsEvidence.DesiredReplicas `
        -Expected $Group.elsReplicas

    $monitorJob = $null
    $nodeEvidenceStarted = $false
    $streamTimingStarted = $false
    $sentinelStarted = $false
    $stageTimingRequested = (
        $null -ne $script:Matrix.fixed.PSObject.Properties[
            "enableStageLatencyTiming"
        ] -and
        [bool]$script:Matrix.fixed.enableStageLatencyTiming
    )
    $sentinelRequested = (
        $null -ne $script:Matrix.fixed.PSObject.Properties[
            "enableElsSentinelMatrix"
        ] -and
        [bool]$script:Matrix.fixed.enableElsSentinelMatrix
    )
    try {
        $nodeEvidenceInterval = $script:Matrix.fixed.PSObject.Properties[
            "nodeEvidenceSampleIntervalSeconds"
        ]
        if ($null -ne $nodeEvidenceInterval) {
            Assert-Equal `
                -Name "node evidence sample interval" `
                -Actual ([int]$nodeEvidenceInterval.Value) `
                -Expected 1
            $nodeEvidenceOutput = @(
                & $script:StartNodeEvidenceScript `
                    -RunId $rendered.RunId `
                    -KubeContext $script:KubeContext `
                    -ExpectedElsPods ([int]$Group.elsReplicas) `
                    -ExpectedFeatBitNodes (
                        [int]$script:Matrix.fixed.featbitNodeCount
                    ) `
                    -ExpectedLoadgenNodes (
                        [int]$script:Matrix.fixed.loadgenNodeCount
                    )
            )
            $nodeEvidenceStarted = $true
            $nodeEvidenceCandidates = @($nodeEvidenceOutput | Where-Object {
                $null -ne $_ -and
                $null -ne $_.PSObject.Properties["CollectorPods"]
            })
            Assert-Equal `
                -Name "1-second collector structured result count" `
                -Actual $nodeEvidenceCandidates.Count `
                -Expected 1
            $nodeEvidence = $nodeEvidenceCandidates[0]
            Assert-Equal `
                -Name "ready 1-second collectors" `
                -Actual ([int]$nodeEvidence.CollectorPods) `
                -Expected (
                    [int]$script:Matrix.fixed.featbitNodeCount +
                    [int]$script:Matrix.fixed.loadgenNodeCount
                )
        }

        if ($stageTimingRequested) {
            $streamTimingOutput = @(
                & $script:StartStreamTimingScript `
                    -RunId $rendered.RunId `
                    -KubeContext $script:KubeContext `
                    -ExpectedLoadgenNodes (
                        [int]$script:Matrix.fixed.loadgenNodeCount
                    )
            )
            $streamTimingStarted = $true
            $streamTimingCandidates = @($streamTimingOutput | Where-Object {
                $null -ne $_ -and
                $null -ne $_.PSObject.Properties["ObserverPods"]
            })
            Assert-Equal `
                -Name "stream timing structured result count" `
                -Actual $streamTimingCandidates.Count `
                -Expected 1
            Assert-Equal `
                -Name "ready stream timing observers" `
                -Actual ([int]$streamTimingCandidates[0].ObserverPods) `
                -Expected ([int]$script:Matrix.fixed.loadgenNodeCount)
        }

        if ($sentinelRequested) {
            $sentinelOutput = @(
                & $script:StartSentinelScript `
                    -RunId $rendered.RunId `
                    -KubeContext $script:KubeContext `
                    -RunnerImage $script:Matrix.fixed.runnerImage `
                    -ExpectedLoadgenNodes (
                        [int]$script:Matrix.fixed.loadgenNodeCount
                    ) `
                    -ExpectedElsPods ([int]$Group.elsReplicas) `
                    -ConnectionsPerTarget (
                        [int]$script:Matrix.fixed.sentinelConnectionsPerTarget
                    ) `
                    -HoldDurationSeconds (
                        [int]$script:Matrix.fixed.sentinelHoldDurationSeconds
                    )
            )
            $sentinelStarted = $true
            $sentinelCandidates = @($sentinelOutput | Where-Object {
                $null -ne $_ -and
                $null -ne $_.PSObject.Properties["SentinelPods"]
            })
            Assert-Equal `
                -Name "ELS sentinel structured result count" `
                -Actual $sentinelCandidates.Count `
                -Expected 1
            Assert-Equal `
                -Name "ready ELS sentinel Pods" `
                -Actual ([int]$sentinelCandidates[0].SentinelPods) `
                -Expected ([int]$script:Matrix.fixed.loadgenNodeCount)
            Assert-Equal `
                -Name "ELS sentinel diagnostic connections" `
                -Actual (
                    [int]$sentinelCandidates[0].TotalDiagnosticConnections
                ) `
                -Expected (
                    [int]$script:Matrix.fixed.loadgenNodeCount *
                    [int]$Group.elsReplicas *
                    [int]$script:Matrix.fixed.sentinelConnectionsPerTarget
                )
        }

        Write-Host (
            "[{0}] submitting {1} ({2}, replicate {3})" -f
            (Get-Date -Format "HH:mm:ss"),
            $rendered.TestRunName,
            $Group.id,
            $RunState.replicate
        )
        $null = Invoke-KubectlText `
            -Arguments @(
                "--context", $script:KubeContext,
                "apply", "-f", $rendered.ManifestPath
            ) `
            -FailureMessage "Failed to submit '$($rendered.TestRunName)'."

        $monitorJob = Start-Job `
            -ScriptBlock {
                param($ScriptPath, $RunId, $Context, $Interval, $ResultsPath)
                $ErrorActionPreference = "Stop"
                & $ScriptPath `
                    -RunId $RunId `
                    -KubeContext $Context `
                    -SampleIntervalSeconds $Interval `
                    -TimeoutMinutes 30 `
                    -OutputDirectory $ResultsPath
            } `
            -ArgumentList @(
                $script:MonitorScript,
                $rendered.RunId,
                $script:KubeContext,
                [int]$script:Matrix.fixed.resourceSampleIntervalSeconds,
                $script:ResultsDirectory
            )

        $placementPath = Wait-RunnerPlacement `
            -RunId $rendered.RunId `
            -TestRunName $rendered.TestRunName `
            -Parallelism ([int]$Group.parallelism) `
            -RunnersPerNode ([int]$Group.runnersPerNode)
        $RunState.runnerPlacementPath = $placementPath
        Save-State

        $stage = Wait-TestRun -TestRunName $rendered.TestRunName
        $RunState.stage = $stage
        Save-State

        $null = Wait-Job -Job $monitorJob -Timeout 180
        if ($monitorJob.State -notin @("Completed", "Failed")) {
            throw "Resource monitor did not exit within 180s of TestRun completion."
        }
        $monitorOutput = @(Receive-Job -Job $monitorJob -ErrorAction Continue)
        if ($monitorJob.State -eq "Failed") {
            $reason = $monitorJob.ChildJobs[0].JobStateInfo.Reason
            throw "Resource monitor failed: $reason"
        }
        if ($stage -ne "finished") {
            throw "TestRun '$($rendered.TestRunName)' ended at stage '$stage'."
        }
    }
    finally {
        if ($null -ne $monitorJob) {
            Remove-Job -Job $monitorJob -Force -ErrorAction SilentlyContinue
        }
        $sentinelStopError = $null
        if ($sentinelStarted) {
            try {
                $null = & $script:StopSentinelScript `
                    -RunId $rendered.RunId `
                    -KubeContext $script:KubeContext `
                    -OutputDirectory $script:ResultsDirectory
            }
            catch {
                $sentinelStopError = $_
            }
        }
        $streamTimingStopError = $null
        if ($streamTimingStarted) {
            try {
                $null = & $script:StopStreamTimingScript `
                    -RunId $rendered.RunId `
                    -KubeContext $script:KubeContext `
                    -OutputDirectory $script:ResultsDirectory
            }
            catch {
                $streamTimingStopError = $_
            }
        }
        if ($nodeEvidenceStarted) {
            $null = & $script:StopNodeEvidenceScript `
                -RunId $rendered.RunId `
                -KubeContext $script:KubeContext
        }
        if ($null -ne $streamTimingStopError) {
            throw $streamTimingStopError
        }
        if ($null -ne $sentinelStopError) {
            throw $sentinelStopError
        }
    }

    $collectionOutput = @(
        & $script:CollectScript `
            -RunId $rendered.RunId `
            -KubeContext $script:KubeContext `
            -AllowFailedRunners
    )
    $collectionCandidates = @($collectionOutput | Where-Object {
        $null -ne $_ -and
        $null -ne $_.PSObject.Properties["CollectionPath"]
    })
    Assert-Equal `
        -Name "collection structured result count" `
        -Actual $collectionCandidates.Count `
        -Expected 1
    $collection = $collectionCandidates[0]
    $collectionManifest = Get-Content -Raw -LiteralPath $collection.CollectionPath |
        ConvertFrom-Json
    if (-not [bool]$collectionManifest.resourceEvidenceComplete) {
        throw "Resource evidence is incomplete for '$($rendered.RunId)'."
    }

    $analysis = Assert-ArchiveForGroup `
        -RunId $rendered.RunId `
        -Group $Group
    $stageLatencyAnalysis = $null
    if ($stageTimingRequested) {
        $stageLatencyAnalysis = & $script:AnalyzeStageScript `
            -RunId $rendered.RunId `
            -ResultsDirectory $script:ResultsDirectory
        $RunState.stageLatencyAnalysis = $stageLatencyAnalysis
    }
    $sentinelAnalysis = $null
    if ($sentinelRequested) {
        $sentinelAnalysis = & $script:AnalyzeSentinelScript `
            -RunId $rendered.RunId `
            -ResultsDirectory $script:ResultsDirectory
        if (-not [bool]$sentinelAnalysis.validation.complete) {
            throw "Sentinel matrix evidence is incomplete for '$($rendered.RunId)'."
        }
        $RunState.sentinelAnalysis = $sentinelAnalysis
    }
    $RunState.analysis = $analysis
    $RunState.archiveDirectory = $collection.ArchiveDirectory
    $RunState.runnerPlacementPath = Join-Path `
        $collection.ArchiveDirectory `
        "$($rendered.RunId)-runner-placement.json"
    $RunState.collectionComplete = [bool]$collectionManifest.complete
    $RunState.resourceEvidenceComplete = [bool]$collectionManifest.resourceEvidenceComplete
    $RunState.status = "completed"
    $RunState.completedAtUtc = [DateTime]::UtcNow.ToString("o")
    Save-State

    Write-Host (
        (
            "[{0}] completed {1}: worst revision runner p99={2:N2}ms, " +
            "threshold failures={3}"
        ) -f
        (Get-Date -Format "HH:mm:ss"),
        $rendered.RunId,
        $analysis.worstRevisionRunnerP99Ms,
        $analysis.thresholdFailureCount
    )
}

$repositoryRoot = Get-RepositoryRoot
$resolvedMatrixPath = if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
    Join-Path $repositoryRoot "k8s-infra\matrices\aks-p99-capacity.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MatrixPath)
}
if (-not (Test-Path -LiteralPath $resolvedMatrixPath -PathType Leaf)) {
    throw "Matrix definition does not exist: $resolvedMatrixPath"
}
$script:Matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath |
    ConvertFrom-Json
Assert-Equal -Name "matrix schema version" -Actual $script:Matrix.schemaVersion -Expected 1
Assert-MatrixDefinition
$script:ValidateOnly = [bool]$ValidateOnly

$script:ResultsDirectory = Join-Path $repositoryRoot "results"
$null = New-Item -ItemType Directory -Force -Path $script:ResultsDirectory
$script:ResolvedStatePath = if ([string]::IsNullOrWhiteSpace($StatePath)) {
    Join-Path $script:ResultsDirectory "$($script:Matrix.matrixId)-state.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StatePath)
}
$script:KubeContext = [string]$script:Matrix.fixed.kubernetesContext
$script:RenderScript = Join-Path $PSScriptRoot "render-aks-testrun.ps1"
$script:MonitorScript = Join-Path $PSScriptRoot "monitor-aks-testrun.ps1"
$script:CaptureElsScript = Join-Path $PSScriptRoot "capture-aks-els-evidence.ps1"
$script:StartNodeEvidenceScript = Join-Path `
    $PSScriptRoot `
    "start-aks-1s-evidence.ps1"
$script:StopNodeEvidenceScript = Join-Path `
    $PSScriptRoot `
    "stop-aks-1s-evidence.ps1"
$script:StartStreamTimingScript = Join-Path `
    $PSScriptRoot `
    "start-aks-streaming-timing.ps1"
$script:StopStreamTimingScript = Join-Path `
    $PSScriptRoot `
    "stop-aks-streaming-timing.ps1"
$script:StartSentinelScript = Join-Path `
    $PSScriptRoot `
    "start-aks-els-sentinels.ps1"
$script:StopSentinelScript = Join-Path `
    $PSScriptRoot `
    "stop-aks-els-sentinels.ps1"
$script:AnalyzeStageScript = Join-Path `
    $PSScriptRoot `
    "analyze-aks-stage-latency.ps1"
$script:AnalyzeSentinelScript = Join-Path `
    $PSScriptRoot `
    "analyze-aks-sentinel-matrix.ps1"
$script:CollectScript = Join-Path $PSScriptRoot "collect-results-aks.ps1"
$script:AnalyzeScript = Join-Path $PSScriptRoot "analyze-aks-latency.ps1"

Assert-KubernetesContext -KubeContext $script:KubeContext

$matrixHash = (
    Get-FileHash -LiteralPath $resolvedMatrixPath -Algorithm SHA256
).Hash.ToLowerInvariant()
if ($ValidateOnly) {
    $script:State = New-MatrixState `
        -MatrixPath $resolvedMatrixPath `
        -MatrixHash $matrixHash
}
elseif (Test-Path -LiteralPath $script:ResolvedStatePath -PathType Leaf) {
    if (-not $Resume) {
        throw (
            "Matrix state already exists: $script:ResolvedStatePath. " +
            "Use -Resume after reviewing it."
        )
    }
    $script:State = Get-Content -Raw -LiteralPath $script:ResolvedStatePath |
        ConvertFrom-Json
    Assert-Equal `
        -Name "state matrix hash" `
        -Actual $script:State.matrixSha256 `
        -Expected $matrixHash
    if ($null -eq $script:State.PSObject.Properties["completedAtUtc"]) {
        # Preserve compatibility with state files created before the
        # top-level completion timestamp was added.
        $script:State | Add-Member `
            -MemberType NoteProperty `
            -Name completedAtUtc `
            -Value $null
    }
}
else {
    if ($Resume) {
        throw "Cannot resume because matrix state does not exist: $script:ResolvedStatePath"
    }
    $script:State = New-MatrixState `
        -MatrixPath $resolvedMatrixPath `
        -MatrixHash $matrixHash
    Save-State
}

if ($RetryFailed) {
    foreach ($failedRun in @($script:State.runs | Where-Object status -eq "failed")) {
        if ($failedRun.source -eq "fresh") {
            $failedRun.status = "pending"
            $failedRun.runId = ""
            $failedRun.testRunName = ""
            $failedRun.stage = ""
            $failedRun.startedAtUtc = $null
            $failedRun.completedAtUtc = $null
            $failedRun.archiveDirectory = ""
            $failedRun.collectionComplete = $false
            $failedRun.resourceEvidenceComplete = $false
            $failedRun.runnerPlacementPath = ""
            $failedRun.analysis = $null
            if ($null -ne $failedRun.PSObject.Properties["stageLatencyAnalysis"]) {
                $failedRun.stageLatencyAnalysis = $null
            }
            if ($null -ne $failedRun.PSObject.Properties["sentinelAnalysis"]) {
                $failedRun.sentinelAnalysis = $null
            }
            $failedRun.error = ""
        }
    }
    Save-State
}

# Preflight the fixed cluster and test configuration without exposing Secret data.
$nodes = Invoke-KubectlJson `
    -Arguments @("--context", $script:KubeContext, "get", "nodes", "-o", "json") `
    -FailureMessage "Failed to read AKS nodes."
$loadgenNodes = @($nodes.items | Where-Object {
    $_.metadata.labels.workload -eq "loadgen" -and
    ($_.status.conditions | Where-Object type -eq "Ready").status -eq "True"
})
$featbitNodes = @($nodes.items | Where-Object {
    $_.metadata.labels.workload -eq "featbit" -and
    ($_.status.conditions | Where-Object type -eq "Ready").status -eq "True"
})
Assert-Equal `
    -Name "ready loadgen node count" `
    -Actual $loadgenNodes.Count `
    -Expected $script:Matrix.fixed.loadgenNodeCount
Assert-Equal `
    -Name "ready FeatBit node count" `
    -Actual $featbitNodes.Count `
    -Expected $script:Matrix.fixed.featbitNodeCount
$expectedLoadgenVmSize = $script:Matrix.fixed.PSObject.Properties[
    "loadgenNodeVmSize"
]
if ($null -ne $expectedLoadgenVmSize) {
    foreach ($node in $loadgenNodes) {
        Assert-Equal `
            -Name "loadgen node '$($node.metadata.name)' VM size" `
            -Actual $node.metadata.labels."node.kubernetes.io/instance-type" `
            -Expected $expectedLoadgenVmSize.Value
    }
}
$expectedFeatbitVmSize = $script:Matrix.fixed.PSObject.Properties[
    "featbitNodeVmSize"
]
if ($null -ne $expectedFeatbitVmSize) {
    foreach ($node in $featbitNodes) {
        Assert-Equal `
            -Name "FeatBit node '$($node.metadata.name)' VM size" `
            -Actual $node.metadata.labels."node.kubernetes.io/instance-type" `
            -Expected $expectedFeatbitVmSize.Value
    }
}

$hpa = Invoke-KubectlJson `
    -Arguments @(
        "--context", $script:KubeContext,
        "-n", "featbit",
        "get", "hpa",
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect FeatBit HPAs."
if (@($hpa.items).Count -ne 0) {
    throw "The capacity matrix requires no FeatBit HPA; found $(@($hpa.items).Count)."
}

$testRuns = Invoke-KubectlJson `
    -Arguments @(
        "--context", $script:KubeContext,
        "-n", "featbit-loadtest",
        "get", "testruns",
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect existing TestRuns."
$activeTestRuns = @($testRuns.items | Where-Object {
    $stage = if (
        $null -ne $_.PSObject.Properties["status"] -and
        $null -ne $_.status.PSObject.Properties["stage"]
    ) {
        [string]$_.status.stage
    }
    else {
        ""
    }
    $stage -notin @("finished", "error")
})
if ($activeTestRuns.Count -ne 0) {
    throw (
        "The capacity matrix requires no other active TestRun; found: " +
        (
            @($activeTestRuns | ForEach-Object {
                $stage = if (
                    $null -ne $_.PSObject.Properties["status"] -and
                    $null -ne $_.status.PSObject.Properties["stage"]
                ) {
                    [string]$_.status.stage
                }
                else {
                    "<unset>"
                }
                "$($_.metadata.name)=$stage"
            }) -join ", "
        )
    )
}

$probeInventoryCommand = @'
PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" -At -F "|" -c "SELECT count(*), count(DISTINCT env_id), string_agg(key, ',' ORDER BY key) FROM feature_flags WHERE key LIKE 'loadtest-sync-probe-%' AND NOT is_archived;"
'@.Trim()
$probeInventoryOutput = Invoke-KubectlText `
    -Arguments @(
        "--context", $script:KubeContext,
        "-n", "featbit",
        "exec", "statefulset/featbit-featbit-postgresql",
        "--", "sh", "-c", $probeInventoryCommand
    ) `
    -FailureMessage "Failed to inspect the provisioned probe flags."
$probeInventoryLine = @(
    $probeInventoryOutput -split "\r?\n" |
        Where-Object { $_ -match "^\d+\|\d+\|" }
)
Assert-Equal `
    -Name "probe flag inventory row count" `
    -Actual $probeInventoryLine.Count `
    -Expected 1
$probeInventoryFields = $probeInventoryLine[0] -split "\|", 3
$expectedProbeKeys = @(
    1..[int]$script:Matrix.fixed.provisionedFlagCount |
        ForEach-Object { "loadtest-sync-probe-{0:D2}" -f $_ }
)
Assert-Equal `
    -Name "active probe flag count" `
    -Actual $probeInventoryFields[0] `
    -Expected $script:Matrix.fixed.provisionedFlagCount
Assert-Equal `
    -Name "probe flag environment count" `
    -Actual $probeInventoryFields[1] `
    -Expected 1
if ($probeInventoryFields[2] -cne ($expectedProbeKeys -join ",")) {
    throw "The active probe flag keys do not match the expected canonical 20-key set."
}

$target = Invoke-KubectlJson `
    -Arguments @(
        "--context", $script:KubeContext,
        "-n", "featbit-loadtest",
        "get", "configmap", "featbit-k6-target",
        "-o", "json"
    ) `
    -FailureMessage "Failed to read the target ConfigMap."
$actualRevisions = @(
    [string]$target.data.EXPECTED_REVISIONS -split "," |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
)
if (
    ($actualRevisions -join ",") -cne
        (@($script:Matrix.fixed.expectedRevisions) -join ",")
) {
    throw "Target ConfigMap EXPECTED_REVISIONS does not match the matrix definition."
}
Assert-Equal `
    -Name "internal streaming URL" `
    -Actual $target.data.FEATBIT_STREAMING_URL `
    -Expected $script:Matrix.fixed.streamingUrl

$controller = Invoke-KubectlJson `
    -Arguments @(
        "--context", $script:KubeContext,
        "-n", "featbit-loadtest",
        "get", "configmap", "featbit-k6-controller",
        "-o", "json"
    ) `
    -FailureMessage "Failed to read the controller ConfigMap."
Assert-Equal `
    -Name "automatic revision control" `
    -Actual ([string]$controller.data.AUTO_CONTROL_REVISIONS).ToLowerInvariant() `
    -Expected "true"
Assert-Equal `
    -Name "internal configuration API URL" `
    -Actual $controller.data.FEATBIT_API_URL `
    -Expected $script:Matrix.fixed.configurationApiUrl
Assert-Equal `
    -Name "controller warm-up settle interval" `
    -Actual $controller.data.CONTROLLER_WARMUP_SETTLE_SECONDS `
    -Expected $script:Matrix.fixed.controllerWarmupSettleSeconds
Assert-Equal `
    -Name "controller start delay" `
    -Actual $controller.data.CONTROLLER_START_DELAY_SECONDS `
    -Expected $script:Matrix.fixed.controllerStartDelaySeconds
Assert-Equal `
    -Name "revision interval" `
    -Actual $controller.data.CONTROLLER_REVISION_INTERVAL_SECONDS `
    -Expected $script:Matrix.fixed.revisionIntervalSeconds
Assert-Equal `
    -Name "controller final settle interval" `
    -Actual $controller.data.CONTROLLER_FINAL_SETTLE_SECONDS `
    -Expected $script:Matrix.fixed.controllerFinalSettleSeconds
$currentElsState = Get-ElsState
Assert-ElsContract -Deployment $currentElsState.deployment

$script:State.preflight = [ordered]@{
    capturedAtUtc = [DateTime]::UtcNow.ToString("o")
    loadgenNodes = @(
        $loadgenNodes | ForEach-Object {
            [ordered]@{
                name = $_.metadata.name
                instanceType = $_.metadata.labels."node.kubernetes.io/instance-type"
                allocatableCpu = $_.status.allocatable.cpu
                allocatableMemory = $_.status.allocatable.memory
            }
        }
    )
    featbitNodes = @(
        $featbitNodes | ForEach-Object {
            [ordered]@{
                name = $_.metadata.name
                instanceType = $_.metadata.labels."node.kubernetes.io/instance-type"
                allocatableCpu = $_.status.allocatable.cpu
                allocatableMemory = $_.status.allocatable.memory
            }
        }
    )
    probeFlags = [ordered]@{
        count = [int]$probeInventoryFields[0]
        environmentCount = [int]$probeInventoryFields[1]
        keys = $expectedProbeKeys
    }
    expectedRevisions = $actualRevisions
    elsImage = $currentElsState.deployment.spec.template.spec.containers[0].image
    hpaCount = @($hpa.items).Count
    activeTestRunCount = $activeTestRuns.Count
}
Save-State

if ($ValidateOnly) {
    $validatedSeeds = [Collections.Generic.List[object]]::new()
    foreach ($runState in @(
        $script:State.runs |
            Where-Object source -eq "existing" |
            Sort-Object sequence
    )) {
        $group = Get-MatrixGroup -GroupId $runState.group
        Write-Host "Read-only validation of seed run '$($runState.runId)'."
        $analysis = Assert-ArchiveForGroup `
            -RunId $runState.runId `
            -Group $group
        $validatedSeeds.Add([ordered]@{
            runId = $runState.runId
            group = $group.id
            replicate = $runState.replicate
            sampleCount = $analysis.sampleCount
            revisionCount = $analysis.revisionCount
            worstRevisionRunnerP99Ms = $analysis.worstRevisionRunnerP99Ms
        })
    }

    Write-Host ""
    Write-Host "Capacity matrix read-only validation passed." -ForegroundColor Green
    return [pscustomobject]@{
        MatrixId = $script:Matrix.matrixId
        MatrixSha256 = $matrixHash
        Groups = @($script:Matrix.groups).Count
        PlannedRuns = @($script:Matrix.executionOrder).Count
        SeedRunsValidated = @($validatedSeeds)
        ReadyLoadgenNodes = $loadgenNodes.Count
        ReadyFeatBitNodes = $featbitNodes.Count
        ExpectedRevisions = $actualRevisions
        CurrentElsReplicas = [int]$currentElsState.deployment.spec.replicas
    }
}

foreach ($failedRun in @(
    $script:State.runs |
        Where-Object {
            $_.status -eq "failed" -and
            -not [string]::IsNullOrWhiteSpace([string]$_.runId)
        } |
        Sort-Object sequence
)) {
    $failedArchive = Join-Path $script:ResultsDirectory $failedRun.runId
    $failedCollectionPath = Join-Path $failedArchive "collection.json"
    if (-not (Test-Path -LiteralPath $failedCollectionPath -PathType Leaf)) {
        continue
    }

    try {
        $failedGroup = Get-MatrixGroup -GroupId $failedRun.group
        Write-Host (
            "Attempting evidence-only recovery of failed run " +
            "'$($failedRun.runId)'."
        )
        $failedAnalysis = Assert-ArchiveForGroup `
            -RunId $failedRun.runId `
            -Group $failedGroup
        $failedCollection = Get-Content `
            -Raw `
            -LiteralPath $failedCollectionPath |
            ConvertFrom-Json
        if (
            [string]$failedCollection.stage -ne "finished" -or
            -not [bool]$failedCollection.resourceEvidenceComplete
        ) {
            throw "The archived stage/resource evidence is incomplete."
        }

        $failedRun.analysis = $failedAnalysis
        $failedRun.archiveDirectory = $failedArchive
        $failedRun.runnerPlacementPath = Join-Path `
            $failedArchive `
            "$($failedRun.runId)-runner-placement.json"
        $failedRun.collectionComplete = [bool]$failedCollection.complete
        $failedRun.resourceEvidenceComplete = [bool](
            $failedCollection.resourceEvidenceComplete
        )
        $failedRun.stage = [string]$failedCollection.stage
        $failedRun.status = "completed"
        $failedRun.error = ""
        $failedRun.completedAtUtc = [DateTime]::UtcNow.ToString("o")
        Write-Host "Recovered '$($failedRun.runId)' from verified archived evidence."
    }
    catch {
        Write-Warning (
            "Failed run '$($failedRun.runId)' could not be recovered from " +
            "its archive: $($_.Exception.Message)"
        )
    }
}

foreach ($completedRun in @(
    $script:State.runs |
        Where-Object status -eq "completed" |
        Sort-Object sequence
)) {
    $completedGroup = Get-MatrixGroup -GroupId $completedRun.group
    Write-Host "Revalidating completed run '$($completedRun.runId)'."
    $completedRun.analysis = Assert-ArchiveForGroup `
        -RunId $completedRun.runId `
        -Group $completedGroup
    $completedRun.archiveDirectory = Join-Path `
        $script:ResultsDirectory `
        $completedRun.runId
    $completedRun.runnerPlacementPath = Join-Path `
        $completedRun.archiveDirectory `
        "$($completedRun.runId)-runner-placement.json"
}

$script:State.status = "running"
Save-State
$freshRunsStarted = 0
$pausedByLimit = $false
try {
    foreach ($runState in @($script:State.runs | Sort-Object sequence)) {
        if ($runState.status -eq "completed") {
            continue
        }
        $group = Get-MatrixGroup -GroupId $runState.group

        try {
            if ($runState.source -eq "existing") {
                Write-Host "Validating seed run '$($runState.runId)' for $($group.id)."
                $analysis = Assert-ArchiveForGroup `
                    -RunId $runState.runId `
                    -Group $group
                $runState.analysis = $analysis
                $runState.archiveDirectory = Join-Path $script:ResultsDirectory $runState.runId
                $runState.runnerPlacementPath = Join-Path `
                    $runState.archiveDirectory `
                    "$($runState.runId)-runner-placement.json"
                $collection = Get-Content `
                    -Raw `
                    -LiteralPath (Join-Path $runState.archiveDirectory "collection.json") |
                    ConvertFrom-Json
                $runState.collectionComplete = [bool]$collection.complete
                $runState.resourceEvidenceComplete = [bool]$collection.resourceEvidenceComplete
                $runState.stage = [string]$collection.stage
                $runState.status = "completed"
                $runState.completedAtUtc = [DateTime]::UtcNow.ToString("o")
                Save-State
                continue
            }

            if ($freshRunsStarted -ge $MaxFreshRuns) {
                $pausedByLimit = $true
                break
            }
            if ($runState.status -eq "failed") {
                throw (
                    "Run sequence $($runState.sequence) is marked failed " +
                    "('$($runState.runId)'). Inspect its evidence, then use " +
                    "-Resume -RetryFailed only if a new run is required."
                )
            }
            if ($runState.status -eq "running") {
                throw (
                    "Run sequence $($runState.sequence) is marked running " +
                    "('$($runState.runId)'). Inspect it before resuming."
                )
            }
            Invoke-FreshMatrixRun -RunState $runState -Group $group
            $freshRunsStarted += 1

            $cooldownSeconds = [int]$script:Matrix.fixed.betweenRunSettleSeconds
            if ($cooldownSeconds -gt 0) {
                Write-Host "Cooling down for ${cooldownSeconds}s before the next run."
                Start-Sleep -Seconds $cooldownSeconds
            }
        }
        catch {
            $runState.status = "failed"
            $runState.error = $_.Exception.Message
            $runState.completedAtUtc = [DateTime]::UtcNow.ToString("o")
            $script:State.status = "failed"
            Save-State
            throw
        }
    }

    if ($pausedByLimit) {
        $script:State.status = "paused"
        Save-State
        Write-Host ""
        Write-Host (
            "Capacity matrix paused after $freshRunsStarted fresh run(s); " +
            "resume with -Resume."
        ) -ForegroundColor Yellow
        return [pscustomobject]@{
            MatrixId = $script:Matrix.matrixId
            StatePath = $script:ResolvedStatePath
            Status = $script:State.status
            CompletedRuns = @(
                $script:State.runs | Where-Object status -eq "completed"
            ).Count
            TotalRuns = @($script:State.runs).Count
        }
    }

    # Restore the documented default after all evidence is safely archived.
    $null = Reset-ElsForRun -Replicas 6

    $script:State.status = "completed"
    $script:State.completedAtUtc = [DateTime]::UtcNow.ToString("o")
    Save-State

    Write-Host ""
    Write-Host "Capacity matrix execution completed." -ForegroundColor Green
    Write-Host "State: $script:ResolvedStatePath"
}
catch {
    Write-Error (
        "Capacity matrix stopped with the current ELS/TestRun state preserved: " +
        $_.Exception.Message
    )
    throw
}

[pscustomobject]@{
    MatrixId = $script:Matrix.matrixId
    StatePath = $script:ResolvedStatePath
    Status = $script:State.status
    CompletedRuns = @($script:State.runs | Where-Object status -eq "completed").Count
    TotalRuns = @($script:State.runs).Count
}
