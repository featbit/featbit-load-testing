[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^growth-f3k-dotnet-p500-[a-z0-9-]+$")]
    [string] $RunId,

    [Parameter(Mandatory)]
    [ValidatePattern("^featbit-growth-f3k-dotnet-p500-[a-z0-9-]+$")]
    [string] $JobName,

    [Parameter(Mandatory)]
    [ValidatePattern("^aks-featbit-load-testing$")]
    [string] $KubeContext,

    [ValidateRange(5, 60)]
    [int] $SampleIntervalSeconds = 5,

    [ValidateRange(5, 60)]
    [int] $TimeoutMinutes = 30,

    [ValidateRange(3, 300)]
    [int] $MaxConsecutiveSampleErrors = 60,

    [string] $OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Read-KubectlJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $FailureMessage
    )

    $text = (& kubectl @Arguments 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        throw $FailureMessage
    }
    return $text | ConvertFrom-Json
}

function Get-StatusInt {
    param(
        [Parameter(Mandatory)][object] $Object,
        [Parameter(Mandatory)][string] $Name
    )

    $property = $Object.status.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return 0
    }
    return [int]$property.Value
}

function Convert-CpuToMillicores {
    param([Parameter(Mandatory)][string] $Quantity)

    if ($Quantity -notmatch "^(?<number>[0-9]+(?:\.[0-9]+)?)(?<unit>n|u|m)?$") {
        throw "Unsupported CPU quantity '$Quantity'."
    }
    $number = [double]::Parse(
        $Matches.number,
        [Globalization.CultureInfo]::InvariantCulture
    )
    $converted = switch ([string]$Matches["unit"]) {
        "n" { $number / 1000000 }
        "u" { $number / 1000 }
        "m" { $number }
        default { $number * 1000 }
    }
    return $converted
}

function Convert-MemoryToBytes {
    param([Parameter(Mandatory)][string] $Quantity)

    if (
        $Quantity -notmatch
            "^(?<number>[0-9]+(?:\.[0-9]+)?)(?<unit>Ki|Mi|Gi|Ti|K|M|G|T)?$"
    ) {
        throw "Unsupported memory quantity '$Quantity'."
    }
    $number = [double]::Parse(
        $Matches.number,
        [Globalization.CultureInfo]::InvariantCulture
    )
    $multiplier = switch ([string]$Matches["unit"]) {
        "Ki" { [Math]::Pow(1024, 1) }
        "Mi" { [Math]::Pow(1024, 2) }
        "Gi" { [Math]::Pow(1024, 3) }
        "Ti" { [Math]::Pow(1024, 4) }
        "K" { [Math]::Pow(1000, 1) }
        "M" { [Math]::Pow(1000, 2) }
        "G" { [Math]::Pow(1000, 3) }
        "T" { [Math]::Pow(1000, 4) }
        default { 1 }
    }
    return $number * $multiplier
}

function Update-Peak {
    param(
        [Parameter(Mandatory)][hashtable] $Peaks,
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)][object] $Identity,
        [Parameter(Mandatory)][double] $CpuMillicores,
        [Parameter(Mandatory)][double] $MemoryBytes,
        [Parameter(Mandatory)][string] $ObservedAtUtc
    )

    if (-not $Peaks.ContainsKey($Key)) {
        $Peaks[$Key] = [ordered]@{
            identity = $Identity
            peakCpuMillicores = 0.0
            peakCpuObservedAtUtc = ""
            peakMemoryBytes = 0.0
            peakMemoryObservedAtUtc = ""
        }
    }
    $entry = $Peaks[$Key]
    if ($CpuMillicores -gt [double]$entry.peakCpuMillicores) {
        $entry.peakCpuMillicores = $CpuMillicores
        $entry.peakCpuObservedAtUtc = $ObservedAtUtc
    }
    if ($MemoryBytes -gt [double]$entry.peakMemoryBytes) {
        $entry.peakMemoryBytes = $MemoryBytes
        $entry.peakMemoryObservedAtUtc = $ObservedAtUtc
    }
}

function Get-PodRole {
    param(
        [Parameter(Mandatory)][object] $Pod,
        [Parameter(Mandatory)][string] $ExpectedRunId
    )

    $namespace = [string]$Pod.metadata.namespace
    $runProperty =
        $Pod.metadata.labels.PSObject.Properties[
            "loadtest.featbit.io/run-id"
        ]
    $appProperty =
        $Pod.metadata.labels.PSObject.Properties[
            "app.kubernetes.io/name"
        ]
    $componentProperty =
        $Pod.metadata.labels.PSObject.Properties[
            "app.kubernetes.io/component"
        ]
    $runLabel = if ($null -eq $runProperty) {
        ""
    }
    else {
        [string]$runProperty.Value
    }
    $appName = if ($null -eq $appProperty) {
        ""
    }
    else {
        [string]$appProperty.Value
    }
    $component = if ($null -eq $componentProperty) {
        ""
    }
    else {
        [string]$componentProperty.Value
    }
    if (
        $namespace -eq "featbit-loadtest" -and
        $runLabel -eq $ExpectedRunId -and
        $appName -eq "featbit-dotnet-sdk-runner"
    ) {
        return "dotnet-runner"
    }
    if (
        $namespace -eq "featbit-loadtest" -and
        $runLabel -eq $ExpectedRunId -and
        $appName -eq "featbit-k6-controller"
    ) {
        return "controller"
    }
    if ($namespace -eq "featbit" -and $component -eq "els") {
        return "els"
    }
    if ($namespace -eq "featbit") {
        return "featbit"
    }
    if ($namespace -eq "featbit-loadtest") {
        return "loadtest-support"
    }
    return "other"
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext
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
$samplesPath = Join-Path $resultsDirectory "$RunId-resource-samples.jsonl"
$summaryPath = Join-Path $resultsDirectory "$RunId-resource-summary.json"
$errorPath = Join-Path $resultsDirectory "$RunId-resource-monitor-error.log"
foreach ($path in @($samplesPath, $summaryPath, $errorPath)) {
    if (Test-Path -LiteralPath $path) {
        throw "Refusing to overwrite resource monitor artifact: $path"
    }
}

$nodes = Read-KubectlJson `
    -Arguments @("--context", $targetContext, "get", "nodes", "-o", "json") `
    -FailureMessage "Failed to inspect AKS nodes before monitoring."
$nodePoolByName = @{}
foreach ($node in @($nodes.items)) {
    $nodePoolByName[[string]$node.metadata.name] =
        [string]$node.metadata.labels.agentpool
}

$nodePeaks = @{}
$containerPeaks = @{}
$rolePeaks = @{}
$poolPeaks = @{}
$sampleCount = 0
$sampleErrors = 0
$consecutiveErrors = 0
$startedAtUtc = [DateTime]::UtcNow
$deadline = $startedAtUtc.AddMinutes($TimeoutMinutes)
$finalJobState = "unknown"
$writer = [IO.StreamWriter]::new(
    $samplesPath,
    $false,
    [Text.UTF8Encoding]::new($false)
)
try {
    do {
        $sampleStartedAt = [DateTime]::UtcNow
        $observedAtUtc = [DateTime]::UtcNow.ToString("o")
        $observedAtUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        try {
            $job = Read-KubectlJson `
                -Arguments @(
                    "--context", $targetContext,
                    "-n", "featbit-loadtest",
                    "get", "job", $JobName,
                    "-o", "json"
                ) `
                -FailureMessage "Failed to inspect pilot Job."
            $pods = Read-KubectlJson `
                -Arguments @(
                    "--context", $targetContext,
                    "get", "pods", "-A",
                    "--field-selector=status.phase=Running",
                    "-o", "json"
                ) `
                -FailureMessage "Failed to inspect Pod metadata."
            $nodeMetrics = Read-KubectlJson `
                -Arguments @(
                    "--context", $targetContext,
                    "get", "--raw",
                    "/apis/metrics.k8s.io/v1beta1/nodes"
                ) `
                -FailureMessage "Failed to query node metrics."
            $podMetrics = Read-KubectlJson `
                -Arguments @(
                    "--context", $targetContext,
                    "get", "--raw",
                    "/apis/metrics.k8s.io/v1beta1/pods"
                ) `
                -FailureMessage "Failed to query Pod metrics."

            $podByKey = @{}
            foreach ($pod in @($pods.items)) {
                $key = "{0}/{1}" -f
                    [string]$pod.metadata.namespace,
                    [string]$pod.metadata.name
                $podByKey[$key] = $pod
            }

            $nodeRows = [Collections.Generic.List[object]]::new()
            $poolTotals = @{}
            foreach ($metric in @($nodeMetrics.items)) {
                $name = [string]$metric.metadata.name
                if (-not $nodePoolByName.ContainsKey($name)) {
                    continue
                }
                $cpu = Convert-CpuToMillicores `
                    -Quantity ([string]$metric.usage.cpu)
                $memory = Convert-MemoryToBytes `
                    -Quantity ([string]$metric.usage.memory)
                $pool = [string]$nodePoolByName[$name]
                $row = [ordered]@{
                    node = $name
                    pool = $pool
                    cpuMillicores = $cpu
                    memoryBytes = $memory
                }
                $nodeRows.Add([pscustomobject]$row)
                Update-Peak `
                    -Peaks $nodePeaks `
                    -Key $name `
                    -Identity ([ordered]@{ node = $name; pool = $pool }) `
                    -CpuMillicores $cpu `
                    -MemoryBytes $memory `
                    -ObservedAtUtc $observedAtUtc
                if (-not $poolTotals.ContainsKey($pool)) {
                    $poolTotals[$pool] = [ordered]@{
                        cpuMillicores = 0.0
                        memoryBytes = 0.0
                    }
                }
                $poolTotals[$pool].cpuMillicores += $cpu
                $poolTotals[$pool].memoryBytes += $memory
            }

            $containerRows = [Collections.Generic.List[object]]::new()
            $roleTotals = @{}
            foreach ($podMetric in @($podMetrics.items)) {
                $namespace = [string]$podMetric.metadata.namespace
                if ($namespace -notin @("featbit", "featbit-loadtest")) {
                    continue
                }
                $podName = [string]$podMetric.metadata.name
                $podKey = "$namespace/$podName"
                if (-not $podByKey.ContainsKey($podKey)) {
                    continue
                }
                $pod = $podByKey[$podKey]
                $role = Get-PodRole -Pod $pod -ExpectedRunId $RunId
                $node = [string]$pod.spec.nodeName
                foreach ($container in @($podMetric.containers)) {
                    $containerName = [string]$container.name
                    $cpu = Convert-CpuToMillicores `
                        -Quantity ([string]$container.usage.cpu)
                    $memory = Convert-MemoryToBytes `
                        -Quantity ([string]$container.usage.memory)
                    $containerKey = "$namespace/$podName/$containerName"
                    $row = [ordered]@{
                        namespace = $namespace
                        pod = $podName
                        container = $containerName
                        node = $node
                        role = $role
                        cpuMillicores = $cpu
                        memoryBytes = $memory
                    }
                    $containerRows.Add([pscustomobject]$row)
                    Update-Peak `
                        -Peaks $containerPeaks `
                        -Key $containerKey `
                        -Identity ([ordered]@{
                            namespace = $namespace
                            pod = $podName
                            container = $containerName
                            node = $node
                            role = $role
                        }) `
                        -CpuMillicores $cpu `
                        -MemoryBytes $memory `
                        -ObservedAtUtc $observedAtUtc
                    if (-not $roleTotals.ContainsKey($role)) {
                        $roleTotals[$role] = [ordered]@{
                            cpuMillicores = 0.0
                            memoryBytes = 0.0
                        }
                    }
                    $roleTotals[$role].cpuMillicores += $cpu
                    $roleTotals[$role].memoryBytes += $memory
                }
            }
            foreach ($entry in $roleTotals.GetEnumerator()) {
                Update-Peak `
                    -Peaks $rolePeaks `
                    -Key ([string]$entry.Key) `
                    -Identity ([ordered]@{ role = [string]$entry.Key }) `
                    -CpuMillicores ([double]$entry.Value.cpuMillicores) `
                    -MemoryBytes ([double]$entry.Value.memoryBytes) `
                    -ObservedAtUtc $observedAtUtc
            }
            foreach ($entry in $poolTotals.GetEnumerator()) {
                Update-Peak `
                    -Peaks $poolPeaks `
                    -Key ([string]$entry.Key) `
                    -Identity ([ordered]@{ pool = [string]$entry.Key }) `
                    -CpuMillicores ([double]$entry.Value.cpuMillicores) `
                    -MemoryBytes ([double]$entry.Value.memoryBytes) `
                    -ObservedAtUtc $observedAtUtc
            }

            $record = [ordered]@{
                schemaVersion = 1
                runId = $RunId
                observedAtUtc = $observedAtUtc
                observedAtUnixMs = $observedAtUnixMs
                job = [ordered]@{
                    active = Get-StatusInt -Object $job -Name "active"
                    succeeded = Get-StatusInt -Object $job -Name "succeeded"
                    failed = Get-StatusInt -Object $job -Name "failed"
                }
                nodes = @($nodeRows)
                containers = @($containerRows)
                roleTotals = @(
                    foreach ($entry in $roleTotals.GetEnumerator()) {
                        [ordered]@{
                            role = [string]$entry.Key
                            cpuMillicores =
                                [double]$entry.Value.cpuMillicores
                            memoryBytes =
                                [double]$entry.Value.memoryBytes
                        }
                    }
                )
                poolTotals = @(
                    foreach ($entry in $poolTotals.GetEnumerator()) {
                        [ordered]@{
                            pool = [string]$entry.Key
                            cpuMillicores =
                                [double]$entry.Value.cpuMillicores
                            memoryBytes =
                                [double]$entry.Value.memoryBytes
                        }
                    }
                )
            }
            $writer.WriteLine(($record | ConvertTo-Json -Depth 10 -Compress))
            $writer.Flush()
            $sampleCount += 1
            $consecutiveErrors = 0

            $conditionsProperty =
                $job.status.PSObject.Properties["conditions"]
            $terminalConditions = @()
            if ($null -ne $conditionsProperty) {
                $terminalConditions = @(
                    $conditionsProperty.Value | Where-Object {
                        [string]$_.status -eq "True" -and
                        [string]$_.type -in @("Complete", "Failed")
                    }
                )
            }
            if ($terminalConditions.Count -gt 0) {
                $finalJobState = if (
                    (Get-StatusInt -Object $job -Name "failed") -gt 0
                ) {
                    "failed"
                }
                else {
                    "complete"
                }
                break
            }
        }
        catch {
            $sampleErrors += 1
            $consecutiveErrors += 1
            $errorRecord = [ordered]@{
                observedAtUtc = $observedAtUtc
                message = $_.Exception.Message
            }
            Add-Content `
                -LiteralPath $errorPath `
                -Value ($errorRecord | ConvertTo-Json -Compress) `
                -Encoding utf8
            if ($consecutiveErrors -ge $MaxConsecutiveSampleErrors) {
                throw (
                    "Resource monitoring reached $consecutiveErrors " +
                    "consecutive sampling errors."
                )
            }
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            $finalJobState = "timeout"
            break
        }
        $remainingSampleDelayMs = [int][Math]::Max(
            0,
            ($SampleIntervalSeconds * 1000) -
                ([DateTime]::UtcNow - $sampleStartedAt).TotalMilliseconds
        )
        if ($remainingSampleDelayMs -gt 0) {
            Start-Sleep -Milliseconds $remainingSampleDelayMs
        }
    } while ($true)
}
finally {
    $writer.Dispose()
}

$summary = [ordered]@{
    schemaVersion = 1
    runId = $RunId
    jobName = $JobName
    kubernetesContext = $targetContext
    startedAtUtc = $startedAtUtc.ToString("o")
    endedAtUtc = [DateTime]::UtcNow.ToString("o")
    sampleIntervalSeconds = $SampleIntervalSeconds
    sampleCount = $sampleCount
    sampleErrors = $sampleErrors
    finalJobState = $finalJobState
    peaks = [ordered]@{
        nodes = @($nodePeaks.Values)
        containers = @($containerPeaks.Values)
        roles = @($rolePeaks.Values)
        nodePools = @($poolPeaks.Values)
    }
}
[IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 12) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
)

if ($finalJobState -eq "timeout") {
    throw "Timed out waiting for Job '$JobName'."
}

[pscustomobject]@{
    RunId = $RunId
    JobName = $JobName
    FinalJobState = $finalJobState
    SampleCount = $sampleCount
    SampleErrors = $sampleErrors
    SamplesPath = $samplesPath
    SummaryPath = $summaryPath
}
