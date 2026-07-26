[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [string] $RunId,

    [string] $ResultsDirectory = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$repositoryRoot = Get-RepositoryRoot
$resultsRoot = if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) {
    Join-Path $repositoryRoot "results"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $ResultsDirectory
    )
}
$analyzer = Join-Path $PSScriptRoot "analyze-aks-sentinel-matrix.mjs"
if (-not (Test-Path -LiteralPath $analyzer -PathType Leaf)) {
    throw "Sentinel matrix analyzer does not exist: $analyzer"
}

$output = (
    & node $analyzer `
        --run-id $RunId `
        --results-directory $resultsRoot |
        Out-String
).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
    throw "Sentinel matrix analysis failed."
}

$output | ConvertFrom-Json
