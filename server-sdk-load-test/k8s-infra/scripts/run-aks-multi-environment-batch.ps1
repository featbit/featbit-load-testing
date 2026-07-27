[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^aks-featbit-load-testing$")]
    [string] $KubeContext,

    [Parameter(Mandatory)]
    [string] $RunnerImage,

    [string] $Note = "100 environments x 100 connections; target fan-out 100"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Select-ExperimentResult {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Output,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Description
    )

    $requiredProperties = @(
        "RunId",
        "TestRunName",
        "RunKind",
        "Passed",
        "BaselineRestored",
        "DeletedResources"
    )
    $matches = @(
        foreach ($candidate in @($Output)) {
            if ($null -eq $candidate) {
                continue
            }
            $hasAllProperties = $true
            foreach ($propertyName in $requiredProperties) {
                if ($null -eq $candidate.PSObject.Properties[$propertyName]) {
                    $hasAllProperties = $false
                    break
                }
            }
            if ($hasAllProperties) {
                $candidate
            }
        }
    )
    if ($matches.Count -ne 1) {
        throw (
            "$Description returned $($matches.Count) experiment result " +
            "objects; expected exactly one."
        )
    }
    return $matches[0]
}

$results = [Collections.Generic.List[object]]::new()

& (Join-Path $PSScriptRoot "ensure-aks-multi-environment-1s-evidence.ps1") `
    -KubeContext $KubeContext |
    Out-Host

$validationOutput = @(
    & (
        Join-Path $PSScriptRoot "run-aks-multi-environment-experiment.ps1"
    ) `
        -RunKind validation `
        -KubeContext $KubeContext `
        -RunnerImage $RunnerImage `
        -Note "$Note; validation"
)
$validation = Select-ExperimentResult `
    -Output $validationOutput `
    -Description "Validation experiment"
$results.Add($validation)
if ($validation.Passed -ne $true) {
    Write-Warning (
        "Validation '$($validation.RunId)' failed. No formal run was " +
        "submitted; all validation resources and evidence were preserved."
    )
    return [pscustomobject]@{
        Passed = $false
        ValidationPassed = $false
        FormalRunsCompleted = 0
        Runs = @($results)
        DeletedResources = 0
    }
}

foreach ($index in 1..3) {
    $formalOutput = @(
        & (
            Join-Path $PSScriptRoot "run-aks-multi-environment-experiment.ps1"
        ) `
            -RunKind formal `
            -KubeContext $KubeContext `
            -RunnerImage $RunnerImage `
            -Note "$Note; formal $index/3"
    )
    $formal = Select-ExperimentResult `
        -Output $formalOutput `
        -Description "Formal experiment $index"
    $results.Add($formal)
    if ($formal.BaselineRestored -ne $true) {
        Write-Warning (
            "Formal run '$($formal.RunId)' could not restore the measured " +
            "flag baseline. No further run was submitted."
        )
        break
    }
}

$summary = $null
if ($results.Count -eq 4) {
    $summary = & (
        Join-Path `
            $PSScriptRoot `
            "summarize-aks-multi-environment-runs.ps1"
    ) -RunIds @($results.RunId)
}

[pscustomobject]@{
    Passed = (
        $results.Count -eq 4 -and
        @($results | Where-Object Passed -ne $true).Count -eq 0
    )
    ValidationPassed = $true
    FormalRunsCompleted = $results.Count - 1
    Runs = @($results)
    Summary = $summary
    DeletedResources = 0
}
