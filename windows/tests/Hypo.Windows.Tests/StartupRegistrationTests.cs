using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

public class StartupRegistrationTests
{
    [Fact]
    public void ThePathIsQuoted()
    {
        // Windows splits an unquoted Run entry at spaces, and the obvious home
        // for an unpacked zip is under %LOCALAPPDATA%\Programs\Hypo -- where a
        // user name with a space in it is enough to break it.
        Assert.Equal(
            "\"C:\\Users\\Derek Zen\\AppData\\Local\\Programs\\Hypo\\Hypo.exe\"",
            StartupRegistration.CommandFor("C:\\Users\\Derek Zen\\AppData\\Local\\Programs\\Hypo\\Hypo.exe"));
    }

    [Fact]
    public void QuotingSomethingAlreadyQuotedDoesNotDoubleIt()
    {
        Assert.Equal("\"C:\\Hypo\\Hypo.exe\"", StartupRegistration.CommandFor("\"C:\\Hypo\\Hypo.exe\""));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void ThereIsNothingToRegisterWithoutAPath(string path)
    {
        Assert.Throws<ArgumentException>(() => StartupRegistration.CommandFor(path));
    }

    [Fact]
    public void ANullPathIsARefusalToo()
    {
        // ArgumentNullException rather than ArgumentException: ThrowIfNullOrWhiteSpace
        // distinguishes them, and so does anything catching them.
        Assert.Throws<ArgumentNullException>(() => StartupRegistration.CommandFor(null!));
    }

    [SkippableFact]
    public void TurningItOnAndOffAgainLeavesNothingBehind()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        var was = StartupRegistration.IsEnabled();

        try
        {
            Assert.Null(StartupRegistration.Set(true, @"C:\Hypo\Hypo.exe"));
            Assert.True(StartupRegistration.IsEnabled());

            // Twice, because a switch someone flips back and forth must not
            // accumulate entries.
            Assert.Null(StartupRegistration.Set(true, @"C:\Hypo\Hypo.exe"));

            Assert.Null(StartupRegistration.Set(false, @"C:\Hypo\Hypo.exe"));
            Assert.False(StartupRegistration.IsEnabled());

            // Removing what is not there is not an error.
            Assert.Null(StartupRegistration.Set(false, @"C:\Hypo\Hypo.exe"));
        }
        finally
        {
            StartupRegistration.Set(was, @"C:\Hypo\Hypo.exe");
        }
    }
}
