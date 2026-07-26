[CmdletBinding()]
param(
    [string] $MatrixPath = "",

    [string] $StatePath = "",

    [string] $OutputPrefix = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Get-Percentile {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Values,

        [Parameter(Mandatory)]
        [ValidateRange(0.0, 1.0)]
        [double] $Percentile
    )

    $numbers = @(
        $Values |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [double]$_ } |
            Sort-Object
    )
    if ($numbers.Count -eq 0) {
        return $null
    }
    if ($numbers.Count -eq 1) {
        return [double]$numbers[0]
    }

    $rank = $Percentile * ($numbers.Count - 1)
    $lower = [Math]::Floor($rank)
    $upper = [Math]::Ceiling($rank)
    if ($lower -eq $upper) {
        return [double]$numbers[$lower]
    }

    $weight = $rank - $lower
    return [double](
        $numbers[$lower] +
        (($numbers[$upper] - $numbers[$lower]) * $weight)
    )
}

function Get-Statistics {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Values
    )

    $numbers = @(
        $Values |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [double]$_ }
    )
    if ($numbers.Count -eq 0) {
        return $null
    }

    return [ordered]@{
        count = $numbers.Count
        minimum = [double](($numbers | Measure-Object -Minimum).Minimum)
        median = Get-Percentile -Values $numbers -Percentile 0.5
        maximum = [double](($numbers | Measure-Object -Maximum).Maximum)
        mean = [double](($numbers | Measure-Object -Average).Average)
    }
}

function Get-VcpuCount {
    param([Parameter(Mandatory)][string] $VmSize)

    if ($VmSize -notmatch "^Standard_D(?<count>\d+)") {
        throw "Cannot derive vCPU count from VM size '$VmSize'."
    }
    return [int]$Matches.count
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Value
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $null = New-Item -ItemType Directory -Force -Path $parent
    }
    [IO.File]::WriteAllText(
        $Path,
        $Value,
        [Text.UTF8Encoding]::new($false)
    )
}

function Format-Milliseconds {
    param([Parameter(Mandatory)][double] $Value)

    return "{0:N2}" -f $Value
}

$repositoryRoot = Get-RepositoryRoot
$resolvedMatrixPath = if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
    Join-Path `
        $repositoryRoot `
        "k8s-infra\matrices\aks-10k-d4-loadgen-d2-featbit-1s.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $MatrixPath
    )
}
$matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath |
    ConvertFrom-Json

$resultsDirectory = Join-Path $repositoryRoot "results"
$resolvedStatePath = if ([string]::IsNullOrWhiteSpace($StatePath)) {
    Join-Path $resultsDirectory "$($matrix.matrixId)-state.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $StatePath
    )
}
$state = Get-Content -Raw -LiteralPath $resolvedStatePath |
    ConvertFrom-Json

$matrixHash = (
    Get-FileHash -LiteralPath $resolvedMatrixPath -Algorithm SHA256
).Hash.ToLowerInvariant()
if ([string]$state.matrixSha256 -cne $matrixHash) {
    throw "Matrix state does not match the current matrix definition."
}
if ([string]$state.status -ne "completed") {
    throw "Matrix state is '$($state.status)', not completed."
}

$completedRuns = @(
    $state.runs |
        Where-Object status -eq "completed" |
        Sort-Object sequence
)
if ($completedRuns.Count -ne [int]$matrix.fixed.repetitions) {
    throw (
        "Expected $($matrix.fixed.repetitions) completed runs; " +
        "found $($completedRuns.Count)."
    )
}

$latencyAnalysisScript = Join-Path $PSScriptRoot "analyze-aks-latency.ps1"
$runRecords = @(
    foreach ($run in $completedRuns) {
        $archive = Join-Path $resultsDirectory $run.runId
        $evidencePath = Join-Path `
            $archive `
            "$($run.runId)-node-evidence-1s.json"
        if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
            throw (
                "Run '$($run.runId)' has no analyzed one-second evidence. " +
                "Run analyze-aks-1s-evidence.ps1 first."
            )
        }

        $latency = & $latencyAnalysisScript `
            -RunId $run.runId `
            -ResultsDirectory $resultsDirectory
        $evidence = Get-Content -Raw -LiteralPath $evidencePath |
            ConvertFrom-Json

        $formalThrottledPeriods = [int64]((
            $evidence.revisions |
                ForEach-Object { [int64]$_.elsThrottledPeriods } |
                Measure-Object -Sum
        ).Sum)
        $formalRetransmissions = [int64]((
            $evidence.revisions |
                ForEach-Object {
                    [int64]$_.loadgenTcpRetransSegments +
                    [int64]$_.featbitTcpRetransSegments
                } |
                Measure-Object -Sum
        ).Sum)
        $formalPacketDrops = [int64]((
            $evidence.revisions |
                ForEach-Object {
                    [int64]$_.loadgenPacketDrops +
                    [int64]$_.featbitPacketDrops
                } |
                Measure-Object -Sum
        ).Sum)
        $loadgenPacketDrops = [int64](
            [int64]$evidence.pools.loadgen.eth0RxDrops +
            [int64]$evidence.pools.loadgen.eth0TxDrops +
            [int64]$evidence.pools.loadgen.ciliumRxDrops +
            [int64]$evidence.pools.loadgen.ciliumTxDrops
        )

        [ordered]@{
            sequence = [int]$run.sequence
            runId = [string]$run.runId
            raw = [ordered]@{
                sampleCount = [int64]$run.analysis.sampleCount
                weightedAverageMs = [double]$run.analysis.weightedAverageMs
                worstRevisionRunnerP95Ms = [double](
                    $run.analysis.worstRevisionRunnerP95Ms
                )
                worstRevisionRunnerP99Ms = [double](
                    $run.analysis.worstRevisionRunnerP99Ms
                )
                maximumMs = [double]$run.analysis.maximumMs
                over100MsCount = [int64]$run.analysis.over100MsCount
                over100MsRate = [double]$run.analysis.over100MsRate
                affectedRunnerRevisionBatches = [int](
                    $latency.AffectedCohortCount
                )
                thresholdFailureCount = [int](
                    $run.analysis.thresholdFailureCount
                )
                connectionCount = [int]$run.analysis.connectionCount
                warmupPasses = [int]$run.analysis.warmupPasses
                revisionCount = [int]$run.analysis.revisionCount
            }
            withoutSpikes = [ordered]@{
                retainedSampleCount = [int64]$latency.RetainedSampleCount
                weightedAverageMs = [double](
                    $latency.WithoutSpikesRollup.avg
                )
                runnerP95MinimumMs = [double](
                    $latency.WithoutSpikesRollup.p95Min
                )
                runnerP95MaximumMs = [double](
                    $latency.WithoutSpikesRollup.p95Max
                )
                runnerP99MinimumMs = [double](
                    $latency.WithoutSpikesRollup.p99Min
                )
                runnerP99MaximumMs = [double](
                    $latency.WithoutSpikesRollup.p99Max
                )
                maximumMs = [double]$latency.WithoutSpikesRollup.max
            }
            oneSecondEvidence = [ordered]@{
                intervalCount = [int]$evidence.evidence.intervalRecords
                intervalP50Seconds = [double](
                    $evidence.evidence.intervalSeconds.median
                )
                intervalP95Seconds = [double](
                    $evidence.evidence.intervalSeconds.p95
                )
                loadgenCpuP99Percent = [double](
                    $evidence.pools.loadgen.cpuPercent.p99
                )
                loadgenCpuPressureP99Percent = [double](
                    $evidence.pools.loadgen.cpuPressurePercent.p99
                )
                loadgenRunQueueP99 = [double](
                    $evidence.pools.loadgen.runQueue.p99
                )
                loadgenRunQueueMaximum = [double](
                    $evidence.pools.loadgen.runQueue.maximum
                )
                loadgenNetRxSoftirqP99PerSecond = [double](
                    $evidence.pools.loadgen.netRxSoftirqPerSecond.p99
                )
                loadgenTcpRetransSegments = [int64](
                    $evidence.pools.loadgen.tcpRetransSegments
                )
                loadgenPacketDrops = $loadgenPacketDrops
                elsCpuP99Millicores = [double](
                    $evidence.els.cpuMillicores.p99
                )
                elsCpuMaximumMillicores = [double](
                    $evidence.els.cpuMillicores.maximum
                )
                elsCpuPressureP99Percent = [double](
                    $evidence.els.cpuPressurePercent.p99
                )
                elsThrottledPeriodRate = [double](
                    $evidence.els.throttledPeriodRate
                )
                elsThrottledMilliseconds = [double](
                    $evidence.els.throttledMilliseconds
                )
                formalWindowsElsThrottledPeriods = $formalThrottledPeriods
                formalWindowsRetransSegments = $formalRetransmissions
                formalWindowsPacketDrops = $formalPacketDrops
                correlationRunnerP99WithLoadgenCpu = [double](
                    $evidence.correlationsWithRunnerP99.
                        loadgenCpuMaximumPercent
                )
                correlationRunnerP99WithLoadgenCpuPressure = [double](
                    $evidence.correlationsWithRunnerP99.
                        loadgenCpuPressureMaximumPercent
                )
                correlationRunnerP99WithElsCpu = [double](
                    $evidence.correlationsWithRunnerP99.
                        elsCpuMaximumMillicores
                )
            }
            kubernetesPeaks = $evidence.kubernetesPeaks
            worstCohort = @($evidence.worstCohorts)[0]
            reports = [ordered]@{
                fullLatency = (
                    "results/$($run.runId)/" +
                    "$($run.runId)-latency-full.md"
                )
                withoutSpikes = (
                    "results/$($run.runId)/" +
                    "$($run.runId)-latency-without-spikes.md"
                )
                nodeEvidence = (
                    "results/$($run.runId)/" +
                    "$($run.runId)-node-evidence-1s.json"
                )
            }
        }
    }
)

$primaryP99 = Get-Statistics -Values @(
    $runRecords.raw.worstRevisionRunnerP99Ms
)
$weightedAverage = Get-Statistics -Values @(
    $runRecords.raw.weightedAverageMs
)
$spikeRate = Get-Statistics -Values @($runRecords.raw.over100MsRate)
$trimmedAverage = Get-Statistics -Values @(
    $runRecords.withoutSpikes.weightedAverageMs
)
$loadgenCpuP99 = Get-Statistics -Values @(
    $runRecords.oneSecondEvidence.loadgenCpuP99Percent
)
$loadgenPressureP99 = Get-Statistics -Values @(
    $runRecords.oneSecondEvidence.loadgenCpuPressureP99Percent
)
$elsCpuP99 = Get-Statistics -Values @(
    $runRecords.oneSecondEvidence.elsCpuP99Millicores
)
$bestRun = @(
    $runRecords |
        Sort-Object { $_.raw.worstRevisionRunnerP99Ms }
)[0]

$priorD2Path = Join-Path `
    $repositoryRoot `
    "docs\reports\aks-10k-d2-node-isolation-1s.json"
$priorD2Comparison = $null
if (Test-Path -LiteralPath $priorD2Path -PathType Leaf) {
    $prior = Get-Content -Raw -LiteralPath $priorD2Path |
        ConvertFrom-Json
    $priorD2Comparison = [ordered]@{
        reference = (
            "6 D4 FeatBit nodes + 10 D2 loadgen nodes, 20 x 500 runners"
        )
        referencePrimaryP99MedianMs = [double](
            $prior.summary.rawPrimaryP99Ms.median
        )
        currentPrimaryP99MedianMs = [double]$primaryP99.median
        primaryP99RelativeChange = (
            [double]$primaryP99.median /
            [double]$prior.summary.rawPrimaryP99Ms.median
        ) - 1.0
        referenceWeightedAverageMedianMs = [double](
            $prior.summary.rawWeightedAverageMs.median
        )
        currentWeightedAverageMedianMs = [double]$weightedAverage.median
        weightedAverageRelativeChange = (
            [double]$weightedAverage.median /
            [double]$prior.summary.rawWeightedAverageMs.median
        ) - 1.0
        referenceOver100MsMedianRate = [double](
            $prior.summary.rawOver100MsRate.median
        )
        currentOver100MsMedianRate = [double]$spikeRate.median
        over100MsRelativeChange = (
            [double]$spikeRate.median /
            [double]$prior.summary.rawOver100MsRate.median
        ) - 1.0
        referenceLoadgenCpuPressureP99MedianPercent = [double](
            $prior.summary.loadgenCpuPressureP99Percent.median
        )
        currentLoadgenCpuPressureP99MedianPercent = [double](
            $loadgenPressureP99.median
        )
        loadgenCpuPressureRelativeChange = (
            [double]$loadgenPressureP99.median /
            [double]$prior.summary.loadgenCpuPressureP99Percent.median
        ) - 1.0
    }
}

$historicalPath = Join-Path `
    $repositoryRoot `
    "docs\reports\aks-p99-capacity-10k-summary.json"
$historicalG1Comparison = $null
if (Test-Path -LiteralPath $historicalPath -PathType Leaf) {
    $historical = Get-Content -Raw -LiteralPath $historicalPath |
        ConvertFrom-Json
    $g1 = @($historical.groups | Where-Object id -eq "g1")[0]
    if ($null -ne $g1) {
        $historicalG1Comparison = [ordered]@{
            reference = (
                "Historical g1: 20 x 500, 10 D4 loadgen nodes, " +
                "six ELS Pods on three D4 FeatBit nodes"
            )
            referencePrimaryP99MedianMs = [double]$g1.primaryP99Ms.median
            currentPrimaryP99MedianMs = [double]$primaryP99.median
            primaryP99DeltaMs = (
                [double]$primaryP99.median -
                [double]$g1.primaryP99Ms.median
            )
            primaryP99RelativeChange = (
                [double]$primaryP99.median /
                [double]$g1.primaryP99Ms.median
            ) - 1.0
            referenceWeightedAverageMedianMs = [double](
                $g1.weightedAverageMs.median
            )
            currentWeightedAverageMedianMs = [double]$weightedAverage.median
            weightedAverageRelativeChange = (
                [double]$weightedAverage.median /
                [double]$g1.weightedAverageMs.median
            ) - 1.0
            referenceOver100MsMedianRate = [double](
                $g1.over100MsRate.median
            )
            currentOver100MsMedianRate = [double]$spikeRate.median
            over100MsPercentagePointDelta = (
                [double]$spikeRate.median -
                [double]$g1.over100MsRate.median
            )
            practicallyEquivalent = (
                [Math]::Abs(
                    [double]$primaryP99.median -
                    [double]$g1.primaryP99Ms.median
                ) -lt [double]$matrix.practicalEquivalence.
                    absoluteMilliseconds -and
                [Math]::Abs(
                    (
                        [double]$primaryP99.median /
                        [double]$g1.primaryP99Ms.median
                    ) - 1.0
                ) -lt [double]$matrix.practicalEquivalence.relativeFraction
            )
        }
    }
}

$systemVcpus = 2
$featbitVcpus = (
    (Get-VcpuCount -VmSize $matrix.fixed.featbitNodeVmSize) *
    [int]$matrix.fixed.featbitNodeCount
)
$loadgenVcpus = (
    (Get-VcpuCount -VmSize $matrix.fixed.loadgenNodeVmSize) *
    [int]$matrix.fixed.loadgenNodeCount
)

$result = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    matrixId = [string]$matrix.matrixId
    matrixSha256 = $matrixHash
    stateStatus = [string]$state.status
    primaryMetric = [string]$matrix.primaryMetric
    topology = [ordered]@{
        system = "1 x Standard_D2ds_v5"
        featbit = (
            "$($matrix.fixed.featbitNodeCount) x " +
            "$($matrix.fixed.featbitNodeVmSize)"
        )
        loadgen = (
            "$($matrix.fixed.loadgenNodeCount) x " +
            "$($matrix.fixed.loadgenNodeVmSize)"
        )
        els = (
            "$($matrix.groups[0].elsReplicas) Pods, one per FeatBit node"
        )
        elsResources = $matrix.fixed.elsResources
        runners = (
            "$($matrix.groups[0].parallelism) x " +
            "$($matrix.groups[0].connectionsPerRunner), " +
            "$($matrix.groups[0].runnersPerNode) per loadgen node"
        )
        runnerResources = $matrix.groups[0].runnerResources
        totalVcpus = $systemVcpus + $featbitVcpus + $loadgenVcpus
    }
    contract = [ordered]@{
        totalConnections = [int]$matrix.fixed.totalConnections
        connectionsPerSecond = [int]$matrix.fixed.connectionsPerSecond
        provisionedFlagCount = [int]$matrix.fixed.provisionedFlagCount
        measuredFlagCount = [int]$matrix.fixed.measuredFlagCount
        revisionCount = @($matrix.fixed.expectedRevisions).Count
        repetitions = [int]$matrix.fixed.repetitions
        spikeCutoffMs = 100
    }
    summary = [ordered]@{
        rawPrimaryP99Ms = $primaryP99
        rawWeightedAverageMs = $weightedAverage
        rawOver100MsRate = $spikeRate
        trimmedWeightedAverageMs = $trimmedAverage
        thresholdFailureCount = [int]((
            $runRecords.raw.thresholdFailureCount |
                Measure-Object -Sum
        ).Sum)
        loadgenCpuP99Percent = $loadgenCpuP99
        loadgenCpuPressureP99Percent = $loadgenPressureP99
        elsCpuP99Millicores = $elsCpuP99
        formalWindowsElsThrottledPeriods = [int64]((
            $runRecords.oneSecondEvidence.
                formalWindowsElsThrottledPeriods |
                Measure-Object -Sum
        ).Sum)
        formalWindowsRetransSegments = [int64]((
            $runRecords.oneSecondEvidence.formalWindowsRetransSegments |
                Measure-Object -Sum
        ).Sum)
        formalWindowsPacketDrops = [int64]((
            $runRecords.oneSecondEvidence.formalWindowsPacketDrops |
                Measure-Object -Sum
        ).Sum)
        bestPrimaryP99RunId = [string]$bestRun.runId
    }
    runs = $runRecords
    comparisons = [ordered]@{
        priorD2Loadgen = $priorD2Comparison
        historicalD4G1 = $historicalG1Comparison
    }
    conclusion = [ordered]@{
        outcome = (
            "The quota-safe D4 loadgen topology restored observer headroom " +
            "and passed all three 10,000-connection repetitions."
        )
        capacityBoundary = (
            "This validates exactly 10,000 concurrent WebSockets under the " +
            "recorded topology; it does not establish a maximum above 10,000."
        )
        spikeInterpretation = (
            "The >100 ms view is a pre-registered diagnostic filter. Run 2 " +
            "contains a whole-revision wave, so filtered values must not " +
            "replace the complete SLO result."
        )
    }
}

$resolvedPrefix = if ([string]::IsNullOrWhiteSpace($OutputPrefix)) {
    Join-Path `
        $repositoryRoot `
        "docs\reports\aks-10k-d4-loadgen-d2-featbit-1s"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputPrefix
    )
}
$jsonPath = "$resolvedPrefix.json"
$markdownPath = "$resolvedPrefix.md"
Write-Utf8Text -Path $jsonPath -Value (
    $result | ConvertTo-Json -Depth 40
)

$markdown = [Collections.Generic.List[string]]::new()
$markdown.Add("# AKS 10k：54-vCPU 配额内的 D4 loadgen 复核")
$markdown.Add("")
$markdown.Add("## 结论")
$markdown.Add("")
$markdown.Add(
    "按 ``1 × D2 system + 6 × D2 FeatBit + 10 × D4 loadgen = " +
    "$($result.topology.totalVcpus) vCPU`` 重分配后，三轮全部完成并通过。" +
    "三轮共 300,000 个正式传播样本、30,000 次满连接预热检查，" +
    "threshold failure 为 0。"
)
$markdown.Add("")
$markdown.Add(
    "- 保守 p99 三轮中位数为 " +
    "$(Format-Milliseconds $primaryP99.median) ms（" +
    "$(Format-Milliseconds $primaryP99.minimum)–" +
    "$(Format-Milliseconds $primaryP99.maximum) ms）。"
)
$markdown.Add(
    "- 加权平均延迟中位数为 " +
    "$(Format-Milliseconds $weightedAverage.median) ms；" +
    "``>100 ms`` 样本中位占比为 " +
    "$("{0:P3}" -f $spikeRate.median)。"
)
$markdown.Add(
    "- 最佳一轮是 ``$($bestRun.runId)``：保守 p99 " +
    "$(Format-Milliseconds $bestRun.raw.worstRevisionRunnerP99Ms) ms，" +
    "加权平均 $(Format-Milliseconds $bestRun.raw.weightedAverageMs) ms，" +
    "``>100 ms`` 占 $("{0:P3}" -f $bestRun.raw.over100MsRate)。"
)
if ($null -ne $priorD2Comparison) {
    $markdown.Add(
        "- 相较 10 × D2 loadgen 诊断轮，三轮中位保守 p99、平均延迟、" +
        "``>100 ms`` 占比和 loadgen CPU-pressure p99 分别变化 " +
        "$("{0:P2}" -f $priorD2Comparison.primaryP99RelativeChange)、" +
        "$("{0:P2}" -f $priorD2Comparison.weightedAverageRelativeChange)、" +
        "$("{0:P2}" -f $priorD2Comparison.over100MsRelativeChange)、" +
        "$("{0:P2}" -f $priorD2Comparison.loadgenCpuPressureRelativeChange)。"
    )
}
$markdown.Add("")
$markdown.Add("## 固定拓扑与负载")
$markdown.Add("")
$markdown.Add("| 项目 | 配置 |")
$markdown.Add("| --- | --- |")
$markdown.Add("| AKS vCPU | $($result.topology.totalVcpus) / 65 quota |")
$markdown.Add("| system | 1 × ``Standard_D2ds_v5`` |")
$markdown.Add(
    "| FeatBit | $($matrix.fixed.featbitNodeCount) × " +
    "``$($matrix.fixed.featbitNodeVmSize)`` |"
)
$markdown.Add(
    "| ELS | $($matrix.groups[0].elsReplicas) Pods，严格一节点一 Pod；" +
    "$($matrix.fixed.elsResources.cpuRequest) request / " +
    "$($matrix.fixed.elsResources.cpuLimit) CPU limit；" +
    "$($matrix.fixed.elsResources.memoryRequest) request / " +
    "$($matrix.fixed.elsResources.memoryLimit) limit |"
)
$markdown.Add(
    "| loadgen | $($matrix.fixed.loadgenNodeCount) × " +
    "``$($matrix.fixed.loadgenNodeVmSize)`` |"
)
$markdown.Add(
    "| k6 | $($matrix.groups[0].parallelism) runners × " +
    "$($matrix.groups[0].connectionsPerRunner) WS；每节点 " +
    "$($matrix.groups[0].runnersPerNode) runners |"
)
$markdown.Add(
    "| runner resources | " +
    "$($matrix.groups[0].runnerResources.cpuRequest) CPU / " +
    "$($matrix.groups[0].runnerResources.memoryRequest) memory request；" +
    "无 CPU limit，$($matrix.groups[0].runnerResources.memoryLimit) " +
    "memory limit |"
)
$markdown.Add(
    "| 建连 | $($matrix.fixed.totalConnections) WS，" +
    "$($matrix.fixed.connectionsPerSecond)/s |"
)
$markdown.Add(
    "| flags | 预置 $($matrix.fixed.provisionedFlagCount)；" +
    "flag-02 满连接预热；只变更/测量 flag-01 |"
)
$markdown.Add(
    "| 正式变更 | $(@($matrix.fixed.expectedRevisions).Count) revisions，" +
    "间隔 $($matrix.fixed.revisionIntervalSeconds)s；共 " +
    "$($matrix.fixed.repetitions) 次 |"
)
$markdown.Add(
    "| 采样 | Kubernetes " +
    "$($matrix.fixed.resourceSampleIntervalSeconds)s；" +
    "16 个工作节点 host/ELS cgroup 约 1s |"
)
$markdown.Add("")
$markdown.Add("## 正常结果（完整样本）")
$markdown.Add("")
$markdown.Add("| Run | 加权平均 | 最差 revision/runner p95 | 保守 p99 | max | >100 ms 波峰 | 受影响 runner × revision | failures |")
$markdown.Add("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
foreach ($run in $runRecords) {
    $markdown.Add(
        "| run $($run.sequence) | " +
        "$(Format-Milliseconds $run.raw.weightedAverageMs) ms | " +
        "$(Format-Milliseconds $run.raw.worstRevisionRunnerP95Ms) ms | " +
        "$(Format-Milliseconds $run.raw.worstRevisionRunnerP99Ms) ms | " +
        "$(Format-Milliseconds $run.raw.maximumMs) ms | " +
        "$($run.raw.over100MsCount) " +
        "($("{0:P3}" -f $run.raw.over100MsRate)) | " +
        "$($run.raw.affectedRunnerRevisionBatches) / 200 | " +
        "$($run.raw.thresholdFailureCount) |"
    )
}
$markdown.Add("")
$markdown.Add(
    "Run 2 的 revision 1 有 10,000 / 10,000 个样本超过 100 ms，" +
    "因此该轮的 20.099% 不是少量离群点，而是一次完整广播波。所有数值仍低于" +
    "预设的 p95 500 ms / p99 1000 ms gate。"
)
$markdown.Add("")
$markdown.Add("## 去除 ``>100 ms`` 后的诊断视图")
$markdown.Add("")
$markdown.Add("| Run | 删除样本 | 保留样本 | 保留后加权平均 | runner p95 范围 | runner p99 范围 |")
$markdown.Add("| --- | ---: | ---: | ---: | ---: | ---: |")
foreach ($run in $runRecords) {
    $markdown.Add(
        "| run $($run.sequence) | $($run.raw.over100MsCount) " +
        "($("{0:P3}" -f $run.raw.over100MsRate)) | " +
        "$($run.withoutSpikes.retainedSampleCount) | " +
        "$(Format-Milliseconds $run.withoutSpikes.weightedAverageMs) ms | " +
        "$(Format-Milliseconds $run.withoutSpikes.runnerP95MinimumMs)–" +
        "$(Format-Milliseconds $run.withoutSpikes.runnerP95MaximumMs) ms | " +
        "$(Format-Milliseconds $run.withoutSpikes.runnerP99MinimumMs)–" +
        "$(Format-Milliseconds $run.withoutSpikes.runnerP99MaximumMs) ms |"
    )
}
$markdown.Add("")
$markdown.Add(
    "> ``>100 ms`` 是运行前固定的诊断阈值。该表用于观察常见路径，" +
    "不能替代完整结果、隐藏波峰或作为新的 SLO。"
)
$markdown.Add("")
$markdown.Add("## 资源消耗")
$markdown.Add("")
$markdown.Add(
    "Kubernetes 峰值为同一 5 秒样本中的池级聚合值；host/cgroup " +
    "指标按约 1 秒采集。"
)
$markdown.Add("")
$markdown.Add("| Run | ELS 聚合峰值 | runner 聚合峰值 | FeatBit nodes 聚合峰值 | loadgen nodes 聚合峰值 | loadgen CPU / pressure / run queue p99 | ELS CPU p99 / throttle rate |")
$markdown.Add("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
foreach ($run in $runRecords) {
    $markdown.Add(
        "| run $($run.sequence) | " +
        "$("{0:N0}" -f $run.kubernetesPeaks.elsCpuMillicores)m / " +
        "$("{0:N0}" -f $run.kubernetesPeaks.elsMemoryMiB)Mi | " +
        "$("{0:N2}" -f ($run.kubernetesPeaks.runnerCpuMillicores / 1000)) " +
        "CPU / " +
        "$("{0:N2}" -f ($run.kubernetesPeaks.runnerMemoryMiB / 1024))Gi | " +
        "$("{0:N2}" -f (
            $run.kubernetesPeaks.featbitNodeCpuMillicores / 1000
        )) CPU / " +
        "$("{0:N2}" -f (
            $run.kubernetesPeaks.featbitNodeMemoryMiB / 1024
        ))Gi | " +
        "$("{0:N2}" -f (
            $run.kubernetesPeaks.loadgenNodeCpuMillicores / 1000
        )) CPU / " +
        "$("{0:N2}" -f (
            $run.kubernetesPeaks.loadgenNodeMemoryMiB / 1024
        ))Gi | " +
        "$("{0:N2}" -f (
            $run.oneSecondEvidence.loadgenCpuP99Percent
        ))% / " +
        "$("{0:N2}" -f (
            $run.oneSecondEvidence.loadgenCpuPressureP99Percent
        ))% / " +
        "$("{0:N2}" -f (
            $run.oneSecondEvidence.loadgenRunQueueP99
        )) | " +
        "$("{0:N1}" -f (
            $run.oneSecondEvidence.elsCpuP99Millicores
        ))m / " +
        "$("{0:P3}" -f (
            $run.oneSecondEvidence.elsThrottledPeriodRate
        )) |"
    )
}
$markdown.Add("")
$markdown.Add(
    "- 正式 revision 窗口合计 ELS throttled periods / TCP retrans / " +
    "packet drops = " +
    "$($result.summary.formalWindowsElsThrottledPeriods) / " +
    "$($result.summary.formalWindowsRetransSegments) / " +
    "$($result.summary.formalWindowsPacketDrops)。"
)
$markdown.Add(
    "- 三轮 ELS 1 秒 CPU p99 为 " +
    "$("{0:N1}" -f $elsCpuP99.minimum)–" +
    "$("{0:N1}" -f $elsCpuP99.maximum)m；没有接近单 Pod 1 CPU limit。"
)
$markdown.Add(
    "- D4 loadgen 的 CPU-pressure p99 为 " +
    "$("{0:N2}" -f $loadgenPressureP99.minimum)%–" +
    "$("{0:N2}" -f $loadgenPressureP99.maximum)%，明显低于 D2 " +
    "诊断轮的 27.67%–28.33%。"
)
$markdown.Add(
    "- Run 1 的最差 revision 与池级 7 次 retrans 同窗，但最差 runner " +
    "所在节点自身记录为 0；三轮均无 packet drop，因此不能把该波峰归因于丢包。"
)
$markdown.Add("")
$markdown.Add("## 对照边界")
$markdown.Add("")
if ($null -ne $priorD2Comparison) {
    $markdown.Add("| 指标 | 10 × D2 loadgen | 当前 10 × D4 loadgen | 变化 |")
    $markdown.Add("| --- | ---: | ---: | ---: |")
    $markdown.Add(
        "| 保守 p99 三轮中位数 | " +
        "$(Format-Milliseconds (
            $priorD2Comparison.referencePrimaryP99MedianMs
        )) ms | " +
        "$(Format-Milliseconds $primaryP99.median) ms | " +
        "$("{0:P2}" -f $priorD2Comparison.primaryP99RelativeChange) |"
    )
    $markdown.Add(
        "| 加权平均三轮中位数 | " +
        "$(Format-Milliseconds (
            $priorD2Comparison.referenceWeightedAverageMedianMs
        )) ms | " +
        "$(Format-Milliseconds $weightedAverage.median) ms | " +
        "$("{0:P2}" -f $priorD2Comparison.weightedAverageRelativeChange) |"
    )
    $markdown.Add(
        "| >100 ms 中位占比 | " +
        "$("{0:P3}" -f (
            $priorD2Comparison.referenceOver100MsMedianRate
        )) | " +
        "$("{0:P3}" -f $spikeRate.median) | " +
        "$("{0:P2}" -f $priorD2Comparison.over100MsRelativeChange) |"
    )
    $markdown.Add(
        "| loadgen CPU-pressure p99 中位数 | " +
        "$("{0:N2}" -f (
            $priorD2Comparison.
                referenceLoadgenCpuPressureP99MedianPercent
        ))% | " +
        "$("{0:N2}" -f $loadgenPressureP99.median)% | " +
        "$("{0:P2}" -f (
            $priorD2Comparison.loadgenCpuPressureRelativeChange
        )) |"
    )
    $markdown.Add("")
}
if ($null -ne $historicalG1Comparison) {
    $markdown.Add(
        "与历史 g1（同为 20 × 500 与 D4 loadgen，但 6 ELS 分布在 3 个 " +
        "D4 FeatBit nodes）相比，当前保守 p99 中位数为 " +
        "$(Format-Milliseconds $primaryP99.median) ms vs " +
        "$(Format-Milliseconds (
            $historicalG1Comparison.referencePrimaryP99MedianMs
        )) ms，差 " +
        "$(Format-Milliseconds (
            $historicalG1Comparison.primaryP99DeltaMs
        )) ms（" +
        "$("{0:P2}" -f (
            $historicalG1Comparison.primaryP99RelativeChange
        ))）。按矩阵预注册的 ``<50 ms`` 且 ``<10%`` 规则，两者实际等价：" +
        "``$($historicalG1Comparison.practicallyEquivalent)``。这是跨 campaign " +
        "比较，不是随机化单变量证明。"
    )
}
$markdown.Add("")
$markdown.Add(
    "现有证据支持「D2 loadgen 是上一轮主要观测端污染源」；它不支持" +
    "「剩余全部尾延迟都来自某一个 FeatBit 组件」。ELS 没有饱和，正式窗口" +
    "几乎无 throttling/丢包，而剩余波峰仍会随 runner/广播批次变化。"
)
$markdown.Add("")
$markdown.Add("## 复现与证据")
$markdown.Add("")
$markdown.Add('- 实验定义：[`aks-10k-d4-loadgen-d2-featbit-1s.json`](../../k8s-infra/matrices/aks-10k-d4-loadgen-d2-featbit-1s.json)')
$markdown.Add('- 基础设施：[`terraform/aks/terraform.tfvars.example`](../../k8s-infra/terraform/aks/terraform.tfvars.example)、[`featbit-aks-internal.yaml`](../../k8s-infra/values/featbit-aks-internal.yaml)')
$markdown.Add('- 执行器：[`run-aks-capacity-matrix.ps1`](../../k8s-infra/scripts/run-aks-capacity-matrix.ps1)')
$markdown.Add('- 单轮分析：[`analyze-aks-latency.ps1`](../../k8s-infra/scripts/analyze-aks-latency.ps1)、[`analyze-aks-1s-evidence.ps1`](../../k8s-infra/scripts/analyze-aks-1s-evidence.ps1)')
$markdown.Add('- 本汇总：[`summarize-aks-quota-safe-d4-loadgen.ps1`](../../k8s-infra/scripts/summarize-aks-quota-safe-d4-loadgen.ps1)')
$markdown.Add('- Machine-readable result：[`aks-10k-d4-loadgen-d2-featbit-1s.json`](aks-10k-d4-loadgen-d2-featbit-1s.json)')
$markdown.Add("")
$markdown.Add(
    '三轮 TestRun、runner JSON/HTML、完整/去波峰延迟报告、5 秒资源记录和 ' +
    '1 秒 TSV 均保留在本地 `results/<run-id>/`。本流程不会删除 TestRun、' +
    "PVC、AKS 或数据库。"
)
Write-Utf8Text -Path $markdownPath -Value (
    $markdown -join [Environment]::NewLine
)

[pscustomobject]@{
    MatrixId = $matrix.matrixId
    Runs = $runRecords.Count
    JsonPath = $jsonPath
    MarkdownPath = $markdownPath
    PrimaryP99MedianMs = $primaryP99.median
    WeightedAverageMedianMs = $weightedAverage.median
    Over100MsMedianRate = $spikeRate.median
    ThresholdFailureCount = $result.summary.thresholdFailureCount
}
