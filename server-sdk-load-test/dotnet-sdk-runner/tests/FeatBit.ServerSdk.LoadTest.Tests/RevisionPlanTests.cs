using FeatBit.ServerSdk.LoadTest;

namespace FeatBit.ServerSdk.LoadTest.Tests;

public sealed class RevisionPlanTests
{
    [Fact]
    public void ParsesStringAndJsonSteps()
    {
        var plan = RevisionPlan.Parse(
            """
            [
              {
                "index": 1,
                "flagKey": "string-flag",
                "revision": "rev-001",
                "variationType": "string"
              },
              {
                "index": 2,
                "flagKey": "json-flag",
                "revision": "rev-002",
                "variationType": "json"
              }
            ]
            """);

        Assert.Equal(2, plan.Steps.Count);
        Assert.Equal("rev-001", RevisionPlan.ExtractRevision("rev-001", "string"));
        Assert.Equal(
            "rev-002",
            RevisionPlan.ExtractRevision(
                """{"_loadTestRevision":"rev-002","padding":"x"}""",
                "json"));
    }

    [Fact]
    public void RejectsDuplicateFlagKeys()
    {
        var error = Assert.Throws<InvalidOperationException>(
            () => RevisionPlan.Parse(
                """
                [
                  {
                    "index": 1,
                    "flagKey": "same",
                    "revision": "rev-001",
                    "variationType": "string"
                  },
                  {
                    "index": 2,
                    "flagKey": "same",
                    "revision": "rev-002",
                    "variationType": "json"
                  }
                ]
                """));

        Assert.Contains("unique", error.Message);
    }
}
