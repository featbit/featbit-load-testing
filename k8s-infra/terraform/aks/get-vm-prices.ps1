[CmdletBinding()]
param(
    [string] $Location = "eastasia",

    [ValidatePattern("^[A-Z]{3}$")]
    [string] $Currency = "USD",

    [string[]] $VmSizes = @(
        "Standard_D2ds_v5",
        "Standard_D4ds_v5",
        "Standard_D8ds_v5",
        "Standard_D16ds_v5"
    ),

    [ValidateRange(1, 8760)]
    [int] $MonthlyHours = 730
)

$ErrorActionPreference = "Stop"
$endpoint = "https://prices.azure.com/api/retail/prices"
$rows = foreach ($vmSize in $VmSizes) {
    $filter = @(
        "serviceName eq 'Virtual Machines'"
        "armRegionName eq '$Location'"
        "armSkuName eq '$vmSize'"
        "priceType eq 'Consumption'"
    ) -join " and "

    $uri = "${endpoint}?currencyCode='$Currency'&`$filter=$([Uri]::EscapeDataString($filter))"
    $response = Invoke-RestMethod -Method Get -Uri $uri
    $meters = @($response.Items | Where-Object {
        $_.type -eq "Consumption" -and
        $_.productName -notmatch "Windows" -and
        $_.skuName -notmatch "Spot|Low Priority" -and
        $_.meterName -notmatch "Spot|Low Priority"
    })

    if ($meters.Count -ne 1) {
        throw "Expected one Linux pay-as-you-go meter for $vmSize in $Location; found $($meters.Count)."
    }

    $meter = $meters[0]
    [pscustomobject]@{
        Region = $Location
        VmSize = $vmSize
        Currency = $meter.currencyCode
        Hourly = [math]::Round([double] $meter.retailPrice, 6)
        MonthlyHours = $MonthlyHours
        Monthly = [math]::Round([double] $meter.retailPrice * $MonthlyHours, 2)
        EffectiveStart = [DateTime] $meter.effectiveStartDate
        MeterId = $meter.meterId
    }
}

$rows
