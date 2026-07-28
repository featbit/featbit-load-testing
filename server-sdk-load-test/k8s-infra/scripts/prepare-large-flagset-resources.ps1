[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^aks-featbit-load-testing$")]
    [string] $KubeContext,

    [string] $ApiUrl = "http://127.0.0.1:15000",

    [string] $MatrixPath = "",

    [string] $InventoryOutputPath = "",

    [ValidateRange(1, 32)]
    [int] $RequestThrottleLimit = 8
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
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][hashtable] $Headers,
        [object] $Body
    )

    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = $Headers
        TimeoutSec = 60
    }
    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = $Body | ConvertTo-Json -Depth 16 -Compress
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
        throw "FeatBit API rejected '$Uri'."
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

function Get-AllFlags {
    param(
        [Parameter(Mandatory)][string] $FeatureFlagsUrl,
        [Parameter(Mandatory)][hashtable] $Headers,
        [Parameter(Mandatory)][bool] $Archived
    )

    $rows = [Collections.Generic.List[object]]::new()
    $pageIndex = 0
    $pageSize = 100
    do {
        $archivedValue = $Archived.ToString().ToLowerInvariant()
        $page = Invoke-FeatBitRequest `
            -Method GET `
            -Uri (
                "${FeatureFlagsUrl}?IsArchived=$archivedValue" +
                "&PageIndex=$pageIndex&PageSize=$pageSize"
            ) `
            -Headers $Headers
        $items = @($page.items)
        foreach ($item in $items) {
            $rows.Add($item)
        }
        $pageIndex += 1
        if ($pageIndex -gt 100) {
            throw "Feature-flag pagination exceeded 100 pages."
        }
    } while ($items.Count -eq $pageSize)
    return @($rows)
}

function Get-ExpectedFlag {
    param(
        [Parameter(Mandatory)][object] $Matrix,
        [Parameter(Mandatory)][int] $Index,
        [Parameter(Mandatory)][hashtable] $RevisionByFlagIndex
    )

    $variationType = if ($Index -le [int]$Matrix.stringFlagCount) {
        "string"
    }
    else {
        "json"
    }
    $revision = if ($RevisionByFlagIndex.ContainsKey($Index)) {
        [string]$RevisionByFlagIndex[$Index]
    }
    elseif ($Index -eq [int]$Matrix.postRampWarmupFlagIndex) {
        [string]$Matrix.revisionPlan[0].revision
    }
    else {
        "stable-alt-{0:D4}" -f $Index
    }

    return [ordered]@{
        index = $Index
        key = "{0}{1:D4}" -f [string]$Matrix.flagPrefix, $Index
        name = "{0}{1:D4}" -f [string]$Matrix.flagNamePrefix, $Index
        description = [string]$Matrix.flagDescription
        variationType = $variationType
        alternateRevision = $revision
        measured = $RevisionByFlagIndex.ContainsKey($Index)
        warmup = $Index -eq [int]$Matrix.postRampWarmupFlagIndex
    }
}

function New-JsonVariationValue {
    param(
        [Parameter(Mandatory)][int] $FlagIndex,
        [Parameter(Mandatory)][string] $Revision,
        [Parameter(Mandatory)][string] $Variant,
        [Parameter(Mandatory)][int] $TargetBytes
    )

    $configuration = [ordered]@{
        _loadTestRevision = $Revision
        schemaVersion = 1
        flagIndex = $FlagIndex
        variant = $Variant
        settings = [ordered]@{
            endpoint = "https://config.example.test/v1/items"
            timeoutMs = if ($Variant -eq "baseline") { 1000 } else { 2500 }
            retry = [ordered]@{
                maximumAttempts = if ($Variant -eq "baseline") { 3 } else { 5 }
                backoffMs = @(50, 100, 250, 500)
            }
            features = [ordered]@{
                cache = $true
                compression = $true
                diagnostics = $Variant -ne "baseline"
            }
        }
        routes = @(
            [ordered]@{ path = "/alpha"; enabled = $true; weight = 25 },
            [ordered]@{ path = "/beta"; enabled = $true; weight = 75 }
        )
        padding = ""
    }
    $withoutPadding = $configuration | ConvertTo-Json -Depth 12 -Compress
    $baseBytes = [Text.Encoding]::UTF8.GetByteCount($withoutPadding)
    $paddingBytes = $TargetBytes - $baseBytes
    if ($paddingBytes -lt 0) {
        throw (
            "JSON configuration metadata for flag $FlagIndex exceeds " +
            "the requested $TargetBytes bytes."
        )
    }
    $configuration.padding = "x" * $paddingBytes
    $value = $configuration | ConvertTo-Json -Depth 12 -Compress
    $actualBytes = [Text.Encoding]::UTF8.GetByteCount($value)
    if ($actualBytes -ne $TargetBytes) {
        throw (
            "JSON configuration for flag $FlagIndex is $actualBytes bytes; " +
            "expected exactly $TargetBytes."
        )
    }
    return $value
}

function New-CanonicalFlagPayload {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)][object] $Matrix
    )

    $baselineId = [Guid]::NewGuid().ToString()
    $alternateId = [Guid]::NewGuid().ToString()
    if ([string]$Expected.variationType -eq "json") {
        $baselineValue = New-JsonVariationValue `
            -FlagIndex ([int]$Expected.index) `
            -Revision "baseline" `
            -Variant "baseline" `
            -TargetBytes ([int]$Matrix.jsonVariationBytes)
        $alternateValue = New-JsonVariationValue `
            -FlagIndex ([int]$Expected.index) `
            -Revision ([string]$Expected.alternateRevision) `
            -Variant "alternate" `
            -TargetBytes ([int]$Matrix.jsonVariationBytes)
    }
    else {
        $baselineValue = "baseline"
        $alternateValue = [string]$Expected.alternateRevision
    }

    return [ordered]@{
        name = [string]$Expected.name
        key = [string]$Expected.key
        isEnabled = $true
        description = [string]$Expected.description
        variationType = [string]$Expected.variationType
        variations = @(
            [ordered]@{
                id = $baselineId
                name = "Baseline"
                value = $baselineValue
            },
            [ordered]@{
                id = $alternateId
                name = if ($Expected.measured) {
                    "Measured $($Expected.alternateRevision)"
                }
                elseif ($Expected.warmup) {
                    "Post-ramp warm-up"
                }
                else {
                    "Stable alternate"
                }
                value = $alternateValue
            }
        )
        enabledVariationId = $baselineId
        disabledVariationId = $baselineId
        tags = @(
            "load-test",
            "large-flagset",
            [string]$Matrix.experimentId
        )
    }
}

function Get-VariationRevision {
    param(
        [Parameter(Mandatory)][object] $Variation,
        [Parameter(Mandatory)][string] $VariationType
    )

    if ($VariationType -eq "string") {
        return [string]$Variation.value
    }
    try {
        $configuration = [string]$Variation.value | ConvertFrom-Json
    }
    catch {
        throw "JSON variation '$($Variation.id)' is not valid JSON."
    }
    $revision = [string]$configuration._loadTestRevision
    if ([string]::IsNullOrWhiteSpace($revision)) {
        throw "JSON variation '$($Variation.id)' has no _loadTestRevision."
    }
    return $revision
}

function Assert-CanonicalFlag {
    param(
        [Parameter(Mandatory)][object] $Flag,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)][object] $Matrix
    )

    if (
        [string]$Flag.key -cne [string]$Expected.key -or
        [string]$Flag.name -cne [string]$Expected.name -or
        [string]$Flag.description -cne [string]$Expected.description
    ) {
        throw "Flag '$($Expected.key)' has non-canonical identity or ownership."
    }
    if (
        $Flag.isArchived -eq $true -or
        $Flag.isEnabled -ne $true -or
        [string]$Flag.variationType -cne [string]$Expected.variationType -or
        @($Flag.targetUsers).Count -ne 0 -or
        @($Flag.rules).Count -ne 0
    ) {
        throw (
            "Flag '$($Expected.key)' must be active, enabled, deterministic, " +
            "and use '$($Expected.variationType)' variations."
        )
    }

    $variations = @($Flag.variations)
    if ($variations.Count -ne 2) {
        throw "Flag '$($Expected.key)' must contain exactly two variations."
    }
    $revisionRows = @(
        foreach ($variation in $variations) {
            [pscustomobject]@{
                revision = Get-VariationRevision `
                    -Variation $variation `
                    -VariationType ([string]$Expected.variationType)
                variation = $variation
            }
        }
    )
    $expectedRevisions = @("baseline", [string]$Expected.alternateRevision)
    if (
        @(Compare-Object `
            -ReferenceObject ($expectedRevisions | Sort-Object) `
            -DifferenceObject ($revisionRows.revision | Sort-Object)).Count -ne 0
    ) {
        throw "Flag '$($Expected.key)' has non-canonical revision tokens."
    }
    if ([string]$Expected.variationType -eq "json") {
        foreach ($row in $revisionRows) {
            $bytes = [Text.Encoding]::UTF8.GetByteCount(
                [string]$row.variation.value
            )
            if ($bytes -ne [int]$Matrix.jsonVariationBytes) {
                throw (
                    "Flag '$($Expected.key)' JSON variation is $bytes bytes; " +
                    "expected $($Matrix.jsonVariationBytes)."
                )
            }
        }
    }

    $baseline = @($revisionRows | Where-Object revision -ceq "baseline")
    $served = @($Flag.fallthrough.variations)
    if (
        $baseline.Count -ne 1 -or
        $served.Count -ne 1 -or
        [string]$served[0].id -cne [string]$baseline[0].variation.id -or
        @($served[0].rollout).Count -ne 2 -or
        [double]$served[0].rollout[0] -ne 0 -or
        [double]$served[0].rollout[1] -ne 1 -or
        [string]$Flag.disabledVariationId -cne
            [string]$baseline[0].variation.id
    ) {
        throw "Flag '$($Expected.key)' must serve baseline to 100 percent."
    }

    $requiredTags = @(
        "load-test",
        "large-flagset",
        [string]$Matrix.experimentId
    )
    $actualTags = @($Flag.tags | ForEach-Object { [string]$_ })
    if (
        @(Compare-Object `
            -ReferenceObject ($requiredTags | Sort-Object) `
            -DifferenceObject ($actualTags | Sort-Object)).Count -ne 0
    ) {
        throw "Flag '$($Expected.key)' has non-canonical ownership tags."
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
Assert-NoActiveLoadTest -Context $targetContext
Assert-KubernetesObjectExists `
    -Kind "secret" `
    -Name "featbit-k6-controller-secret" `
    -KubeContext $targetContext

$repositoryRoot = Get-RepositoryRoot
$resolvedMatrixPath = if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
    Join-Path `
        $repositoryRoot `
        "k8s-infra\matrices\aks-single-environment-3k-flags-g5-d4-els3.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $MatrixPath
    )
}
if (-not (Test-Path -LiteralPath $resolvedMatrixPath -PathType Leaf)) {
    throw "Matrix does not exist: $resolvedMatrixPath"
}
$matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath | ConvertFrom-Json
if (
    $matrix.schemaVersion -ne 1 -or
    [string]$matrix.kubernetesContext -cne $targetContext -or
    [int]$matrix.flagCount -ne 3000 -or
    [int]$matrix.stringFlagCount -ne 2500 -or
    [int]$matrix.jsonFlagCount -ne 500 -or
    [int]$matrix.stringFlagCount + [int]$matrix.jsonFlagCount -ne
        [int]$matrix.flagCount -or
    [int]$matrix.jsonVariationBytes -lt 1024 -or
    @($matrix.revisionPlan).Count -ne 10
) {
    throw "Matrix does not match the fixed one-environment / 3,000-flag contract."
}

$revisionByFlagIndex = @{}
$expectedRevisionIndexes = [Collections.Generic.List[int]]::new()
$expectedRevisionTokens = [Collections.Generic.List[string]]::new()
for ($offset = 0; $offset -lt @($matrix.revisionPlan).Count; $offset += 1) {
    $step = $matrix.revisionPlan[$offset]
    if (
        [int]$step.index -ne $offset + 1 -or
        $revisionByFlagIndex.ContainsKey([int]$step.flagIndex) -or
        $expectedRevisionTokens.Contains([string]$step.revision) -or
        [string]$step.variationType -notin @("string", "json")
    ) {
        throw "Matrix revisionPlan is not canonical at step $($offset + 1)."
    }
    $expectedType = if (
        [int]$step.flagIndex -le [int]$matrix.stringFlagCount
    ) {
        "string"
    }
    else {
        "json"
    }
    if ([string]$step.variationType -cne $expectedType) {
        throw "Revision step $($step.index) variation type is inconsistent."
    }
    $revisionByFlagIndex[[int]$step.flagIndex] = [string]$step.revision
    $expectedRevisionIndexes.Add([int]$step.flagIndex)
    $expectedRevisionTokens.Add([string]$step.revision)
}
if (
    @($matrix.revisionPlan | Where-Object variationType -eq "string").Count -ne 8 -or
    @($matrix.revisionPlan | Where-Object variationType -eq "json").Count -ne 2 -or
    $revisionByFlagIndex.ContainsKey([int]$matrix.postRampWarmupFlagIndex)
) {
    throw "Matrix must contain eight string and two JSON measured flags plus a separate warm-up flag."
}

$expectedFlags = @(
    1..([int]$matrix.flagCount) | ForEach-Object {
        Get-ExpectedFlag `
            -Matrix $matrix `
            -Index $_ `
            -RevisionByFlagIndex $revisionByFlagIndex
    }
)
$desiredFlagKeys = @($expectedFlags.key)
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
    $projects = @(
        Invoke-FeatBitRequest `
            -Method GET `
            -Uri "$normalizedApiUrl/api/v1/projects" `
            -Headers $headers
    )
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
    $environmentMatches = @($project.environments | Where-Object {
        [string]$_.key -ceq [string]$matrix.environmentKey
    })
    if ($environmentMatches.Count -gt 1) {
        throw "Environment '$($matrix.environmentKey)' is not unique."
    }

    $createdEnvironment = $false
    if ($environmentMatches.Count -eq 0) {
        $null = Invoke-FeatBitRequest `
            -Method POST `
            -Uri "$normalizedApiUrl/api/v1/projects/$projectId/envs" `
            -Headers $headers `
            -Body ([ordered]@{
                name = [string]$matrix.environmentName
                key = [string]$matrix.environmentKey
                description = [string]$matrix.environmentDescription
            })
        $project = Invoke-FeatBitRequest `
            -Method GET `
            -Uri "$normalizedApiUrl/api/v1/projects/$projectId" `
            -Headers $headers
        $environmentMatches = @($project.environments | Where-Object {
            [string]$_.key -ceq [string]$matrix.environmentKey
        })
        if ($environmentMatches.Count -ne 1) {
            throw "Created environment could not be rediscovered uniquely."
        }
        $createdEnvironment = $true
    }
    $environment = $environmentMatches[0]
    if (
        [string]$environment.name -cne [string]$matrix.environmentName -or
        [string]$environment.description -cne
            [string]$matrix.environmentDescription -or
        [string]$environment.projectId -cne $projectId
    ) {
        throw (
            "Environment '$($matrix.environmentKey)' exists but differs " +
            "from the experiment contract."
        )
    }
    $serverSecrets = @($environment.secrets | Where-Object {
        [string]$_.type -ieq "server" -and
        -not [string]::IsNullOrWhiteSpace([string]$_.value)
    })
    if ($serverSecrets.Count -ne 1) {
        throw "The experiment environment must have exactly one Server SDK secret."
    }
    $serverSecret = [string]$serverSecrets[0].value
    $environmentId = [string]$environment.id
    $featureFlagsUrl = "$normalizedApiUrl/api/v1/envs/$environmentId/feature-flags"

    $activeFlags = @(Get-AllFlags `
        -FeatureFlagsUrl $featureFlagsUrl `
        -Headers $headers `
        -Archived $false)
    $archivedFlags = @(Get-AllFlags `
        -FeatureFlagsUrl $featureFlagsUrl `
        -Headers $headers `
        -Archived $true)
    $foreignFlags = @($activeFlags | Where-Object {
        -not ([string]$_.key).StartsWith(
            [string]$matrix.flagPrefix,
            [StringComparison]::Ordinal
        )
    })
    if ($foreignFlags.Count -gt 0) {
        throw (
            "The dedicated experiment environment contains " +
            "$($foreignFlags.Count) non-experiment active flag(s)."
        )
    }
    if ($archivedFlags.Count -gt 0) {
        throw (
            "The dedicated experiment environment contains archived flags; " +
            "refusing to delete or replace them."
        )
    }
    $extraFlags = @($activeFlags | Where-Object {
        [string]$_.key -cnotin $desiredFlagKeys
    })
    if ($extraFlags.Count -gt 0) {
        throw (
            "Unexpected flags use the experiment prefix: " +
            (($extraFlags.key | Sort-Object) -join ", ")
        )
    }

    $activeByKey = @{}
    foreach ($flag in $activeFlags) {
        $key = [string]$flag.key
        if ($activeByKey.ContainsKey($key)) {
            throw "Feature flag '$key' is not unique."
        }
        $activeByKey[$key] = $flag
    }
    $missingFlags = @($expectedFlags | Where-Object {
        -not $activeByKey.ContainsKey([string]$_.key)
    })
    $createRequests = @(
        $missingFlags | ForEach-Object {
            [pscustomobject]@{
                key = [string]$_.key
                body = (
                    New-CanonicalFlagPayload `
                        -Expected $_ `
                        -Matrix $matrix |
                        ConvertTo-Json -Depth 16 -Compress
                )
            }
        }
    )
    $createdFlagCount = 0
    if ($createRequests.Count -gt 0) {
        Write-Host (
            "Creating $($createRequests.Count) missing flags with throttle " +
            "$RequestThrottleLimit..."
        )
        $createdKeys = @(
            $createRequests |
                ForEach-Object -Parallel {
                    $ErrorActionPreference = "Stop"
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
                            -Body $_.body `
                            -TimeoutSec 60
                    }
                    catch {
                        throw "Flag creation failed for '$($_.key)'."
                    }
                    if ($response.success -ne $true) {
                        throw "FeatBit rejected flag creation for '$($_.key)'."
                    }
                    [string]$_.key
                } `
                -ThrottleLimit $RequestThrottleLimit
        )
        if ($createdKeys.Count -ne $createRequests.Count) {
            throw (
                "Only $($createdKeys.Count) of $($createRequests.Count) " +
                "missing flags reported successful creation."
            )
        }
        $createdFlagCount = $createdKeys.Count
    }

    Write-Host "Reading and validating all 3,000 flags..."
    $flagRequests = @($expectedFlags | ForEach-Object {
        [pscustomobject]@{
            expected = $_
            encodedKey = [Uri]::EscapeDataString([string]$_.key)
        }
    })
    $fetchedFlags = @(
        $flagRequests |
            ForEach-Object -Parallel {
                $ErrorActionPreference = "Stop"
                $requestHeaders = @{
                    Authorization = $using:plainToken
                    Accept = "application/json"
                }
                try {
                    $response = Invoke-RestMethod `
                        -Method GET `
                        -Uri "$using:featureFlagsUrl/$($_.encodedKey)" `
                        -Headers $requestHeaders `
                        -TimeoutSec 60
                }
                catch {
                    throw "Flag read failed for '$($_.expected.key)'."
                }
                if ($response.success -ne $true) {
                    throw "FeatBit rejected flag read for '$($_.expected.key)'."
                }
                [pscustomobject]@{
                    expected = $_.expected
                    flag = $response.data
                }
            } `
            -ThrottleLimit $RequestThrottleLimit
    )
    if ($fetchedFlags.Count -ne [int]$matrix.flagCount) {
        throw (
            "Only $($fetchedFlags.Count) of $($matrix.flagCount) flags " +
            "were returned for canonical validation."
        )
    }
    $validated = 0
    foreach ($row in $fetchedFlags) {
        Assert-CanonicalFlag `
            -Flag $row.flag `
            -Expected $row.expected `
            -Matrix $matrix
        $validated += 1
        if ($validated % 250 -eq 0) {
            Write-Host "Validated $validated/3000 flags."
        }
    }

    $verifiedActiveFlags = @(Get-AllFlags `
        -FeatureFlagsUrl $featureFlagsUrl `
        -Headers $headers `
        -Archived $false)
    if (
        $verifiedActiveFlags.Count -ne [int]$matrix.flagCount -or
        @($verifiedActiveFlags | Where-Object {
            -not ([string]$_.key).StartsWith(
                [string]$matrix.flagPrefix,
                [StringComparison]::Ordinal
            )
        }).Count -ne 0
    ) {
        throw "Final environment inventory is not exactly 3,000 experiment flags."
    }

    $revisionPlan = @(
        foreach ($step in $matrix.revisionPlan) {
            [ordered]@{
                index = [int]$step.index
                flagKey = "{0}{1:D4}" -f `
                    [string]$matrix.flagPrefix, `
                    [int]$step.flagIndex
                revision = [string]$step.revision
                variationType = [string]$step.variationType
            }
        }
    )
    $measuredFlagKeys = @($revisionPlan.flagKey)
    $warmupFlagKey = "{0}{1:D4}" -f `
        [string]$matrix.flagPrefix, `
        [int]$matrix.postRampWarmupFlagIndex
    $validatedFlagKeys = @($measuredFlagKeys + $warmupFlagKey)
    $inventory = [ordered]@{
        schemaVersion = 1
        experimentId = [string]$matrix.experimentId
        kubernetesContext = $targetContext
        project = [ordered]@{
            id = $projectId
            key = [string]$project.key
            name = [string]$project.name
        }
        environment = [ordered]@{
            id = $environmentId
            key = [string]$environment.key
            name = [string]$environment.name
        }
        naming = [ordered]@{
            environmentKey = [string]$matrix.environmentKey
            flagPrefix = [string]$matrix.flagPrefix
        }
        topology = [ordered]@{
            environmentCount = 1
            flagCount = 3000
            stringFlagCount = 2500
            jsonFlagCount = 500
            jsonVariationBytes = [int]$matrix.jsonVariationBytes
            parallelism = 20
            connectionsPerRunner = 500
            connectionsPerEnvironmentPerRunner = 500
            connectionsPerEnvironment = 10000
            totalConnections = 10000
        }
        postRampWarmupFlagKey = $warmupFlagKey
        measuredFlagKeys = $measuredFlagKeys
        validatedFlagKeys = $validatedFlagKeys
        revisionPlan = $revisionPlan
        expectedRevisions = @($revisionPlan.revision)
        flagKeys = $desiredFlagKeys
    }
    $inventoryJson = $inventory | ConvertTo-Json -Depth 14
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
    $revisionPlanJson = $revisionPlan | ConvertTo-Json -Depth 8 -Compress

    $secretDocument = [ordered]@{
        schemaVersion = 1
        experimentId = [string]$matrix.experimentId
        projectId = $projectId
        targetEnvironmentId = $environmentId
        environments = @(
            [ordered]@{
                index = 1
                id = $environmentId
                key = [string]$environment.key
                serverSecret = $serverSecret
            }
        )
    }
    $secretJson = $secretDocument | ConvertTo-Json -Depth 8 -Compress
    $secretBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($secretJson)
    )
    $labels = [ordered]@{
        "app.kubernetes.io/name" = "featbit-k6-large-flagset"
        "app.kubernetes.io/part-of" = "featbit-load-testing"
        "loadtest.featbit.io/experiment" = [string]$matrix.experimentId
    }
    $configMap = [ordered]@{
        apiVersion = "v1"
        kind = "ConfigMap"
        metadata = [ordered]@{
            name = [string]$matrix.kubernetesObjects.configMap
            namespace = $script:LoadTestNamespace
            labels = $labels
        }
        data = [ordered]@{
            MULTI_ENVIRONMENT_MODE = "true"
            MULTI_ENVIRONMENT_SECRET_PATH = (
                "/var/run/featbit-loadtest/environments.json"
            )
            EXPECTED_ENVIRONMENT_COUNT = "1"
            EXPECTED_CONNECTIONS_PER_ENVIRONMENT_PER_RUNNER = "500"
            EXPECTED_FULL_SYNC_FLAG_COUNT = "3000"
            FEATBIT_ENVIRONMENT_ID = $environmentId
            TARGET_ENVIRONMENT_KEY = [string]$environment.key
            PROBE_INITIAL_VALUE = "baseline"
            PROBE_FLAG_KEYS = ($measuredFlagKeys -join ",")
            POST_RAMP_WARMUP_FLAG_KEY = $warmupFlagKey
            VALIDATED_FLAG_KEYS = ($validatedFlagKeys -join ",")
            EXPECTED_REVISIONS = (@($revisionPlan.revision) -join ",")
            REVISION_PLAN_JSON = $revisionPlanJson
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
            name = [string]$matrix.kubernetesObjects.secret
            namespace = $script:LoadTestNamespace
            labels = $labels
        }
        type = "Opaque"
        data = [ordered]@{
            "environments.json" = $secretBase64
        }
    }

    foreach ($desiredObject in @($configMap, $secret)) {
        $existing = Get-OwnedKubernetesObject `
            -Context $targetContext `
            -Kind $desiredObject.kind `
            -Name $desiredObject.metadata.name `
            -ExperimentId ([string]$matrix.experimentId)
        if ($null -ne $existing) {
            if (
                -not (
                    Test-KubernetesDataEqual `
                        -Actual $existing.data `
                        -Expected $desiredObject.data
                )
            ) {
                throw (
                    "$($desiredObject.kind)/$($desiredObject.metadata.name) " +
                    "is owned by this experiment but differs from the " +
                    "canonical inventory. Refusing to overwrite it."
                )
            }
            Write-Host (
                "$($desiredObject.kind)/$($desiredObject.metadata.name) " +
                "already exists and is canonical; reused."
            )
            continue
        }
        $desiredObject |
            ConvertTo-Json -Depth 18 |
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
    Write-Host "Large flag-set resources are complete and canonical." `
        -ForegroundColor Green
    Write-Host "Project: $($project.name) [$($project.key)]"
    Write-Host (
        "Environment: $($environment.key) " +
        "($($(if ($createdEnvironment) { 'created' } else { 'reused' })))"
    )
    Write-Host (
        "Flags: 3,000 (created $createdFlagCount, " +
        "reused $([int]$matrix.flagCount - $createdFlagCount)); " +
        "2,500 string + 500 JSON"
    )
    Write-Host (
        "JSON variation size: $($matrix.jsonVariationBytes) bytes each"
    )
    Write-Host (
        "Kubernetes Secret: $($matrix.kubernetesObjects.secret) " +
        "(values not displayed)"
    )
    Write-Host "Inventory: $resolvedInventoryPath"

    [pscustomobject]@{
        ExperimentId = [string]$matrix.experimentId
        ProjectId = $projectId
        EnvironmentId = $environmentId
        EnvironmentKey = [string]$environment.key
        EnvironmentCreated = $createdEnvironment
        FlagCount = 3000
        StringFlagCount = 2500
        JsonFlagCount = 500
        JsonVariationBytes = [int]$matrix.jsonVariationBytes
        CreatedFlagCount = $createdFlagCount
        ReusedFlagCount = [int]$matrix.flagCount - $createdFlagCount
        ConfigMapName = [string]$matrix.kubernetesObjects.configMap
        SecretName = [string]$matrix.kubernetesObjects.secret
        InventorySha256 = $inventorySha256
        InventoryPath = $resolvedInventoryPath
    }
}
finally {
    $plainToken = $null
    $encodedToken = $null
    $headers = $null
    $serverSecret = $null
    $secretDocument = $null
    $secretJson = $null
    $secretBase64 = $null
    $secret = $null
}
