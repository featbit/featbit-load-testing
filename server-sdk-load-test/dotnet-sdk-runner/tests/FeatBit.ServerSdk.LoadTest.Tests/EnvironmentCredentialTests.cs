using FeatBit.ServerSdk.LoadTest;

namespace FeatBit.ServerSdk.LoadTest.Tests;

public sealed class EnvironmentCredentialTests
{
    [Fact]
    public void ParsesOneEnvironmentWithoutExposingSecret()
    {
        var credential = EnvironmentCredential.Parse(
            """
            {
              "schemaVersion": 1,
              "experimentId": "sdk-flagset-3k-g5-v1",
              "targetEnvironmentId": "env-id",
              "environments": [
                {
                  "index": 1,
                  "id": "env-id",
                  "key": "env-key",
                  "serverSecret": "super-secret"
                }
              ]
            }
            """,
            "env-id",
            "env-key");

        Assert.Equal("env-id", credential.EnvironmentId);
        Assert.DoesNotContain("super-secret", credential.ToString());
        Assert.Contains("<redacted>", credential.ToString());
    }

    [Fact]
    public void RejectsCredentialForDifferentEnvironment()
    {
        var error = Assert.Throws<InvalidOperationException>(
            () => EnvironmentCredential.Parse(
                """
                {
                  "schemaVersion": 1,
                  "experimentId": "experiment",
                  "targetEnvironmentId": "other",
                  "environments": [
                    {
                      "index": 1,
                      "id": "other",
                      "key": "other-key",
                      "serverSecret": "secret"
                    }
                  ]
                }
                """,
                "env-id",
                "env-key"));

        Assert.Contains("does not match", error.Message);
    }
}
