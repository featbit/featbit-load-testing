[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^(smoke|baseline-plus|baseline|growth-plus|growth)-[a-z0-9-]+$")]
    [ValidateLength(1, 63)]
    [string] $RunId,

    [Parameter(Mandatory)]
    [string] $KubeContext,

    [ValidateRange(1, 100)]
    [int] $ExpectedLoadgenNodes = 10
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$targetContext = $KubeContext.Trim()
$namespace = "featbit"
$daemonSetName = "featbit-stream-timing"
$redisImage = "docker.io/bitnamilegacy/redis:7.2.4-debian-11-r5"

Assert-KubernetesContext -KubeContext $targetContext

& kubectl --context $targetContext `
    -n $namespace `
    get daemonset $daemonSetName -o name *> $null
if ($LASTEXITCODE -eq 0) {
    throw (
        "DaemonSet '$daemonSetName' already exists. Stop its current run " +
        "before starting '$RunId'."
    )
}

foreach ($object in @(
    @{ Kind = "secret"; Name = "featbit-redis-auth" },
    @{ Kind = "service"; Name = "featbit-featbit-redis-master" }
)) {
    & kubectl --context $targetContext `
        -n $namespace `
        get $object.Kind $object.Name -o name *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Required $($object.Kind) '$($object.Name)' does not exist."
    }
}

$nodeText = (
    & kubectl --context $targetContext `
        get nodes `
        -l workload=loadgen `
        -o json |
        Out-String
)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($nodeText)) {
    throw "Failed to inspect loadgen nodes."
}
$nodes = ($nodeText | ConvertFrom-Json).items
$readyNodes = @($nodes | Where-Object {
    ($_.status.conditions | Where-Object type -eq "Ready").status -eq "True"
})
if ($readyNodes.Count -ne $ExpectedLoadgenNodes) {
    throw (
        "Expected $ExpectedLoadgenNodes ready loadgen nodes; " +
        "found $($readyNodes.Count)."
    )
}

$observerScript = @'
set -euo pipefail
export REDISCLI_AUTH="${REDIS_PASSWORD}"
export REDISCLI_HISTFILE=/dev/null

while true; do
  redis-cli \
    -h "${REDIS_HOST}" \
    -p "${REDIS_PORT}" \
    --raw \
    SUBSCRIBE "${REDIS_CHANNEL}" |
  while IFS= read -r kind && IFS= read -r channel && IFS= read -r payload; do
    if [[ "${kind}" == "subscribe" ]]; then
      printf 'STREAM_OBSERVER_READY|1|%s|%s\n' "${NODE_NAME}" "$(date +%s%3N)"
      continue
    fi
    if [[ "${kind}" != "message" ]]; then
      continue
    fi

    observed_at_ms="$(date +%s%3N)"
    encoded_payload="$(printf '%s' "${payload}" | base64 | tr -d '\n')"
    printf 'STREAM_TIMING|1|%s|%s|%s\n' \
      "${NODE_NAME}" \
      "${observed_at_ms}" \
      "${encoded_payload}"
  done
  sleep 1
done
'@

$labels = [ordered]@{
    "app.kubernetes.io/name" = $daemonSetName
    "app.kubernetes.io/part-of" = "featbit-load-testing"
    "loadtest.featbit.io/run-id" = $RunId
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
                terminationGracePeriodSeconds = 10
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
                        name = "observer"
                        image = $redisImage
                        imagePullPolicy = "IfNotPresent"
                        command = @("/bin/bash", "-c", $observerScript)
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
                                name = "REDIS_HOST"
                                value = "featbit-featbit-redis-master"
                            },
                            [ordered]@{
                                name = "REDIS_PORT"
                                value = "6379"
                            },
                            [ordered]@{
                                name = "REDIS_CHANNEL"
                                value = "featbit-feature-flag-change"
                            },
                            [ordered]@{
                                name = "REDIS_PASSWORD"
                                valueFrom = [ordered]@{
                                    secretKeyRef = [ordered]@{
                                        name = "featbit-redis-auth"
                                        key = "redis-password"
                                    }
                                }
                            }
                        )
                        securityContext = [ordered]@{
                            runAsNonRoot = $true
                            runAsUser = 1001
                            runAsGroup = 1001
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
                                cpu = "5m"
                                memory = "16Mi"
                            }
                            limits = [ordered]@{
                                cpu = "100m"
                                memory = "64Mi"
                            }
                        }
                    }
                )
            }
        }
    }
}

$cleanupRequired = $true
try {
    $daemonSet |
        ConvertTo-Json -Depth 30 |
        & kubectl --context $targetContext apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the streaming timing observer."
    }

    & kubectl --context $targetContext `
        -n $namespace `
        rollout status "daemonset/$daemonSetName" `
        --timeout=5m
    if ($LASTEXITCODE -ne 0) {
        throw "The streaming timing observer did not become ready."
    }

    $podsText = (
        & kubectl --context $targetContext `
            -n $namespace `
            get pods `
            -l "app.kubernetes.io/name=$daemonSetName" `
            -o json |
            Out-String
    )
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($podsText)) {
        throw "Failed to inspect streaming timing observer Pods."
    }
    $pods = ($podsText | ConvertFrom-Json).items
    if ($pods.Count -ne $ExpectedLoadgenNodes) {
        throw (
            "Expected $ExpectedLoadgenNodes observer Pods; " +
            "found $($pods.Count)."
        )
    }
    $observedNodes = @($pods.spec.nodeName | Sort-Object -Unique)
    if ($observedNodes.Count -ne $ExpectedLoadgenNodes) {
        throw (
            "Expected one observer per loadgen node; found " +
            "$($pods.Count) Pods on $($observedNodes.Count) nodes."
        )
    }

    Start-Sleep -Seconds 2
    foreach ($pod in $pods) {
        $logText = (
            & kubectl --context $targetContext `
                -n $namespace `
                logs $pod.metadata.name `
                --tail=20 |
                Out-String
        )
        if (
            $LASTEXITCODE -ne 0 -or
            $logText -notmatch "STREAM_OBSERVER_READY\|1\|"
        ) {
            throw (
                "Observer '$($pod.metadata.name)' did not confirm its Redis " +
                "subscription."
            )
        }
    }

    $cleanupRequired = $false
    [pscustomobject]@{
        RunId = $RunId
        DaemonSet = $daemonSetName
        ObserverPods = $pods.Count
        ObservedNodes = $observedNodes
        RedisChannel = "featbit-feature-flag-change"
        Boundary = "Earliest Redis publication observation across loadgen nodes"
    }
}
finally {
    if ($cleanupRequired) {
        & kubectl --context $targetContext `
            -n $namespace `
            delete daemonset $daemonSetName `
            --ignore-not-found=true `
            --wait=false *> $null
    }
}
