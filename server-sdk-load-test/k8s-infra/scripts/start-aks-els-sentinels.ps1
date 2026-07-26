[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [ValidateLength(1, 63)]
    [string] $RunId,

    [Parameter(Mandatory)]
    [string] $KubeContext,

    [Parameter(Mandatory)]
    [string] $RunnerImage,

    [ValidateRange(1, 100)]
    [int] $ExpectedLoadgenNodes = 10,

    [ValidateRange(1, 20)]
    [int] $ExpectedElsPods = 6,

    [ValidateRange(1, 20)]
    [int] $ConnectionsPerTarget = 3,

    [ValidateRange(300, 3600)]
    [int] $HoldDurationSeconds = 1800
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Invoke-KubectlJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $FailureMessage
    )

    $text = (
        & kubectl --request-timeout=30s @Arguments 2>&1 |
            Out-String
    )
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        throw "$FailureMessage`n$text"
    }
    return $text | ConvertFrom-Json
}

function Test-ReadyPod {
    param([Parameter(Mandatory)][object] $Pod)

    return (
        $null -eq $Pod.metadata.PSObject.Properties["deletionTimestamp"] -and
        $Pod.status.phase -eq "Running" -and
        @($Pod.status.containerStatuses).Count -gt 0 -and
        @($Pod.status.containerStatuses | Where-Object ready).Count -eq
            @($Pod.status.containerStatuses).Count
    )
}

$targetContext = $KubeContext.Trim()
$namespace = "featbit-loadtest"
$daemonSetName = "featbit-els-sentinel"
$configMapName = "featbit-els-sentinel-script"
$repositoryRoot = Get-RepositoryRoot

Assert-KubernetesContext -KubeContext $targetContext

foreach ($object in @(
    @{ Namespace = $namespace; Kind = "secret"; Name = "featbit-k6-secret" },
    @{ Namespace = $namespace; Kind = "configmap"; Name = "featbit-k6-target" }
)) {
    & kubectl --context $targetContext `
        -n $object.Namespace `
        get $object.Kind $object.Name -o name *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Required $($object.Kind) '$($object.Name)' does not exist."
    }
}

foreach ($name in @($daemonSetName, $configMapName)) {
    $kind = if ($name -ceq $daemonSetName) { "daemonset" } else { "configmap" }
    & kubectl --context $targetContext `
        -n $namespace `
        get $kind $name -o name *> $null
    if ($LASTEXITCODE -eq 0) {
        throw (
            "$kind '$name' already exists. Collect or stop the active sentinel " +
            "experiment before starting '$RunId'."
        )
    }
}

$nodes = (
    Invoke-KubectlJson `
        -Arguments @(
            "--context", $targetContext,
            "get", "nodes",
            "-l", "workload=loadgen",
            "-o", "json"
        ) `
        -FailureMessage "Failed to inspect loadgen nodes."
).items
$readyNodes = @($nodes | Where-Object {
    ($_.status.conditions | Where-Object type -eq "Ready").status -eq "True"
})
if ($readyNodes.Count -ne $ExpectedLoadgenNodes) {
    throw (
        "Expected $ExpectedLoadgenNodes ready loadgen nodes; " +
        "found $($readyNodes.Count)."
    )
}

$elsPods = @(
    (
        Invoke-KubectlJson `
            -Arguments @(
                "--context", $targetContext,
                "-n", "featbit",
                "get", "pods",
                "-l", "app.kubernetes.io/component=els",
                "-o", "json"
            ) `
            -FailureMessage "Failed to inspect ELS Pods."
    ).items |
        Where-Object { Test-ReadyPod -Pod $_ } |
        Sort-Object { $_.metadata.name }
)
if ($elsPods.Count -ne $ExpectedElsPods) {
    throw "Expected $ExpectedElsPods ready ELS Pods; found $($elsPods.Count)."
}
$elsNodes = @($elsPods.spec.nodeName | Sort-Object -Unique)
if ($elsNodes.Count -ne $ExpectedElsPods) {
    throw (
        "The sentinel experiment requires one ELS Pod per node; found " +
        "$($elsPods.Count) Pods on $($elsNodes.Count) nodes."
    )
}

$targets = @(
    $elsPods | ForEach-Object {
        $ip = [string]$_.status.podIP
        if ($ip -notmatch "^\d{1,3}(\.\d{1,3}){3}$") {
            throw "ELS Pod '$($_.metadata.name)' has invalid IPv4 address '$ip'."
        }
        [ordered]@{
            pod = [string]$_.metadata.name
            ip = $ip
            node = [string]$_.spec.nodeName
            uid = [string]$_.metadata.uid
        }
    }
)
$targetEnv = @(
    $targets | ForEach-Object {
        [ordered]@{
            pod = $_.pod
            ip = $_.ip
        }
    }
) | ConvertTo-Json -Depth 5 -Compress

$sourceFiles = [ordered]@{
    "els-sentinel.js" = Join-Path $repositoryRoot "k6\els-sentinel.js"
    "connection-token.js" = Join-Path $repositoryRoot "k6\lib\connection-token.js"
    "probe.js" = Join-Path $repositoryRoot "k6\lib\probe.js"
    "sentinel.js" = Join-Path $repositoryRoot "k6\lib\sentinel.js"
}
foreach ($entry in $sourceFiles.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
        throw "Sentinel source does not exist: $($entry.Value)"
    }
}

$labels = [ordered]@{
    "app.kubernetes.io/name" = $daemonSetName
    "app.kubernetes.io/part-of" = "featbit-load-testing"
    "loadtest.featbit.io/run-id" = $RunId
}
$configMap = [ordered]@{
    apiVersion = "v1"
    kind = "ConfigMap"
    metadata = [ordered]@{
        name = $configMapName
        namespace = $namespace
        labels = $labels
    }
    data = [ordered]@{
        "els-sentinel.js" = Get-Content -Raw -LiteralPath $sourceFiles["els-sentinel.js"]
        "connection-token.js" = Get-Content -Raw -LiteralPath $sourceFiles["connection-token.js"]
        "probe.js" = Get-Content -Raw -LiteralPath $sourceFiles["probe.js"]
        "sentinel.js" = Get-Content -Raw -LiteralPath $sourceFiles["sentinel.js"]
        "targets.json" = ($targets | ConvertTo-Json -Depth 10)
    }
}

$daemonSet = [ordered]@{
    apiVersion = "apps/v1"
    kind = "DaemonSet"
    metadata = [ordered]@{
        name = $daemonSetName
        namespace = $namespace
        labels = $labels
    }
    spec = [ordered]@{
        selector = [ordered]@{
            matchLabels = [ordered]@{
                "app.kubernetes.io/name" = $daemonSetName
            }
        }
        template = [ordered]@{
            metadata = [ordered]@{
                labels = $labels
            }
            spec = [ordered]@{
                automountServiceAccountToken = $false
                terminationGracePeriodSeconds = 20
                nodeSelector = [ordered]@{
                    workload = "loadgen"
                }
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
                        name = "sentinel"
                        image = $RunnerImage
                        imagePullPolicy = "IfNotPresent"
                        command = @(
                            "k6",
                            "run",
                            "--quiet",
                            "/sentinel/els-sentinel.js"
                        )
                        envFrom = @(
                            [ordered]@{
                                configMapRef = [ordered]@{
                                    name = "featbit-k6-target"
                                }
                            },
                            [ordered]@{
                                secretRef = [ordered]@{
                                    name = "featbit-k6-secret"
                                }
                            }
                        )
                        env = @(
                            [ordered]@{
                                name = "RUN_ID"
                                value = $RunId
                            },
                            [ordered]@{
                                name = "NODE_NAME"
                                valueFrom = [ordered]@{
                                    fieldRef = [ordered]@{
                                        fieldPath = "spec.nodeName"
                                    }
                                }
                            },
                            [ordered]@{
                                name = "POD_NAME"
                                valueFrom = [ordered]@{
                                    fieldRef = [ordered]@{
                                        fieldPath = "metadata.name"
                                    }
                                }
                            },
                            [ordered]@{
                                name = "ELS_SENTINEL_TARGETS"
                                value = $targetEnv
                            },
                            [ordered]@{
                                name = "SENTINEL_CONNECTIONS_PER_TARGET"
                                value = [string]$ConnectionsPerTarget
                            },
                            [ordered]@{
                                name = "SENTINEL_HOLD_SECONDS"
                                value = [string]$HoldDurationSeconds
                            },
                            [ordered]@{
                                name = "PROBE_FLAG_KEY"
                                value = "loadtest-sync-probe-01"
                            }
                        )
                        securityContext = [ordered]@{
                            runAsNonRoot = $true
                            runAsUser = 12345
                            runAsGroup = 12345
                            allowPrivilegeEscalation = $false
                            readOnlyRootFilesystem = $true
                            capabilities = [ordered]@{
                                drop = @("ALL")
                            }
                            seccompProfile = [ordered]@{
                                type = "RuntimeDefault"
                            }
                        }
                        resources = [ordered]@{
                            requests = [ordered]@{
                                cpu = "20m"
                                memory = "64Mi"
                            }
                            limits = [ordered]@{
                                cpu = "250m"
                                memory = "256Mi"
                            }
                        }
                        volumeMounts = @(
                            [ordered]@{
                                name = "script"
                                mountPath = "/sentinel"
                                readOnly = $true
                            }
                        )
                    }
                )
                volumes = @(
                    [ordered]@{
                        name = "script"
                        configMap = [ordered]@{
                            name = $configMapName
                            items = @(
                                [ordered]@{
                                    key = "els-sentinel.js"
                                    path = "els-sentinel.js"
                                },
                                [ordered]@{
                                    key = "connection-token.js"
                                    path = "lib/connection-token.js"
                                },
                                [ordered]@{
                                    key = "probe.js"
                                    path = "lib/probe.js"
                                },
                                [ordered]@{
                                    key = "sentinel.js"
                                    path = "lib/sentinel.js"
                                }
                            )
                        }
                    }
                )
            }
        }
    }
}

$cleanupRequired = $true
try {
    foreach ($object in @($configMap, $daemonSet)) {
        $object |
            ConvertTo-Json -Depth 40 |
            & kubectl --context $targetContext apply -f -
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create $($object.kind) '$($object.metadata.name)'."
        }
    }

    & kubectl --context $targetContext `
        -n $namespace `
        rollout status "daemonset/$daemonSetName" `
        --timeout=5m
    if ($LASTEXITCODE -ne 0) {
        throw "The ELS sentinel DaemonSet did not become ready."
    }

    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        $sentinelPods = @(
            (
                Invoke-KubectlJson `
                    -Arguments @(
                        "--context", $targetContext,
                        "-n", $namespace,
                        "get", "pods",
                        "-l", "app.kubernetes.io/name=$daemonSetName",
                        "-o", "json"
                    ) `
                    -FailureMessage "Failed to inspect sentinel Pods."
            ).items |
                Sort-Object { $_.metadata.name }
        )
        if ($sentinelPods.Count -ne $ExpectedLoadgenNodes) {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw (
                    "Expected $ExpectedLoadgenNodes sentinel Pods; found " +
                    "$($sentinelPods.Count)."
                )
            }
            Start-Sleep -Seconds 2
            continue
        }

        $allReady = $true
        foreach ($pod in $sentinelPods) {
            $podName = [string]$pod.metadata.name
            $nodeName = [string]$pod.spec.nodeName
            $logText = (
                & kubectl --context $targetContext `
                    -n $namespace `
                    logs $podName |
                    Out-String
            )
            if ($LASTEXITCODE -ne 0) {
                $allReady = $false
                break
            }

            $identities = [Collections.Generic.HashSet[string]]::new()
            $expression = [regex]::new(
                "SENTINEL_READY\|1\|(?<run>[^|]+)\|(?<node>[^|]+)\|" +
                "(?<pod>[^|]+)\|(?<els>[^|]+)\|(?<ip>[^|]+)\|" +
                "(?<connection>\d+)\|(?<at>\d+)"
            )
            foreach ($match in $expression.Matches($logText)) {
                if (
                    $match.Groups["run"].Value -cne $RunId -or
                    $match.Groups["node"].Value -cne $nodeName -or
                    $match.Groups["pod"].Value -cne $podName
                ) {
                    throw "Sentinel '$podName' emitted an identity mismatch."
                }
                $null = $identities.Add(
                    "$($match.Groups["els"].Value)|$($match.Groups["connection"].Value)"
                )
            }
            if ($identities.Count -ne ($ExpectedElsPods * $ConnectionsPerTarget)) {
                $allReady = $false
                break
            }
        }

        if ($allReady) {
            break
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Not every sentinel connection completed initial synchronization."
        }
        Start-Sleep -Seconds 2
    } while ($true)

    $observedNodes = @($sentinelPods.spec.nodeName | Sort-Object -Unique)
    if ($observedNodes.Count -ne $ExpectedLoadgenNodes) {
        throw (
            "Expected one sentinel Pod per loadgen node; found " +
            "$($sentinelPods.Count) Pods on $($observedNodes.Count) nodes."
        )
    }

    $cleanupRequired = $false
    [pscustomobject]@{
        RunId = $RunId
        DaemonSet = $daemonSetName
        SentinelPods = $sentinelPods.Count
        LoadgenNodes = $observedNodes
        ElsPods = $targets
        ConnectionsPerTarget = $ConnectionsPerTarget
        ConnectionsPerLoadgenNode = $ExpectedElsPods * $ConnectionsPerTarget
        TotalDiagnosticConnections = (
            $ExpectedLoadgenNodes *
            $ExpectedElsPods *
            $ConnectionsPerTarget
        )
    }
}
finally {
    if ($cleanupRequired) {
        & kubectl --context $targetContext `
            -n $namespace `
            delete daemonset $daemonSetName `
            --ignore-not-found=true `
            --wait=false *> $null
        & kubectl --context $targetContext `
            -n $namespace `
            delete configmap $configMapName `
            --ignore-not-found=true `
            --wait=false *> $null
    }
}
