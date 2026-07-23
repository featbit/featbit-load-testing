[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $StreamingUrl,

    [Parameter(Mandatory)]
    [Security.SecureString] $ServerSecret,

    [string] $KubeContext = "docker-desktop"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext
Assert-KubernetesObjectExists `
    -Kind "namespace" `
    -Name $script:LoadTestNamespace `
    -Namespace "default" `
    -KubeContext $targetContext

$normalizedStreamingUrl = $StreamingUrl.Trim().TrimEnd("/")
if ($normalizedStreamingUrl -notmatch "^wss?://") {
    throw "StreamingUrl must start with ws:// or wss://."
}
if ($normalizedStreamingUrl.Contains("?")) {
    throw "StreamingUrl must not contain query parameters."
}

$secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ServerSecret)
try {
    $plainServerSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
    if ([string]::IsNullOrWhiteSpace($plainServerSecret)) {
        throw "ServerSecret must not be empty."
    }

    $configMapYaml = (& kubectl `
        --context $targetContext `
        -n $script:LoadTestNamespace `
        create configmap featbit-k6-target `
        --from-literal="FEATBIT_STREAMING_URL=$normalizedStreamingUrl" `
        --from-literal="PROBE_INITIAL_VALUE=baseline" `
        --from-literal="EXPECTED_REVISIONS=rev-001,rev-002" `
        --from-literal="STRICT_PATCH_DELIVERY=false" `
        --dry-run=client `
        -o yaml | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to generate featbit-k6-target ConfigMap."
    }

    $configMapYaml | & kubectl `
        --context $targetContext `
        -n $script:LoadTestNamespace `
        apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply featbit-k6-target ConfigMap."
    }

    $secretYaml = (& kubectl `
        --context $targetContext `
        -n $script:LoadTestNamespace `
        create secret generic featbit-k6-secret `
        --from-literal="FEATBIT_SERVER_SECRET=$plainServerSecret" `
        --dry-run=client `
        -o yaml | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to generate featbit-k6-secret Secret."
    }

    $secretYaml | & kubectl `
        --context $targetContext `
        -n $script:LoadTestNamespace `
        apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply featbit-k6-secret Secret."
    }
}
finally {
    if ($secretPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
    }
    $plainServerSecret = $null
    $secretYaml = $null
}

Write-Host ""
Write-Host "Kubernetes context: $targetContext"
Write-Host "Target configured: $normalizedStreamingUrl"
Write-Host "Next: run-test.ps1 -Profile smoke"
