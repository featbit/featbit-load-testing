[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunId,
    [string] $ResultsDirectory = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$repositoryRoot = Get-RepositoryRoot
$resolvedResultsDirectory = if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) {
    Join-Path $repositoryRoot "results"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $ResultsDirectory
    )
}
$analyzerPath = Join-Path $PSScriptRoot "analyze-aks-large-flagset.mjs"
$output = & node $analyzerPath `
    --run-id $RunId `
    --results-directory $resolvedResultsDirectory
$exitCode = $LASTEXITCODE
if ($exitCode -notin @(0, 2)) {
    throw "Large flag-set analyzer failed with exit code $exitCode."
}
$result = $output | Select-Object -Last 1 | ConvertFrom-Json
[pscustomobject]@{
    runId = [string]$result.runId
    passed = [bool]$result.passed
    jsonPath = [string]$result.jsonPath
    markdownPath = [string]$result.markdownPath
    htmlPath = [string]$result.htmlPath
    rampAssessment = $result.rampAssessment
    metrics = $result.metrics
}
