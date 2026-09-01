using System.Text;
using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

public class ArrivalNoticeTests
{
    private static HistoryEntry Entry(string text, string? device = "OPPO PLP110") => new()
    {
        Content = new ClipboardContent
        {
            ContentType = ContentType.Text,
            Data = Encoding.UTF8.GetBytes(text),
        },
        CopiedAt = DateTimeOffset.UnixEpoch,
        SourceDeviceName = device,
        SourceDeviceId = device is null ? null : "bbe296d6-0785-43d2-91b6-b135b72f4c41",
    };

    [Fact]
    public void SaysWhichDeviceItCameFrom()
    {
        var notice = ArrivalNotice.For(Entry("a link to the thing"));

        Assert.NotNull(notice);
        Assert.Equal("Copied from OPPO PLP110", notice.Title);
        Assert.Contains("a link to the thing", notice.Body);
    }

    [Fact]
    public void SaysNothingAboutWhatYouCopiedYourself()
    {
        // Applied only fires for inbound items, so this is belt and braces --
        // but it is the rule, and a rule with no test is a comment.
        Assert.Null(ArrivalNotice.For(Entry("copied right here", device: null)));
    }

    [Fact]
    public void ThePreviewIsShortEnoughNotToReadOverAShoulder()
    {
        var secret = new string('x', 500);

        var notice = ArrivalNotice.For(Entry(secret));

        Assert.NotNull(notice);
        Assert.True(
            notice.Body.Length <= ArrivalNotice.MaxPreview,
            $"the body is {notice.Body.Length} characters");
        Assert.EndsWith("…", notice.Body, StringComparison.Ordinal);
    }

    [Fact]
    public void ALongDeviceNameIsTrimmedRatherThanRefused()
    {
        // NotifyIcon throws rather than truncating when the text is too long,
        // which would take the notification and the arrival with it.
        var notice = ArrivalNotice.For(Entry("hello", device: new string('D', 200)));

        Assert.NotNull(notice);
        Assert.True(notice.Title.Length <= ArrivalNotice.MaxTitle, $"{notice.Title.Length} characters");
        Assert.True(notice.Body.Length <= ArrivalNotice.MaxBody);
    }

    [Fact]
    public void AnImageIsDescribedRatherThanShown()
    {
        var entry = new HistoryEntry
        {
            Content = new ClipboardContent
            {
                ContentType = ContentType.Image,
                Data = [1, 2, 3, 4],
            },
            CopiedAt = DateTimeOffset.UnixEpoch,
            SourceDeviceName = "derek's MacBook Air",
        };

        var notice = ArrivalNotice.For(entry);

        Assert.NotNull(notice);
        Assert.Contains("Image", notice.Body, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void NotifyingIsOnByDefault()
    {
        // Unlike the two sharing switches: this one shares nothing beyond the
        // screen already in front of you, and an arrival nobody is told about is
        // one you find out about by pasting and seeing.
        Assert.True(new HypoSettings().NotifyOnArrival);
    }
}
