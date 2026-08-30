using Hypo.Windows.Clipboard;

namespace Hypo.Windows.Tests;

[Collection("clipboard")]
public class ClipboardPrivacyTests
{
    private static void RequireWindows() =>
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only: drives the real Win32 clipboard.");

    [Fact]
    public void TheDefaultRestrictsBothDirections()
    {
        Assert.True(ClipboardPrivacy.Private.RestrictsLocalHistory);
        Assert.True(ClipboardPrivacy.Private.RestrictsCloudUpload);
        Assert.Equal(2, ClipboardPrivacy.Private.MarkerCount);
    }

    [Fact]
    public void AllowingHistoryStopsRestrictingIt()
    {
        var privacy = new ClipboardPrivacy { AllowLocalHistory = true };

        Assert.False(privacy.RestrictsLocalHistory);
        Assert.True(privacy.RestrictsCloudUpload);
        Assert.Equal(1, privacy.MarkerCount);
    }

    [Fact]
    public void AllowingEverythingRestrictsNothing()
    {
        // Absence already means "no opinion". Publishing
        // CanUploadToCloudClipboard = 1 would assert a permission nobody asked
        // us to assert.
        var privacy = new ClipboardPrivacy { AllowLocalHistory = true, AllowCloudUpload = true };

        Assert.Equal(0, privacy.MarkerCount);
    }

    [Fact]
    public void TheCloudMarkerIsAZeroDword()
    {
        // Unlike the history marker, this one carries a value: omitting it is
        // not the same as forbidding.
        Assert.Equal(4, ClipboardPrivacy.ForbidCloudUploadValue.Length);
        Assert.Equal(0u, BitConverter.ToUInt32(ClipboardPrivacy.ForbidCloudUploadValue));
    }

    [SkippableFact]
    public void TheFormatsRegisterUnderTheNamesWindowsLooksFor()
    {
        RequireWindows();

        // A typo here produces a format Windows has never heard of, the marker
        // is published, nothing reads it, and the content is shared anyway --
        // silently, and in the direction that matters.
        Assert.NotEqual(0u, ClipboardPrivacy.ExcludeFromHistoryFormat);
        Assert.NotEqual(0u, ClipboardPrivacy.CanUploadToCloudFormat);
        Assert.NotEqual(ClipboardPrivacy.ExcludeFromHistoryFormat, ClipboardPrivacy.CanUploadToCloudFormat);
    }

    [SkippableFact]
    public void WritingTextPublishesTheMarkersBesideIt()
    {
        RequireWindows();

        WindowsClipboard.WriteText("private by default", ClipboardPrivacy.Private);

        Assert.Equal("private by default", WindowsClipboard.ReadText());
        Assert.True(WindowsClipboard.HasFormat(ClipboardPrivacy.ExcludeFromHistoryFormat));
        Assert.True(WindowsClipboard.HasFormat(ClipboardPrivacy.CanUploadToCloudFormat));
    }

    [SkippableFact]
    public void OptingInLeavesTheMarkersOff()
    {
        RequireWindows();

        WindowsClipboard.WriteText(
            "shared on purpose",
            new ClipboardPrivacy { AllowLocalHistory = true, AllowCloudUpload = true });

        Assert.Equal("shared on purpose", WindowsClipboard.ReadText());
        Assert.False(WindowsClipboard.HasFormat(ClipboardPrivacy.ExcludeFromHistoryFormat));
        Assert.False(WindowsClipboard.HasFormat(ClipboardPrivacy.CanUploadToCloudFormat));
    }

    [SkippableFact]
    public void TheContentSurvivesBeingMarked()
    {
        RequireWindows();

        // The markers go on in the same clipboard session as the content.
        // Writing them separately would EmptyClipboard over the content and
        // publish markers on an empty clipboard -- failing in the direction of
        // sharing more than intended, which is the worst way for this to break.
        WindowsClipboard.WriteText("你好,剪贴板 🎉", ClipboardPrivacy.Private);

        Assert.Equal("你好,剪贴板 🎉", WindowsClipboard.ReadText());
        Assert.True(WindowsClipboard.HasFormat(ClipboardPrivacy.ExcludeFromHistoryFormat));
    }
}
