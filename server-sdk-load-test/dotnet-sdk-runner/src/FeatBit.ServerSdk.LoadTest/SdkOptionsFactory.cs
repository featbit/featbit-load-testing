using FeatBit.Sdk.Server.Options;
using Microsoft.Extensions.Logging.Abstractions;

namespace FeatBit.ServerSdk.LoadTest;

public static class SdkOptionsFactory
{
    public static FbOptions Create(
        RunnerOptions options,
        string serverSecret)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentException.ThrowIfNullOrWhiteSpace(serverSecret);

        // FbOptionsBuilder validates each setter immediately. Set the long
        // start-wait boundary before increasing the connect timeout so the
        // intermediate builder state remains valid.
        return new FbOptionsBuilder(serverSecret)
            .Streaming(options.StreamingUri)
            .Event(options.EventUri)
            .StartWaitTime(
                TimeSpan.FromMilliseconds(options.StartWaitTimeMs))
            .ConnectTimeout(
                TimeSpan.FromMilliseconds(options.ConnectTimeoutMs))
            .DisableEvents(true)
            .LoggerFactory(NullLoggerFactory.Instance)
            .Build();
    }
}
