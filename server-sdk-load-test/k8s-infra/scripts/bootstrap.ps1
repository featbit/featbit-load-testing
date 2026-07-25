[CmdletBinding()]
param(
    [switch] $SkipImageBuild
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

Assert-LocalKubernetesContext
Assert-CommandAvailable -Name "docker"
Assert-CommandAvailable -Name "helm"

$repositoryRoot = Get-RepositoryRoot
$dockerfile = Join-Path $repositoryRoot "k8s-infra\Dockerfile.k6"
$baseManifest = Join-Path $repositoryRoot "k8s-infra\manifests\local-base.yaml"

if (-not $SkipImageBuild) {
    Write-Host "Building $script:K6Image ..."
    Invoke-CheckedCommand `
        -FilePath "docker" `
        -ArgumentList @("build", "--file", $dockerfile, "--tag", $script:K6Image, $repositoryRoot) `
        -FailureMessage "Failed to build the local k6 image"
}

# Isolate this command from unrelated or broken repositories in the user's Helm cache.
$helmStateDirectory = Join-Path ([IO.Path]::GetTempPath()) "featbit-loadtest-helm"
$null = New-Item -ItemType Directory -Force $helmStateDirectory
$previousRepositoryConfig = $env:HELM_REPOSITORY_CONFIG
$previousRepositoryCache = $env:HELM_REPOSITORY_CACHE

try {
    $env:HELM_REPOSITORY_CONFIG = Join-Path $helmStateDirectory "repositories.yaml"
    $env:HELM_REPOSITORY_CACHE = Join-Path $helmStateDirectory "cache"

    Write-Host "Installing k6 Operator chart 4.5.0 ..."
    Invoke-CheckedCommand `
        -FilePath "helm" `
        -ArgumentList @(
            "upgrade", "--install", "k6-operator", "k6-operator",
            "--repo", "https://grafana.github.io/helm-charts",
            "--version", "4.5.0",
            "--namespace", "k6-operator-system",
            "--create-namespace",
            # Helm creates the release namespace. Disable the chart's Namespace
            # resource so an existing namespace is not created a second time.
            "--set", "namespace.create=false",
            "--kube-context", $script:LocalKubernetesContext,
            "--wait",
            "--timeout", "5m"
        ) `
        -FailureMessage "Failed to install k6 Operator"
}
finally {
    if ($null -eq $previousRepositoryConfig) {
        Remove-Item Env:HELM_REPOSITORY_CONFIG -ErrorAction SilentlyContinue
    }
    else {
        $env:HELM_REPOSITORY_CONFIG = $previousRepositoryConfig
    }

    if ($null -eq $previousRepositoryCache) {
        Remove-Item Env:HELM_REPOSITORY_CACHE -ErrorAction SilentlyContinue
    }
    else {
        $env:HELM_REPOSITORY_CACHE = $previousRepositoryCache
    }
}

Write-Host "Applying local test namespace and result storage ..."
Invoke-CheckedCommand `
    -FilePath "kubectl" `
    -ArgumentList @("--context", $script:LocalKubernetesContext, "apply", "-f", $baseManifest) `
    -FailureMessage "Failed to apply the local base manifest"

Invoke-CheckedCommand `
    -FilePath "kubectl" `
    -ArgumentList @(
        "--context", $script:LocalKubernetesContext,
        "-n", $script:LoadTestNamespace,
        "wait", "--for=condition=Ready", "pod/results-reader", "--timeout=120s"
    ) `
    -FailureMessage "The results-reader Pod did not become ready"

Invoke-CheckedCommand `
    -FilePath "kubectl" `
    -ArgumentList @(
        "--context", $script:LocalKubernetesContext,
        "get", "crd", "testruns.k6.io", "-o", "name"
    ) `
    -FailureMessage "The k6 TestRun CRD is unavailable"

Write-Host ""
Write-Host "Local k6 infrastructure is ready."
Write-Host "Next: deploy FeatBit yourself, then run configure-target.ps1."
