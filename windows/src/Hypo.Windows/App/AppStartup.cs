using System.Runtime.Versioning;
using Hypo.Core.Abstractions;
using Hypo.Core.Client;
using Hypo.Core.History;
using Hypo.Core.Relay;
using Hypo.Core.Sync;

namespace Hypo.Windows.App;

/// <summary>Why a start attempt ended the way it did.</summary>
public enum StartupOutcome
{
    Started,

    /// <summary>Another copy holds the single-instance lock.</summary>
    AlreadyRunning,

    /// <summary>No relay secret, and nothing paired to reach over the LAN either.</summary>
    NotConfigured,

    /// <summary>Something on this machine refused: an unwritable state directory, a taken port.</summary>
    Failed,
}

public sealed record StartupResult
{
    public required StartupOutcome Outcome { get; init; }

    /// <summary>What to tell the user. Never null, and never a stack trace.</summary>
    public required string Message { get; init; }

    public HypoClient? Client { get; init; }

    public ClipboardHistoryStore? History { get; init; }

    public string? DeviceId { get; init; }

    public bool Started => Outcome == StartupOutcome.Started;
}

/// <summary>
/// Everything that happens between double-clicking the application and a tray
/// icon existing, with no dialogs in it.
///
/// <para>Separated from <c>App.xaml.cs</c> because it was the least tested code
/// in the project and the first thing a user meets: an unwritable state
/// directory, a missing relay secret, a second copy already running. Those are
/// decisions, and decisions mixed into a method that also shows a MessageBox
/// cannot be tested at all.</para>
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class AppStartup
{
    /// <summary>
    /// Per user, not global. Two people signed into one machine each have their
    /// own clipboard, and a global name would let whoever logged in first
    /// silently block the second.
    /// </summary>
    public static string MutexNameFor(string userName) => $"Local\\Hypo.Windows.App.{userName}";

    public static string DefaultStateDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Hypo");

    /// <summary>
    /// Reads this installation's device id, creating one the first time.
    ///
    /// <para>Stored with the keys it belongs with. An id that changed between
    /// runs would make every existing pairing useless, because peers key on
    /// it.</para>
    /// </summary>
    public static string LoadOrCreateDeviceId(ISecretStore store)
    {
        ArgumentNullException.ThrowIfNull(store);

        const string Key = "local-device-id";

        if (store.Read(Key) is { Length: 16 } stored)
        {
            return new Guid(stored).ToString();
        }

        var id = Guid.NewGuid();
        store.Write(Key, id.ToByteArray());
        return id.ToString();
    }

    /// <summary>
    /// Builds and starts the client.
    ///
    /// <para>Returns a result rather than throwing: every failure here is
    /// something to tell the user in a sentence, and an exception escaping into
    /// <c>OnStartup</c> would close the application before anything could.</para>
    /// </summary>
    /// <param name="relaySearchFrom">
    /// Where to start looking for a <c>.env</c> holding the relay secret.
    /// Defaults to the binary's directory, and is a parameter because the search
    /// walks upwards -- a test cannot isolate itself from the repository's own
    /// <c>.env</c> by clearing an environment variable.
    /// </param>
    public static async Task<StartupResult> RunAsync(
        IClipboard clipboard,
        string stateDirectory,
        string deviceName,
        string? relaySearchFrom = null,
        HypoSettings? settings = null,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(clipboard);

        settings ??= new HypoSettings();

        ISecretStore store;
        string deviceId;
        ClipboardHistoryStore history;

        try
        {
            Directory.CreateDirectory(stateDirectory);
            store = new FileSecretStore(stateDirectory);
            deviceId = LoadOrCreateDeviceId(store);
            history = new ClipboardHistoryStore(
                Path.Combine(stateDirectory, "history.db"), settings.HistoryLimit);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new StartupResult
            {
                Outcome = StartupOutcome.Failed,
                Message = $"Hypo could not use {stateDirectory}: {ex.Message}",
            };
        }

        RelayOptions relay;
        try
        {
            relay = RelayOptions.FromEnvironment(
                deviceId, "windows", searchFrom: relaySearchFrom ?? AppContext.BaseDirectory);
        }
        catch (InvalidOperationException)
        {
            // No relay secret. The LAN still works, so this is only fatal when
            // there is nothing paired to reach over it either.
            history.Dispose();

            return new StartupResult
            {
                Outcome = StartupOutcome.NotConfigured,
                Message =
                    "Hypo has no relay credentials, so it can only sync with devices on this "
                    + $"network. Set {RelayOptions.SecretVariable} to sync when they are elsewhere.",
                DeviceId = deviceId,
            };
        }

        var client = HypoClient.Create(
            clipboard, store, history, deviceId, deviceName, relay,
            lanPort: settings.LanPort,
            lanEnabled: settings.LanEnabled,
            cloudEnabled: settings.CloudEnabled);

        try
        {
            await client.StartAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            await client.DisposeAsync().ConfigureAwait(false);
            history.Dispose();

            return new StartupResult
            {
                Outcome = StartupOutcome.Failed,
                Message = $"Hypo could not start syncing: {ex.Message}",
                DeviceId = deviceId,
            };
        }

        return new StartupResult
        {
            Outcome = StartupOutcome.Started,
            Message = $"Syncing as {deviceName}.",
            Client = client,
            History = history,
            DeviceId = deviceId,
        };
    }
}
