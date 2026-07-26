[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [ValidateLength(1, 63)]
    [string] $RunId,

    [Parameter(Mandatory)]
    [string] $KubeContext,

    [string] $OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content
    )

    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
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
    throw "The streaming timing observer DaemonSet does not exist."
}
$daemonSet = $daemonSetText | ConvertFrom-Json
$actualRunId = [string]$daemonSet.metadata.labels."loadtest.featbit.io/run-id"
if ($actualRunId -cne $RunId) {
    throw (
        "Refusing to stop timing for '$RunId'; the active observer belongs " +
        "to '$actualRunId'."
    )
}

$podsText = (
    & kubectl --context $targetContext `
        -n $namespace `
        get pods `
        -l "app.kubernetes.io/name=$daemonSetName" `
        -o json |
        Out-String
)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($podsText)) {
    throw "Failed to inspect streaming timing observer Pods."
}
$pods = ($podsText | ConvertFrom-Json).items
if ($pods.Count -eq 0) {
    throw "No streaming timing observer Pods were found."
}

$records = [Collections.Generic.List[object]]::new()
$rawLogs = [Collections.Generic.List[string]]::new()
foreach ($pod in ($pods | Sort-Object { $_.metadata.name })) {
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
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $rawLogs.Add("$podName`t$line")
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

        try {
            $payloadJson = [Text.Encoding]::UTF8.GetString(
                [Convert]::FromBase64String($match.Groups["payload"].Value)
            )
            $payload = $payloadJson | ConvertFrom-Json
        }
        catch {
            throw "Observer '$podName' emitted an invalid payload: $($_.Exception.Message)"
        }

        $records.Add([ordered]@{
            schemaVersion = 1
            runId = $RunId
            pod = $podName
            node = $nodeName
            observedAtUnixMs = [int64]$match.Groups["at"].Value
            channel = "featbit-feature-flag-change"
            payload = $payload
        })
    }
}

if ($records.Count -eq 0) {
    throw (
        "No feature-flag publication events were captured. The observer is " +
        "being preserved for diagnosis."
    )
}

$eventsPath = Join-Path $resultsDirectory "$RunId-stream-timing-events.jsonl"
$podsPath = Join-Path $resultsDirectory "$RunId-stream-timing-pods.json"
$logsPath = Join-Path $resultsDirectory "$RunId-stream-timing-raw.log"
$eventLines = @(
    $records | ForEach-Object { $_ | ConvertTo-Json -Depth 30 -Compress }
)
Write-Utf8NoBom -Path $eventsPath -Content (($eventLines -join "`n") + "`n")
Write-Utf8NoBom `
    -Path $podsPath `
    -Content ($podsText.Trim() + "`n")
Write-Utf8NoBom `
    -Path $logsPath `
    -Content (($rawLogs -join "`n") + "`n")

foreach ($path in @($eventsPath, $podsPath, $logsPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Timing evidence was not written: $path"
    }
}

& kubectl --context $targetContext `
    -n $namespace `
    delete daemonset $daemonSetName `
    --wait=true `
    --timeout=5m
if ($LASTEXITCODE -ne 0) {
    throw "Timing evidence was saved, but the observer DaemonSet could not be removed."
}

[pscustomobject]@{
    RunId = $RunId
    Stopped = $true
    ObserverPods = $pods.Count
    EventCount = $records.Count
    EventsPath = $eventsPath
    PodsPath = $podsPath
    RawLogsPath = $logsPath
}
