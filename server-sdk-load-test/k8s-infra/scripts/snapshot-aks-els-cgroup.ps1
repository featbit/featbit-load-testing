[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [string] $RunId,

    [Parameter(Mandatory)]
    [ValidatePattern("^aks-featbit-load-testing$")]
    [string] $KubeContext,

    [Parameter(Mandatory)]
    [ValidateSet("pre", "post")]
    [string] $Phase,

    [string] $OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Read-KubectlJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $FailureMessage
    )

    $text = (& kubectl @Arguments | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        throw $FailureMessage
    }
    return $text | ConvertFrom-Json
}

function Read-ContainerFile {
    param(
        [Parameter(Mandatory)][string] $Pod,
        [Parameter(Mandatory)][string] $Path
    )

    $text = (
        & kubectl --context $script:targetContext `
            -n featbit `
            exec $Pod -- cat $Path 2>$null |
            Out-String
    )
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        throw "Failed to read '$Path' from ELS Pod '$Pod'."
    }
    return $text.Trim()
}

function Convert-KeyValueLines {
    param([Parameter(Mandatory)][string] $Text)

    $result = [ordered]@{}
    foreach ($line in @($Text -split "\r?\n")) {
        $parts = @($line.Trim() -split "\s+", 2)
        if ($parts.Count -eq 2 -and $parts[0] -match "^[a-z_]+$") {
            $value = 0L
            if ([int64]::TryParse($parts[1], [ref]$value)) {
                $result[$parts[0]] = $value
            }
        }
    }
    return $result
}

function Convert-PressureLines {
    param([Parameter(Mandatory)][string] $Text)

    $result = [ordered]@{}
    foreach ($line in @($Text -split "\r?\n")) {
        if (
            $line -match
                "^(?<kind>some|full)\s+avg10=(?<avg10>[0-9.]+)\s+" +
                "avg60=(?<avg60>[0-9.]+)\s+avg300=(?<avg300>[0-9.]+)\s+" +
                "total=(?<total>\d+)$"
        ) {
            $result[$Matches["kind"]] = [ordered]@{
                avg10 = [double]$Matches["avg10"]
                avg60 = [double]$Matches["avg60"]
                avg300 = [double]$Matches["avg300"]
                totalUsec = [int64]$Matches["total"]
            }
        }
    }
    return $result
}

$script:targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $script:targetContext
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
$outputPath = Join-Path $resultsDirectory "$RunId-els-cgroup-$Phase.json"
if (Test-Path -LiteralPath $outputPath) {
    throw "Refusing to overwrite existing ELS cgroup snapshot: $outputPath"
}

$deployment = Read-KubectlJson `
    -Arguments @(
        "--context", $script:targetContext,
        "-n", "featbit",
        "get", "deployment", "featbit-els",
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect the ELS deployment."
$pods = @(
    (
        Read-KubectlJson `
            -Arguments @(
                "--context", $script:targetContext,
                "-n", "featbit",
                "get", "pods",
                "-l", "app.kubernetes.io/component=els",
                "-o", "json"
            ) `
            -FailureMessage "Failed to inspect the ELS Pods."
    ).items
)
$readyPods = @($pods | Where-Object {
    $_.status.phase -eq "Running" -and
    @($_.status.containerStatuses).Count -eq 1 -and
    $_.status.containerStatuses[0].ready -eq $true
})
$nodes = @($readyPods.spec.nodeName | Sort-Object -Unique)
if ($readyPods.Count -ne 3 -or $nodes.Count -ne 3) {
    throw (
        "Expected three ready ELS Pods on three nodes; found " +
        "$($readyPods.Count) Pods on $($nodes.Count) nodes."
    )
}

$snapshots = @(
    foreach ($pod in $readyPods | Sort-Object { $_.metadata.name }) {
        $name = [string]$pod.metadata.name
        $cpuStat = Convert-KeyValueLines `
            -Text (Read-ContainerFile -Pod $name -Path "/sys/fs/cgroup/cpu.stat")
        foreach ($required in @(
            "usage_usec",
            "nr_periods",
            "nr_throttled",
            "throttled_usec"
        )) {
            if (-not $cpuStat.Contains($required)) {
                throw "ELS Pod '$name' cpu.stat has no '$required' field."
            }
        }
        $pressure = Convert-PressureLines `
            -Text (
                Read-ContainerFile `
                    -Pod $name `
                    -Path "/sys/fs/cgroup/cpu.pressure"
            )
        [ordered]@{
            pod = $name
            podUid = [string]$pod.metadata.uid
            node = [string]$pod.spec.nodeName
            startedAtUtc = [string]$pod.status.startTime
            restartCount =
                [int]$pod.status.containerStatuses[0].restartCount
            cpu = $cpuStat
            pressure = $pressure
        }
    }
)

$record = [ordered]@{
    schemaVersion = 1
    runId = $RunId
    phase = $Phase
    capturedAtUtc = [DateTime]::UtcNow.ToString("o")
    capturedAtUnixMs =
        [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    kubernetesContext = $script:targetContext
    namespace = "featbit"
    deployment = [ordered]@{
        name = "featbit-els"
        replicas = [int]$deployment.spec.replicas
        image = [string]$deployment.spec.template.spec.containers[0].image
        cpuRequest = [string](
            $deployment.spec.template.spec.containers[0].resources.requests.cpu
        )
        cpuLimit = [string](
            $deployment.spec.template.spec.containers[0].resources.limits.cpu
        )
        memoryRequest = [string](
            $deployment.spec.template.spec.containers[0].resources.requests.memory
        )
        memoryLimit = [string](
            $deployment.spec.template.spec.containers[0].resources.limits.memory
        )
    }
    pods = $snapshots
    readOnly = $true
    resourcesDeleted = 0
}
[IO.File]::WriteAllText(
    $outputPath,
    (($record | ConvertTo-Json -Depth 10) + "`n"),
    [Text.UTF8Encoding]::new($false)
)

[pscustomobject]@{
    RunId = $RunId
    Phase = $Phase
    PodCount = $snapshots.Count
    OutputPath = $outputPath
    ResourcesDeleted = 0
}
