using System.Text;
using Hypo.Core.Abstractions;
using Hypo.Core.History;
using Hypo.Core.Pairing;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Core.Transport;
using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

public class SettingsViewModelTests : IDisposable
{
    private const string PhoneId = "bbe296d6-0785-43d2-91b6-b135b72f4c41";
    private const string LaptopId = "007e4a95-0e1a-4b10-91fa-87942efaa68e";

    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-settings-vm").FullName;
    private readonly ClipboardHistoryStore _history;
    private readonly InMemorySecretStore _store = new();
    private readonly Status _status = new();
    private readonly List<HypoSettings> _saved = [];

    private bool _startsAtLogin;
    private string? _startupRefusal;

    public SettingsViewModelTests()
    {
        _history = new ClipboardHistoryStore(Path.Combine(_dir, "history.db"));

        _store.Write(PhoneId, new byte[32]);
        PairedDevices.Remember(_store, PhoneId, "OPPO PLP110");
        _store.Write(LaptopId, new byte[32]);
        PairedDevices.Remember(_store, LaptopId, "derek's MacBook Air");
    }

    public void Dispose()
    {
        _history.Dispose();
        Directory.Delete(_dir, recursive: true);
    }

    private sealed class Status : ISyncStatusSource
    {
        public IReadOnlyCollection<string> LanPeers { get; set; } = [];

        public TransportState State { get; set; } = TransportState.Disconnected;
    }

    private SettingsViewModel Build(HypoSettings? settings = null)
    {
        var model = new SettingsViewModel(
            _store,
            _history,
            _status,
            settings ?? new HypoSettings(),
            _saved.Add,
            () => _startsAtLogin,
            enabled =>
            {
                if (_startupRefusal is not null)
                {
                    return _startupRefusal;
                }

                _startsAtLogin = enabled;
                return null;
            });

        model.Refresh();
        return model;
    }

    private void Fill(int count)
    {
        for (var i = 0; i < count; i++)
        {
            _history.Add(new HistoryEntry
            {
                Content = new ClipboardContent
                {
                    ContentType = ContentType.Text,
                    Data = Encoding.UTF8.GetBytes($"entry {i}"),
                },
                CopiedAt = DateTimeOffset.UnixEpoch.AddMinutes(i),
            });
        }
    }

    [Fact]
    public void ListsPairedDevicesByName()
    {
        var model = Build();

        Assert.Equal(
            ["derek's MacBook Air", "OPPO PLP110"],
            model.Devices.Select(d => d.DisplayName));
    }

    [Fact]
    public void SaysWhichDevicesAreOnThisNetwork()
    {
        _status.LanPeers = [PhoneId];

        var model = Build();

        Assert.Equal("On this network", model.Devices.Single(d => d.DeviceId == PhoneId).Status);

        // Not "offline": a phone out of the house still syncs through the relay,
        // and calling that offline sends someone hunting a fault that is not there.
        Assert.Equal("Not on this network", model.Devices.Single(d => d.DeviceId == LaptopId).Status);
    }

    [Fact]
    public void UnpairingRemovesTheDeviceAndSaysWhatThatMeans()
    {
        var model = Build();

        model.Unpair(model.Devices.Single(d => d.DeviceId == PhoneId));

        Assert.DoesNotContain(model.Devices, d => d.DeviceId == PhoneId);
        Assert.Null(_store.Read(PhoneId));
        Assert.Contains("pair the two devices", model.LastMessage);
    }

    [Fact]
    public void TheHistoryLimitStartsAtTheDesignsNumberAndAppliesOnOpening()
    {
        Fill(30);

        var model = Build(new HypoSettings { HistoryLimit = 12 });

        // Applied by the constructor: a limit that only took effect after the
        // next copy would look like it had not been saved.
        Assert.Equal(12, _history.Recent(2000).Count);
        Assert.Equal(200, new HypoSettings().HistoryLimit);
        Assert.Equal(12, model.Settings.HistoryLimit);
    }

    [Fact]
    public void LoweringTheLimitSaysHowMuchWentWithIt()
    {
        Fill(30);
        var model = Build();

        model.SetHistoryLimit(10);

        Assert.Equal(10, _history.Recent(2000).Count);
        Assert.Contains("20 older entries were removed", model.LastMessage);
        Assert.Equal(10, _saved[^1].HistoryLimit);
    }

    [Fact]
    public void RaisingTheLimitDoesNotClaimToHaveRemovedAnything()
    {
        Fill(5);
        var model = Build();

        model.SetHistoryLimit(500);

        Assert.Equal("Keeping 500 entries.", model.LastMessage);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(9)]
    [InlineData(2001)]
    public void ARefusedLimitChangesNothing(int limit)
    {
        Fill(20);
        var model = Build();

        model.SetHistoryLimit(limit);

        Assert.Equal(20, _history.Recent(2000).Count);
        Assert.Empty(_saved);
        Assert.Contains("between 10 and 2000", model.LastMessage);
    }

    [Fact]
    public void ClearingSaysHowMuchWent()
    {
        Fill(7);
        var model = Build();

        model.ClearHistory();

        Assert.Empty(_history.Recent());
        Assert.Equal("Cleared 7 entries.", model.LastMessage);
    }

    [Fact]
    public void ClearingAnEmptyHistorySaysSoRatherThanClaimingSuccess()
    {
        var model = Build();

        model.ClearHistory();

        Assert.Equal("There was nothing to clear.", model.LastMessage);
    }

    [Fact]
    public void StartingWithWindowsCanBeTurnedOnAndOff()
    {
        var model = Build();

        model.SetRunAtLogin(true);
        Assert.True(model.RunsAtLogin);
        Assert.Contains("when you sign in", model.LastMessage);

        model.SetRunAtLogin(false);
        Assert.False(model.RunsAtLogin);
    }

    [Fact]
    public void ASwitchWindowsRefusesToMoveDoesNotMove()
    {
        // Group policy can lock the Run key. A switch that stayed where it was
        // put would be telling someone their machine does something it will not.
        _startupRefusal = "Windows would not let Hypo change this: access denied";

        var model = Build();
        model.SetRunAtLogin(true);

        Assert.False(model.RunsAtLogin);
        Assert.Equal(_startupRefusal, model.LastMessage);
    }

    [Theory]
    [InlineData(TransportState.Disconnected, 0, "Not connected")]
    [InlineData(TransportState.Connecting, 0, "Connecting…")]
    [InlineData(TransportState.Connected, 0, "Connected through the relay")]
    [InlineData(TransportState.Connected, 1, "Connected — 1 device on this network")]
    [InlineData(TransportState.Connected, 3, "Connected — 3 devices on this network")]
    public void TheStatusLineSaysWhichConnectionIsCarryingIt(
        TransportState state, int peers, string expected)
    {
        _status.State = state;
        _status.LanPeers = Enumerable.Range(0, peers).Select(i => $"peer-{i}").ToArray();

        Assert.Equal(expected, Build().ConnectionSummary);
    }

    [Fact]
    public void TheThreeSwitchesAreWrittenDownWhenChanged()
    {
        var model = Build();

        model.SetShareWithWindowsHistory(true);
        model.SetAllowCloudClipboardUpload(true);
        model.SetNotifyOnArrival(false);

        Assert.True(_saved[^1].ShareWithWindowsHistory);
        Assert.True(_saved[^1].AllowCloudClipboardUpload);
        Assert.False(_saved[^1].NotifyOnArrival);
    }
}
