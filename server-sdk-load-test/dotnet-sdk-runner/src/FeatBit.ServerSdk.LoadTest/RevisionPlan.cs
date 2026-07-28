using System.Text.Json;

namespace FeatBit.ServerSdk.LoadTest;

public sealed record RevisionStep(
    int Index,
    string FlagKey,
    string Revision,
    string VariationType);

public sealed class RevisionPlan
{
    public required IReadOnlyList<RevisionStep> Steps { get; init; }

    public static RevisionPlan Parse(string json)
    {
        List<RevisionStep>? steps;
        try
        {
            steps = JsonSerializer.Deserialize<List<RevisionStep>>(
                json,
                JsonOptions);
        }
        catch (JsonException exception)
        {
            throw new InvalidOperationException(
                "REVISION_PLAN_JSON is not valid JSON.",
                exception);
        }

        if (steps is null || steps.Count == 0)
        {
            throw new InvalidOperationException(
                "REVISION_PLAN_JSON must contain at least one step.");
        }

        var flagKeys = new HashSet<string>(StringComparer.Ordinal);
        var revisions = new HashSet<string>(StringComparer.Ordinal);
        for (var offset = 0; offset < steps.Count; offset++)
        {
            var step = steps[offset];
            var expectedIndex = offset + 1;
            if (step.Index != expectedIndex ||
                string.IsNullOrWhiteSpace(step.FlagKey) ||
                string.IsNullOrWhiteSpace(step.Revision) ||
                step.VariationType is not ("string" or "json"))
            {
                throw new InvalidOperationException(
                    $"Revision step {expectedIndex} is invalid.");
            }
            if (!flagKeys.Add(step.FlagKey) || !revisions.Add(step.Revision))
            {
                throw new InvalidOperationException(
                    "Revision plan flag keys and revisions must be unique.");
            }
        }

        return new RevisionPlan { Steps = steps };
    }

    public static string ExtractRevision(string value, string variationType)
    {
        if (variationType == "string")
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new InvalidOperationException(
                    "String variation value is empty.");
            }

            return value.Trim();
        }
        if (variationType != "json")
        {
            throw new InvalidOperationException(
                "Variation type must be string or json.");
        }

        try
        {
            using var document = JsonDocument.Parse(value);
            if (!document.RootElement.TryGetProperty(
                    "_loadTestRevision",
                    out var revisionElement))
            {
                throw new InvalidOperationException(
                    "JSON variation has no _loadTestRevision property.");
            }

            var revision = revisionElement.GetString()?.Trim();
            if (string.IsNullOrEmpty(revision))
            {
                throw new InvalidOperationException(
                    "JSON variation _loadTestRevision is empty.");
            }

            return revision;
        }
        catch (JsonException exception)
        {
            throw new InvalidOperationException(
                "JSON variation value is invalid.",
                exception);
        }
    }

    private static readonly JsonSerializerOptions JsonOptions =
        new()
        {
            PropertyNameCaseInsensitive = true,
        };
}
