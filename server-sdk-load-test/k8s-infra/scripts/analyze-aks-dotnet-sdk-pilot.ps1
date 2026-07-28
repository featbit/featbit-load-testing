[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RunDirectory
)

$ErrorActionPreference = "Stop"

$resolvedRunDirectory = (
    $ExecutionContext.SessionState.Path.
        GetUnresolvedProviderPathFromPSPath($RunDirectory)
)
if (-not (Test-Path -LiteralPath $resolvedRunDirectory -PathType Container)) {
    throw "Run directory does not exist: $resolvedRunDirectory"
}

& node (Join-Path $PSScriptRoot "analyze-aks-dotnet-sdk-pilot.mjs") `
    --run-dir $resolvedRunDirectory
if ($LASTEXITCODE -ne 0) {
    throw ".NET SDK pilot analysis failed with exit code $LASTEXITCODE."
}
