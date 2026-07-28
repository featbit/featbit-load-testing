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

    [ValidatePattern("^growth-[a-z0-9-]+$")]
    [string] $SourceRunId = "growth-menv-continuous",

    [ValidatePattern("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")]
    [string] $DaemonSetName = "featbit-1s-evidence",

    [ValidateRange(1, 100)]
    [int] $ExpectedNodeCount = 13,

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

function Read-RemoteResultText {
    param(
        [Parameter(Mandatory)][string] $RemotePath,
        [Parameter(Mandatory)][string] $FailureMessage
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $text = (
            & kubectl --context $script:targetContext `
                -n $script:namespace `
                exec results-reader -- cat $RemotePath 2>$null |
                Out-String
        )
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($text)) {
            return $text
        }
        if ($attempt -lt 3) {
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    throw $FailureMessage
}

function Read-RemoteSampleWindow {
    param(
        [Parameter(Mandatory)][string] $RemotePath,
        [Parameter(Mandatory)][string] $WindowStartText,
        [Parameter(Mandatory)][string] $WindowEndText,
        [Parameter(Mandatory)][string] $FailureMessage
    )

    $awkProgram = (
        'NR == 1 || (' +
        '"x" $1 >= "x" start && "x" $1 <= "x" end' +
        ')'
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $text = (
            & kubectl --context $script:targetContext `
                -n $script:namespace `
                exec results-reader -- `
                awk -F "`t" `
                    -v "start=$WindowStartText" `
                    -v "end=$WindowEndText" `
                    $awkProgram `
                    $RemotePath 2>$null |
                Out-String
        )
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($text)) {
            return $text
        }
        if ($attempt -lt 3) {
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    throw $FailureMessage
}

function Copy-LocalEvidenceToPvc {
    param(
        [Parameter(Mandatory)][string] $LocalPath,
        [Parameter(Mandatory)][string] $RemoteName
    )

    $localDirectory = Split-Path -Parent $LocalPath
    $localName = Split-Path -Leaf $LocalPath
    Push-Location $localDirectory
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            & kubectl --context $script:targetContext `
                -n $script:namespace `
                cp ".\$localName" "results-reader:/results/$RemoteName" `
                *> $null
            if ($LASTEXITCODE -eq 0) {
                return
            }
            if ($attempt -lt 3) {
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    }
    finally {
        Pop-Location
    }
    throw "Failed to publish '$RemoteName' to the results PVC."
}

function Invoke-CollectorFlush {
    param(
        [Parameter(Mandatory)][string] $PodName,
        [Parameter(Mandatory)][string] $PublishCommand
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & kubectl --context $script:targetContext `
            -n $script:namespace `
            exec $PodName -- sh -c $PublishCommand *> $null
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($attempt -lt 3) {
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    throw (
        "Failed to flush one-second evidence from '$PodName' " +
        "after three attempts."
    )
}

if ($EndUnixMs -le $StartUnixMs) {
    throw "EndUnixMs must be greater than StartUnixMs."
}

$targetContext = $KubeContext.Trim()
$namespace = $script:LoadTestNamespace
$continuousRunId = $SourceRunId
$daemonSetName = $DaemonSetName
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
if (
    $readyPods.Count -ne $ExpectedNodeCount -or
    $nodes.Count -ne $ExpectedNodeCount
) {
    throw (
        "Expected $ExpectedNodeCount ready continuous collectors on " +
        "$ExpectedNodeCount nodes; found " +
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
    Invoke-CollectorFlush `
        -PodName $podName `
        -PublishCommand $publishCommand
}

$windowStart = [DateTimeOffset]::FromUnixTimeMilliseconds(
    $StartUnixMs - 5000
)
$windowEnd = [DateTimeOffset]::FromUnixTimeMilliseconds($EndUnixMs + 5000)
$windowStartText = $windowStart.UtcDateTime.ToString(
    "yyyy-MM-ddTHH:mm:ssZ",
    [Globalization.CultureInfo]::InvariantCulture
)
$windowEndText = $windowEnd.UtcDateTime.ToString(
    "yyyy-MM-ddTHH:mm:ssZ",
    [Globalization.CultureInfo]::InvariantCulture
)
$written = [Collections.Generic.List[object]]::new()

foreach ($node in $nodes) {
    $nodeToken = ([string]$node) -replace "[^A-Za-z0-9._-]", "_"
    $sourceSamplesName = "$continuousRunId-node-$nodeToken-1s.tsv"
    $sourceMetadataName = "$continuousRunId-node-$nodeToken-metadata.txt"
    $samplesText = Read-RemoteSampleWindow `
        -RemotePath "/results/$sourceSamplesName" `
        -WindowStartText $windowStartText `
        -WindowEndText $windowEndText `
        -FailureMessage (
            "Failed to read continuous one-second samples for '$node'."
        )
    $metadataText = Read-RemoteResultText `
        -RemotePath "/results/$sourceMetadataName" `
        -FailureMessage (
            "Failed to read continuous one-second metadata for '$node'."
        )

    $lines = @($samplesText -split "\r?\n")
    if ($lines.Count -lt 2 -or $lines[0] -notmatch "^observed_at_utc`t") {
        throw "Continuous one-second samples for '$node' have an invalid header."
    }
    $lastNonBlankLineIndex = -1
    for ($lineIndex = $lines.Count - 1; $lineIndex -ge 1; $lineIndex--) {
        if (-not [string]::IsNullOrWhiteSpace($lines[$lineIndex])) {
            $lastNonBlankLineIndex = $lineIndex
            break
        }
    }
    $selected = [Collections.Generic.List[string]]::new()
    $selected.Add($lines[0])
    $ignoredTruncatedTrailingSamples = 0
    for ($lineIndex = 1; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $timestampText = ($line -split "`t", 2)[0]
        $timestamp = [DateTimeOffset]::MinValue
        $timestampValid = [DateTimeOffset]::TryParse(
            $timestampText,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$timestamp
        )
        if (-not $timestampValid) {
            if ($lineIndex -eq $lastNonBlankLineIndex) {
                # The collector is still appending while its buffer is copied.
                # Only a single partial final line is safe to ignore.
                $ignoredTruncatedTrailingSamples++
                continue
            }
            throw (
                "Continuous one-second samples for '$node' contain an " +
                "invalid timestamp before the final data line: " +
                "'$timestampText'."
            )
        }
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
        "window_end_utc=$($windowEnd.ToString('o'))`n" +
        (
            "ignored_truncated_trailing_sample_count=" +
            "$ignoredTruncatedTrailingSamples`n"
        )
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
        Copy-LocalEvidenceToPvc `
            -LocalPath $file.Path `
            -RemoteName $file.Name
    }

    $written.Add([ordered]@{
        node = [string]$node
        samples = $selected.Count - 1
        ignoredTruncatedTrailingSamples = $ignoredTruncatedTrailingSamples
        samplesPath = $runSamplesPath
        metadataPath = $runMetadataPath
    })
}

Write-Host (
    "One-second evidence window published for $ExpectedNodeCount nodes; " +
    "the continuous " +
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
