using FeatBit.ServerSdk.LoadTest;

namespace FeatBit.ServerSdk.LoadTest.Tests;

public sealed class SdkOptionsFactoryTests
{
    [Fact]
    public void SetsStartWaitBeforeTheLongerConnectTimeout()
    {
        var options = RunnerOptions.FromValues(ValidValues().GetValueOrDefault);

        var sdkOptions = SdkOptionsFactory.Create(
            options,
            "test-server-secret");

        Assert.NotNull(sdkOptions);
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
            ["CONNECT_TIMEOUT_MS"] = "15000",
            ["START_WAIT_TIME_MS"] = "300000",
            ["READY_TIMEOUT_SECONDS"] = "600",
            ["RUN_DURATION_SECONDS"] = "1200",
            ["POLL_INTERVAL_MS"] = "10",
            ["RESOURCE_SAMPLE_INTERVAL_MS"] = "1000",
        };
    }
}
