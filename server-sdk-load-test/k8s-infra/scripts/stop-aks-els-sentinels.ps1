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
$namespace = "featbit-loadtest"
$daemonSetName = "featbit-els-sentinel"
$configMapName = "featbit-els-sentinel-script"
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
    throw "The ELS sentinel DaemonSet does not exist."
}
$daemonSet = $daemonSetText | ConvertFrom-Json
$actualRunId = [string]$daemonSet.metadata.labels."loadtest.featbit.io/run-id"
if ($actualRunId -cne $RunId) {
    throw (
        "Refusing to stop sentinels for '$RunId'; the active DaemonSet belongs " +
        "to '$actualRunId'."
    )
}

$configMapText = (
    & kubectl --context $targetContext `
        -n $namespace `
        get configmap $configMapName `
        -o json |
        Out-String
)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($configMapText)) {
    throw "The ELS sentinel script ConfigMap does not exist."
}
$configMap = $configMapText | ConvertFrom-Json
$targets = @($configMap.data."targets.json" | ConvertFrom-Json)
$targetNames = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($target in $targets) {
    $null = $targetNames.Add([string]$target.pod)
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
    throw "Failed to inspect ELS sentinel Pods."
}
$pods = @(($podsText | ConvertFrom-Json).items)
if ($pods.Count -eq 0) {
    throw "No ELS sentinel Pods were found."
}

$readyRecords = [Collections.Generic.List[object]]::new()
$eventRecords = [Collections.Generic.List[object]]::new()
$rawLogs = [Collections.Generic.List[string]]::new()
$readyExpression = [regex]::new(
    "SENTINEL_READY\|1\|(?<run>[^|]+)\|(?<node>[^|]+)\|" +
    "(?<pod>[^|]+)\|(?<els>[^|]+)\|(?<ip>[^|]+)\|" +
    "(?<connection>\d+)\|(?<at>\d+)"
)
$eventExpression = [regex]::new(
    "SENTINEL_EVENT\|1\|(?<run>[^|]+)\|(?<node>[^|]+)\|" +
    "(?<pod>[^|]+)\|(?<els>[^|]+)\|(?<ip>[^|]+)\|" +
    "(?<connection>\d+)\|(?<revisionIndex>\d+)\|(?<revision>[^|]+)\|" +
    "(?<receivedAt>\d+)\|(?<updatedAt>\d+)"
)

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
        throw "Failed to collect ELS sentinel log from '$podName'."
    }

    foreach ($line in ($logText -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $rawLogs.Add("$podName`t$line")

        $readyMatch = $readyExpression.Match($line)
        if ($readyMatch.Success) {
            if (
                $readyMatch.Groups["run"].Value -cne $RunId -or
                $readyMatch.Groups["node"].Value -cne $nodeName -or
                $readyMatch.Groups["pod"].Value -cne $podName
            ) {
                throw "Sentinel '$podName' emitted an invalid READY identity."
            }
            if (-not $targetNames.Contains($readyMatch.Groups["els"].Value)) {
                throw "Sentinel '$podName' emitted an unknown ELS target."
            }
            $readyRecords.Add([ordered]@{
                schemaVersion = 1
                runId = $RunId
                sentinelPod = $podName
                loadgenNode = $nodeName
                elsPod = $readyMatch.Groups["els"].Value
                elsIp = $readyMatch.Groups["ip"].Value
                connectionIndex = [int]$readyMatch.Groups["connection"].Value
                readyAtUnixMs = [int64]$readyMatch.Groups["at"].Value
            })
            continue
        }

        $eventMatch = $eventExpression.Match($line)
        if (-not $eventMatch.Success) {
            continue
        }
        if (
            $eventMatch.Groups["run"].Value -cne $RunId -or
            $eventMatch.Groups["node"].Value -cne $nodeName -or
            $eventMatch.Groups["pod"].Value -cne $podName
        ) {
            throw "Sentinel '$podName' emitted an invalid EVENT identity."
        }
        if (-not $targetNames.Contains($eventMatch.Groups["els"].Value)) {
            throw "Sentinel '$podName' emitted an unknown ELS target."
        }
        $eventRecords.Add([ordered]@{
            schemaVersion = 1
            runId = $RunId
            sentinelPod = $podName
            loadgenNode = $nodeName
            elsPod = $eventMatch.Groups["els"].Value
            elsIp = $eventMatch.Groups["ip"].Value
            connectionIndex = [int]$eventMatch.Groups["connection"].Value
            revisionIndex = [int]$eventMatch.Groups["revisionIndex"].Value
            revision = $eventMatch.Groups["revision"].Value
            receivedAtUnixMs = [int64]$eventMatch.Groups["receivedAt"].Value
            updatedAtUnixMs = [int64]$eventMatch.Groups["updatedAt"].Value
        })
    }
}

if ($readyRecords.Count -eq 0 -or $eventRecords.Count -eq 0) {
    throw (
        "Sentinel evidence is empty. The DaemonSet is being preserved for " +
        "diagnosis."
    )
}

$eventsPath = Join-Path $resultsDirectory "$RunId-sentinel-events.jsonl"
$readyPath = Join-Path $resultsDirectory "$RunId-sentinel-ready.jsonl"
$podsPath = Join-Path $resultsDirectory "$RunId-sentinel-pods.json"
$targetsPath = Join-Path $resultsDirectory "$RunId-sentinel-targets.json"
$logsPath = Join-Path $resultsDirectory "$RunId-sentinel-raw.log"

$eventLines = @(
    $eventRecords | ForEach-Object {
        $_ | ConvertTo-Json -Depth 20 -Compress
    }
)
$readyLines = @(
    $readyRecords | ForEach-Object {
        $_ | ConvertTo-Json -Depth 20 -Compress
    }
)
Write-Utf8NoBom -Path $eventsPath -Content (($eventLines -join "`n") + "`n")
Write-Utf8NoBom -Path $readyPath -Content (($readyLines -join "`n") + "`n")
Write-Utf8NoBom -Path $podsPath -Content ($podsText.Trim() + "`n")
Write-Utf8NoBom `
    -Path $targetsPath `
    -Content (($targets | ConvertTo-Json -Depth 20) + "`n")
Write-Utf8NoBom -Path $logsPath -Content (($rawLogs -join "`n") + "`n")

foreach ($path in @(
    $eventsPath,
    $readyPath,
    $podsPath,
    $targetsPath,
    $logsPath
)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Sentinel evidence was not written: $path"
    }
}

& kubectl --context $targetContext `
    -n $namespace `
    delete daemonset $daemonSetName `
    --wait=true `
    --timeout=5m
if ($LASTEXITCODE -ne 0) {
    throw "Sentinel evidence was saved, but the DaemonSet could not be removed."
}
& kubectl --context $targetContext `
    -n $namespace `
    delete configmap $configMapName `
    --wait=true `
    --timeout=2m
if ($LASTEXITCODE -ne 0) {
    throw "Sentinel evidence was saved, but the ConfigMap could not be removed."
}

[pscustomobject]@{
    RunId = $RunId
    Stopped = $true
    SentinelPods = $pods.Count
    ElsTargets = $targets.Count
    ReadyRecords = $readyRecords.Count
    EventRecords = $eventRecords.Count
    EventsPath = $eventsPath
    ReadyPath = $readyPath
    PodsPath = $podsPath
    TargetsPath = $targetsPath
    RawLogsPath = $logsPath
}
