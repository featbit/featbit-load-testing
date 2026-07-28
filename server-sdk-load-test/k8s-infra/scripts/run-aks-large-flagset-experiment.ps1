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

    [string] $MatrixPath = "",

    [string] $Note = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content
    )

    if (Test-Path -LiteralPath $Path) {
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
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Output,
        [Parameter(Mandatory)][string[]] $RequiredProperties,
        [Parameter(Mandatory)][string] $Description
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
    return @(
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

function Wait-TestRunStarted {
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    do {
        $stage = (
            & kubectl --context $script:targetContext `
                -n $script:namespace `
                get testrun $script:testRunName `
                -o "jsonpath={.status.stage}" 2>$null |
                Out-String
        ).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to inspect TestRun stage before the ready window."
        }
        Write-Host (
            "{0:HH:mm:ss} waiting for workload start: stage={1}" -f
            [DateTime]::Now,
            $stage
        )
        if ($stage -eq "started") {
            return
        }
        if ($stage -eq "error") {
            throw "TestRun entered the error stage before workload start."
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for the TestRun workload to start."
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
    $runnerCounts = @{}
    $syncIdentity = @{}
    foreach ($entry in $Logs.GetEnumerator()) {
        $podName = [string]$entry.Key
        if (
            $podName -notmatch
                "^$([regex]::Escape($script:testRunName))-(?<runner>\d+)-"
        ) {
            continue
        }
        $logRunner = [int]$Matches.runner
        $readyMatches = [regex]::Matches(
            [string]$entry.Value,
            (
                "STREAM_READY\|1\|(?<at>\d+)\|" +
                [regex]::Escape($script:runId) +
                "\|" +
                [regex]::Escape(
                    [string]$script:inventory.environment.id
                ) +
                "\|(?<runner>\d+)\|(?<connection>\d+)"
            )
        )
        foreach ($match in $readyMatches) {
            $runner = [int]$match.Groups["runner"].Value
            $connection = [int]$match.Groups["connection"].Value
            if (
                $runner -ne $logRunner -or
                $runner -lt 1 -or $runner -gt 20 -or
                $connection -lt 1 -or $connection -gt 500
            ) {
                throw "Runner ready identity is outside the fixed topology."
            }
            $key = "$runner|$connection"
            if ($identity.ContainsKey($key)) {
                throw "Duplicate STREAM_READY identity '$key'."
            }
            $identity[$key] = $true
            $runnerCounts[$runner] = 1 + [int]$runnerCounts[$runner]
        }
        $syncMatches = [regex]::Matches(
            [string]$entry.Value,
            (
                "STREAM_SYNC\|1\|\d+\|" +
                [regex]::Escape($script:runId) +
                "\|" +
                [regex]::Escape(
                    [string]$script:inventory.environment.id
                ) +
                "\|(?<runner>\d+)\|(?<connection>\d+)\|" +
                "\d+\|\d+\|\d+\|\d+\|(?<flags>\d+)\|"
            )
        )
        foreach ($match in $syncMatches) {
            $runner = [int]$match.Groups["runner"].Value
            $connection = [int]$match.Groups["connection"].Value
            if ([int]$match.Groups["flags"].Value -ne 3000) {
                throw (
                    "Runner $runner connection $connection reported a " +
                    "non-3,000 flag full sync."
                )
            }
            $key = "$runner|$connection"
            if ($syncIdentity.ContainsKey($key)) {
                throw "Duplicate STREAM_SYNC identity '$key'."
            }
            $syncIdentity[$key] = $true
        }
    }
    return [pscustomobject]@{
        ReadyCount = $identity.Count
        SyncCount = $syncIdentity.Count
        RunnerCounts = $runnerCounts
    }
}

function Assert-ReadyTopology {
    param([Parameter(Mandatory)][object] $Snapshot)

    if ($Snapshot.ReadyCount -ne 10000 -or $Snapshot.SyncCount -ne 10000) {
        throw (
            "Expected 10,000 unique ready and sync records; found " +
            "$($Snapshot.ReadyCount) ready and $($Snapshot.SyncCount) sync."
        )
    }
    foreach ($runner in 1..20) {
        if ([int]$Snapshot.RunnerCounts[$runner] -ne 500) {
            throw "Runner $runner did not report exactly 500 ready connections."
        }
    }
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
                [regex]::Escape(
                    [string]$script:inventory.environment.id
                ) +
                "\|" +
                [regex]::Escape(
                    [string]$script:inventory.postRampWarmupFlagKey
                ) +
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
        [ValidateRange(1, 300)][int] $TimeoutSeconds = 120
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $logs = Get-RunnerLogs -RunnerPods $RunnerPods
        $coverage = Get-WarmupSnapshot -Logs $logs -Phase $Phase
        Write-Host (
            "{0:HH:mm:ss} warm-up {1}: unique={2}/10000, records={3}" -f
            [DateTime]::Now,
            $Phase,
            $coverage.Unique,
            $coverage.Total
        )
        if ($coverage.Unique -eq 10000 -and $coverage.Total -eq 10000) {
            return $coverage
        }
        if ($coverage.Unique -gt 10000 -or $coverage.Total -gt 10000) {
            throw "Warm-up '$Phase' contains duplicate delivery records."
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw (
                "Warm-up '$Phase' did not reach exactly 10,000/10,000 " +
                "within $TimeoutSeconds seconds."
            )
        }
        Start-Sleep -Seconds 5
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
        "exec", $RunnerPodName, "--",
        "k6", "run", "--summary-mode", "disabled",
        "-e", "RUN_ID=$script:runId",
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
    $records = @(Add-ControlRecords -Text $output)
    $resultPattern = (
        "STREAM_CONTROLLER_RESULT\|1\|" +
        [regex]::Escape($script:runId) +
        "\|" +
        [regex]::Escape([string]$script:inventory.environment.id) +
        "\|" +
        [regex]::Escape($FlagKey) +
        "\|" +
        [regex]::Escape($Phase) +
        "\|" +
        [regex]::Escape($TargetRevision) +
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
    param([Parameter(Mandatory)][int64] $DueUnixMs)

    do {
        $remaining = $DueUnixMs -
            [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        if ($remaining -le 0) {
            return
        }
        Start-Sleep -Milliseconds ([int][Math]::Min(5000, $remaining))
    } while ($true)
}

function Write-RunnerPlacement {
    param([Parameter(Mandatory)][object[]] $RunnerPods)

    $placementProperty = (
        $script:matrix.fixedInfrastructure.PSObject.Properties[
            "runnerPlacement"
        ]
    )
    $expectedNodeCount = if ($null -eq $placementProperty) {
        [int]$script:matrix.fixedInfrastructure.loadgenNodes
    }
    else {
        [int]$placementProperty.Value.nodeCount
    }
    $expectedRunnersPerNode = if ($null -eq $placementProperty) {
        [int]$script:matrix.parallelism / $expectedNodeCount
    }
    else {
        [int]$placementProperty.Value.runnersPerNode
    }
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
        $rows.Count -ne [int]$script:matrix.parallelism -or
        $nodeGroups.Count -ne $expectedNodeCount -or
        @(
            $nodeGroups |
                Where-Object Count -ne $expectedRunnersPerNode
        ).Count -ne 0
    ) {
        throw (
            "Runner placement is not exactly $expectedRunnersPerNode " +
            "runner(s) on each of $expectedNodeCount nodes."
        )
    }
    $document = [ordered]@{
        schemaVersion = 1
        runId = $script:runId
        capturedAtUtc = [DateTime]::UtcNow.ToString("o")
        pods = $rows
        nodeCount = $nodeGroups.Count
        runnersPerNode = $expectedRunnersPerNode
    }
    Write-Utf8NoBom `
        -Path (
            Join-Path `
                $script:resultsDirectory `
                "$script:runId-runner-placement.json"
        ) `
        -Content (($document | ConvertTo-Json -Depth 8) + "`n")
}

function Wait-TestRunTerminal {
    param([ValidateRange(5, 120)][int] $TimeoutMinutes = 35)

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
    $jobName = "flagset3k-preflight-{0}-{1}" -f `
        [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"), `
        [Guid]::NewGuid().ToString("N").Substring(0, 6)
    $logPath = Join-Path `
        $script:resultsDirectory `
        "$script:runId-runner-image-preflight.log"
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
                    initContainers = @(
                        [ordered]@{
                            name = "archive-without-runner-env"
                            image = [string]$script:metadata.runnerImage
                            imagePullPolicy = "IfNotPresent"
                            command = @(
                                "k6",
                                "archive",
                                (
                                    "/tests/k6/" +
                                    "server-streaming-large-flagset.js"
                                ),
                                "-O",
                                "/tmp/server-streaming-large-flagset.tar"
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
                                "/tests/k6/server-streaming-large-flagset.js"
                            )
                            envFrom = @(
                                [ordered]@{
                                    configMapRef = [ordered]@{
                                        name = [string](
                                            $script:matrix.kubernetesObjects.
                                                configMap
                                        )
                                    }
                                }
                            )
                            env = @(
                                [ordered]@{
                                    name = "FEATBIT_STREAMING_URL"
                                    value = [string]$script:matrix.streamingUrl
                                },
                                [ordered]@{
                                    name = "FEATBIT_API_URL"
                                    value = (
                                        [string]$script:matrix.
                                            configurationApiUrl
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
                                    value = "180"
                                },
                                [ordered]@{
                                    name = "INITIAL_SYNC_TIMEOUT_SECONDS"
                                    value = "180"
                                },
                                [ordered]@{
                                    name = "INITIAL_SYNC_P99_MS"
                                    value = "180000"
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
                                    name = "environment-secret"
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
                            name = "environment-secret"
                            secret = [ordered]@{
                                secretName = [string](
                                    $script:matrix.kubernetesObjects.secret
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
    & kubectl --context $script:targetContext `
        -n $script:namespace `
        wait "job/$jobName" `
        --for=condition=complete `
        --timeout=5m *> $null
    $waitExit = $LASTEXITCODE
    $logText = (
        & kubectl --context $script:targetContext `
            -n $script:namespace `
            logs "job/$jobName" 2>&1 |
            Out-String
    )
    $logExit = $LASTEXITCODE
    Write-Utf8NoBom -Path $logPath -Content $logText
    if (
        $waitExit -ne 0 -or
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

function Restore-MeasuredFlagsBaseline {
    $jobs = [Collections.Generic.List[string]]::new()
    $failures = [Collections.Generic.List[string]]::new()
    $logBuilder = [Text.StringBuilder]::new()
    foreach ($step in @($script:inventory.revisionPlan)) {
        $jobName = "flagset3k-restore-{0:D2}-{1}" -f `
            [int]$step.index, `
            [Guid]::NewGuid().ToString("N").Substring(0, 6)
        $jobs.Add($jobName)
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
                                    "k6", "run",
                                    "--summary-mode", "disabled",
                                    "-e", "RUN_ID=$script:runId",
                                    "-e", (
                                        "CONTROLLER_FLAG_KEY=" +
                                        [string]$step.flagKey
                                    ),
                                    "-e", "CONTROLLER_TARGET_REVISION=baseline",
                                    "-e", (
                                        "CONTROLLER_REQUIRED_REVISIONS=" +
                                        [string]$step.revision
                                    ),
                                    "-e", (
                                        "CONTROLLER_VARIATION_TYPE=" +
                                        [string]$step.variationType
                                    ),
                                    "-e", (
                                        "CONTROLLER_PHASE=post-run-baseline-" +
                                        ("{0:D2}" -f [int]$step.index)
                                    ),
                                    "-e", "CONTROLLER_REVISION_INDEX=0",
                                    "-e", (
                                        "CONTROLLER_ALLOW_ALREADY_SERVED=true"
                                    ),
                                    (
                                        "/tests/k6/" +
                                        "controller-update-large-flagset.js"
                                    )
                                )
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
                                            name = (
                                                "featbit-k6-controller-secret"
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
                                    runAsNonRoot = $true
                                    runAsUser = 12345
                                    runAsGroup = 12345
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
            $failures.Add("Failed to create restore Job '$jobName'.")
            continue
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
                logs "job/$jobName" 2>&1 |
                Out-String
        )
        $logExit = $LASTEXITCODE
        $null = $logBuilder.AppendLine("===== $jobName =====")
        $null = $logBuilder.AppendLine($logText.TrimEnd())
        $expectedPhase = "post-run-baseline-{0:D2}" -f [int]$step.index
        $resultPattern = (
            "STREAM_CONTROLLER_RESULT\|1\|" +
            [regex]::Escape($script:runId) +
            "\|.+\|" +
            [regex]::Escape([string]$step.flagKey) +
            "\|" +
            [regex]::Escape($expectedPhase) +
            "\|baseline\|(changed|unchanged)"
        )
        if (
            $waitExit -ne 0 -or
            $logExit -ne 0 -or
            $logText -notmatch $resultPattern
        ) {
            $failures.Add(
                "Restore Job '$jobName' did not return a valid result."
            )
        }
    }
    Write-Utf8NoBom `
        -Path (
            Join-Path $script:resultsDirectory "$script:runId-restore.log"
        ) `
        -Content $logBuilder.ToString()
    if ($failures.Count -gt 0) {
        throw ($failures -join " ")
    }
    return @($jobs)
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
$script:matrix = $null
$resourceMonitor = $null
$testRunSubmitted = $false
$runStartUnixMs = 0L
$runEndUnixMs = 0L
$terminalStage = ""
$baselineRestored = $false
$archiveDirectory = ""

Assert-KubernetesContext -KubeContext $script:targetContext
$repositoryRoot = Get-RepositoryRoot
$script:resultsDirectory = Join-Path $repositoryRoot "results"
$resolvedMatrixPath = if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
    Join-Path `
        $repositoryRoot `
        "k8s-infra\matrices\aks-single-environment-3k-flags-g5-d4-els3.json"
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $MatrixPath
    )
}
if (-not (Test-Path -LiteralPath $resolvedMatrixPath -PathType Leaf)) {
    throw "Large flag-set matrix does not exist: $resolvedMatrixPath"
}
$script:matrix = Get-Content `
    -Raw `
    -LiteralPath $resolvedMatrixPath |
    ConvertFrom-Json
$null = New-Item -ItemType Directory -Force -Path $script:resultsDirectory

$renderOutput = @(
    & (
        Join-Path $PSScriptRoot "render-aks-large-flagset-testrun.ps1"
    ) `
        -RunKind $RunKind `
        -KubeContext $script:targetContext `
        -RunnerImage $RunnerImage `
        -MatrixPath $resolvedMatrixPath `
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
    -Description "Large flag-set TestRun renderer"
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
        "get", "configmap",
        [string]$script:matrix.kubernetesObjects.configMap,
        "-o", "json"
    ) `
    -FailureMessage "Failed to read the large flag-set ConfigMap."
$script:inventory = [string]$configMap.data."inventory.json" | ConvertFrom-Json
if (
    [int]$script:inventory.topology.environmentCount -ne 1 -or
    [int]$script:inventory.topology.flagCount -ne 3000 -or
    [int]$script:inventory.topology.totalConnections -ne 10000 -or
    @($script:inventory.revisionPlan).Count -ne 10
) {
    throw "The large flag-set inventory does not match the fixed topology."
}
$inventoryPath = Join-Path `
    $script:resultsDirectory `
    "$script:runId-large-flagset-inventory.json"
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

& (Join-Path $PSScriptRoot "ensure-aks-multi-environment-1s-evidence.ps1") `
    -KubeContext $script:targetContext |
    Out-Host
$additionalCollectorProperty = $script:matrix.PSObject.Properties["evidence"]
if (
    $null -ne $additionalCollectorProperty -and
    $null -ne $additionalCollectorProperty.Value.PSObject.Properties[
        "additionalCollector"
    ]
) {
    & (Join-Path $PSScriptRoot "ensure-aks-large-flagset-1s-evidence.ps1") `
        -KubeContext $script:targetContext `
        -MatrixPath $resolvedMatrixPath |
        Out-Host
}

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
    $additionalPoolsProperty = (
        $script:matrix.fixedInfrastructure.PSObject.Properties[
            "additionalNodePools"
        ]
    )
    $monitorNodePools = @(
        "system",
        "featbit",
        "loadgen"
        if ($null -ne $additionalPoolsProperty) {
            @($additionalPoolsProperty.Value) |
                ForEach-Object { [string]$_.name }
        }
    ) | Sort-Object -Unique
    $powershellPath = (Get-Process -Id $PID).Path
    $resourceMonitor = Start-Process `
        -FilePath $powershellPath `
        -ArgumentList @(
            "-NoProfile",
            "-File", (Join-Path $PSScriptRoot "monitor-aks-testrun.ps1"),
            "-RunId", $script:runId,
            "-KubeContext", $script:targetContext,
            "-SampleIntervalSeconds", "5",
            "-TimeoutMinutes", "35",
            "-IncludedNodePools", ($monitorNodePools -join ","),
            "-OutputDirectory", $script:resultsDirectory
        ) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $monitorOutput `
        -RedirectStandardError $monitorError `
        -PassThru

    $runnerPods = @(Wait-RunnerPodsReady)
    Write-RunnerPlacement -RunnerPods $runnerPods
    Wait-TestRunStarted
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(
        [int]$script:matrix.readyCoverageTimeoutSeconds
    )
    do {
        $logs = Get-RunnerLogs -RunnerPods $runnerPods
        $readySnapshot = Get-ReadySnapshot -Logs $logs
        Write-Host (
            "{0:HH:mm:ss} ready={1}/10000; exact-sync={2}/10000" -f
            [DateTime]::Now,
            $readySnapshot.ReadyCount,
            $readySnapshot.SyncCount
        )
        if (
            $readySnapshot.ReadyCount -eq 10000 -and
            $readySnapshot.SyncCount -eq 10000
        ) {
            Assert-ReadyTopology -Snapshot $readySnapshot
            break
        }
        if ([DateTime]::UtcNow -ge $readyDeadline) {
            throw "The exact 10,000-connection / 3,000-flag ready topology was not reached."
        }
        Start-Sleep -Seconds 5
    } while ($true)
    Add-JsonLine -Path $script:experimentEventsPath -Record ([ordered]@{
        schemaVersion = 1
        runId = $script:runId
        atUtc = [DateTime]::UtcNow.ToString("o")
        event = "ready_topology_verified"
        connections = 10000
        environments = 1
        flagsPerFullSync = 3000
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
        -TargetRevision $warmRevision `
        -VariationType "string" `
        -Phase "post-ramp-warmup-revision" |
        Out-Host
    $warmRevisionCoverage = Wait-WarmupCoverage `
        -RunnerPods $runnerPods `
        -Phase "revision" `
        -TimeoutSeconds ([int]$script:matrix.warmupCoverageTimeoutSeconds)

    Invoke-ControllerUpdate `
        -RunnerPodName $runnerOneName `
        -FlagKey ([string]$script:inventory.postRampWarmupFlagKey) `
        -TargetRevision "baseline" `
        -VariationType "string" `
        -Phase "post-ramp-warmup-baseline" |
        Out-Host
    $warmBaselineCoverage = Wait-WarmupCoverage `
        -RunnerPods $runnerPods `
        -Phase "baseline" `
        -TimeoutSeconds ([int]$script:matrix.warmupCoverageTimeoutSeconds)
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
    foreach ($step in @($script:inventory.revisionPlan)) {
        $offset = [int]$step.index - 1
        $dueUnixMs = 0L
        if ($offset -gt 0) {
            $dueUnixMs = (
                $firstFormalStartUnixMs +
                ($offset * [int]$script:matrix.revisionIntervalSeconds * 1000)
            )
            Wait-UntilUnixMs -DueUnixMs ($dueUnixMs - 10000)
        }
        $update = Invoke-ControllerUpdate `
            -RunnerPodName $runnerOneName `
            -FlagKey ([string]$step.flagKey) `
            -TargetRevision ([string]$step.revision) `
            -VariationType ([string]$step.variationType) `
            -Phase ("formal-revision-{0:D3}" -f [int]$step.index) `
            -RevisionIndex ([int]$step.index) `
            -DueUnixMs $dueUnixMs
        if ($null -eq $update.RequestStartUnixMs) {
            throw "Formal revision '$($step.revision)' has no request_start timestamp."
        }
        if ([int]$step.index -eq 1) {
            $firstFormalStartUnixMs = [int64]$update.RequestStartUnixMs
        }
        Write-Host (
            "{0:HH:mm:ss} formal revision {1}/10 applied: {2} ({3})" -f
            [DateTime]::Now,
            [int]$step.index,
            [string]$step.revision,
            [string]$step.variationType
        )
        Add-JsonLine -Path $script:experimentEventsPath -Record ([ordered]@{
            schemaVersion = 1
            runId = $script:runId
            atUtc = [DateTime]::UtcNow.ToString("o")
            event = "formal_update_succeeded"
            revisionIndex = [int]$step.index
            flagKey = [string]$step.flagKey
            variationType = [string]$step.variationType
            revision = [string]$step.revision
            requestStartUnixMs = [int64]$update.RequestStartUnixMs
        })
    }
    Wait-UntilUnixMs -DueUnixMs (
        $firstFormalStartUnixMs +
        (10 * [int]$script:matrix.revisionIntervalSeconds * 1000)
    )
}
catch {
    Add-Failure -Message $_.Exception.Message
}
finally {
    if ($testRunSubmitted) {
        try {
            $terminalStage = Wait-TestRunTerminal -TimeoutMinutes 35
            if ($terminalStage -ne "finished") {
                Add-Failure -Message (
                    "TestRun finished in terminal stage '$terminalStage'."
                )
            }
        }
        catch {
            Add-Failure -Message $_.Exception.Message
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
                if (
                    $null -ne $additionalCollectorProperty -and
                    $null -ne
                        $additionalCollectorProperty.Value.PSObject.Properties[
                            "additionalCollector"
                        ]
                ) {
                    $additionalCollector = (
                        $additionalCollectorProperty.Value.additionalCollector
                    )
                    & (
                        Join-Path `
                            $PSScriptRoot `
                            "snapshot-aks-multi-environment-1s-evidence.ps1"
                    ) `
                        -RunId $script:runId `
                        -KubeContext $script:targetContext `
                        -StartUnixMs $runStartUnixMs `
                        -EndUnixMs $runEndUnixMs `
                        -SourceRunId (
                            [string]$additionalCollector.sourceRunId
                        ) `
                        -DaemonSetName (
                            [string]$additionalCollector.daemonSetName
                        ) `
                        -ExpectedNodeCount (
                            [int]$additionalCollector.expectedNodeCount
                        ) `
                        -OutputDirectory $script:resultsDirectory |
                        Out-Host
                }
            }
            catch {
                Add-Failure -Message (
                    "One-second evidence snapshot failed: " +
                    $_.Exception.Message
                )
            }
        }

        try {
            $restoreJobs = @(Restore-MeasuredFlagsBaseline)
            $baselineRestored = $restoreJobs.Count -eq 10
            Add-JsonLine -Path $script:experimentEventsPath -Record ([ordered]@{
                schemaVersion = 1
                runId = $script:runId
                atUtc = [DateTime]::UtcNow.ToString("o")
                event = "baselines_restored"
                jobNames = $restoreJobs
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
                        "Resource monitor did not exit within two minutes."
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
                & (Join-Path $PSScriptRoot "collect-results-aks.ps1") `
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
                            "analyze-aks-large-flagset.ps1"
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
                    -Description "Large flag-set analyzer"
                if ($analysis.passed -ne $true) {
                    Add-Failure -Message (
                        "Large flag-set analysis failed one or more gates."
                    )
                }
            }
            catch {
                Add-Failure -Message (
                    "Large flag-set analysis failed: " +
                    $_.Exception.Message
                )
            }
        }
    }
}

$analysisPath = if ($archiveDirectory) {
    Join-Path `
        $archiveDirectory `
        "$script:runId-large-flagset-analysis.json"
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
