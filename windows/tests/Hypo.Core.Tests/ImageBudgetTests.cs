using Hypo.Core.Sync;

namespace Hypo.Core.Tests;

public class ImageBudgetTests
{
    [Fact]
    public void LeavesASmallImageAlone()
    {
        // Most clipboard images are small, and re-encoding one that fits would
        // lose quality for no reason at all.
        var plan = ImageBudget.Plan(200 * 1024, 800, 600);

        Assert.Equal(ImageAction.SendAsIs, plan.Action);
    }

    [Fact]
    public void LeavesAnImageJustUnderTheThresholdAlone()
    {
        Assert.Equal(
            ImageAction.SendAsIs,
            ImageBudget.Plan(ImageBudget.CompressAboveBytes, 4000, 3000).Action);
    }

    [Fact]
    public void CompressesABigScreenshotAndScalesIt()
    {
        // A 4K screenshot: over the size budget and over the side limit.
        var plan = ImageBudget.Plan(9 * 1024 * 1024, 3840, 2160);

        Assert.Equal(ImageAction.Compress, plan.Action);
        Assert.Equal(ImageBudget.MaxLongestSide, plan.LongestSide);
        Assert.Equal([85, 75, 60, 40], plan.Qualities);
    }

    [Fact]
    public void DoesNotScaleAnImageThatIsMerelyHeavy()
    {
        // A long thin image can be over the size budget without exceeding the
        // side limit. Scaling it anyway would lose detail for nothing; the
        // quality ladder is what brings the size down.
        var plan = ImageBudget.Plan(9 * 1024 * 1024, 2000, 1200);

        Assert.Equal(ImageAction.Compress, plan.Action);
        Assert.Null(plan.LongestSide);
        Assert.NotEmpty(plan.Qualities);
    }

    [Fact]
    public void ScalesOnTheLongestSideWhicheverItIs()
    {
        Assert.Equal(
            ImageBudget.MaxLongestSide,
            ImageBudget.Plan(9 * 1024 * 1024, 1000, 4000).LongestSide);
    }

    [Fact]
    public void RefusesSomethingThatIsNotReallyAClipboardItem()
    {
        // A hundred megabytes of bitmap is a mistake somewhere. Decoding it to
        // find that out costs the memory before it costs the failure.
        var plan = ImageBudget.Plan(200 * 1024 * 1024, 20000, 20000);

        Assert.Equal(ImageAction.Refuse, plan.Action);
        Assert.Contains("MB", plan.Reason!, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(0, true)]
    [InlineData(ImageBudget.MaxBytes, true)]
    [InlineData(ImageBudget.MaxBytes + 1, false)]
    public void FitsIsTheProtocolCeiling(int bytes, bool expected)
    {
        Assert.Equal(expected, ImageBudget.Fits(bytes));
    }

    [Fact]
    public void TheQualityLadderOnlyGoesDown()
    {
        // Trying a higher quality after a lower one would make the result depend
        // on where the loop happened to stop.
        var ladder = ImageBudget.QualityLadder;

        Assert.Equal(ladder.OrderByDescending(q => q), ladder);
        Assert.All(ladder, q => Assert.InRange(q, 1, 100));
    }

    [Fact]
    public void TheThresholdsAreOrderedTheWayTheDecisionsAre()
    {
        // Compressing above a threshold higher than the ceiling would mean
        // nothing ever compressed and everything over the ceiling just failed.
        Assert.True(ImageBudget.CompressAboveBytes < ImageBudget.MaxBytes);
        Assert.True(ImageBudget.MaxBytes < ImageBudget.RefuseAboveBytes);
    }

    [Fact]
    public void RejectsANegativeLength()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => ImageBudget.Plan(-1, 100, 100));
    }
}
