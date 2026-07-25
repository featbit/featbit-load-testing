[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^[a-z0-9-]+$")]
    [string] $RunId,

    [switch] $OpenReport
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

Assert-LocalKubernetesContext
Assert-KubernetesObjectExists -Kind "pod" -Name "results-reader"

$repositoryRoot = Get-RepositoryRoot
$resultsDirectory = Join-Path $repositoryRoot "results"
$null = New-Item -ItemType Directory -Force $resultsDirectory
$copiedFiles = @()

foreach ($suffix in @("summary.json", "report.html")) {
    $fileName = "$RunId-$suffix"
    $remotePath = "/results/$fileName"
    $localPath = Join-Path $resultsDirectory $fileName

    & kubectl `
        --context $script:LocalKubernetesContext `
        -n $script:LoadTestNamespace `
        exec results-reader -- test -f $remotePath *> $null

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Result file is not available yet: $fileName"
        continue
    }

    Push-Location $resultsDirectory
    try {
        & kubectl `
            --context $script:LocalKubernetesContext `
            -n $script:LoadTestNamespace `
            cp "results-reader:$remotePath" ".\$fileName"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to copy $fileName"
            continue
        }
    }
    finally {
        Pop-Location
    }

    $copiedFiles += $localPath
}

$testRunName = "featbit-$RunId"
$runnerJobName = "$testRunName-1"

Write-Host ""
Write-Host "Runner summary log:"
& kubectl `
    --context $script:LocalKubernetesContext `
    -n $script:LoadTestNamespace `
    logs "job/$runnerJobName"
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Runner Job logs are unavailable. The TestRun may still be running or may have been deleted."
}

Write-Host ""
if ($copiedFiles.Count -gt 0) {
    Write-Host "Collected result files:"
    $copiedFiles | ForEach-Object { Write-Host "- $_" }
}
else {
    Write-Warning "No JSON or HTML artifacts were collected."
}

$htmlReportPath = Join-Path $resultsDirectory "$RunId-report.html"
if ($OpenReport) {
    if (Test-Path $htmlReportPath) {
        Start-Process $htmlReportPath
    }
    else {
        Write-Warning "HTML report does not exist locally: $htmlReportPath"
    }
}
