using System.Text;
using Hypo.Core.Abstractions;
using Hypo.Core.Protocol;
using Hypo.Core.Relay;
using Hypo.Core.Sync;
using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

/// <summary>
/// What happens between double-clicking the application and a tray icon
/// existing. It was the least tested code in the project and the first thing a
/// user meets.
/// </summary>
public class AppStartupTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-startup").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private sealed class NullClipboard : IClipboard
    {
        public event EventHandler<ClipboardContent>? ContentChanged;

        public Task<ClipboardContent?> GetAsync(CancellationToken ct = default)
        {
            _ = ContentChanged;
            return Task.FromResult<ClipboardContent?>(null);
        }

        public Task SetAsync(ClipboardContent content, CancellationToken ct = default) => Task.CompletedTask;
    }

    [Fact]
    public void CreatesADeviceIdOnTheFirstRun()
    {
        var store = new InMemorySecretStore();

        var id = AppStartup.LoadOrCreateDeviceId(store);

        Assert.True(Guid.TryParse(id, out _));
        Assert.NotNull(store.Read("local-device-id"));
    }

    [Fact]
    public void KeepsTheSameDeviceIdOnEveryRunAfter()
    {
        // An id that changed between runs would make every existing pairing
        // useless: peers key on it.
        var store = new InMemorySecretStore();

        Assert.Equal(AppStartup.LoadOrCreateDeviceId(store), AppStartup.LoadOrCreateDeviceId(store));
    }

    [Fact]
    public void ReplacesADeviceIdThatIsNotAGuid()
    {
        // Something truncated the file, or an older build wrote a different
        // shape. Refusing to start over 16 bytes would be worse than repairing.
        var store = new InMemorySecretStore();
        store.Write("local-device-id", [1, 2, 3]);

        var id = AppStartup.LoadOrCreateDeviceId(store);

        Assert.True(Guid.TryParse(id, out _));
    }

    [Fact]
    public void TheInstanceLockIsPerUserRatherThanGlobal()
    {
        // Two people signed into one machine each have their own clipboard; a
        // global name would let whoever logged in first block the second.
        Assert.NotEqual(AppStartup.MutexNameFor("alice"), AppStartup.MutexNameFor("bob"));
        Assert.StartsWith("Local\\", AppStartup.MutexNameFor("alice"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task SaysWhatIsWrongWhenThereIsNoRelaySecret()
    {
        // A sentence, not an exception: an exception escaping OnStartup closes
        // the application before it can say anything at all.
        var result = await RunWithoutRelaySecretAsync();

        Assert.Equal(StartupOutcome.NotConfigured, result.Outcome);
        Assert.Contains(RelayOptions.SecretVariable, result.Message, StringComparison.Ordinal);
        Assert.Contains("this network", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.NotNull(result.DeviceId);
    }

    [Fact]
    public async Task DoesNotLeaveTheHistoryOpenWhenItGivesUp()
    {
        // A held SQLite handle would stop the next attempt from deleting or
        // repairing the file, which is the failure that turns a bad start into
        // a permanently bad one.
        var result = await RunWithoutRelaySecretAsync();

        Assert.False(result.Started);
        File.Delete(Path.Combine(_dir, "history.db"));
    }

    [Fact]
    public async Task ReportsAStateDirectoryItCannotUse()
    {
        // A file where the directory should be. Windows and Unix both refuse,
        // and the user gets told which path rather than a stack trace.
        var blocked = Path.Combine(_dir, "blocked");
        await File.WriteAllTextAsync(blocked, "not a directory");

        var result = await AppStartup.RunAsync(new NullClipboard(), blocked, "Test PC");

        Assert.Equal(StartupOutcome.Failed, result.Outcome);
        Assert.Contains(blocked, result.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void TheConsoleClientAndTheTrayApplicationAgreeOnTheDeviceId()
    {
        // Two copies of "which id am I?" would be two chances to disagree, and
        // disagreeing means every pairing made by the other one stops working.
        // The console client used to have its own.
        var store = new InMemorySecretStore();

        var first = AppStartup.LoadOrCreateDeviceId(store);

        Assert.Equal(first, Program.ReadDeviceIdForTests(store));
    }

    [Fact]
    public void RunningWithNoArgumentsSyncs()
    {
        // Someone who typed the name of a sync tool wanted it to sync. Printing
        // usage instead is one wrong word away and would be quietly annoying
        // forever.
        Assert.Equal("run", Program.DefaultCommand);
        Assert.Contains(Program.DefaultCommand, Program.Commands);
    }

    [Fact]
    public void EveryDocumentedCommandIsOneItAnswersTo()
    {
        Assert.Equal(["discover", "pair", "code", "enter", "run"], Program.Commands);
    }

    [Fact]
    public void ThereIsAWayToPairWithoutASharedNetwork()
    {
        // Without these, two devices that are never on one LAN cannot be paired
        // at all -- a phone on cellular, a laptop somewhere else.
        Assert.Contains("code", Program.Commands);
        Assert.Contains("enter", Program.Commands);
    }

    /// <summary>
    /// Runs a start with the relay secret hidden.
    ///
    /// <para>The secret is found by walking up from the binary looking for a
    /// <c>.env</c>, so a temporary state directory is not enough to hide it --
    /// the variable has to be cleared and the search has to miss.</para>
    /// </summary>
    private async Task<StartupResult> RunWithoutRelaySecretAsync()
    {
        var previous = Environment.GetEnvironmentVariable(RelayOptions.SecretVariable);
        Environment.SetEnvironmentVariable(RelayOptions.SecretVariable, string.Empty);

        try
        {
            // A temp directory with no .env anywhere above it: the search walks
            // upwards, so clearing the variable alone still finds the repo's.
            return await AppStartup.RunAsync(
                new NullClipboard(), _dir, "Test PC", relaySearchFrom: _dir);
        }
        finally
        {
            Environment.SetEnvironmentVariable(RelayOptions.SecretVariable, previous);
        }
    }
}
