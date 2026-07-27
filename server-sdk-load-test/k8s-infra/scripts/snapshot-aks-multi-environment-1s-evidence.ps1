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
        throw "Refusing to overwrite existing one-second evidence: $Path"
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
$namespace = $script:LoadTestNamespace
$continuousRunId = "growth-menv-continuous"
$daemonSetName = "featbit-1s-evidence"
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

$podsText = (
    & kubectl --context $targetContext `
        -n $namespace `
        get pods `
        -l "app.kubernetes.io/name=$daemonSetName" `
        -o json |
        Out-String
)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($podsText)) {
    throw "Failed to inspect the continuous one-second collector Pods."
}
$pods = @((($podsText | ConvertFrom-Json).items))
$readyPods = @($pods | Where-Object {
    [string]$_.metadata.labels."loadtest.featbit.io/run-id" -ceq
        $continuousRunId -and
    $_.status.phase -eq "Running" -and
    @($_.status.containerStatuses | Where-Object ready).Count -eq
        @($_.status.containerStatuses).Count
})
$nodes = @($readyPods.spec.nodeName | Sort-Object -Unique)
if ($readyPods.Count -ne 13 -or $nodes.Count -ne 13) {
    throw (
        "Expected 13 ready continuous collectors on 13 nodes; found " +
        "$($readyPods.Count) Pods on $($nodes.Count) nodes."
    )
}

# Force each collector to publish its in-memory buffer without stopping or
# restarting any Pod or Kubernetes resource.
foreach ($pod in $readyPods) {
    $podName = [string]$pod.metadata.name
    $nodeToken = ([string]$pod.spec.nodeName) -replace "[^A-Za-z0-9._-]", "_"
    $samplesName = "$continuousRunId-node-$nodeToken-1s.tsv"
    $metadataName = "$continuousRunId-node-$nodeToken-metadata.txt"
    $publishCommand = (
        "cp /buffer/{0} /results/{0}.partial && " +
        "mv /results/{0}.partial /results/{0} && " +
        "cp /buffer/{1} /results/{1}.partial && " +
        "mv /results/{1}.partial /results/{1}"
    ) -f $samplesName, $metadataName
    & kubectl --context $targetContext `
        -n $namespace `
        exec $podName -- sh -c $publishCommand *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to flush one-second evidence from '$podName'."
    }
}

$windowStart = [DateTimeOffset]::FromUnixTimeMilliseconds(
    $StartUnixMs - 5000
)
$windowEnd = [DateTimeOffset]::FromUnixTimeMilliseconds($EndUnixMs + 5000)
$written = [Collections.Generic.List[object]]::new()

foreach ($node in $nodes) {
    $nodeToken = ([string]$node) -replace "[^A-Za-z0-9._-]", "_"
    $sourceSamplesName = "$continuousRunId-node-$nodeToken-1s.tsv"
    $sourceMetadataName = "$continuousRunId-node-$nodeToken-metadata.txt"
    $samplesText = (
        & kubectl --context $targetContext `
            -n $namespace `
            exec results-reader -- `
            cat "/results/$sourceSamplesName" |
            Out-String
    )
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($samplesText)) {
        throw "Failed to read continuous one-second samples for '$node'."
    }
    $metadataText = (
        & kubectl --context $targetContext `
            -n $namespace `
            exec results-reader -- `
            cat "/results/$sourceMetadataName" |
            Out-String
    )
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($metadataText)) {
        throw "Failed to read continuous one-second metadata for '$node'."
    }

    $lines = @($samplesText -split "\r?\n")
    if ($lines.Count -lt 2 -or $lines[0] -notmatch "^observed_at_utc`t") {
        throw "Continuous one-second samples for '$node' have an invalid header."
    }
    $selected = [Collections.Generic.List[string]]::new()
    $selected.Add($lines[0])
    foreach ($line in $lines | Select-Object -Skip 1) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $timestampText = ($line -split "`t", 2)[0]
        $timestamp = [DateTimeOffset]::Parse(
            $timestampText,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        )
        if ($timestamp -ge $windowStart -and $timestamp -le $windowEnd) {
            $selected.Add($line)
        }
    }
    if ($selected.Count -lt 3) {
        throw "Node '$node' has fewer than two one-second samples in the run window."
    }

    $runSamplesName = "$RunId-node-$nodeToken-1s.tsv"
    $runMetadataName = "$RunId-node-$nodeToken-metadata.txt"
    $runSamplesPath = Join-Path $resultsDirectory $runSamplesName
    $runMetadataPath = Join-Path $resultsDirectory $runMetadataName
    $runMetadata = (
        ($metadataText.Trim() -replace "(?m)^run_id=.*$", "run_id=$RunId") +
        "`nsource_continuous_run_id=$continuousRunId`n" +
        "window_start_utc=$($windowStart.ToString('o'))`n" +
        "window_end_utc=$($windowEnd.ToString('o'))`n"
    )
    Write-Utf8NoBom `
        -Path $runSamplesPath `
        -Content (($selected -join "`n") + "`n")
    Write-Utf8NoBom -Path $runMetadataPath -Content $runMetadata

    foreach ($file in @(
        @{ Path = $runSamplesPath; Name = $runSamplesName },
        @{ Path = $runMetadataPath; Name = $runMetadataName }
    )) {
        & kubectl --context $targetContext `
            -n $namespace `
            exec results-reader -- `
            test ! -e "/results/$($file.Name)"
        if ($LASTEXITCODE -ne 0) {
            throw (
                "Refusing to overwrite existing PVC evidence " +
                "'/results/$($file.Name)'."
            )
        }
        Push-Location $resultsDirectory
        try {
            & kubectl --context $targetContext `
                -n $namespace `
                cp ".\$($file.Name)" "results-reader:/results/$($file.Name)"
            $copyExitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
        if ($copyExitCode -ne 0) {
            throw "Failed to publish '$($file.Name)' to the results PVC."
        }
    }

    $written.Add([ordered]@{
        node = [string]$node
        samples = $selected.Count - 1
        samplesPath = $runSamplesPath
        metadataPath = $runMetadataPath
    })
}

Write-Host (
    "One-second evidence window published for 13 nodes; the continuous " +
    "collector was preserved."
) -ForegroundColor Green
[pscustomobject]@{
    RunId = $RunId
    SourceRunId = $continuousRunId
    NodeCount = $written.Count
    StartUnixMs = $StartUnixMs
    EndUnixMs = $EndUnixMs
    Evidence = @($written)
    DeletedResources = 0
}
