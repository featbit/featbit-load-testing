[CmdletBinding(DefaultParameterSetName = "ByKey")]
param(
    [Parameter(Mandatory)]
    [Security.SecureString] $AccessToken,

    [Parameter(Mandatory, ParameterSetName = "ByKey")]
    [string] $ProjectKey,

    [Parameter(Mandatory, ParameterSetName = "ByKey")]
    [string] $EnvironmentKey,

    [Parameter(Mandatory, ParameterSetName = "ById")]
    [Guid] $EnvironmentId,

    [Parameter(Mandatory, ParameterSetName = "List")]
    [switch] $ListEnvironments,

    [string] $ApiUrl = "http://localhost:30000",

    [string] $ClusterApiUrl = "http://featbit-api.featbit.svc.cluster.local:5000",

    [ValidateRange(0, 60)]
    [int] $WarmupSettleSeconds = 2,

    [ValidateRange(0, 300)]
    [int] $StartDelaySeconds = 5,

    [ValidateRange(1, 3600)]
    [int] $RevisionIntervalSeconds = 30,

    [ValidateRange(1, 3600)]
    [int] $FinalSettleSeconds = 30
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Normalize-HttpUrl {
    param(
        [Parameter(Mandatory)]
        [string] $Value,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $normalized = $Value.Trim().TrimEnd("/")
    if ($normalized -notmatch "^https?://") {
        throw "$Name must start with http:// or https://."
    }
    if ($normalized.Contains("?")) {
        throw "$Name must not contain query parameters."
    }

    return $normalized
}

function Invoke-FeatBitApi {
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [string] $Token
    )

    try {
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $Uri `
            -Headers @{ Authorization = $Token; Accept = "application/json" } `
            -TimeoutSec 15
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($null -eq $statusCode) {
            throw "FeatBit API request failed: $($_.Exception.Message)"
        }
        throw "FeatBit API request failed with HTTP $statusCode. Check the access token and API URL."
    }

    if ($response.success -ne $true) {
        $details = @($response.errors) -join "; "
        throw "FeatBit API rejected the request: $details"
    }

    return @($response.data)
}

Assert-LocalKubernetesContext
Assert-KubernetesObjectExists -Kind "namespace" -Name $script:LoadTestNamespace -Namespace "default"

$normalizedApiUrl = Normalize-HttpUrl -Value $ApiUrl -Name "ApiUrl"
$normalizedClusterApiUrl = Normalize-HttpUrl -Value $ClusterApiUrl -Name "ClusterApiUrl"

$secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AccessToken)
try {
    $plainAccessToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
    if ([string]::IsNullOrWhiteSpace($plainAccessToken)) {
        throw "AccessToken must not be empty."
    }

    $projects = Invoke-FeatBitApi `
        -Uri "$normalizedApiUrl/api/v1/projects" `
        -Token $plainAccessToken

    if ($PSCmdlet.ParameterSetName -eq "List") {
        $rows = foreach ($candidateProject in $projects) {
            foreach ($candidateEnvironment in @($candidateProject.environments)) {
                [pscustomobject]@{
                    ProjectName = $candidateProject.name
                    ProjectKey = $candidateProject.key
                    EnvironmentName = $candidateEnvironment.name
                    EnvironmentKey = $candidateEnvironment.key
                    EnvironmentId = $candidateEnvironment.id
                }
            }
        }
        $rows | Format-Table -AutoSize
        return
    }
    elseif ($PSCmdlet.ParameterSetName -eq "ByKey") {
        $matchingProjects = @($projects | Where-Object { $_.key -ceq $ProjectKey })
        if ($matchingProjects.Count -ne 1) {
            $available = @($projects | ForEach-Object { $_.key }) -join ", "
            throw "Project key '$ProjectKey' was not found uniquely. Available project keys: $available"
        }

        $project = $matchingProjects[0]
        $matchingEnvironments = @($project.environments | Where-Object { $_.key -ceq $EnvironmentKey })
        if ($matchingEnvironments.Count -ne 1) {
            $available = @($project.environments | ForEach-Object { $_.key }) -join ", "
            throw "Environment key '$EnvironmentKey' was not found uniquely. Available environment keys: $available"
        }
        $environment = $matchingEnvironments[0]
    }
    else {
        $matches = @(
            foreach ($candidateProject in $projects) {
                foreach ($candidateEnvironment in @($candidateProject.environments)) {
                    if ([Guid]$candidateEnvironment.id -eq $EnvironmentId) {
                        [pscustomobject]@{
                            Project = $candidateProject
                            Environment = $candidateEnvironment
                        }
                    }
                }
            }
        )
        if ($matches.Count -ne 1) {
            throw "Environment ID '$EnvironmentId' was not found uniquely in the accessible projects."
        }
        $project = $matches[0].Project
        $environment = $matches[0].Environment
    }

    $resolvedEnvironmentId = [string]$environment.id

    $configMapYaml = (& kubectl `
        --context $script:LocalKubernetesContext `
        -n $script:LoadTestNamespace `
        create configmap featbit-k6-controller `
        --from-literal="AUTO_CONTROL_REVISIONS=true" `
        --from-literal="FEATBIT_API_URL=$normalizedClusterApiUrl" `
        --from-literal="FEATBIT_ENVIRONMENT_ID=$resolvedEnvironmentId" `
        --from-literal="CONTROLLER_WARMUP_SETTLE_SECONDS=$WarmupSettleSeconds" `
        --from-literal="CONTROLLER_START_DELAY_SECONDS=$StartDelaySeconds" `
        --from-literal="CONTROLLER_REVISION_INTERVAL_SECONDS=$RevisionIntervalSeconds" `
        --from-literal="CONTROLLER_FINAL_SETTLE_SECONDS=$FinalSettleSeconds" `
        --dry-run=client `
        -o yaml | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to generate featbit-k6-controller ConfigMap."
    }

    $configMapYaml | & kubectl `
        --context $script:LocalKubernetesContext `
        -n $script:LoadTestNamespace `
        apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply featbit-k6-controller ConfigMap."
    }

    # Keep the token out of kubectl's process arguments. Kubernetes Secret data is
    # base64-encoded locally and the manifest is sent to kubectl only through stdin.
    $encodedAccessToken = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($plainAccessToken)
    )
    $secretManifest = [ordered]@{
        apiVersion = "v1"
        kind = "Secret"
        metadata = [ordered]@{
            name = "featbit-k6-controller-secret"
            namespace = $script:LoadTestNamespace
        }
        type = "Opaque"
        data = [ordered]@{
            FEATBIT_API_ACCESS_TOKEN = $encodedAccessToken
        }
    } | ConvertTo-Json -Depth 5

    $secretManifest | & kubectl `
        --context $script:LocalKubernetesContext `
        -n $script:LoadTestNamespace `
        apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply featbit-k6-controller-secret Secret."
    }

    Write-Host ""
    Write-Host "REST controller configured." -ForegroundColor Green
    Write-Host "Project: $($project.name) [$($project.key)]"
    Write-Host "Environment: $($environment.name) [$($environment.key)]"
    Write-Host "Environment ID: $resolvedEnvironmentId"
    Write-Host "Runner API URL: $normalizedClusterApiUrl"
    Write-Host "Pre-test warm-up settle: ${WarmupSettleSeconds}s per step"
}
finally {
    if ($secretPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
    }
    $plainAccessToken = $null
    $encodedAccessToken = $null
    $secretManifest = $null
}
