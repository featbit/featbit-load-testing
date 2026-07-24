[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [string] $RunId,

    [Parameter(Mandatory)]
    [string] $KubeContext,

    [ValidateRange(5, 300)]
    [int] $SampleIntervalSeconds = 15,

    [ValidateRange(5, 120)]
    [int] $TimeoutMinutes = 30,

    [ValidateRange(3, 720)]
    [int] $MaxConsecutiveSampleErrors = 120,

    [string] $OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Invoke-KubectlJson {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter(Mandatory)]
        [string] $FailureMessage
    )

    $raw = (& kubectl @Arguments | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw $FailureMessage
    }

    return $raw | ConvertFrom-Json
}

function Convert-CpuToMillicores {
    param([Parameter(Mandatory)][string] $Quantity)

    if ($Quantity -notmatch "^(?<number>[0-9]+(?:\.[0-9]+)?)(?<unit>n|u|m)?$") {
        throw "Unsupported CPU quantity '$Quantity'."
    }

    $number = [double]::Parse(
        $Matches.number,
        [Globalization.CultureInfo]::InvariantCulture
    )
    $unit = if ($Matches.ContainsKey("unit")) {
        [string]$Matches["unit"]
    }
    else {
        ""
    }
    switch ($unit) {
        "n" { return $number / 1000000 }
        "u" { return $number / 1000 }
        "m" { return $number }
        default { return $number * 1000 }
    }
}

function Convert-MemoryToBytes {
    param([Parameter(Mandatory)][string] $Quantity)

    if ($Quantity -notmatch "^(?<number>[0-9]+(?:\.[0-9]+)?)(?<unit>Ki|Mi|Gi|Ti|K|M|G|T)?$") {
        throw "Unsupported memory quantity '$Quantity'."
    }

    $number = [double]::Parse(
        $Matches.number,
        [Globalization.CultureInfo]::InvariantCulture
    )
    $unit = if ($Matches.ContainsKey("unit")) {
        [string]$Matches["unit"]
    }
    else {
        ""
    }
    $multiplier = switch ($unit) {
        "Ki" { [Math]::Pow(1024, 1) }
        "Mi" { [Math]::Pow(1024, 2) }
        "Gi" { [Math]::Pow(1024, 3) }
        "Ti" { [Math]::Pow(1024, 4) }
        "K" { [Math]::Pow(1000, 1) }
        "M" { [Math]::Pow(1000, 2) }
        "G" { [Math]::Pow(1000, 3) }
        "T" { [Math]::Pow(1000, 4) }
        default { 1 }
    }

    return $number * $multiplier
}

function Update-Peak {
    param(
        [Parameter(Mandatory)][hashtable] $Peaks,
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)][hashtable] $Identity,
        [Parameter(Mandatory)][double] $CpuMillicores,
        [Parameter(Mandatory)][double] $MemoryBytes,
        [Parameter(Mandatory)][string] $ObservedAtUtc
    )

    if (-not $Peaks.ContainsKey($Key)) {
        $Peaks[$Key] = [ordered]@{
            identity = $Identity
            peakCpuMillicores = 0.0
            peakCpuObservedAtUtc = ""
            peakMemoryBytes = 0.0
            peakMemoryObservedAtUtc = ""
        }
    }

    $entry = $Peaks[$Key]
    if ($CpuMillicores -gt $entry.peakCpuMillicores) {
        $entry.peakCpuMillicores = $CpuMillicores
        $entry.peakCpuObservedAtUtc = $ObservedAtUtc
    }
    if ($MemoryBytes -gt $entry.peakMemoryBytes) {
        $entry.peakMemoryBytes = $MemoryBytes
        $entry.peakMemoryObservedAtUtc = $ObservedAtUtc
    }
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext

$testRunName = "featbit-$RunId"
Assert-KubernetesObjectExists `
    -Kind "testrun" `
    -Name $testRunName `
    -KubeContext $targetContext

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

$samplesPath = Join-Path $resultsDirectory "$RunId-resource-samples.jsonl"
$summaryPath = Join-Path $resultsDirectory "$RunId-resource-summary.json"
foreach ($path in @($samplesPath, $summaryPath)) {
    if (Test-Path -LiteralPath $path) {
        throw "Refusing to overwrite existing resource evidence: $path"
    }
}

$nodes = Invoke-KubectlJson `
    -Arguments @("--context", $targetContext, "get", "nodes", "-o", "json") `
    -FailureMessage "Failed to read AKS node metadata."
$nodePools = @{}
foreach ($node in $nodes.items) {
    $poolProperty = $node.metadata.labels.PSObject.Properties["agentpool"]
    $nodePools[[string]$node.metadata.name] = if ($null -eq $poolProperty) {
        "unknown"
    }
    else {
        [string]$poolProperty.Value
    }
}

$nodePeaks = @{}
$containerPeaks = @{}
$sampleCount = 0
$sampleErrors = @()
$consecutiveErrors = 0
$startedAtUtc = [DateTime]::UtcNow
$deadline = $startedAtUtc.AddMinutes($TimeoutMinutes)
$finalStage = ""
$utf8NoBom = [Text.UTF8Encoding]::new($false)

do {
    $sampleCycleStartedAt = [DateTime]::UtcNow
    $observedAtUtc = [DateTime]::UtcNow.ToString("o")
    try {
        $testRun = Invoke-KubectlJson `
            -Arguments @(
                "--context", $targetContext,
                "-n", $script:LoadTestNamespace,
                "get", "testrun", $testRunName,
                "-o", "json"
            ) `
            -FailureMessage "Failed to read TestRun '$testRunName'."
        $stageProperty = $testRun.status.PSObject.Properties["stage"]
        $finalStage = if ($null -eq $stageProperty) {
            "pending"
        }
        else {
            [string]$stageProperty.Value
        }

        $nodeMetrics = Invoke-KubectlJson `
            -Arguments @(
                "--context", $targetContext,
                "get", "--raw", "/apis/metrics.k8s.io/v1beta1/nodes"
            ) `
            -FailureMessage "Failed to read node metrics."
        $podMetrics = Invoke-KubectlJson `
            -Arguments @(
                "--context", $targetContext,
                "get", "--raw", "/apis/metrics.k8s.io/v1beta1/pods"
            ) `
            -FailureMessage "Failed to read Pod metrics."

        $nodeRows = @()
        foreach ($nodeMetric in $nodeMetrics.items) {
            $nodeName = [string]$nodeMetric.metadata.name
            $pool = if ($nodePools.ContainsKey($nodeName)) {
                [string]$nodePools[$nodeName]
            }
            else {
                "unknown"
            }
            if ($pool -notin @("featbit", "loadgen", "system")) {
                continue
            }

            $cpuMillicores = Convert-CpuToMillicores `
                -Quantity ([string]$nodeMetric.usage.cpu)
            $memoryBytes = Convert-MemoryToBytes `
                -Quantity ([string]$nodeMetric.usage.memory)
            $nodeRows += [ordered]@{
                node = $nodeName
                nodePool = $pool
                cpuMillicores = $cpuMillicores
                memoryBytes = $memoryBytes
            }
            Update-Peak `
                -Peaks $nodePeaks `
                -Key "$pool/$nodeName" `
                -Identity ([ordered]@{
                    node = $nodeName
                    nodePool = $pool
                }) `
                -CpuMillicores $cpuMillicores `
                -MemoryBytes $memoryBytes `
                -ObservedAtUtc $observedAtUtc
        }

        $containerRows = @()
        foreach ($podMetric in $podMetrics.items) {
            $namespace = [string]$podMetric.metadata.namespace
            if ($namespace -notin @("featbit", $script:LoadTestNamespace)) {
                continue
            }

            $podName = [string]$podMetric.metadata.name
            foreach ($containerMetric in $podMetric.containers) {
                $containerName = [string]$containerMetric.name
                $cpuMillicores = Convert-CpuToMillicores `
                    -Quantity ([string]$containerMetric.usage.cpu)
                $memoryBytes = Convert-MemoryToBytes `
                    -Quantity ([string]$containerMetric.usage.memory)
                $containerRows += [ordered]@{
                    namespace = $namespace
                    pod = $podName
                    container = $containerName
                    cpuMillicores = $cpuMillicores
                    memoryBytes = $memoryBytes
                }
                Update-Peak `
                    -Peaks $containerPeaks `
                    -Key "$namespace/$podName/$containerName" `
                    -Identity ([ordered]@{
                        namespace = $namespace
                        pod = $podName
                        container = $containerName
                    }) `
                    -CpuMillicores $cpuMillicores `
                    -MemoryBytes $memoryBytes `
                    -ObservedAtUtc $observedAtUtc
            }
        }

        $sample = [ordered]@{
            observedAtUtc = $observedAtUtc
            stage = $finalStage
            nodes = $nodeRows
            containers = $containerRows
        }
        [IO.File]::AppendAllText(
            $samplesPath,
            (($sample | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine),
            $utf8NoBom
        )
        $sampleCount += 1
        $consecutiveErrors = 0

        Write-Host (
            "{0:HH:mm:ss} stage={1} samples={2} nodes={3} containers={4}" -f
            [DateTime]::Now,
            $finalStage,
            $sampleCount,
            $nodeRows.Count,
            $containerRows.Count
        )
    }
    catch {
        $consecutiveErrors += 1
        $sampleErrors += [ordered]@{
            observedAtUtc = $observedAtUtc
            message = $_.Exception.Message
        }
        Write-Warning "Resource sample failed: $($_.Exception.Message)"
        if ($consecutiveErrors -ge $MaxConsecutiveSampleErrors) {
            throw (
                "$consecutiveErrors consecutive resource samples failed; " +
                "the configured maximum is $MaxConsecutiveSampleErrors."
            )
        }
    }

    if ($finalStage -in @("finished", "error")) {
        break
    }
    if ([DateTime]::UtcNow -ge $deadline) {
        throw "Timed out waiting for TestRun '$testRunName' after $TimeoutMinutes minutes."
    }

    $sampleElapsedMilliseconds = (
        [DateTime]::UtcNow - $sampleCycleStartedAt
    ).TotalMilliseconds
    $remainingMilliseconds = [Math]::Max(
        0,
        ($SampleIntervalSeconds * 1000) - $sampleElapsedMilliseconds
    )
    if ($remainingMilliseconds -gt 0) {
        Start-Sleep -Milliseconds ([int]$remainingMilliseconds)
    }
} while ($true)

$summary = [ordered]@{
    runId = $RunId
    testRunName = $testRunName
    kubernetesContext = $targetContext
    startedAtUtc = $startedAtUtc.ToString("o")
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
    finalStage = $finalStage
    sampleIntervalSeconds = $SampleIntervalSeconds
    maxConsecutiveSampleErrors = $MaxConsecutiveSampleErrors
    sampleCount = $sampleCount
    sampleErrors = $sampleErrors
    complete = (
        $finalStage -eq "finished" -and
        $sampleCount -gt 0 -and
        $sampleErrors.Count -eq 0
    )
    nodePeaks = @(
        $nodePeaks.Values |
        Sort-Object {
            "$($_.identity.nodePool)/$($_.identity.node)"
        }
    )
    containerPeaks = @(
        $containerPeaks.Values |
        Sort-Object {
            "$($_.identity.namespace)/$($_.identity.pod)/$($_.identity.container)"
        }
    )
}
[IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 10),
    $utf8NoBom
)

Write-Host ""
Write-Host "AKS resource monitoring completed." -ForegroundColor Green
Write-Host "Final stage: $finalStage"
Write-Host "Samples: $sampleCount"
Write-Host "Samples: $samplesPath"
Write-Host "Summary: $summaryPath"

[pscustomobject]@{
    RunId = $RunId
    FinalStage = $finalStage
    SampleCount = $sampleCount
    Complete = $summary.complete
    SamplesPath = $samplesPath
    SummaryPath = $summaryPath
}
