[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateCount(4, 4)]
    [string[]] $RunIds,

    [string] $ResultsDirectory = "",

    [string] $OutputDirectory = "",

    [string] $OutputName = ""
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
$outputRoot = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path $repositoryRoot "results"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputDirectory
    )
}
$name = if ([string]::IsNullOrWhiteSpace($OutputName)) {
    "aks-10k-multi-environment-g5-d4-els3-{0}" -f `
        [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss")
}
else {
    $OutputName.Trim()
}
if ($name -notmatch "^[a-zA-Z0-9._-]+$") {
    throw "OutputName contains unsupported characters."
}

$analyzer = Join-Path `
    $PSScriptRoot `
    "summarize-aks-multi-environment-runs.mjs"
$output = (
    & node $analyzer `
        --run-ids ($RunIds -join ",") `
        --results-directory $resultsRoot `
        --output-directory $outputRoot `
        --output-name $name |
        Out-String
).Trim()
$exitCode = $LASTEXITCODE
if ([string]::IsNullOrWhiteSpace($output)) {
    throw "Multi-environment summary produced no result."
}
$result = $output | ConvertFrom-Json
if ($exitCode -eq 1) {
    throw "Multi-environment summary could not be completed."
}
if ($exitCode -eq 2 -or $result.passed -ne $true) {
    Write-Warning "One or more included runs failed a gate."
}
$result
