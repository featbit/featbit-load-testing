[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 20)]
    [int] $ProbeFlagCount,

    [string] $ApiUrl = "http://localhost:30000"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$script:ProbeFlagPrefix = "loadtest-sync-probe-"
$script:RequiredProbeValues = @("baseline", "rev-001", "rev-002")

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
        $statusCode = if ($null -eq $_.Exception.Response) {
            $null
        }
        else {
            [int]$_.Exception.Response.StatusCode
        }
        if ($null -eq $statusCode) {
            throw "FeatBit API request failed: $($_.Exception.Message)"
        }
        throw "FeatBit API request failed with HTTP $statusCode."
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
    $revision1Id = [Guid]::NewGuid().ToString()
    $revision2Id = [Guid]::NewGuid().ToString()
    $number = $FlagKey.Substring($script:ProbeFlagPrefix.Length)

    $payload = [ordered]@{
        name = "Load-test sync probe $number"
        key = $FlagKey
        isEnabled = $true
        description = "Reserved for the automated Server SDK streaming load test."
        variationType = "string"
        variations = @(
            [ordered]@{ id = $baselineId; name = "Baseline"; value = "baseline" }
            [ordered]@{ id = $revision1Id; name = "Revision 1"; value = "rev-001" }
            [ordered]@{ id = $revision2Id; name = "Revision 2"; value = "rev-002" }
        )
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

Assert-LocalKubernetesContext
Assert-KubernetesObjectExists -Kind "configmap" -Name "featbit-k6-controller"
Assert-KubernetesObjectExists -Kind "secret" -Name "featbit-k6-controller-secret"

$normalizedApiUrl = Normalize-ApiUrl -Value $ApiUrl
$environmentId = (& kubectl `
    --context $script:LocalKubernetesContext `
    -n $script:LoadTestNamespace `
    get configmap featbit-k6-controller `
    -o jsonpath='{.data.FEATBIT_ENVIRONMENT_ID}' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($environmentId)) {
    throw "Unable to read FEATBIT_ENVIRONMENT_ID from featbit-k6-controller."
}

$encodedAccessToken = (& kubectl `
    --context $script:LocalKubernetesContext `
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
}
finally {
    $accessToken = $null
    $encodedAccessToken = $null
    $headers = $null
}
