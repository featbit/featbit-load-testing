[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateCount(2, 20)]
    [string[]] $RunId,

    [string[]] $Label = @(),

    [string] $ResultsDirectory = "",

    [string] $OutputPath = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

if ($Label.Count -gt 0 -and $Label.Count -ne $RunId.Count) {
    throw "Label must be omitted or contain exactly one value per RunId."
}

function Format-Milliseconds {
    param([AllowNull()][object] $Value)

    if ($null -eq $Value) {
        return "n/a"
    }
    return "{0:N2}" -f [double]$Value
}

function Format-Range {
    param(
        [AllowNull()][object] $Minimum,
        [AllowNull()][object] $Maximum
    )

    if ($null -eq $Minimum -or $null -eq $Maximum) {
        return "n/a"
    }
    return "{0:N2}–{1:N2}" -f [double]$Minimum, [double]$Maximum
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
$analysisScript = Join-Path $PSScriptRoot "analyze-aks-latency.ps1"

$rows = @(
    for ($index = 0; $index -lt $RunId.Count; $index += 1) {
        $id = $RunId[$index]
        $archiveDirectory = Join-Path $resultsRoot $id
        $collectionPath = Join-Path $archiveDirectory "collection.json"
        if (-not (Test-Path -LiteralPath $collectionPath -PathType Leaf)) {
            throw "Collection manifest does not exist for '$id'."
        }

        $analysis = & $analysisScript `
            -RunId $id `
            -ResultsDirectory $resultsRoot
        $collection = Get-Content -Raw -LiteralPath $collectionPath |
            ConvertFrom-Json

        $deploymentPath = Join-Path $archiveDirectory "$id-els-deployment.json"
        $deployment = if (Test-Path -LiteralPath $deploymentPath -PathType Leaf) {
            Get-Content -Raw -LiteralPath $deploymentPath | ConvertFrom-Json
        }
        else {
            $null
        }
        $podsPath = Join-Path $archiveDirectory "$id-els-pods.json"
        $pods = if (Test-Path -LiteralPath $podsPath -PathType Leaf) {
            (Get-Content -Raw -LiteralPath $podsPath | ConvertFrom-Json).items
        }
        else {
            @()
        }
        $placement = if (@($pods).Count -eq 0) {
            "n/a"
        }
        else {
            @(
                $pods |
                Group-Object { $_.spec.nodeName } |
                ForEach-Object Count |
                Sort-Object
            ) -join "/"
        }

        [pscustomobject]@{
            label = if ($Label.Count -eq 0) { $id } else { $Label[$index] }
            runId = $id
            image = if ($null -eq $deployment) {
                "n/a"
            }
            else {
                [string]$deployment.spec.template.spec.containers[0].image
            }
            placement = $placement
            collectionComplete = [bool]$collection.complete
            resourceEvidenceComplete = [bool]$collection.resourceEvidenceComplete
            analysis = $analysis
        }
    }
)

$lines = [Collections.Generic.List[string]]::new()
$lines.Add("# AKS 负载测试对照")
$lines.Add("")
$lines.Add("## 汇总")
$lines.Add("")
$lines.Add("| 轮次 | 样本 | avg | 去波峰 avg | >100ms | runner p95 范围 | runner p99 范围 | max | ELS 分布 | 资源完整 |")
$lines.Add("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
foreach ($row in $rows) {
    $analysis = $row.analysis
    $full = $analysis.FullRollup
    $trimmed = $analysis.WithoutSpikesRollup
    $lines.Add(
        "| $($row.label) | $($analysis.FullSampleCount) | " +
        "$(Format-Milliseconds $full.avg) ms | " +
        "$(Format-Milliseconds $trimmed.avg) ms | " +
        "$($analysis.SpikeCount) ($("{0:P3}" -f $analysis.SpikeRate)) | " +
        "$(Format-Range $full.p95Min $full.p95Max) ms | " +
        "$(Format-Range $full.p99Min $full.p99Max) ms | " +
        "$(Format-Milliseconds $full.max) ms | $($row.placement) | " +
        "$($row.resourceEvidenceComplete) |"
    )
}
$lines.Add("")
$lines.Add("## ELS 镜像")
$lines.Add("")
$lines.Add("| 轮次 | 镜像 |")
$lines.Add("| --- | --- |")
foreach ($row in $rows) {
    $imageMarkdown = if ($row.image -eq "n/a") {
        "n/a"
    }
    else {
        [char]0x60 + $row.image + [char]0x60
    }
    $lines.Add("| $($row.label) | $imageMarkdown |")
}
$lines.Add("")
$lines.Add("## Revision 明细")
$lines.Add("")
$lines.Add("| Revision | " + (($rows.label | ForEach-Object { "$_ avg / >100ms" }) -join " | ") + " |")
$lines.Add("| ---: | " + (($rows | ForEach-Object { "---: |" }) -join " "))
$revisionIndexes = @($rows[0].analysis.RevisionRollups.revision)
foreach ($revisionIndex in $revisionIndexes) {
    $cells = @(
        foreach ($row in $rows) {
            $revision = @(
                $row.analysis.RevisionRollups |
                Where-Object revision -eq $revisionIndex
            )
            if ($revision.Count -ne 1) {
                throw (
                    "Run '$($row.runId)' does not expose exactly one rollup " +
                    "for revision $revisionIndex."
                )
            }
            "$(Format-Milliseconds $revision[0].latency.avg) ms / " +
                "$("{0:P2}" -f $revision[0].spikeRate)"
        }
    )
    $lines.Add("| $revisionIndex | " + ($cells -join " | ") + " |")
}
$lines.Add("")
$lines.Add("## 证据质量")
$lines.Add("")
foreach ($row in $rows) {
    $analysis = $row.analysis
    $lines.Add(
        "- $($row.label): collectionComplete=$($row.collectionComplete), " +
        "resourceComplete=$($row.resourceEvidenceComplete), " +
        "thresholdFailures=$($analysis.ThresholdFailureCount), " +
        "warmup=$($analysis.WarmupPasses)/$($analysis.ConnectionCount), " +
        "runnerErrors=$($analysis.ErrorLineCount), " +
        "unknownPongWarnings=$($analysis.UnknownPingWarningCount)."
    )
}
$lines.Add("")

$resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $resultsRoot "aks-latency-comparison.md"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputPath
    )
}
$parentDirectory = Split-Path -Parent $resolvedOutputPath
if (-not [string]::IsNullOrWhiteSpace($parentDirectory)) {
    $null = New-Item -ItemType Directory -Force -Path $parentDirectory
}
[IO.File]::WriteAllLines(
    $resolvedOutputPath,
    $lines,
    [Text.UTF8Encoding]::new($false)
)

[pscustomobject]@{
    OutputPath = $resolvedOutputPath
    Runs = $rows
}
