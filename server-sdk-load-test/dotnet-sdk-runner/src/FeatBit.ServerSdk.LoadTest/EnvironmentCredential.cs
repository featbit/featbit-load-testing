using System.Text.Json;
using System.Text.Json.Serialization;

namespace FeatBit.ServerSdk.LoadTest;

public sealed class EnvironmentCredential
{
    public required string ExperimentId { get; init; }
    public required string EnvironmentId { get; init; }
    public required string EnvironmentKey { get; init; }
    [JsonIgnore]
    public required string ServerSecret { get; init; }

    public override string ToString()
    {
        return $"{ExperimentId}/{EnvironmentKey}/<redacted>";
    }

    public static EnvironmentCredential Read(
        string path,
        string expectedEnvironmentId,
        string expectedEnvironmentKey)
    {
        if (!File.Exists(path))
        {
            throw new InvalidOperationException(
                "The mounted environment credential file does not exist.");
        }

        return Parse(
            File.ReadAllText(path),
            expectedEnvironmentId,
            expectedEnvironmentKey);
    }

    public static EnvironmentCredential Parse(
        string json,
        string expectedEnvironmentId,
        string expectedEnvironmentKey)
    {
        SecretDocument? document;
        try
        {
            document = JsonSerializer.Deserialize<SecretDocument>(
                json,
                JsonOptions);
        }
        catch (JsonException exception)
        {
            throw new InvalidOperationException(
                "The environment credential document is not valid JSON.",
                exception);
        }

        if (document is null ||
            document.SchemaVersion != 1 ||
            string.IsNullOrWhiteSpace(document.ExperimentId) ||
            string.IsNullOrWhiteSpace(document.TargetEnvironmentId) ||
            document.Environments is null ||
            document.Environments.Count != 1)
        {
            throw new InvalidOperationException(
                "The environment credential document must contain exactly one " +
                "schemaVersion 1 environment.");
        }

        var environment = document.Environments[0];
        if (environment.Index != 1 ||
            string.IsNullOrWhiteSpace(environment.Id) ||
            string.IsNullOrWhiteSpace(environment.Key) ||
            string.IsNullOrWhiteSpace(environment.ServerSecret))
        {
            throw new InvalidOperationException(
                "The environment credential entry is incomplete.");
        }
        if (!string.Equals(
                document.TargetEnvironmentId,
                expectedEnvironmentId,
                StringComparison.Ordinal) ||
            !string.Equals(
                environment.Id,
                expectedEnvironmentId,
                StringComparison.Ordinal) ||
            !string.Equals(
                environment.Key,
                expectedEnvironmentKey,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "The mounted environment credential does not match the pilot " +
                "configuration.");
        }

        return new EnvironmentCredential
        {
            ExperimentId = document.ExperimentId.Trim(),
            EnvironmentId = environment.Id.Trim(),
            EnvironmentKey = environment.Key.Trim(),
            ServerSecret = environment.ServerSecret.Trim(),
        };
    }

    private static readonly JsonSerializerOptions JsonOptions =
        new()
        {
            PropertyNameCaseInsensitive = true,
        };

    private sealed class SecretDocument
    {
        public int SchemaVersion { get; set; }
        public string? ExperimentId { get; set; }
        public string? TargetEnvironmentId { get; set; }
        public List<SecretEnvironment>? Environments { get; set; }
    }

    private sealed class SecretEnvironment
    {
        public int Index { get; set; }
        public string? Id { get; set; }
        public string? Key { get; set; }
        public string? ServerSecret { get; set; }
    }
}
