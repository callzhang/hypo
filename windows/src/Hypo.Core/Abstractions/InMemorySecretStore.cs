using System.Collections.Concurrent;

namespace Hypo.Core.Abstractions;

/// <summary>Non-persistent secret store for tests and development.</summary>
public sealed class InMemorySecretStore : ISecretStore
{
    private readonly ConcurrentDictionary<string, byte[]> _entries = new(StringComparer.Ordinal);

    public byte[]? Read(string key) =>
        _entries.TryGetValue(Normalise(key), out var value) ? (byte[])value.Clone() : null;

    public void Write(string key, ReadOnlySpan<byte> value) =>
        _entries[Normalise(key)] = value.ToArray();

    public IEnumerable<string> Keys() => _entries.Keys.ToArray();

    public bool Delete(string key) => _entries.TryRemove(Normalise(key), out _);

    private static string Normalise(string key)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        return key.ToLowerInvariant();
    }
}
