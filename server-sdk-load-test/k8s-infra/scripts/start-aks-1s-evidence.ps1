[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [ValidateLength(1, 63)]
    [string] $RunId,

    [Parameter(Mandatory)]
    [string] $KubeContext,

    [ValidateRange(1, 100)]
    [int] $ExpectedElsPods = 6,

    [ValidateRange(1, 100)]
    [int] $ExpectedElsNodes = 6,

    [ValidateRange(1, 100)]
    [int] $ExpectedFeatBitNodes = 6,

    [ValidateRange(1, 100)]
    [int] $ExpectedLoadgenNodes = 10,

    [ValidatePattern("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")]
    [ValidateLength(1, 63)]
    [string] $CollectorName = "featbit-1s-evidence",

    [ValidatePattern("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")]
    [string] $FeatBitWorkload = "featbit",

    [ValidatePattern("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")]
    [string] $LoadgenWorkload = "loadgen",

    [switch] $PreserveOnFailure
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Invoke-KubectlJson {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter(Mandatory)]
        [string] $FailureMessage
    )

    $text = (& kubectl @Arguments | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        throw $FailureMessage
    }

    return $text | ConvertFrom-Json
}

function Test-PodReady {
    param([Parameter(Mandatory)][object] $Pod)

    if ($Pod.status.phase -ne "Running") {
        return $false
    }

    $statuses = @($Pod.status.containerStatuses)
    return (
        $statuses.Count -gt 0 -and
        @($statuses | Where-Object ready).Count -eq $statuses.Count
    )
}

$targetContext = $KubeContext.Trim()
Assert-KubernetesContext -KubeContext $targetContext

& kubectl --context $targetContext `
    -n $script:LoadTestNamespace `
    get daemonset $CollectorName -o name *> $null
if ($LASTEXITCODE -eq 0) {
    throw (
        "DaemonSet $CollectorName already exists. " +
        "Stop its current run before starting '$RunId'."
    )
}

Assert-KubernetesObjectExists `
    -Kind "persistentvolumeclaim" `
    -Name "featbit-k6-results" `
    -KubeContext $targetContext

$nodes = Invoke-KubectlJson `
    -Arguments @("--context", $targetContext, "get", "nodes", "-o", "json") `
    -FailureMessage "Failed to read AKS nodes."
$readyNodes = @($nodes.items | Where-Object {
    ($_.status.conditions | Where-Object type -eq "Ready").status -eq "True"
})
$featbitNodes = @($readyNodes | Where-Object {
    $_.metadata.labels.workload -eq $FeatBitWorkload
})
$loadgenNodes = @($readyNodes | Where-Object {
    $_.metadata.labels.workload -eq $LoadgenWorkload
})
if ($featbitNodes.Count -ne $ExpectedFeatBitNodes) {
    throw (
        "Expected $ExpectedFeatBitNodes ready FeatBit nodes; " +
        "found $($featbitNodes.Count)."
    )
}
if ($loadgenNodes.Count -ne $ExpectedLoadgenNodes) {
    throw (
        "Expected $ExpectedLoadgenNodes ready loadgen nodes; " +
        "found $($loadgenNodes.Count)."
    )
}

$els = Invoke-KubectlJson `
    -Arguments @(
        "--context", $targetContext,
        "-n", "featbit",
        "get", "pods",
        "-l", "app.kubernetes.io/component=els",
        "-o", "json"
    ) `
    -FailureMessage "Failed to read ELS Pods."
$elsPods = @($els.items)
$readyElsPods = @($elsPods | Where-Object { Test-PodReady -Pod $_ })
if (
    $elsPods.Count -ne $ExpectedElsPods -or
    $readyElsPods.Count -ne $ExpectedElsPods
) {
    throw (
        "Expected $ExpectedElsPods ready ELS Pods; found " +
        "$($readyElsPods.Count) ready of $($elsPods.Count) total."
    )
}

$elsNodes = @($readyElsPods.spec.nodeName | Sort-Object -Unique)
if ($elsNodes.Count -ne $ExpectedElsNodes) {
    throw (
        "Expected $ExpectedElsPods ELS Pods on $ExpectedElsNodes node(s); " +
        "found $ExpectedElsPods Pods on $($elsNodes.Count) nodes."
    )
}

$elsMap = [Collections.Generic.List[string]]::new()
foreach ($pod in $readyElsPods) {
    $podName = [string]$pod.metadata.name
    $nodeName = [string]$pod.spec.nodeName
    $containerStatuses = @(
        $pod.status.containerStatuses |
            Where-Object name -eq "featbit-els"
    )
    if ($containerStatuses.Count -ne 1) {
        throw (
            "Expected one featbit-els container status for Pod '$podName'; " +
            "found $($containerStatuses.Count)."
        )
    }
    $containerId = [string]$containerStatuses[0].containerID
    if ($containerId -notmatch "^containerd://([0-9a-f]{64})$") {
        throw (
            "Expected a containerd container ID for ELS Pod '$podName'; " +
            "found '$containerId'."
        )
    }
    $elsMap.Add("$nodeName|$podName|$($Matches[1])")
}

$collectorPath = Join-Path $PSScriptRoot "collect-aks-node-evidence.sh"
if (-not (Test-Path -LiteralPath $collectorPath -PathType Leaf)) {
    throw "Collector script was not found: $collectorPath"
}
$collectorScript = Get-Content -Raw -LiteralPath $collectorPath

$commonLabels = [ordered]@{
    "app.kubernetes.io/name" = $CollectorName
    "app.kubernetes.io/part-of" = "featbit-load-testing"
    "loadtest.featbit.io/run-id" = $RunId
}
$configMap = [ordered]@{
    apiVersion = "v1"
    kind = "ConfigMap"
    metadata = [ordered]@{
        name = $CollectorName
        namespace = $script:LoadTestNamespace
        labels = $commonLabels
    }
    data = [ordered]@{
        "collect-aks-node-evidence.sh" = $collectorScript
        "els-map" = (($elsMap | Sort-Object) -join "`n") + "`n"
    }
}
$daemonSet = [ordered]@{
    apiVersion = "apps/v1"
    kind = "DaemonSet"
    metadata = [ordered]@{
        name = $CollectorName
        namespace = $script:LoadTestNamespace
        labels = $commonLabels
    }
    spec = [ordered]@{
        selector = [ordered]@{
            matchLabels = [ordered]@{
                "app.kubernetes.io/name" = $CollectorName
            }
        }
        template = [ordered]@{
            metadata = [ordered]@{
                labels = $commonLabels
            }
            spec = [ordered]@{
                terminationGracePeriodSeconds = 30
                hostNetwork = $true
                hostPID = $true
                affinity = [ordered]@{
                    nodeAffinity = [ordered]@{
                        requiredDuringSchedulingIgnoredDuringExecution = [ordered]@{
                            nodeSelectorTerms = @(
                                [ordered]@{
                                    matchExpressions = @(
                                        [ordered]@{
                                            key = "workload"
                                            operator = "In"
                                            values = @(
                                                $FeatBitWorkload,
                                                $LoadgenWorkload
                                            )
                                        }
                                    )
                                }
                            )
                        }
                    }
                }
                tolerations = @(
                    [ordered]@{
                        key = "workload"
                        operator = "Equal"
                        value = $FeatBitWorkload
                        effect = "NoSchedule"
                    },
                    [ordered]@{
                        key = "workload"
                        operator = "Equal"
                        value = $LoadgenWorkload
                        effect = "NoSchedule"
                    }
                )
                containers = @(
                    [ordered]@{
                        name = "collector"
                        image = "busybox:1.36.1"
                        imagePullPolicy = "IfNotPresent"
                        command = @(
                            "/bin/sh",
                            "/config/collect-aks-node-evidence.sh"
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
                            }
                        )
                        securityContext = [ordered]@{
                            privileged = $true
                            runAsUser = 0
                            runAsGroup = 0
                            readOnlyRootFilesystem = $true
                            allowPrivilegeEscalation = $true
                        }
                        resources = [ordered]@{
                            requests = [ordered]@{
                                cpu = "10m"
                                memory = "16Mi"
                            }
                            limits = [ordered]@{
                                cpu = "500m"
                                memory = "64Mi"
                            }
                        }
                        volumeMounts = @(
                            [ordered]@{
                                name = "host-proc"
                                mountPath = "/host/proc"
                                readOnly = $true
                            },
                            [ordered]@{
                                name = "host-sys"
                                mountPath = "/host/sys"
                                readOnly = $true
                            },
                            [ordered]@{
                                name = "config"
                                mountPath = "/config"
                                readOnly = $true
                            },
                            [ordered]@{
                                name = "results"
                                mountPath = "/results"
                            },
                            [ordered]@{
                                name = "buffer"
                                mountPath = "/buffer"
                            }
                        )
                    }
                )
                volumes = @(
                    [ordered]@{
                        name = "host-proc"
                        hostPath = [ordered]@{
                            path = "/proc"
                            type = "Directory"
                        }
                    },
                    [ordered]@{
                        name = "host-sys"
                        hostPath = [ordered]@{
                            path = "/sys"
                            type = "Directory"
                        }
                    },
                    [ordered]@{
                        name = "config"
                        configMap = [ordered]@{
                            name = $CollectorName
                            defaultMode = 365
                        }
                    },
                    [ordered]@{
                        name = "results"
                        persistentVolumeClaim = [ordered]@{
                            claimName = "featbit-k6-results"
                        }
                    },
                    [ordered]@{
                        name = "buffer"
                        emptyDir = [ordered]@{}
                    }
                )
            }
        }
    }
}
$resourceList = [ordered]@{
    apiVersion = "v1"
    kind = "List"
    items = @($configMap, $daemonSet)
}

$cleanupRequired = $true
try {
    $resourceJson = $resourceList | ConvertTo-Json -Depth 30
    $resourceJson | & kubectl --context $targetContext apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the 1-second AKS evidence collector."
    }

    & kubectl --context $targetContext `
        -n $script:LoadTestNamespace `
        rollout status "daemonset/$CollectorName" `
        --timeout=5m
    if ($LASTEXITCODE -ne 0) {
        throw "The 1-second AKS evidence DaemonSet did not become ready."
    }

    $status = Invoke-KubectlJson `
        -Arguments @(
            "--context", $targetContext,
            "-n", $script:LoadTestNamespace,
            "get", "daemonset", $CollectorName,
            "-o", "json"
        ) `
        -FailureMessage "Failed to read the evidence DaemonSet status."
    $expectedCollectors = $ExpectedFeatBitNodes + $ExpectedLoadgenNodes
    if (
        [int]$status.status.desiredNumberScheduled -ne $expectedCollectors -or
        [int]$status.status.numberReady -ne $expectedCollectors
    ) {
        throw (
            "Expected $expectedCollectors ready collectors; desired=" +
            "$($status.status.desiredNumberScheduled), " +
            "ready=$($status.status.numberReady)."
        )
    }

    $mappingValidated = $false
    $mappedElsPods = -1
    $mappingFiles = @(
        $featbitNodes |
            ForEach-Object {
                $nodeToken = (
                    [string]$_.metadata.name
                ) -replace "[^A-Za-z0-9._-]", "_"
                "/results/$RunId-node-$nodeToken-metadata.txt"
            }
    )
    $mappingCommand = (
        "grep -h '^els_pod_count=' " +
        ($mappingFiles -join " ") +
        " 2>/dev/null || true"
    )
    for ($attempt = 1; $attempt -le 30; $attempt += 1) {
        $mappingOutput = (
            & kubectl --request-timeout=30s `
                --context $targetContext `
                -n $script:LoadTestNamespace `
                exec results-reader -- `
                sh -c $mappingCommand |
                Out-String
        )
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to validate the ELS cgroup mapping evidence."
        }
        $mappingCounts = @(
            $mappingOutput -split "\r?\n" |
                Where-Object { $_ -match "^els_pod_count=(\d+)$" } |
                ForEach-Object { [int]$Matches[1] }
        )
        if ($mappingCounts.Count -eq $ExpectedFeatBitNodes) {
            $mappedElsPods = [int](
                $mappingCounts |
                    Measure-Object -Sum |
                    Select-Object -ExpandProperty Sum
            )
            if ($mappedElsPods -eq $ExpectedElsPods) {
                $mappingValidated = $true
                break
            }
        }
        Start-Sleep -Seconds 1
    }
    if (-not $mappingValidated) {
        throw (
            "Expected one-second evidence mappings for $ExpectedElsPods ELS " +
            "Pod(s) across $ExpectedFeatBitNodes FeatBit collectors; found " +
            "$mappedElsPods mapped ELS Pod(s)."
        )
    }

    $cleanupRequired = $false
    [pscustomobject]@{
        RunId = $RunId
        CollectorName = $CollectorName
        CollectorPods = [int]$status.status.numberReady
        FeatBitNodes = $featbitNodes.Count
        FeatBitWorkload = $FeatBitWorkload
        LoadgenNodes = $loadgenNodes.Count
        LoadgenWorkload = $LoadgenWorkload
        ElsPods = $readyElsPods.Count
        ElsNodes = $elsNodes.Count
        MappedElsPods = $mappedElsPods
        SampleIntervalSeconds = 1
    }
}
finally {
    if ($cleanupRequired -and -not $PreserveOnFailure) {
        & kubectl --context $targetContext `
            -n $script:LoadTestNamespace `
            delete daemonset $CollectorName `
            --ignore-not-found=true `
            --wait=false *> $null
        & kubectl --context $targetContext `
            -n $script:LoadTestNamespace `
            delete configmap $CollectorName `
            --ignore-not-found=true *> $null
    }
}
