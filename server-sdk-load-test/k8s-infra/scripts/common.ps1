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
    Assert-KubernetesContext `
        -KubeContext $script:LocalKubernetesContext `
        -RequireActive
}

function Assert-KubernetesContext {
    param(
        [Parameter(Mandatory)]
        [string] $KubeContext,

        [switch] $RequireActive
    )

    Assert-CommandAvailable -Name "kubectl"

    $normalizedContext = $KubeContext.Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedContext)) {
        throw "KubeContext must not be empty."
    }

    $availableContexts = @(& kubectl config get-contexts -o name 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list kubectl contexts."
    }
    if ($availableContexts -notcontains $normalizedContext) {
        throw "kubectl context '$normalizedContext' does not exist."
    }

    $activeContext = (& kubectl config current-context 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read the current kubectl context."
    }

    if ($RequireActive -and $activeContext -ne $normalizedContext) {
        throw @"
Refusing to continue because the active kubectl context is '$activeContext'.
This command requires '$normalizedContext' as the active context.
Run: kubectl config use-context $normalizedContext
"@
    }

    $nodes = (& kubectl --context $normalizedContext get nodes -o name 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($nodes)) {
        throw "Kubernetes context '$normalizedContext' is not reachable or has no nodes."
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

        [string] $Namespace = $script:LoadTestNamespace,

        [string] $KubeContext = $script:LocalKubernetesContext
    )

    & kubectl --context $KubeContext -n $Namespace get $Kind $Name -o name *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Required Kubernetes object '$Kind/$Name' was not found in namespace '$Namespace' through context '$KubeContext'."
    }
}
