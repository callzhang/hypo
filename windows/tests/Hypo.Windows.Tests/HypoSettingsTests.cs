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
    public void AHandEditedHotkeyFallsBackRatherThanBreaking()
    {
        // People edit this file. A typo should cost them the shortcut they meant,
        // not the application.
        File.WriteAllText(Path, """{"hotkey": "Ctrl+Alt+H"}""");
        Assert.Equal("Ctrl+Alt+H", HypoSettings.Load(Path).HotkeyBinding.ToString());

        File.WriteAllText(Path, """{"hotkey": "Alt+"}""");
        Assert.Equal(HotkeyBinding.Default, HypoSettings.Load(Path).HotkeyBinding);
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

    [Fact]
    public void TheFirewallNoticeStartsUnshown()
    {
        Assert.False(new HypoSettings().FirewallNoticeShown);
    }

    [Fact]
    public void RecordingTheNoticeDoesNotChangeWhatIsShared()
    {
        // It goes through the same record as the sharing switches, and carrying
        // the wrong values along would widen sharing without anyone asking.
        var settings = new HypoSettings() with { FirewallNoticeShown = true };

        Assert.True(settings.FirewallNoticeShown);
        Assert.False(settings.ShareWithWindowsHistory);
        Assert.False(settings.AllowCloudClipboardUpload);
    }

    /// <summary>
    /// The name every peer shows for this device. It defaults to what the OS
    /// calls the machine, which is rarely what its owner would call it.
    /// </summary>
    [Fact]
    public void FallsBackToTheMachineNameUntilItIsRenamed()
    {
        Assert.Equal(Environment.MachineName, new HypoSettings().EffectiveDeviceName);
        Assert.Equal("Studio PC", new HypoSettings { DeviceName = "Studio PC" }.EffectiveDeviceName);
        // Whitespace is not a name.
        Assert.Equal(Environment.MachineName, new HypoSettings { DeviceName = "   " }.EffectiveDeviceName);
    }

    [Fact]
    public void SanitisesANameTheWayEveryOtherClientDoes()
    {
        Assert.Equal("studio", HypoSettings.SanitiseDeviceName("  studio.local  "));
        Assert.Equal("Derek's PC", HypoSettings.SanitiseDeviceName("Derek's PC"));
        // Null rather than empty: a device with no name is worse than one named
        // after the machine, so the caller keeps what it had.
        Assert.Null(HypoSettings.SanitiseDeviceName("   "));
        Assert.Null(HypoSettings.SanitiseDeviceName(null));
    }

    [Fact]
    public void KeepsTheNameAcrossASaveAndLoad()
    {
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), System.IO.Path.GetRandomFileName());
        try
        {
            new HypoSettings { DeviceName = "Studio PC" }.Save(path);

            Assert.Equal("Studio PC", HypoSettings.Load(path).DeviceName);
        }
        finally
        {
            System.IO.File.Delete(path);
        }
    }
}
