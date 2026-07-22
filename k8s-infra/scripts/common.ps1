Set-StrictMode -Version Latest

$script:LocalKubernetesContext = "docker-desktop"
$script:LoadTestNamespace = "featbit-loadtest"
$script:K6Image = "featbit-k6-local:2.1.0"

function Assert-CommandAvailable {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $FailureMessage
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage (exit code $LASTEXITCODE)."
    }
}

function Assert-LocalKubernetesContext {
    Assert-CommandAvailable -Name "kubectl"

    $activeContext = (& kubectl config current-context 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read the current kubectl context."
    }

    if ($activeContext -ne $script:LocalKubernetesContext) {
        throw @"
Refusing to continue because the active kubectl context is '$activeContext'.
This local-only script requires '$($script:LocalKubernetesContext)'.
Run: kubectl config use-context $($script:LocalKubernetesContext)
"@
    }

    $nodes = (& kubectl --context $script:LocalKubernetesContext get nodes -o name 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($nodes)) {
        throw "Docker Desktop Kubernetes is not reachable or has no nodes."
    }
}

function Get-RepositoryRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Assert-KubernetesObjectExists {
    param(
        [Parameter(Mandatory)]
        [string] $Kind,

        [Parameter(Mandatory)]
        [string] $Name,

        [string] $Namespace = $script:LoadTestNamespace
    )

    & kubectl --context $script:LocalKubernetesContext -n $Namespace get $Kind $Name -o name *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Required Kubernetes object '$Kind/$Name' was not found in namespace '$Namespace'."
    }
}

