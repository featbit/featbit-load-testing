[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^growth-menv-(validation|formal)-[a-z0-9-]+$")]
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
$analyzer = Join-Path $PSScriptRoot "analyze-aks-multi-environment.mjs"
$output = (
    & node $analyzer `
        --run-id $RunId `
        --results-directory $resultsRoot |
        Out-String
).Trim()
$exitCode = $LASTEXITCODE
if ([string]::IsNullOrWhiteSpace($output)) {
    throw "Multi-environment analyzer produced no result."
}
$result = $output | ConvertFrom-Json
if ($exitCode -eq 1) {
    throw "Multi-environment analysis could not be completed."
}
if ($exitCode -eq 2 -or $result.passed -ne $true) {
    Write-Warning "Multi-environment run '$RunId' failed one or more gates."
}
$result
