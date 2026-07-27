[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $KubeContext,

    [string] $ApiUrl = "http://127.0.0.1:15000",

    [string] $MatrixPath = "",

    [string] $InventoryOutputPath = "",

    [ValidateRange(1, 20)]
    [int] $RequestThrottleLimit = 4
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Normalize-ApiUrl {
    param([Parameter(Mandatory)][string] $Value)

    $normalized = $Value.Trim().TrimEnd("/")
    if ($normalized -notmatch "^https?://") {
        throw "ApiUrl must start with http:// or https://."
    }
    if ($normalized.Contains("?")) {
        throw "ApiUrl must not contain query parameters."
    }
    return $normalized
}

function Invoke-FeatBitRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("GET", "POST")]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [hashtable] $Headers,

        [object] $Body
    )

    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = $Headers
        TimeoutSec = 30
    }
    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = $Body | ConvertTo-Json -Depth 12 -Compress
    }

    try {
        $response = Invoke-RestMethod @parameters
    }
    catch {
        $statusCode = $null
        $responseProperty = $_.Exception.PSObject.Properties["Response"]
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            $statusProperty = $responseProperty.Value.PSObject.Properties["StatusCode"]
            if ($null -ne $statusProperty) {
                $statusCode = [int]$statusProperty.Value
            }
        }
        if ($null -ne $statusCode) {
            throw "FeatBit API request failed with HTTP $statusCode at '$Uri'."
        }
        throw "FeatBit API request failed at '$Uri': $($_.Exception.Message)"
    }

    if ($response.success -ne $true) {
        $details = @($response.errors | ForEach-Object {
            $code = $_.PSObject.Properties["code"]
            $message = $_.PSObject.Properties["message"]
            if ($null -ne $code) {
                [string]$code.Value
            }
            elseif ($null -ne $message) {
                [string]$message.Value
            }
            else {
                "unspecified FeatBit API error"
            }
        }) -join "; "
        throw "FeatBit API rejected '$Uri': $details"
    }
    return $response.data
}

function Assert-NoActiveLoadTest {
    param([Parameter(Mandatory)][string] $Context)

    $text = (
        & kubectl --context $Context `
            -n $script:LoadTestNamespace `
            get testruns.k6.io `
            -o json |
            Out-String
    )
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        throw "Failed to inspect existing TestRuns."
    }
    $active = @(($text | ConvertFrom-Json).items | Where-Object {
        [string]$_.status.stage -notin @("finished", "error")
    })
    if ($active.Count -gt 0) {
        throw (
            "Refusing to prepare resources while TestRun(s) are active: " +
            (($active.metadata.name | Sort-Object) -join ", ")
        )
    }
}

function Get-ExpectedEnvironment {
    param(
        [Parameter(Mandatory)][object] $Matrix,
        [Parameter(Mandatory)][int] $Index
    )

    return [ordered]@{
        index = $Index
        key = "{0}{1:D3}" -f [string]$Matrix.environmentPrefix, $Index
        name = "{0}{1:D3}" -f [string]$Matrix.environmentNamePrefix, $Index
        description = [string]$Matrix.environmentDescription
    }
}

function Assert-EnvironmentConfiguration {
    param(
        [Parameter(Mandatory)][object] $Environment,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)][string] $ProjectId
    )

    if (
        [string]$Environment.key -cne [string]$Expected.key -or
        [string]$Environment.name -cne [string]$Expected.name -or
        [string]$Environment.description -cne [string]$Expected.description -or
        [string]$Environment.projectId -cne $ProjectId
    ) {
        throw (
            "Environment '$($Expected.key)' exists but its name, description, " +
            "or project ownership differs from the experiment contract."
        )
    }

    $serverSecrets = @($Environment.secrets | Where-Object {
        [string]$_.type -ieq "server" -and
        -not [string]::IsNullOrWhiteSpace([string]$_.value)
    })
    if ($serverSecrets.Count -ne 1) {
        throw (
            "Environment '$($Expected.key)' must expose exactly one non-empty " +
            "Server SDK secret; found $($serverSecrets.Count)."
        )
    }
    return [string]$serverSecrets[0].value
}

function Get-ExpectedFlag {
    param(
        [Parameter(Mandatory)][object] $Matrix,
        [Parameter(Mandatory)][int] $Index
    )

    return [ordered]@{
        index = $Index
        key = "{0}{1:D2}" -f [string]$Matrix.flagPrefix, $Index
        name = "{0}{1:D2}" -f [string]$Matrix.flagNamePrefix, $Index
        description = [string]$Matrix.flagDescription
    }
}

function Get-FlagsByPrefix {
    param(
        [Parameter(Mandatory)][string] $FeatureFlagsUrl,
        [Parameter(Mandatory)][hashtable] $Headers,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][bool] $Archived
    )

    $encodedPrefix = [Uri]::EscapeDataString($Prefix)
    $archivedValue = $Archived.ToString().ToLowerInvariant()
    $page = Invoke-FeatBitRequest `
        -Method GET `
        -Uri (
            "${FeatureFlagsUrl}?Name=$encodedPrefix&IsArchived=$archivedValue" +
            "&PageIndex=0&PageSize=100"
        ) `
        -Headers $Headers
    return @($page.items | Where-Object {
        ([string]$_.key).StartsWith($Prefix, [StringComparison]::Ordinal)
    })
}

function New-CanonicalFlagPayload {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)][string[]] $RevisionValues
    )

    $baselineId = [Guid]::NewGuid().ToString()
    $variations = @(
        [ordered]@{
            id = $baselineId
            name = "Baseline"
            value = "baseline"
        }
        for ($offset = 0; $offset -lt $RevisionValues.Count; $offset += 1) {
            [ordered]@{
                id = [Guid]::NewGuid().ToString()
                name = "Revision {0:D3}" -f ($offset + 1)
                value = $RevisionValues[$offset]
            }
        }
    )
    return [ordered]@{
        name = [string]$Expected.name
        key = [string]$Expected.key
        isEnabled = $true
        description = [string]$Expected.description
        variationType = "string"
        variations = $variations
        enabledVariationId = $baselineId
        disabledVariationId = $baselineId
        tags = @("load-test", "streaming-probe", "sdk-menv-g5-v1")
    }
}

function New-CanonicalFlag {
    param(
        [Parameter(Mandatory)][string] $FeatureFlagsUrl,
        [Parameter(Mandatory)][hashtable] $Headers,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)][string[]] $RevisionValues
    )

    $payload = New-CanonicalFlagPayload `
        -Expected $Expected `
        -RevisionValues $RevisionValues
    return Invoke-FeatBitRequest `
        -Method POST `
        -Uri $FeatureFlagsUrl `
        -Headers $Headers `
        -Body $payload
}

function Assert-CanonicalFlag {
    param(
        [Parameter(Mandatory)][object] $Flag,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)][string[]] $RevisionValues
    )

    if (
        [string]$Flag.key -cne [string]$Expected.key -or
        [string]$Flag.name -cne [string]$Expected.name -or
        [string]$Flag.description -cne [string]$Expected.description
    ) {
        throw (
            "Flag '$($Expected.key)' exists but its name or ownership " +
            "description differs from the experiment contract."
        )
    }
    if (
        $Flag.isArchived -eq $true -or
        $Flag.isEnabled -ne $true -or
        [string]$Flag.variationType -cne "string" -or
        @($Flag.targetUsers).Count -ne 0 -or
        @($Flag.rules).Count -ne 0
    ) {
        throw (
            "Flag '$($Expected.key)' must be active, enabled, string-valued, " +
            "and have no targeting rules."
        )
    }

    $expectedValues = @("baseline") + @($RevisionValues)
    $actualValues = @($Flag.variations | ForEach-Object {
        [string]$_.value
    })
    if (
        $actualValues.Count -ne $expectedValues.Count -or
        @(Compare-Object `
            -ReferenceObject ($expectedValues | Sort-Object) `
            -DifferenceObject ($actualValues | Sort-Object)).Count -ne 0
    ) {
        throw "Flag '$($Expected.key)' has non-canonical variation values."
    }
    if (@($actualValues | Sort-Object -Unique).Count -ne $actualValues.Count) {
        throw "Flag '$($Expected.key)' has duplicate variation values."
    }

    $baseline = @($Flag.variations | Where-Object {
        [string]$_.value -ceq "baseline"
    })
    $served = @($Flag.fallthrough.variations)
    if (
        $baseline.Count -ne 1 -or
        $served.Count -ne 1 -or
        [string]$served[0].id -cne [string]$baseline[0].id -or
        @($served[0].rollout).Count -ne 2 -or
        [double]$served[0].rollout[0] -ne 0 -or
        [double]$served[0].rollout[1] -ne 1 -or
        [string]$Flag.disabledVariationId -cne [string]$baseline[0].id
    ) {
        throw "Flag '$($Expected.key)' must serve baseline to 100 percent."
    }

    $requiredTags = @("load-test", "streaming-probe", "sdk-menv-g5-v1")
    $actualTags = @($Flag.tags | ForEach-Object { [string]$_ })
    if (@(Compare-Object `
        -ReferenceObject ($requiredTags | Sort-Object) `
        -DifferenceObject ($actualTags | Sort-Object)).Count -ne 0) {
        throw "Flag '$($Expected.key)' does not have the experiment ownership tags."
    }
}

function Get-OwnedKubernetesObject {
    param(
        [Parameter(Mandatory)][string] $Context,
        [Parameter(Mandatory)][string] $Kind,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $ExperimentId
    )

    $text = (
        & kubectl --context $Context `
            -n $script:LoadTestNamespace `
            get $Kind $Name `
            -o json 2>$null |
            Out-String
    )
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    $object = $text | ConvertFrom-Json
    $owner = [string]$object.metadata.labels."loadtest.featbit.io/experiment"
    if ($owner -cne $ExperimentId) {
        throw (
            "Refusing to replace existing $Kind/$Name because it is not " +
            "owned by experiment '$ExperimentId'."
        )
    }
    return $object
}

function Test-KubernetesDataEqual {
    param(
        [Parameter(Mandatory)][object] $Actual,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected
    )

    $actualProperties = @($Actual.PSObject.Properties)
    if ($actualProperties.Count -ne $Expected.Count) {
        return $false
    }
    foreach ($entry in $Expected.GetEnumerator()) {
        $property = $Actual.PSObject.Properties[[string]$entry.Key]
        if (
            $null -eq $property -or
            [string]$property.Value -cne [string]$entry.Value
        ) {
            return $false
        }
    }
    return $true
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext
if ($targetContext -cne "aks-featbit-load-testing") {
    throw "This experiment is fixed to context 'aks-featbit-load-testing'."
}
Assert-NoActiveLoadTest -Context $targetContext
Assert-KubernetesObjectExists `
    -Kind "secret" `
    -Name "featbit-k6-controller-secret" `
    -KubeContext $targetContext

$repositoryRoot = Get-RepositoryRoot
$resolvedMatrixPath = if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
    Join-Path $repositoryRoot "k8s-infra\matrices\aks-multi-environment-g5-d4-els3.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MatrixPath)
}
if (-not (Test-Path -LiteralPath $resolvedMatrixPath -PathType Leaf)) {
    throw "Matrix does not exist: $resolvedMatrixPath"
}
$matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath | ConvertFrom-Json
if (
    $matrix.schemaVersion -ne 1 -or
    [string]$matrix.kubernetesContext -cne $targetContext -or
    [int]$matrix.environmentCount -ne 100 -or
    [int]$matrix.flagCountPerEnvironment -ne 20
) {
    throw "Matrix does not match the fixed 100-environment / 20-flag contract."
}

$revisionValues = @($matrix.expectedRevisions | ForEach-Object {
    [string]$_
})
if (
    $revisionValues.Count -ne 10 -or
    @($revisionValues | Sort-Object -Unique).Count -ne 10 -or
    $revisionValues -contains "baseline"
) {
    throw "Matrix must contain ten unique non-baseline revisions."
}

$normalizedApiUrl = Normalize-ApiUrl -Value $ApiUrl
$encodedToken = (
    & kubectl --context $targetContext `
        -n $script:LoadTestNamespace `
        get secret featbit-k6-controller-secret `
        -o jsonpath='{.data.FEATBIT_API_ACCESS_TOKEN}' |
        Out-String
).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($encodedToken)) {
    throw "Unable to read the existing controller token."
}

$plainToken = $null
$headers = $null
try {
    $plainToken = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($encodedToken)
    )
    if ([string]::IsNullOrWhiteSpace($plainToken)) {
        throw "The existing controller token is empty."
    }
    $headers = @{ Authorization = $plainToken; Accept = "application/json" }

    $projects = @(Invoke-FeatBitRequest `
        -Method GET `
        -Uri "$normalizedApiUrl/api/v1/projects" `
        -Headers $headers)
    $matchingProjects = @($projects | Where-Object {
        [string]$_.key -ceq [string]$matrix.projectKey
    })
    if ($matchingProjects.Count -ne 1) {
        throw (
            "Project key '$($matrix.projectKey)' was not found uniquely; " +
            "found $($matchingProjects.Count)."
        )
    }
    $project = $matchingProjects[0]
    $projectId = [string]$project.id
    $desiredEnvironments = @(
        1..([int]$matrix.environmentCount) | ForEach-Object {
            Get-ExpectedEnvironment -Matrix $matrix -Index $_
        }
    )
    $desiredEnvironmentKeys = @($desiredEnvironments.key)
    $prefixedEnvironments = @($project.environments | Where-Object {
        ([string]$_.key).StartsWith(
            [string]$matrix.environmentPrefix,
            [StringComparison]::Ordinal
        )
    })
    $extraEnvironmentKeys = @($prefixedEnvironments | Where-Object {
        [string]$_.key -cnotin $desiredEnvironmentKeys
    } | ForEach-Object { [string]$_.key })
    if ($extraEnvironmentKeys.Count -gt 0) {
        throw (
            "Unexpected environment(s) use the experiment prefix: " +
            ($extraEnvironmentKeys -join ", ")
        )
    }

    $createdEnvironmentCount = 0
    $createdFlagCount = 0
    $reusedEnvironmentCount = 0
    $reusedFlagCount = 0
    $secretRows = [Collections.Generic.List[object]]::new()
    $inventoryRows = [Collections.Generic.List[object]]::new()
    $expectedFlags = @(
        1..([int]$matrix.flagCountPerEnvironment) | ForEach-Object {
            Get-ExpectedFlag -Matrix $matrix -Index $_
        }
    )
    $desiredFlagKeys = @($expectedFlags.key)

    foreach ($expectedEnvironment in $desiredEnvironments) {
        $matches = @($prefixedEnvironments | Where-Object {
            [string]$_.key -ceq [string]$expectedEnvironment.key
        })
        if ($matches.Count -gt 1) {
            throw "Environment '$($expectedEnvironment.key)' is not unique."
        }
        if ($matches.Count -eq 0) {
            $null = Invoke-FeatBitRequest `
                -Method POST `
                -Uri "$normalizedApiUrl/api/v1/projects/$projectId/envs" `
                -Headers $headers `
                -Body ([ordered]@{
                    name = [string]$expectedEnvironment.name
                    key = [string]$expectedEnvironment.key
                    description = [string]$expectedEnvironment.description
                })
            $projectDetail = Invoke-FeatBitRequest `
                -Method GET `
                -Uri "$normalizedApiUrl/api/v1/projects/$projectId" `
                -Headers $headers
            $createdMatches = @($projectDetail.environments | Where-Object {
                [string]$_.key -ceq [string]$expectedEnvironment.key
            })
            if ($createdMatches.Count -ne 1) {
                throw (
                    "Created environment '$($expectedEnvironment.key)' could " +
                    "not be rediscovered uniquely."
                )
            }
            $environment = $createdMatches[0]
            $createdEnvironmentCount += 1
            $prefixedEnvironments += $environment
        }
        else {
            $environment = $matches[0]
            $reusedEnvironmentCount += 1
        }

        $serverSecret = Assert-EnvironmentConfiguration `
            -Environment $environment `
            -Expected $expectedEnvironment `
            -ProjectId $projectId
        $environmentId = [string]$environment.id
        $featureFlagsUrl = "$normalizedApiUrl/api/v1/envs/$environmentId/feature-flags"
        $activeFlags = @(Get-FlagsByPrefix `
            -FeatureFlagsUrl $featureFlagsUrl `
            -Headers $headers `
            -Prefix ([string]$matrix.flagPrefix) `
            -Archived $false)
        $archivedFlags = @(Get-FlagsByPrefix `
            -FeatureFlagsUrl $featureFlagsUrl `
            -Headers $headers `
            -Prefix ([string]$matrix.flagPrefix) `
            -Archived $true)
        if ($archivedFlags.Count -gt 0) {
            throw (
                "Environment '$($expectedEnvironment.key)' contains archived " +
                "flags under the experiment prefix; refusing to delete or replace them."
            )
        }
        $extraFlagKeys = @($activeFlags | Where-Object {
            [string]$_.key -cnotin $desiredFlagKeys
        } | ForEach-Object { [string]$_.key })
        if ($extraFlagKeys.Count -gt 0) {
            throw (
                "Environment '$($expectedEnvironment.key)' contains unexpected " +
                "experiment-prefixed flags: $($extraFlagKeys -join ', ')."
            )
        }

        $missingFlags = [Collections.Generic.List[object]]::new()
        foreach ($expectedFlag in $expectedFlags) {
            $flagMatches = @($activeFlags | Where-Object {
                [string]$_.key -ceq [string]$expectedFlag.key
            })
            if ($flagMatches.Count -gt 1) {
                throw (
                    "Flag '$($expectedFlag.key)' is not unique in environment " +
                    "'$($expectedEnvironment.key)'."
                )
            }
            if ($flagMatches.Count -eq 0) {
                $missingFlags.Add($expectedFlag)
            }
            else {
                $reusedFlagCount += 1
            }
        }

        $createRequests = @($missingFlags | ForEach-Object {
            [pscustomobject]@{
                key = [string]$_.key
                body = (
                    New-CanonicalFlagPayload `
                        -Expected $_ `
                        -RevisionValues $revisionValues |
                        ConvertTo-Json -Depth 12 -Compress
                )
            }
        })
        if ($createRequests.Count -gt 0) {
            $createdKeys = @(
                $createRequests |
                    ForEach-Object -Parallel {
                        $ErrorActionPreference = "Stop"
                        $request = $_
                        $requestHeaders = @{
                            Authorization = $using:plainToken
                            Accept = "application/json"
                        }
                        try {
                            $response = Invoke-RestMethod `
                                -Method POST `
                                -Uri $using:featureFlagsUrl `
                                -Headers $requestHeaders `
                                -ContentType "application/json" `
                                -Body $request.body `
                                -TimeoutSec 30
                        }
                        catch {
                            $statusCode = $null
                            $responseProperty = `
                                $_.Exception.PSObject.Properties["Response"]
                            if (
                                $null -ne $responseProperty -and
                                $null -ne $responseProperty.Value
                            ) {
                                $statusProperty = $responseProperty.Value.
                                    PSObject.Properties["StatusCode"]
                                if ($null -ne $statusProperty) {
                                    $statusCode = [int]$statusProperty.Value
                                }
                            }
                            if ($null -ne $statusCode) {
                                throw (
                                    "Flag creation failed with HTTP " +
                                    "$statusCode for '$($request.key)'."
                                )
                            }
                            throw "Flag creation failed for '$($request.key)'."
                        }
                        if ($response.success -ne $true) {
                            throw (
                                "FeatBit rejected flag creation for " +
                                "'$($request.key)'."
                            )
                        }
                        [string]$request.key
                    } `
                    -ThrottleLimit $RequestThrottleLimit
            )
            if ($createdKeys.Count -ne $createRequests.Count) {
                throw (
                    "Only $($createdKeys.Count) of $($createRequests.Count) " +
                    "missing flags reported successful creation."
                )
            }
            $createdFlagCount += $createdKeys.Count
        }

        $flagRequests = @($expectedFlags | ForEach-Object {
            [pscustomobject]@{
                key = [string]$_.key
                encodedKey = [Uri]::EscapeDataString([string]$_.key)
            }
        })
        $fetchedFlags = @(
            $flagRequests |
                ForEach-Object -Parallel {
                    $ErrorActionPreference = "Stop"
                    $request = $_
                    $baseUrl = $using:featureFlagsUrl
                    $requestHeaders = @{
                        Authorization = $using:plainToken
                        Accept = "application/json"
                    }
                    try {
                        $response = Invoke-RestMethod `
                            -Method GET `
                            -Uri "$baseUrl/$($request.encodedKey)" `
                            -Headers $requestHeaders `
                            -TimeoutSec 30
                    }
                    catch {
                        $statusCode = $null
                        $responseProperty = `
                            $_.Exception.PSObject.Properties["Response"]
                        if (
                            $null -ne $responseProperty -and
                            $null -ne $responseProperty.Value
                        ) {
                            $statusProperty = $responseProperty.Value.
                                PSObject.Properties["StatusCode"]
                            if ($null -ne $statusProperty) {
                                $statusCode = [int]$statusProperty.Value
                            }
                        }
                        if ($null -ne $statusCode) {
                            throw (
                                "Flag read failed with HTTP $statusCode for " +
                                "'$($request.key)'."
                            )
                        }
                        throw "Flag read failed for '$($request.key)'."
                    }
                    if ($response.success -ne $true) {
                        throw (
                            "FeatBit rejected flag read for " +
                            "'$($request.key)'."
                        )
                    }
                    [pscustomobject]@{
                        key = [string]$request.key
                        flag = $response.data
                    }
                } `
                -ThrottleLimit $RequestThrottleLimit
        )
        if ($fetchedFlags.Count -ne $expectedFlags.Count) {
            throw (
                "Only $($fetchedFlags.Count) of $($expectedFlags.Count) " +
                "flags were returned for canonical validation."
            )
        }

        foreach ($expectedFlag in $expectedFlags) {
            $fetchedMatches = @($fetchedFlags | Where-Object {
                [string]$_.key -ceq [string]$expectedFlag.key
            })
            if ($fetchedMatches.Count -ne 1) {
                throw (
                    "Flag '$($expectedFlag.key)' was not fetched uniquely " +
                    "for canonical validation."
                )
            }
            Assert-CanonicalFlag `
                -Flag $fetchedMatches[0].flag `
                -Expected $expectedFlag `
                -RevisionValues $revisionValues
        }

        $verifiedFlags = @(Get-FlagsByPrefix `
            -FeatureFlagsUrl $featureFlagsUrl `
            -Headers $headers `
            -Prefix ([string]$matrix.flagPrefix) `
            -Archived $false)
        if ($verifiedFlags.Count -ne [int]$matrix.flagCountPerEnvironment) {
            throw (
                "Environment '$($expectedEnvironment.key)' has " +
                "$($verifiedFlags.Count) active experiment flags; expected " +
                "$($matrix.flagCountPerEnvironment)."
            )
        }

        $secretRows.Add([ordered]@{
            index = [int]$expectedEnvironment.index
            id = $environmentId
            key = [string]$expectedEnvironment.key
            serverSecret = $serverSecret
        })
        $inventoryRows.Add([ordered]@{
            index = [int]$expectedEnvironment.index
            id = $environmentId
            key = [string]$expectedEnvironment.key
            name = [string]$expectedEnvironment.name
            flagCount = [int]$matrix.flagCountPerEnvironment
        })
        Write-Host (
            "Environment {0:D3}/100 verified; flags=20" -f
            [int]$expectedEnvironment.index
        )
    }

    if ($secretRows.Count -ne 100 -or $inventoryRows.Count -ne 100) {
        throw "Prepared environment inventory is incomplete."
    }
    $targetRows = @($secretRows | Where-Object {
        [int]$_.index -eq [int]$matrix.targetEnvironmentIndex
    })
    if ($targetRows.Count -ne 1) {
        throw "Target environment index was not resolved uniquely."
    }
    $targetEnvironment = $targetRows[0]

    $inventory = [ordered]@{
        schemaVersion = 1
        experimentId = [string]$matrix.experimentId
        kubernetesContext = $targetContext
        project = [ordered]@{
            id = $projectId
            key = [string]$project.key
            name = [string]$project.name
        }
        naming = [ordered]@{
            environmentPrefix = [string]$matrix.environmentPrefix
            flagPrefix = [string]$matrix.flagPrefix
        }
        topology = [ordered]@{
            environmentCount = 100
            flagCountPerEnvironment = 20
            parallelism = 20
            connectionsPerRunner = 500
            connectionsPerEnvironmentPerRunner = 5
            connectionsPerEnvironment = 100
            totalConnections = 10000
        }
        targetEnvironment = [ordered]@{
            index = [int]$targetEnvironment.index
            id = [string]$targetEnvironment.id
            key = [string]$targetEnvironment.key
        }
        measuredFlagKey = [string]$desiredFlagKeys[
            [int]$matrix.measuredFlagIndex - 1
        ]
        postRampWarmupFlagKey = [string]$desiredFlagKeys[
            [int]$matrix.postRampWarmupFlagIndex - 1
        ]
        flagKeys = $desiredFlagKeys
        expectedRevisions = $revisionValues
        environments = @($inventoryRows)
    }
    $inventoryJson = $inventory | ConvertTo-Json -Depth 12
    $inventoryBytes = [Text.Encoding]::UTF8.GetBytes($inventoryJson)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $inventorySha256 = [Convert]::ToHexString(
            $sha.ComputeHash($inventoryBytes)
        ).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }

    $secretDocument = [ordered]@{
        schemaVersion = 1
        experimentId = [string]$matrix.experimentId
        projectId = $projectId
        targetEnvironmentId = [string]$targetEnvironment.id
        environments = @($secretRows)
    }
    $secretJson = $secretDocument | ConvertTo-Json -Depth 8 -Compress
    $secretBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($secretJson)
    )

    $configMapName = [string]$matrix.kubernetesObjects.configMap
    $secretName = [string]$matrix.kubernetesObjects.secret
    $existingConfigMap = Get-OwnedKubernetesObject `
        -Context $targetContext `
        -Kind "configmap" `
        -Name $configMapName `
        -ExperimentId ([string]$matrix.experimentId)
    $existingSecret = Get-OwnedKubernetesObject `
        -Context $targetContext `
        -Kind "secret" `
        -Name $secretName `
        -ExperimentId ([string]$matrix.experimentId)

    $labels = [ordered]@{
        "app.kubernetes.io/name" = "featbit-k6-multi-environment"
        "app.kubernetes.io/part-of" = "featbit-load-testing"
        "loadtest.featbit.io/experiment" = [string]$matrix.experimentId
    }
    $configMap = [ordered]@{
        apiVersion = "v1"
        kind = "ConfigMap"
        metadata = [ordered]@{
            name = $configMapName
            namespace = $script:LoadTestNamespace
            labels = $labels
        }
        data = [ordered]@{
            MULTI_ENVIRONMENT_MODE = "true"
            MULTI_ENVIRONMENT_SECRET_PATH = "/var/run/featbit-loadtest/environments.json"
            EXPECTED_ENVIRONMENT_COUNT = "100"
            EXPECTED_CONNECTIONS_PER_ENVIRONMENT_PER_RUNNER = "5"
            FEATBIT_ENVIRONMENT_ID = [string]$targetEnvironment.id
            TARGET_ENVIRONMENT_KEY = [string]$targetEnvironment.key
            PROBE_INITIAL_VALUE = "baseline"
            PROBE_FLAG_KEYS = [string]$inventory.measuredFlagKey
            POST_RAMP_WARMUP_FLAG_KEY = [string]$inventory.postRampWarmupFlagKey
            VALIDATED_FLAG_KEYS = ($desiredFlagKeys -join ",")
            EXPECTED_REVISIONS = ($revisionValues -join ",")
            STRICT_PATCH_DELIVERY = "false"
            AUTO_CONTROL_REVISIONS = "false"
            INVENTORY_SHA256 = $inventorySha256
            "inventory.json" = $inventoryJson
        }
    }
    $secret = [ordered]@{
        apiVersion = "v1"
        kind = "Secret"
        metadata = [ordered]@{
            name = $secretName
            namespace = $script:LoadTestNamespace
            labels = $labels
        }
        type = "Opaque"
        data = [ordered]@{
            "environments.json" = $secretBase64
        }
    }

    foreach ($pair in @(
        @{
            Desired = $configMap
            Existing = $existingConfigMap
        },
        @{
            Desired = $secret
            Existing = $existingSecret
        }
    )) {
        $desiredObject = $pair.Desired
        $existingObject = $pair.Existing
        if ($null -ne $existingObject) {
            if (
                -not (
                    Test-KubernetesDataEqual `
                        -Actual $existingObject.data `
                        -Expected $desiredObject.data
                )
            ) {
                throw (
                    "$($desiredObject.kind)/$($desiredObject.metadata.name) " +
                    "is owned by this experiment but its data differs from " +
                    "the canonical inventory. Refusing to overwrite it."
                )
            }
            Write-Host (
                "$($desiredObject.kind)/$($desiredObject.metadata.name) " +
                "already exists and is canonical; reused."
            )
            continue
        }
        $desiredObject |
            ConvertTo-Json -Depth 14 |
            & kubectl --context $targetContext apply -f -
        if ($LASTEXITCODE -ne 0) {
            throw (
                "Failed to create " +
                "$($desiredObject.kind)/$($desiredObject.metadata.name)."
            )
        }
    }

    $resolvedInventoryPath = if (
        [string]::IsNullOrWhiteSpace($InventoryOutputPath)
    ) {
        Join-Path `
            (Join-Path $repositoryRoot "results") `
            (
                "{0}-inventory-{1}.json" -f
                [string]$matrix.experimentId,
                [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss")
            )
    }
    else {
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            $InventoryOutputPath
        )
    }
    $inventoryDirectory = Split-Path -Parent $resolvedInventoryPath
    $null = New-Item -ItemType Directory -Force -Path $inventoryDirectory
    if (Test-Path -LiteralPath $resolvedInventoryPath) {
        throw "Refusing to overwrite existing inventory: $resolvedInventoryPath"
    }
    [IO.File]::WriteAllText(
        $resolvedInventoryPath,
        $inventoryJson + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host ""
    Write-Host "Multi-environment resources are complete and canonical." `
        -ForegroundColor Green
    Write-Host "Project: $($project.name) [$($project.key)]"
    Write-Host "Environments: 100 (created $createdEnvironmentCount, reused $reusedEnvironmentCount)"
    Write-Host "Flags: 2,000 (created $createdFlagCount, reused $reusedFlagCount)"
    Write-Host "Target environment: $($targetEnvironment.key)"
    Write-Host "Kubernetes Secret: $secretName (values not displayed)"
    Write-Host "Inventory: $resolvedInventoryPath"

    [pscustomobject]@{
        ExperimentId = [string]$matrix.experimentId
        ProjectId = $projectId
        ProjectKey = [string]$project.key
        EnvironmentCount = 100
        FlagCount = 2000
        CreatedEnvironmentCount = $createdEnvironmentCount
        ReusedEnvironmentCount = $reusedEnvironmentCount
        CreatedFlagCount = $createdFlagCount
        ReusedFlagCount = $reusedFlagCount
        TargetEnvironmentId = [string]$targetEnvironment.id
        TargetEnvironmentKey = [string]$targetEnvironment.key
        ConfigMapName = $configMapName
        SecretName = $secretName
        InventorySha256 = $inventorySha256
        InventoryPath = $resolvedInventoryPath
    }
}
finally {
    $plainToken = $null
    $encodedToken = $null
    $headers = $null
    $secretRows = $null
    $secretDocument = $null
    $secretJson = $null
    $secretBase64 = $null
    $secret = $null
}
