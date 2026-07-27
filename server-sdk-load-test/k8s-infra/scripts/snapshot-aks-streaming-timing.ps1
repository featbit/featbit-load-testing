[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [ValidateLength(1, 63)]
    [string] $RunId,

    [Parameter(Mandatory)]
    [string] $KubeContext,

    [Parameter(Mandatory)]
    [int64] $StartUnixMs,

    [Parameter(Mandatory)]
    [int64] $EndUnixMs,

    [string] $OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content
    )

    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite existing timing evidence: $Path"
    }
    [IO.File]::WriteAllText(
        $Path,
        $Content,
        [Text.UTF8Encoding]::new($false)
    )
}

if ($EndUnixMs -le $StartUnixMs) {
    throw "EndUnixMs must be greater than StartUnixMs."
}

$targetContext = $KubeContext.Trim()
$namespace = "featbit"
$daemonSetName = "featbit-stream-timing"
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

Assert-KubernetesContext -KubeContext $targetContext

$daemonSetText = (
    & kubectl --context $targetContext `
        -n $namespace `
        get daemonset $daemonSetName `
        -o json |
        Out-String
)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($daemonSetText)) {
    throw "The existing streaming timing observer DaemonSet does not exist."
}
$daemonSet = $daemonSetText | ConvertFrom-Json
$sourceRunId = [string]$daemonSet.metadata.labels."loadtest.featbit.io/run-id"

$podsText = (
    & kubectl --context $targetContext `
        -n $namespace `
        get pods `
        -l "app.kubernetes.io/name=$daemonSetName" `
        -o json |
        Out-String
)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($podsText)) {
    throw "Failed to inspect the existing streaming timing observer Pods."
}
$pods = @((($podsText | ConvertFrom-Json).items))
$readyPods = @($pods | Where-Object {
    $_.status.phase -eq "Running" -and
    @($_.status.containerStatuses | Where-Object ready).Count -eq
        @($_.status.containerStatuses).Count
})
$nodes = @($readyPods.spec.nodeName | Sort-Object -Unique)
if ($readyPods.Count -ne 10 -or $nodes.Count -ne 10) {
    throw (
        "Expected ten ready timing observer Pods on ten loadgen nodes; " +
        "found $($readyPods.Count) Pods on $($nodes.Count) nodes."
    )
}

$records = [Collections.Generic.List[object]]::new()
$rawLogs = [Collections.Generic.List[string]]::new()
foreach ($pod in ($readyPods | Sort-Object { $_.metadata.name })) {
    $podName = [string]$pod.metadata.name
    $nodeName = [string]$pod.spec.nodeName
    $logText = (
        & kubectl --context $targetContext `
            -n $namespace `
            logs $podName |
            Out-String
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to collect timing log from '$podName'."
    }

    foreach ($line in ($logText -split "\r?\n")) {
        $match = [regex]::Match(
            $line,
            "^STREAM_TIMING\|1\|(?<node>[^|]+)\|(?<at>\d+)\|(?<payload>[A-Za-z0-9+/=]+)$"
        )
        if (-not $match.Success) {
            continue
        }
        if ($match.Groups["node"].Value -cne $nodeName) {
            throw "Observer '$podName' logged an unexpected node name."
        }
        $observedAtUnixMs = [int64]$match.Groups["at"].Value
        if (
            $observedAtUnixMs -lt $StartUnixMs -or
            $observedAtUnixMs -gt $EndUnixMs
        ) {
            continue
        }

        try {
            $payloadJson = [Text.Encoding]::UTF8.GetString(
                [Convert]::FromBase64String($match.Groups["payload"].Value)
            )
            $payload = $payloadJson | ConvertFrom-Json
        }
        catch {
            throw (
                "Observer '$podName' emitted an invalid payload in the " +
                "requested window: $($_.Exception.Message)"
            )
        }

        $rawLogs.Add("$podName`t$line")
        $records.Add([ordered]@{
            schemaVersion = 1
            runId = $RunId
            sourceObserverRunId = $sourceRunId
            pod = $podName
            node = $nodeName
            observedAtUnixMs = $observedAtUnixMs
            channel = "featbit-feature-flag-change"
            payload = $payload
        })
    }
}

if ($records.Count -eq 0) {
    throw (
        "No feature-flag publication events were captured between " +
        "$StartUnixMs and $EndUnixMs. The existing observer was not changed."
    )
}

$eventsPath = Join-Path $resultsDirectory "$RunId-stream-timing-events.jsonl"
$podsPath = Join-Path $resultsDirectory "$RunId-stream-timing-pods.json"
$logsPath = Join-Path $resultsDirectory "$RunId-stream-timing-raw.log"
$eventLines = @(
    $records |
        Sort-Object observedAtUnixMs, node |
        ForEach-Object { $_ | ConvertTo-Json -Depth 30 -Compress }
)
Write-Utf8NoBom -Path $eventsPath -Content (($eventLines -join "`n") + "`n")
Write-Utf8NoBom -Path $podsPath -Content ($podsText.Trim() + "`n")
Write-Utf8NoBom -Path $logsPath -Content (($rawLogs -join "`n") + "`n")

Write-Host (
    "Streaming timing snapshot saved; the existing DaemonSet was preserved."
) -ForegroundColor Green
[pscustomobject]@{
    RunId = $RunId
    SourceObserverRunId = $sourceRunId
    ObserverPods = $readyPods.Count
    EventCount = $records.Count
    StartUnixMs = $StartUnixMs
    EndUnixMs = $EndUnixMs
    EventsPath = $eventsPath
    PodsPath = $podsPath
    RawLogsPath = $logsPath
    DeletedResources = 0
}
