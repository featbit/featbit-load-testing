using System.Collections.Concurrent;
using System.Diagnostics;
using FeatBit.Sdk.Server;
using FeatBit.Sdk.Server.Model;

namespace FeatBit.ServerSdk.LoadTest;

public sealed class LoadTestRunner
{
    private const string MissingVariation = "__featbit_loadtest_missing__";

    private readonly RunnerOptions _options;
    private readonly EnvironmentCredential _credential;
    private readonly RevisionPlan _revisionPlan;
    private readonly JsonEventWriter _events;
    private readonly ConcurrentDictionary<int, ClientState> _clients = new();
    private readonly ConcurrentDictionary<string, int> _observationCounts =
        new(StringComparer.Ordinal);
    private int _readyCount;
    private int _creationFailures;
    private int _unexpectedValues;
    private int _canaryFlagCountFailures;
    private int _readyTimeoutEmitted;

    public LoadTestRunner(
        RunnerOptions options,
        EnvironmentCredential credential,
        RevisionPlan revisionPlan,
        JsonEventWriter events)
    {
        _options = options;
        _credential = credential;
        _revisionPlan = revisionPlan;
        _events = events;
    }

    public async Task<int> RunAsync(CancellationToken cancellationToken)
    {
        File.WriteAllText(
            "/tmp/featbit-dotnet-runner-ready",
            "ready",
            System.Text.Encoding.ASCII);

        _events.Emit(
            "runner_started",
            new Dictionary<string, object?>
            {
                ["runnerIndexZeroBased"] = _options.RunnerIndex,
                ["parallelism"] = _options.Parallelism,
                ["clientsPerRunner"] = _options.ClientsPerRunner,
                ["totalConnections"] = _options.TotalConnections,
                ["connectionsPerSecond"] = _options.ConnectionsPerSecond,
                ["startAtUnixMs"] = _options.StartAtUnixMs,
                ["pollIntervalMs"] = _options.PollIntervalMs,
                ["sdkPackageVersion"] = typeof(FbClient).Assembly
                    .GetName()
                    .Version?
                    .ToString(),
                ["environmentId"] = _options.EnvironmentId,
                ["environmentKey"] = _options.TargetEnvironmentKey,
                ["expectedFlagCount"] = _options.ExpectedFlagCount,
            });

        var now = Clock.UnixMilliseconds();
        if (_options.StartAtUnixMs <= now)
        {
            _events.Emit(
                "start_gate_late",
                new Dictionary<string, object?>
                {
                    ["lateByMs"] = now - _options.StartAtUnixMs,
                });
        }
        else
        {
            _events.Emit(
                "waiting_for_start",
                new Dictionary<string, object?>
                {
                    ["waitMs"] = _options.StartAtUnixMs - now,
                });
            await Task.Delay(
                TimeSpan.FromMilliseconds(_options.StartAtUnixMs - now),
                cancellationToken);
        }

        using var backgroundCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var monitorTask = MonitorClientsAsync(backgroundCancellation.Token);
        var resourceTask = SampleResourcesAsync(backgroundCancellation.Token);
        var creationTasks = Enumerable
            .Range(1, _options.ClientsPerRunner)
            .Select(ScheduleClientCreationAsync)
            .ToArray();

        await Task.WhenAll(creationTasks);
        _events.Emit(
            "connection_creation_complete",
            new Dictionary<string, object?>
            {
                ["constructed"] = _clients.Count,
                ["creationFailures"] = Volatile.Read(ref _creationFailures),
            });

        var stopAtUnixMs =
            _options.StartAtUnixMs + (_options.RunDurationSeconds * 1000L);
        while (!cancellationToken.IsCancellationRequested &&
               Clock.UnixMilliseconds() < stopAtUnixMs &&
               !File.Exists(_options.StopFile))
        {
            await Task.Delay(100, cancellationToken);
        }

        _events.Emit(
            File.Exists(_options.StopFile) ? "external_stop_observed" : "run_window_ended");
        backgroundCancellation.Cancel();
        await IgnoreCancellation(monitorTask);
        await IgnoreCancellation(resourceTask);

        await CloseClientsAsync();

        var summary = new
        {
            schemaVersion = 1,
            runId = _options.RunId,
            runner = _options.RunnerIndex + 1,
            generatedAtUnixMs = Clock.UnixMilliseconds(),
            topology = new
            {
                _options.Parallelism,
                _options.ClientsPerRunner,
                _options.TotalConnections,
                _options.ConnectionsPerSecond,
                scheduledRampSpanMs =
                    ((_options.TotalConnections - 1) * 1000L) /
                    _options.ConnectionsPerSecond,
                configuredRampDurationMs =
                    (long)Math.Ceiling(
                        _options.TotalConnections /
                        (double)_options.ConnectionsPerSecond) *
                    1000L,
            },
            measurement = new
            {
                _options.PollIntervalMs,
                initializationBoundary =
                    "client construction start -> first public Initialized=true observation",
                propagationBoundary =
                    "controller/Redis timestamps -> first public StringVariation observation",
                propagationQuantizationMs = _options.PollIntervalMs,
            },
            counts = new
            {
                scheduled = _options.ClientsPerRunner,
                constructed = _clients.Count,
                ready = Volatile.Read(ref _readyCount),
                creationFailures = Volatile.Read(ref _creationFailures),
                unexpectedValues = Volatile.Read(ref _unexpectedValues),
                canaryFlagCountFailures =
                    Volatile.Read(ref _canaryFlagCountFailures),
            },
            observations = _observationCounts
                .OrderBy(pair => pair.Key, StringComparer.Ordinal)
                .ToDictionary(pair => pair.Key, pair => pair.Value),
            passedInitialization =
                _clients.Count == _options.ClientsPerRunner &&
                Volatile.Read(ref _readyCount) == _options.ClientsPerRunner &&
                Volatile.Read(ref _creationFailures) == 0 &&
                Volatile.Read(ref _canaryFlagCountFailures) == 0,
        };
        _events.WriteSummary(summary);
        _events.Emit(
            "runner_finished",
            new Dictionary<string, object?>
            {
                ["constructed"] = _clients.Count,
                ["ready"] = Volatile.Read(ref _readyCount),
                ["creationFailures"] = Volatile.Read(ref _creationFailures),
                ["unexpectedValues"] = Volatile.Read(ref _unexpectedValues),
                ["canaryFlagCountFailures"] =
                    Volatile.Read(ref _canaryFlagCountFailures),
            });

        return summary.passedInitialization ? 0 : 1;
    }

    private async Task ScheduleClientCreationAsync(int localConnection)
    {
        var scheduledAt = _options.ScheduledAtUnixMs(localConnection);
        var delay = scheduledAt - Clock.UnixMilliseconds();
        if (delay > 0)
        {
            await Task.Delay(TimeSpan.FromMilliseconds(delay));
        }

        await Task.Factory.StartNew(
            () => CreateClient(localConnection, scheduledAt),
            CancellationToken.None,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default);
    }

    private void CreateClient(int localConnection, long scheduledAtUnixMs)
    {
        var createStartedAt = Clock.UnixMilliseconds();
        var globalConnection =
            _options.GlobalConnectionIndex(localConnection);
        _events.Emit(
            "client_create_started",
            new Dictionary<string, object?>
            {
                ["localConnection"] = localConnection,
                ["globalConnection"] = globalConnection,
                ["scheduledAtUnixMs"] = scheduledAtUnixMs,
                ["scheduleDriftMs"] = createStartedAt - scheduledAtUnixMs,
                ["environmentId"] = _options.EnvironmentId,
            },
            createStartedAt);

        try
        {
            var sdkOptions = SdkOptionsFactory.Create(
                _options,
                _credential.ServerSecret);
            var client = new FbClient(sdkOptions);
            var constructorReturnedAt = Clock.UnixMilliseconds();
            var user = FbUser
                .Builder(
                    $"{_options.RunId}-r{_options.RunnerIndex + 1:D2}" +
                    $"-c{localConnection:D3}")
                .Build();
            var state = new ClientState
            {
                LocalConnection = localConnection,
                GlobalConnection = globalConnection,
                ScheduledAtUnixMs = scheduledAtUnixMs,
                CreateStartedAtUnixMs = createStartedAt,
                ConstructorReturnedAtUnixMs = constructorReturnedAt,
                Client = client,
                User = user,
                LastStatus = client.Status,
            };
            if (!_clients.TryAdd(localConnection, state))
            {
                throw new InvalidOperationException(
                    "Duplicate local connection index.");
            }

            _events.Emit(
                "client_constructor_returned",
                new Dictionary<string, object?>
                {
                    ["localConnection"] = localConnection,
                    ["globalConnection"] = globalConnection,
                    ["durationMs"] = constructorReturnedAt - createStartedAt,
                    ["initialized"] = client.Initialized,
                    ["status"] = client.Status.ToString(),
                },
                constructorReturnedAt);

            if (client.Initialized)
            {
                MarkReady(state, constructorReturnedAt);
            }
        }
        catch (Exception exception)
        {
            Interlocked.Increment(ref _creationFailures);
            _events.Emit(
                "client_create_failed",
                new Dictionary<string, object?>
                {
                    ["localConnection"] = localConnection,
                    ["globalConnection"] = globalConnection,
                    ["errorType"] = exception.GetType().Name,
                    ["message"] = Sanitize(exception.Message),
                });
        }
    }

    private async Task MonitorClientsAsync(CancellationToken cancellationToken)
    {
        var readyDeadline =
            _options.StartAtUnixMs + (_options.ReadyTimeoutSeconds * 1000L);
        while (!cancellationToken.IsCancellationRequested)
        {
            var observedAt = Clock.UnixMilliseconds();
            foreach (var state in _clients.Values)
            {
                var status = state.Client.Status;
                if (status != state.LastStatus)
                {
                    _events.Emit(
                        "client_status_changed",
                        ClientIdentity(
                            state,
                            ("previousStatus", state.LastStatus.ToString()),
                            ("status", status.ToString())),
                        observedAt);
                    state.LastStatus = status;
                }

                if (!state.Ready && state.Client.Initialized)
                {
                    MarkReady(state, observedAt);
                }
                if (state.Ready)
                {
                    ObserveVariations(state, observedAt);
                }
            }

            if (observedAt >= readyDeadline &&
                Volatile.Read(ref _readyCount) != _options.ClientsPerRunner &&
                Interlocked.CompareExchange(
                    ref _readyTimeoutEmitted,
                    1,
                    0) == 0)
            {
                _events.Emit(
                    "ready_timeout",
                    new Dictionary<string, object?>
                    {
                        ["ready"] = Volatile.Read(ref _readyCount),
                        ["expected"] = _options.ClientsPerRunner,
                        ["timeoutSeconds"] = _options.ReadyTimeoutSeconds,
                    },
                    observedAt);
            }

            await Task.Delay(
                _options.PollIntervalMs,
                cancellationToken);
        }
    }

    private void MarkReady(ClientState state, long observedAtUnixMs)
    {
        if (!state.TryMarkReady())
        {
            return;
        }

        Interlocked.Increment(ref _readyCount);
        _events.Emit(
            "sdk_ready",
            ClientIdentity(
                state,
                ("scheduledAtUnixMs", state.ScheduledAtUnixMs),
                ("createStartedAtUnixMs", state.CreateStartedAtUnixMs),
                (
                    "constructorReturnedAtUnixMs",
                    state.ConstructorReturnedAtUnixMs
                ),
                (
                    "initializationLatencyMs",
                    observedAtUnixMs - state.CreateStartedAtUnixMs
                ),
                (
                    "readyScheduleDriftMs",
                    observedAtUnixMs - state.ScheduledAtUnixMs
                ),
                ("status", state.Client.Status.ToString()),
                ("environmentId", _options.EnvironmentId)),
            observedAtUnixMs);

        ObserveVariations(state, observedAtUnixMs);
        if (state.LocalConnection == 1)
        {
            _ = Task.Run(() => ValidateCanaryFlagCount(state));
        }
    }

    private void ValidateCanaryFlagCount(ClientState state)
    {
        try
        {
            var count = state.Client.GetAllVariations(state.User).Length;
            var matched = count == _options.ExpectedFlagCount;
            if (!matched)
            {
                Interlocked.Increment(ref _canaryFlagCountFailures);
            }

            _events.Emit(
                "canary_flag_count",
                ClientIdentity(
                    state,
                    ("count", count),
                    ("expected", _options.ExpectedFlagCount),
                    ("matched", matched)));
        }
        catch (Exception exception)
        {
            Interlocked.Increment(ref _canaryFlagCountFailures);
            _events.Emit(
                "canary_flag_count_failed",
                ClientIdentity(
                    state,
                    ("errorType", exception.GetType().Name),
                    ("message", Sanitize(exception.Message))));
        }
    }

    private void ObserveVariations(ClientState state, long observedAtUnixMs)
    {
        foreach (var step in _revisionPlan.Steps)
        {
            ObserveVariation(
                state,
                step.FlagKey,
                step.VariationType,
                step.Index,
                observedAtUnixMs);
        }

        ObserveVariation(
            state,
            _options.WarmupFlagKey,
            "string",
            revisionIndex: 0,
            observedAtUnixMs);
    }

    private void ObserveVariation(
        ClientState state,
        string flagKey,
        string variationType,
        int revisionIndex,
        long observedAtUnixMs)
    {
        var rawValue = state.Client.StringVariation(
            flagKey,
            state.User,
            MissingVariation);
        if (state.LastRawValues.TryGetValue(flagKey, out var previous) &&
            string.Equals(previous, rawValue, StringComparison.Ordinal))
        {
            return;
        }

        state.LastRawValues[flagKey] = rawValue;
        string revision;
        try
        {
            revision = RevisionPlan.ExtractRevision(rawValue, variationType);
        }
        catch (Exception exception)
        {
            Interlocked.Increment(ref _unexpectedValues);
            _events.Emit(
                "variation_observation_invalid",
                ClientIdentity(
                    state,
                    ("environmentId", _options.EnvironmentId),
                    ("flagKey", flagKey),
                    ("revisionIndex", revisionIndex),
                    ("variationType", variationType),
                    ("errorType", exception.GetType().Name),
                    ("message", Sanitize(exception.Message))),
                observedAtUnixMs);
            return;
        }

        var observationKey =
            $"{revisionIndex:D3}|{flagKey}|{revision}";
        _observationCounts.AddOrUpdate(
            observationKey,
            addValue: 1,
            updateValueFactory: static (_, count) => count + 1);
        _events.Emit(
            "variation_observed",
            ClientIdentity(
                state,
                ("environmentId", _options.EnvironmentId),
                ("flagKey", flagKey),
                ("revisionIndex", revisionIndex),
                ("revision", revision),
                ("variationType", variationType),
                ("pollIntervalMs", _options.PollIntervalMs)),
            observedAtUnixMs);
    }

    private async Task SampleResourcesAsync(CancellationToken cancellationToken)
    {
        using var process = Process.GetCurrentProcess();
        var previousAt = Stopwatch.GetTimestamp();
        var previousCpu = process.TotalProcessorTime;
        while (!cancellationToken.IsCancellationRequested)
        {
            await Task.Delay(
                _options.ResourceSampleIntervalMs,
                cancellationToken);
            process.Refresh();
            var currentAt = Stopwatch.GetTimestamp();
            var currentCpu = process.TotalProcessorTime;
            var elapsedSeconds =
                (currentAt - previousAt) / (double)Stopwatch.Frequency;
            var cpuCores =
                (currentCpu - previousCpu).TotalSeconds / elapsedSeconds;
            previousAt = currentAt;
            previousCpu = currentCpu;

            var gc = GC.GetGCMemoryInfo();
            ThreadPool.GetAvailableThreads(
                out var availableWorkerThreads,
                out var availableIoThreads);
            ThreadPool.GetMaxThreads(
                out var maximumWorkerThreads,
                out var maximumIoThreads);
            _events.Emit(
                "runtime_sample",
                new Dictionary<string, object?>
                {
                    ["cpuCores"] = Math.Round(cpuCores, 4),
                    ["workingSetBytes"] = process.WorkingSet64,
                    ["privateMemoryBytes"] = process.PrivateMemorySize64,
                    ["managedMemoryBytes"] = GC.GetTotalMemory(false),
                    ["gcHeapSizeBytes"] = gc.HeapSizeBytes,
                    ["gcFragmentedBytes"] = gc.FragmentedBytes,
                    ["gcTotalAvailableMemoryBytes"] =
                        gc.TotalAvailableMemoryBytes,
                    ["gen0Collections"] = GC.CollectionCount(0),
                    ["gen1Collections"] = GC.CollectionCount(1),
                    ["gen2Collections"] = GC.CollectionCount(2),
                    ["processThreads"] = process.Threads.Count,
                    ["threadPoolAvailableWorkerThreads"] =
                        availableWorkerThreads,
                    ["threadPoolMaximumWorkerThreads"] =
                        maximumWorkerThreads,
                    ["threadPoolAvailableIoThreads"] = availableIoThreads,
                    ["threadPoolMaximumIoThreads"] = maximumIoThreads,
                    ["threadPoolPendingWorkItems"] =
                        ThreadPool.PendingWorkItemCount,
                    ["constructed"] = _clients.Count,
                    ["ready"] = Volatile.Read(ref _readyCount),
                });
        }
    }

    private async Task CloseClientsAsync()
    {
        await Parallel.ForEachAsync(
            _clients.Values,
            new ParallelOptions { MaxDegreeOfParallelism = 8 },
            async (state, _) =>
            {
                try
                {
                    await state.Client.CloseAsync();
                }
                catch (Exception exception)
                {
                    _events.Emit(
                        "client_close_failed",
                        ClientIdentity(
                            state,
                            ("errorType", exception.GetType().Name),
                            ("message", Sanitize(exception.Message))));
                }
            });
    }

    private static Dictionary<string, object?> ClientIdentity(
        ClientState state,
        params (string Name, object? Value)[] fields)
    {
        var result = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["localConnection"] = state.LocalConnection,
            ["globalConnection"] = state.GlobalConnection,
        };
        foreach (var field in fields)
        {
            result[field.Name] = field.Value;
        }

        return result;
    }

    private string Sanitize(string value)
    {
        var normalized = value
            .Replace("\r", " ", StringComparison.Ordinal)
            .Replace("\n", " ", StringComparison.Ordinal)
            .Replace(
                _credential.ServerSecret,
                "<redacted>",
                StringComparison.Ordinal)
            .Trim();
        return normalized.Length <= 300 ? normalized : normalized[..300];
    }

    private static async Task IgnoreCancellation(Task task)
    {
        try
        {
            await task;
        }
        catch (OperationCanceledException)
        {
            // Expected during normal runner shutdown.
        }
    }
}
