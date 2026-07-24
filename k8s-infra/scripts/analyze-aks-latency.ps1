[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [string] $RunId,

    [ValidateSet(100)]
    [int] $SpikeCutoffMs = 100,

    [string] $ResultsDirectory = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Get-Metric {
    param(
        [Parameter(Mandatory)][object] $Summary,
        [Parameter(Mandatory)][string] $Name,
        [switch] $Optional
    )

    $property = $Summary.metrics.PSObject.Properties[$Name]
    if ($null -eq $property) {
        if ($Optional) {
            return $null
        }
        throw "Summary is missing required metric '$Name'."
    }
    return $property.Value
}

function Get-TrueCount {
    param([AllowNull()][object] $RateMetric)

    if ($null -eq $RateMetric) {
        return 0
    }
    $passes = $RateMetric.PSObject.Properties["passes"]
    if ($null -eq $passes) {
        throw "Rate metric does not expose a 'passes' count."
    }
    return [int64]$passes.Value
}

function Get-TrendRollup {
    param(
        [Parameter(Mandatory)][object[]] $Rows,
        [Parameter(Mandatory)][string] $Property
    )

    $eligible = @($Rows | Where-Object {
        $null -ne $_.$Property -and [int64]$_.$Property.count -gt 0
    })
    $count = [int64](($eligible | Measure-Object {
        [int64]$_.$Property.count
    } -Sum).Sum)
    if ($count -eq 0) {
        return [pscustomobject]@{
            count = 0
            avg = $null
            min = $null
            max = $null
            medMin = $null
            medMax = $null
            p90Min = $null
            p90Max = $null
            p95Min = $null
            p95Max = $null
            p99Min = $null
            p99Max = $null
        }
    }

    $weightedSum = ($eligible | Measure-Object {
        [double]$_.$Property.avg * [int64]$_.$Property.count
    } -Sum).Sum
    return [pscustomobject]@{
        count = $count
        avg = [double]$weightedSum / $count
        min = [double](($eligible | Measure-Object { [double]$_.$Property.min } -Minimum).Minimum)
        max = [double](($eligible | Measure-Object { [double]$_.$Property.max } -Maximum).Maximum)
        medMin = [double](($eligible | Measure-Object { [double]$_.$Property.med } -Minimum).Minimum)
        medMax = [double](($eligible | Measure-Object { [double]$_.$Property.med } -Maximum).Maximum)
        p90Min = [double](($eligible | Measure-Object { [double]$_.$Property.'p(90)' } -Minimum).Minimum)
        p90Max = [double](($eligible | Measure-Object { [double]$_.$Property.'p(90)' } -Maximum).Maximum)
        p95Min = [double](($eligible | Measure-Object { [double]$_.$Property.'p(95)' } -Minimum).Minimum)
        p95Max = [double](($eligible | Measure-Object { [double]$_.$Property.'p(95)' } -Maximum).Maximum)
        p99Min = [double](($eligible | Measure-Object { [double]$_.$Property.'p(99)' } -Minimum).Minimum)
        p99Max = [double](($eligible | Measure-Object { [double]$_.$Property.'p(99)' } -Maximum).Maximum)
    }
}

function Format-Milliseconds {
    param([AllowNull()][object] $Value)

    if ($null -eq $Value) {
        return "n/a"
    }
    return ("{0:N2} ms" -f [double]$Value)
}

function Format-Range {
    param(
        [AllowNull()][object] $Minimum,
        [AllowNull()][object] $Maximum
    )

    if ($null -eq $Minimum -or $null -eq $Maximum) {
        return "n/a"
    }
    return ("{0:N2}–{1:N2} ms" -f [double]$Minimum, [double]$Maximum)
}

function Format-RevisionSpikes {
    param([Parameter(Mandatory)][object] $RevisionSpikeCounts)

    $items = @(
        foreach ($entry in $RevisionSpikeCounts.GetEnumerator()) {
            if ([int64]$entry.Value -gt 0) {
                "rev-$($entry.Key):$($entry.Value)"
            }
        }
    )
    return $(if ($items.Count -eq 0) { "-" } else { $items -join ", " })
}

function Get-ThresholdFailures {
    param([Parameter(Mandatory)][object] $Summary)

    return @(
        foreach ($metricProperty in $Summary.metrics.PSObject.Properties) {
            $thresholdsProperty = $metricProperty.Value.PSObject.Properties["thresholds"]
            if ($null -eq $thresholdsProperty -or $null -eq $thresholdsProperty.Value) {
                continue
            }
            foreach ($thresholdProperty in $thresholdsProperty.Value.PSObject.Properties) {
                $value = $thresholdProperty.Value
                $failed = if ($value -is [bool]) {
                    [bool]$value
                }
                else {
                    $ok = $value.PSObject.Properties["ok"]
                    if ($null -eq $ok) {
                        throw "Unsupported threshold result for '$($metricProperty.Name)'."
                    }
                    -not [bool]$ok.Value
                }
                if ($failed) {
                    "$($metricProperty.Name): $($thresholdProperty.Name)"
                }
            }
        }
    )
}

$repositoryRoot = Get-RepositoryRoot
$resultsRoot = if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) {
    Join-Path $repositoryRoot "results"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $ResultsDirectory
    )
}
$archiveDirectory = Join-Path $resultsRoot $RunId
if (-not (Test-Path -LiteralPath $archiveDirectory -PathType Container)) {
    throw "Collected result directory does not exist: $archiveDirectory"
}

$collectionPath = Join-Path $archiveDirectory "collection.json"
if (-not (Test-Path -LiteralPath $collectionPath -PathType Leaf)) {
    throw "Collection manifest does not exist: $collectionPath"
}
$collection = Get-Content -Raw -LiteralPath $collectionPath | ConvertFrom-Json

$testRunName = "featbit-$RunId"
$runnerNodes = @{}
$podsPath = Join-Path $archiveDirectory "pods-cluster.json"
if (Test-Path -LiteralPath $podsPath -PathType Leaf) {
    $pods = (Get-Content -Raw -LiteralPath $podsPath | ConvertFrom-Json).items
    foreach ($pod in $pods) {
        if (
            [string]$pod.metadata.name -match
            "^$([regex]::Escape($testRunName))-(?<runner>\d+)-[a-z0-9]+$"
        ) {
            $runnerNodes[[int]$Matches.runner] = [string]$pod.spec.nodeName
        }
    }
}
$summaryPattern = "^$([regex]::Escape($testRunName))-(?<runner>\d+)-[a-z0-9]+-summary\.json$"
$summaryFiles = @(
    [IO.Directory]::GetFiles($archiveDirectory, "*-summary.json") |
    ForEach-Object {
        $match = [regex]::Match([IO.Path]::GetFileName($_), $summaryPattern)
        if ($match.Success) {
            [pscustomobject]@{
                Path = $_
                Runner = [int]$match.Groups["runner"].Value
            }
        }
    } |
    Sort-Object Runner
)
if ($summaryFiles.Count -ne [int]$collection.parallelism) {
    throw (
        "Expected $($collection.parallelism) runner summaries; " +
        "found $($summaryFiles.Count)."
    )
}

$rows = @(
    foreach ($file in $summaryFiles) {
        $summary = Get-Content -Raw -LiteralPath $file.Path | ConvertFrom-Json
        $full = Get-Metric -Summary $summary -Name "probe_sync_latency_ms"
        $withoutSpikes = Get-Metric `
            -Summary $summary `
            -Name "probe_sync_latency_without_spikes_ms" `
            -Optional
        $spikes = Get-Metric `
            -Summary $summary `
            -Name "probe_sync_over_${SpikeCutoffMs}ms"
        $revisionSpikeCounts = [ordered]@{}
        $revisionLatencyMetrics = [ordered]@{}
        $taggedLatencyMetrics = @(
            foreach ($metricProperty in $summary.metrics.PSObject.Properties) {
                $match = [regex]::Match(
                    $metricProperty.Name,
                    "^probe_sync_latency_ms\{revision_index:(?<index>\d+)\}$"
                )
                if ($match.Success) {
                    [pscustomobject]@{
                        index = [int]$match.Groups["index"].Value
                        metric = $metricProperty.Value
                    }
                }
            }
        ) | Sort-Object index
        foreach ($revisionMetric in $taggedLatencyMetrics) {
            $revisionLatencyMetrics[[string]$revisionMetric.index] = `
                $revisionMetric.metric
        }
        $revisionMetrics = @(
            foreach ($metricProperty in $summary.metrics.PSObject.Properties) {
                $match = [regex]::Match(
                    $metricProperty.Name,
                    "^probe_sync_over_$([regex]::Escape([string]$SpikeCutoffMs))ms" +
                    "\{revision_index:(?<index>\d+)\}$"
                )
                if ($match.Success) {
                    [pscustomobject]@{
                        index = [int]$match.Groups["index"].Value
                        metric = $metricProperty.Value
                    }
                }
            }
        ) | Sort-Object index
        foreach ($revisionMetric in $revisionMetrics) {
            $revisionSpikeCounts[[string]$revisionMetric.index] = Get-TrueCount `
                -RateMetric $revisionMetric.metric
        }
        $warmupCoverage = Get-Metric `
            -Summary $summary `
            -Name "post_ramp_warmup_coverage"
        $connectionOpened = Get-Metric `
            -Summary $summary `
            -Name "connection_opened"
        $jobLogPath = Join-Path `
            $archiveDirectory `
            "$testRunName-$($file.Runner).log"
        $jobLog = if (Test-Path -LiteralPath $jobLogPath -PathType Leaf) {
            [IO.File]::ReadAllText($jobLogPath)
        }
        else {
            ""
        }

        [pscustomobject]@{
            runner = $file.Runner
            node = if ($runnerNodes.ContainsKey($file.Runner)) {
                $runnerNodes[$file.Runner]
            }
            else {
                "unknown"
            }
            full = $full
            withoutSpikes = $withoutSpikes
            spikeCount = Get-TrueCount -RateMetric $spikes
            revisionSpikeCounts = $revisionSpikeCounts
            revisionLatencyMetrics = $revisionLatencyMetrics
            warmupPasses = Get-TrueCount -RateMetric $warmupCoverage
            connectionCount = [int64]$connectionOpened.count
            unknownPingWarningCount = [regex]::Matches(
                $jobLog,
                "received pong for unknown ping ID"
            ).Count
            errorLineCount = [regex]::Matches(
                $jobLog,
                "level=error",
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            ).Count
            thresholdFailures = @(Get-ThresholdFailures -Summary $summary)
        }
    }
)

$revisionIndexes = @(
    $rows[0].revisionSpikeCounts.Keys |
    ForEach-Object { [int]$_ } |
    Sort-Object
)
if ($revisionIndexes.Count -eq 0) {
    throw "Runner summaries do not contain any revision-specific spike metrics."
}
$expectedRevisionIndexes = @(1..$revisionIndexes.Count)
if (@(
    Compare-Object `
        -ReferenceObject $expectedRevisionIndexes `
        -DifferenceObject $revisionIndexes
).Count -ne 0) {
    throw "Revision-specific metrics must use contiguous indexes starting at 1."
}
foreach ($row in $rows) {
    $rowRevisionIndexes = @(
        $row.revisionSpikeCounts.Keys |
        ForEach-Object { [int]$_ } |
        Sort-Object
    )
    if (@(
        Compare-Object `
            -ReferenceObject $revisionIndexes `
            -DifferenceObject $rowRevisionIndexes
    ).Count -ne 0) {
        throw "Runner $($row.runner) has inconsistent revision-specific metrics."
    }
    $rowLatencyRevisionIndexes = @(
        $row.revisionLatencyMetrics.Keys |
        ForEach-Object { [int]$_ } |
        Sort-Object
    )
    if (@(
        Compare-Object `
            -ReferenceObject $revisionIndexes `
            -DifferenceObject $rowLatencyRevisionIndexes
    ).Count -ne 0) {
        throw "Runner $($row.runner) has inconsistent revision latency metrics."
    }
}
$revisionCount = $revisionIndexes.Count

$fullRollup = Get-TrendRollup -Rows $rows -Property "full"
$trimmedRollup = Get-TrendRollup -Rows $rows -Property "withoutSpikes"
$revisionRollups = @(
    foreach ($revisionIndex in $revisionIndexes) {
        $revisionRows = @(
            foreach ($row in $rows) {
                [pscustomobject]@{
                    value = $row.revisionLatencyMetrics[[string]$revisionIndex]
                }
            }
        )
        $rollup = Get-TrendRollup -Rows $revisionRows -Property "value"
        $revisionSpikeCount = [int64]((
            $rows |
            ForEach-Object {
                [int64]$_.revisionSpikeCounts[[string]$revisionIndex]
            } |
            Measure-Object -Sum
        ).Sum)
        [pscustomobject]@{
            revision = $revisionIndex
            latency = $rollup
            spikeCount = $revisionSpikeCount
            spikeRate = if ($rollup.count -eq 0) {
                0
            }
            else {
                $revisionSpikeCount / [double]$rollup.count
            }
        }
    }
)
$spikeCount = [int64](($rows | Measure-Object spikeCount -Sum).Sum)
$retainedCount = [int64]$trimmedRollup.count
if ($retainedCount + $spikeCount -ne [int64]$fullRollup.count) {
    throw (
        "Filtered sample accounting is inconsistent: retained=$retainedCount, " +
        "spikes=$spikeCount, full=$($fullRollup.count)."
    )
}

$warmupPasses = [int64](($rows | Measure-Object warmupPasses -Sum).Sum)
$connectionCount = [int64](($rows | Measure-Object connectionCount -Sum).Sum)
$unknownPingWarningCount = [int64]((
    $rows | Measure-Object unknownPingWarningCount -Sum
).Sum)
$errorLineCount = [int64](($rows | Measure-Object errorLineCount -Sum).Sum)
$affectedRunners = @($rows | Where-Object spikeCount -gt 0)
$affectedNodes = @(
    $affectedRunners.node |
    Where-Object { $_ -ne "unknown" } |
    Sort-Object -Unique
)
$affectedCohorts = @(
    foreach ($row in $rows) {
        foreach ($revisionIndex in $revisionIndexes) {
            $revisionSpikeCount = [int64]$row.revisionSpikeCounts[
                [string]$revisionIndex
            ]
            if ($revisionSpikeCount -gt 0) {
                [pscustomobject]@{
                    runner = $row.runner
                    node = $row.node
                    revision = $revisionIndex
                    spikes = $revisionSpikeCount
                }
            }
        }
    }
)
$thresholdFailures = @(
    foreach ($row in $rows) {
        foreach ($failure in $row.thresholdFailures) {
            "runner $($row.runner): $failure"
        }
    }
)
$spikeRate = if ($fullRollup.count -eq 0) {
    0
}
else {
    $spikeCount / [double]$fullRollup.count
}

$fullLines = [Collections.Generic.List[string]]::new()
$fullLines.Add("# $RunId 完整延迟报告")
$fullLines.Add("")
$fullLines.Add("## 统计口径")
$fullLines.Add("")
$fullLines.Add("- 只统计满连接预热之后 flag-01 的 $revisionCount 次正式 revision。")
$fullLines.Add("- 完整样本不删除任何 `probe_sync_latency_ms` 数据。")
$fullLines.Add("- 波峰在运行前固定定义为 `probe_sync_latency_ms > ${SpikeCutoffMs}ms`。")
$fullLines.Add("- 分布式 k6 无法从各 runner 摘要精确合并全局 percentile；因此平均值、样本数、min/max 和波峰占比是全局精确值，p90/p95/p99 报告为 runner 范围。")
$fullLines.Add("")
$fullLines.Add("## 总览")
$fullLines.Add("")
$fullLines.Add("| 指标 | 结果 |")
$fullLines.Add("| --- | ---: |")
$fullLines.Add("| 正式延迟样本 | $($fullRollup.count) |")
$fullLines.Add("| 加权平均 | $(Format-Milliseconds $fullRollup.avg) |")
$fullLines.Add("| 全局 min / max | $(Format-Milliseconds $fullRollup.min) / $(Format-Milliseconds $fullRollup.max) |")
$fullLines.Add("| runner median 范围 | $(Format-Range $fullRollup.medMin $fullRollup.medMax) |")
$fullLines.Add("| runner p90 范围 | $(Format-Range $fullRollup.p90Min $fullRollup.p90Max) |")
$fullLines.Add("| runner p95 范围 | $(Format-Range $fullRollup.p95Min $fullRollup.p95Max) |")
$fullLines.Add("| runner p99 范围 | $(Format-Range $fullRollup.p99Min $fullRollup.p99Max) |")
$fullLines.Add("| >${SpikeCutoffMs}ms 波峰样本 | $spikeCount / $($fullRollup.count) ($("{0:P3}" -f $spikeRate)) |")
$fullLines.Add("| 涉及 runner | $($affectedRunners.Count) / $($rows.Count) |")
$fullLines.Add("| 涉及 loadgen nodes | $($affectedNodes.Count) / $(@($rows.node | Sort-Object -Unique).Count) |")
$fullLines.Add("| 涉及 runner × revision 广播批次 | $($affectedCohorts.Count) / $($rows.Count * $revisionCount) |")
$fullLines.Add("| 满连接预热覆盖 | $warmupPasses / $connectionCount |")
$fullLines.Add("| threshold failures | $($thresholdFailures.Count) |")
$fullLines.Add("| runner error 日志行 | $errorLineCount |")
$fullLines.Add("| received pong for unknown ping ID warnings | $unknownPingWarningCount |")
$fullLines.Add("")
$fullLines.Add("## Revision 明细")
$fullLines.Add("")
$fullLines.Add("| Revision | count | avg | min | runner p95 范围 | runner p99 范围 | max | >${SpikeCutoffMs}ms |")
$fullLines.Add("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
foreach ($revisionRollup in $revisionRollups) {
    $latency = $revisionRollup.latency
    $fullLines.Add(
        "| $($revisionRollup.revision) | $($latency.count) | " +
        "$(Format-Milliseconds $latency.avg) | $(Format-Milliseconds $latency.min) | " +
        "$(Format-Range $latency.p95Min $latency.p95Max) | " +
        "$(Format-Range $latency.p99Min $latency.p99Max) | " +
        "$(Format-Milliseconds $latency.max) | $($revisionRollup.spikeCount) " +
        "($("{0:P3}" -f $revisionRollup.spikeRate)) |"
    )
}
$fullLines.Add("")
$fullLines.Add("## Runner 明细")
$fullLines.Add("")
$fullLines.Add("| Runner | Node | count | avg | med | p90 | p95 | p99 | max | >${SpikeCutoffMs}ms | 波峰 revisions |")
$fullLines.Add("| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
foreach ($row in $rows) {
    $fullLines.Add(
        "| $($row.runner) | $($row.node) | $($row.full.count) | $("{0:N2}" -f $row.full.avg) | " +
        "$("{0:N2}" -f $row.full.med) | $("{0:N2}" -f $row.full.'p(90)') | " +
        "$("{0:N2}" -f $row.full.'p(95)') | $("{0:N2}" -f $row.full.'p(99)') | " +
        "$("{0:N2}" -f $row.full.max) | $($row.spikeCount) | " +
        "$(Format-RevisionSpikes $row.revisionSpikeCounts) |"
    )
}
$fullLines.Add("")
if ($affectedCohorts.Count -gt 0) {
    $fullLines.Add("## 波峰广播批次")
    $fullLines.Add("")
    $fullLines.Add("| Runner | Node | Revision | 波峰样本 |")
    $fullLines.Add("| ---: | --- | ---: | ---: |")
    foreach ($cohort in $affectedCohorts) {
        $fullLines.Add(
            "| $($cohort.runner) | $($cohort.node) | " +
            "$($cohort.revision) | $($cohort.spikes) |"
        )
    }
    $fullLines.Add("")
    $fullLines.Add(
        "波峰集中在 $($affectedNodes.Count) 个 loadgen node。该相关性支持继续检查 " +
        "runner node 的进程调度、网络队列和日志 I/O，但本身不能证明 ELS 没有贡献。"
    )
    $fullLines.Add("")
}
if ($thresholdFailures.Count -gt 0) {
    $fullLines.Add("## Threshold failures")
    $fullLines.Add("")
    foreach ($failure in $thresholdFailures) {
        $fullLines.Add("- $failure")
    }
    $fullLines.Add("")
}

$trimmedLines = [Collections.Generic.List[string]]::new()
$trimmedLines.Add("# $RunId 去除偶发波峰后的延迟报告")
$trimmedLines.Add("")
$trimmedLines.Add("## 统计口径")
$trimmedLines.Add("")
$trimmedLines.Add("- 与完整报告来自同一次 TestRun、同一批连接和同 $revisionCount 次 flag 变更。")
$trimmedLines.Add("- 仅删除运行前预先定义的 `probe_sync_latency_ms > ${SpikeCutoffMs}ms` 样本。")
$trimmedLines.Add("- 该视图用于区分常态路径与偶发尾部，不替代完整结果或 SLO 判定。")
$trimmedLines.Add("")
$trimmedLines.Add("## 总览")
$trimmedLines.Add("")
$trimmedLines.Add("| 指标 | 结果 |")
$trimmedLines.Add("| --- | ---: |")
$trimmedLines.Add("| 原始样本 | $($fullRollup.count) |")
$trimmedLines.Add("| 删除波峰样本 | $spikeCount ($("{0:P3}" -f $spikeRate)) |")
$trimmedLines.Add("| 保留样本 | $retainedCount |")
$trimmedLines.Add("| 保留后加权平均 | $(Format-Milliseconds $trimmedRollup.avg) |")
$trimmedLines.Add("| 保留后全局 min / max | $(Format-Milliseconds $trimmedRollup.min) / $(Format-Milliseconds $trimmedRollup.max) |")
$trimmedLines.Add("| 保留后 runner median 范围 | $(Format-Range $trimmedRollup.medMin $trimmedRollup.medMax) |")
$trimmedLines.Add("| 保留后 runner p90 范围 | $(Format-Range $trimmedRollup.p90Min $trimmedRollup.p90Max) |")
$trimmedLines.Add("| 保留后 runner p95 范围 | $(Format-Range $trimmedRollup.p95Min $trimmedRollup.p95Max) |")
$trimmedLines.Add("| 保留后 runner p99 范围 | $(Format-Range $trimmedRollup.p99Min $trimmedRollup.p99Max) |")
$trimmedLines.Add("")
$trimmedLines.Add("## Runner 明细")
$trimmedLines.Add("")
$trimmedLines.Add("| Runner | Node | retained | removed | avg | med | p90 | p95 | p99 | max |")
$trimmedLines.Add("| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
foreach ($row in $rows) {
    if ($null -eq $row.withoutSpikes -or [int64]$row.withoutSpikes.count -eq 0) {
        $trimmedLines.Add(
            "| $($row.runner) | $($row.node) | 0 | $($row.spikeCount) | " +
            "n/a | n/a | n/a | n/a | n/a | n/a |"
        )
        continue
    }
    $trimmedLines.Add(
        "| $($row.runner) | $($row.node) | $($row.withoutSpikes.count) | " +
        "$($row.spikeCount) | " +
        "$("{0:N2}" -f $row.withoutSpikes.avg) | $("{0:N2}" -f $row.withoutSpikes.med) | " +
        "$("{0:N2}" -f $row.withoutSpikes.'p(90)') | " +
        "$("{0:N2}" -f $row.withoutSpikes.'p(95)') | " +
        "$("{0:N2}" -f $row.withoutSpikes.'p(99)') | " +
        "$("{0:N2}" -f $row.withoutSpikes.max) |"
    )
}
$trimmedLines.Add("")

$fullReportPath = Join-Path $archiveDirectory "$RunId-latency-full.md"
$trimmedReportPath = Join-Path $archiveDirectory "$RunId-latency-without-spikes.md"
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllLines($fullReportPath, $fullLines, $utf8NoBom)
[IO.File]::WriteAllLines($trimmedReportPath, $trimmedLines, $utf8NoBom)

[pscustomobject]@{
    RunId = $RunId
    FullReportPath = $fullReportPath
    WithoutSpikesReportPath = $trimmedReportPath
    FullSampleCount = $fullRollup.count
    SpikeCount = $spikeCount
    SpikeRate = $spikeRate
    RetainedSampleCount = $retainedCount
    AffectedRunnerCount = $affectedRunners.Count
    AffectedNodeCount = $affectedNodes.Count
    AffectedCohortCount = $affectedCohorts.Count
    FullRollup = $fullRollup
    WithoutSpikesRollup = $trimmedRollup
    ThresholdFailureCount = $thresholdFailures.Count
    WarmupPasses = $warmupPasses
    ConnectionCount = $connectionCount
    UnknownPingWarningCount = $unknownPingWarningCount
    ErrorLineCount = $errorLineCount
    RevisionRollups = $revisionRollups
}
