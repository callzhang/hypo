namespace Hypo.Core.Abstractions;

/// <summary>
/// Stores secrets as files in one directory, so they outlive a process.
///
/// Development use only: the bytes are written unencrypted. The Windows client
/// stores keys through DPAPI instead — see the design spec section 4.5 — and
/// that implementation satisfies this same interface, so nothing above it
/// changes.
/// </summary>
public sealed class FileSecretStore : ISecretStore
{
    private readonly string _directory;

    public FileSecretStore(string directory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(directory);
        _directory = directory;
        Directory.CreateDirectory(_directory);
    }

    public byte[]? Read(string key)
    {
        var path = PathFor(key);
        return File.Exists(path) ? File.ReadAllBytes(path) : null;
    }

    public void Write(string key, ReadOnlySpan<byte> value)
    {
        var path = PathFor(key);
        File.WriteAllBytes(path, value);

        // Plaintext is the documented tradeoff for a development store;
        // world-readable plaintext is not, and costs nothing to avoid.
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }

    public bool Delete(string key)
    {
        var path = PathFor(key);
        if (!File.Exists(path))
        {
            return false;
        }

        File.Delete(path);
        return true;
    }

    /// <summary>
    /// Keys are device ids that arrive over the network, so the name is
    /// validated rather than trusted: anything outside the expected alphabet is
    /// rejected instead of being pasted into a path.
    /// </summary>
    private string PathFor(string key)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);

        var normalised = key.ToLowerInvariant();
        foreach (var c in normalised)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c != '-' && c != '_')
            {
                throw new ArgumentException(
                    $"A secret key may contain only letters, digits, '-' and '_'; got '{key}'.",
                    nameof(key));
            }
        }

        return Path.Combine(_directory, normalised);
    }
}
