using Hypo.Core.Protocol;

namespace Hypo.Core.Discovery;

/// <summary>
/// A peer found over mDNS. The TXT schema was measured against live macOS and
/// Android clients; see the design spec section 4.2.
/// </summary>
public sealed record DiscoveredPeer
{
    public const string ServiceType = "_hypo._tcp.local";

    public required string InstanceName { get; init; }
    public required string DisplayName { get; init; }
    public required string Host { get; init; }
    public required string Address { get; init; }
    public required int Port { get; init; }
    public required IReadOnlyDictionary<string, string> Txt { get; init; }

    public string? DeviceId { get; init; }
    public byte[]? PublicKey { get; init; }
    public byte[]? SigningPublicKey { get; init; }
    public string? Version { get; init; }

    /// <summary>
    /// Built from the A record rather than the advertised hostname, which on
    /// macOS is a .local name that would need resolving again. Always ws://:
    /// the advertised "protocols=ws+tls" is not implemented by any client.
    /// </summary>
    public Uri WebSocketUri => new($"ws://{Address}:{Port}/");

    public static DiscoveredPeer FromTxt(
        string instanceName,
        string host,
        string address,
        int port,
        IReadOnlyDictionary<string, string> txt)
    {
        ArgumentNullException.ThrowIfNull(txt);

        return new DiscoveredPeer
        {
            InstanceName = instanceName,
            DisplayName = DnsSdName.InstanceLabel(instanceName, ServiceType),
            Host = host,
            Address = address,
            Port = port,
            Txt = txt,
            DeviceId = txt.TryGetValue("device_id", out var id) ? id.ToLowerInvariant() : null,
            PublicKey = TryKey(txt, "pub_key"),
            SigningPublicKey = TryKey(txt, "signing_pub_key"),
            Version = txt.GetValueOrDefault("version"),
        };
    }

    private static byte[]? TryKey(IReadOnlyDictionary<string, string> txt, string key)
    {
        if (!txt.TryGetValue(key, out var value))
        {
            return null;
        }

        try
        {
            return Base64Compat.Decode(value);
        }
        catch (FormatException)
        {
            // A peer advertising a malformed key is not a reason to hide it from
            // the device list; pairing will fail later with a clearer message.
            return null;
        }
    }
}
