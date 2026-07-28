# Official .NET Server SDK load generator

This directory contains an independent load generator built on the public
`FeatBit.ServerSdk` NuGet package. It does not replace or modify the k6
experiments, and it does not contain FeatBit Evaluation Server source code.

The first checked-in profile is a 500-client pilot for one Environment with
3,000 flags:

- 20 runner Pods × 25 independent `FbClient` instances;
- 20 new clients/s for 25 seconds;
- 2,500 string flags and 500 JSON flags with 2,048-byte variations;
- one warm-up flag changed and restored;
- eight string revisions followed by two JSON revisions.

The fixed matrix is
[`aks-single-environment-3k-flags-dotnet-sdk-p500-els-expanded.json`](../k8s-infra/matrices/aks-single-environment-3k-flags-dotnet-sdk-p500-els-expanded.json).
The earlier k6 files and matrices remain runnable.

## Measurement boundaries

Each SDK client is a real `FbClient` from `FeatBit.ServerSdk` 1.2.11.

| Measurement | Boundary |
| --- | --- |
| SDK initialization | client construction start → first public `Initialized=true` observation |
| End to end | controller PUT start → first public `StringVariation` observation |
| Control plane | controller PUT start → first matching Redis observer event |
| Probe sync | first matching Redis observer event → first public `StringVariation` observation |

The public SDK does not expose a WebSocket-open callback, so the runner does
not invent a separate connection-open timestamp. `StringVariation` is polled
every 10 ms; SDK-side propagation timestamps may therefore be 0–10 ms later
than the internal apply time.

One canary client per runner calls `GetAllVariations` after initialization and
must see exactly 3,000 flags. All clients must remain healthy and observe both
warm-up deliveries and all ten formal revisions.

## Connection scheduling

Runner indexes are interleaved globally. For one-based local client `c` and
one-based runner `r`:

```text
global client = (c - 1) × runner count + r
scheduled time = ramp start + floor((global client - 1) × 1000 / rate)
```

This produces exactly 500 unique clients at 20/s without allowing each Pod to
run its own independent 20/s ramp.

## Credentials and output

The Server SDK secret is read from a mounted Kubernetes Secret file. It is
never emitted to events, summaries, manifests, ConfigMaps, or reports.
Exception messages are sanitized before being written.

Each runner writes JSONL events and one JSON summary to the existing results
PVC. Events include the run ID, environment ID, flag key, revision, runner,
local client, and global client identities. The analyzer rejects duplicate,
missing, foreign, or out-of-sequence observations.

## Build and test

```powershell
dotnet test .\dotnet-sdk-runner\tests\FeatBit.ServerSdk.LoadTest.Tests\FeatBit.ServerSdk.LoadTest.Tests.csproj
npm test

.\k8s-infra\scripts\build-aks-dotnet-sdk-runner.ps1
```

The build script uses the test ACR and returns an immutable digest. Pass only
`registry/repository@sha256:...` references to render and run scripts.

## Render, run, and analyze

Run from `server-sdk-load-test/`:

```powershell
$context = "aks-featbit-load-testing"
$matrix = ".\k8s-infra\matrices\aks-single-environment-3k-flags-dotnet-sdk-p500-els-expanded.json"
$runnerImage = "<test-acr>/featbit-dotnet-sdk-loadtest@sha256:<digest>"
$controllerImage = "<test-acr>/featbit-k6@sha256:<digest>"

.\k8s-infra\scripts\render-aks-dotnet-sdk-pilot.ps1 `
  -RunKind validation `
  -KubeContext $context `
  -RunnerImage $runnerImage `
  -ControllerImage $controllerImage `
  -MatrixPath $matrix

.\k8s-infra\scripts\run-aks-dotnet-sdk-pilot.ps1 `
  -RunKind validation `
  -KubeContext $context `
  -RunnerImage $runnerImage `
  -ControllerImage $controllerImage `
  -MatrixPath $matrix
```

The executor retains the Job, controller, raw runner output, failed attempts,
one-second node evidence, ELS logs, and all derived reports. It restores the
eleven changed flags but does not delete AKS resources or historical results.

For an already collected run:

```powershell
.\k8s-infra\scripts\analyze-aks-dotnet-sdk-pilot.ps1 `
  -RunDirectory .\results\<run-id>

.\k8s-infra\scripts\analyze-aks-dotnet-node-evidence.ps1 `
  -RunDirectory .\results\<run-id>
```

The canonical full distribution is always retained. The optional
`probe_sync_latency_ms <= 100 ms` view is a secondary jitter diagnostic, not
an SLO or a PASS gate.

## Scope

This runner answers whether the official SDK can initialize and measure the
large flag set without the k6 JavaScript JSON receive/parse path. A successful
500-client pilot is not evidence that 10,000 clients fit the same resource
profile. Higher connection counts require a separate capacity ladder.
