namespace Hypo.Core.Sync;

/// <summary>
/// Suppresses a clipboard item that has just been seen.
///
/// <para><b>Why time-bounded rather than "seen ever".</b> Identical content is
/// not always a duplicate. A person can copy the same string twice on purpose,
/// minutes apart, and that is a real second event they expect to see. So the
/// rule is: identical content within <see cref="Window"/> of the last accepted
/// copy is a duplicate; the same content later is a new entry.</para>
///
/// <para><b>Why this exists at all.</b> The Android client sends the same
/// clipboard item twice over the relay when it has no LAN route to the peer --
/// two envelopes, same content, different ids, both addressed to us. Measured
/// on 2026-08-29; both arrived inside the same second. Envelope-id dedup in
/// DualSyncTransport cannot help, because these are genuinely two messages. A
/// window in the low seconds covers that with a wide margin while staying far
/// below any plausible human repeat.</para>
/// </summary>
public sealed class ContentDeduplicator(TimeProvider? clock = null, TimeSpan? window = null)
{
    private readonly TimeProvider _clock = clock ?? TimeProvider.System;
    private readonly Lock _gate = new();
    private readonly Dictionary<string, DateTimeOffset> _seen = [];

    public TimeSpan Window { get; } = window ?? TimeSpan.FromSeconds(3);

    /// <summary>
    /// A safety valve, not the primary bound. Entries are evicted by age, so
    /// the real bound is arrival rate times <see cref="Window"/> -- a few
    /// thousand entries even at implausible rates. This cap only engages beyond
    /// that, and when it does it drops the oldest, which can discard an entry
    /// the window still covers. That is the deliberate trade: the cost is one
    /// duplicate slipping through during a burst nobody should be producing,
    /// and the alternative is unbounded memory in a process that runs for weeks.
    /// </summary>
    public int Capacity { get; init; } = 4096;

    /// <summary>
    /// Records <paramref name="content"/> and reports whether it should be
    /// acted on. False means it is a duplicate of something accepted within the
    /// window.
    /// </summary>
    public bool ShouldAccept(ClipboardContent content)
    {
        ArgumentNullException.ThrowIfNull(content);

        var key = Convert.ToHexString(content.Hash);
        var now = _clock.GetUtcNow();

        lock (_gate)
        {
            Evict(now);

            if (_seen.TryGetValue(key, out var last) && now - last < Window)
            {
                // Deliberately does *not* refresh the timestamp. A peer
                // retrying in a tight loop would otherwise hold the window open
                // forever and the item would never be accepted again.
                return false;
            }

            _seen[key] = now;
            return true;
        }
    }

    private void Evict(DateTimeOffset now)
    {
        // Age first: that is the rule. The count cap below is a backstop and
        // can discard a still-covered entry, which is why it is set far above
        // any realistic burst.
        foreach (var (key, at) in _seen.ToArray())
        {
            if (now - at >= Window)
            {
                _seen.Remove(key);
            }
        }

        while (_seen.Count > Capacity)
        {
            var oldest = _seen.OrderBy(pair => pair.Value).First().Key;
            _seen.Remove(oldest);
        }
    }
}
