[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^aks-featbit-load-testing$")]
    [string] $KubeContext,

    [Parameter(Mandatory)]
    [string] $MatrixPath,

    [string] $OutputDirectory = "",

    [switch] $CheckOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Read-KubectlJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $FailureMessage
    )

    $text = (& kubectl @Arguments | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        throw $FailureMessage
    }
    return $text | ConvertFrom-Json
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Content
    )

    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite ELS profile evidence: $Path"
    }
    [IO.File]::WriteAllText(
        $Path,
        $Content,
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-ElsContainer {
    param([Parameter(Mandatory)][object] $Deployment)

    $containers = @(
        $Deployment.spec.template.spec.containers |
            Where-Object name -eq "featbit-els"
    )
    if ($containers.Count -ne 1) {
        throw "Expected exactly one 'featbit-els' container."
    }
    return $containers[0]
}

function Convert-Resources {
    param([Parameter(Mandatory)][object] $Resources)

    return [ordered]@{
        cpuRequest = [string]$Resources.requests.cpu
        cpuLimit = [string]$Resources.limits.cpu
        memoryRequest = [string]$Resources.requests.memory
        memoryLimit = [string]$Resources.limits.memory
    }
}

function Test-ResourcesEqual {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Actual,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected
    )

    return (
        $Actual.cpuRequest -ceq $Expected.cpuRequest -and
        $Actual.cpuLimit -ceq $Expected.cpuLimit -and
        $Actual.memoryRequest -ceq $Expected.memoryRequest -and
        $Actual.memoryLimit -ceq $Expected.memoryLimit
    )
}

function Get-ElsPlacementWorkload {
    param([Parameter(Mandatory)][object] $Deployment)

    $workloadProperty = (
        $Deployment.spec.template.spec.nodeSelector.PSObject.Properties[
            "workload"
        ]
    )
    if ($null -eq $workloadProperty) {
        throw "ELS Deployment has no explicit workload node selector."
    }
    return [string]$workloadProperty.Value
}

function Test-ElsPlacementToleration {
    param(
        [Parameter(Mandatory)][object] $Deployment,
        [Parameter(Mandatory)][string] $Workload
    )

    return @($Deployment.spec.template.spec.tolerations | Where-Object {
        [string]$_.key -ceq "workload" -and
        [string]$_.operator -ceq "Equal" -and
        [string]$_.value -ceq $Workload -and
        [string]$_.effect -ceq "NoSchedule"
    }).Count -eq 1
}

function Get-SanitizedSnapshot {
    param(
        [Parameter(Mandatory)][object] $Deployment,
        [Parameter(Mandatory)][object[]] $Pods,
        [Parameter(Mandatory)][string] $MatrixId
    )

    $container = Get-ElsContainer -Deployment $Deployment
    return [ordered]@{
        schemaVersion = 1
        capturedAtUtc = [DateTime]::UtcNow.ToString("o")
        matrixId = $MatrixId
        deployment = [ordered]@{
            name = [string]$Deployment.metadata.name
            namespace = [string]$Deployment.metadata.namespace
            uid = [string]$Deployment.metadata.uid
            generation = [int64]$Deployment.metadata.generation
            replicas = [int]$Deployment.spec.replicas
            readyReplicas = [int]$Deployment.status.readyReplicas
            image = [string]$container.image
            resources = Convert-Resources -Resources $container.resources
            placementWorkload = Get-ElsPlacementWorkload `
                -Deployment $Deployment
        }
        pods = @(
            $Pods |
                Sort-Object { $_.metadata.name } |
                ForEach-Object {
                    [ordered]@{
                        name = [string]$_.metadata.name
                        uid = [string]$_.metadata.uid
                        node = [string]$_.spec.nodeName
                        phase = [string]$_.status.phase
                        ready = [bool]$_.status.containerStatuses[0].ready
                        restarts = [int](
                            $_.status.containerStatuses[0].restartCount
                        )
                    }
                }
        )
    }
}

function Invoke-ElsDeploymentPatch {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Patch,
        [Parameter(Mandatory)][string] $FailureMessage
    )

    $patchJson = $Patch | ConvertTo-Json -Depth 12 -Compress
    & kubectl --context $script:targetContext `
        -n featbit `
        patch deployment featbit-els `
        --type strategic `
        -p $patchJson |
        Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

$targetContext = $KubeContext.Trim()
$script:targetContext = $targetContext
Assert-KubernetesContext -KubeContext $targetContext
$repositoryRoot = Get-RepositoryRoot
$pathProvider = $ExecutionContext.SessionState.Path
$resolvedMatrixPath = $pathProvider.GetUnresolvedProviderPathFromPSPath(
    $MatrixPath
)
if (-not (Test-Path -LiteralPath $resolvedMatrixPath -PathType Leaf)) {
    throw "Large flag-set matrix does not exist: $resolvedMatrixPath"
}
$matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath | ConvertFrom-Json
if (
    $matrix.schemaVersion -ne 1 -or
    [string]$matrix.kubernetesContext -cne $targetContext -or
    [int]$matrix.fixedInfrastructure.elsReplicas -ne 3 -or
    [int]$matrix.flagCount -ne 3000 -or
    [int]$matrix.totalConnections -ne 10000
) {
    throw "Matrix is not a supported 3,000-flag AKS ELS profile."
}

$targetResources = [ordered]@{
    cpuRequest = [string](
        $matrix.fixedInfrastructure.elsResources.cpuRequest
    )
    cpuLimit = [string]$matrix.fixedInfrastructure.elsResources.cpuLimit
    memoryRequest = [string](
        $matrix.fixedInfrastructure.elsResources.memoryRequest
    )
    memoryLimit = [string](
        $matrix.fixedInfrastructure.elsResources.memoryLimit
    )
}
$elsPlacementProperty = (
    $matrix.fixedInfrastructure.PSObject.Properties["elsPlacement"]
)
$targetPlacementWorkload = if ($null -eq $elsPlacementProperty) {
    "featbit"
}
else {
    [string]$elsPlacementProperty.Value.nodeWorkload
}
if ($targetPlacementWorkload -notin @("featbit", "els3k")) {
    throw "Matrix ELS placement is not one of the explicit workload pools."
}
$allowedProfiles = @(
    [ordered]@{
        cpuRequest = "500m"
        cpuLimit = "1"
        memoryRequest = "256Mi"
        memoryLimit = "512Mi"
    },
    [ordered]@{
        cpuRequest = "1"
        cpuLimit = "3"
        memoryRequest = "2Gi"
        memoryLimit = "8Gi"
    },
    [ordered]@{
        cpuRequest = "2"
        cpuLimit = "4"
        memoryRequest = "8Gi"
        memoryLimit = "12Gi"
    }
)
if (
    @(
        $allowedProfiles |
            Where-Object {
                Test-ResourcesEqual -Actual $_ -Expected $targetResources
            }
    ).Count -ne 1
) {
    throw "Matrix ELS resources are not one of the three explicit profiles."
}

$testRuns = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit-loadtest",
        "get", "testruns.k6.io",
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect existing TestRuns."
$activeTestRuns = @(
    $testRuns.items |
        Where-Object { [string]$_.status.stage -notin @("finished", "error") }
)
if ($activeTestRuns.Count -gt 0) {
    throw (
        "Refusing to change ELS resources while TestRun(s) are active: " +
        (($activeTestRuns.metadata.name | Sort-Object) -join ", ")
    )
}

$deployment = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit",
        "get", "deployment", "featbit-els",
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect the ELS deployment."
$podsDocument = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit",
        "get", "pods",
        "-l", "app.kubernetes.io/component=els",
        "-o", "json"
    ) `
    -FailureMessage "Failed to inspect the ELS Pods."
$pods = @($podsDocument.items)
$container = Get-ElsContainer -Deployment $deployment
$originalImage = [string]$container.image
$originalReplicas = [int]$deployment.spec.replicas
$originalStrategyType = [string]$deployment.spec.strategy.type
$originalMaxSurge = [string](
    $deployment.spec.strategy.rollingUpdate.maxSurge
)
$originalMaxUnavailable = [string](
    $deployment.spec.strategy.rollingUpdate.maxUnavailable
)
$currentResources = Convert-Resources -Resources $container.resources
$currentPlacementWorkload = Get-ElsPlacementWorkload `
    -Deployment $deployment
if ($originalReplicas -ne 3) {
    throw "ELS replicas must remain exactly 3."
}
if (
    @(
        $allowedProfiles |
            Where-Object {
                Test-ResourcesEqual -Actual $_ -Expected $currentResources
            }
    ).Count -ne 1
) {
    throw "Current ELS resources are not an explicit known profile."
}
if (
    $currentPlacementWorkload -notin @("featbit", "els3k") -or
    -not (
        Test-ElsPlacementToleration `
            -Deployment $deployment `
            -Workload $currentPlacementWorkload
    )
) {
    throw "Current ELS placement is not an explicit known profile."
}

$resultsDirectory = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path $repositoryRoot "results"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputDirectory
    )
}
$null = New-Item -ItemType Directory -Force -Path $resultsDirectory
$changeId = "els-profile-{0}-{1}" -f `
    [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"), `
    [Guid]::NewGuid().ToString("N").Substring(0, 6)
$beforePath = Join-Path $resultsDirectory "$changeId-before.json"
$afterPath = Join-Path $resultsDirectory "$changeId-after.json"
$before = Get-SanitizedSnapshot `
    -Deployment $deployment `
    -Pods $pods `
    -MatrixId ([string]$matrix.matrixId)
Write-Utf8NoBom `
    -Path $beforePath `
    -Content (($before | ConvertTo-Json -Depth 12) + "`n")

$alreadyApplied = Test-ResourcesEqual `
    -Actual $currentResources `
    -Expected $targetResources
$alreadyApplied = (
    $alreadyApplied -and
    $currentPlacementWorkload -ceq $targetPlacementWorkload
)
if ($CheckOnly -or $alreadyApplied) {
    [pscustomobject]@{
        ChangeId = $changeId
        MatrixId = [string]$matrix.matrixId
        Changed = $false
        CheckOnly = $CheckOnly.IsPresent
        AlreadyApplied = $alreadyApplied
        BeforePath = $beforePath
        AfterPath = ""
        Resources = [pscustomobject]$currentResources
        PlacementWorkload = $currentPlacementWorkload
        DeletedResources = 0
    }
    return
}

$patch = [ordered]@{
    spec = [ordered]@{
        template = [ordered]@{
            metadata = [ordered]@{
                annotations = [ordered]@{
                    "loadtest.featbit.io/els-resource-profile" = (
                        [string]$matrix.matrixId
                    )
                }
            }
            spec = [ordered]@{
                nodeSelector = [ordered]@{
                    workload = $targetPlacementWorkload
                }
                tolerations = @(
                    [ordered]@{
                        key = "workload"
                        operator = "Equal"
                        value = $targetPlacementWorkload
                        effect = "NoSchedule"
                    }
                )
                containers = @(
                    [ordered]@{
                        name = "featbit-els"
                        resources = [ordered]@{
                            requests = [ordered]@{
                                cpu = $targetResources.cpuRequest
                                memory = $targetResources.memoryRequest
                            }
                            limits = [ordered]@{
                                cpu = $targetResources.cpuLimit
                                memory = $targetResources.memoryLimit
                            }
                        }
                    }
                )
            }
        }
    }
}
$requiredAntiAffinity = @(
    $deployment.spec.template.spec.affinity.podAntiAffinity.
        requiredDuringSchedulingIgnoredDuringExecution
).Count -gt 0
$temporaryStrategyRequired = (
    $requiredAntiAffinity -and
    $originalReplicas -gt 1 -and
    $originalMaxSurge -cne "0"
)
$strategyTemporarilyChanged = $false
try {
    if ($temporaryStrategyRequired) {
        Invoke-ElsDeploymentPatch `
            -Patch ([ordered]@{
                spec = [ordered]@{
                    strategy = [ordered]@{
                        type = "RollingUpdate"
                        rollingUpdate = [ordered]@{
                            maxSurge = 0
                            maxUnavailable = 1
                        }
                    }
                }
            }) `
            -FailureMessage (
                "Failed to set the temporary one-at-a-time ELS rollout " +
                "strategy."
            )
        $strategyTemporarilyChanged = $true
    }

    Invoke-ElsDeploymentPatch `
        -Patch $patch `
        -FailureMessage "Failed to apply the ELS resource profile."
    & kubectl --context $targetContext `
        -n featbit `
        rollout status deployment/featbit-els `
        --timeout=10m |
        Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "ELS did not complete its resource-profile rollout."
    }
}
finally {
    if ($strategyTemporarilyChanged) {
        Invoke-ElsDeploymentPatch `
            -Patch ([ordered]@{
                spec = [ordered]@{
                    strategy = [ordered]@{
                        type = $originalStrategyType
                        rollingUpdate = [ordered]@{
                            maxSurge = $originalMaxSurge
                            maxUnavailable = $originalMaxUnavailable
                        }
                    }
                }
            }) `
            -FailureMessage (
                "ELS resources rolled out, but restoring the original " +
                "deployment strategy failed."
            )
    }
}

$updatedDeployment = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit",
        "get", "deployment", "featbit-els",
        "-o", "json"
    ) `
    -FailureMessage "Failed to verify the updated ELS deployment."
$updatedPodsDocument = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit",
        "get", "pods",
        "-l", "app.kubernetes.io/component=els",
        "-o", "json"
    ) `
    -FailureMessage "Failed to verify the updated ELS Pods."
$updatedPods = @($updatedPodsDocument.items)
$updatedContainer = Get-ElsContainer -Deployment $updatedDeployment
$updatedResources = Convert-Resources -Resources $updatedContainer.resources
$updatedPlacementWorkload = Get-ElsPlacementWorkload `
    -Deployment $updatedDeployment
$readyPods = @(
    $updatedPods |
        Where-Object {
            $_.status.phase -eq "Running" -and
            $_.status.containerStatuses[0].ready -eq $true
        }
)
$readyNodes = @($readyPods.spec.nodeName | Sort-Object -Unique)
$nodeDocument = Read-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "get", "nodes",
        "-o", "json"
    ) `
    -FailureMessage "Failed to verify ELS placement node labels."
$nodesByName = @{}
foreach ($node in $nodeDocument.items) {
    $nodesByName[[string]$node.metadata.name] = $node
}
$wrongPlacementPods = @($readyPods | Where-Object {
    $nodeName = [string]$_.spec.nodeName
    -not $nodesByName.ContainsKey($nodeName) -or
    [string]$nodesByName[$nodeName].metadata.labels.workload -cne
        $targetPlacementWorkload
})
if (
    [string]$updatedContainer.image -cne $originalImage -or
    [int]$updatedDeployment.spec.replicas -ne $originalReplicas -or
    [string]$updatedDeployment.spec.strategy.type -cne
        $originalStrategyType -or
    [string]$updatedDeployment.spec.strategy.rollingUpdate.maxSurge -cne
        $originalMaxSurge -or
    [string]$updatedDeployment.spec.strategy.rollingUpdate.maxUnavailable -cne
        $originalMaxUnavailable -or
    [int]$updatedDeployment.status.readyReplicas -ne 3 -or
    -not (Test-ResourcesEqual `
        -Actual $updatedResources `
        -Expected $targetResources) -or
    $updatedPlacementWorkload -cne $targetPlacementWorkload -or
    -not (
        Test-ElsPlacementToleration `
            -Deployment $updatedDeployment `
            -Workload $targetPlacementWorkload
    ) -or
    $readyPods.Count -ne 3 -or
    $readyNodes.Count -ne 3 -or
    $wrongPlacementPods.Count -ne 0
) {
    throw "ELS resource-profile verification failed."
}

$after = Get-SanitizedSnapshot `
    -Deployment $updatedDeployment `
    -Pods $updatedPods `
    -MatrixId ([string]$matrix.matrixId)
Write-Utf8NoBom `
    -Path $afterPath `
    -Content (($after | ConvertTo-Json -Depth 12) + "`n")

[pscustomobject]@{
    ChangeId = $changeId
    MatrixId = [string]$matrix.matrixId
    Changed = $true
    CheckOnly = $false
    AlreadyApplied = $false
    BeforePath = $beforePath
    AfterPath = $afterPath
    Resources = [pscustomobject]$updatedResources
    PlacementWorkload = $updatedPlacementWorkload
    Image = $originalImage
    Replicas = $originalReplicas
    ReadyPods = $readyPods.Count
    ReadyNodes = $readyNodes.Count
    DeletedResources = 0
}
