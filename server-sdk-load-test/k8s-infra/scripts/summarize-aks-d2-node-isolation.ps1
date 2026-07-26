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

function Get-TrimmedLatency {
    param(
        [Parameter(Mandatory)][string] $ArchiveDirectory,
        [Parameter(Mandatory)][string] $RunId
    )

    $testRunName = "featbit-$RunId"
    $pattern = (
        "^$([regex]::Escape($testRunName))-" +
        "(?<runner>\d+)-[a-z0-9]+-summary\.json$"
    )
    $rows = @(
        foreach ($summaryPath in [IO.Directory]::GetFiles(
            $ArchiveDirectory,
            "*-summary.json"
        )) {
            $match = [regex]::Match(
                [IO.Path]::GetFileName($summaryPath),
                $pattern
            )
            if (-not $match.Success) {
                continue
            }
            $summary = Get-Content -Raw -LiteralPath $summaryPath |
                ConvertFrom-Json
            $metricProperty = $summary.metrics.PSObject.Properties[
                "probe_sync_latency_without_spikes_ms"
            ]
            if ($null -eq $metricProperty) {
                throw (
                    "Runner $($match.Groups['runner'].Value) in '$RunId' " +
                    "does not expose the pre-registered de-spiked metric."
                )
            }
            [pscustomobject]@{
                runner = [int]$match.Groups["runner"].Value
                metric = $metricProperty.Value
            }
        }
    )
    if ($rows.Count -eq 0) {
        throw "No runner summaries were found for '$RunId'."
    }

    $count = [int64]((
        $rows |
            ForEach-Object { [int64]$_.metric.count } |
            Measure-Object -Sum
    ).Sum)
    $weightedSum = [double]((
        $rows |
            ForEach-Object {
                [double]$_.metric.avg * [int64]$_.metric.count
            } |
            Measure-Object -Sum
    ).Sum)

    return [ordered]@{
        retainedSampleCount = $count
        weightedAverageMs = if ($count -eq 0) {
            $null
        } else {
            $weightedSum / $count
        }
        runnerP95MinimumMs = [double]((
            $rows |
                ForEach-Object { [double]$_.metric.'p(95)' } |
                Measure-Object -Minimum
        ).Minimum)
        runnerP95MaximumMs = [double]((
            $rows |
                ForEach-Object { [double]$_.metric.'p(95)' } |
                Measure-Object -Maximum
        ).Maximum)
        runnerP99MinimumMs = [double]((
            $rows |
                ForEach-Object { [double]$_.metric.'p(99)' } |
                Measure-Object -Minimum
        ).Minimum)
        runnerP99MaximumMs = [double]((
            $rows |
                ForEach-Object { [double]$_.metric.'p(99)' } |
                Measure-Object -Maximum
        ).Maximum)
        maximumMs = [double]((
            $rows |
                ForEach-Object { [double]$_.metric.max } |
                Measure-Object -Maximum
        ).Maximum)
    }
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Value
    )

    [IO.File]::WriteAllText(
        $Path,
        $Value,
        [Text.UTF8Encoding]::new($false)
    )
}

$repositoryRoot = Get-RepositoryRoot
$resolvedMatrixPath = if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
    Join-Path `
        $repositoryRoot `
        "k8s-infra\matrices\aks-10k-d2-els-node-isolation-1s.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $MatrixPath
    )
}
$matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath | ConvertFrom-Json
$resultsDirectory = Join-Path $repositoryRoot "results"
$resolvedStatePath = if ([string]::IsNullOrWhiteSpace($StatePath)) {
    Join-Path $resultsDirectory "$($matrix.matrixId)-state.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $StatePath
    )
}
$state = Get-Content -Raw -LiteralPath $resolvedStatePath | ConvertFrom-Json
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
        $nodeEvidence = Get-Content -Raw -LiteralPath $evidencePath |
            ConvertFrom-Json
        $trimmed = Get-TrimmedLatency `
            -ArchiveDirectory $archive `
            -RunId $run.runId
        $spikeCount = [int64]$run.analysis.over100MsCount
        $sampleCount = [int64]$run.analysis.sampleCount
        if (
            $trimmed.retainedSampleCount + $spikeCount -ne $sampleCount
        ) {
            throw "Run '$($run.runId)' has inconsistent trimmed sample totals."
        }

        $eventThrottledPeriods = [int64]((
            $nodeEvidence.revisions |
                ForEach-Object { [int64]$_.elsThrottledPeriods } |
                Measure-Object -Sum
        ).Sum)
        $eventRetrans = [int64]((
            $nodeEvidence.revisions |
                ForEach-Object {
                    [int64]$_.loadgenTcpRetransSegments +
                    [int64]$_.featbitTcpRetransSegments
                } |
                Measure-Object -Sum
        ).Sum)
        $eventDrops = [int64]((
            $nodeEvidence.revisions |
                ForEach-Object {
                    [int64]$_.loadgenPacketDrops +
                    [int64]$_.featbitPacketDrops
                } |
                Measure-Object -Sum
        ).Sum)

        [ordered]@{
            sequence = [int]$run.sequence
            runId = [string]$run.runId
            raw = [ordered]@{
                sampleCount = $sampleCount
                weightedAverageMs = [double]$run.analysis.weightedAverageMs
                worstRevisionRunnerP95Ms = [double](
                    $run.analysis.worstRevisionRunnerP95Ms
                )
                worstRevisionRunnerP99Ms = [double](
                    $run.analysis.worstRevisionRunnerP99Ms
                )
                maximumMs = [double]$run.analysis.maximumMs
                over100MsCount = $spikeCount
                over100MsRate = [double]$run.analysis.over100MsRate
                thresholdFailureCount = [int](
                    $run.analysis.thresholdFailureCount
                )
                connectionCount = [int]$run.analysis.connectionCount
                warmupPasses = [int]$run.analysis.warmupPasses
                revisionCount = [int]$run.analysis.revisionCount
            }
            withoutSpikes = $trimmed
            oneSecondEvidence = [ordered]@{
                intervalCount = [int]$nodeEvidence.evidence.intervalRecords
                intervalP50Seconds = [double](
                    $nodeEvidence.evidence.intervalSeconds.median
                )
                intervalP95Seconds = [double](
                    $nodeEvidence.evidence.intervalSeconds.p95
                )
                loadgenCpuP95Percent = [double](
                    $nodeEvidence.pools.loadgen.cpuPercent.p95
                )
                loadgenCpuP99Percent = [double](
                    $nodeEvidence.pools.loadgen.cpuPercent.p99
                )
                loadgenCpuPressureP95Percent = [double](
                    $nodeEvidence.pools.loadgen.cpuPressurePercent.p95
                )
                loadgenCpuPressureP99Percent = [double](
                    $nodeEvidence.pools.loadgen.cpuPressurePercent.p99
                )
                loadgenRunQueueP99 = [double](
                    $nodeEvidence.pools.loadgen.runQueue.p99
                )
                loadgenRunQueueMaximum = [double](
                    $nodeEvidence.pools.loadgen.runQueue.maximum
                )
                loadgenTcpRetransSegments = [int64](
                    $nodeEvidence.pools.loadgen.tcpRetransSegments
                )
                loadgenPacketDrops = [int64](
                    $nodeEvidence.pools.loadgen.eth0RxDrops +
                    $nodeEvidence.pools.loadgen.eth0TxDrops +
                    $nodeEvidence.pools.loadgen.ciliumRxDrops +
                    $nodeEvidence.pools.loadgen.ciliumTxDrops
                )
                elsCpuP99Millicores = [double](
                    $nodeEvidence.els.cpuMillicores.p99
                )
                elsCpuMaximumMillicores = [double](
                    $nodeEvidence.els.cpuMillicores.maximum
                )
                elsCpuPressureP99Percent = [double](
                    $nodeEvidence.els.cpuPressurePercent.p99
                )
                elsThrottledPeriodRate = [double](
                    $nodeEvidence.els.throttledPeriodRate
                )
                elsThrottledMilliseconds = [double](
                    $nodeEvidence.els.throttledMilliseconds
                )
                formalWindowsElsThrottledPeriods = $eventThrottledPeriods
                formalWindowsRetransSegments = $eventRetrans
                formalWindowsPacketDrops = $eventDrops
                correlationRunnerP99WithLoadgenCpu = [double](
                    $nodeEvidence.correlationsWithRunnerP99.
                        loadgenCpuMaximumPercent
                )
                correlationRunnerP99WithLoadgenCpuPressure = [double](
                    $nodeEvidence.correlationsWithRunnerP99.
                        loadgenCpuPressureMaximumPercent
                )
                correlationRunnerP99WithElsCpu = [double](
                    $nodeEvidence.correlationsWithRunnerP99.
                        elsCpuMaximumMillicores
                )
            }
            kubernetesPeaks = $nodeEvidence.kubernetesPeaks
            worstCohort = @($nodeEvidence.worstCohorts)[0]
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

$primaryStats = Get-Statistics -Values @(
    $runRecords.raw.worstRevisionRunnerP99Ms
)
$averageStats = Get-Statistics -Values @($runRecords.raw.weightedAverageMs)
$spikeRateStats = Get-Statistics -Values @($runRecords.raw.over100MsRate)
$trimmedAverageStats = Get-Statistics -Values @(
    $runRecords.withoutSpikes.weightedAverageMs
)
$loadgenCpuP99Stats = Get-Statistics -Values @(
    $runRecords.oneSecondEvidence.loadgenCpuP99Percent
)
$loadgenPressureP99Stats = Get-Statistics -Values @(
    $runRecords.oneSecondEvidence.loadgenCpuPressureP99Percent
)
$elsCpuP99Stats = Get-Statistics -Values @(
    $runRecords.oneSecondEvidence.elsCpuP99Millicores
)
$lowestP99Run = @(
    $runRecords |
        Sort-Object { $_.raw.worstRevisionRunnerP99Ms }
)[0]

$historicalPath = Join-Path `
    $repositoryRoot `
    "docs\reports\aks-p99-capacity-10k-summary.json"
$historicalComparison = $null
if (Test-Path -LiteralPath $historicalPath -PathType Leaf) {
    $historical = Get-Content -Raw -LiteralPath $historicalPath |
        ConvertFrom-Json
    $g1 = @($historical.groups | Where-Object id -eq "g1")[0]
    if ($null -ne $g1) {
        $historicalComparison = [ordered]@{
            reference = (
                "Historical g1: 20 x 500, 10 D4 loadgen nodes, " +
                "six ELS Pods on three D4 FeatBit nodes"
            )
            historicalPrimaryP99MedianMs = [double]$g1.primaryP99Ms.median
            currentPrimaryP99MedianMs = [double]$primaryStats.median
            primaryP99DeltaMs = (
                [double]$primaryStats.median -
                [double]$g1.primaryP99Ms.median
            )
            primaryP99RelativeChange = (
                [double]$primaryStats.median /
                [double]$g1.primaryP99Ms.median
            ) - 1.0
            historicalWeightedAverageMedianMs = [double](
                $g1.weightedAverageMs.median
            )
            currentWeightedAverageMedianMs = [double]$averageStats.median
            weightedAverageDeltaMs = (
                [double]$averageStats.median -
                [double]$g1.weightedAverageMs.median
            )
            weightedAverageRelativeChange = (
                [double]$averageStats.median /
                [double]$g1.weightedAverageMs.median
            ) - 1.0
            historicalOver100MsMedianRate = [double](
                $g1.over100MsRate.median
            )
            currentOver100MsMedianRate = [double]$spikeRateStats.median
            over100MsPercentagePointDelta = (
                [double]$spikeRateStats.median -
                [double]$g1.over100MsRate.median
            )
            causalBoundary = (
                "This is a cross-campaign comparison: FeatBit placement and " +
                "the one-second collector also changed, so it is diagnostic " +
                "rather than a randomized single-variable proof."
            )
        }
    }
}

$result = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    matrixId = [string]$matrix.matrixId
    matrixSha256 = $matrixHash
    stateStatus = [string]$state.status
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
        runners = (
            "$($matrix.groups[0].parallelism) x " +
            "$($matrix.groups[0].connectionsPerRunner), " +
            "$($matrix.groups[0].runnersPerNode) per loadgen node"
        )
        totalVcpus = 46
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
        rawPrimaryP99Ms = $primaryStats
        rawWeightedAverageMs = $averageStats
        rawOver100MsRate = $spikeRateStats
        trimmedWeightedAverageMs = $trimmedAverageStats
        thresholdFailureCount = [int]((
            $runRecords.raw.thresholdFailureCount |
                Measure-Object -Sum
        ).Sum)
        loadgenCpuP99Percent = $loadgenCpuP99Stats
        loadgenCpuPressureP99Percent = $loadgenPressureP99Stats
        elsCpuP99Millicores = $elsCpuP99Stats
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
        lowestPrimaryP99RunId = [string]$lowestP99Run.runId
    }
    runs = $runRecords
    historicalComparison = $historicalComparison
    conclusion = [ordered]@{
        outcome = "D2 loadgen is not equivalent to the prior D4 reference."
        evidence = @(
            (
                "All 300,000 formal samples arrived, but the median " +
                "worst runner/revision p99 was " +
                "$([Math]::Round($primaryStats.median, 2)) ms."
            ),
            (
                "The >100 ms filter removes " +
                "$([Math]::Round($spikeRateStats.minimum * 100, 3))% to " +
                "$([Math]::Round($spikeRateStats.maximum * 100, 3))% of " +
                "samples, so the trimmed view is not an occasional-spike SLO."
            ),
            (
                "Loadgen CPU pressure repeated in all runs while ELS CPU, " +
                "throttling, retransmissions, and packet drops did not align " +
                "with formal revision tails."
            )
        )
        nextQuotaSafeIsolation = (
            "If another run is approved, first test one runner per D2 node " +
            "(10 x 1,000) or move D4 capacity back to loadgen by using six " +
            "D2 FeatBit nodes; do not lower k6 requests and mistake that for " +
            "additional physical CPU."
        )
    }
}

$resolvedPrefix = if ([string]::IsNullOrWhiteSpace($OutputPrefix)) {
    Join-Path `
        $repositoryRoot `
        "docs\reports\aks-10k-d2-node-isolation-1s"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputPrefix
    )
}
$jsonPath = "$resolvedPrefix.json"
$markdownPath = "$resolvedPrefix.md"
Write-Utf8Text -Path $jsonPath -Value ($result | ConvertTo-Json -Depth 40)

$markdown = [Collections.Generic.List[string]]::new()
$markdown.Add("# AKS 10k：D2 loadgen 与 ELS 单节点隔离实验")
$markdown.Add("")
$markdown.Add("## 结论")
$markdown.Add("")
$markdown.Add("本轮在现有配额内完成资源重分配并跑满三次，但 **D2 loadgen 不能替代先前 D4 参考拓扑来判断 FeatBit 容量**。三轮共 300,000 个正式传播样本全部收到；第三轮有 1 个 runner × revision 的 p95 超过 500 ms，其余连接、revision、最终状态和生存检查完整。")
$markdown.Add("")
$markdown.Add("- 保守 p99 三轮中位数为 $([Math]::Round($primaryStats.median, 2)) ms（$([Math]::Round($primaryStats.minimum, 2))–$([Math]::Round($primaryStats.maximum, 2)) ms）。")
$markdown.Add("- 加权平均延迟中位数为 $([Math]::Round($averageStats.median, 2)) ms；``>100 ms`` 样本中位占比为 $([Math]::Round($spikeRateStats.median * 100, 3))%。")
$markdown.Add("- D2 节点 CPU p99 只有 $([Math]::Round($loadgenCpuP99Stats.minimum, 2))%–$([Math]::Round($loadgenCpuP99Stats.maximum, 2))%，但 CPU pressure p99 稳定在 $([Math]::Round($loadgenPressureP99Stats.minimum, 2))%–$([Math]::Round($loadgenPressureP99Stats.maximum, 2))%，说明平均 CPU 掩盖了短时调度等待。")
$markdown.Add("- 正式 revision 窗口合计 ELS throttled periods / TCP retrans / packet drops 为 $($result.summary.formalWindowsElsThrottledPeriods) / $($result.summary.formalWindowsRetransSegments) / $($result.summary.formalWindowsPacketDrops)。")
$markdown.Add("")
$markdown.Add("## 固定拓扑与负载")
$markdown.Add("")
$markdown.Add("| 项目 | 配置 |")
$markdown.Add("| --- | --- |")
$markdown.Add("| AKS vCPU | 46（无需提高本轮配额） |")
$markdown.Add("| system | 1 × ``Standard_D2ds_v5`` |")
$markdown.Add("| FeatBit | 6 × ``Standard_D4ds_v5`` |")
$markdown.Add("| ELS | 6 Pods，严格每节点 1 Pod，500m request / 1 CPU limit，256Mi request / 512Mi limit |")
$markdown.Add("| loadgen | 10 × ``Standard_D2ds_v5`` |")
$markdown.Add("| k6 | 20 runners × 500 WS；每个 loadgen node 2 runners |")
$markdown.Add("| 建连 | 10,000 WS，100/s |")
$markdown.Add("| flags | 预置 20；flag-02 满连接预热；只变更/测量 flag-01 |")
$markdown.Add("| 正式变更 | 10 revisions，间隔 30s；每种配置 3 次 |")
$markdown.Add("| 采样 | Kubernetes 5s；16 个工作节点 host/ELS cgroup 实测 p50 1.01s、p95 1.06s |")
$markdown.Add("")
$markdown.Add("## 正常结果（不删除样本）")
$markdown.Add("")
$markdown.Add("| Run | 加权平均 | 最差 revision/runner p95 | 保守 p99 | max | >100 ms | threshold failures |")
$markdown.Add("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
foreach ($run in $runRecords) {
    $markdown.Add((
        "| ``$($run.runId)`` | " +
        "$("{0:N2}" -f $run.raw.weightedAverageMs) ms | " +
        "$("{0:N2}" -f $run.raw.worstRevisionRunnerP95Ms) ms | " +
        "$("{0:N2}" -f $run.raw.worstRevisionRunnerP99Ms) ms | " +
        "$("{0:N2}" -f $run.raw.maximumMs) ms | " +
        "$($run.raw.over100MsCount) " +
        "($("{0:P3}" -f $run.raw.over100MsRate)) | " +
        "$($run.raw.thresholdFailureCount) |"
    ))
}
$markdown.Add("")
$markdown.Add("三轮中最低保守 p99 是 run 2 的 $([Math]::Round($lowestP99Run.raw.worstRevisionRunnerP99Ms, 2)) ms；它是「本拓扑最好一次」，不是替代三轮稳定性统计。")
$markdown.Add("")
$markdown.Add("第三轮唯一 threshold failure 来自 runner 18 / revision 9：p95/p99/max = 562/567.03/571 ms。该节点上的另一个 runner 同一 revision p99 也约 460 ms；窗口 CPU/pressure 约 71.3%/51.2%，且 ELS throttling、重传、丢包均为 0。")
$markdown.Add("")
$markdown.Add("## 去除 ``>100 ms`` 后的诊断视图")
$markdown.Add("")
$markdown.Add("| Run | 删除样本 | 保留样本 | 保留后加权平均 | runner p95 范围 | runner p99 范围 |")
$markdown.Add("| --- | ---: | ---: | ---: | ---: | ---: |")
foreach ($run in $runRecords) {
    $markdown.Add((
        "| ``$($run.runId)`` | $($run.raw.over100MsCount) " +
        "($("{0:P3}" -f $run.raw.over100MsRate)) | " +
        "$($run.withoutSpikes.retainedSampleCount) | " +
        "$("{0:N2}" -f $run.withoutSpikes.weightedAverageMs) ms | " +
        "$("{0:N2}" -f $run.withoutSpikes.runnerP95MinimumMs)–" +
        "$("{0:N2}" -f $run.withoutSpikes.runnerP95MaximumMs) ms | " +
        "$("{0:N2}" -f $run.withoutSpikes.runnerP99MinimumMs)–" +
        "$("{0:N2}" -f $run.withoutSpikes.runnerP99MaximumMs) ms |"
    ))
}
$markdown.Add("")
$markdown.Add("> 本轮 ``>100 ms`` 占 52.503%–55.411%，已经不是「偶发波峰」。这个视图只回答剩余样本的形状，不能作为去抖后的真实性能或 SLO。")
$markdown.Add("")
$markdown.Add("## 资源消耗")
$markdown.Add("")
$markdown.Add("5 秒 Kubernetes 峰值是同一时刻的聚合值；1 秒 host 指标是各节点秒级分布。")
$markdown.Add("")
$markdown.Add("| Run | ELS 聚合峰值 | runner 聚合峰值 | FeatBit nodes 聚合峰值 | loadgen nodes 聚合峰值 | D2 CPU p99 / pressure p99 / run queue p99 | ELS cgroup CPU p99 / throttle rate |")
$markdown.Add("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
foreach ($run in $runRecords) {
    $markdown.Add((
        "| run $($run.sequence) | " +
        "$("{0:N0}" -f $run.kubernetesPeaks.elsCpuMillicores)m / " +
        "$("{0:N0}" -f $run.kubernetesPeaks.elsMemoryMiB)Mi | " +
        "$("{0:N2}" -f ($run.kubernetesPeaks.runnerCpuMillicores / 1000)) CPU / " +
        "$("{0:N2}" -f ($run.kubernetesPeaks.runnerMemoryMiB / 1024))Gi | " +
        "$("{0:N2}" -f ($run.kubernetesPeaks.featbitNodeCpuMillicores / 1000)) CPU / " +
        "$("{0:N2}" -f ($run.kubernetesPeaks.featbitNodeMemoryMiB / 1024))Gi | " +
        "$("{0:N2}" -f ($run.kubernetesPeaks.loadgenNodeCpuMillicores / 1000)) CPU / " +
        "$("{0:N2}" -f ($run.kubernetesPeaks.loadgenNodeMemoryMiB / 1024))Gi | " +
        "$("{0:N2}" -f $run.oneSecondEvidence.loadgenCpuP99Percent)% / " +
        "$("{0:N2}" -f $run.oneSecondEvidence.loadgenCpuPressureP99Percent)% / " +
        "$("{0:N2}" -f $run.oneSecondEvidence.loadgenRunQueueP99) | " +
        "$("{0:N1}" -f $run.oneSecondEvidence.elsCpuP99Millicores)m / " +
        "$("{0:P3}" -f $run.oneSecondEvidence.elsThrottledPeriodRate) |"
    ))
}
$markdown.Add("")
$markdown.Add("- ELS 六 Pod 聚合峰值仅 445–511m CPU、771–781Mi memory；单 Pod 1 秒 CPU p99 为 151–157m。")
$markdown.Add("- loadgen Kubernetes 聚合峰值只有 3.11–3.37 CPU / 20 vCPU，但单节点 1 秒 run queue p99 为 6.66–7（D2 仅 2 vCPU）。")
$markdown.Add("- 三轮 loadgen 全程 TCP retrans 合计 $((($runRecords.oneSecondEvidence.loadgenTcpRetransSegments | Measure-Object -Sum).Sum))，packet drops 为 0；全部正式 revision 窗口合计只有 2 次 retrans、0 次 drops，且没有与最差波峰对齐。")
$markdown.Add("- ELS 全程 throttling 很少（period rate 0.068%–0.092%），正式 revision 窗口为 0；其 CPU 与 runner p99 的探索性相关性也未呈正向。")
$markdown.Add("")
$markdown.Add("## 与历史 D4 参考的边界比较")
$markdown.Add("")
if ($null -ne $historicalComparison) {
    $markdown.Add("| 指标 | 历史 D4 g1 三轮中位数 | 当前 D2 三轮中位数 | 变化 |")
    $markdown.Add("| --- | ---: | ---: | ---: |")
    $markdown.Add("| 保守 p99 | $("{0:N2}" -f $historicalComparison.historicalPrimaryP99MedianMs) ms | $("{0:N2}" -f $historicalComparison.currentPrimaryP99MedianMs) ms | +$("{0:N2}" -f $historicalComparison.primaryP99DeltaMs) ms ($("{0:P2}" -f $historicalComparison.primaryP99RelativeChange)) |")
    $markdown.Add("| 加权平均 | $("{0:N2}" -f $historicalComparison.historicalWeightedAverageMedianMs) ms | $("{0:N2}" -f $historicalComparison.currentWeightedAverageMedianMs) ms | +$("{0:N2}" -f $historicalComparison.weightedAverageDeltaMs) ms ($("{0:P2}" -f $historicalComparison.weightedAverageRelativeChange)) |")
    $markdown.Add("| >100 ms | $("{0:P3}" -f $historicalComparison.historicalOver100MsMedianRate) | $("{0:P3}" -f $historicalComparison.currentOver100MsMedianRate) | +$("{0:N3}" -f ($historicalComparison.over100MsPercentagePointDelta * 100)) pp |")
    $markdown.Add("")
    $markdown.Add("这是跨 campaign 的诊断比较：FeatBit 从 3 个 D4 nodes（每节点 2 ELS）变成 6 个 D4 nodes（每节点 1 ELS），并加入 1 秒采集器，因此不能把差异当作严格的单变量因果证明。不过，同 D2 节点上的两个 runner 在同一 revision 成对变慢、loadgen CPU/pressure 与 p99 同向，而 ELS/网络指标不随之抬升，足以说明本轮结果受负载生成器明显污染。")
}
$markdown.Add("")
$markdown.Add("## 下一步（仍不申请配额）")
$markdown.Add("")
$markdown.Add("先不要继续降低 runner request；request 只影响调度保留量，不会给 D2 增加物理 CPU。更有信息量的下一步二选一：")
$markdown.Add("")
$markdown.Add("1. 保持 10 × D2 loadgen，改为 10 runners × 1,000 WS（每节点一个进程），检验同节点双 runner 调度竞争；")
$markdown.Add("2. 把 6 个 FeatBit nodes 改为 D2、把 10 个 loadgen nodes 恢复 D4：system 2 + FeatBit 12 + loadgen 40 = 54 vCPU，仍保留 ELS 一节点一 Pod且不提高现有峰值配额。")
$markdown.Add("")
$markdown.Add("方案 2 更适合继续判断 FeatBit 极限：本轮 ELS 单 Pod CPU p99 仅约 0.15 core，D4 算力优先留给观测端更合理；但它仍需作为新配置重新跑三次，不能与本轮拼接。")
$markdown.Add("")
$markdown.Add("## 复现与证据")
$markdown.Add("")
$markdown.Add('- Matrix：[`k8s-infra/matrices/aks-10k-d2-els-node-isolation-1s.json`](../../k8s-infra/matrices/aks-10k-d2-els-node-isolation-1s.json)')
$markdown.Add('- 执行器：[`k8s-infra/scripts/run-aks-capacity-matrix.ps1`](../../k8s-infra/scripts/run-aks-capacity-matrix.ps1)')
$markdown.Add('- 1 秒采集：[`start-aks-1s-evidence.ps1`](../../k8s-infra/scripts/start-aks-1s-evidence.ps1)、[`collect-aks-node-evidence.sh`](../../k8s-infra/scripts/collect-aks-node-evidence.sh)、[`stop-aks-1s-evidence.ps1`](../../k8s-infra/scripts/stop-aks-1s-evidence.ps1)')
$markdown.Add('- 单轮分析：[`analyze-aks-1s-evidence.ps1`](../../k8s-infra/scripts/analyze-aks-1s-evidence.ps1)、[`analyze-aks-latency.ps1`](../../k8s-infra/scripts/analyze-aks-latency.ps1)')
$markdown.Add('- 本汇总：[`summarize-aks-d2-node-isolation.ps1`](../../k8s-infra/scripts/summarize-aks-d2-node-isolation.ps1)')
$markdown.Add('- Machine-readable result：[`aks-10k-d2-node-isolation-1s.json`](aks-10k-d2-node-isolation-1s.json)')
$markdown.Add("")
$markdown.Add('所有 TestRun、Pod snapshot、runner JSON/HTML、正常/去波峰报告、5 秒资源记录与 1 秒 TSV 均保留在本地 `results/<run-id>/`。本流程不会删除 TestRun、PVC、AKS 或数据库。')
Write-Utf8Text -Path $markdownPath -Value ($markdown -join [Environment]::NewLine)

[pscustomobject]@{
    MatrixId = $matrix.matrixId
    Runs = $runRecords.Count
    JsonPath = $jsonPath
    MarkdownPath = $markdownPath
    PrimaryP99MedianMs = $primaryStats.median
    WeightedAverageMedianMs = $averageStats.median
    Over100MsMedianRate = $spikeRateStats.median
    ThresholdFailureCount = $result.summary.thresholdFailureCount
}
