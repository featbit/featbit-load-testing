[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [string] $RunId,

    [string] $ResultsDirectory = ""
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
        p95 = Get-Percentile -Values $numbers -Percentile 0.95
        p99 = Get-Percentile -Values $numbers -Percentile 0.99
        maximum = [double](($numbers | Measure-Object -Maximum).Maximum)
        mean = [double](($numbers | Measure-Object -Average).Average)
    }
}

function Get-CounterDelta {
    param(
        [Parameter(Mandatory)][double] $Current,
        [Parameter(Mandatory)][double] $Previous
    )

    $delta = $Current - $Previous
    if ($delta -lt 0) {
        return $null
    }
    return [double]$delta
}

function Get-RowNumber {
    param(
        [Parameter(Mandatory)][object] $Row,
        [Parameter(Mandatory)][string] $Property
    )

    $value = $Row.PSObject.Properties[$Property]
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value.Value)) {
        return 0.0
    }
    return [double]$value.Value
}

function Get-Sum {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Values
    )

    $numbers = @($Values | Where-Object { $null -ne $_ })
    if ($numbers.Count -eq 0) {
        return 0.0
    }
    return [double](($numbers | Measure-Object -Sum).Sum)
}

function Get-Maximum {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Values
    )

    $numbers = @($Values | Where-Object { $null -ne $_ })
    if ($numbers.Count -eq 0) {
        return $null
    }
    return [double](($numbers | Measure-Object -Maximum).Maximum)
}

function Get-Correlation {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Rows,

        [Parameter(Mandatory)]
        [string] $XProperty,

        [Parameter(Mandatory)]
        [string] $YProperty
    )

    $pairs = @(
        $Rows |
            Where-Object {
                $null -ne $_.$XProperty -and $null -ne $_.$YProperty
            } |
            ForEach-Object {
                [pscustomobject]@{
                    x = [double]$_.$XProperty
                    y = [double]$_.$YProperty
                }
            }
    )
    if ($pairs.Count -lt 3) {
        return $null
    }

    $meanX = [double](($pairs.x | Measure-Object -Average).Average)
    $meanY = [double](($pairs.y | Measure-Object -Average).Average)
    $numerator = 0.0
    $sumX = 0.0
    $sumY = 0.0
    foreach ($pair in $pairs) {
        $deltaX = $pair.x - $meanX
        $deltaY = $pair.y - $meanY
        $numerator += $deltaX * $deltaY
        $sumX += $deltaX * $deltaX
        $sumY += $deltaY * $deltaY
    }
    if ($sumX -eq 0 -or $sumY -eq 0) {
        return $null
    }
    return [double]($numerator / [Math]::Sqrt($sumX * $sumY))
}

function Get-PoolSummary {
    param(
        [Parameter(Mandatory)]
        [object[]] $Records,

        [Parameter(Mandatory)]
        [string] $Pool
    )

    $poolRecords = @($Records | Where-Object nodePool -eq $Pool)
    if ($poolRecords.Count -eq 0) {
        throw "No one-second evidence records were found for pool '$Pool'."
    }

    return [ordered]@{
        nodeCount = @($poolRecords.node | Sort-Object -Unique).Count
        intervalSeconds = Get-Statistics -Values @($poolRecords.intervalSeconds)
        cpuPercent = Get-Statistics -Values @($poolRecords.cpuPercent)
        stealPercent = Get-Statistics -Values @($poolRecords.stealPercent)
        softirqCpuPercent = Get-Statistics -Values @(
            $poolRecords.softirqCpuPercent
        )
        cpuPressurePercent = Get-Statistics -Values @(
            $poolRecords.cpuPressurePercent
        )
        memoryPressurePercent = Get-Statistics -Values @(
            $poolRecords.memoryPressurePercent
        )
        ioPressurePercent = Get-Statistics -Values @(
            $poolRecords.ioPressurePercent
        )
        procsRunning = Get-Statistics -Values @($poolRecords.procsRunning)
        runQueue = Get-Statistics -Values @($poolRecords.runQueue)
        load1m = Get-Statistics -Values @($poolRecords.load1m)
        netRxSoftirqPerSecond = Get-Statistics -Values @(
            $poolRecords.netRxSoftirqPerSecond
        )
        tcpRetransSegments = [int64](Get-Sum -Values @(
            $poolRecords.tcpRetransSegments
        ))
        tcpInErrors = [int64](Get-Sum -Values @($poolRecords.tcpInErrors))
        listenDrops = [int64](Get-Sum -Values @($poolRecords.listenDrops))
        backlogDrops = [int64](Get-Sum -Values @($poolRecords.backlogDrops))
        receiveQueueDrops = [int64](Get-Sum -Values @(
            $poolRecords.receiveQueueDrops
        ))
        eth0RxErrors = [int64](Get-Sum -Values @($poolRecords.eth0RxErrors))
        eth0RxDrops = [int64](Get-Sum -Values @($poolRecords.eth0RxDrops))
        eth0TxErrors = [int64](Get-Sum -Values @($poolRecords.eth0TxErrors))
        eth0TxDrops = [int64](Get-Sum -Values @($poolRecords.eth0TxDrops))
        ciliumRxErrors = [int64](Get-Sum -Values @(
            $poolRecords.ciliumRxErrors
        ))
        ciliumRxDrops = [int64](Get-Sum -Values @($poolRecords.ciliumRxDrops))
        ciliumTxErrors = [int64](Get-Sum -Values @(
            $poolRecords.ciliumTxErrors
        ))
        ciliumTxDrops = [int64](Get-Sum -Values @($poolRecords.ciliumTxDrops))
    }
}

function Get-EventWindowSummary {
    param(
        [Parameter(Mandatory)]
        [object[]] $Records,

        [Parameter(Mandatory)]
        [DateTimeOffset] $EventTime,

        [string] $Node = "",

        [string] $Pool = ""
    )

    $windowStart = $EventTime.AddSeconds(-1)
    $windowEnd = $EventTime.AddSeconds(2.25)
    $window = @(
        $Records |
            Where-Object {
                $_.observedAt -ge $windowStart -and
                $_.observedAt -le $windowEnd -and
                (
                    [string]::IsNullOrWhiteSpace($Node) -or
                    $_.node -eq $Node
                ) -and
                (
                    [string]::IsNullOrWhiteSpace($Pool) -or
                    $_.nodePool -eq $Pool
                )
            }
    )

    return [ordered]@{
        sampleCount = $window.Count
        cpuMaximumPercent = Get-Maximum -Values @($window.cpuPercent)
        stealMaximumPercent = Get-Maximum -Values @($window.stealPercent)
        cpuPressureMaximumPercent = Get-Maximum -Values @(
            $window.cpuPressurePercent
        )
        runQueueMaximum = Get-Maximum -Values @($window.runQueue)
        netRxSoftirqMaximumPerSecond = Get-Maximum -Values @(
            $window.netRxSoftirqPerSecond
        )
        tcpRetransSegments = [int64](Get-Sum -Values @(
            $window.tcpRetransSegments
        ))
        packetDrops = [int64](Get-Sum -Values @(
            $window.eth0RxDrops
            $window.eth0TxDrops
            $window.ciliumRxDrops
            $window.ciliumTxDrops
        ))
        elsCpuMaximumMillicores = Get-Maximum -Values @(
            $window.elsCpuMillicores
        )
        elsThrottledPeriods = [int64](Get-Sum -Values @(
            $window.elsThrottledPeriods
        ))
        elsCpuPeriods = [int64](Get-Sum -Values @($window.elsCpuPeriods))
        elsThrottledMilliseconds = (
            Get-Sum -Values @($window.elsThrottledMicroseconds)
        ) / 1000.0
        elsCpuPressureMaximumPercent = Get-Maximum -Values @(
            $window.elsCpuPressurePercent
        )
    }
}

function Format-Number {
    param(
        [AllowNull()][object] $Value,
        [string] $Suffix = ""
    )

    if ($null -eq $Value) {
        return "n/a"
    }
    return ("{0:N2}{1}" -f [double]$Value, $Suffix)
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

$nodeFiles = @(
    Get-ChildItem `
        -LiteralPath $archiveDirectory `
        -File `
        -Filter "$RunId-node-*-1s.tsv" |
        Sort-Object Name
)
if ($nodeFiles.Count -eq 0) {
    throw "No one-second node evidence files exist for '$RunId'."
}

$intervalRecords = [Collections.Generic.List[object]]::new()
$metadataRecords = [Collections.Generic.List[object]]::new()
foreach ($nodeFile in $nodeFiles) {
    $nodeMatch = [regex]::Match(
        $nodeFile.Name,
        "^$([regex]::Escape($RunId))-node-(?<node>.+)-1s\.tsv$"
    )
    if (-not $nodeMatch.Success) {
        throw "Could not parse node name from '$($nodeFile.Name)'."
    }
    $node = $nodeMatch.Groups["node"].Value
    $nodePool = if ($node -match "^aks-loadgen-") {
        "loadgen"
    }
    elseif ($node -match "^aks-featbit-") {
        "featbit"
    }
    else {
        "other"
    }

    $metadataPath = Join-Path `
        $archiveDirectory `
        "$RunId-node-$node-metadata.txt"
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Node '$node' is missing its evidence metadata."
    }
    $metadata = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $metadataPath) {
        $parts = $line -split "=", 2
        if ($parts.Count -eq 2) {
            $metadata[$parts[0]] = $parts[1]
        }
    }
    if ([string]$metadata.target_sample_interval_seconds -ne "1") {
        throw "Node '$node' did not target a one-second sample interval."
    }
    $metadataElsPod = if ($metadata.Contains("els_pod")) {
        [string]$metadata.els_pod
    }
    else {
        ""
    }
    $metadataElsPodCount = if ($metadata.Contains("els_pod_count")) {
        [int]$metadata.els_pod_count
    }
    elseif ([string]::IsNullOrWhiteSpace($metadataElsPod)) {
        0
    }
    else {
        @($metadataElsPod -split "," | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }).Count
    }
    if (
        $nodePool -eq "featbit" -and
        $metadataElsPodCount -gt 0 -and
        [string]::IsNullOrWhiteSpace([string]$metadata.els_container_cgroup)
    ) {
        throw "FeatBit node '$node' is missing the ELS host-cgroup mapping."
    }
    $metadataRecords.Add([ordered]@{
        node = $node
        nodePool = $nodePool
        elsPod = $metadataElsPod
        elsPodCount = $metadataElsPodCount
        elsMappingMode = if ($metadata.Contains("els_mapping_mode")) {
            [string]$metadata.els_mapping_mode
        } else { "legacy-first-pod-on-node" }
        elsContainerId = if ($metadata.Contains("els_container_id")) {
            [string]$metadata.els_container_id
        } else { "" }
        elsContainerCgroup = if ($metadata.Contains("els_container_cgroup")) {
            [string]$metadata.els_container_cgroup
        } else { "" }
        elsCpuLimitCgroup = if (
            $metadata.Contains("els_cpu_limit_cgroup")
        ) {
            [string]$metadata.els_cpu_limit_cgroup
        } else { "" }
        elsCpuMax = if ($metadata.Contains("els_cpu_max")) {
            [string]$metadata.els_cpu_max
        } else { "" }
    })

    $rows = @(Import-Csv -LiteralPath $nodeFile.FullName -Delimiter "`t")
    if ($rows.Count -lt 2) {
        throw "Node evidence '$($nodeFile.Name)' has fewer than two samples."
    }
    for ($index = 1; $index -lt $rows.Count; $index += 1) {
        $previous = $rows[$index - 1]
        $current = $rows[$index]
        $interval = (
            Get-RowNumber -Row $current -Property "uptime_seconds"
        ) - (
            Get-RowNumber -Row $previous -Property "uptime_seconds"
        )
        if ($interval -le 0) {
            continue
        }

        $cpuProperties = @(
            "cpu_user",
            "cpu_nice",
            "cpu_system",
            "cpu_idle",
            "cpu_iowait",
            "cpu_irq",
            "cpu_softirq",
            "cpu_steal"
        )
        $cpuDeltas = [ordered]@{}
        foreach ($property in $cpuProperties) {
            $cpuDeltas[$property] = Get-CounterDelta `
                -Current (Get-RowNumber -Row $current -Property $property) `
                -Previous (Get-RowNumber -Row $previous -Property $property)
        }
        $cpuTotal = Get-Sum -Values @($cpuDeltas.Values)
        $cpuIdle = (
            [double]$cpuDeltas.cpu_idle +
            [double]$cpuDeltas.cpu_iowait
        )
        $cpuPercent = if ($cpuTotal -eq 0) {
            $null
        }
        else {
            ($cpuTotal - $cpuIdle) / $cpuTotal * 100.0
        }
        $stealPercent = if ($cpuTotal -eq 0) {
            $null
        }
        else {
            [double]$cpuDeltas.cpu_steal / $cpuTotal * 100.0
        }
        $softirqCpuPercent = if ($cpuTotal -eq 0) {
            $null
        }
        else {
            [double]$cpuDeltas.cpu_softirq / $cpuTotal * 100.0
        }

        $pressure = [ordered]@{}
        foreach ($property in @(
            "cpu_pressure_some_usec",
            "memory_pressure_some_usec",
            "io_pressure_some_usec"
        )) {
            $pressure[$property] = (
                Get-CounterDelta `
                    -Current (
                        Get-RowNumber -Row $current -Property $property
                    ) `
                    -Previous (
                        Get-RowNumber -Row $previous -Property $property
                    )
            ) / $interval / 1000000.0 * 100.0
        }

        $counterProperties = @(
            "eth0_rx_errors",
            "eth0_rx_drops",
            "eth0_tx_errors",
            "eth0_tx_drops",
            "cilium_rx_errors",
            "cilium_rx_drops",
            "cilium_tx_errors",
            "cilium_tx_drops",
            "tcp_retrans_segs",
            "tcp_in_errors",
            "tcp_ext_listen_drops",
            "tcp_ext_backlog_drops",
            "tcp_ext_rcv_queue_drops"
        )
        $counterDeltas = [ordered]@{}
        foreach ($property in $counterProperties) {
            $counterDeltas[$property] = Get-CounterDelta `
                -Current (Get-RowNumber -Row $current -Property $property) `
                -Previous (Get-RowNumber -Row $previous -Property $property)
        }

        $netRxSoftirq = (
            Get-CounterDelta `
                -Current (
                    Get-RowNumber -Row $current -Property "softirq_net_rx"
                ) `
                -Previous (
                    Get-RowNumber -Row $previous -Property "softirq_net_rx"
                )
        ) / $interval

        $elsUsageCurrent = Get-RowNumber `
            -Row $current `
            -Property "els_cpu_usage_usec"
        $elsUsagePrevious = Get-RowNumber `
            -Row $previous `
            -Property "els_cpu_usage_usec"
        $elsCpuMillicores = if (
            $elsUsageCurrent -lt 0 -or $elsUsagePrevious -lt 0
        ) {
            $null
        }
        else {
            (
                Get-CounterDelta `
                    -Current $elsUsageCurrent `
                    -Previous $elsUsagePrevious
            ) / $interval / 1000.0
        }

        $elsPeriodsCurrent = Get-RowNumber `
            -Row $current `
            -Property "els_cpu_periods"
        $elsPeriodsPrevious = Get-RowNumber `
            -Row $previous `
            -Property "els_cpu_periods"
        $elsCpuPeriods = if (
            $elsPeriodsCurrent -lt 0 -or $elsPeriodsPrevious -lt 0
        ) {
            $null
        }
        else {
            Get-CounterDelta `
                -Current $elsPeriodsCurrent `
                -Previous $elsPeriodsPrevious
        }

        $elsThrottledCurrent = Get-RowNumber `
            -Row $current `
            -Property "els_cpu_throttled_periods"
        $elsThrottledPrevious = Get-RowNumber `
            -Row $previous `
            -Property "els_cpu_throttled_periods"
        $elsThrottledPeriods = if (
            $elsThrottledCurrent -lt 0 -or $elsThrottledPrevious -lt 0
        ) {
            $null
        }
        else {
            Get-CounterDelta `
                -Current $elsThrottledCurrent `
                -Previous $elsThrottledPrevious
        }

        $elsThrottledUsecCurrent = Get-RowNumber `
            -Row $current `
            -Property "els_cpu_throttled_usec"
        $elsThrottledUsecPrevious = Get-RowNumber `
            -Row $previous `
            -Property "els_cpu_throttled_usec"
        $elsThrottledMicroseconds = if (
            $elsThrottledUsecCurrent -lt 0 -or
            $elsThrottledUsecPrevious -lt 0
        ) {
            $null
        }
        else {
            Get-CounterDelta `
                -Current $elsThrottledUsecCurrent `
                -Previous $elsThrottledUsecPrevious
        }

        $elsPressureCurrent = Get-RowNumber `
            -Row $current `
            -Property "els_cpu_pressure_some_usec"
        $elsPressurePrevious = Get-RowNumber `
            -Row $previous `
            -Property "els_cpu_pressure_some_usec"
        $elsCpuPressurePercent = if (
            $elsPressureCurrent -lt 0 -or $elsPressurePrevious -lt 0
        ) {
            $null
        }
        else {
            (
                Get-CounterDelta `
                    -Current $elsPressureCurrent `
                    -Previous $elsPressurePrevious
            ) / $interval / 1000000.0 * 100.0
        }

        $intervalRecords.Add([pscustomobject]@{
            observedAt = [DateTimeOffset]::Parse(
                [string]$current.observed_at_utc
            )
            node = $node
            nodePool = $nodePool
            elsPod = [string]$current.els_pod
            intervalSeconds = $interval
            cpuPercent = $cpuPercent
            stealPercent = $stealPercent
            softirqCpuPercent = $softirqCpuPercent
            procsRunning = Get-RowNumber `
                -Row $current `
                -Property "procs_running"
            runQueue = Get-RowNumber -Row $current -Property "run_queue"
            load1m = Get-RowNumber -Row $current -Property "load_1m"
            cpuPressurePercent = $pressure.cpu_pressure_some_usec
            memoryPressurePercent = $pressure.memory_pressure_some_usec
            ioPressurePercent = $pressure.io_pressure_some_usec
            netRxSoftirqPerSecond = $netRxSoftirq
            eth0RxErrors = $counterDeltas.eth0_rx_errors
            eth0RxDrops = $counterDeltas.eth0_rx_drops
            eth0TxErrors = $counterDeltas.eth0_tx_errors
            eth0TxDrops = $counterDeltas.eth0_tx_drops
            ciliumRxErrors = $counterDeltas.cilium_rx_errors
            ciliumRxDrops = $counterDeltas.cilium_rx_drops
            ciliumTxErrors = $counterDeltas.cilium_tx_errors
            ciliumTxDrops = $counterDeltas.cilium_tx_drops
            tcpRetransSegments = $counterDeltas.tcp_retrans_segs
            tcpInErrors = $counterDeltas.tcp_in_errors
            listenDrops = $counterDeltas.tcp_ext_listen_drops
            backlogDrops = $counterDeltas.tcp_ext_backlog_drops
            receiveQueueDrops = $counterDeltas.tcp_ext_rcv_queue_drops
            elsCpuMillicores = $elsCpuMillicores
            elsCpuPeriods = $elsCpuPeriods
            elsThrottledPeriods = $elsThrottledPeriods
            elsThrottledMicroseconds = $elsThrottledMicroseconds
            elsCpuPressurePercent = $elsCpuPressurePercent
        })
    }
}

$records = @($intervalRecords)
$loadgenSummary = Get-PoolSummary -Records $records -Pool "loadgen"
$featbitSummary = Get-PoolSummary -Records $records -Pool "featbit"
$elsRecords = @($records | Where-Object {
    $_.nodePool -eq "featbit" -and -not [string]::IsNullOrWhiteSpace($_.elsPod)
})
$elsPeriods = Get-Sum -Values @($elsRecords.elsCpuPeriods)
$elsThrottledPeriods = Get-Sum -Values @($elsRecords.elsThrottledPeriods)
$elsSummary = [ordered]@{
    podCount = [int](Get-Sum -Values @(
        $metadataRecords |
            Where-Object elsPodCount -gt 0 |
            ForEach-Object elsPodCount
    ))
    mappingModes = @(
        $metadataRecords |
            Where-Object elsPodCount -gt 0 |
            ForEach-Object elsMappingMode |
            Sort-Object -Unique
    )
    cpuMillicores = Get-Statistics -Values @($elsRecords.elsCpuMillicores)
    cpuPressurePercent = Get-Statistics -Values @(
        $elsRecords.elsCpuPressurePercent
    )
    cpuPeriods = [int64]$elsPeriods
    throttledPeriods = [int64]$elsThrottledPeriods
    throttledPeriodRate = if ($elsPeriods -eq 0) {
        0.0
    }
    else {
        [double]($elsThrottledPeriods / $elsPeriods)
    }
    intervalsWithThrottling = @(
        $elsRecords | Where-Object elsThrottledPeriods -gt 0
    ).Count
    intervalCount = $elsRecords.Count
    throttledMilliseconds = (
        Get-Sum -Values @($elsRecords.elsThrottledMicroseconds)
    ) / 1000.0
}

$podsPath = Join-Path $archiveDirectory "pods-cluster.json"
if (-not (Test-Path -LiteralPath $podsPath -PathType Leaf)) {
    throw "The archived Pod snapshot is missing: $podsPath"
}
$testRunName = "featbit-$RunId"
$runnerNodes = @{}
foreach ($pod in @(
    (Get-Content -Raw -LiteralPath $podsPath | ConvertFrom-Json).items
)) {
    if (
        [string]$pod.metadata.name -match
        "^$([regex]::Escape($testRunName))-(?<runner>\d+)-[a-z0-9]+$"
    ) {
        $runnerNodes[[int]$Matches.runner] = [string]$pod.spec.nodeName
    }
}

$controllerLog = @(
    Get-ChildItem `
        -LiteralPath $archiveDirectory `
        -File `
        -Filter "$testRunName-1.log"
)[0]
if ($null -eq $controllerLog) {
    throw "Runner 1 controller log is missing for '$RunId'."
}
$events = [ordered]@{}
foreach ($line in Get-Content -LiteralPath $controllerLog.FullName) {
    $match = [regex]::Match(
        $line,
        '^time="(?<time>[^"]+)".+\[controller\] applying ' +
        'rev-(?<revision>\d+) to '
    )
    if ($match.Success) {
        $revisionKey = [string]([int]$match.Groups["revision"].Value)
        $events[$revisionKey] = [DateTimeOffset]::Parse(
            $match.Groups["time"].Value
        )
    }
}
if ($events.Count -eq 0) {
    throw "No controller revision timestamps were found in '$($controllerLog.Name)'."
}

$recordsByNode = @{}
foreach ($nodeGroup in $records | Group-Object node) {
    $recordsByNode[[string]$nodeGroup.Name] = @($nodeGroup.Group)
}
$featbitRecords = @($records | Where-Object nodePool -eq "featbit")
$eventNodeWindows = @{}
$eventElsWindows = @{}
foreach ($event in $events.GetEnumerator()) {
    $revision = [int]$event.Key
    $eventElsWindows[[string]$revision] = Get-EventWindowSummary `
        -Records $featbitRecords `
        -EventTime $event.Value
    foreach ($node in @($runnerNodes.Values | Sort-Object -Unique)) {
        if (-not $recordsByNode.ContainsKey([string]$node)) {
            throw "Runner node '$node' has no one-second evidence."
        }
        $eventNodeWindows["$revision|$node"] = Get-EventWindowSummary `
            -Records $recordsByNode[[string]$node] `
            -EventTime $event.Value
    }
}

$cohorts = [Collections.Generic.List[object]]::new()
$summaryPattern = (
    "^$([regex]::Escape($testRunName))-" +
    "(?<runner>\d+)-[a-z0-9]+-summary\.json$"
)
$latencyMetricBaseName = $null
foreach ($summaryPath in [IO.Directory]::GetFiles(
    $archiveDirectory,
    "*-summary.json"
)) {
    $match = [regex]::Match([IO.Path]::GetFileName($summaryPath), $summaryPattern)
    if (-not $match.Success) {
        continue
    }
    $runner = [int]$match.Groups["runner"].Value
    $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
    foreach ($event in $events.GetEnumerator()) {
        $metricCandidates = @(
            "probe_sync_latency_ms{revision_index:$($event.Key)}",
            (
                "probe_updated_at_to_sdk_latency_ms" +
                "{revision_index:$($event.Key)}"
            )
        )
        $metricName = $null
        $metric = $null
        foreach ($candidate in $metricCandidates) {
            $candidateMetric = $summary.metrics.PSObject.Properties[$candidate]
            if ($null -ne $candidateMetric) {
                $metricName = $candidate
                $metric = $candidateMetric
                break
            }
        }
        if ($null -eq $metric) {
            throw (
                "Runner $runner is missing all supported per-revision " +
                "latency metrics: $($metricCandidates -join ', ')."
            )
        }
        $currentMetricBaseName = $metricName.Split("{")[0]
        if ($null -eq $latencyMetricBaseName) {
            $latencyMetricBaseName = $currentMetricBaseName
        } elseif ($latencyMetricBaseName -cne $currentMetricBaseName) {
            throw (
                "Runner summaries mix latency contracts: " +
                "'$latencyMetricBaseName' and '$currentMetricBaseName'."
            )
        }
        $node = [string]$runnerNodes[$runner]
        $nodeWindow = $eventNodeWindows["$($event.Key)|$node"]
        $elsWindow = $eventElsWindows[[string]$event.Key]
        $cohorts.Add([pscustomobject]@{
            runner = $runner
            node = $node
            revision = [int]$event.Key
            eventTimeUtc = $event.Value.ToString("o")
            averageMs = [double]$metric.Value.avg
            p95Ms = [double]$metric.Value.'p(95)'
            p99Ms = [double]$metric.Value.'p(99)'
            maximumMs = [double]$metric.Value.max
            loadgenCpuMaximumPercent = $nodeWindow.cpuMaximumPercent
            loadgenStealMaximumPercent = $nodeWindow.stealMaximumPercent
            loadgenCpuPressureMaximumPercent = (
                $nodeWindow.cpuPressureMaximumPercent
            )
            loadgenRunQueueMaximum = $nodeWindow.runQueueMaximum
            loadgenNetRxSoftirqMaximumPerSecond = (
                $nodeWindow.netRxSoftirqMaximumPerSecond
            )
            loadgenTcpRetransSegments = $nodeWindow.tcpRetransSegments
            loadgenPacketDrops = $nodeWindow.packetDrops
            elsCpuMaximumMillicores = $elsWindow.elsCpuMaximumMillicores
            elsThrottledPeriods = $elsWindow.elsThrottledPeriods
            elsCpuPeriods = $elsWindow.elsCpuPeriods
            elsThrottledMilliseconds = $elsWindow.elsThrottledMilliseconds
            elsCpuPressureMaximumPercent = (
                $elsWindow.elsCpuPressureMaximumPercent
            )
            featbitNodeCpuMaximumPercent = $elsWindow.cpuMaximumPercent
            featbitNodeRunQueueMaximum = $elsWindow.runQueueMaximum
            featbitTcpRetransSegments = $elsWindow.tcpRetransSegments
            featbitPacketDrops = $elsWindow.packetDrops
        })
    }
}

$correlations = [ordered]@{}
foreach ($property in @(
    "loadgenCpuMaximumPercent",
    "loadgenStealMaximumPercent",
    "loadgenCpuPressureMaximumPercent",
    "loadgenRunQueueMaximum",
    "loadgenNetRxSoftirqMaximumPerSecond",
    "loadgenTcpRetransSegments",
    "elsCpuMaximumMillicores",
    "elsThrottledPeriods",
    "elsCpuPressureMaximumPercent",
    "featbitNodeCpuMaximumPercent",
    "featbitNodeRunQueueMaximum"
)) {
    $correlations[$property] = Get-Correlation `
        -Rows @($cohorts) `
        -XProperty $property `
        -YProperty "p99Ms"
}

$revisionRecords = @(
    foreach ($event in $events.GetEnumerator() | Sort-Object {
        [int]$_.Key
    }) {
        $revisionCohorts = @(
            $cohorts | Where-Object {
                $_.revision -eq [int]$event.Key
            }
        )
        $elsWindow = $eventElsWindows[[string]$event.Key]
        [ordered]@{
            revision = [int]$event.Key
            eventTimeUtc = $event.Value.ToString("o")
            weightedAverageMs = [double]((
                $revisionCohorts.averageMs |
                    Measure-Object -Average
            ).Average)
            runnerP95MaximumMs = Get-Maximum -Values @(
                $revisionCohorts.p95Ms
            )
            runnerP99MaximumMs = Get-Maximum -Values @(
                $revisionCohorts.p99Ms
            )
            maximumMs = Get-Maximum -Values @($revisionCohorts.maximumMs)
            loadgenCpuMaximumPercent = Get-Maximum -Values @(
                $revisionCohorts.loadgenCpuMaximumPercent
            )
            loadgenCpuPressureMaximumPercent = Get-Maximum -Values @(
                $revisionCohorts.loadgenCpuPressureMaximumPercent
            )
            loadgenRunQueueMaximum = Get-Maximum -Values @(
                $revisionCohorts.loadgenRunQueueMaximum
            )
            loadgenTcpRetransSegments = [int64](Get-Sum -Values @(
                $revisionCohorts |
                    Group-Object node |
                    ForEach-Object {
                        $_.Group[0].loadgenTcpRetransSegments
                    }
            ))
            loadgenPacketDrops = [int64](Get-Sum -Values @(
                $revisionCohorts |
                    Group-Object node |
                    ForEach-Object { $_.Group[0].loadgenPacketDrops }
            ))
            featbitNodeCpuMaximumPercent = $elsWindow.cpuMaximumPercent
            featbitNodeRunQueueMaximum = $elsWindow.runQueueMaximum
            elsCpuMaximumMillicores = $elsWindow.elsCpuMaximumMillicores
            elsThrottledPeriods = $elsWindow.elsThrottledPeriods
            elsCpuPeriods = $elsWindow.elsCpuPeriods
            elsThrottledMilliseconds = $elsWindow.elsThrottledMilliseconds
            elsCpuPressureMaximumPercent = (
                $elsWindow.elsCpuPressureMaximumPercent
            )
            featbitTcpRetransSegments = $elsWindow.tcpRetransSegments
            featbitPacketDrops = $elsWindow.packetDrops
        }
    }
)

$resourceSamplesPath = Join-Path `
    $archiveDirectory `
    "$RunId-resource-samples.jsonl"
$kubernetesPeaks = $null
if (Test-Path -LiteralPath $resourceSamplesPath -PathType Leaf) {
    $samples = @(
        Get-Content -LiteralPath $resourceSamplesPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    $samplePeaks = @(
        foreach ($sample in $samples) {
            $elsContainers = @($sample.containers | Where-Object {
                $_.namespace -eq "featbit" -and
                $_.container -eq "featbit-els"
            })
            $runners = @($sample.containers | Where-Object {
                $_.namespace -eq "featbit-loadtest" -and
                $_.container -eq "k6"
            })
            $sentinels = @($sample.containers | Where-Object {
                $_.namespace -eq "featbit-loadtest" -and
                $_.container -eq "sentinel"
            })
            $apiContainers = @($sample.containers | Where-Object {
                $_.namespace -eq "featbit" -and
                $_.container -eq "featbit-api"
            })
            $postgresqlContainers = @($sample.containers | Where-Object {
                $_.namespace -eq "featbit" -and
                $_.container -eq "postgresql"
            })
            $redisContainers = @($sample.containers | Where-Object {
                $_.namespace -eq "featbit" -and
                $_.container -eq "redis"
            })
            [pscustomobject]@{
                elsCpu = Get-Sum -Values @(
                    $elsContainers |
                        ForEach-Object { $_.cpuMillicores }
                )
                elsMemory = (
                    Get-Sum -Values @(
                        $elsContainers |
                            ForEach-Object { $_.memoryBytes }
                    )
                ) / 1MB
                runnerCpu = Get-Sum -Values @(
                    $runners |
                        ForEach-Object { $_.cpuMillicores }
                )
                runnerMemory = (
                    Get-Sum -Values @(
                        $runners |
                            ForEach-Object { $_.memoryBytes }
                    )
                ) / 1MB
                sentinelCpu = Get-Sum -Values @(
                    $sentinels |
                        ForEach-Object { $_.cpuMillicores }
                )
                sentinelMemory = (
                    Get-Sum -Values @(
                        $sentinels |
                            ForEach-Object { $_.memoryBytes }
                    )
                ) / 1MB
                apiCpu = Get-Sum -Values @(
                    $apiContainers |
                        ForEach-Object { $_.cpuMillicores }
                )
                apiMemory = (
                    Get-Sum -Values @(
                        $apiContainers |
                            ForEach-Object { $_.memoryBytes }
                    )
                ) / 1MB
                postgresqlCpu = Get-Sum -Values @(
                    $postgresqlContainers |
                        ForEach-Object { $_.cpuMillicores }
                )
                postgresqlMemory = (
                    Get-Sum -Values @(
                        $postgresqlContainers |
                            ForEach-Object { $_.memoryBytes }
                    )
                ) / 1MB
                redisCpu = Get-Sum -Values @(
                    $redisContainers |
                        ForEach-Object { $_.cpuMillicores }
                )
                redisMemory = (
                    Get-Sum -Values @(
                        $redisContainers |
                            ForEach-Object { $_.memoryBytes }
                    )
                ) / 1MB
                featbitNodeCpu = Get-Sum -Values @(
                    $sample.nodes |
                        Where-Object nodePool -eq "featbit" |
                        ForEach-Object { $_.cpuMillicores }
                )
                featbitNodeMemory = (
                    Get-Sum -Values @(
                        $sample.nodes |
                            Where-Object nodePool -eq "featbit" |
                            ForEach-Object { $_.memoryBytes }
                    )
                ) / 1MB
                loadgenNodeCpu = Get-Sum -Values @(
                    $sample.nodes |
                        Where-Object nodePool -eq "loadgen" |
                        ForEach-Object { $_.cpuMillicores }
                )
                loadgenNodeMemory = (
                    Get-Sum -Values @(
                        $sample.nodes |
                            Where-Object nodePool -eq "loadgen" |
                            ForEach-Object { $_.memoryBytes }
                    )
                ) / 1MB
            }
        }
    )
    $kubernetesPeaks = [ordered]@{
        sampleCount = $samples.Count
        elsCpuMillicores = Get-Maximum -Values @($samplePeaks.elsCpu)
        elsMemoryMiB = Get-Maximum -Values @($samplePeaks.elsMemory)
        runnerCpuMillicores = Get-Maximum -Values @($samplePeaks.runnerCpu)
        runnerMemoryMiB = Get-Maximum -Values @($samplePeaks.runnerMemory)
        sentinelCpuMillicores = Get-Maximum -Values @(
            $samplePeaks.sentinelCpu
        )
        sentinelMemoryMiB = Get-Maximum -Values @(
            $samplePeaks.sentinelMemory
        )
        apiCpuMillicores = Get-Maximum -Values @($samplePeaks.apiCpu)
        apiMemoryMiB = Get-Maximum -Values @($samplePeaks.apiMemory)
        postgresqlCpuMillicores = Get-Maximum -Values @(
            $samplePeaks.postgresqlCpu
        )
        postgresqlMemoryMiB = Get-Maximum -Values @(
            $samplePeaks.postgresqlMemory
        )
        redisCpuMillicores = Get-Maximum -Values @($samplePeaks.redisCpu)
        redisMemoryMiB = Get-Maximum -Values @(
            $samplePeaks.redisMemory
        )
        featbitNodeCpuMillicores = Get-Maximum -Values @(
            $samplePeaks.featbitNodeCpu
        )
        featbitNodeMemoryMiB = Get-Maximum -Values @(
            $samplePeaks.featbitNodeMemory
        )
        loadgenNodeCpuMillicores = Get-Maximum -Values @(
            $samplePeaks.loadgenNodeCpu
        )
        loadgenNodeMemoryMiB = Get-Maximum -Values @(
            $samplePeaks.loadgenNodeMemory
        )
    }
}

$result = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    runId = $RunId
    evidence = [ordered]@{
        nodeFiles = $nodeFiles.Count
        metadataFiles = $metadataRecords.Count
        intervalRecords = $records.Count
        firstObservedAtUtc = (
            $records.observedAt |
                Sort-Object |
                Select-Object -First 1
        ).ToString("o")
        lastObservedAtUtc = (
            $records.observedAt |
                Sort-Object |
                Select-Object -Last 1
        ).ToString("o")
        intervalSeconds = Get-Statistics -Values @($records.intervalSeconds)
        eventWindow = "-1.00s through +2.25s around controller apply log"
        runnerCohortLatencyMetric = $latencyMetricBaseName
        runnerCohortLatencyBoundary = if (
            $latencyMetricBaseName -ceq "probe_sync_latency_ms"
        ) {
            "canonical streaming delivery"
        } else {
            (
                "FeatureFlag.UpdatedAt to SDK; used only to associate " +
                "runner cohorts with one-second resource windows"
            )
        }
        resolutionBoundary = (
            "One-second deltas can reveal sustained scheduling, network, " +
            "pressure, and throttling events, but may dilute sub-second bursts."
        )
    }
    pools = [ordered]@{
        loadgen = $loadgenSummary
        featbit = $featbitSummary
    }
    els = $elsSummary
    kubernetesPeaks = $kubernetesPeaks
    revisions = $revisionRecords
    worstCohorts = @(
        $cohorts |
            Sort-Object p99Ms -Descending |
            Select-Object -First 20
    )
    correlationsWithRunnerP99 = $correlations
    metadata = @($metadataRecords)
}

$jsonPath = Join-Path $archiveDirectory "$RunId-node-evidence-1s.json"
$markdownPath = Join-Path $archiveDirectory "$RunId-node-evidence-1s.md"
Write-Utf8Text -Path $jsonPath -Value ($result | ConvertTo-Json -Depth 30)

$markdown = [Collections.Generic.List[string]]::new()
$markdown.Add("# $RunId：1 秒节点与 ELS 证据")
$markdown.Add("")
$markdown.Add("## 证据口径")
$markdown.Add("")
$markdown.Add("- $($nodeFiles.Count) 个节点文件，$($records.Count) 个相邻采样区间。")
$markdown.Add("- 实际区间 p50/p95/max：$(Format-Number $result.evidence.intervalSeconds.median 's') / $(Format-Number $result.evidence.intervalSeconds.p95 's') / $(Format-Number $result.evidence.intervalSeconds.maximum 's')。")
$markdown.Add("- Revision 窗口为 controller apply 日志前 1 秒至后 2.25 秒。")
$markdown.Add(
    "- runner cohort 关联指标：``$latencyMetricBaseName``；" +
    "canonical streaming 延迟以同轮三阶段报告为准。"
)
$markdown.Add("- 1 秒差分可发现持续的调度、网络、pressure 和 throttling；亚秒微突发可能被稀释。")
$markdown.Add("")
$markdown.Add("## 全程主机指标")
$markdown.Add("")
$markdown.Add("| Pool | Nodes | CPU p95 / p99 / max | CPU pressure p99 / max | run queue p99 / max | steal max | TCP retrans | packet drops |")
$markdown.Add("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
foreach ($poolName in @("loadgen", "featbit")) {
    $pool = $result.pools[$poolName]
    $drops = (
        $pool.eth0RxDrops + $pool.eth0TxDrops +
        $pool.ciliumRxDrops + $pool.ciliumTxDrops
    )
    $markdown.Add(((
        "| {0} | {1} | {2:N2}% / {3:N2}% / {4:N2}% | " +
        "{5:N3}% / {6:N3}% | {7:N2} / {8:N2} | {9:N3}% | " +
        "{10} | {11} |"
    ) -f
        $poolName,
        $pool.nodeCount,
        $pool.cpuPercent.p95,
        $pool.cpuPercent.p99,
        $pool.cpuPercent.maximum,
        $pool.cpuPressurePercent.p99,
        $pool.cpuPressurePercent.maximum,
        $pool.runQueue.p99,
        $pool.runQueue.maximum,
        $pool.stealPercent.maximum,
        $pool.tcpRetransSegments,
        $drops
    ))
}
$markdown.Add("")
$markdown.Add("## ELS cgroup")
$markdown.Add("")
$markdown.Add("| Pods | CPU p95 / p99 / max | CPU pressure p99 / max | throttled periods | throttled interval | throttled time |")
$markdown.Add("| ---: | ---: | ---: | ---: | ---: | ---: |")
$markdown.Add(((
    "| {0} | {1:N2}m / {2:N2}m / {3:N2}m | {4:N3}% / {5:N3}% | " +
    "{6}/{7} ({8:P3}) | {9}/{10} | {11:N2} ms |"
) -f
    $elsSummary.podCount,
    $elsSummary.cpuMillicores.p95,
    $elsSummary.cpuMillicores.p99,
    $elsSummary.cpuMillicores.maximum,
    $elsSummary.cpuPressurePercent.p99,
    $elsSummary.cpuPressurePercent.maximum,
    $elsSummary.throttledPeriods,
    $elsSummary.cpuPeriods,
    $elsSummary.throttledPeriodRate,
    $elsSummary.intervalsWithThrottling,
    $elsSummary.intervalCount,
    $elsSummary.throttledMilliseconds
))
$markdown.Add("")
$markdown.Add("## Revision 窗口")
$markdown.Add("")
$markdown.Add("| Rev | worst runner p99 | max | loadgen CPU max | pressure max | run queue max | retrans | drops | ELS CPU max | throttled periods | throttle time |")
$markdown.Add("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
foreach ($revision in $revisionRecords) {
    $markdown.Add(((
        "| {0} | {1:N2} ms | {2:N2} ms | {3:N2}% | {4:N3}% | " +
        "{5:N2} | {6} | {7} | {8:N2}m | {9} | {10:N2} ms |"
    ) -f
        $revision.revision,
        $revision.runnerP99MaximumMs,
        $revision.maximumMs,
        $revision.loadgenCpuMaximumPercent,
        $revision.loadgenCpuPressureMaximumPercent,
        $revision.loadgenRunQueueMaximum,
        $revision.loadgenTcpRetransSegments,
        $revision.loadgenPacketDrops,
        $revision.elsCpuMaximumMillicores,
        $revision.elsThrottledPeriods,
        $revision.elsThrottledMilliseconds
    ))
}
$markdown.Add("")
$markdown.Add("## 最差 runner × revision")
$markdown.Add("")
$markdown.Add("| Runner | Node | Rev | p95 | p99 | max | node CPU max | pressure max | run queue max | retrans | ELS throttled periods |")
$markdown.Add("| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
foreach ($cohort in $result.worstCohorts) {
    $markdown.Add(((
        "| {0} | {1} | {2} | {3:N2} ms | {4:N2} ms | {5:N2} ms | " +
        "{6:N2}% | {7:N3}% | {8:N2} | {9} | {10} |"
    ) -f
        $cohort.runner,
        $cohort.node,
        $cohort.revision,
        $cohort.p95Ms,
        $cohort.p99Ms,
        $cohort.maximumMs,
        $cohort.loadgenCpuMaximumPercent,
        $cohort.loadgenCpuPressureMaximumPercent,
        $cohort.loadgenRunQueueMaximum,
        $cohort.loadgenTcpRetransSegments,
        $cohort.elsThrottledPeriods
    ))
}
$markdown.Add("")
$markdown.Add("## 相关性（探索性）")
$markdown.Add("")
$markdown.Add("Pearson r 只用于寻找后续方向；同节点两个 runner 会共享同一节点窗口，因此不作为因果证明。")
$markdown.Add("")
$markdown.Add("| 1 秒窗口指标 | 与 runner/revision p99 的 r |")
$markdown.Add("| --- | ---: |")
foreach ($entry in $correlations.GetEnumerator()) {
    $markdown.Add(
        "| $($entry.Key) | $(Format-Number $entry.Value) |"
    )
}
$markdown.Add("")
$markdown.Add("Machine-readable evidence: ``$jsonPath``")
Write-Utf8Text -Path $markdownPath -Value ($markdown -join [Environment]::NewLine)

[pscustomobject]@{
    RunId = $RunId
    JsonPath = $jsonPath
    MarkdownPath = $markdownPath
    NodeFileCount = $nodeFiles.Count
    IntervalRecordCount = $records.Count
    IntervalP50Seconds = $result.evidence.intervalSeconds.median
    IntervalP95Seconds = $result.evidence.intervalSeconds.p95
    LoadgenCpuP99Percent = $loadgenSummary.cpuPercent.p99
    LoadgenCpuPressureP99Percent = $loadgenSummary.cpuPressurePercent.p99
    ElsCpuP99Millicores = $elsSummary.cpuMillicores.p99
    ElsThrottledPeriodRate = $elsSummary.throttledPeriodRate
    ElsThrottledMilliseconds = $elsSummary.throttledMilliseconds
}
