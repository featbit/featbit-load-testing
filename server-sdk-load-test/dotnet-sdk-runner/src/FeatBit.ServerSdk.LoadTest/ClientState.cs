using System.Collections.Concurrent;
using FeatBit.Sdk.Server;
using FeatBit.Sdk.Server.Model;

namespace FeatBit.ServerSdk.LoadTest;

internal sealed class ClientState
{
    private int _ready;

    public required int LocalConnection { get; init; }
    public required int GlobalConnection { get; init; }
    public required long ScheduledAtUnixMs { get; init; }
    public required long CreateStartedAtUnixMs { get; init; }
    public required long ConstructorReturnedAtUnixMs { get; init; }
    public required FbClient Client { get; init; }
    public required FbUser User { get; init; }
    public FbClientStatus LastStatus { get; set; } = FbClientStatus.NotReady;
    public ConcurrentDictionary<string, string> LastRawValues { get; } =
        new(StringComparer.Ordinal);

    public bool Ready => Volatile.Read(ref _ready) == 1;

    public bool TryMarkReady()
    {
        return Interlocked.CompareExchange(ref _ready, 1, 0) == 0;
    }
}
