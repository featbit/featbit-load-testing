[CmdletBinding()]
param(
    [ValidatePattern("^featbitloadtesting22793c56acr$")]
    [string] $AcrName = "featbitloadtesting22793c56acr",

    [ValidatePattern("^[a-z0-9][a-z0-9._/-]*$")]
    [string] $Repository = "featbit-dotnet-sdk-loadtest"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$repositoryRoot = Get-RepositoryRoot
$dockerfile = Join-Path $repositoryRoot "k8s-infra\Dockerfile.dotnet-sdk-runner"
$projectFile = Join-Path $repositoryRoot (
    "dotnet-sdk-runner\src\FeatBit.ServerSdk.LoadTest\" +
    "FeatBit.ServerSdk.LoadTest.csproj"
)
if (
    -not (Test-Path -LiteralPath $dockerfile -PathType Leaf) -or
    -not (Test-Path -LiteralPath $projectFile -PathType Leaf)
) {
    throw "The .NET SDK runner Docker build inputs are incomplete."
}

$sourceFiles = @(
    Get-ChildItem `
        -LiteralPath (
            Join-Path $repositoryRoot (
                "dotnet-sdk-runner\src\FeatBit.ServerSdk.LoadTest"
            )
        ) `
        -File |
        Sort-Object Name
)
$hashInput = (
    @($sourceFiles | ForEach-Object {
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }) +
    (Get-FileHash -LiteralPath $dockerfile -Algorithm SHA256).Hash
) -join ""
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $sourceDigest = [Convert]::ToHexString(
        $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($hashInput))
    ).ToLowerInvariant()
}
finally {
    $sha.Dispose()
}
$tag = "p500-{0}-{1}" -f
    [DateTime]::UtcNow.ToString("yyyyMMddHHmmss"),
    $sourceDigest.Substring(0, 10)
$taggedImage = "$Repository`:$tag"

Write-Host (
    "Building the official .NET SDK pilot image in test ACR '$AcrName'."
)
Write-Host "Source fingerprint: $sourceDigest"
Write-Host "Tag: $taggedImage"

& az acr build `
    --registry $AcrName `
    --image $taggedImage `
    --file $dockerfile `
    $repositoryRoot
if ($LASTEXITCODE -ne 0) {
    throw "ACR build failed."
}

$loginServer = (
    & az acr show `
        --name $AcrName `
        --query loginServer `
        --output tsv |
        Out-String
).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($loginServer)) {
    throw "Failed to resolve the test ACR login server."
}
$digest = (
    & az acr repository show `
        --name $AcrName `
        --image $taggedImage `
        --query digest `
        --output tsv |
        Out-String
).Trim()
if ($LASTEXITCODE -ne 0 -or $digest -notmatch "^sha256:[a-f0-9]{64}$") {
    throw "Failed to resolve the immutable runner image digest."
}
$image = "$loginServer/$Repository@$digest"

Write-Host ""
Write-Host "Immutable runner image: $image" -ForegroundColor Green

[pscustomobject]@{
    AcrName = $AcrName
    Repository = $Repository
    Tag = $tag
    TaggedImage = "$loginServer/$taggedImage"
    Digest = $digest
    Image = $image
    SourceFingerprint = $sourceDigest
}
