using FeatBit.ServerSdk.LoadTest;

EnvironmentCredential? credential = null;

if (args.Length == 1 && args[0] == "--version")
{
    Console.WriteLine(
        "FeatBit.ServerSdk.LoadTest/1.0.0 " +
        $"FeatBit.ServerSdk/{typeof(FeatBit.Sdk.Server.FbClient).Assembly.GetName().Version}");
    return 0;
}

using var shutdown = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    shutdown.Cancel();
};

try
{
    var options = RunnerOptions.FromEnvironment();
    credential = EnvironmentCredential.Read(
        options.EnvironmentSecretPath,
        options.EnvironmentId,
        options.TargetEnvironmentKey);
    var revisionPlan = RevisionPlan.Parse(options.RevisionPlanJson);
    using var events = new JsonEventWriter(
        options.ResultsDirectory,
        options.RunId,
        options.RunnerIndex);
    var runner = new LoadTestRunner(
        options,
        credential,
        revisionPlan,
        events);
    return await runner.RunAsync(shutdown.Token);
}
catch (OperationCanceledException)
{
    Console.Error.WriteLine("Runner cancelled.");
    return 130;
}
catch (Exception exception)
{
    var message = exception.Message
        .Replace("\r", " ", StringComparison.Ordinal)
        .Replace("\n", " ", StringComparison.Ordinal);
    if (credential is not null)
    {
        message = message.Replace(
            credential.ServerSecret,
            "<redacted>",
            StringComparison.Ordinal);
    }
    Console.Error.WriteLine(
        $"Runner configuration or execution failed: {exception.GetType().Name}: " +
        message);
    return 1;
}
