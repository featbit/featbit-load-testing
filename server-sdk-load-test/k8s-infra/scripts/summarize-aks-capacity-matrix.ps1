[CmdletBinding()]
param(
    [string] $MatrixPath = "",

    [string] $StatePath = "",

    [string] $OutputPrefix = "",

    [switch] $AllowIncomplete
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Get-Statistics {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Values
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

    $middle = [Math]::Floor($numbers.Count / 2)
    $median = if ($numbers.Count % 2 -eq 1) {
        $numbers[$middle]
    }
    else {
        ($numbers[$middle - 1] + $numbers[$middle]) / 2
    }
    return [ordered]@{
        count = $numbers.Count
        minimum = [double]$numbers[0]
        median = [double]$median
        maximum = [double]$numbers[-1]
        mean = [double](($numbers | Measure-Object -Average).Average)
    }
}

function Get-Maximum {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Values
    )

    $numbers = @($Values | Where-Object { $null -ne $_ })
    if ($numbers.Count -eq 0) {
        return 0.0
    }
    return [double](($numbers | Measure-Object -Maximum).Maximum)
}

function Get-RunResourceRecord {
    param(
        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [int] $ElsReplicas,

        [Parameter(Mandatory)]
        [string] $ArchiveDirectory
    )

    $samplesPath = Join-Path `
        $ArchiveDirectory `
        "$RunId-resource-samples.jsonl"
    $summaryPath = Join-Path `
        $ArchiveDirectory `
        "$RunId-resource-summary.json"
    foreach ($path in @($samplesPath, $summaryPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Run '$RunId' is missing resource evidence '$path'."
        }
    }

    $resourceSummary = Get-Content -Raw -LiteralPath $summaryPath |
        ConvertFrom-Json
    if (-not [bool]$resourceSummary.complete) {
        throw "Run '$RunId' has incomplete resource sampling."
    }

    $sampleRecords = [Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $samplesPath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $sample = $line | ConvertFrom-Json
        $containers = @($sample.containers)
        $nodes = @($sample.nodes)
        $els = @($containers | Where-Object {
            $_.namespace -eq "featbit" -and $_.container -eq "featbit-els"
        })
        $runners = @($containers | Where-Object {
            $_.namespace -eq "featbit-loadtest" -and $_.container -eq "k6"
        })
        $sampleRecords.Add([ordered]@{
            observedAtUtc = $sample.observedAtUtc
            elsPodCount = $els.Count
            elsCpuMillicores = [double]((
                $els |
                    ForEach-Object { $_.cpuMillicores } |
                    Measure-Object -Sum
            ).Sum)
            elsMemoryBytes = [double]((
                $els |
                    ForEach-Object { $_.memoryBytes } |
                    Measure-Object -Sum
            ).Sum)
            runnerPodCount = $runners.Count
            runnerCpuMillicores = [double]((
                $runners |
                    ForEach-Object { $_.cpuMillicores } |
                    Measure-Object -Sum
            ).Sum)
            runnerMemoryBytes = [double]((
                $runners |
                    ForEach-Object { $_.memoryBytes } |
                    Measure-Object -Sum
            ).Sum)
            featbitNodeCpuMillicores = [double]((
                $nodes |
                    Where-Object nodePool -eq "featbit" |
                    ForEach-Object { $_.cpuMillicores } |
                    Measure-Object -Sum
            ).Sum)
            featbitNodeMemoryBytes = [double]((
                $nodes |
                    Where-Object nodePool -eq "featbit" |
                    ForEach-Object { $_.memoryBytes } |
                    Measure-Object -Sum
            ).Sum)
            loadgenNodeCpuMillicores = [double]((
                $nodes |
                    Where-Object nodePool -eq "loadgen" |
                    ForEach-Object { $_.cpuMillicores } |
                    Measure-Object -Sum
            ).Sum)
            loadgenNodeMemoryBytes = [double]((
                $nodes |
                    Where-Object nodePool -eq "loadgen" |
                    ForEach-Object { $_.memoryBytes } |
                    Measure-Object -Sum
            ).Sum)
        })
    }
    if ($sampleRecords.Count -eq 0) {
        throw "Run '$RunId' has no resource samples."
    }

    $elsContainerPeaks = @($resourceSummary.containerPeaks | Where-Object {
        $_.identity.namespace -eq "featbit" -and
        $_.identity.container -eq "featbit-els"
    })
    $runnerContainerPeaks = @($resourceSummary.containerPeaks | Where-Object {
        $_.identity.namespace -eq "featbit-loadtest" -and
        $_.identity.container -eq "k6"
    })
    $elsCpuCapacityMillicores = $ElsReplicas * 1000.0
    $elsMemoryCapacityBytes = $ElsReplicas * 512.0 * 1024.0 * 1024.0
    $elsAggregatePeakCpu = Get-Maximum -Values @(
        $sampleRecords.elsCpuMillicores
    )
    $elsAggregatePeakMemory = Get-Maximum -Values @(
        $sampleRecords.elsMemoryBytes
    )

    return [ordered]@{
        sampleCount = $sampleRecords.Count
        els = [ordered]@{
            replicas = $ElsReplicas
            aggregatePeakCpuMillicores = $elsAggregatePeakCpu
            aggregatePeakCpuLimitPercent = (
                $elsAggregatePeakCpu / $elsCpuCapacityMillicores * 100.0
            )
            aggregatePeakMemoryMiB = $elsAggregatePeakMemory / 1MB
            aggregatePeakMemoryLimitPercent = (
                $elsAggregatePeakMemory / $elsMemoryCapacityBytes * 100.0
            )
            busiestPodPeakCpuMillicores = Get-Maximum -Values @(
                $elsContainerPeaks |
                    ForEach-Object { $_.peakCpuMillicores }
            )
            busiestPodPeakMemoryMiB = (
                (
                    Get-Maximum -Values @(
                        $elsContainerPeaks |
                            ForEach-Object { $_.peakMemoryBytes }
                    )
                ) / 1MB
            )
            maximumObservedPodCount = Get-Maximum -Values @(
                $sampleRecords.elsPodCount
            )
        }
        runners = [ordered]@{
            aggregatePeakCpuMillicores = Get-Maximum -Values @(
                $sampleRecords.runnerCpuMillicores
            )
            aggregatePeakMemoryMiB = (
                (Get-Maximum -Values @($sampleRecords.runnerMemoryBytes)) / 1MB
            )
            busiestPodPeakCpuMillicores = Get-Maximum -Values @(
                $runnerContainerPeaks |
                    ForEach-Object { $_.peakCpuMillicores }
            )
            busiestPodPeakMemoryMiB = (
                (
                    Get-Maximum -Values @(
                        $runnerContainerPeaks |
                            ForEach-Object { $_.peakMemoryBytes }
                    )
                ) / 1MB
            )
            maximumObservedPodCount = Get-Maximum -Values @(
                $sampleRecords.runnerPodCount
            )
        }
        nodes = [ordered]@{
            featbitAggregatePeakCpuMillicores = Get-Maximum -Values @(
                $sampleRecords.featbitNodeCpuMillicores
            )
            featbitAggregatePeakMemoryMiB = (
                (
                    Get-Maximum -Values @(
                        $sampleRecords.featbitNodeMemoryBytes
                    )
                ) / 1MB
            )
            loadgenAggregatePeakCpuMillicores = Get-Maximum -Values @(
                $sampleRecords.loadgenNodeCpuMillicores
            )
            loadgenAggregatePeakMemoryMiB = (
                (
                    Get-Maximum -Values @(
                        $sampleRecords.loadgenNodeMemoryBytes
                    )
                ) / 1MB
            )
        }
    }
}

function New-GroupComparison {
    param(
        [Parameter(Mandatory)]
        [string] $Label,

        [Parameter(Mandatory)]
        [object] $Reference,

        [Parameter(Mandatory)]
        [object] $Candidate
    )

    if (
        $null -eq $Reference.primaryP99Ms -or
        $null -eq $Candidate.primaryP99Ms
    ) {
        return [ordered]@{
            label = $Label
            referenceGroup = $Reference.id
            candidateGroup = $Candidate.id
            complete = $false
        }
    }

    $referenceMedian = [double]$Reference.primaryP99Ms.median
    $candidateMedian = [double]$Candidate.primaryP99Ms.median
    $delta = $candidateMedian - $referenceMedian
    $relative = if ($referenceMedian -eq 0) {
        $null
    }
    else {
        $delta / $referenceMedian
    }
    $withinAbsolute = (
        [Math]::Abs($delta) -lt
        [double]$script:Matrix.practicalEquivalence.absoluteMilliseconds
    )
    $withinRelative = (
        $null -ne $relative -and
        [Math]::Abs($relative) -lt
        [double]$script:Matrix.practicalEquivalence.relativeFraction
    )

    return [ordered]@{
        label = $Label
        referenceGroup = $Reference.id
        candidateGroup = $Candidate.id
        complete = (
            $Reference.completedRuns -eq $Reference.requiredRuns -and
            $Candidate.completedRuns -eq $Candidate.requiredRuns
        )
        referenceMedianMs = $referenceMedian
        candidateMedianMs = $candidateMedian
        deltaMs = $delta
        relativeChange = $relative
        practicallyEquivalent = ($withinAbsolute -and $withinRelative)
        direction = if ($delta -lt 0) {
            "candidate-lower"
        }
        elseif ($delta -gt 0) {
            "candidate-higher"
        }
        else {
            "equal"
        }
    }
}

function Format-Range {
    param(
        [AllowNull()]
        [object] $Statistics,

        [string] $Suffix = ""
    )

    if ($null -eq $Statistics) {
        return "n/a"
    }
    return (
        "{0:N2}{3} ({1:N2}–{2:N2}{3})" -f
        $Statistics.median,
        $Statistics.minimum,
        $Statistics.maximum,
        $Suffix
    )
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Value
    )

    [IO.File]::WriteAllText(
        $Path,
        $Value,
        [Text.UTF8Encoding]::new($false)
    )
}

$repositoryRoot = Get-RepositoryRoot
$resolvedMatrixPath = if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
    Join-Path $repositoryRoot "k8s-infra\matrices\aks-p99-capacity.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $MatrixPath
    )
}
$script:Matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath |
    ConvertFrom-Json
$resultsDirectory = Join-Path $repositoryRoot "results"
$resolvedStatePath = if ([string]::IsNullOrWhiteSpace($StatePath)) {
    Join-Path $resultsDirectory "$($script:Matrix.matrixId)-state.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $StatePath
    )
}
if (-not (Test-Path -LiteralPath $resolvedStatePath -PathType Leaf)) {
    throw "Matrix state does not exist: $resolvedStatePath"
}
$state = Get-Content -Raw -LiteralPath $resolvedStatePath |
    ConvertFrom-Json
$matrixHash = (
    Get-FileHash -LiteralPath $resolvedMatrixPath -Algorithm SHA256
).Hash.ToLowerInvariant()
if ([string]$state.matrixSha256 -cne $matrixHash) {
    throw "Matrix state does not match the current matrix definition."
}

$requiredRuns = [int]$script:Matrix.fixed.repetitions
$groupRecords = [Collections.Generic.List[object]]::new()
$runRecords = [Collections.Generic.List[object]]::new()
foreach ($group in @($script:Matrix.groups)) {
    $groupRuns = @(
        $state.runs |
            Where-Object group -eq $group.id |
            Sort-Object replicate
    )
    $completed = @($groupRuns | Where-Object status -eq "completed")
    if (-not $AllowIncomplete -and $completed.Count -ne $requiredRuns) {
        throw (
            "Group '$($group.id)' has $($completed.Count)/$requiredRuns " +
            "completed runs. Use -AllowIncomplete only for an interim report."
        )
    }

    foreach ($run in $completed) {
        if ($null -eq $run.analysis) {
            throw "Completed run '$($run.runId)' has no latency analysis."
        }
        $recordedArchive = if (
            -not [string]::IsNullOrWhiteSpace([string]$run.archiveDirectory)
        ) {
            [string]$run.archiveDirectory
        }
        else {
            ""
        }
        $suiteArchive = Join-Path $resultsDirectory $run.runId
        $archive = if (
            -not [string]::IsNullOrWhiteSpace($recordedArchive) -and
            (Test-Path -LiteralPath $recordedArchive -PathType Container)
        ) {
            $recordedArchive
        }
        else {
            $suiteArchive
        }
        $resources = Get-RunResourceRecord `
            -RunId $run.runId `
            -ElsReplicas ([int]$group.elsReplicas) `
            -ArchiveDirectory $archive
        $runRecords.Add([ordered]@{
            sequence = $run.sequence
            group = $group.id
            replicate = $run.replicate
            source = $run.source
            runId = $run.runId
            thresholdPassed = (
                [double]$run.analysis.worstRevisionRunnerP99Ms -lt
                [double]$script:Matrix.successThresholdMs
            )
            analysis = $run.analysis
            resources = $resources
        })
    }

    $completedRecords = @($runRecords | Where-Object group -eq $group.id)
    $primaryP99 = Get-Statistics -Values @(
        $completedRecords |
            ForEach-Object { $_.analysis.worstRevisionRunnerP99Ms }
    )
    $groupRecords.Add([ordered]@{
        id = $group.id
        label = $group.label
        parallelism = [int]$group.parallelism
        connectionsPerRunner = [int]$group.connectionsPerRunner
        runnersPerNode = [int]$group.runnersPerNode
        elsReplicas = [int]$group.elsReplicas
        averageConnectionsPerElsPod = (
            [double]$script:Matrix.fixed.totalConnections /
            [int]$group.elsReplicas
        )
        requiredRuns = $requiredRuns
        completedRuns = $completed.Count
        primaryP99Ms = $primaryP99
        weightedAverageMs = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object { $_.analysis.weightedAverageMs }
        )
        worstRevisionRunnerP95Ms = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object { $_.analysis.worstRevisionRunnerP95Ms }
        )
        maximumMs = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object { $_.analysis.maximumMs }
        )
        over100MsRate = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object { $_.analysis.over100MsRate }
        )
        allRevisionsBelowThreshold = (
            $completed.Count -eq $requiredRuns -and
            @($completedRecords | Where-Object {
                -not $_.thresholdPassed -or
                [int]$_.analysis.revisionCount -ne
                    @($script:Matrix.fixed.expectedRevisions).Count
            }).Count -eq 0
        )
        elsAggregatePeakCpuMillicores = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object {
                    $_.resources.els.aggregatePeakCpuMillicores
                }
        )
        elsAggregatePeakCpuLimitPercent = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object {
                    $_.resources.els.aggregatePeakCpuLimitPercent
                }
        )
        elsAggregatePeakMemoryMiB = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object {
                    $_.resources.els.aggregatePeakMemoryMiB
                }
        )
        elsAggregatePeakMemoryLimitPercent = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object {
                    $_.resources.els.aggregatePeakMemoryLimitPercent
                }
        )
        elsBusiestPodPeakCpuMillicores = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object {
                    $_.resources.els.busiestPodPeakCpuMillicores
                }
        )
        elsBusiestPodPeakMemoryMiB = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object {
                    $_.resources.els.busiestPodPeakMemoryMiB
                }
        )
        runnerAggregatePeakCpuMillicores = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object {
                    $_.resources.runners.aggregatePeakCpuMillicores
                }
        )
        runnerAggregatePeakMemoryMiB = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object {
                    $_.resources.runners.aggregatePeakMemoryMiB
                }
        )
        runnerBusiestPodPeakMemoryMiB = Get-Statistics -Values @(
            $completedRecords |
                ForEach-Object {
                    $_.resources.runners.busiestPodPeakMemoryMiB
                }
        )
        runIds = @($completed | ForEach-Object { $_.runId })
    })
}

function Get-GroupRecord {
    param([Parameter(Mandatory)][string] $Id)
    return @($groupRecords | Where-Object id -eq $Id)[0]
}

$comparisons = @(
    New-GroupComparison `
        -Label "runner sharding at ELS 6: p20 -> p40" `
        -Reference (Get-GroupRecord -Id "g1") `
        -Candidate (Get-GroupRecord -Id "g2")
    New-GroupComparison `
        -Label "runner sharding at ELS 12: p20 -> p40" `
        -Reference (Get-GroupRecord -Id "g3") `
        -Candidate (Get-GroupRecord -Id "g4")
    New-GroupComparison `
        -Label "ELS scaling at p20: 3 -> 6" `
        -Reference (Get-GroupRecord -Id "g5") `
        -Candidate (Get-GroupRecord -Id "g1")
    New-GroupComparison `
        -Label "ELS scaling at p20: 6 -> 12" `
        -Reference (Get-GroupRecord -Id "g1") `
        -Candidate (Get-GroupRecord -Id "g3")
    New-GroupComparison `
        -Label "ELS scaling at p40: 6 -> 12" `
        -Reference (Get-GroupRecord -Id "g2") `
        -Candidate (Get-GroupRecord -Id "g4")
)

$completeMatrix = @($groupRecords | Where-Object {
    $_.completedRuns -ne $_.requiredRuns
}).Count -eq 0
$passingGroups = @($groupRecords | Where-Object allRevisionsBelowThreshold)
$p20Passing = @($passingGroups | Where-Object parallelism -eq 20)
$tiersWithBothShardings = @(
    $groupRecords |
        # Group records are ordered dictionaries. Group-Object's property-name
        # form does not reliably resolve dictionary keys, so use an explicit
        # expression to keep ELS tiers distinct.
        Group-Object { [int]$_.elsReplicas } |
        Where-Object {
            @($_.Group | Where-Object allRevisionsBelowThreshold).Count -eq 2 -and
            @(
                $_.Group |
                    ForEach-Object { [int]$_.parallelism } |
                    Sort-Object -Unique
            ).Count -eq 2
        } |
        ForEach-Object { [int]$_.Name } |
        Sort-Object
)

$capacityConclusion = [ordered]@{
    complete = $completeMatrix
    thresholdMs = [double]$script:Matrix.successThresholdMs
    totalConnectionsTested = [int]$script:Matrix.fixed.totalConnections
    smallestPassingElsReplicaCountAtP20 = if ($p20Passing.Count -gt 0) {
        [int](($p20Passing.elsReplicas | Measure-Object -Minimum).Minimum)
    }
    else {
        $null
    }
    smallestPassingElsReplicaCountValidatedAcrossBothShardings = if (
        $tiersWithBothShardings.Count -gt 0
    ) {
        [int]$tiersWithBothShardings[0]
    }
    else {
        $null
    }
    exactMaximumConnectionCapacityEstablished = $false
    scope = (
        "This matrix establishes support (or failure) at exactly 10,000 " +
        "concurrent WebSockets. It does not establish the maximum above 10,000."
    )
}

$result = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    matrixId = $script:Matrix.matrixId
    matrixSha256 = $matrixHash
    stateStatus = $state.status
    complete = $completeMatrix
    primaryMetric = $script:Matrix.primaryMetric
    successThresholdMs = [double]$script:Matrix.successThresholdMs
    practicalEquivalence = $script:Matrix.practicalEquivalence
    fixed = $script:Matrix.fixed
    groups = @($groupRecords)
    runs = @($runRecords | Sort-Object sequence)
    comparisons = $comparisons
    capacityConclusion = $capacityConclusion
}

$resolvedPrefix = if ([string]::IsNullOrWhiteSpace($OutputPrefix)) {
    Join-Path $resultsDirectory $script:Matrix.matrixId
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputPrefix
    )
}
$jsonPath = "$resolvedPrefix-summary.json"
$markdownPath = "$resolvedPrefix-summary.md"
Write-Utf8Text `
    -Path $jsonPath `
    -Value ($result | ConvertTo-Json -Depth 30)

$markdown = [Collections.Generic.List[string]]::new()
$markdown.Add("# AKS 10k WebSocket p99 capacity matrix")
$markdown.Add("")
$markdown.Add("- 状态：$(if ($completeMatrix) { '完整' } else { '进行中' })")
$markdown.Add("- 主指标：$($script:Matrix.primaryMetric)")
$markdown.Add("- 门槛：每次运行的每个 revision、每个 runner p99 均小于 $($script:Matrix.successThresholdMs) ms")
$markdown.Add("- 固定负载：$($script:Matrix.fixed.totalConnections) 条 WebSocket，以 $($script:Matrix.fixed.connectionsPerSecond)/s 建连，10 revisions，3 次重复")
$markdown.Add("")
$markdown.Add("## 组汇总")
$markdown.Add("")
$markdown.Add("| 组 | runners × WS | ELS | 完成 | 最差 revision/runner p99 中位数（范围） | 全部通过 | ELS 聚合峰值 CPU 中位数 | ELS 聚合峰值内存中位数 |")
$markdown.Add("|---|---:|---:|---:|---:|:---:|---:|---:|")
foreach ($group in $groupRecords) {
    $markdown.Add((
        "| {0} | {1} × {2} | {3} pods / 3 nodes | {4}/{5} | {6} | {7} | {8} | {9} |" -f
        $group.id,
        $group.parallelism,
        $group.connectionsPerRunner,
        $group.elsReplicas,
        $group.completedRuns,
        $group.requiredRuns,
        (Format-Range -Statistics $group.primaryP99Ms -Suffix " ms"),
        $(if ($group.allRevisionsBelowThreshold) { "是" } else { "否/未完整" }),
        (Format-Range -Statistics $group.elsAggregatePeakCpuMillicores -Suffix "m"),
        (Format-Range -Statistics $group.elsAggregatePeakMemoryMiB -Suffix " MiB")
    ))
}
$markdown.Add("")
$markdown.Add("## 预注册组间比较")
$markdown.Add("")
$markdown.Add("只有相对变化 < $([double]$script:Matrix.practicalEquivalence.relativeFraction * 100)% 且绝对变化 < $($script:Matrix.practicalEquivalence.absoluteMilliseconds) ms，才判定为实际等价。")
$markdown.Add("")
$markdown.Add("| 比较 | 参考中位数 | 候选中位数 | 差值 | 相对变化 | 实际等价 |")
$markdown.Add("|---|---:|---:|---:|---:|:---:|")
foreach ($comparison in $comparisons) {
    if (-not $comparison.complete) {
        $markdown.Add("| $($comparison.label) | n/a | n/a | n/a | n/a | 未完整 |")
        continue
    }
    $markdown.Add((
        "| {0} | {1:N2} ms | {2:N2} ms | {3:+0.00;-0.00;0.00} ms | {4:+0.00%;-0.00%;0.00%} | {5} |" -f
        $comparison.label,
        $comparison.referenceMedianMs,
        $comparison.candidateMedianMs,
        $comparison.deltaMs,
        $comparison.relativeChange,
        $(if ($comparison.practicallyEquivalent) { "是" } else { "否" })
    ))
}
$markdown.Add("")
$markdown.Add("## 容量结论边界")
$markdown.Add("")
if ($completeMatrix) {
    $markdown.Add((
        "- p20 下通过门槛的最小 ELS 规模：{0}。" -f
        $(if ($null -eq $capacityConclusion.smallestPassingElsReplicaCountAtP20) {
            "没有通过的规模"
        } else {
            "$($capacityConclusion.smallestPassingElsReplicaCountAtP20) pods"
        })
    ))
    $markdown.Add((
        "- 同时在 p20 与 p40 分片下通过的最小已测 ELS 规模：{0}。" -f
        $(if (
            $null -eq
                $capacityConclusion.smallestPassingElsReplicaCountValidatedAcrossBothShardings
        ) {
            "没有"
        } else {
            "$($capacityConclusion.smallestPassingElsReplicaCountValidatedAcrossBothShardings) pods"
        })
    ))
}
else {
    $markdown.Add("- 矩阵尚未完成，暂不下容量结论。")
}
$markdown.Add("- 本实验只验证 10,000 并行 WebSocket；不能据此宣称 10,000 以上的精确极限。")
$markdown.Add("- 3 次重复用于观察稳定性和范围，不作统计显著性声明。")
$markdown.Add("")
$markdown.Add("JSON evidence: ``$jsonPath``")
Write-Utf8Text -Path $markdownPath -Value ($markdown -join [Environment]::NewLine)

Write-Host "Capacity matrix summary written." -ForegroundColor Green
Write-Host "JSON: $jsonPath"
Write-Host "Markdown: $markdownPath"

[pscustomobject]@{
    MatrixId = $script:Matrix.matrixId
    Complete = $completeMatrix
    CompletedRuns = @($runRecords).Count
    TotalRuns = @($script:Matrix.executionOrder).Count
    JsonPath = $jsonPath
    MarkdownPath = $markdownPath
}
