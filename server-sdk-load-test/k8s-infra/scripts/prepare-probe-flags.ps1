[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 20)]
    [int] $ProbeFlagCount,

    [string] $ExpectedRevisions = "rev-001,rev-002",

    [string] $ApiUrl = "http://localhost:30000",

    [string] $KubeContext = "docker-desktop"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$script:ProbeFlagPrefix = "loadtest-sync-probe-"
$script:RevisionValues = @(
    $ExpectedRevisions.Split(
        ",",
        [StringSplitOptions]::RemoveEmptyEntries -bor [StringSplitOptions]::TrimEntries
    )
)
if ($script:RevisionValues.Count -eq 0) {
    throw "ExpectedRevisions must contain at least one value."
}
$uniqueRevisionValues = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($revisionValue in $script:RevisionValues) {
    if ($revisionValue -ceq "baseline") {
        throw "ExpectedRevisions must not contain the initial value 'baseline'."
    }
    if (-not $uniqueRevisionValues.Add($revisionValue)) {
        throw "ExpectedRevisions contains duplicate value '$revisionValue'."
    }
}
$script:RequiredProbeValues = @("baseline") + $script:RevisionValues

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

function Assert-NoActiveLoadTest {
    $podJson = (& kubectl `
        --context $targetContext `
        -n $script:LoadTestNamespace `
        get pods `
        -l "loadtest.featbit.io/run-id" `
        -o json | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query existing load-test Pods."
    }

    $activePods = @(($podJson | ConvertFrom-Json).items | Where-Object {
        $_.status.phase -in @("Pending", "Running", "Unknown")
    })
    if ($activePods.Count -gt 0) {
        $names = ($activePods | ForEach-Object { $_.metadata.name }) -join ", "
        throw "Refusing to change probe flags while a load test is active: $names"
    }
}

function Invoke-FeatBitRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("GET", "POST", "PUT", "DELETE")]
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
        TimeoutSec = 15
    }
    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = $Body | ConvertTo-Json -Depth 10 -Compress
    }

    try {
        $response = Invoke-RestMethod @parameters
    }
    catch {
        $caughtException = $_.Exception
        $statusCode = $null
        $responseProperty = $caughtException.PSObject.Properties["Response"]
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            $statusCodeProperty = $responseProperty.Value.PSObject.Properties["StatusCode"]
            if ($null -ne $statusCodeProperty) {
                $statusCode = [int]$statusCodeProperty.Value
            }
        }

        if ($null -ne $statusCode) {
            throw "FeatBit API request failed with HTTP $statusCode."
        }

        $connectionHint = ""
        if (([Uri]$Uri).IsLoopback) {
            $connectionHint = (
                " Keep 'kubectl port-forward service/featbit-api 5000:5000' " +
                "running in a second terminal."
            )
        }
        throw "FeatBit API request to '$Uri' failed: $($caughtException.Message).$connectionHint"
    }

    if ($response.success -ne $true) {
        $details = @($response.errors | ForEach-Object {
            if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Compress }
        }) -join "; "
        throw "FeatBit API rejected the request: $details"
    }

    return $response.data
}

function Get-ManagedProbeFlags {
    param(
        [Parameter(Mandatory)]
        [string] $FeatureFlagsUrl,

        [Parameter(Mandatory)]
        [hashtable] $Headers,

        [Parameter(Mandatory)]
        [bool] $IsArchived
    )

    $archived = $IsArchived.ToString().ToLowerInvariant()
    $encodedPrefix = [Uri]::EscapeDataString($script:ProbeFlagPrefix)
    $uri = "${FeatureFlagsUrl}?Name=$encodedPrefix&IsArchived=$archived&PageIndex=0&PageSize=100"
    $page = Invoke-FeatBitRequest -Method GET -Uri $uri -Headers $Headers

    return @($page.items | Where-Object {
        $_.key -match "^$([regex]::Escape($script:ProbeFlagPrefix))\d{2}$"
    })
}

function Remove-ManagedProbeFlag {
    param(
        [Parameter(Mandatory)]
        [string] $FeatureFlagsUrl,

        [Parameter(Mandatory)]
        [hashtable] $Headers,

        [Parameter(Mandatory)]
        [string] $FlagKey,

        [Parameter(Mandatory)]
        [bool] $IsArchived
    )

    $encodedKey = [Uri]::EscapeDataString($FlagKey)
    $flagUrl = "$FeatureFlagsUrl/$encodedKey"
    $comment = @{ comment = "Reprovisioning reserved streaming load-test probe flags" }

    if (-not $IsArchived) {
        $null = Invoke-FeatBitRequest `
            -Method PUT `
            -Uri "$flagUrl/archive" `
            -Headers $Headers `
            -Body $comment
    }

    $null = Invoke-FeatBitRequest `
        -Method DELETE `
        -Uri $flagUrl `
        -Headers $Headers `
        -Body $comment
}

function New-ManagedProbeFlag {
    param(
        [Parameter(Mandatory)]
        [string] $FeatureFlagsUrl,

        [Parameter(Mandatory)]
        [hashtable] $Headers,

        [Parameter(Mandatory)]
        [string] $FlagKey
    )

    $baselineId = [Guid]::NewGuid().ToString()
    $number = $FlagKey.Substring($script:ProbeFlagPrefix.Length)
    $variations = @(
        [ordered]@{ id = $baselineId; name = "Baseline"; value = "baseline" }
        for ($index = 0; $index -lt $script:RevisionValues.Count; $index++) {
            [ordered]@{
                id = [Guid]::NewGuid().ToString()
                name = "Revision $($index + 1)"
                value = $script:RevisionValues[$index]
            }
        }
    )

    $payload = [ordered]@{
        name = "Load-test sync probe $number"
        key = $FlagKey
        isEnabled = $true
        description = "Reserved for the automated Server SDK streaming load test."
        variationType = "string"
        variations = $variations
        enabledVariationId = $baselineId
        disabledVariationId = $baselineId
        tags = @("load-test", "streaming-probe")
    }

    return Invoke-FeatBitRequest `
        -Method POST `
        -Uri $FeatureFlagsUrl `
        -Headers $Headers `
        -Body $payload
}

function Assert-CanonicalProbeFlag {
    param(
        [Parameter(Mandatory)]
        [object] $Flag,

        [Parameter(Mandatory)]
        [string] $ExpectedKey
    )

    if ($Flag.key -cne $ExpectedKey) {
        throw "Expected probe flag '$ExpectedKey', but the API returned '$($Flag.key)'."
    }
    if ($Flag.isArchived -eq $true -or $Flag.isEnabled -ne $true) {
        throw "Probe flag '$ExpectedKey' must be active and enabled."
    }
    if ([string]$Flag.variationType -cne "string") {
        throw "Probe flag '$ExpectedKey' must use string variations."
    }
    if (@($Flag.targetUsers).Count -ne 0 -or @($Flag.rules).Count -ne 0) {
        throw "Probe flag '$ExpectedKey' must not have target users or targeting rules."
    }

    $actualValues = @($Flag.variations | ForEach-Object { [string]$_.value } | Sort-Object)
    $expectedValues = @($script:RequiredProbeValues | Sort-Object)
    if (@(Compare-Object -ReferenceObject $expectedValues -DifferenceObject $actualValues).Count -ne 0) {
        throw "Probe flag '$ExpectedKey' does not have the canonical variation values."
    }

    $baselineVariation = @($Flag.variations | Where-Object { $_.value -ceq "baseline" })
    $servedVariations = @($Flag.fallthrough.variations)
    if (
        $baselineVariation.Count -ne 1 -or
        $servedVariations.Count -ne 1 -or
        $servedVariations[0].id -cne $baselineVariation[0].id -or
        @($servedVariations[0].rollout).Count -ne 2 -or
        [double]$servedVariations[0].rollout[0] -ne 0 -or
        [double]$servedVariations[0].rollout[1] -ne 1
    ) {
        throw "Probe flag '$ExpectedKey' must serve baseline to 100 percent."
    }
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext
Assert-KubernetesObjectExists `
    -Kind "configmap" `
    -Name "featbit-k6-controller" `
    -KubeContext $targetContext
Assert-KubernetesObjectExists `
    -Kind "secret" `
    -Name "featbit-k6-controller-secret" `
    -KubeContext $targetContext
Assert-NoActiveLoadTest

$normalizedApiUrl = Normalize-ApiUrl -Value $ApiUrl
$environmentId = (& kubectl `
    --context $targetContext `
    -n $script:LoadTestNamespace `
    get configmap featbit-k6-controller `
    -o jsonpath='{.data.FEATBIT_ENVIRONMENT_ID}' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($environmentId)) {
    throw "Unable to read FEATBIT_ENVIRONMENT_ID from featbit-k6-controller."
}

$encodedAccessToken = (& kubectl `
    --context $targetContext `
    -n $script:LoadTestNamespace `
    get secret featbit-k6-controller-secret `
    -o jsonpath='{.data.FEATBIT_API_ACCESS_TOKEN}' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($encodedAccessToken)) {
    throw "Unable to read FEATBIT_API_ACCESS_TOKEN from featbit-k6-controller-secret."
}

try {
    $accessToken = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($encodedAccessToken)
    )
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw "The configured FeatBit API access token is empty."
    }

    $headers = @{
        Accept = "application/json"
        Authorization = $accessToken
    }
    $featureFlagsUrl = "$normalizedApiUrl/api/v1/envs/$environmentId/feature-flags"
    $activeFlags = @(Get-ManagedProbeFlags `
        -FeatureFlagsUrl $featureFlagsUrl `
        -Headers $headers `
        -IsArchived $false)
    $archivedFlags = @(Get-ManagedProbeFlags `
        -FeatureFlagsUrl $featureFlagsUrl `
        -Headers $headers `
        -IsArchived $true)

    foreach ($flag in $activeFlags) {
        Remove-ManagedProbeFlag `
            -FeatureFlagsUrl $featureFlagsUrl `
            -Headers $headers `
            -FlagKey $flag.key `
            -IsArchived $false
    }
    foreach ($flag in $archivedFlags) {
        Remove-ManagedProbeFlag `
            -FeatureFlagsUrl $featureFlagsUrl `
            -Headers $headers `
            -FlagKey $flag.key `
            -IsArchived $true
    }

    $expectedKeys = @(1..$ProbeFlagCount | ForEach-Object {
        "$script:ProbeFlagPrefix$($_.ToString('D2'))"
    })
    foreach ($flagKey in $expectedKeys) {
        $null = New-ManagedProbeFlag `
            -FeatureFlagsUrl $featureFlagsUrl `
            -Headers $headers `
            -FlagKey $flagKey
    }

    $verifiedActiveFlags = @(Get-ManagedProbeFlags `
        -FeatureFlagsUrl $featureFlagsUrl `
        -Headers $headers `
        -IsArchived $false)
    $verifiedArchivedFlags = @(Get-ManagedProbeFlags `
        -FeatureFlagsUrl $featureFlagsUrl `
        -Headers $headers `
        -IsArchived $true)
    if ($verifiedActiveFlags.Count -ne $ProbeFlagCount -or $verifiedArchivedFlags.Count -ne 0) {
        throw "Probe flag provisioning did not produce exactly $ProbeFlagCount active flags."
    }

    foreach ($flagKey in $expectedKeys) {
        $encodedKey = [Uri]::EscapeDataString($flagKey)
        $flag = Invoke-FeatBitRequest `
            -Method GET `
            -Uri "$featureFlagsUrl/$encodedKey" `
            -Headers $headers
        Assert-CanonicalProbeFlag -Flag $flag -ExpectedKey $flagKey
    }

    Write-Host "Prepared $ProbeFlagCount canonical probe flag(s) in baseline state."
    Write-Host "Expected revisions: $($script:RevisionValues -join ',')"
    Write-Host "Kubernetes context: $targetContext"
}
finally {
    $accessToken = $null
    $encodedAccessToken = $null
    $headers = $null
}
