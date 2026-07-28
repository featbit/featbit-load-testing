using FeatBit.ServerSdk.LoadTest;

namespace FeatBit.ServerSdk.LoadTest.Tests;

public sealed class RunnerOptionsTests
{
    [Fact]
    public void ProducesExactlyTwentyFiveSecondGlobalRamp()
    {
        var options = RunnerOptions.FromValues(ValidValues().GetValueOrDefault);
        var scheduled = new HashSet<long>();

        for (var runner = 0; runner < 20; runner++)
        {
            var values = ValidValues();
            values["RUNNER_INDEX"] = runner.ToString();
            var runnerOptions =
                RunnerOptions.FromValues(values.GetValueOrDefault);
            for (var local = 1; local <= 25; local++)
            {
                Assert.True(
                    scheduled.Add(
                        runnerOptions.ScheduledAtUnixMs(local)));
            }
        }

        Assert.Equal(500, scheduled.Count);
        Assert.Equal(1_700_000_000_000, scheduled.Min());
        Assert.Equal(1_700_000_024_950, scheduled.Max());
        Assert.Equal(
            1_700_000_000_950,
            options.WithRunnerIndex(19).ScheduledAtUnixMs(1));
    }

    [Fact]
    public void RejectsTopologyThatDoesNotMultiplyToTotal()
    {
        var values = ValidValues();
        values["TOTAL_CONNECTIONS"] = "501";

        var error = Assert.Throws<InvalidOperationException>(
            () => RunnerOptions.FromValues(values.GetValueOrDefault));

        Assert.Contains("must equal", error.Message);
    }

    private static Dictionary<string, string> ValidValues()
    {
        return new Dictionary<string, string>
        {
            ["RUN_ID"] = "growth-f3k-dotnet-p500-v-test",
            ["RUNNER_INDEX"] = "0",
            ["LOADTEST_PARALLELISM"] = "20",
            ["CLIENTS_PER_RUNNER"] = "25",
            ["TOTAL_CONNECTIONS"] = "500",
            ["CONNECTIONS_PER_SECOND"] = "20",
            ["START_AT_UNIX_MS"] = "1700000000000",
            ["FEATBIT_STREAMING_URL"] = "ws://featbit-els:5100",
            ["FEATBIT_API_URL"] = "http://featbit-api:5000",
            ["MULTI_ENVIRONMENT_SECRET_PATH"] = "/secret/environments.json",
            ["FEATBIT_ENVIRONMENT_ID"] = "env-id",
            ["TARGET_ENVIRONMENT_KEY"] = "env-key",
            ["REVISION_PLAN_JSON"] =
                "[{\"index\":1,\"flagKey\":\"flag-1\",\"revision\":\"rev-001\",\"variationType\":\"string\"}]",
            ["POST_RAMP_WARMUP_FLAG_KEY"] = "warmup",
            ["RESULTS_DIRECTORY"] = "/results",
            ["STOP_FILE"] = "/tmp/stop",
            ["EXPECTED_FULL_SYNC_FLAG_COUNT"] = "3000",
            ["CONNECT_TIMEOUT_MS"] = "3000",
            ["START_WAIT_TIME_MS"] = "5000",
            ["READY_TIMEOUT_SECONDS"] = "300",
            ["RUN_DURATION_SECONDS"] = "900",
            ["POLL_INTERVAL_MS"] = "10",
            ["RESOURCE_SAMPLE_INTERVAL_MS"] = "1000",
        };
    }
}

internal static class RunnerOptionsTestExtensions
{
    public static RunnerOptions WithRunnerIndex(
        this RunnerOptions value,
        int runnerIndex)
    {
        return new RunnerOptions
        {
            RunId = value.RunId,
            RunnerIndex = runnerIndex,
            Parallelism = value.Parallelism,
            ClientsPerRunner = value.ClientsPerRunner,
            TotalConnections = value.TotalConnections,
            ConnectionsPerSecond = value.ConnectionsPerSecond,
            StartAtUnixMs = value.StartAtUnixMs,
            StreamingUri = value.StreamingUri,
            EventUri = value.EventUri,
            EnvironmentSecretPath = value.EnvironmentSecretPath,
            EnvironmentId = value.EnvironmentId,
            TargetEnvironmentKey = value.TargetEnvironmentKey,
            RevisionPlanJson = value.RevisionPlanJson,
            WarmupFlagKey = value.WarmupFlagKey,
            ResultsDirectory = value.ResultsDirectory,
            StopFile = value.StopFile,
            ExpectedFlagCount = value.ExpectedFlagCount,
            ConnectTimeoutMs = value.ConnectTimeoutMs,
            StartWaitTimeMs = value.StartWaitTimeMs,
            ReadyTimeoutSeconds = value.ReadyTimeoutSeconds,
            RunDurationSeconds = value.RunDurationSeconds,
            PollIntervalMs = value.PollIntervalMs,
            ResourceSampleIntervalMs = value.ResourceSampleIntervalMs,
        };
    }
}
