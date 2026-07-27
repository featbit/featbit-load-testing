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

    [string] $Note = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content,
        [switch] $AllowExistingSameContent
    )

    if (Test-Path -LiteralPath $Path) {
        if (
            $AllowExistingSameContent -and
            [IO.File]::ReadAllText($Path) -ceq $Content
        ) {
            return
        }
        throw "Refusing to overwrite existing run evidence: $Path"
    }
    [IO.File]::WriteAllText(
        $Path,
        $Content,
        [Text.UTF8Encoding]::new($false)
    )
}

function Read-KubectlJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $FailureMessage
    )

    $text = (& kubectl @Arguments | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        throw $FailureMessage
    }
    return $text | ConvertFrom-Json
}

function Add-JsonLine {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Record
    )

    [IO.File]::AppendAllText(
        $Path,
        (($Record | ConvertTo-Json -Depth 12 -Compress) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Add-Failure {
    param([Parameter(Mandatory)][string] $Message)

    $script:failureReasons.Add($Message)
    Write-Warning $Message
    if ($script:experimentEventsPath) {
        Add-JsonLine -Path $script:experimentEventsPath -Record ([ordered]@{
            schemaVersion = 1
            runId = $script:runId
            atUtc = [DateTime]::UtcNow.ToString("o")
            event = "failure"
            message = $Message
        })
    }
}

function Select-ScriptResult {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Output,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $RequiredProperties,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Description
    )

    $matches = @(
        foreach ($candidate in @($Output)) {
            if ($null -eq $candidate) {
                continue
            }
            $hasAllProperties = $true
            foreach ($propertyName in $RequiredProperties) {
                if ($null -eq $candidate.PSObject.Properties[$propertyName]) {
                    $hasAllProperties = $false
                    break
                }
            }
            if ($hasAllProperties) {
                $candidate
            }
        }
    )
    if ($matches.Count -ne 1) {
        throw (
            "$Description returned $($matches.Count) structured result " +
            "objects; expected exactly one."
        )
    }
    return $matches[0]
}

function Test-CrossEnvironmentMonitorLog {
    if (
        [string]::IsNullOrWhiteSpace(
            $script:crossEnvironmentMonitorLogPath
        ) -or
        -not (
            Test-Path `
                -LiteralPath $script:crossEnvironmentMonitorLogPath `
                -PathType Leaf
        )
    ) {
        return $false
    }

    return [bool](
        Select-String `
            -LiteralPath $script:crossEnvironmentMonitorLogPath `
            -SimpleMatch "STREAM_CROSS_ENV|1|" `
            -Quiet
    )
}

function Start-CrossEnvironmentMonitor {
    $script:crossEnvironmentMonitorLogPath = Join-Path `
        $script:resultsDirectory `
        "$script:runId-cross-environment-monitor.log"
    $script:crossEnvironmentMonitorErrorPath = Join-Path `
        $script:resultsDirectory `
        "$script:runId-cross-environment-monitor-error.log"
    foreach ($path in @(
        $script:crossEnvironmentMonitorLogPath,
        $script:crossEnvironmentMonitorErrorPath
    )) {
        if (Test-Path -LiteralPath $path) {
            throw "Refusing to overwrite cross-environment evidence '$path'."
        }
    }

    $kubectlPath = (
        Get-Command kubectl -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
    ).Source
    $monitor = Start-Process `
        -FilePath $kubectlPath `
        -ArgumentList @(
            "--context", $script:targetContext,
            "-n", $script:namespace,
            "logs",
            "-f",
            "-l", "k6_cr=$script:testRunName,runner=true",
            "--all-containers=true",
            "--prefix=true",
            "--tail=0",
            "--max-log-requests=20"
        ) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $script:crossEnvironmentMonitorLogPath `
        -RedirectStandardError $script:crossEnvironmentMonitorErrorPath `
        -PassThru
    Start-Sleep -Seconds 1
    $monitor.Refresh()
    if ($monitor.HasExited) {
        throw (
            "Cross-environment monitor exited during startup with code " +
            "$($monitor.ExitCode); see " +
            "'$script:crossEnvironmentMonitorErrorPath'."
        )
    }
    return $monitor
}

function Assert-CrossEnvironmentIsolation {
    param(
        [Parameter(Mandatory)]
        [Diagnostics.Process] $Monitor
    )

    if (Test-CrossEnvironmentMonitorLog) {
        $script:crossEnvironmentDetected = $true
        throw (
            "Cross-environment delivery was observed by the live runner " +
            "monitor; no further controller updates are permitted."
        )
    }
    $Monitor.Refresh()
    if ($Monitor.HasExited) {
        throw (
            "Cross-environment monitor exited unexpectedly with code " +
            "$($Monitor.ExitCode); no further controller updates are " +
            "permitted."
        )
    }
}

function Stop-CrossEnvironmentMonitor {
    param(
        [Parameter(Mandatory)]
        [Diagnostics.Process] $Monitor
    )

    $Monitor.Refresh()
    if (-not $Monitor.HasExited) {
        $null = $Monitor.WaitForExit(5000)
        $Monitor.Refresh()
    }
    if (-not $Monitor.HasExited) {
        Stop-Process -Id $Monitor.Id -Force
        $null = $Monitor.WaitForExit(5000)
    }
}

function Get-RunnerPods {
    $podList = Read-KubectlJson `
        -Arguments @(
            "--context", $script:targetContext,
            "-n", $script:namespace,
            "get", "pods",
            "-l", "loadtest.featbit.io/run-id=$script:runId",
            "-o", "json"
        ) `
        -FailureMessage "Failed to inspect runner Pods for '$script:runId'."
    $runnerPods = @(
        $podList.items |
            Where-Object {
                [string]$_.metadata.name -match
                    "^$([regex]::Escape($script:testRunName))-(\d+)-[a-z0-9]+$"
            } |
            Sort-Object {
                if (
                    [string]$_.metadata.name -match
                        "^$([regex]::Escape($script:testRunName))-(\d+)-"
                ) {
                    [int]$Matches[1]
                }
                else {
                    999
                }
            }
    )
    return $runnerPods
}

function Test-PodReady {
    param([Parameter(Mandatory)][object] $Pod)

    $statuses = @($Pod.status.containerStatuses)
    return (
        $Pod.status.phase -eq "Running" -and
        $statuses.Count -gt 0 -and
        @($statuses | Where-Object ready).Count -eq $statuses.Count
    )
}

function Wait-RunnerPodsReady {
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    do {
        $pods = @(Get-RunnerPods)
        $ready = @($pods | Where-Object { Test-PodReady -Pod $_ })
        $stage = (
            & kubectl --context $script:targetContext `
                -n $script:namespace `
                get testrun $script:testRunName `
                -o "jsonpath={.status.stage}" 2>$null |
                Out-String
        ).Trim()
        Write-Host (
            "{0:HH:mm:ss} TestRun stage={1}; runner Pods ready={2}/20" -f
            [DateTime]::Now,
            $stage,
            $ready.Count
        )
        if ($pods.Count -eq 20 -and $ready.Count -eq 20) {
            return $ready
        }
        if ($stage -eq "error") {
            throw "TestRun entered the error stage before all runners were ready."
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for 20 ready runner Pods."
        }
        Start-Sleep -Seconds 5
    } while ($true)
}

function Get-RunnerLogs {
    param([Parameter(Mandatory)][object[]] $RunnerPods)

    $logs = @{}
    foreach ($pod in $RunnerPods) {
        $podName = [string]$pod.metadata.name
        $text = (
            & kubectl --context $script:targetContext `
                -n $script:namespace `
                logs $podName 2>$null |
                Out-String
        )
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to read runner log '$podName'."
        }
        $logs[$podName] = $text
    }
    return $logs
}

function Get-ReadySnapshot {
    param([Parameter(Mandatory)][hashtable] $Logs)

    $identity = @{}
    $environmentCounts = @{}
    $runnerCounts = @{}
    $environmentRunnerCounts = @{}
    foreach ($entry in $Logs.GetEnumerator()) {
        $podName = [string]$entry.Key
        if (
            $podName -notmatch
                "^$([regex]::Escape($script:testRunName))-(?<runner>\d+)-"
        ) {
            continue
        }
        $logRunner = [int]$Matches.runner
        $matches = [regex]::Matches(
            [string]$entry.Value,
            (
                "STREAM_READY\|1\|(?<at>\d+)\|" +
                [regex]::Escape($script:runId) +
                "\|(?<environment>[^|]+)\|(?<runner>\d+)\|" +
                "(?<connection>\d+)"
            )
        )
        foreach ($match in $matches) {
            $runner = [int]$match.Groups["runner"].Value
            $connection = [int]$match.Groups["connection"].Value
            $environmentId = $match.Groups["environment"].Value
            if ($runner -ne $logRunner) {
                throw "Runner '$podName' logged runner index $runner."
            }
            if (
                $runner -lt 1 -or $runner -gt 20 -or
                $connection -lt 1 -or $connection -gt 500
            ) {
                throw "Runner ready identity is outside the fixed topology."
            }
            $expectedEnvironmentIndex = (($connection - 1) % 100) + 1
            $expectedEnvironmentId = [string]$script:environmentIdByIndex[
                $expectedEnvironmentIndex
            ]
            if ($environmentId -cne $expectedEnvironmentId) {
                throw (
                    "Runner $runner connection $connection mapped to " +
                    "'$environmentId'; expected '$expectedEnvironmentId'."
                )
            }
            $key = "$runner|$connection"
            if ($identity.ContainsKey($key)) {
                throw "Duplicate STREAM_READY identity '$key'."
            }
            $identity[$key] = $true
            $environmentCounts[$environmentId] = 1 + [int](
                $environmentCounts[$environmentId]
            )
            $runnerCounts[$runner] = 1 + [int]$runnerCounts[$runner]
            $environmentRunnerKey = "$environmentId|$runner"
            $environmentRunnerCounts[$environmentRunnerKey] = 1 + [int](
                $environmentRunnerCounts[$environmentRunnerKey]
            )
        }
    }
    return [pscustomobject]@{
        Count = $identity.Count
        EnvironmentCounts = $environmentCounts
        RunnerCounts = $runnerCounts
        EnvironmentRunnerCounts = $environmentRunnerCounts
    }
}

function Assert-ReadyTopology {
    param([Parameter(Mandatory)][object] $Snapshot)

    if ($Snapshot.Count -ne 10000) {
        throw "Expected 10,000 unique ready connections; found $($Snapshot.Count)."
    }
    foreach ($runner in 1..20) {
        if ([int]$Snapshot.RunnerCounts[$runner] -ne 500) {
            throw "Runner $runner did not report exactly 500 ready connections."
        }
    }
    foreach ($environment in $script:inventory.environments) {
        $environmentId = [string]$environment.id
        if ([int]$Snapshot.EnvironmentCounts[$environmentId] -ne 100) {
            throw (
                "Environment '$environmentId' did not report exactly 100 " +
                "ready connections."
            )
        }
        foreach ($runner in 1..20) {
            if (
                [int]$Snapshot.EnvironmentRunnerCounts[
                    "$environmentId|$runner"
                ] -ne 5
            ) {
                throw (
                    "Environment '$environmentId' runner $runner did not " +
                    "report exactly five ready connections."
                )
            }
        }
    }
}

function Get-CrossEnvironmentCount {
    param([Parameter(Mandatory)][hashtable] $Logs)

    $count = 0
    foreach ($text in $Logs.Values) {
        $count += [regex]::Matches(
            [string]$text,
            (
                "STREAM_CROSS_ENV\|1\|\d+\|" +
                [regex]::Escape($script:runId) +
                "\|"
            )
        ).Count
    }
    return $count
}

function Get-WarmupSnapshot {
    param(
        [Parameter(Mandatory)][hashtable] $Logs,
        [Parameter(Mandatory)][ValidateSet("revision", "baseline")]
        [string] $Phase
    )

    $identity = @{}
    $total = 0
    foreach ($text in $Logs.Values) {
        $matches = [regex]::Matches(
            [string]$text,
            (
                "STREAM_WARMUP\|1\|\d+\|" +
                [regex]::Escape($script:runId) +
                "\|" +
                [regex]::Escape([string]$script:inventory.targetEnvironment.id) +
                "\|" +
                [regex]::Escape([string]$script:inventory.postRampWarmupFlagKey) +
                "\|" +
                [regex]::Escape($Phase) +
                "\|[^|]+\|(?<runner>\d+)\|(?<connection>\d+)"
            )
        )
        foreach ($match in $matches) {
            $total += 1
            $runner = [int]$match.Groups["runner"].Value
            $connection = [int]$match.Groups["connection"].Value
            $identity["$runner|$connection"] = $true
        }
    }
    return [pscustomobject]@{
        Total = $total
        Unique = $identity.Count
    }
}

function Wait-WarmupCoverage {
    param(
        [Parameter(Mandatory)][object[]] $RunnerPods,
        [Parameter(Mandatory)][ValidateSet("revision", "baseline")]
        [string] $Phase,
        [Parameter(Mandatory)][Diagnostics.Process] $CrossEnvironmentMonitor,
        [ValidateRange(1, 120)][int] $TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Assert-CrossEnvironmentIsolation `
            -Monitor $CrossEnvironmentMonitor
        $logs = Get-RunnerLogs -RunnerPods $RunnerPods
        Assert-CrossEnvironmentIsolation `
            -Monitor $CrossEnvironmentMonitor
        $crossCount = Get-CrossEnvironmentCount -Logs $logs
        if ($crossCount -gt 0) {
            throw (
                "Cross-environment delivery was observed during warm-up " +
                "'$Phase' (count=$crossCount)."
            )
        }
        $coverage = Get-WarmupSnapshot -Logs $logs -Phase $Phase
        Write-Host (
            "{0:HH:mm:ss} warm-up {1}: unique={2}/100, records={3}" -f
            [DateTime]::Now,
            $Phase,
            $coverage.Unique,
            $coverage.Total
        )
        if ($coverage.Unique -eq 100 -and $coverage.Total -eq 100) {
            return $coverage
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw (
                "Warm-up '$Phase' did not reach exactly 100/100 within " +
                "$TimeoutSeconds seconds."
            )
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
        [Parameter(Mandatory)][string] $RunnerPodName,
        [Parameter(Mandatory)][string] $FlagKey,
        [Parameter(Mandatory)][string] $TargetValue,
        [Parameter(Mandatory)][string] $Phase,
        [ValidateRange(0, 100)][int] $RevisionIndex = 0,
        [ValidateRange(0, [int64]::MaxValue)][int64] $DueUnixMs = 0,
        [switch] $AllowAlreadyServed
    )

    $arguments = @(
        "--context", $script:targetContext,
        "-n", $script:namespace,
        "exec", $RunnerPodName, "--",
        "k6", "run", "--summary-mode", "disabled",
        "-e", "RUN_ID=$script:runId",
        "-e", "CONTROLLER_FLAG_KEY=$FlagKey",
        "-e", "CONTROLLER_TARGET_VALUE=$TargetValue",
        "-e", "CONTROLLER_PHASE=$Phase",
        "-e", "CONTROLLER_REVISION_INDEX=$RevisionIndex",
        "-e", "CONTROLLER_DUE_UNIX_MS=$DueUnixMs",
        "-e", (
            "CONTROLLER_ALLOW_ALREADY_SERVED=" +
            $AllowAlreadyServed.IsPresent.ToString().ToLowerInvariant()
        ),
        "/tests/k6/controller-update.js"
    )
    $output = (& kubectl @arguments 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    $records = @(Add-ControlRecords -Text $output)
    $resultPattern = (
        "STREAM_CONTROLLER_RESULT\|1\|" +
        [regex]::Escape($script:runId) +
        "\|" +
        [regex]::Escape(
            [string]$script:inventory.targetEnvironment.id
        ) +
        "\|" +
        [regex]::Escape($FlagKey) +
        "\|" +
        [regex]::Escape($Phase) +
        "\|" +
        [regex]::Escape($TargetValue) +
        "\|(?<outcome>changed|unchanged)"
    )
    $resultMatch = [regex]::Match($output, $resultPattern)
    if ($exitCode -ne 0 -or -not $resultMatch.Success) {
        throw (
            "Controller update '$Phase' failed without a valid success " +
            "record (kubectl exit=$exitCode)."
        )
    }
    $requestStart = @(
        $records |
            Where-Object event -eq "request_start" |
            Sort-Object attempt |
            Select-Object -Last 1
    )[0]
    return [pscustomobject]@{
        Phase = $Phase
        Outcome = $resultMatch.Groups["outcome"].Value
        RequestStartUnixMs = if ($null -eq $requestStart) {
            $null
        }
        else {
            [int64]$requestStart.atUnixMs
        }
        RecordCount = $records.Count
    }
}

function Wait-UntilUnixMs {
    param(
        [Parameter(Mandatory)][int64] $DueUnixMs,
        [Diagnostics.Process] $CrossEnvironmentMonitor
    )

    do {
        if ($null -ne $CrossEnvironmentMonitor) {
            Assert-CrossEnvironmentIsolation `
                -Monitor $CrossEnvironmentMonitor
        }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $remaining = $DueUnixMs - $now
        if ($remaining -le 0) {
            return
        }
        $maximumSleepMs = if ($null -eq $CrossEnvironmentMonitor) {
            5000
        }
        else {
            250
        }
        Start-Sleep -Milliseconds (
            [int][Math]::Min($maximumSleepMs, $remaining)
        )
    } while ($true)
}

function Write-RunnerPlacement {
    param([Parameter(Mandatory)][object[]] $RunnerPods)

    $rows = @(
        foreach ($pod in $RunnerPods) {
            if (
                [string]$pod.metadata.name -notmatch
                    "^$([regex]::Escape($script:testRunName))-(?<runner>\d+)-"
            ) {
                throw "Could not parse runner index from '$($pod.metadata.name)'."
            }
            [pscustomobject][ordered]@{
                runner = [int]$Matches.runner
                name = [string]$pod.metadata.name
                node = [string]$pod.spec.nodeName
                phase = [string]$pod.status.phase
                podIP = [string]$pod.status.podIP
            }
        }
    )
    $nodeGroups = @($rows | Group-Object node)
    if (
        $rows.Count -ne 20 -or
        $nodeGroups.Count -ne 10 -or
        @($nodeGroups | Where-Object Count -ne 2).Count -ne 0
    ) {
        throw "Runner placement is not exactly two runners on each of ten nodes."
    }
    $document = [ordered]@{
        schemaVersion = 1
        runId = $script:runId
        capturedAtUtc = [DateTime]::UtcNow.ToString("o")
        pods = $rows
        nodeCount = $nodeGroups.Count
        runnersPerNode = 2
    }
    Write-Utf8NoBom `
        -Path (Join-Path $script:resultsDirectory "$script:runId-runner-placement.json") `
        -Content (($document | ConvertTo-Json -Depth 8) + "`n")
}

function Wait-TestRunTerminal {
    param([ValidateRange(5, 120)][int] $TimeoutMinutes = 30)

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    do {
        $testRun = Read-KubectlJson `
            -Arguments @(
                "--context", $script:targetContext,
                "-n", $script:namespace,
                "get", "testrun", $script:testRunName,
                "-o", "json"
            ) `
            -FailureMessage "Failed to inspect TestRun '$script:testRunName'."
        $stage = [string]$testRun.status.stage
        Write-Host (
            "{0:HH:mm:ss} waiting for TestRun terminal stage: {1}" -f
            [DateTime]::Now,
            $stage
        )
        if ($stage -in @("finished", "error")) {
            return $stage
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for TestRun '$script:testRunName'."
        }
        Start-Sleep -Seconds 15
    } while ($true)
}

function Invoke-RunnerImagePreflight {
    $jobName = "menv-image-preflight-{0}-{1}" -f `
        [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"), `
        [Guid]::NewGuid().ToString("N").Substring(0, 6)
    $logPath = Join-Path `
        $script:resultsDirectory `
        "$script:runId-runner-image-preflight.log"
    if (Test-Path -LiteralPath $logPath) {
        throw "Refusing to overwrite runner image preflight evidence '$logPath'."
    }

    $job = [ordered]@{
        apiVersion = "batch/v1"
        kind = "Job"
        metadata = [ordered]@{
            name = $jobName
            namespace = $script:namespace
            labels = [ordered]@{
                "app.kubernetes.io/name" = "featbit-k6-runner-preflight"
                "app.kubernetes.io/part-of" = "featbit-load-testing"
                "loadtest.featbit.io/run-id" = $script:runId
                "loadtest.featbit.io/operation" = "runner-image-preflight"
            }
        }
        spec = [ordered]@{
            backoffLimit = 0
            ttlSecondsAfterFinished = $null
            template = [ordered]@{
                metadata = [ordered]@{
                    labels = [ordered]@{
                        "app.kubernetes.io/name" = (
                            "featbit-k6-runner-preflight"
                        )
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
                    containers = @(
                        [ordered]@{
                            name = "inspect"
                            image = [string]$script:metadata.runnerImage
                            imagePullPolicy = "IfNotPresent"
                            command = @(
                                "k6",
                                "inspect",
                                "--include-system-env-vars",
                                "--execution-requirements",
                                "/tests/k6/server-streaming.js"
                            )
                            envFrom = @(
                                [ordered]@{
                                    configMapRef = [ordered]@{
                                        name = (
                                            "featbit-k6-menv-g5-v1-config"
                                        )
                                    }
                                }
                            )
                            env = @(
                                [ordered]@{
                                    name = "FEATBIT_STREAMING_URL"
                                    value = (
                                        "ws://featbit-els.featbit.svc." +
                                        "cluster.local:5100"
                                    )
                                },
                                [ordered]@{
                                    name = "FEATBIT_API_URL"
                                    value = (
                                        "http://featbit-api.featbit.svc." +
                                        "cluster.local:5000"
                                    )
                                },
                                [ordered]@{
                                    name = "RUN_ID"
                                    value = $script:runId
                                },
                                [ordered]@{
                                    name = "LOADTEST_PARALLELISM"
                                    value = "20"
                                },
                                [ordered]@{
                                    name = "MAX_CONNECTIONS"
                                    value = "10000"
                                },
                                [ordered]@{
                                    name = "CONNECTIONS_PER_SECOND"
                                    value = "100"
                                },
                                [ordered]@{
                                    name = "STABILIZATION_SECONDS"
                                    value = "30"
                                },
                                [ordered]@{
                                    name = "INITIAL_SYNC_TIMEOUT_SECONDS"
                                    value = "20"
                                },
                                [ordered]@{
                                    name = "HOLD_DURATION_SECONDS"
                                    value = "600"
                                },
                                [ordered]@{
                                    name = "DRAIN_DURATION_SECONDS"
                                    value = "10"
                                }
                            )
                            volumeMounts = @(
                                [ordered]@{
                                    name = "multi-environment-secrets"
                                    mountPath = "/var/run/featbit-loadtest"
                                    readOnly = $true
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
                                runAsNonRoot = $true
                                runAsUser = 12345
                                runAsGroup = 12345
                                allowPrivilegeEscalation = $false
                                capabilities = [ordered]@{ drop = @("ALL") }
                            }
                        }
                    )
                    volumes = @(
                        [ordered]@{
                            name = "multi-environment-secrets"
                            secret = [ordered]@{
                                secretName = (
                                    "featbit-k6-menv-g5-v1-secret"
                                )
                                items = @(
                                    [ordered]@{
                                        key = "environments.json"
                                        path = "environments.json"
                                    }
                                )
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
        throw "Failed to create runner image preflight Job '$jobName'."
    }

    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    $complete = $false
    $failed = $false
    do {
        $jobState = Read-KubectlJson `
            -Arguments @(
                "--context", $script:targetContext,
                "-n", $script:namespace,
                "get", "job", $jobName,
                "-o", "json"
            ) `
            -FailureMessage "Failed to inspect runner image preflight Job."
        $conditionsProperty = (
            $jobState.status.PSObject.Properties["conditions"]
        )
        $conditions = if ($null -eq $conditionsProperty) {
            @()
        }
        else {
            @($conditionsProperty.Value)
        }
        $complete = @($conditions | Where-Object {
            $_.type -eq "Complete" -and $_.status -eq "True"
        }).Count -gt 0
        $failed = @($conditions | Where-Object {
            $_.type -eq "Failed" -and $_.status -eq "True"
        }).Count -gt 0
        if ($complete -or $failed) {
            break
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            break
        }
        Start-Sleep -Seconds 2
    } while ($true)

    $logText = (
        & kubectl --context $script:targetContext `
            -n $script:namespace `
            logs "job/$jobName" 2>&1 |
            Out-String
    )
    $logExit = $LASTEXITCODE
    Write-Utf8NoBom -Path $logPath -Content $logText
    if (
        -not $complete -or
        $failed -or
        $logExit -ne 0 -or
        [string]::IsNullOrWhiteSpace($logText)
    ) {
        throw (
            "Runner image preflight Job '$jobName' failed; the Job and " +
            "local log were preserved."
        )
    }
    return $jobName
}

function Restore-MeasuredFlagBaseline {
    $jobName = "menv-restore-{0}-{1}" -f `
        [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"), `
        [Guid]::NewGuid().ToString("N").Substring(0, 6)
    $job = [ordered]@{
        apiVersion = "batch/v1"
        kind = "Job"
        metadata = [ordered]@{
            name = $jobName
            namespace = $script:namespace
            labels = [ordered]@{
                "app.kubernetes.io/name" = "featbit-k6-controller"
                "app.kubernetes.io/part-of" = "featbit-load-testing"
                "loadtest.featbit.io/run-id" = $script:runId
                "loadtest.featbit.io/operation" = "restore-baseline"
            }
        }
        spec = [ordered]@{
            backoffLimit = 0
            ttlSecondsAfterFinished = $null
            template = [ordered]@{
                metadata = [ordered]@{
                    labels = [ordered]@{
                        "app.kubernetes.io/name" = "featbit-k6-controller"
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
                    containers = @(
                        [ordered]@{
                            name = "controller"
                            image = [string]$script:metadata.runnerImage
                            imagePullPolicy = "IfNotPresent"
                            command = @(
                                "k6", "run", "--summary-mode", "disabled",
                                "-e", "RUN_ID=$script:runId",
                                "-e", (
                                    "CONTROLLER_FLAG_KEY=" +
                                    [string]$script:inventory.measuredFlagKey
                                ),
                                "-e", "CONTROLLER_TARGET_VALUE=baseline",
                                "-e", "CONTROLLER_PHASE=post-run-baseline",
                                "-e", "CONTROLLER_REVISION_INDEX=0",
                                "-e", "CONTROLLER_ALLOW_ALREADY_SERVED=true",
                                "/tests/k6/controller-update.js"
                            )
                            env = @(
                                [ordered]@{
                                    name = "FEATBIT_API_URL"
                                    value = (
                                        "http://featbit-api.featbit.svc." +
                                        "cluster.local:5000"
                                    )
                                }
                            )
                            envFrom = @(
                                [ordered]@{
                                    configMapRef = [ordered]@{
                                        name = "featbit-k6-menv-g5-v1-config"
                                    }
                                },
                                [ordered]@{
                                    secretRef = [ordered]@{
                                        name = "featbit-k6-controller-secret"
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
                                runAsNonRoot = $true
                                runAsUser = 12345
                                runAsGroup = 12345
                                allowPrivilegeEscalation = $false
                                capabilities = [ordered]@{ drop = @("ALL") }
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
        throw "Failed to create the post-run baseline restoration Job."
    }
    & kubectl --context $script:targetContext `
        -n $script:namespace `
        wait "job/$jobName" `
        --for=condition=complete `
        --timeout=3m *> $null
    $waitExit = $LASTEXITCODE
    $logText = (
        & kubectl --context $script:targetContext `
            -n $script:namespace `
            logs "job/$jobName" |
            Out-String
    )
    $logExit = $LASTEXITCODE
    Write-Utf8NoBom `
        -Path (Join-Path $script:resultsDirectory "$script:runId-restore.log") `
        -Content $logText
    if (
        $waitExit -ne 0 -or
        $logExit -ne 0 -or
        $logText -notmatch (
            "STREAM_CONTROLLER_RESULT\|1\|" +
            [regex]::Escape($script:runId) +
            "\|.+\|post-run-baseline\|baseline\|" +
            "(changed|unchanged)"
        )
    ) {
        throw (
            "The post-run baseline restoration Job '$jobName' did not " +
            "complete with a valid result. The Job was preserved."
        )
    }
    return $jobName
}

$script:targetContext = $KubeContext.Trim()
$script:namespace = $script:LoadTestNamespace
$script:failureReasons = [Collections.Generic.List[string]]::new()
$script:runId = ""
$script:testRunName = ""
$script:experimentEventsPath = ""
$script:controllerEventsPath = ""
$script:inventory = $null
$script:metadata = $null
$script:environmentIdByIndex = @{}
$resourceMonitor = $null
$testRunSubmitted = $false
$runStartUnixMs = 0L
$runEndUnixMs = 0L
$terminalStage = ""
$baselineRestored = $false
$archiveDirectory = ""
$crossEnvironmentMonitor = $null
$script:crossEnvironmentMonitorLogPath = ""
$script:crossEnvironmentMonitorErrorPath = ""
$script:crossEnvironmentDetected = $false

Assert-KubernetesContext -KubeContext $script:targetContext
$repositoryRoot = Get-RepositoryRoot
$script:resultsDirectory = Join-Path $repositoryRoot "results"
$null = New-Item -ItemType Directory -Force -Path $script:resultsDirectory

$renderOutput = @(
    & (
        Join-Path $PSScriptRoot "render-aks-multi-environment-testrun.ps1"
    ) `
        -RunKind $RunKind `
        -KubeContext $script:targetContext `
        -RunnerImage $RunnerImage `
        -Note $Note
)
$rendered = Select-ScriptResult `
    -Output $renderOutput `
    -RequiredProperties @(
        "RunId",
        "TestRunName",
        "ManifestPath",
        "MetadataPath"
    ) `
    -Description "Multi-environment TestRun renderer"
$script:runId = [string]$rendered.RunId
$script:testRunName = [string]$rendered.TestRunName
$script:metadata = Get-Content `
    -Raw `
    -LiteralPath ([string]$rendered.MetadataPath) |
    ConvertFrom-Json
$script:experimentEventsPath = Join-Path `
    $script:resultsDirectory `
    "$script:runId-experiment-events.jsonl"
$script:controllerEventsPath = Join-Path `
    $script:resultsDirectory `
    "$script:runId-external-controller-events.jsonl"
foreach ($path in @(
    $script:experimentEventsPath,
    $script:controllerEventsPath
)) {
    if (Test-Path -LiteralPath $path) {
        throw "Refusing to overwrite existing run event evidence: $path"
    }
    [IO.File]::WriteAllText($path, "", [Text.UTF8Encoding]::new($false))
}

$configMap = Read-KubectlJson `
    -Arguments @(
        "--context", $script:targetContext,
        "-n", $script:namespace,
        "get", "configmap", "featbit-k6-menv-g5-v1-config",
        "-o", "json"
    ) `
    -FailureMessage "Failed to read the multi-environment ConfigMap."
$script:inventory = [string]$configMap.data."inventory.json" | ConvertFrom-Json
if (
    [int]$script:inventory.topology.environmentCount -ne 100 -or
    [int]$script:inventory.topology.totalConnections -ne 10000 -or
    @($script:inventory.environments).Count -ne 100
) {
    throw "The multi-environment inventory does not match the fixed topology."
}
foreach ($environment in $script:inventory.environments) {
    $index = [int]$environment.index
    if ($script:environmentIdByIndex.ContainsKey($index)) {
        throw "The inventory contains duplicate environment index $index."
    }
    $script:environmentIdByIndex[$index] = [string]$environment.id
}
$inventoryPath = Join-Path `
    $script:resultsDirectory `
    "$script:runId-multi-environment-inventory.json"
Write-Utf8NoBom `
    -Path $inventoryPath `
    -Content (([string]$configMap.data."inventory.json").Trim() + "`n")

Add-JsonLine -Path $script:experimentEventsPath -Record ([ordered]@{
    schemaVersion = 1
    runId = $script:runId
    atUtc = [DateTime]::UtcNow.ToString("o")
    event = "rendered"
    runKind = $RunKind
    testRunName = $script:testRunName
})

try {
    $runnerImagePreflightJob = Invoke-RunnerImagePreflight
    Add-JsonLine -Path $script:experimentEventsPath -Record ([ordered]@{
        schemaVersion = 1
        runId = $script:runId
        atUtc = [DateTime]::UtcNow.ToString("o")
        event = "runner_image_preflight_passed"
        jobName = $runnerImagePreflightJob
        image = [string]$script:metadata.runnerImage
    })
    $runStartUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    & kubectl --context $script:targetContext `
        apply -f ([string]$rendered.ManifestPath) |
        Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to submit TestRun '$script:testRunName'."
    }
    $testRunSubmitted = $true
    Add-JsonLine -Path $script:experimentEventsPath -Record ([ordered]@{
        schemaVersion = 1
        runId = $script:runId
        atUtc = [DateTime]::UtcNow.ToString("o")
        event = "testrun_submitted"
        testRunName = $script:testRunName
    })

    & (Join-Path $PSScriptRoot "capture-aks-els-evidence.ps1") `
        -RunId $script:runId `
        -KubeContext $script:targetContext `
        -OutputDirectory $script:resultsDirectory |
        Out-Host

    $monitorOutput = Join-Path `
        $script:resultsDirectory `
        "$script:runId-resource-monitor.log"
    $monitorError = Join-Path `
        $script:resultsDirectory `
        "$script:runId-resource-monitor-error.log"
    $powershellPath = (Get-Process -Id $PID).Path
    $resourceMonitor = Start-Process `
        -FilePath $powershellPath `
        -ArgumentList @(
            "-NoProfile",
            "-File", (Join-Path $PSScriptRoot "monitor-aks-testrun.ps1"),
            "-RunId", $script:runId,
            "-KubeContext", $script:targetContext,
            "-SampleIntervalSeconds", "5",
            "-TimeoutMinutes", "30",
            "-OutputDirectory", $script:resultsDirectory
        ) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $monitorOutput `
        -RedirectStandardError $monitorError `
        -PassThru

    $runnerPods = @(Wait-RunnerPodsReady)
    Write-RunnerPlacement -RunnerPods $runnerPods
    $crossEnvironmentMonitor = Start-CrossEnvironmentMonitor

    $readyDeadline = [DateTime]::UtcNow.AddSeconds(180)
    do {
        $logs = Get-RunnerLogs -RunnerPods $runnerPods
        $crossCount = Get-CrossEnvironmentCount -Logs $logs
        if ($crossCount -gt 0) {
            throw (
                "Cross-environment delivery was observed before control " +
                "updates (count=$crossCount)."
            )
        }
        $readySnapshot = Get-ReadySnapshot -Logs $logs
        Write-Host (
            "{0:HH:mm:ss} initial full-sync ready={1}/10000" -f
            [DateTime]::Now,
            $readySnapshot.Count
        )
        if ($readySnapshot.Count -eq 10000) {
            Assert-ReadyTopology -Snapshot $readySnapshot
            break
        }
        if ([DateTime]::UtcNow -ge $readyDeadline) {
            throw "The exact 10,000-connection ready topology was not reached."
        }
        Start-Sleep -Seconds 5
    } while ($true)
    Add-JsonLine -Path $script:experimentEventsPath -Record ([ordered]@{
        schemaVersion = 1
        runId = $script:runId
        atUtc = [DateTime]::UtcNow.ToString("o")
        event = "ready_topology_verified"
        connections = 10000
        environments = 100
        connectionsPerEnvironment = 100
        connectionsPerEnvironmentPerRunner = 5
    })

    $runnerOne = @(
        $runnerPods |
            Where-Object {
                [string]$_.metadata.name -match
                    "^$([regex]::Escape($script:testRunName))-1-[a-z0-9]+$"
            }
    )
    if ($runnerOne.Count -ne 1) {
        throw "Runner 1 was not resolved uniquely."
    }
    $runnerOneName = [string]$runnerOne[0].metadata.name

    $warmRevision = [string]$script:inventory.expectedRevisions[0]
    Invoke-ControllerUpdate `
        -RunnerPodName $runnerOneName `
        -FlagKey ([string]$script:inventory.postRampWarmupFlagKey) `
        -TargetValue $warmRevision `
        -Phase "post-ramp-warmup-revision" |
        Out-Host
    $warmRevisionCoverage = Wait-WarmupCoverage `
        -RunnerPods $runnerPods `
        -Phase "revision" `
        -CrossEnvironmentMonitor $crossEnvironmentMonitor `
        -TimeoutSeconds 30

    Invoke-ControllerUpdate `
        -RunnerPodName $runnerOneName `
        -FlagKey ([string]$script:inventory.postRampWarmupFlagKey) `
        -TargetValue "baseline" `
        -Phase "post-ramp-warmup-baseline" |
        Out-Host
    $warmBaselineCoverage = Wait-WarmupCoverage `
        -RunnerPods $runnerPods `
        -Phase "baseline" `
        -CrossEnvironmentMonitor $crossEnvironmentMonitor `
        -TimeoutSeconds 30
    Add-JsonLine -Path $script:experimentEventsPath -Record ([ordered]@{
        schemaVersion = 1
        runId = $script:runId
        atUtc = [DateTime]::UtcNow.ToString("o")
        event = "warmup_verified"
        revisionDeliveries = $warmRevisionCoverage.Unique
        baselineDeliveries = $warmBaselineCoverage.Unique
        totalDeliveries = (
            $warmRevisionCoverage.Total + $warmBaselineCoverage.Total
        )
    })

    $firstFormalStartUnixMs = 0L
    for (
        $revisionOffset = 0;
        $revisionOffset -lt @($script:inventory.expectedRevisions).Count;
        $revisionOffset += 1
    ) {
        $dueUnixMs = 0L
        if ($revisionOffset -gt 0) {
            $dueUnixMs = (
                $firstFormalStartUnixMs + ($revisionOffset * 30000)
            )
            Wait-UntilUnixMs `
                -DueUnixMs ($dueUnixMs - 10000) `
                -CrossEnvironmentMonitor $crossEnvironmentMonitor
        }
        Assert-CrossEnvironmentIsolation `
            -Monitor $crossEnvironmentMonitor
        $revision = [string]$script:inventory.expectedRevisions[$revisionOffset]
        $update = Invoke-ControllerUpdate `
            -RunnerPodName $runnerOneName `
            -FlagKey ([string]$script:inventory.measuredFlagKey) `
            -TargetValue $revision `
            -Phase ("formal-revision-{0:D3}" -f ($revisionOffset + 1)) `
            -RevisionIndex ($revisionOffset + 1) `
            -DueUnixMs $dueUnixMs
        if ($null -eq $update.RequestStartUnixMs) {
            throw "Formal revision '$revision' has no request_start timestamp."
        }
        if ($revisionOffset -eq 0) {
            $firstFormalStartUnixMs = [int64]$update.RequestStartUnixMs
        }
        Write-Host (
            "{0:HH:mm:ss} formal revision {1}/10 applied: {2}" -f
            [DateTime]::Now,
            ($revisionOffset + 1),
            $revision
        )
        Add-JsonLine -Path $script:experimentEventsPath -Record ([ordered]@{
            schemaVersion = 1
            runId = $script:runId
            atUtc = [DateTime]::UtcNow.ToString("o")
            event = "formal_update_succeeded"
            revisionIndex = $revisionOffset + 1
            revision = $revision
            requestStartUnixMs = [int64]$update.RequestStartUnixMs
        })
    }

    Wait-UntilUnixMs `
        -DueUnixMs ($firstFormalStartUnixMs + 300000) `
        -CrossEnvironmentMonitor $crossEnvironmentMonitor
    $finalLogs = Get-RunnerLogs -RunnerPods $runnerPods
    $finalCrossCount = Get-CrossEnvironmentCount -Logs $finalLogs
    if ($finalCrossCount -gt 0) {
        throw (
            "Cross-environment delivery was detected after formal updates " +
            "(count=$finalCrossCount)."
        )
    }
}
catch {
    Add-Failure -Message $_.Exception.Message
}
finally {
    if ($testRunSubmitted) {
        try {
            $terminalStage = Wait-TestRunTerminal -TimeoutMinutes 30
            if ($terminalStage -ne "finished") {
                Add-Failure -Message (
                    "TestRun finished in terminal stage '$terminalStage'."
                )
            }
        }
        catch {
            Add-Failure -Message $_.Exception.Message
        }
        if ($null -ne $crossEnvironmentMonitor) {
            if (
                -not $script:crossEnvironmentDetected -and
                (Test-CrossEnvironmentMonitorLog)
            ) {
                $script:crossEnvironmentDetected = $true
                Add-Failure -Message (
                    "Cross-environment delivery was present in the live " +
                    "runner monitor evidence."
                )
            }
            try {
                Stop-CrossEnvironmentMonitor `
                    -Monitor $crossEnvironmentMonitor
            }
            catch {
                Add-Failure -Message (
                    "Stopping the local cross-environment monitor failed: " +
                    $_.Exception.Message
                )
            }
        }
        $runEndUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

        if ($runStartUnixMs -gt 0 -and $runEndUnixMs -gt $runStartUnixMs) {
            try {
                & (Join-Path $PSScriptRoot "snapshot-aks-streaming-timing.ps1") `
                    -RunId $script:runId `
                    -KubeContext $script:targetContext `
                    -StartUnixMs $runStartUnixMs `
                    -EndUnixMs $runEndUnixMs `
                    -OutputDirectory $script:resultsDirectory |
                    Out-Host
            }
            catch {
                Add-Failure -Message (
                    "Streaming timing snapshot failed: " +
                    $_.Exception.Message
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
                    -OutputDirectory $script:resultsDirectory |
                    Out-Host
            }
            catch {
                Add-Failure -Message (
                    "One-second evidence snapshot failed: " +
                    $_.Exception.Message
                )
            }
        }

        try {
            $restoreJobName = Restore-MeasuredFlagBaseline
            $baselineRestored = $true
            Add-JsonLine -Path $script:experimentEventsPath -Record ([ordered]@{
                schemaVersion = 1
                runId = $script:runId
                atUtc = [DateTime]::UtcNow.ToString("o")
                event = "baseline_restored"
                jobName = $restoreJobName
            })
        }
        catch {
            Add-Failure -Message (
                "Measured flag baseline restoration failed: " +
                $_.Exception.Message
            )
        }

        if ($null -ne $resourceMonitor) {
            try {
                if (-not $resourceMonitor.HasExited) {
                    $resourceMonitor.WaitForExit(120000)
                }
                if (-not $resourceMonitor.HasExited) {
                    Add-Failure -Message (
                        "Resource monitor did not exit within two minutes " +
                        "after the TestRun."
                    )
                }
                elseif ($resourceMonitor.ExitCode -ne 0) {
                    Add-Failure -Message (
                        "Resource monitor exited with code " +
                        "$($resourceMonitor.ExitCode)."
                    )
                }
            }
            catch {
                Add-Failure -Message (
                    "Resource monitor wait failed: $($_.Exception.Message)"
                )
            }
        }

        try {
            $collectionOutput = @(
                & (
                    Join-Path $PSScriptRoot "collect-results-aks.ps1"
                ) `
                    -RunId $script:runId `
                    -KubeContext $script:targetContext `
                    -AllowIncomplete `
                    -AllowFailedRunners
            )
            $collection = Select-ScriptResult `
                -Output $collectionOutput `
                -RequiredProperties @(
                    "RunId",
                    "ArchiveDirectory",
                    "CollectionPath",
                    "ArtifactCount"
                ) `
                -Description "AKS result collector"
            $archiveDirectory = [string]$collection.ArchiveDirectory
        }
        catch {
            Add-Failure -Message (
                "AKS result collection failed: $($_.Exception.Message)"
            )
        }

        if ($archiveDirectory) {
            try {
                & (Join-Path $PSScriptRoot "analyze-aks-1s-evidence.ps1") `
                    -RunId $script:runId `
                    -ResultsDirectory $script:resultsDirectory |
                    Out-Host
            }
            catch {
                Add-Failure -Message (
                    "One-second evidence analysis failed: " +
                    $_.Exception.Message
                )
            }
            try {
                $analysisOutput = @(
                    & (
                        Join-Path `
                            $PSScriptRoot `
                            "analyze-aks-multi-environment.ps1"
                    ) `
                        -RunId $script:runId `
                        -ResultsDirectory $script:resultsDirectory
                )
                $analysis = Select-ScriptResult `
                    -Output $analysisOutput `
                    -RequiredProperties @(
                        "runId",
                        "passed",
                        "jsonPath"
                    ) `
                    -Description "Multi-environment analyzer"
                if ($analysis.passed -ne $true) {
                    Add-Failure -Message (
                        "Multi-environment analysis failed one or more gates."
                    )
                }
            }
            catch {
                Add-Failure -Message (
                    "Multi-environment analysis failed: " +
                    $_.Exception.Message
                )
            }
        }
    }
}

$analysisPath = if ($archiveDirectory) {
    Join-Path `
        $archiveDirectory `
        "$script:runId-multi-environment-analysis.json"
}
else {
    ""
}
$analysisPassed = $false
if ($analysisPath -and (Test-Path -LiteralPath $analysisPath -PathType Leaf)) {
    $analysisPassed = [bool](
        (Get-Content -Raw -LiteralPath $analysisPath | ConvertFrom-Json).passed
    )
}
$passed = (
    $analysisPassed -and
    $terminalStage -eq "finished" -and
    $baselineRestored -and
    $script:failureReasons.Count -eq 0
)

[pscustomobject]@{
    RunId = $script:runId
    TestRunName = $script:testRunName
    RunKind = $RunKind
    Passed = $passed
    TerminalStage = $terminalStage
    BaselineRestored = $baselineRestored
    ArchiveDirectory = $archiveDirectory
    AnalysisPath = $analysisPath
    FailureReasons = @($script:failureReasons)
    DeletedResources = 0
}
