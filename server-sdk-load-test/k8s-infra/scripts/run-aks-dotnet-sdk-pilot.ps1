[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("validation", "formal")]
    [string] $RunKind,

    [Parameter(Mandatory)]
    [ValidatePattern("^aks-featbit-load-testing$")]
    [string] $KubeContext,

    [Parameter(Mandatory)]
    [string] $RunnerImage,

    [Parameter(Mandatory)]
    [string] $ControllerImage,

    [ValidateRange(180, 900)]
    [int] $StartDelaySeconds = 300,

    [string] $MatrixPath = "",

    [string] $Note = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content,
        [switch] $AllowOverwrite
    )

    if (-not $AllowOverwrite -and (Test-Path -LiteralPath $Path)) {
        throw "Refusing to overwrite existing artifact: $Path"
    }
    [IO.File]::WriteAllText(
        $Path,
        $Content,
        [Text.UTF8Encoding]::new($false)
    )
}

function Add-JsonLine {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][object] $Record
    )

    $json = $Record | ConvertTo-Json -Depth 12 -Compress
    [IO.File]::AppendAllText(
        $Path,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
}

function Add-ExperimentEvent {
    param(
        [Parameter(Mandatory)][string] $Event,
        [hashtable] $Fields = @{}
    )

    if ([string]::IsNullOrWhiteSpace($script:experimentEventsPath)) {
        return
    }
    $record = [ordered]@{
        schemaVersion = 1
        event = $Event
        atUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        atUtc = [DateTime]::UtcNow.ToString("o")
        runId = $script:runId
    }
    foreach ($entry in $Fields.GetEnumerator()) {
        $record[$entry.Key] = $entry.Value
    }
    Add-JsonLine -Path $script:experimentEventsPath -Record $record
}

function Read-KubectlJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $FailureMessage,
        [switch] $AllowNotFound
    )

    $text = (& kubectl @Arguments 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0) {
        if ($AllowNotFound) {
            return $null
        }
        throw $FailureMessage
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw $FailureMessage
    }
    return $text | ConvertFrom-Json
}

function Get-StatusInt {
    param(
        [Parameter(Mandatory)][object] $Object,
        [Parameter(Mandatory)][string] $Name
    )

    $property = $Object.status.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return 0
    }
    return [int]$property.Value
}

function Assert-DigestImage {
    param(
        [Parameter(Mandatory)][string] $Image,
        [Parameter(Mandatory)][string] $Name
    )

    if (
        $Image -notmatch
            "^[A-Za-z0-9._:/-]+@sha256:[a-fA-F0-9]{64}$" -or
        $Image -notmatch "/"
    ) {
        throw "$Name must be an immutable registry image digest."
    }
}

function Test-RunnerImagePull {
    param([Parameter(Mandatory)][string] $Image)

    $name = "dotnet-p500-preflight-" +
        [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $job = [ordered]@{
        apiVersion = "batch/v1"
        kind = "Job"
        metadata = [ordered]@{
            name = $name
            namespace = $script:namespace
            labels = [ordered]@{
                "app.kubernetes.io/name" = "featbit-dotnet-sdk-preflight"
                "app.kubernetes.io/part-of" = "featbit-load-testing"
            }
        }
        spec = [ordered]@{
            backoffLimit = 0
            template = [ordered]@{
                metadata = [ordered]@{
                    labels = [ordered]@{
                        "app.kubernetes.io/name" =
                            "featbit-dotnet-sdk-preflight"
                    }
                }
                spec = [ordered]@{
                    restartPolicy = "Never"
                    nodeSelector = [ordered]@{ workload = "loadgen" }
                    tolerations = @(
                        [ordered]@{
                            key = "workload"
                            operator = "Equal"
                            value = "loadgen"
                            effect = "NoSchedule"
                        }
                    )
                    securityContext = [ordered]@{
                        runAsNonRoot = $true
                        runAsUser = 12345
                        runAsGroup = 12345
                        seccompProfile = [ordered]@{
                            type = "RuntimeDefault"
                        }
                    }
                    containers = @(
                        [ordered]@{
                            name = "preflight"
                            image = $Image
                            imagePullPolicy = "IfNotPresent"
                            args = @("--version")
                            resources = [ordered]@{
                                requests = [ordered]@{
                                    cpu = "100m"
                                    memory = "128Mi"
                                }
                                limits = [ordered]@{
                                    cpu = "1"
                                    memory = "512Mi"
                                }
                            }
                            securityContext = [ordered]@{
                                allowPrivilegeEscalation = $false
                                capabilities = [ordered]@{
                                    drop = @("ALL")
                                }
                            }
                        }
                    )
                }
            }
        }
    }
    $job |
        ConvertTo-Json -Depth 18 |
        & kubectl --context $script:targetContext apply -f - *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create runner image preflight Job '$name'."
    }
    & kubectl --context $script:targetContext `
        -n $script:namespace `
        wait "job/$name" `
        --for=condition=complete `
        --timeout=5m *> $null
    $waitExit = $LASTEXITCODE
    $log = (
        & kubectl --context $script:targetContext `
            -n $script:namespace `
            logs "job/$name" 2>&1 |
            Out-String
    ).Trim()
    if (
        $waitExit -ne 0 -or
        $LASTEXITCODE -ne 0 -or
        $log -notmatch
            "FeatBit\.ServerSdk\.LoadTest/1\.0\.0 FeatBit\.ServerSdk/1\.2\.11"
    ) {
        throw (
            "Runner image preflight failed; Job '$name' was preserved."
        )
    }
    Write-Host "Runner image preflight passed: $log"
    return $name
}

function Ensure-StreamingObserver {
    $daemonSet = Read-KubectlJson `
        -Arguments @(
            "--context", $script:targetContext,
            "-n", "featbit",
            "get", "daemonset", "featbit-stream-timing",
            "-o", "json"
        ) `
        -FailureMessage "Failed to inspect the Redis observer." `
        -AllowNotFound
    if ($null -eq $daemonSet) {
        $sourceRunId = "growth-dotnet-observer-{0}-{1}" -f
            [DateTime]::UtcNow.ToString("yyyyMMddHHmmss"),
            [Guid]::NewGuid().ToString("N").Substring(0, 4)
        & (Join-Path $PSScriptRoot "start-aks-streaming-timing.ps1") `
            -RunId $sourceRunId `
            -KubeContext $script:targetContext `
            -ExpectedLoadgenNodes 10 | Out-Host
        return $sourceRunId
    }
    if (
        [int]$daemonSet.status.desiredNumberScheduled -ne 10 -or
        [int]$daemonSet.status.numberReady -ne 10
    ) {
        throw "The existing Redis observer is not ready on all 10 loadgen nodes."
    }
    return [string](
        $daemonSet.metadata.labels."loadtest.featbit.io/run-id"
    )
}

function Ensure-OneSecondCollector {
    $daemonSet = Read-KubectlJson `
        -Arguments @(
            "--context", $script:targetContext,
            "-n", $script:namespace,
            "get", "daemonset", "featbit-1s-evidence",
            "-o", "json"
        ) `
        -FailureMessage "Failed to inspect the one-second collector." `
        -AllowNotFound
    if ($null -eq $daemonSet) {
        $sourceRunId = "growth-dotnet-evidence-{0}-{1}" -f
            [DateTime]::UtcNow.ToString("yyyyMMddHHmmss"),
            [Guid]::NewGuid().ToString("N").Substring(0, 4)
        & (Join-Path $PSScriptRoot "start-aks-1s-evidence.ps1") `
            -RunId $sourceRunId `
            -KubeContext $script:targetContext `
            -ExpectedElsPods 3 `
            -ExpectedElsNodes 3 `
            -ExpectedFeatBitNodes 3 `
            -ExpectedLoadgenNodes 10 `
            -PreserveOnFailure | Out-Host
        return $sourceRunId
    }
    if (
        [int]$daemonSet.status.desiredNumberScheduled -ne 13 -or
        [int]$daemonSet.status.numberReady -ne 13
    ) {
        throw (
            "The existing one-second collector is not ready on all " +
            "3 FeatBit and 10 loadgen nodes."
        )
    }
    return [string](
        $daemonSet.metadata.labels."loadtest.featbit.io/run-id"
    )
}

function New-ControllerJob {
    $controllerName = "ctrl-$($script:runId)"
    if ($controllerName.Length -gt 63) {
        throw "Generated controller Job name exceeds 63 characters."
    }
    $job = [ordered]@{
        apiVersion = "batch/v1"
        kind = "Job"
        metadata = [ordered]@{
            name = $controllerName
            namespace = $script:namespace
            labels = [ordered]@{
                "app.kubernetes.io/name" = "featbit-k6-controller"
                "app.kubernetes.io/part-of" = "featbit-load-testing"
                "loadtest.featbit.io/run-id" = $script:runId
            }
        }
        spec = [ordered]@{
            backoffLimit = 0
            template = [ordered]@{
                metadata = [ordered]@{
                    labels = [ordered]@{
                        "app.kubernetes.io/name" =
                            "featbit-k6-controller"
                        "app.kubernetes.io/part-of" =
                            "featbit-load-testing"
                        "loadtest.featbit.io/run-id" = $script:runId
                    }
                }
                spec = [ordered]@{
                    restartPolicy = "Never"
                    nodeSelector = [ordered]@{ workload = "loadgen" }
                    tolerations = @(
                        [ordered]@{
                            key = "workload"
                            operator = "Equal"
                            value = "loadgen"
                            effect = "NoSchedule"
                        }
                    )
                    securityContext = [ordered]@{
                        runAsNonRoot = $true
                        runAsUser = 12345
                        runAsGroup = 12345
                        seccompProfile = [ordered]@{
                            type = "RuntimeDefault"
                        }
                    }
                    containers = @(
                        [ordered]@{
                            name = "controller"
                            image = [string]$script:metadata.controllerImage
                            imagePullPolicy = "IfNotPresent"
                            command = @(
                                "sh", "-c",
                                (
                                    "touch /tmp/controller-ready; " +
                                    "while [ ! -f /tmp/controller-stop ]; " +
                                    "do sleep 1; done"
                                )
                            )
                            readinessProbe = [ordered]@{
                                exec = [ordered]@{
                                    command = @(
                                        "sh", "-c",
                                        "test -f /tmp/controller-ready"
                                    )
                                }
                                periodSeconds = 1
                                timeoutSeconds = 1
                                failureThreshold = 120
                            }
                            env = @(
                                [ordered]@{
                                    name = "FEATBIT_API_URL"
                                    value = [string](
                                        $script:matrix.configurationApiUrl
                                    )
                                }
                            )
                            envFrom = @(
                                [ordered]@{
                                    configMapRef = [ordered]@{
                                        name = [string](
                                            $script:matrix.
                                                kubernetesObjects.configMap
                                        )
                                    }
                                },
                                [ordered]@{
                                    secretRef = [ordered]@{
                                        name = [string](
                                            $script:matrix.
                                                kubernetesObjects.
                                                controllerSecret
                                        )
                                    }
                                }
                            )
                            resources = [ordered]@{
                                requests = [ordered]@{
                                    cpu = "100m"
                                    memory = "128Mi"
                                }
                                limits = [ordered]@{
                                    cpu = "1"
                                    memory = "512Mi"
                                }
                            }
                            securityContext = [ordered]@{
                                allowPrivilegeEscalation = $false
                                capabilities = [ordered]@{
                                    drop = @("ALL")
                                }
                            }
                        }
                    )
                }
            }
        }
    }
    $job |
        ConvertTo-Json -Depth 20 |
        & kubectl --context $script:targetContext apply -f - *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create controller Job '$controllerName'."
    }
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        $pods = Read-KubectlJson `
            -Arguments @(
                "--context", $script:targetContext,
                "-n", $script:namespace,
                "get", "pods",
                "-l", (
                    "app.kubernetes.io/name=featbit-k6-controller," +
                    "loadtest.featbit.io/run-id=$($script:runId)"
                ),
                "-o", "json"
            ) `
            -FailureMessage "Failed to inspect the controller Pod."
        $ready = @($pods.items | Where-Object {
            $_.status.phase -eq "Running" -and
            @($_.status.containerStatuses | Where-Object ready).Count -eq 1
        })
        if ($ready.Count -eq 1) {
            $script:controllerJobName = $controllerName
            $script:controllerPodName =
                [string]$ready[0].metadata.name
            return
        }
        $allPods = @($pods.items)
        if ($allPods.Count -gt 0) {
            $statuses = @($allPods[0].status.containerStatuses)
            if ($statuses.Count -gt 0) {
                $terminatedProperty =
                    $statuses[0].state.PSObject.Properties["terminated"]
                if (
                    $null -ne $terminatedProperty -and
                    [int]$terminatedProperty.Value.exitCode -ne 0
                ) {
                    throw "Controller Pod terminated before becoming ready."
                }
            }
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for the controller Pod."
        }
        Start-Sleep -Seconds 2
    } while ($true)
}

function Get-RunnerPods {
    $pods = Read-KubectlJson `
        -Arguments @(
            "--context", $script:targetContext,
            "-n", $script:namespace,
            "get", "pods",
            "-l", (
                "app.kubernetes.io/name=featbit-dotnet-sdk-runner," +
                "loadtest.featbit.io/run-id=$($script:runId)"
            ),
            "-o", "json"
        ) `
        -FailureMessage "Failed to inspect .NET runner Pods."
    return @($pods.items)
}

function Wait-RunnerPodsReady {
    $deadlineUnixMs = [int64]$script:metadata.startAtUnixMs - 10000L
    do {
        $pods = @(Get-RunnerPods)
        $ready = @($pods | Where-Object {
            $_.status.phase -eq "Running" -and
            @($_.status.containerStatuses | Where-Object ready).Count -eq 1
        })
        Write-Host (
            "{0:HH:mm:ss} .NET runner Pods ready={1}/20" -f
            [DateTime]::Now,
            $ready.Count
        )
        $failed = @($pods | Where-Object {
            $_.status.phase -eq "Failed"
        })
        if ($failed.Count -gt 0) {
            throw "A .NET runner Pod failed before the shared start gate."
        }
        if ($ready.Count -eq 20) {
            $groups = @($ready | Group-Object { $_.spec.nodeName })
            if (
                $groups.Count -ne 10 -or
                @($groups | Where-Object Count -ne 2).Count -ne 0
            ) {
                throw (
                    "Runner placement is not exactly two Pods on each " +
                    "of ten loadgen nodes."
                )
            }
            return $ready
        }
        if (
            [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -ge
                $deadlineUnixMs
        ) {
            throw (
                "All 20 runner Pods were not ready at least ten seconds " +
                "before the shared start gate."
            )
        }
        Start-Sleep -Seconds 3
    } while ($true)
}

function Get-RemoteEvents {
    param([Parameter(Mandatory)][string] $EventName)

    if ($EventName -notmatch "^[a-z0-9_]+$") {
        throw "Unsafe event name '$EventName'."
    }
    $needle = '"event":"' + $EventName + '"'
    $command = (
        "grep -h '$needle' " +
        "/results/$($script:runId)/*-events.jsonl 2>/dev/null || true"
    )
    $text = (
        & kubectl --context $script:targetContext `
            -n $script:namespace `
            exec results-reader -- sh -c $command |
            Out-String
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read '$EventName' events from the results PVC."
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }
    return @(
        $text -split "\r?\n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
}

function Wait-SdkReadyCoverage {
    $deadline = [DateTimeOffset]::FromUnixTimeMilliseconds(
        [int64]$script:metadata.startAtUnixMs
    ).UtcDateTime.AddSeconds(
        [int]$script:matrix.readyCoverageTimeoutSeconds
    )
    do {
        $ready = @(Get-RemoteEvents -EventName "sdk_ready")
        $unique = @(
            $ready |
                Group-Object { "$($_.runner)|$($_.localConnection)" }
        )
        Write-Host (
            "{0:HH:mm:ss} official SDK initialized={1}/500" -f
            [DateTime]::Now,
            $unique.Count
        )
        $creationFailures = @(
            Get-RemoteEvents -EventName "client_create_failed"
        )
        if ($creationFailures.Count -gt 0) {
            $first = $creationFailures[0]
            throw (
                "Detected $($creationFailures.Count) SDK client creation " +
                "failure(s); first=$([string]$first.errorType): " +
                [string]$first.message
            )
        }
        if (
            $ready.Count -gt 500 -or
            @($unique | Where-Object Count -ne 1).Count -gt 0
        ) {
            throw "SDK readiness evidence contains duplicate connection identities."
        }
        if ($unique.Count -eq 500) {
            $canaries = @(
                Get-RemoteEvents -EventName "canary_flag_count"
            )
            $matched = @($canaries | Where-Object matched).Count
            if (
                $canaries.Count -gt 20 -or
                @($canaries | Where-Object { -not $_.matched }).Count -gt 0
            ) {
                throw (
                    "Expected 20/20 canaries to confirm exactly 3,000 flags; " +
                    "found $matched/$($canaries.Count)."
                )
            }
            if ($canaries.Count -eq 20 -and $matched -eq 20) {
                return $ready
            }
            Write-Host (
                "{0:HH:mm:ss} 3,000-flag canaries={1}/20" -f
                [DateTime]::Now,
                $matched
            )
        }
        $job = Read-KubectlJson `
            -Arguments @(
                "--context", $script:targetContext,
                "-n", $script:namespace,
                "get", "job", $script:jobName,
                "-o", "json"
            ) `
            -FailureMessage "Failed to inspect the runner Job."
        if ((Get-StatusInt -Object $job -Name "failed") -gt 0) {
            throw "The runner Job failed before 500 SDK clients initialized."
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Official SDK initialization did not reach 500/500 in time."
        }
        Start-Sleep -Seconds 5
    } while ($true)
}

function Get-VariationCoverage {
    param(
        [Parameter(Mandatory)][string] $FlagKey,
        [Parameter(Mandatory)][string] $Revision,
        [Parameter(Mandatory)][int64] $AfterUnixMs,
        [Parameter(Mandatory)][int] $RevisionIndex
    )

    $events = @(Get-RemoteEvents -EventName "variation_observed")
    $matching = @($events | Where-Object {
        [string]$_.environmentId -ceq
            [string]$script:metadata.targetEnvironmentId -and
        [string]$_.flagKey -ceq $FlagKey -and
        [string]$_.revision -ceq $Revision -and
        [int]$_.revisionIndex -eq $RevisionIndex -and
        [int64]$_.atUnixMs -ge $AfterUnixMs
    })
    $unique = @(
        $matching |
            Group-Object { "$($_.runner)|$($_.localConnection)" }
    )
    if (
        $matching.Count -gt 500 -or
        @($unique | Where-Object Count -ne 1).Count -gt 0
    ) {
        throw (
            "Variation '$FlagKey/$Revision' contains duplicate SDK " +
            "delivery identities."
        )
    }
    return [pscustomobject]@{
        Count = $matching.Count
        Unique = $unique.Count
    }
}

function Wait-VariationCoverage {
    param(
        [Parameter(Mandatory)][string] $FlagKey,
        [Parameter(Mandatory)][string] $Revision,
        [Parameter(Mandatory)][int64] $AfterUnixMs,
        [Parameter(Mandatory)][int] $RevisionIndex,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $coverage = Get-VariationCoverage `
            -FlagKey $FlagKey `
            -Revision $Revision `
            -AfterUnixMs $AfterUnixMs `
            -RevisionIndex $RevisionIndex
        Write-Host (
            "{0:HH:mm:ss} {1}: {2}/500" -f
            [DateTime]::Now,
            $Label,
            $coverage.Unique
        )
        if ($coverage.Unique -eq 500 -and $coverage.Count -eq 500) {
            return $coverage
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "$Label did not reach exactly 500/500 within $TimeoutSeconds seconds."
        }
        Start-Sleep -Seconds 2
    } while ($true)
}

function Add-ControlRecords {
    param([Parameter(Mandatory)][string] $Text)

    $matches = [regex]::Matches(
        $Text,
        (
            "STREAM_CONTROL\|2\|" +
            "(?<event>request_start|request_end|request_error)\|" +
            "(?<at>\d+)\|(?<run>[^|]+)\|(?<environment>[^|]+)\|" +
            "(?<index>\d+)\|(?<revision>[^|]+)\|(?<flag>[^|]+)\|" +
            "(?<attempt>\d+)"
        )
    )
    $records = [Collections.Generic.List[object]]::new()
    foreach ($match in $matches) {
        $record = [ordered]@{
            schemaVersion = 2
            event = $match.Groups["event"].Value
            atUnixMs = [int64]$match.Groups["at"].Value
            runId = $match.Groups["run"].Value
            environmentId = $match.Groups["environment"].Value
            revisionIndex = [int]$match.Groups["index"].Value
            revision = $match.Groups["revision"].Value
            flagKey = $match.Groups["flag"].Value
            attempt = [int]$match.Groups["attempt"].Value
        }
        if ($record.runId -cne $script:runId) {
            throw "Controller emitted an unexpected run ID."
        }
        Add-JsonLine -Path $script:controllerEventsPath -Record $record
        $records.Add([pscustomobject]$record)
    }
    return @($records)
}

function Invoke-ControllerUpdate {
    param(
        [Parameter(Mandatory)][string] $FlagKey,
        [Parameter(Mandatory)][string] $TargetRevision,
        [Parameter(Mandatory)][ValidateSet("string", "json")]
        [string] $VariationType,
        [Parameter(Mandatory)][string] $Phase,
        [ValidateRange(0, 100)][int] $RevisionIndex = 0,
        [ValidateRange(0, [int64]::MaxValue)][int64] $DueUnixMs = 0,
        [switch] $AllowAlreadyServed
    )

    $arguments = @(
        "--context", $script:targetContext,
        "-n", $script:namespace,
        "exec", $script:controllerPodName, "--",
        "k6", "run", "--summary-mode", "disabled",
        "-e", "RUN_ID=$($script:runId)",
        "-e", "CONTROLLER_FLAG_KEY=$FlagKey",
        "-e", "CONTROLLER_TARGET_REVISION=$TargetRevision",
        "-e", "CONTROLLER_REQUIRED_REVISIONS=$TargetRevision",
        "-e", "CONTROLLER_VARIATION_TYPE=$VariationType",
        "-e", "CONTROLLER_PHASE=$Phase",
        "-e", "CONTROLLER_REVISION_INDEX=$RevisionIndex",
        "-e", "CONTROLLER_DUE_UNIX_MS=$DueUnixMs",
        "-e", (
            "CONTROLLER_ALLOW_ALREADY_SERVED=" +
            $AllowAlreadyServed.IsPresent.ToString().ToLowerInvariant()
        ),
        "/tests/k6/controller-update-large-flagset.js"
    )
    $output = (& kubectl @arguments 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    [IO.File]::AppendAllText(
        $script:controllerLogPath,
        $output + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $records = @(Add-ControlRecords -Text $output)
    $resultPattern = (
        "STREAM_CONTROLLER_RESULT\|1\|" +
        [regex]::Escape($script:runId) +
        "\|" +
        [regex]::Escape(
            [string]$script:metadata.targetEnvironmentId
        ) +
        "\|" +
        [regex]::Escape($FlagKey) +
        "\|" +
        [regex]::Escape($Phase) +
        "\|" +
        [regex]::Escape($TargetRevision) +
        "\|(?<outcome>changed|unchanged)"
    )
    $result = [regex]::Match($output, $resultPattern)
    if ($exitCode -ne 0 -or -not $result.Success) {
        throw (
            "Controller update '$Phase' failed without a valid success " +
            "record (kubectl exit=$exitCode)."
        )
    }
    $start = @(
        $records |
            Where-Object event -eq "request_start" |
            Sort-Object attempt |
            Select-Object -Last 1
    )
    if ($start.Count -ne 1) {
        throw "Controller update '$Phase' emitted no unique request start."
    }
    return [pscustomobject]@{
        Phase = $Phase
        Outcome = $result.Groups["outcome"].Value
        RequestStartUnixMs = [int64]$start[0].atUnixMs
    }
}

function Invoke-RestoreUpdate {
    param(
        [Parameter(Mandatory)][string] $FlagKey,
        [Parameter(Mandatory)][ValidateSet("string", "json")]
        [string] $VariationType,
        [Parameter(Mandatory)][string] $Phase
    )

    $arguments = @(
        "--context", $script:targetContext,
        "-n", $script:namespace,
        "exec", $script:controllerPodName, "--",
        "k6", "run", "--summary-mode", "disabled",
        "-e", "RUN_ID=$($script:runId)",
        "-e", "CONTROLLER_FLAG_KEY=$FlagKey",
        "-e", "CONTROLLER_TARGET_REVISION=baseline",
        "-e", "CONTROLLER_REQUIRED_REVISIONS=baseline",
        "-e", "CONTROLLER_VARIATION_TYPE=$VariationType",
        "-e", "CONTROLLER_PHASE=$Phase",
        "-e", "CONTROLLER_REVISION_INDEX=0",
        "-e", "CONTROLLER_ALLOW_ALREADY_SERVED=true",
        "/tests/k6/controller-update-large-flagset.js"
    )
    $output = (& kubectl @arguments 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    [IO.File]::AppendAllText(
        $script:restoreLogPath,
        $output + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $pattern = (
        "STREAM_CONTROLLER_RESULT\|1\|" +
        [regex]::Escape($script:runId) +
        "\|.+\|" +
        [regex]::Escape($FlagKey) +
        "\|" +
        [regex]::Escape($Phase) +
        "\|baseline\|(changed|unchanged)"
    )
    if ($exitCode -ne 0 -or $output -notmatch $pattern) {
        throw "Baseline restore '$Phase' failed."
    }
}

function Start-ResourceMonitor {
    $scriptPath = Join-Path `
        $PSScriptRoot `
        "monitor-aks-dotnet-sdk-pilot.ps1"
    $stdoutPath = Join-Path `
        $script:resultsDirectory `
        "$($script:runId)-resource-monitor.log"
    $stderrPath = Join-Path `
        $script:resultsDirectory `
        "$($script:runId)-resource-monitor-process-error.log"
    $powerShell = (Get-Process -Id $PID).Path
    return Start-Process `
        -FilePath $powerShell `
        -ArgumentList @(
            "-NoProfile",
            "-File", $scriptPath,
            "-RunId", $script:runId,
            "-JobName", $script:jobName,
            "-KubeContext", $script:targetContext,
            "-SampleIntervalSeconds", "5",
            "-TimeoutMinutes", "30",
            "-OutputDirectory", $script:resultsDirectory
        ) `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden `
        -PassThru
}

function Signal-RunnerStop {
    $pods = @(Get-RunnerPods | Where-Object {
        $_.status.phase -eq "Running" -and
        @($_.status.containerStatuses | Where-Object ready).Count -eq 1
    })
    foreach ($pod in $pods) {
        & kubectl --context $script:targetContext `
            -n $script:namespace `
            exec ([string]$pod.metadata.name) `
            -- touch /tmp/featbit-stop *> $null
        if ($LASTEXITCODE -ne 0) {
            $script:failureReasons.Add(
                "Failed to signal stop to runner '$($pod.metadata.name)'."
            )
        }
    }
}

function Wait-RunnerJobTerminal {
    $deadline = [DateTime]::UtcNow.AddMinutes(6)
    do {
        $job = Read-KubectlJson `
            -Arguments @(
                "--context", $script:targetContext,
                "-n", $script:namespace,
                "get", "job", $script:jobName,
                "-o", "json"
            ) `
            -FailureMessage "Failed to inspect the runner Job."
        $conditionsProperty =
            $job.status.PSObject.Properties["conditions"]
        $terminalConditions = @()
        if ($null -ne $conditionsProperty) {
            $terminalConditions = @(
                $conditionsProperty.Value | Where-Object {
                    [string]$_.status -eq "True" -and
                    [string]$_.type -in @("Complete", "Failed")
                }
            )
        }
        if ($terminalConditions.Count -gt 0) {
            return $job
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for the runner Job to finish."
        }
        Start-Sleep -Seconds 3
    } while ($true)
}

function Stop-Controller {
    if ([string]::IsNullOrWhiteSpace($script:controllerPodName)) {
        return
    }
    & kubectl --context $script:targetContext `
        -n $script:namespace `
        exec $script:controllerPodName `
        -- touch /tmp/controller-stop *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to stop the controller Job normally."
    }
    & kubectl --context $script:targetContext `
        -n $script:namespace `
        wait "job/$($script:controllerJobName)" `
        --for=condition=complete `
        --timeout=2m *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Controller Job did not complete normally."
    }
}

function Save-KubectlJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $FailureMessage
    )

    $value = Read-KubectlJson `
        -Arguments $Arguments `
        -FailureMessage $FailureMessage
    Write-Utf8NoBom `
        -Path $Path `
        -Content (($value | ConvertTo-Json -Depth 30) + "`n")
}

function Capture-ClusterEvidence {
    Save-KubectlJson `
        -Arguments @(
            "--context", $script:targetContext,
            "-n", $script:namespace,
            "get", "job", $script:jobName,
            "-o", "json"
        ) `
        -Path (
            Join-Path `
                $script:resultsDirectory `
                "$($script:runId)-job-prestop-cluster.json"
        ) `
        -FailureMessage "Failed to capture the runner Job."
    Save-KubectlJson `
        -Arguments @(
            "--context", $script:targetContext,
            "-n", $script:namespace,
            "get", "pods",
            "-l", "loadtest.featbit.io/run-id=$($script:runId)",
            "-o", "json"
        ) `
        -Path (
            Join-Path `
                $script:resultsDirectory `
                "$($script:runId)-pods-cluster.json"
        ) `
        -FailureMessage "Failed to capture run Pods."
    Save-KubectlJson `
        -Arguments @(
            "--context", $script:targetContext,
            "get", "nodes",
            "-o", "json"
        ) `
        -Path (
            Join-Path `
                $script:resultsDirectory `
                "$($script:runId)-nodes-cluster.json"
        ) `
        -FailureMessage "Failed to capture AKS nodes."
    Save-KubectlJson `
        -Arguments @(
            "--context", $script:targetContext,
            "-n", "featbit",
            "get", "deployment", "featbit-els",
            "-o", "json"
        ) `
        -Path (
            Join-Path `
                $script:resultsDirectory `
                "$($script:runId)-els-deployment.json"
        ) `
        -FailureMessage "Failed to capture ELS Deployment."
    Save-KubectlJson `
        -Arguments @(
            "--context", $script:targetContext,
            "-n", "featbit",
            "get", "pods",
            "-l", "app.kubernetes.io/component=els",
            "-o", "json"
        ) `
        -Path (
            Join-Path `
                $script:resultsDirectory `
                "$($script:runId)-els-pods.json"
        ) `
        -FailureMessage "Failed to capture ELS Pods."
    $events = (
        & kubectl --context $script:targetContext `
            -n $script:namespace `
            get events `
            --sort-by=.metadata.creationTimestamp 2>&1 |
            Out-String
    )
    Write-Utf8NoBom `
        -Path (
            Join-Path `
                $script:resultsDirectory `
                "$($script:runId)-kubernetes-events.txt"
        ) `
        -Content $events
}

function Copy-RemoteRunnerArtifact {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Destination
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $content = (
            & kubectl --context $script:targetContext `
                -n $script:namespace `
                exec results-reader -- `
                cat "/results/$($script:runId)/$Name" 2>$null |
                Out-String
        )
        $exitCode = $LASTEXITCODE
        if (
            $exitCode -eq 0 -and
            -not [string]::IsNullOrWhiteSpace($content)
        ) {
            Write-Utf8NoBom -Path $Destination -Content $content
            return
        }
        if ($attempt -lt 3) {
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    throw "Failed to copy runner artifact '$Name' after three attempts."
}

function Collect-RunnerArtifacts {
    $archiveDirectory = Join-Path `
        $script:resultsDirectory `
        $script:runId
    if (Test-Path -LiteralPath $archiveDirectory) {
        throw "Refusing to overwrite existing run archive: $archiveDirectory"
    }
    $null = New-Item `
        -ItemType Directory `
        -Path $archiveDirectory

    $remoteFilesText = (
        & kubectl --context $script:targetContext `
            -n $script:namespace `
            exec results-reader -- sh -c (
                "ls -1 /results/$($script:runId)"
            ) |
            Out-String
    ).Trim()
    if (
        $LASTEXITCODE -ne 0 -or
        [string]::IsNullOrWhiteSpace($remoteFilesText)
    ) {
        throw "No runner artifacts were found on the results PVC."
    }
    $remoteFiles = @(
        $remoteFilesText -split "\r?\n" |
            Where-Object { $_ }
    )
    foreach ($name in $remoteFiles) {
        if ($name -notmatch "^[A-Za-z0-9._-]+$") {
            throw "Unsafe runner artifact name '$name'."
        }
        Copy-RemoteRunnerArtifact `
            -Name $name `
            -Destination (Join-Path $archiveDirectory $name)
    }
    $eventFiles = @($remoteFiles | Where-Object {
        $_ -match "-dotnet-runner-\d{2}-events\.jsonl$"
    })
    $summaryFiles = @($remoteFiles | Where-Object {
        $_ -match "-dotnet-runner-\d{2}-summary\.json$"
    })
    if ($eventFiles.Count -ne 20 -or $summaryFiles.Count -ne 20) {
        $script:failureReasons.Add(
            "Expected 20 event and 20 summary files; found " +
            "$($eventFiles.Count) and $($summaryFiles.Count)."
        )
    }

    $localArtifacts = @(
        Get-ChildItem `
            -LiteralPath $script:resultsDirectory `
            -File |
            Where-Object {
                $_.Name.StartsWith(
                    "$($script:runId)-",
                    [StringComparison]::Ordinal
                )
            }
    )
    foreach ($file in $localArtifacts) {
        $destination = Join-Path $archiveDirectory $file.Name
        if (Test-Path -LiteralPath $destination) {
            throw "Artifact collision while archiving '$($file.Name)'."
        }
        Copy-Item -LiteralPath $file.FullName -Destination $destination
    }
    return $archiveDirectory
}

$script:targetContext = $KubeContext.Trim()
$script:namespace = $script:LoadTestNamespace
$script:resultsDirectory = ""
$script:runId = ""
$script:jobName = ""
$script:metadata = $null
$script:matrix = $null
$script:controllerJobName = ""
$script:controllerPodName = ""
$script:experimentEventsPath = ""
$script:controllerEventsPath = ""
$script:controllerLogPath = ""
$script:restoreLogPath = ""
$script:failureReasons = [Collections.Generic.List[string]]::new()
$runnerJobSubmitted = $false
$resourceMonitor = $null
$runStartUnixMs = 0L
$runEndUnixMs = 0L
$baselineRestored = $false
$archiveDirectory = ""

Assert-DigestImage -Image $RunnerImage -Name "RunnerImage"
Assert-DigestImage -Image $ControllerImage -Name "ControllerImage"
Assert-KubernetesContext -KubeContext $script:targetContext
$repositoryRoot = Get-RepositoryRoot
$script:resultsDirectory = Join-Path $repositoryRoot "results"
$resolvedMatrixPath = if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
    Join-Path $repositoryRoot (
        "k8s-infra\matrices\" +
        "aks-single-environment-3k-flags-dotnet-sdk-p500.json"
    )
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $MatrixPath
    )
}
$script:matrix = Get-Content -Raw -LiteralPath $resolvedMatrixPath |
    ConvertFrom-Json

$streamObserverSource = Ensure-StreamingObserver
$oneSecondSource = Ensure-OneSecondCollector
$preflightJob = Test-RunnerImagePull -Image $RunnerImage

$rendered = & (Join-Path $PSScriptRoot "render-aks-dotnet-sdk-pilot.ps1") `
    -RunKind $RunKind `
    -KubeContext $script:targetContext `
    -RunnerImage $RunnerImage `
    -ControllerImage $ControllerImage `
    -StartDelaySeconds $StartDelaySeconds `
    -MatrixPath $resolvedMatrixPath `
    -OutputDirectory $script:resultsDirectory `
    -Note $Note
$script:runId = [string]$rendered.RunId
$script:jobName = [string]$rendered.JobName
$script:metadata = Get-Content `
    -Raw `
    -LiteralPath ([string]$rendered.MetadataPath) |
    ConvertFrom-Json
$script:experimentEventsPath = Join-Path `
    $script:resultsDirectory `
    "$($script:runId)-experiment-events.jsonl"
$script:controllerEventsPath = Join-Path `
    $script:resultsDirectory `
    "$($script:runId)-external-controller-events.jsonl"
$script:controllerLogPath = Join-Path `
    $script:resultsDirectory `
    "$($script:runId)-controller.log"
$script:restoreLogPath = Join-Path `
    $script:resultsDirectory `
    "$($script:runId)-restore.log"
foreach ($path in @(
    $script:experimentEventsPath,
    $script:controllerEventsPath,
    $script:controllerLogPath,
    $script:restoreLogPath
)) {
    Write-Utf8NoBom -Path $path -Content ""
}
$inventory = Read-KubectlJson `
    -Arguments @(
        "--context", $script:targetContext,
        "-n", $script:namespace,
        "get", "configmap",
        [string]$script:matrix.kubernetesObjects.configMap,
        "-o", "json"
    ) `
    -FailureMessage "Failed to read the 3,000-flag ConfigMap."
Write-Utf8NoBom `
    -Path (
        Join-Path `
            $script:resultsDirectory `
            "$($script:runId)-large-flagset-inventory.json"
    ) `
    -Content (([string]$inventory.data."inventory.json").Trim() + "`n")

Add-ExperimentEvent `
    -Event "preflight_passed" `
    -Fields @{
        runnerImagePreflightJob = $preflightJob
        streamingObserverSourceRunId = $streamObserverSource
        oneSecondEvidenceSourceRunId = $oneSecondSource
        totalConnections = 500
        connectionsPerSecond = 20
        rampDurationSeconds = 25
    }

try {
    New-ControllerJob
    Add-ExperimentEvent `
        -Event "controller_ready" `
        -Fields @{
            job = $script:controllerJobName
            pod = $script:controllerPodName
        }

    $runStartUnixMs =
        [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 5000L
    & kubectl --context $script:targetContext `
        apply -f ([string]$rendered.ManifestPath) *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to submit runner Job '$($script:jobName)'."
    }
    $runnerJobSubmitted = $true
    Add-ExperimentEvent `
        -Event "runner_job_submitted" `
        -Fields @{
            job = $script:jobName
            startAtUnixMs = [int64]$script:metadata.startAtUnixMs
        }
    $resourceMonitor = Start-ResourceMonitor
    $runnerPods = @(Wait-RunnerPodsReady)
    Add-ExperimentEvent `
        -Event "runner_pods_ready" `
        -Fields @{ ready = $runnerPods.Count; nodes = 10 }
    & (Join-Path $PSScriptRoot "snapshot-aks-els-cgroup.ps1") `
        -RunId $script:runId `
        -KubeContext $script:targetContext `
        -Phase "pre" `
        -OutputDirectory $script:resultsDirectory | Out-Host
    Add-ExperimentEvent `
        -Event "els_cgroup_pre_captured" `
        -Fields @{ pods = 3; readOnly = $true }

    $ready = @(Wait-SdkReadyCoverage)
    Add-ExperimentEvent `
        -Event "sdk_initialization_complete" `
        -Fields @{
            ready = $ready.Count
            lastReadyAtUnixMs = [int64](
                $ready.atUnixMs |
                    Measure-Object -Maximum
            ).Maximum
        }

    Start-Sleep -Seconds 10
    $warmupFlag = [string]$script:metadata.postRampWarmupFlagKey
    $warmupUpdate = Invoke-ControllerUpdate `
        -FlagKey $warmupFlag `
        -TargetRevision "rev-001" `
        -VariationType "string" `
        -Phase "post-ramp-warmup-revision"
    Wait-VariationCoverage `
        -FlagKey $warmupFlag `
        -Revision "rev-001" `
        -AfterUnixMs $warmupUpdate.RequestStartUnixMs `
        -RevisionIndex 0 `
        -TimeoutSeconds (
            [int]$script:matrix.warmupCoverageTimeoutSeconds
        ) `
        -Label "warm-up revision" | Out-Null

    $warmupRestore = Invoke-ControllerUpdate `
        -FlagKey $warmupFlag `
        -TargetRevision "baseline" `
        -VariationType "string" `
        -Phase "post-ramp-warmup-baseline"
    Wait-VariationCoverage `
        -FlagKey $warmupFlag `
        -Revision "baseline" `
        -AfterUnixMs $warmupRestore.RequestStartUnixMs `
        -RevisionIndex 0 `
        -TimeoutSeconds (
            [int]$script:matrix.warmupCoverageTimeoutSeconds
        ) `
        -Label "warm-up baseline restore" | Out-Null
    Add-ExperimentEvent `
        -Event "warmup_verified" `
        -Fields @{ connections = 500; deliveries = 1000 }

    $formalStartUnixMs =
        [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 5000L
    foreach ($step in @($script:metadata.revisionPlan)) {
        $due = $formalStartUnixMs +
            (([int]$step.index - 1) *
                [int]$script:matrix.revisionIntervalSeconds * 1000L)
        $update = Invoke-ControllerUpdate `
            -FlagKey ([string]$step.flagKey) `
            -TargetRevision ([string]$step.revision) `
            -VariationType ([string]$step.variationType) `
            -Phase (
                "formal-revision-{0:D3}" -f [int]$step.index
            ) `
            -RevisionIndex ([int]$step.index) `
            -DueUnixMs $due
        Wait-VariationCoverage `
            -FlagKey ([string]$step.flagKey) `
            -Revision ([string]$step.revision) `
            -AfterUnixMs $update.RequestStartUnixMs `
            -RevisionIndex ([int]$step.index) `
            -TimeoutSeconds 25 `
            -Label (
                "formal revision {0:D3}" -f [int]$step.index
            ) | Out-Null
        Add-ExperimentEvent `
            -Event "formal_revision_verified" `
            -Fields @{
                revisionIndex = [int]$step.index
                flagKey = [string]$step.flagKey
                revision = [string]$step.revision
                variationType = [string]$step.variationType
                connections = 500
                requestStartUnixMs = $update.RequestStartUnixMs
            }
    }
    Start-Sleep -Seconds ([int]$script:matrix.finalSettleSeconds)
    $runEndUnixMs =
        [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Add-ExperimentEvent `
        -Event "formal_workload_complete" `
        -Fields @{ formalDeliveries = 5000 }
}
catch {
    $script:failureReasons.Add($_.Exception.Message)
    Add-ExperimentEvent `
        -Event "run_failed" `
        -Fields @{ message = $_.Exception.Message }
}
finally {
    if ($runEndUnixMs -eq 0L) {
        $runEndUnixMs =
            [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }

    if ($runnerJobSubmitted) {
        try {
            Capture-ClusterEvidence
        }
        catch {
            $script:failureReasons.Add(
                "Cluster evidence capture failed: $($_.Exception.Message)"
            )
        }
        try {
            Signal-RunnerStop
            $terminalJob = Wait-RunnerJobTerminal
            if (
                (Get-StatusInt -Object $terminalJob -Name "succeeded") -ne
                    20 -or
                (Get-StatusInt -Object $terminalJob -Name "failed") -gt 0
            ) {
                $script:failureReasons.Add(
                    "Runner Job did not complete with 20 successful indexes."
                )
            }
        }
        catch {
            $script:failureReasons.Add(
                "Runner shutdown failed: $($_.Exception.Message)"
            )
        }
        try {
            & (Join-Path $PSScriptRoot "snapshot-aks-els-cgroup.ps1") `
                -RunId $script:runId `
                -KubeContext $script:targetContext `
                -Phase "post" `
                -OutputDirectory $script:resultsDirectory | Out-Host
            Add-ExperimentEvent `
                -Event "els_cgroup_post_captured" `
                -Fields @{ pods = 3; readOnly = $true }
        }
        catch {
            $script:failureReasons.Add(
                "ELS cgroup post-snapshot failed: $($_.Exception.Message)"
            )
        }
    }

    if ($null -ne $resourceMonitor) {
        $monitorDeadline = [DateTime]::UtcNow.AddSeconds(60)
        while (
            -not $resourceMonitor.HasExited -and
            [DateTime]::UtcNow -lt $monitorDeadline
        ) {
            Start-Sleep -Seconds 2
            $resourceMonitor.Refresh()
        }
        if (-not $resourceMonitor.HasExited) {
            $script:failureReasons.Add(
                "Resource monitor did not exit within 60 seconds."
            )
        }
        elseif ($resourceMonitor.ExitCode -ne 0) {
            $script:failureReasons.Add(
                "Resource monitor exited with code $($resourceMonitor.ExitCode)."
            )
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:controllerPodName)) {
        try {
            foreach ($step in @($script:metadata.revisionPlan)) {
                Invoke-RestoreUpdate `
                    -FlagKey ([string]$step.flagKey) `
                    -VariationType ([string]$step.variationType) `
                    -Phase (
                        "post-run-baseline-{0:D2}" -f [int]$step.index
                    )
            }
            Invoke-RestoreUpdate `
                -FlagKey (
                    [string]$script:metadata.postRampWarmupFlagKey
                ) `
                -VariationType "string" `
                -Phase "post-run-warmup-baseline"
            $baselineRestored = $true
            Add-ExperimentEvent `
                -Event "baseline_restored" `
                -Fields @{ flags = 11 }
        }
        catch {
            $script:failureReasons.Add(
                "Flag baseline restore failed: $($_.Exception.Message)"
            )
        }
        try {
            Stop-Controller
        }
        catch {
            $script:failureReasons.Add(
                "Controller shutdown failed: $($_.Exception.Message)"
            )
        }
    }

    if ($runnerJobSubmitted) {
        try {
            & (Join-Path $PSScriptRoot "snapshot-aks-streaming-timing.ps1") `
                -RunId $script:runId `
                -KubeContext $script:targetContext `
                -StartUnixMs $runStartUnixMs `
                -EndUnixMs ($runEndUnixMs + 5000L) `
                -OutputDirectory $script:resultsDirectory | Out-Host
        }
        catch {
            $script:failureReasons.Add(
                "Redis observer snapshot failed: $($_.Exception.Message)"
            )
        }
        try {
            & (
                Join-Path `
                    $PSScriptRoot `
                    "snapshot-aks-multi-environment-1s-evidence.ps1"
            ) `
                -RunId $script:runId `
                -KubeContext $script:targetContext `
                -StartUnixMs $runStartUnixMs `
                -EndUnixMs $runEndUnixMs `
                -SourceRunId $oneSecondSource `
                -ExpectedNodeCount 13 `
                -OutputDirectory $script:resultsDirectory | Out-Host
        }
        catch {
            $script:failureReasons.Add(
                "One-second evidence snapshot failed: $($_.Exception.Message)"
            )
        }
        try {
            # Capture terminal status after normal shutdown.
            $terminalJobPath = Join-Path `
                $script:resultsDirectory `
                "$($script:runId)-job-cluster.json"
            Save-KubectlJson `
                -Arguments @(
                    "--context", $script:targetContext,
                    "-n", $script:namespace,
                    "get", "job", $script:jobName,
                    "-o", "json"
                ) `
                -Path $terminalJobPath `
                -FailureMessage "Failed to capture terminal runner Job."
        }
        catch {
            $script:failureReasons.Add(
                "Terminal Job capture failed: $($_.Exception.Message)"
            )
        }
        try {
            $archiveDirectory = Collect-RunnerArtifacts
        }
        catch {
            $script:failureReasons.Add(
                "Artifact collection failed: $($_.Exception.Message)"
            )
        }
    }
}

$execution = [ordered]@{
    schemaVersion = 1
    runId = $script:runId
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
    status = if ($script:failureReasons.Count -eq 0) {
        "raw-gates-passed"
    }
    else {
        "failed"
    }
    baselineRestored = $baselineRestored
    runnerJobRetained = $runnerJobSubmitted
    controllerJobRetained =
        -not [string]::IsNullOrWhiteSpace($script:controllerJobName)
    observersRetained = $true
    infrastructureDeleted = $false
    failureReasons = @($script:failureReasons)
}
if (-not [string]::IsNullOrWhiteSpace($archiveDirectory)) {
    Write-Utf8NoBom `
        -Path (
            Join-Path `
                $archiveDirectory `
                "$($script:runId)-execution.json"
        ) `
        -Content (($execution | ConvertTo-Json -Depth 8) + "`n")
    try {
        & (Join-Path $PSScriptRoot "analyze-aks-dotnet-sdk-pilot.ps1") `
            -RunDirectory $archiveDirectory | Out-Host
        & (
            Join-Path `
                $PSScriptRoot `
                "analyze-aks-dotnet-node-evidence.ps1"
        ) -RunDirectory $archiveDirectory | Out-Host
        & (
            Join-Path `
                $PSScriptRoot `
                "snapshot-aks-els-run-logs.ps1"
        ) `
            -RunDirectory $archiveDirectory `
            -KubeContext $script:targetContext | Out-Host
    }
    catch {
        $script:failureReasons.Add(
            "Final analysis failed: $($_.Exception.Message)"
        )
    }
}

if ($script:failureReasons.Count -gt 0) {
    throw (
        ".NET SDK pilot '$($script:runId)' failed. Evidence was retained. " +
        ($script:failureReasons -join " ")
    )
}

Write-Host ""
Write-Host ".NET SDK 500-connection pilot passed." -ForegroundColor Green
Write-Host "Run ID: $($script:runId)"
Write-Host "Archive: $archiveDirectory"
Write-Host "No AKS infrastructure or historical result was deleted."

[pscustomobject]@{
    RunId = $script:runId
    JobName = $script:jobName
    Status = "passed"
    ArchiveDirectory = $archiveDirectory
    BaselineRestored = $baselineRestored
    InfrastructureDeleted = $false
}
