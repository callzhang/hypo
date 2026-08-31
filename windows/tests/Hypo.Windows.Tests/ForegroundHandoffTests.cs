using Hypo.Windows.Clipboard;

namespace Hypo.Windows.Tests;

public class ForegroundHandoffTests
{
    private static void RequireWindows() =>
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only: uses the Win32 foreground window.");

    [SkippableFact]
    public void StartsWithNowhereToReturn()
    {
        RequireWindows();

        Assert.False(new ForegroundHandoff().HasSomewhereToReturn);
    }

    [SkippableFact]
    public void ReturningWithoutCapturingIsHarmless()
    {
        RequireWindows();

        // The user may open the history window from the tray without having been
        // in any application at all.
        Assert.False(new ForegroundHandoff().Return());
    }

    [SkippableFact]
    public void ForgetsTheWindowAfterReturningToIt()
    {
        RequireWindows();

        // Returning twice would drag the user back to an application they have
        // since left.
        var handoff = new ForegroundHandoff();
        handoff.Capture();
        handoff.Return();

        Assert.False(handoff.HasSomewhereToReturn);
    }

}
