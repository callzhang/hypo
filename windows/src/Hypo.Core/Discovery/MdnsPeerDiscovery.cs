using Makaretu.Dns;

namespace Hypo.Core.Discovery;

/// <summary>
/// Correlates the SRV, A and TXT records that arrive separately for one peer.
/// Split out from the network plumbing so it can be tested without multicast.
/// </summary>
public sealed class MdnsRecordSet
{
    private readonly Dictionary<string, (string Host, int Port)> _srv = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _address = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, IReadOnlyDictionary<string, string>> _txt = new(StringComparer.OrdinalIgnoreCase);

    public void NoteSrv(string instance, string host, int port) => _srv[instance] = (host, port);

    public void NoteAddress(string host, string address) => _address[host] = address;

    public void NoteTxt(string instance, IReadOnlyDictionary<string, string> txt) => _txt[instance] = txt;

    /// <summary>
    /// Returns a peer once both its SRV record and the A record for that SRV
    /// target have arrived. TXT is optional: a peer with no pairing keys is
    /// still worth showing, it just cannot be paired with yet.
    /// </summary>
    public DiscoveredPeer? TryBuildPeer(string instance)
    {
        if (!_srv.TryGetValue(instance, out var srv) ||
            !_address.TryGetValue(srv.Host, out var address))
        {
            return null;
        }

        var txt = _txt.TryGetValue(instance, out var t)
            ? t
            : new Dictionary<string, string>();

        return DiscoveredPeer.FromTxt(instance, srv.Host, address, srv.Port, txt);
    }
}

/// <summary>
/// Publishes this device and browses for peers over mDNS. Validated against
/// live macOS and Android clients; see the design spec section 4.2.
/// </summary>
public sealed class MdnsPeerDiscovery : IPeerDiscovery
{
    private const string QueryName = "_hypo._tcp";

    private readonly MulticastService _mdns = new();
    private readonly ServiceDiscovery _sd;
    private readonly MdnsRecordSet _records = new();
    private readonly Dictionary<string, DiscoveredPeer> _peers = new(StringComparer.OrdinalIgnoreCase);
    private readonly Lock _gate = new();

    private ServiceProfile? _advertised;
    private bool _started;

    public MdnsPeerDiscovery()
    {
        // AnswerReceived lives on MulticastService, not ServiceDiscovery, so the
        // two have to be constructed separately and the service passed in.
        _sd = new ServiceDiscovery(_mdns);
        _mdns.AnswerReceived += OnAnswer;
    }

    public event EventHandler<DiscoveredPeer>? PeerDiscovered;

    // PeerLost is required by IPeerDiscovery but deliberately never raised here:
    // Makaretu surfaces goodbye packets inconsistently across platforms, so
    // staleness eviction is deferred to Plan 3. CS0067 (event never used) is an
    // error under this project's TreatWarningsAsErrors until then.
#pragma warning disable CS0067
    public event EventHandler<string>? PeerLost;
#pragma warning restore CS0067

    public IReadOnlyCollection<DiscoveredPeer> KnownPeers
    {
        get { lock (_gate) { return _peers.Values.ToArray(); } }
    }

    public static bool IsHypoInstance(string instanceName) =>
        instanceName.EndsWith(DiscoveredPeer.ServiceType, StringComparison.OrdinalIgnoreCase);

    public Task AdvertiseAsync(
        string deviceName,
        int port,
        IReadOnlyDictionary<string, string> txt,
        CancellationToken ct = default)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(port);

        var profile = new ServiceProfile(deviceName, QueryName, (ushort)port);
        foreach (var (key, value) in txt)
        {
            profile.AddProperty(key, value);
        }

        _advertised = profile;
        EnsureStarted();
        _sd.Advertise(profile);
        _sd.Announce(profile);
        return Task.CompletedTask;
    }

    public Task StartBrowsingAsync(CancellationToken ct = default)
    {
        EnsureStarted();
        _sd.QueryServiceInstances(QueryName);
        return Task.CompletedTask;
    }

    /// <summary>Re-sends the query. Peers that started late answer this one.</summary>
    public void Refresh() => _sd.QueryServiceInstances(QueryName);

    private void EnsureStarted()
    {
        if (_started)
        {
            return;
        }

        _mdns.Start();
        _started = true;
    }

    private void OnAnswer(object? sender, MessageEventArgs e)
    {
        var changed = new List<DiscoveredPeer>();

        lock (_gate)
        {
            foreach (var record in e.Message.Answers.Concat(e.Message.AdditionalRecords))
            {
                var name = record.Name.ToString();
                switch (record)
                {
                    case SRVRecord srv when IsHypoInstance(name):
                        _records.NoteSrv(name, srv.Target.ToString(), srv.Port);
                        break;
                    case TXTRecord txt when IsHypoInstance(name):
                        _records.NoteTxt(name, ParseTxt(txt));
                        break;
                    case ARecord a:
                        _records.NoteAddress(name, a.Address.ToString());
                        break;
                }
            }

            foreach (var instance in e.Message.Answers
                         .Concat(e.Message.AdditionalRecords)
                         .Select(r => r.Name.ToString())
                         .Where(IsHypoInstance)
                         .Distinct(StringComparer.OrdinalIgnoreCase))
            {
                var peer = _records.TryBuildPeer(instance);
                if (peer is null)
                {
                    continue;
                }

                if (!_peers.TryGetValue(instance, out var existing) || existing != peer)
                {
                    _peers[instance] = peer;
                    changed.Add(peer);
                }
            }
        }

        foreach (var peer in changed)
        {
            PeerDiscovered?.Invoke(this, peer);
        }
    }

    private static Dictionary<string, string> ParseTxt(TXTRecord record)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in record.Strings)
        {
            var split = entry.IndexOf('=');
            if (split > 0)
            {
                result[entry[..split]] = entry[(split + 1)..];
            }
        }

        return result;
    }

    public ValueTask DisposeAsync()
    {
        _mdns.AnswerReceived -= OnAnswer;
        if (_advertised is not null)
        {
            _sd.Unadvertise(_advertised);
        }

        _sd.Dispose();
        _mdns.Dispose();
        return ValueTask.CompletedTask;
    }
}
