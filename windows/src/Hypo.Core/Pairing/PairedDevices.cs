using Hypo.Core.Abstractions;

namespace Hypo.Core.Pairing;

/// <summary>
/// Which devices this one is paired with, and what they are called.
///
/// <para>The shared key is stored under the peer's device id and nothing else,
/// which is all syncing needs. It is not enough to show anyone: "unpair
/// bbe296d6-0785-43d2-91b6-b135b72f4c41" asks a question nobody can answer.
/// The name is written beside the key at pairing time.</para>
///
/// <para>In the same store rather than a file of its own, under a prefix that
/// cannot collide with a device id. It costs no new plumbing, and the name gets
/// the same protection as everything else there -- a list of the devices someone
/// owns is not secret, but it is not nothing either.</para>
/// </summary>
public static class PairedDevices
{
    private const string NamePrefix = "name:";

    /// <summary>A paired device: always an id, and a name when one is known.</summary>
    public sealed record Device
    {
        public required string DeviceId { get; init; }

        public string? Name { get; init; }

        /// <summary>The name, or a shortened id -- never the empty string.</summary>
        public string DisplayName =>
            string.IsNullOrWhiteSpace(Name) ? $"Unnamed device ({Short(DeviceId)})" : Name;

        private static string Short(string id) => id.Length <= 8 ? id : id[..8];
    }

    /// <summary>Every paired device, newest first is not knowable, so: by name.</summary>
    public static IReadOnlyList<Device> All(ISecretStore store)
    {
        ArgumentNullException.ThrowIfNull(store);

        return store.Keys()
            .Where(key => Guid.TryParse(key, out _))
            .Select(id => new Device { DeviceId = id, Name = NameOf(store, id) })
            .OrderBy(device => device.DisplayName, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }

    public static string? NameOf(ISecretStore store, string deviceId)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceId);

        var stored = store.Read(NamePrefix + deviceId);

        return stored is null or { Length: 0 } ? null : System.Text.Encoding.UTF8.GetString(stored);
    }

    public static void Remember(ISecretStore store, string deviceId, string? name)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceId);

        if (string.IsNullOrWhiteSpace(name))
        {
            return;
        }

        store.Write(NamePrefix + deviceId, System.Text.Encoding.UTF8.GetBytes(name));
    }

    /// <summary>
    /// Forgets a device: its key and its name.
    ///
    /// <para>The key is what matters -- without it nothing from that device can
    /// be decrypted and nothing goes to it. Leaving the name behind would keep
    /// an unpaired device in every list that reads this.</para>
    /// </summary>
    public static bool Forget(ISecretStore store, string deviceId)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceId);

        var removed = store.Delete(deviceId);
        store.Delete(NamePrefix + deviceId);

        return removed;
    }
}
