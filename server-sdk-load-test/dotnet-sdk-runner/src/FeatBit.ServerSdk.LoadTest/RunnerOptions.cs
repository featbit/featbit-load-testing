using System.Globalization;
using System.Text.RegularExpressions;

namespace FeatBit.ServerSdk.LoadTest;

public sealed class RunnerOptions
{
    private static readonly Regex SafeRunId =
        new("^[a-z0-9][a-z0-9-]{0,62}$", RegexOptions.CultureInvariant);

    public required string RunId { get; init; }
    public required int RunnerIndex { get; init; }
    public required int Parallelism { get; init; }
    public required int ClientsPerRunner { get; init; }
    public required int TotalConnections { get; init; }
    public required int ConnectionsPerSecond { get; init; }
    public required long StartAtUnixMs { get; init; }
    public required Uri StreamingUri { get; init; }
    public required Uri EventUri { get; init; }
    public required string EnvironmentSecretPath { get; init; }
    public required string EnvironmentId { get; init; }
    public required string TargetEnvironmentKey { get; init; }
    public required string RevisionPlanJson { get; init; }
    public required string WarmupFlagKey { get; init; }
    public required string ResultsDirectory { get; init; }
    public required string StopFile { get; init; }
    public required int ExpectedFlagCount { get; init; }
    public required int ConnectTimeoutMs { get; init; }
    public required int StartWaitTimeMs { get; init; }
    public required int ReadyTimeoutSeconds { get; init; }
    public required int RunDurationSeconds { get; init; }
    public required int PollIntervalMs { get; init; }
    public required int ResourceSampleIntervalMs { get; init; }

    public int GlobalConnectionIndex(int localConnectionIndex)
    {
        if (localConnectionIndex < 1 || localConnectionIndex > ClientsPerRunner)
        {
            throw new ArgumentOutOfRangeException(
                nameof(localConnectionIndex),
                $"Local connection index must be in [1, {ClientsPerRunner}].");
        }

        return ((localConnectionIndex - 1) * Parallelism) + RunnerIndex + 1;
    }

    public long ScheduledAtUnixMs(int localConnectionIndex)
    {
        var globalZeroBased = GlobalConnectionIndex(localConnectionIndex) - 1;
        return StartAtUnixMs + ((globalZeroBased * 1000L) / ConnectionsPerSecond);
    }

    public static RunnerOptions FromEnvironment()
    {
        return FromValues(
            key => Environment.GetEnvironmentVariable(key));
    }

    public static RunnerOptions FromValues(Func<string, string?> read)
    {
        ArgumentNullException.ThrowIfNull(read);

        var runId = Required(read, "RUN_ID");
        if (!SafeRunId.IsMatch(runId))
        {
            throw new InvalidOperationException(
                "RUN_ID must contain only lowercase letters, digits, and hyphens.");
        }

        var runnerIndex = Integer(read, "RUNNER_INDEX", 0, 10_000);
        var parallelism = Integer(read, "LOADTEST_PARALLELISM", 1, 10_000);
        var clientsPerRunner = Integer(read, "CLIENTS_PER_RUNNER", 1, 100_000);
        var totalConnections = Integer(read, "TOTAL_CONNECTIONS", 1, 1_000_000);
        var connectionsPerSecond =
            Integer(read, "CONNECTIONS_PER_SECOND", 1, 1_000_000);
        var connectTimeoutMs = Integer(read, "CONNECT_TIMEOUT_MS", 100, 300_000);
        var startWaitTimeMs =
            Integer(read, "START_WAIT_TIME_MS", 101, 600_000);

        if (runnerIndex >= parallelism)
        {
            throw new InvalidOperationException(
                "RUNNER_INDEX must be lower than LOADTEST_PARALLELISM.");
        }
        if (parallelism * clientsPerRunner != totalConnections)
        {
            throw new InvalidOperationException(
                "LOADTEST_PARALLELISM × CLIENTS_PER_RUNNER must equal " +
                "TOTAL_CONNECTIONS.");
        }
        if (startWaitTimeMs <= connectTimeoutMs)
        {
            throw new InvalidOperationException(
                "START_WAIT_TIME_MS must be greater than CONNECT_TIMEOUT_MS.");
        }

        return new RunnerOptions
        {
            RunId = runId,
            RunnerIndex = runnerIndex,
            Parallelism = parallelism,
            ClientsPerRunner = clientsPerRunner,
            TotalConnections = totalConnections,
            ConnectionsPerSecond = connectionsPerSecond,
            StartAtUnixMs = LongInteger(
                read,
                "START_AT_UNIX_MS",
                1,
                long.MaxValue),
            StreamingUri = AbsoluteUri(read, "FEATBIT_STREAMING_URL", "ws", "wss"),
            EventUri = AbsoluteUri(read, "FEATBIT_API_URL", "http", "https"),
            EnvironmentSecretPath =
                Required(read, "MULTI_ENVIRONMENT_SECRET_PATH"),
            EnvironmentId = Required(read, "FEATBIT_ENVIRONMENT_ID"),
            TargetEnvironmentKey = Required(read, "TARGET_ENVIRONMENT_KEY"),
            RevisionPlanJson = Required(read, "REVISION_PLAN_JSON"),
            WarmupFlagKey = Required(read, "POST_RAMP_WARMUP_FLAG_KEY"),
            ResultsDirectory = Required(read, "RESULTS_DIRECTORY"),
            StopFile = Required(read, "STOP_FILE"),
            ExpectedFlagCount =
                Integer(read, "EXPECTED_FULL_SYNC_FLAG_COUNT", 1, 1_000_000),
            ConnectTimeoutMs = connectTimeoutMs,
            StartWaitTimeMs = startWaitTimeMs,
            ReadyTimeoutSeconds =
                Integer(read, "READY_TIMEOUT_SECONDS", 1, 86_400),
            RunDurationSeconds =
                Integer(read, "RUN_DURATION_SECONDS", 1, 86_400),
            PollIntervalMs = Integer(read, "POLL_INTERVAL_MS", 1, 60_000),
            ResourceSampleIntervalMs =
                Integer(read, "RESOURCE_SAMPLE_INTERVAL_MS", 100, 60_000),
        };
    }

    private static string Required(Func<string, string?> read, string name)
    {
        var value = read(name)?.Trim();
        if (string.IsNullOrEmpty(value))
        {
            throw new InvalidOperationException($"{name} is required.");
        }

        return value;
    }

    private static int Integer(
        Func<string, string?> read,
        string name,
        int minimum,
        int maximum)
    {
        var raw = Required(read, name);
        if (!int.TryParse(
                raw,
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out var value) ||
            value < minimum ||
            value > maximum)
        {
            throw new InvalidOperationException(
                $"{name} must be an integer in [{minimum}, {maximum}].");
        }

        return value;
    }

    private static long LongInteger(
        Func<string, string?> read,
        string name,
        long minimum,
        long maximum)
    {
        var raw = Required(read, name);
        if (!long.TryParse(
                raw,
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out var value) ||
            value < minimum ||
            value > maximum)
        {
            throw new InvalidOperationException(
                $"{name} must be an integer in [{minimum}, {maximum}].");
        }

        return value;
    }

    private static Uri AbsoluteUri(
        Func<string, string?> read,
        string name,
        params string[] allowedSchemes)
    {
        var raw = Required(read, name);
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri) ||
            !allowedSchemes.Contains(uri.Scheme, StringComparer.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"{name} must be an absolute {string.Join("/", allowedSchemes)} URI.");
        }

        return uri;
    }
}
