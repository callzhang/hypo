using System.Text.Json;

namespace Hypo.Core.Presence;

/// <summary>
/// Decides when a peer coming back is worth telling someone about.
///
/// <para>Every reappearance is not. A phone whose screen sleeps, or a laptop
/// changing network, goes offline and back several times an hour; a notification
/// per flip is noise that teaches people to ignore the ones that matter. So a
/// device has to have been gone for <see cref="Threshold"/> before its return is
/// announced.</para>
///
/// <para>The record is persisted because the interesting case spans a restart: a
/// device that went quiet yesterday should still be news when it returns today,
/// even if this application was restarted in between.</para>
/// </summary>
public sealed class PeerReturnTracker
{
    /// <summary>
    /// How long a peer must have been away. A day: long enough that coming back is
    /// news, short enough that a laptop shut over a weekend still announces itself.
    /// </summary>
    public static readonly TimeSpan Threshold = TimeSpan.FromHours(24);

    private readonly string _path;
    private readonly Dictionary<string, DateTimeOffset> _offlineSince;

    public PeerReturnTracker(string stateDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(stateDirectory);

        _path = Path.Combine(stateDirectory, "peer-presence.json");
        _offlineSince = Load(_path);
    }

    /// <summary>
    /// Records who is online now and returns the peers that just came back after
    /// being away longer than <see cref="Threshold"/>.
    /// </summary>
    /// <param name="onlineNow">Peers reachable this moment, over any transport.</param>
    /// <param name="knownPeers">Every paired peer, so absence can be recorded.</param>
    public IReadOnlyList<string> Observe(
        IReadOnlyCollection<string> onlineNow,
        IEnumerable<string> knownPeers,
        DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(onlineNow);
        ArgumentNullException.ThrowIfNull(knownPeers);

        var online = onlineNow
            .Where(id => !string.IsNullOrWhiteSpace(id))
            .Select(id => id.Trim().ToLowerInvariant())
            .ToHashSet();

        var returned = new List<string>();
        var changed = false;

        foreach (var peer in knownPeers
                     .Where(id => !string.IsNullOrWhiteSpace(id))
                     .Select(id => id.Trim().ToLowerInvariant())
                     .Distinct())
        {
            if (online.Contains(peer))
            {
                if (_offlineSince.TryGetValue(peer, out var since))
                {
                    if (now - since >= Threshold)
                    {
                        returned.Add(peer);
                    }

                    _offlineSince.Remove(peer);
                    changed = true;
                }

                // A peer we never saw go offline says nothing: on a first run that
                // would announce every device at once.
                continue;
            }

            // Stamped once, on the way down. Rewriting it on every poll while the
            // peer stays offline would keep resetting the clock, and the day would
            // never elapse.
            if (!_offlineSince.ContainsKey(peer))
            {
                _offlineSince[peer] = now;
                changed = true;
            }
        }

        if (changed)
        {
            Save();
        }

        return returned;
    }

    private static Dictionary<string, DateTimeOffset> Load(string path)
    {
        try
        {
            return File.Exists(path)
                ? JsonSerializer.Deserialize<Dictionary<string, DateTimeOffset>>(File.ReadAllText(path)) ?? []
                : [];
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            // Unreadable state means we have forgotten who was away, which costs a
            // missed notification -- not a reason to fail starting up.
            return [];
        }
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(_offlineSince));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Same bargain as above, in the other direction.
        }
    }
}
