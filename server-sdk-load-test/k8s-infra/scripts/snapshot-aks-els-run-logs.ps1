[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RunDirectory,

    [Parameter(Mandatory)]
    [string] $KubeContext
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        throw "Refusing to overwrite existing ELS log evidence: $Path"
    }
    [IO.File]::WriteAllText(
        $Path,
        $Content,
        [Text.UTF8Encoding]::new($false)
    )
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext

$resolvedRunDirectory = (
    $ExecutionContext.SessionState.Path.
        GetUnresolvedProviderPathFromPSPath($RunDirectory)
)
if (-not (Test-Path -LiteralPath $resolvedRunDirectory -PathType Container)) {
    throw "Run directory does not exist: $resolvedRunDirectory"
}
$runId = Split-Path -Leaf $resolvedRunDirectory
$analysisPath = Join-Path `
    $resolvedRunDirectory `
    "$runId-dotnet-pilot-analysis.json"
if (-not (Test-Path -LiteralPath $analysisPath -PathType Leaf)) {
    throw "Canonical .NET pilot analysis is missing: $analysisPath"
}
$analysis = Get-Content -LiteralPath $analysisPath -Raw | ConvertFrom-Json
if ([string]$analysis.status -ne "passed") {
    throw "ELS run logs can only be finalized for a passed pilot analysis."
}

$startUnixMs = [int64]$analysis.elsCgroup.preCapturedAtUnixMs
$endUnixMs = [int64]$analysis.elsCgroup.postCapturedAtUnixMs
$start = [DateTimeOffset]::FromUnixTimeMilliseconds($startUnixMs)
$end = [DateTimeOffset]::FromUnixTimeMilliseconds($endUnixMs)
$sinceTime = $start.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

$podResults = [Collections.Generic.List[object]]::new()
foreach ($expected in @($analysis.elsCgroup.perPod)) {
    $podName = [string]$expected.pod
    $podText = (& kubectl `
        --context $targetContext `
        -n featbit `
        get pod $podName `
        -o json | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($podText)) {
        throw "Failed to read ELS Pod '$podName'."
    }
    $pod = $podText | ConvertFrom-Json
    if ([string]$pod.metadata.uid -cne [string]$expected.podUid) {
        throw (
            "ELS Pod '$podName' changed UID after the exact cgroup window; " +
            "refusing to associate foreign logs."
        )
    }

    $allLines = @(& kubectl `
        --context $targetContext `
        -n featbit `
        logs $podName `
        -c featbit-els `
        --timestamps=true `
        --since-time=$sinceTime)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to capture ELS logs for '$podName'."
    }

    $windowLines = [Collections.Generic.List[string]]::new()
    foreach ($line in $allLines) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) {
            continue
        }
        $parts = [string]$line -split "\s+", 2
        if ($parts.Count -ne 2) {
            continue
        }
        try {
            $timestamp = [DateTimeOffset]::Parse($parts[0])
        }
        catch {
            continue
        }
        if ($timestamp -ge $start -and $timestamp -le $end) {
            $windowLines.Add([string]$line)
        }
    }

    $logPath = Join-Path `
        $resolvedRunDirectory `
        "$runId-els-$podName.log"
    Write-Utf8NoBom `
        -Path $logPath `
        -Content (($windowLines -join "`n") + "`n")

    $oomLines = @($windowLines | Where-Object {
        $_ -match "(?i)OutOfMemoryException|out of memory|oomkill"
    })
    $dataSyncErrorLines = @($windowLines | Where-Object {
        $_ -match "(?i)DataSyncMessageHandler" -and
        $_ -match "(?i)error|fail|exception"
    })
    $fatalLines = @($windowLines | Where-Object {
        $_ -match "(?i)\b(fatal|unhandled exception)\b"
    })
    $podResults.Add([ordered]@{
        pod = $podName
        podUid = [string]$expected.podUid
        node = [string]$expected.node
        restartCountDelta = 0
        lineCount = $windowLines.Count
        outOfMemoryLines = $oomLines.Count
        dataSyncMessageHandlerErrorLines = $dataSyncErrorLines.Count
        fatalOrUnhandledLines = $fatalLines.Count
        logFile = Split-Path -Leaf $logPath
    })
}

$summary = [ordered]@{
    schemaVersion = 1
    runId = $runId
    status = "passed"
    kubernetesContext = $targetContext
    startUnixMs = $startUnixMs
    endUnixMs = $endUnixMs
    podCount = $podResults.Count
    pods = @($podResults)
    totals = [ordered]@{
        restartCountDelta = [int]((
            $podResults.restartCountDelta | Measure-Object -Sum
        ).Sum)
        lineCount = [int](($podResults.lineCount | Measure-Object -Sum).Sum)
        outOfMemoryLines = [int]((
            $podResults.outOfMemoryLines | Measure-Object -Sum
        ).Sum)
        dataSyncMessageHandlerErrorLines = [int]((
            $podResults.dataSyncMessageHandlerErrorLines |
                Measure-Object -Sum
        ).Sum)
        fatalOrUnhandledLines = [int]((
            $podResults.fatalOrUnhandledLines | Measure-Object -Sum
        ).Sum)
    }
    credentialsPassedToKubectlLogs = $false
    resourcesDeleted = 0
}
if (
    $summary.totals.outOfMemoryLines -ne 0 -or
    $summary.totals.dataSyncMessageHandlerErrorLines -ne 0 -or
    $summary.totals.fatalOrUnhandledLines -ne 0
) {
    $summary.status = "failed"
}

$summaryPath = Join-Path `
    $resolvedRunDirectory `
    "$runId-els-log-summary.json"
Write-Utf8NoBom `
    -Path $summaryPath `
    -Content (($summary | ConvertTo-Json -Depth 12) + "`n")

if ($summary.status -ne "passed") {
    throw (
        "ELS log gate failed: OOM=$($summary.totals.outOfMemoryLines), " +
        "DataSync=$($summary.totals.dataSyncMessageHandlerErrorLines), " +
        "fatal=$($summary.totals.fatalOrUnhandledLines)."
    )
}

[pscustomobject]@{
    RunId = $runId
    Status = $summary.status
    PodCount = $summary.podCount
    OutOfMemoryLines = $summary.totals.outOfMemoryLines
    DataSyncMessageHandlerErrorLines =
        $summary.totals.dataSyncMessageHandlerErrorLines
    FatalOrUnhandledLines = $summary.totals.fatalOrUnhandledLines
    RestartCountDelta = $summary.totals.restartCountDelta
    SummaryPath = $summaryPath
    ResourcesDeleted = 0
}
