using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

public class HypoSettingsTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-settings").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private string Path => HypoSettings.PathIn(_dir);

    [Fact]
    public void BothSharingSettingsStartOff()
    {
        // The design's decision, and worth a test rather than a comment: Hypo
        // puts whatever was copied on another device onto this clipboard, and a
        // password roaming to a Microsoft account is worse than Win+V is good.
        var settings = new HypoSettings();

        Assert.False(settings.ShareWithWindowsHistory);
        Assert.False(settings.AllowCloudClipboardUpload);
    }

    [Fact]
    public void TheDefaultsRestrictBothDirections()
    {
        var privacy = new HypoSettings().Privacy;

        Assert.False(privacy.AllowLocalHistory);
        Assert.False(privacy.AllowCloudUpload);
    }

    [Fact]
    public void AMissingFileYieldsTheDefaults()
    {
        var settings = HypoSettings.Load(Path);

        Assert.False(settings.ShareWithWindowsHistory);
        Assert.False(settings.AllowCloudClipboardUpload);
    }

    [Fact]
    public void SurvivesBeingWrittenAndReadBack()
    {
        new HypoSettings { ShareWithWindowsHistory = true, AllowCloudClipboardUpload = true }.Save(Path);

        var settings = HypoSettings.Load(Path);

        Assert.True(settings.ShareWithWindowsHistory);
        Assert.True(settings.AllowCloudClipboardUpload);
    }

    [Theory]
    [InlineData("this is not json")]
    [InlineData("")]
    [InlineData("null")]
    [InlineData("{\"ShareWithWindowsHistory\": \"not a bool\"}")]
    public void ACorruptFileFallsBackToTheSafeEnd(string contents)
    {
        // Failing this way cannot silently widen what is shared, which is the
        // only failure mode here that would matter.
        File.WriteAllText(Path, contents);

        var settings = HypoSettings.Load(Path);

        Assert.False(settings.ShareWithWindowsHistory);
        Assert.False(settings.AllowCloudClipboardUpload);
    }

    [Fact]
    public void KeepsWhatItWasNotToldAbout()
    {
        // A file written by an older build has one of the two keys. The missing
        // one has to land on its default rather than being read as true.
        File.WriteAllText(Path, "{\"ShareWithWindowsHistory\": true}");

        var settings = HypoSettings.Load(Path);

        Assert.True(settings.ShareWithWindowsHistory);
        Assert.False(settings.AllowCloudClipboardUpload);
    }
}
