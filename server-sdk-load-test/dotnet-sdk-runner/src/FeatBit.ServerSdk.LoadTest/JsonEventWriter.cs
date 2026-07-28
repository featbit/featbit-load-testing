using System.Text;
using System.Text.Json;

namespace FeatBit.ServerSdk.LoadTest;

public sealed class JsonEventWriter : IDisposable
{
    private readonly object _gate = new();
    private readonly StreamWriter _writer;
    private readonly string _summaryPath;
    private readonly string _runId;
    private readonly int _runnerIndex;
    private bool _disposed;

    public JsonEventWriter(
        string resultsDirectory,
        string runId,
        int runnerIndex)
    {
        Directory.CreateDirectory(resultsDirectory);
        _runId = runId;
        _runnerIndex = runnerIndex;
        var prefix = $"{runId}-dotnet-runner-{runnerIndex + 1:D2}";
        var eventPath = Path.Combine(resultsDirectory, $"{prefix}-events.jsonl");
        _summaryPath = Path.Combine(
            resultsDirectory,
            $"{prefix}-summary.json");
        _writer = new StreamWriter(
            new FileStream(
                eventPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.Read),
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false))
        {
            AutoFlush = true,
        };
    }

    public void Emit(
        string eventName,
        IReadOnlyDictionary<string, object?>? fields = null,
        long? atUnixMs = null)
    {
        var record = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["schemaVersion"] = 1,
            ["event"] = eventName,
            ["atUnixMs"] = atUnixMs ?? Clock.UnixMilliseconds(),
            ["runId"] = _runId,
            ["runner"] = _runnerIndex + 1,
        };
        if (fields is not null)
        {
            foreach (var field in fields)
            {
                if (record.ContainsKey(field.Key))
                {
                    throw new InvalidOperationException(
                        $"Event field '{field.Key}' is reserved.");
                }

                record[field.Key] = field.Value;
            }
        }

        var json = JsonSerializer.Serialize(record, JsonOptions);
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _writer.WriteLine(json);
            Console.Out.WriteLine(json);
        }
    }

    public void WriteSummary(object summary)
    {
        var json = JsonSerializer.Serialize(
            summary,
            new JsonSerializerOptions(JsonOptions) { WriteIndented = true });
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            File.WriteAllText(
                _summaryPath,
                json + Environment.NewLine,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _writer.Dispose();
        }
    }

    private static readonly JsonSerializerOptions JsonOptions =
        new()
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        };
}

public static class Clock
{
    public static long UnixMilliseconds()
    {
        return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    }
}
