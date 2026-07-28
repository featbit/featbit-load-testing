[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^aks-featbit-load-testing$")]
    [string] $KubeContext,

    [Parameter(Mandatory)]
    [string] $MatrixPath,

    [string] $OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $FailureMessage
    )

    $text = (& az @Arguments --output json | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        throw $FailureMessage
    }
    return $text | ConvertFrom-Json
}

function Write-Evidence {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][object] $Value
    )

    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite node-pool evidence: $Path"
    }
    [IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 12) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-SanitizedPool {
    param([Parameter(Mandatory)][object] $Pool)

    return [ordered]@{
        name = [string]$Pool.name
        count = [int]$Pool.count
        vmSize = [string]$Pool.vmSize
        mode = [string]$Pool.mode
        provisioningState = [string]$Pool.provisioningState
        enableAutoScaling = [bool]$Pool.enableAutoScaling
        maxPods = [int]$Pool.maxPods
        nodeLabels = $Pool.nodeLabels
        nodeTaints = @($Pool.nodeTaints)
        osSku = [string]$Pool.osSku
    }
}

function Assert-PoolMatches {
    param(
        [Parameter(Mandatory)][object] $Actual,
        [Parameter(Mandatory)][object] $Expected
    )

    $workload = [string]$Actual.nodeLabels.workload
    if (
        [string]$Actual.name -cne [string]$Expected.name -or
        [int]$Actual.count -ne [int]$Expected.nodes -or
        [string]$Actual.vmSize -cne [string]$Expected.vmSize -or
        [string]$Actual.mode -cne "User" -or
        [string]$Actual.provisioningState -cne "Succeeded" -or
        [bool]$Actual.enableAutoScaling -or
        [int]$Actual.maxPods -ne [int]$Expected.maxPods -or
        $workload -cne [string]$Expected.workload -or
        @($Actual.nodeTaints | Where-Object {
            [string]$_ -ceq [string]$Expected.taint
        }).Count -ne 1
    ) {
        throw (
            "Existing AKS node pool '$([string]$Expected.name)' differs " +
            "from the immutable large-flagset matrix; it was not changed."
        )
    }
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext
$resourceGroup = "featbit-devtest"
$clusterName = "aks-featbit-load-testing"
$resolvedMatrixPath = (
    $ExecutionContext.SessionState.Path.
        GetUnresolvedProviderPathFromPSPath($MatrixPath)
)
if (-not (Test-Path -LiteralPath $resolvedMatrixPath -PathType Leaf)) {
    throw "Large flag-set matrix does not exist: $resolvedMatrixPath"
}
$matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath | ConvertFrom-Json
$additionalProperty = (
    $matrix.fixedInfrastructure.PSObject.Properties["additionalNodePools"]
)
if ($null -eq $additionalProperty) {
    [pscustomobject]@{
        MatrixId = [string]$matrix.matrixId
        Required = $false
        Changed = $false
        DeletedResources = 0
    }
    return
}
$expectedPools = @($additionalProperty.Value)
if (
    $expectedPools.Count -ne 2 -or
    @($expectedPools | Where-Object {
        [string]$_.name -notin @("loadgen3k", "els3k") -or
        [string]$_.vmSize -cne "Standard_D4ds_v5" -or
        [int]$_.nodes -lt 1
    }).Count -ne 0
) {
    throw "Matrix additional node pools are outside the explicit safe contract."
}

$testRunsText = (
    & kubectl --context $targetContext `
        -n $script:LoadTestNamespace `
        get testruns.k6.io `
        -o json |
        Out-String
)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($testRunsText)) {
    throw "Failed to verify that no AKS TestRun is active."
}
$activeTestRuns = @(
    ($testRunsText | ConvertFrom-Json).items |
        Where-Object { [string]$_.status.stage -notin @("finished", "error") }
)
if ($activeTestRuns.Count -gt 0) {
    throw (
        "Refusing to create node pools while TestRun(s) are active: " +
        (($activeTestRuns.metadata.name | Sort-Object) -join ", ")
    )
}

$cluster = Invoke-AzJson `
    -Arguments @(
        "aks", "show",
        "--resource-group", $resourceGroup,
        "--name", $clusterName
    ) `
    -FailureMessage "Failed to inspect the exact load-testing AKS cluster."
if (
    [string]$cluster.name -cne $clusterName -or
    [string]$cluster.resourceGroup -cne $resourceGroup -or
    [string]$cluster.provisioningState -cne "Succeeded"
) {
    throw "Azure CLI resolved an unexpected or unhealthy AKS cluster."
}

$existingPools = @(
    Invoke-AzJson `
        -Arguments @(
            "aks", "nodepool", "list",
            "--resource-group", $resourceGroup,
            "--cluster-name", $clusterName
        ) `
        -FailureMessage "Failed to inspect the exact AKS node pools."
)
$resultsRoot = Get-RepositoryRoot
$resultsDirectory = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path $resultsRoot "results"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputDirectory
    )
}
$null = New-Item -ItemType Directory -Force -Path $resultsDirectory
$changeId = "large-flagset-pools-{0}-{1}" -f `
    [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"), `
    [Guid]::NewGuid().ToString("N").Substring(0, 6)
$beforePath = Join-Path $resultsDirectory "$changeId-before.json"
$afterPath = Join-Path $resultsDirectory "$changeId-after.json"
Write-Evidence -Path $beforePath -Value ([ordered]@{
    schemaVersion = 1
    capturedAtUtc = [DateTime]::UtcNow.ToString("o")
    matrixId = [string]$matrix.matrixId
    cluster = [ordered]@{
        name = [string]$cluster.name
        resourceGroup = [string]$cluster.resourceGroup
        location = [string]$cluster.location
        nodeResourceGroup = [string]$cluster.nodeResourceGroup
    }
    pools = @($existingPools | ForEach-Object { Get-SanitizedPool -Pool $_ })
})

$missingPools = [Collections.Generic.List[object]]::new()
foreach ($expected in $expectedPools) {
    $matches = @($existingPools | Where-Object {
        [string]$_.name -ceq [string]$expected.name
    })
    if ($matches.Count -gt 1) {
        throw "AKS returned duplicate node pool '$([string]$expected.name)'."
    }
    if ($matches.Count -eq 1) {
        Assert-PoolMatches -Actual $matches[0] -Expected $expected
    }
    else {
        $missingPools.Add($expected)
    }
}

if ($missingPools.Count -gt 0) {
    $requiredVcpus = [int](
        @($missingPools | ForEach-Object { [int]$_.nodes * 4 }) |
            Measure-Object -Sum |
            Select-Object -ExpandProperty Sum
    )
    $usages = @(
        Invoke-AzJson `
            -Arguments @(
                "vm", "list-usage",
                "--location", [string]$cluster.location
            ) `
            -FailureMessage "Failed to inspect regional Azure vCPU quota."
    )
    $totalQuota = @($usages | Where-Object {
        [string]$_.name.value -ceq "cores"
    })
    $familyQuota = @($usages | Where-Object {
        [string]$_.name.value -ceq "standardDDSv5Family"
    })
    if ($totalQuota.Count -ne 1 -or $familyQuota.Count -ne 1) {
        throw "Could not resolve total and Standard DDSv5 vCPU quotas."
    }
    $totalAvailable = [int]$totalQuota[0].limit -
        [int]$totalQuota[0].currentValue
    $familyAvailable = [int]$familyQuota[0].limit -
        [int]$familyQuota[0].currentValue
    if (
        $totalAvailable -lt $requiredVcpus -or
        $familyAvailable -lt $requiredVcpus
    ) {
        throw (
            "Insufficient East Asia quota for the isolated profile: need " +
            "$requiredVcpus additional vCPU, total available=" +
            "$totalAvailable, Standard DDSv5 available=$familyAvailable. " +
            "No node pool was created; increase both quotas before retrying."
        )
    }
}

$created = [Collections.Generic.List[string]]::new()
foreach ($expected in $missingPools) {
    & az aks nodepool add `
        --resource-group $resourceGroup `
        --cluster-name $clusterName `
        --name ([string]$expected.name) `
        --node-count ([int]$expected.nodes) `
        --node-vm-size ([string]$expected.vmSize) `
        --max-pods ([int]$expected.maxPods) `
        --mode User `
        --labels "workload=$([string]$expected.workload)" `
        --node-taints ([string]$expected.taint) `
        --os-sku AzureLinux `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw (
            "Failed to create node pool '$([string]$expected.name)'. " +
            "Any successfully created earlier pool was preserved."
        )
    }
    $created.Add([string]$expected.name)
}

$updatedPools = @(
    Invoke-AzJson `
        -Arguments @(
            "aks", "nodepool", "list",
            "--resource-group", $resourceGroup,
            "--cluster-name", $clusterName
        ) `
        -FailureMessage "Failed to verify the exact AKS node pools."
)
foreach ($expected in $expectedPools) {
    $matches = @($updatedPools | Where-Object {
        [string]$_.name -ceq [string]$expected.name
    })
    if ($matches.Count -ne 1) {
        throw "Created node pool '$([string]$expected.name)' was not found."
    }
    Assert-PoolMatches -Actual $matches[0] -Expected $expected
}

Write-Evidence -Path $afterPath -Value ([ordered]@{
    schemaVersion = 1
    capturedAtUtc = [DateTime]::UtcNow.ToString("o")
    matrixId = [string]$matrix.matrixId
    createdPools = @($created)
    pools = @($updatedPools | ForEach-Object { Get-SanitizedPool -Pool $_ })
})

[pscustomobject]@{
    MatrixId = [string]$matrix.matrixId
    Required = $true
    Changed = $created.Count -gt 0
    CreatedPools = @($created)
    BeforePath = $beforePath
    AfterPath = $afterPath
    DeletedResources = 0
}
